-module(copilot_session).
-type session_health() ::
          ready | connecting | initializing | active_query | error.
-type mcp_wire_content() :: map().
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).
-export([start_link/1,send_query/4,receive_message/3,health/1,stop/1]).
-export([send_control/3,interrupt/1,session_info/1,set_model/2]).
-export([callback_mode/0,init/1,terminate/3]).
-export([connecting/3,initializing/3,ready/3,active_query/3,error/3]).
-type state_name() ::
          connecting | initializing | ready | active_query | error.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).
-export_type([state_name/0]).
-dialyzer({no_underspecs,
           [{build_session_info, 1},
            {build_port_opts, 1},
            {call_permission_handler, 3},
            {call_hook_handler, 4},
            {call_user_input_handler, 3},
            {format_mcp_content, 1}]}).
-dialyzer({nowarn_function,
           [{call_permission_handler, 3},
            {call_hook_handler, 4},
            {call_user_input_handler, 3}]}).
-record(data,{port :: port() | undefined,
              buffer = <<>> :: binary(),
              buffer_max :: pos_integer(),
              pending =
                  #{} ::
                      #{binary() =>
                            {gen_statem:from() |
                             internal | internal_create |
                             internal_resume,
                             reference() | undefined}},
              next_id = 1 :: pos_integer(),
              consumer :: gen_statem:from() | undefined,
              query_ref :: reference() | undefined,
              msg_queue :: queue:queue() | undefined,
              session_id :: binary() | undefined,
              copilot_session_id :: binary() | undefined,
              opts :: map(),
              cli_path :: string(),
              model :: binary() | undefined,
              sdk_mcp_registry ::
                  beam_agent_mcp_core:mcp_registry() | undefined,
              permission_handler :: fun() | undefined,
              user_input_handler :: fun() | undefined,
              sdk_hook_registry ::
                  beam_agent_hooks_core:hook_registry() | undefined,
              query_start_time :: integer() | undefined}).
-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(copilot_session, Opts, []).
-spec send_query(pid(), binary(), map(), timeout()) ->
                    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).
-spec receive_message(pid(), reference(), timeout()) ->
                         {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).
-spec health(pid()) -> session_health().
health(Pid) ->
    gen_statem:call(Pid, health, 5000).
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 30000).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 10000).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 10000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 10000).
-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].
-spec init(map()) -> gen_statem:init_result(state_name()).
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = resolve_cli_path(Opts),
    HookRegistry =
        beam_agent_hooks_core:build_registry(maps:get(sdk_hooks, Opts,
                                                 undefined)),
    McpRegistry = build_mcp_registry(Opts),
    Opts1 =
        case McpRegistry of
            undefined ->
                Opts;
            Reg ->
                case beam_agent_mcp_core:all_tool_definitions(Reg) of
                    [] ->
                        Opts;
                    ToolDefs ->
                        Opts#{sdk_tools => ToolDefs}
                end
        end,
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    Data =
        #data{opts = Opts1,
              cli_path = CliPath,
              buffer_max = maps:get(buffer_max, Opts, 2097152),
              model = maps:get(model, Opts, undefined),
              session_id = maps:get(session_id, Opts, undefined),
              sdk_mcp_registry = McpRegistry,
              permission_handler = PermHandler,
              user_input_handler = UserInputHandler,
              sdk_hook_registry = HookRegistry},
    case open_copilot_port(Data) of
        {ok, Port} ->
            {ok, connecting, Data#data{port = Port}};
        {error, Reason} ->
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.
-spec terminate(term(), state_name(), #data{}) -> ok.
terminate(Reason, _State, Data) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  Data),
    close_port(Data#data.port),
    maps:foreach(fun(_Id, {From, TRef}) ->
                        cancel_timer(TRef),
                        case From of
                            internal ->
                                ok;
                            internal_create ->
                                ok;
                            _ ->
                                gen_statem:reply(From,
                                                 {error,
                                                  session_terminated})
                        end
                 end,
                 Data#data.pending),
    case Data#data.consumer of
        undefined ->
            ok;
        Consumer ->
            gen_statem:reply(Consumer, {error, session_terminated})
    end,
    ok.
-spec connecting(gen_statem:event_type(), term(), #data{}) ->
                    state_callback_result().
connecting(enter, _OldState, Data) ->
    beam_agent_telemetry_core:state_change(copilot, undefined, connecting),
    ReqId = make_request_id(Data),
    PingMsg =
        copilot_protocol:encode_request(ReqId,
                                        <<"ping">>,
                                        #{<<"message">> => <<"hello">>}),
    port_command(Data#data.port, copilot_frame:encode_message(PingMsg)),
    NewData =
        Data#data{next_id = Data#data.next_id + 1,
                  pending =
                      maps:put(ReqId,
                               {internal, undefined},
                               Data#data.pending)},
    {keep_state, NewData, [{state_timeout, 15000, connect_timeout}]};
connecting(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(NewBuffer),
                                                 Data#data.buffer_max),
            {next_state, error,
             Data#data{buffer = <<>>},
             [{next_event, internal, {connect_error, buffer_overflow}}]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData = NewData0#data{buffer = RestBuf},
                    case
                        handle_connecting_messages(Messages, NewData)
                    of
                        {ping_ok, Data1} ->
                            {next_state, initializing, Data1};
                        {wait, Data1} ->
                            {keep_state, Data1}
                    end
            end
    end;
connecting(state_timeout, connect_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {connect_error, connect_timeout}}]};
connecting(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};
connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};
connecting({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
connecting({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, connecting}}]}.
-spec initializing(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
initializing(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(copilot, OldState, initializing),
    ReqId = make_request_id(Data),
    {Method, Params, PendingTag} = init_request(Data),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData =
        Data#data{next_id = Data#data.next_id + 1,
                  pending =
                      maps:put(ReqId,
                               {PendingTag, undefined},
                               Data#data.pending)},
    {keep_state, NewData, [{state_timeout, 15000, init_timeout}]};
initializing(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(NewBuffer),
                                                 Data#data.buffer_max),
            {next_state, error,
             Data#data{buffer = <<>>},
             [{next_event, internal, {init_error, buffer_overflow}}]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData = NewData0#data{buffer = RestBuf},
                    case handle_init_messages(Messages, NewData) of
                        {session_created, SessionId, Data1} ->
                            _ = fire_hook(session_start,
                                          #{session_id => SessionId},
                                          Data1),
                            {next_state, ready,
                             Data1#data{copilot_session_id = SessionId}};
                        {wait, Data1} ->
                            {keep_state, Data1}
                    end
            end
    end;
initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {init_error, init_timeout}}]};
initializing(info,
             {Port, {exit_status, Code}},
             #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};
initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};
initializing({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, initializing}}]}.
-spec ready(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
ready(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(copilot, OldState, ready),
    keep_state_and_data;
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            case
                fire_hook(user_prompt_submit, #{prompt => Prompt}, Data)
            of
                {deny, _Reason} ->
                    {keep_state_and_data,
                     [{reply, From, {error, denied_by_hook}}]};
                _ ->
                    Ref = make_ref(),
                    StartTime =
                        beam_agent_telemetry_core:span_start(copilot, query,
                                                        #{prompt =>
                                                              Prompt}),
                    ReqId = make_request_id(Data),
                    SendParams =
                        copilot_protocol:build_session_send_params(SessionId,
                                                                   Prompt,
                                                                   Params),
                    Msg =
                        copilot_protocol:encode_request(ReqId,
                                                        <<"session.send">>,
                                                        SendParams),
                    port_command(Data#data.port,
                                 copilot_frame:encode_message(Msg)),
                    NewData =
                        Data#data{query_ref = Ref,
                                  msg_queue = queue:new(),
                                  next_id = Data#data.next_id + 1,
                                  pending =
                                      maps:put(ReqId,
                                               {internal, undefined},
                                               Data#data.pending),
                                  query_start_time = StartTime},
                    {next_state, active_query, NewData,
                     [{reply, From, {ok, Ref}}]}
            end
    end;
ready({call, From}, {receive_message, _Ref}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {set_model, Model}, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            ReqId = make_request_id(Data),
            Params =
                #{<<"sessionId">> => SessionId, <<"modelId">> => Model},
            Msg =
                copilot_protocol:encode_request(ReqId,
                                                <<"session.model.switch"
                                                  "To">>,
                                                Params),
            port_command(Data#data.port,
                         copilot_frame:encode_message(Msg)),
            NewData =
                Data#data{next_id = Data#data.next_id + 1,
                          pending =
                              maps:put(ReqId,
                                       {From, undefined},
                                       Data#data.pending),
                          model = Model},
            {keep_state, NewData}
    end;
ready({call, From}, {send_control, Method, Params}, Data) ->
    ReqId = make_request_id(Data),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData =
        Data#data{next_id = Data#data.next_id + 1,
                  pending =
                      maps:put(ReqId,
                               {From, undefined},
                               Data#data.pending)},
    {keep_state, NewData};
ready({call, From}, interrupt, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
ready(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    case process_buffer(NewBuffer, Data) of
        {Messages, RestBuf, NewData0} ->
            NewData1 = NewData0#data{buffer = RestBuf},
            NewData2 = handle_ready_messages(Messages, NewData1),
            {keep_state, NewData2}
    end;
ready(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};
ready(info, {'EXIT', Port, _Reason}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, abnormal}}]}.
-spec active_query(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
active_query(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(copilot, OldState, active_query),
    keep_state_and_data;
active_query({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From},
             {receive_message, Ref},
             #data{query_ref = Ref} = Data) ->
    case queue:out(Data#data.msg_queue) of
        {{value, Msg}, NewQueue} ->
            case is_terminal_message(Msg) of
                true ->
                    {next_state, ready,
                     Data#data{msg_queue = undefined,
                               consumer = undefined,
                               query_ref = undefined},
                     [{reply, From, {ok, Msg}}]};
                false ->
                    {keep_state,
                     Data#data{msg_queue = NewQueue},
                     [{reply, From, {ok, Msg}}]}
            end;
        {empty, _} ->
            {keep_state, Data#data{consumer = From}}
    end;
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
active_query({call, From}, interrupt, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            ReqId = make_request_id(Data),
            Params = #{<<"sessionId">> => SessionId},
            Msg =
                copilot_protocol:encode_request(ReqId,
                                                <<"session.abort">>,
                                                Params),
            port_command(Data#data.port,
                         copilot_frame:encode_message(Msg)),
            NewData =
                Data#data{next_id = Data#data.next_id + 1,
                          pending =
                              maps:put(ReqId,
                                       {internal, undefined},
                                       Data#data.pending)},
            {keep_state, NewData, [{reply, From, ok}]}
    end;
active_query({call, From}, {send_control, Method, Params}, Data) ->
    ReqId = make_request_id(Data),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData =
        Data#data{next_id = Data#data.next_id + 1,
                  pending =
                      maps:put(ReqId,
                               {From, undefined},
                               Data#data.pending)},
    {keep_state, NewData};
active_query({call, From}, {set_model, _Model}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(NewBuffer),
                                                 Data#data.buffer_max),
            Actions =
                case Data#data.consumer of
                    undefined ->
                        [];
                    Consumer ->
                        [{reply, Consumer, {error, buffer_overflow}}]
                end,
            {next_state, error,
             Data#data{buffer = <<>>, consumer = undefined},
             [{next_event, internal, buffer_overflow} | Actions]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData1 = NewData0#data{buffer = RestBuf},
                    NewData2 =
                        handle_active_messages(Messages, NewData1),
                    case NewData2#data.msg_queue of
                        undefined ->
                            {next_state, ready, NewData2};
                        _ ->
                            {keep_state, NewData2}
                    end
            end
    end;
active_query(info,
             {Port, {exit_status, Code}},
             #data{port = Port} = Data) ->
    maybe_span_exception(Data, {cli_exit, Code}),
    ErrorMsg =
        #{type => error,
          content =>
              iolist_to_binary(io_lib:format("CLI exited with code ~p d"
                                             "uring query",
                                             [Code]))},
    Data1 =
        deliver_or_enqueue(ErrorMsg,
                           Data#data{query_start_time = undefined}),
    ResultMsg =
        #{type => result,
          is_error => true,
          content => <<"CLI process exited unexpectedly">>},
    Data2 = deliver_or_enqueue(ResultMsg, Data1),
    {next_state, error,
     Data2#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};
active_query(info, {'EXIT', Port, Reason}, #data{port = Port} = Data) ->
    maybe_span_exception(Data, {port_crash, Reason}),
    ErrorMsg = #{type => error, content => <<"CLI process crashed">>},
    Data1 =
        deliver_or_enqueue(ErrorMsg,
                           Data#data{query_start_time = undefined}),
    {next_state, error,
     Data1#data{port = undefined},
     [{next_event, internal, {port_exit, abnormal}}]}.
-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(copilot, OldState, error),
    close_port(Data#data.port),
    maps:foreach(fun(_Id, {From, TRef}) ->
                        cancel_timer(TRef),
                        case From of
                            internal ->
                                ok;
                            internal_create ->
                                ok;
                            _ ->
                                gen_statem:reply(From,
                                                 {error, session_error})
                        end
                 end,
                 Data#data.pending),
    NewData = Data#data{port = undefined, pending = #{}},
    {keep_state, NewData, [{state_timeout, 60000, auto_stop}]};
error(internal, Reason, _Data) ->
    logger:error("Copilot session error: ~p", [Reason]),
    keep_state_and_data;
error(state_timeout, auto_stop, _Data) ->
    {stop, {shutdown, error_linger_expired}};
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]};
error(info, {_Port, _}, _Data) ->
    keep_state_and_data;
error(info, {'EXIT', _, _}, _Data) ->
    keep_state_and_data.
-spec open_copilot_port(#data{}) -> {ok, port()} | {error, term()}.
open_copilot_port(Data) ->
    CliPath = Data#data.cli_path,
    Args = copilot_protocol:build_cli_args(Data#data.opts),
    Env = copilot_protocol:build_env(Data#data.opts),
    PortOpts = build_port_opts(Data#data.opts),
    try
        Port =
            open_port({spawn_executable, CliPath},
                      [{args, Args}, {env, Env} | PortOpts]),
        {ok, Port}
    catch
        error:Reason ->
            {error, {open_port_failed, Reason}}
    end.
-spec build_port_opts(map()) -> list().
build_port_opts(Opts) ->
    Base = [binary, stream, use_stdio, exit_status, hide],
    WorkDir = maps:get(work_dir, Opts, maps:get(cwd, Opts, undefined)),
    case WorkDir of
        undefined ->
            Base;
        Dir when is_binary(Dir) ->
            [{cd, binary_to_list(Dir)} | Base];
        Dir when is_list(Dir) ->
            [{cd, Dir} | Base]
    end.
-spec resolve_cli_path(map()) -> string().
resolve_cli_path(Opts) ->
    case maps:get(cli_path, Opts, undefined) of
        undefined ->
            "copilot";
        Path when is_binary(Path) ->
            binary_to_list(Path);
        Path when is_list(Path) ->
            Path
    end.
-spec process_buffer(binary(), #data{}) -> {[map()], binary(), #data{}}.
process_buffer(Buffer, Data) ->
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Buffer),
    {Events, NewData} = dispatch_jsonrpc(RawMsgs, Data, []),
    {Events, RestBuf, NewData}.
-spec dispatch_jsonrpc([map()], #data{}, [map()]) -> {[map()], #data{}}.
dispatch_jsonrpc([], Data, Acc) ->
    {lists:reverse(Acc), Data};
dispatch_jsonrpc([Msg | Rest], Data, Acc) ->
    case beam_agent_jsonrpc:decode(Msg) of
        {response, Id, Result} ->
            NewData = handle_response(Id, {ok, Result}, Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        {error_response, Id, Code, ErrMsg, ErrData} ->
            NewData =
                handle_response(Id,
                                {error, {Code, ErrMsg, ErrData}},
                                Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        {notification, <<"session.event">>, Params} ->
            Event = maps:get(<<"event">>, Params, Params),
            dispatch_jsonrpc(Rest, Data, [Event | Acc]);
        {notification, _Method, _Params} ->
            dispatch_jsonrpc(Rest, Data, Acc);
        {request, ReqId, Method, Params} ->
            NewData = handle_server_request(ReqId, Method, Params, Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        {unknown, _} ->
            dispatch_jsonrpc(Rest, Data, Acc)
    end.
-spec handle_response(binary() | integer(),
                      {ok, term()} | {error, term()},
                      #data{}) ->
                         #data{}.
handle_response(Id, Result, Data) ->
    BinId = ensure_binary_id(Id),
    case maps:take(BinId, Data#data.pending) of
        {{internal, TRef}, NewPending} ->
            cancel_timer(TRef),
            Data#data{pending = NewPending};
        {{internal_create, TRef}, NewPending} ->
            cancel_timer(TRef),
            SessionId = extract_response_session_id(Result),
            Data#data{pending = NewPending,
                      copilot_session_id = SessionId};
        {{internal_resume, TRef}, NewPending} ->
            cancel_timer(TRef),
            SessionId = extract_response_session_id(Result),
            Data#data{pending = NewPending,
                      copilot_session_id = SessionId};
        {{From, TRef}, NewPending} ->
            cancel_timer(TRef),
            gen_statem:reply(From, Result),
            Data#data{pending = NewPending};
        error ->
            Data
    end.
-spec init_request(#data{}) ->
                      {binary(),
                       map(),
                       internal_create | internal_resume}.
init_request(#data{opts = Opts, session_id = SessionId}) ->
    ResumeRequested = maps:get(resume, Opts, SessionId =/= undefined),
    case {ResumeRequested, SessionId} of
        {true, ResumeId}
            when is_binary(ResumeId), byte_size(ResumeId) > 0 ->
            {<<"session.resume">>,
             copilot_protocol:build_session_resume_params(ResumeId,
                                                          Opts),
             internal_resume};
        _ ->
            {<<"session.create">>,
             copilot_protocol:build_session_create_params(Opts),
             internal_create}
    end.
-spec extract_response_session_id({ok, term()} |
                                  {error, {integer(), binary(), term()}}) ->
                                     binary() | undefined.
extract_response_session_id({ok, #{<<"sessionId">> := SId}})
    when is_binary(SId) ->
    SId;
extract_response_session_id({ok, #{<<"session_id">> := SId}})
    when is_binary(SId) ->
    SId;
extract_response_session_id({ok, #{session_id := SId}})
    when is_binary(SId) ->
    SId;
extract_response_session_id(_) ->
    undefined.
-dialyzer({nowarn_function, {handle_server_request, 4}}).
-spec handle_server_request(binary() | integer(),
                            binary(),
                            map() | undefined,
                            #data{}) ->
                               #data{}.
handle_server_request(ReqId,
                      <<"tool.call">>,
                      Params,
                      #data{sdk_mcp_registry = Registry} = Data)
    when is_map(Registry) ->
    ToolName = maps:get(<<"toolName">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Result =
        beam_agent_mcp_core:call_tool_by_name(ToolName, Arguments, Registry),
    Response =
        case Result of
            {ok, Content} ->
                WireContent =
                    [ 
                     format_mcp_content(C) ||
                         C <- Content
                    ],
                copilot_protocol:encode_response(ReqId,
                                                 #{<<"resultType">> =>
                                                       <<"success">>,
                                                   <<"content">> =>
                                                       WireContent});
            {error, ErrMsg} ->
                copilot_protocol:encode_response(ReqId,
                                                 #{<<"resultType">> =>
                                                       <<"failure">>,
                                                   <<"error">> => ErrMsg})
        end,
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data;
handle_server_request(ReqId, <<"tool.call">>, _Params, Data) ->
    Response =
        copilot_protocol:encode_response(ReqId,
                                         #{<<"resultType">> =>
                                               <<"failure">>,
                                           <<"error">> =>
                                               <<"No MCP servers regist"
                                                 "ered">>}),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data;
handle_server_request(ReqId, <<"permission.request">>, Params, Data) ->
    Request = maps:get(<<"request">>, Params, Params),
    Invocation = maps:get(<<"invocation">>, Params, #{}),
    Data1 = call_permission_handler(ReqId, Request, Data),
    ContentBin = iolist_to_binary(json:encode(Request)),
    EventMsg =
        #{type => control_request,
          subtype => <<"permission_request">>,
          content => ContentBin,
          timestamp => erlang:system_time(millisecond),
          permission_kind =>
              maps:get(<<"kind">>, Request, <<"unknown">>),
          raw => #{request => Request, invocation => Invocation}},
    deliver_or_enqueue(EventMsg, Data1);
handle_server_request(ReqId, <<"hooks.invoke">>, Params, Data) ->
    HookType = maps:get(<<"hookType">>, Params, <<>>),
    Input = maps:get(<<"input">>, Params, #{}),
    _Context = maps:get(<<"context">>, Params, #{}),
    call_hook_handler(ReqId, HookType, Input, Data);
handle_server_request(ReqId, <<"user_input.request">>, Params, Data) ->
    call_user_input_handler(ReqId, Params, Data);
handle_server_request(ReqId, Method, _Params, Data) ->
    logger:warning("Unknown server request: ~s", [Method]),
    Response =
        copilot_protocol:encode_error_response(ReqId,
                                               -32601,
                                               <<"Method not found: ",
                                                 Method/binary>>),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.
-spec call_permission_handler(binary() | integer(), map(), #data{}) ->
                                 #data{}.
call_permission_handler(ReqId, Request, Data) ->
    Result =
        case Data#data.permission_handler of
            undefined ->
                copilot_protocol:build_permission_result(undefined);
            Handler ->
                try
                    Invocation =
                        #{session_id => Data#data.copilot_session_id},
                    case Handler(Request, Invocation) of
                        PermResult ->
                            copilot_protocol:build_permission_result(PermResult)
                    end
                catch
                    _:_ ->
                        copilot_protocol:build_permission_result(undefined)
                end
        end,
    Response = copilot_protocol:encode_response(ReqId, Result),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.
-spec call_hook_handler(binary() | integer(), binary(), map(), #data{}) ->
                           #data{}.
call_hook_handler(ReqId, HookType, Input, Data) ->
    Result =
        case Data#data.sdk_hook_registry of
            undefined ->
                #{};
            _Registry ->
                Event =
                    case HookType of
                        <<"preToolUse">> ->
                            pre_tool_use;
                        <<"postToolUse">> ->
                            post_tool_use;
                        <<"userPromptSubmitted">> ->
                            user_prompt_submit;
                        <<"sessionStart">> ->
                            session_start;
                        <<"sessionEnd">> ->
                            session_end;
                        <<"errorOccurred">> ->
                            error_occurred;
                        _ ->
                            unknown_hook
                    end,
                case Event of
                    unknown_hook ->
                        #{};
                    _ ->
                        case fire_hook(Event, Input, Data) of
                            ok ->
                                #{};
                            {deny, Reason} ->
                                #{<<"permissionDecision">> => <<"deny">>,
                                  <<"permissionDecisionReason">> =>
                                      Reason};
                            HookResult when is_map(HookResult) ->
                                HookResult;
                            _ ->
                                #{}
                        end
                end
        end,
    WireResult = copilot_protocol:build_hook_result(Result),
    Response = copilot_protocol:encode_response(ReqId, WireResult),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.
-spec call_user_input_handler(binary() | integer(), map(), #data{}) ->
                                 #data{}.
call_user_input_handler(ReqId, Params, Data) ->
    case Data#data.user_input_handler of
        undefined ->
            Response =
                copilot_protocol:encode_error_response(ReqId,
                                                       -32603,
                                                       <<"No user input"
                                                         " handler regi"
                                                         "stered">>),
            port_command(Data#data.port,
                         copilot_frame:encode_message(Response)),
            Data;
        Handler ->
            try
                Request =
                    #{question => maps:get(<<"question">>, Params, <<>>),
                      choices => maps:get(<<"choices">>, Params, []),
                      allow_freeform =>
                          maps:get(<<"allowFreeform">>, Params, true)},
                Ctx = #{session_id => Data#data.copilot_session_id},
                case Handler(Request, Ctx) of
                    InputResult when is_map(InputResult) ->
                        WireResult =
                            copilot_protocol:build_user_input_result(InputResult),
                        Resp =
                            copilot_protocol:encode_response(ReqId,
                                                             WireResult),
                        port_command(Data#data.port,
                                     copilot_frame:encode_message(Resp)),
                        Data
                end
            catch
                Class:Reason:_Stack ->
                    ErrMsg =
                        iolist_to_binary(io_lib:format("User input hand"
                                                       "ler error: ~p:~"
                                                       "p",
                                                       [Class, Reason])),
                    ErrResp =
                        copilot_protocol:encode_error_response(ReqId,
                                                               -32603,
                                                               ErrMsg),
                    port_command(Data#data.port,
                                 copilot_frame:encode_message(ErrResp)),
                    Data
            end
    end.
-spec handle_connecting_messages([map()], #data{}) ->
                                    {ping_ok, #data{}} | {wait, #data{}}.
handle_connecting_messages(_Events, Data) ->
    case maps:size(Data#data.pending) of
        0 ->
            {ping_ok, Data};
        _ ->
            {wait, Data}
    end.
-spec handle_init_messages([map()], #data{}) ->
                              {session_created, binary(), #data{}} |
                              {wait, #data{}}.
handle_init_messages([], Data) ->
    case Data#data.copilot_session_id of
        undefined ->
            {wait, Data};
        SessionId ->
            {session_created, SessionId, Data}
    end;
handle_init_messages([_Event | Rest], Data) ->
    handle_init_messages(Rest, Data).
-spec handle_ready_messages([map()], #data{}) -> #data{}.
handle_ready_messages([], Data) ->
    Data;
handle_ready_messages([Event | Rest], Data) ->
    _Msg = copilot_protocol:normalize_event(Event),
    handle_ready_messages(Rest, Data).
-spec handle_active_messages([map()], #data{}) -> #data{}.
handle_active_messages([], Data) ->
    Data;
handle_active_messages([Event | Rest], Data) ->
    Msg = copilot_protocol:normalize_event(Event),
    case maps:get(type, Msg) of
        result ->
            maybe_span_stop(Data),
            _ = fire_hook(stop, Msg, Data),
            ConsumerWaiting = Data#data.consumer =/= undefined,
            Data1 = deliver_or_enqueue(Msg, Data),
            case ConsumerWaiting of
                true ->
                    Data1#data{msg_queue = undefined,
                               consumer = undefined,
                               query_ref = undefined,
                               query_start_time = undefined};
                false ->
                    Data1#data{query_start_time = undefined}
            end;
        tool_use ->
            _ = fire_hook(pre_tool_use, Msg, Data),
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1);
        tool_result ->
            _ = fire_hook(post_tool_use, Msg, Data),
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1);
        _ ->
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1)
    end.
-spec is_terminal_message(beam_agent_core:message()) -> boolean().
is_terminal_message(#{type := result}) ->
    true;
is_terminal_message(#{type := error, is_error := true}) ->
    true;
is_terminal_message(_) ->
    false.
-spec deliver_or_enqueue(beam_agent_core:message(), #data{}) -> #data{}.
deliver_or_enqueue(Msg,
                   #data{consumer = undefined, msg_queue = Queue} = Data)
    when Queue =/= undefined ->
    _ = track_message(Msg, Data),
    Data#data{msg_queue = queue:in(Msg, Queue)};
deliver_or_enqueue(Msg, #data{consumer = Consumer} = Data)
    when Consumer =/= undefined ->
    _ = track_message(Msg, Data),
    gen_statem:reply(Consumer, {ok, Msg}),
    Data#data{consumer = undefined};
deliver_or_enqueue(_Msg, Data) ->
    Data.
-spec fire_hook(atom(), map(), #data{}) ->
                   ok | {deny, binary()} | term().
fire_hook(Event, Context, #data{sdk_hook_registry = undefined}) ->
    _ = Event,
    _ = Context,
    ok;
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).
-spec make_request_id(#data{}) -> binary().
make_request_id(#data{next_id = N}) ->
    integer_to_binary(N).
-spec ensure_binary_id(binary() | integer()) -> binary().
ensure_binary_id(Id) when is_binary(Id) ->
    Id;
ensure_binary_id(Id) when is_integer(Id) ->
    integer_to_binary(Id).
-spec close_port(port() | undefined) -> ok.
close_port(undefined) ->
    ok;
close_port(Port) ->
    try
        port_close(Port)
    catch
        error:_ ->
            ok
    end,
    ok.
-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    Base =
        #{adapter => copilot,
          session_id => Data#data.copilot_session_id,
          model => Data#data.model,
          cli_path => list_to_binary(Data#data.cli_path)},
    case Data#data.copilot_session_id of
        undefined ->
            Base;
        SId ->
            Base#{copilot_session_id => SId}
    end.
-spec track_message(beam_agent_core:message(), #data{}) -> ok.
track_message(Msg, Data) ->
    SessionId = session_store_id(Data),
    ok =
        beam_agent_session_store_core:register_session(SessionId,
                                                  #{adapter => copilot}),
    StoredMsg = maybe_tag_session_id(Msg, SessionId),
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(SessionId,
                                                     ThreadId,
                                                     StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(SessionId,
                                                    StoredMsg)
    end,
    ok.
-spec session_store_id(#data{}) -> binary().
session_store_id(#data{copilot_session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(#data{session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_Data) ->
    unicode:characters_to_binary(pid_to_list(self())).
-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
                              beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.
-spec build_mcp_registry(map()) ->
                            beam_agent_mcp_core:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    beam_agent_mcp_core:build_registry(maps:get(sdk_mcp_servers, Opts,
                                           undefined)).
-spec format_mcp_content(beam_agent_mcp_core:content_result()) ->
                            mcp_wire_content().
format_mcp_content(#{type := text, text := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_mcp_content(#{type := image, data := ImgData, mime_type := Mime}) ->
    #{<<"type">> => <<"image">>,
      <<"data">> => ImgData,
      <<"mimeType">> => Mime}.
-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(copilot, query, StartTime).
-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(copilot, query, Reason).
