-module(codex_session).
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).
-export([start_link/1,send_query/4,receive_message/3,health/1,stop/1]).
-export([send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         respond_request/3]).
-export([callback_mode/0,init/1,terminate/3]).
-export([initializing/3,ready/3,active_turn/3,error/3]).
-type state_name() :: initializing | ready | active_turn | error.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).
-export_type([state_name/0]).
-dialyzer({no_underspecs,
           [{build_session_info, 1},
            {build_port_opts, 1},
            {build_cli_args, 1},
            {build_approval_response, 2},
            {put_new, 3},
            {safe_user_input_response, 3},
            {dynamic_tool_call_response, 1},
            {dynamic_tool_content_item, 1}]}).
-dialyzer({nowarn_function, [{call_approval_handler, 3}]}).
-record(data,{port :: port() | undefined,
              buffer = <<>> :: binary(),
              buffer_max :: pos_integer(),
              pending =
                  #{} ::
                      #{integer() => {gen_statem:from(), reference()}},
              consumer :: gen_statem:from() | undefined,
              query_ref :: reference() | undefined,
              msg_queue :: queue:queue() | undefined,
              thread_id :: binary() | undefined,
              turn_id :: binary() | undefined,
              server_info = #{} :: map(),
              server_requests =
                  #{} :: #{binary() => {integer(), binary()}},
              opts :: map(),
              cli_path :: string(),
              model :: binary() | undefined,
              approval_policy :: binary() | undefined,
              sandbox_mode :: binary() | undefined,
              approval_handler ::
                  fun((binary(), map(), map()) ->
                          codex_protocol:approval_decision()) |
                  undefined,
              user_input_handler ::
                  fun((map(), map()) -> {ok, map()} | {error, term()}) |
                  undefined,
              sdk_hook_registry ::
                  beam_agent_hooks_core:hook_registry() | undefined,
              sdk_mcp_registry ::
                  beam_agent_mcp_core:mcp_registry() | undefined,
              query_start_time :: integer() | undefined}).
-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(codex_session, Opts, []).
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
                    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).
-spec receive_message(pid(), reference(), timeout()) ->
                         {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
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
    gen_statem:call(Pid, interrupt, 5000).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5000).
-spec respond_request(pid(), binary() | integer(), map()) ->
                         {ok, term()} | {error, term()}.
respond_request(Pid, RequestId, Params) ->
    gen_statem:call(Pid, {respond_request, RequestId, Params}, 30000).
-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].
-spec init(map()) ->
              gen_statem:init_result(initializing) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath =
        maps:get(cli_path, Opts, os:getenv("CODEX_CLI_PATH", "codex")),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    Model = maps:get(model, Opts, undefined),
    ApprovalPolicy =
        case maps:get(approval_policy, Opts, undefined) of
            undefined ->
                undefined;
            AP when is_atom(AP) ->
                codex_protocol:encode_ask_for_approval(AP);
            AP when is_binary(AP) ->
                AP
        end,
    SandboxMode =
        case maps:get(sandbox_mode, Opts, undefined) of
            undefined ->
                undefined;
            SM when is_atom(SM) ->
                codex_protocol:encode_sandbox_mode(SM);
            SM when is_binary(SM) ->
                SM
        end,
    ApprovalHandler = maps:get(approval_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    HookRegistry = build_hook_registry(Opts),
    McpRegistry = build_mcp_registry(Opts),
    Data =
        #data{opts = Opts,
              cli_path = CliPath,
              buffer_max = BufferMax,
              model = Model,
              approval_policy = ApprovalPolicy,
              sandbox_mode = SandboxMode,
              approval_handler = ApprovalHandler,
              user_input_handler = UserInputHandler,
              sdk_hook_registry = HookRegistry,
              sdk_mcp_registry = McpRegistry,
              msg_queue = queue:new()},
    case open_port_safe(Data) of
        {ok, Port} ->
            {ok, initializing,
             Data#data{port = Port},
             [{state_timeout, 15000, init_timeout}]};
        {error, Reason} ->
            logger:warning("Codex session failed to open port: ~p",
                           [Reason]),
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.
-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = Port} = Data) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  Data),
    close_port(Port),
    ok.
-spec initializing(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
initializing(enter, initializing, Data) ->
    beam_agent_telemetry_core:state_change(codex, undefined, initializing),
    Id = beam_agent_jsonrpc:next_id(),
    InitParams = codex_protocol:initialize_params(Data#data.opts),
    send_json(beam_agent_jsonrpc:encode_request(Id,
                                                <<"initialize">>,
                                                InitParams),
              Data),
    Pending = (Data#data.pending)#{Id => init},
    {keep_state, Data#data{pending = Pending}};
initializing(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, initializing),
    keep_state_and_data;
initializing(info,
             {Port, {data, {eol, Line}}},
             #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_initializing_buffer(Data1);
initializing(info,
             {Port, {data, {noeol, Partial}}},
             #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
initializing(info,
             {Port, {exit_status, Status}},
             #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{state_timeout, 60000, auto_stop},
      {next_event, internal, {port_exit, Status}}]};
initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data, [{state_timeout, 60000, auto_stop}]};
initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};
initializing({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.
-spec ready(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
ready(enter, initializing, Data) ->
    beam_agent_telemetry_core:state_change(codex, initializing, ready),
    _ = fire_hook(session_start,
                  #{event => session_start,
                    system_info => Data#data.server_info},
                  Data),
    keep_state_and_data;
ready(enter, active_turn, _Data) ->
    beam_agent_telemetry_core:state_change(codex, active_turn, ready),
    keep_state_and_data;
ready(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, ready),
    keep_state_and_data;
ready(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_ready_buffer(Data1);
ready(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
ready(info, {Port, {exit_status, _Status}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{state_timeout, 60000, auto_stop}]};
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    HookCtx =
        #{event => user_prompt_submit,
          prompt => Prompt,
          params => Params},
    case fire_hook(user_prompt_submit, HookCtx, Data) of
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_send_query(From, Prompt, Params, Data)
    end;
ready({call, From}, {send_control, Method, Params}, Data) ->
    do_send_control(From, Method, Params, Data);
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};
ready({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state,
     Data#data{approval_policy = Mode},
     [{reply, From, {ok, Mode}}]};
ready({call, From}, {respond_request, RequestId, Params}, Data) ->
    do_respond_request(From, RequestId, Params, Data);
ready({call, From},
      {receive_message, Ref},
      #data{query_ref = Ref, msg_queue = Q} = Data) ->
    case Q of
        undefined ->
            {keep_state,
             Data#data{query_ref = undefined},
             [{reply, From, {error, complete}}]};
        _ ->
            case queue:out(Q) of
                {{value, Msg}, Q1} ->
                    {keep_state,
                     Data#data{msg_queue = Q1},
                     [{reply, From, {ok, Msg}}]};
                {empty, _} ->
                    {keep_state,
                     Data#data{query_ref = undefined,
                               msg_queue = undefined},
                     [{reply, From, {error, complete}}]}
            end
    end;
ready({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
ready(info, {pending_timeout, Id}, #data{pending = Pending} = Data) ->
    {keep_state, Data#data{pending = maps:remove(Id, Pending)}};
ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.
-spec active_turn(gen_statem:event_type(), term(), #data{}) ->
                     state_callback_result().
active_turn(enter, ready, _Data) ->
    beam_agent_telemetry_core:state_change(codex, ready, active_turn),
    keep_state_and_data;
active_turn(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, active_turn),
    keep_state_and_data;
active_turn(info,
            {Port, {data, {eol, Line}}},
            #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_active_buffer(Data1);
active_turn(info,
            {Port, {data, {noeol, Partial}}},
            #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
active_turn(info,
            {Port, {exit_status, Status}},
            #data{port = Port} = Data) ->
    maybe_span_exception(Data, {port_exit, Status}),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    case Data1#data.consumer of
        undefined ->
            {next_state, error, Data1,
             [{state_timeout, 60000, auto_stop}]};
        From ->
            Data2 =
                Data1#data{consumer = undefined, query_ref = undefined},
            {next_state, error, Data2,
             [{reply, From, {error, port_closed}},
              {state_timeout, 60000, auto_stop}]}
    end;
active_turn({call, From},
            {receive_message, Ref},
            #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);
active_turn({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_turn({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_turn({call, From}, interrupt, Data) ->
    case Data#data.turn_id of
        undefined ->
            {keep_state_and_data,
             [{reply, From, {error, no_active_turn}}]};
        TurnId ->
            Id = beam_agent_jsonrpc:next_id(),
            Params = #{<<"turnId">> => TurnId},
            send_json(beam_agent_jsonrpc:encode_request(Id,
                                                        <<"turn/interru"
                                                          "pt">>,
                                                        Params),
                      Data),
            {keep_state_and_data, [{reply, From, ok}]}
    end;
active_turn({call, From}, {send_control, Method, Params}, Data) ->
    do_send_control(From, Method, Params, Data);
active_turn({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_turn({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
active_turn({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};
active_turn({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state,
     Data#data{approval_policy = Mode},
     [{reply, From, {ok, Mode}}]};
active_turn({call, From}, {respond_request, RequestId, Params}, Data) ->
    do_respond_request(From, RequestId, Params, Data);
active_turn(info,
            {pending_timeout, Id},
            #data{pending = Pending} = Data) ->
    {keep_state, Data#data{pending = maps:remove(Id, Pending)}};
active_turn({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.
-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, error),
    keep_state_and_data;
error(internal, {port_exit, _Status}, _Data) ->
    keep_state_and_data;
error(state_timeout, auto_stop, _Data) ->
    {stop, normal};
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.
-spec open_port_safe(#data{}) -> {ok, port()} | {error, term()}.
open_port_safe(Data) ->
    try
        {CliPath, PortOpts} = build_port_opts(Data),
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        {ok, Port}
    catch
        error:Reason ->
            {error, Reason}
    end.
-spec build_port_opts(#data{}) -> {string(), list()}.
build_port_opts(#data{cli_path = CliPath, opts = Opts}) ->
    WorkDir = maps:get(work_dir, Opts, undefined),
    Env = maps:get(env, Opts, []),
    BaseEnv = [{"CODEX_SDK_VERSION", "0.1.0"} | Env],
    Args = build_cli_args(Opts),
    PortOpts =
        [{args, Args},
         {line, 65536},
         binary, exit_status, use_stdio,
         {env, BaseEnv}],
    case WorkDir of
        undefined ->
            {CliPath, PortOpts};
        Dir ->
            {CliPath, [{cd, Dir} | PortOpts]}
    end.
-spec build_cli_args(map()) -> [string()].
build_cli_args(_Opts) ->
    ["--app-server"].
-spec close_port(port() | undefined) -> ok.
close_port(Port) ->
    codex_port_utils:close_port(Port).
-spec send_json(iodata(), #data{}) -> ok.
send_json(Iodata, #data{port = Port}) when Port =/= undefined ->
    port_command(Port, Iodata),
    ok;
send_json(_Iodata, _Data) ->
    ok.
-spec buffer_line(binary(), #data{}) -> #data{}.
buffer_line(Line, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = codex_port_utils:buffer_line(Line, Buffer, Max)}.
-spec append_buffer(binary(), #data{}) -> #data{}.
append_buffer(Partial, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer =
                  codex_port_utils:append_buffer(Partial, Buffer, Max)}.
-spec process_initializing_buffer(#data{}) -> state_callback_result().
process_initializing_buffer(Data) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_init_message(beam_agent_jsonrpc:decode(Map),
                                        Map, Data1);
                {error, _} ->
                    process_initializing_buffer(Data1)
            end
    end.
-spec handle_init_message(beam_agent_jsonrpc:jsonrpc_msg(),
                          map(),
                          #data{}) ->
                             state_callback_result().
handle_init_message({response, Id, Result}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, init} ->
            Pending1 = maps:remove(Id, Data#data.pending),
            Data1 = Data#data{pending = Pending1, server_info = Result},
            send_json(beam_agent_jsonrpc:encode_notification(<<"initial"
                                                               "ized">>,
                                                             undefined),
                      Data1),
            {next_state, ready, Data1};
        _ ->
            process_initializing_buffer(Data)
    end;
handle_init_message({error_response, Id, _Code, Msg, _ErrData},
                    _Raw, Data) ->
    Pending1 = maps:remove(Id, Data#data.pending),
    logger:error("Codex initialize failed: ~s", [Msg]),
    {next_state, error,
     Data#data{pending = Pending1},
     [{state_timeout, 60000, auto_stop}]};
handle_init_message(_Other, _Raw, Data) ->
    process_initializing_buffer(Data).
-spec process_ready_buffer(#data{}) -> state_callback_result().
process_ready_buffer(Data) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_ready_message(beam_agent_jsonrpc:decode(Map),
                                         Map, Data1);
                {error, _} ->
                    process_ready_buffer(Data1)
            end
    end.
-spec handle_ready_message(beam_agent_jsonrpc:jsonrpc_msg(),
                           map(),
                           #data{}) ->
                              state_callback_result().
handle_ready_message({response, Id, Result}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state,
             Data#data{pending = Pending1},
             [{reply, From, {ok, Result}}]};
        _ ->
            {keep_state, Data}
    end;
handle_ready_message({error_response, Id, _Code, Msg, _ErrData},
                     _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state,
             Data#data{pending = Pending1},
             [{reply, From, {error, Msg}}]};
        _ ->
            {keep_state, Data}
    end;
handle_ready_message({request, Id, Method, Params}, _Raw, Data) ->
    Data1 = handle_server_request(Id, Method, Params, Data),
    process_ready_buffer(Data1);
handle_ready_message({notification, Method, Params}, _Raw, Data) ->
    SafeParams =
        case Params of
            undefined ->
                #{};
            P ->
                P
        end,
    Data1 = apply_notification_side_effects(Method, SafeParams, Data),
    process_ready_buffer(Data1);
handle_ready_message(_Other, _Raw, Data) ->
    process_ready_buffer(Data).
-spec process_active_buffer(#data{}) -> state_callback_result().
process_active_buffer(Data) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_active_message(beam_agent_jsonrpc:decode(Map),
                                          Map, Data1);
                {error, _} ->
                    process_active_buffer(Data1)
            end
    end.
-spec handle_active_message(beam_agent_jsonrpc:jsonrpc_msg(),
                            map(),
                            #data{}) ->
                               state_callback_result().
handle_active_message({notification, Method, Params}, _Raw, Data) ->
    SafeParams =
        case Params of
            undefined ->
                #{};
            P ->
                P
        end,
    Data0 = apply_notification_side_effects(Method, SafeParams, Data),
    Msg = codex_protocol:normalize_notification(Method, SafeParams),
    Data1 = fire_notification_hooks(Method, SafeParams, Msg, Data0),
    case Method of
        <<"turn/completed">> ->
            maybe_span_stop(Data1),
            _ = fire_hook(stop,
                          #{event => stop,
                            stop_reason =>
                                maps:get(<<"status">>, SafeParams, <<>>)},
                          Data1),
            deliver_or_enqueue(Msg, Data1,
                               fun(D) ->
                                      {next_state, ready,
                                       D#data{turn_id = undefined,
                                              consumer = undefined,
                                              query_start_time =
                                                  undefined}}
                               end);
        _ ->
            deliver_or_enqueue(Msg, Data1,
                               fun(D) ->
                                      process_active_buffer(D)
                               end)
    end;
handle_active_message({request, Id, Method, Params}, _Raw, Data) ->
    Data1 = handle_server_request(Id, Method, Params, Data),
    process_active_buffer(Data1);
handle_active_message({response, Id, Result}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {thread_then_turn, Prompt, Opts}} ->
            Pending1 = maps:remove(Id, Data#data.pending),
            ThreadId = maps:get(<<"threadId">>, Result, undefined),
            Data1 = Data#data{pending = Pending1, thread_id = ThreadId},
            TurnId = beam_agent_jsonrpc:next_id(),
            TurnParams =
                codex_protocol:turn_start_params(ThreadId, Prompt, Opts),
            send_json(beam_agent_jsonrpc:encode_request(TurnId,
                                                        <<"turn/start">>,
                                                        TurnParams),
                      Data1),
            Data2 =
                Data1#data{pending =
                               (Data1#data.pending)#{TurnId =>
                                                         turn_start}},
            process_active_buffer(Data2);
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            Data1 = Data#data{pending = Pending1},
            ThreadId =
                maps:get(<<"threadId">>, Result, Data1#data.thread_id),
            TurnId = maps:get(<<"turnId">>, Result, Data1#data.turn_id),
            Data2 = Data1#data{thread_id = ThreadId, turn_id = TurnId},
            {keep_state, Data2, [{reply, From, {ok, Result}}]};
        {ok, turn_start} ->
            Pending1 = maps:remove(Id, Data#data.pending),
            ThreadId =
                maps:get(<<"threadId">>, Result, Data#data.thread_id),
            TurnId = maps:get(<<"turnId">>, Result, Data#data.turn_id),
            Data1 =
                Data#data{pending = Pending1,
                          thread_id = ThreadId,
                          turn_id = TurnId},
            process_active_buffer(Data1);
        _ ->
            process_active_buffer(Data)
    end;
handle_active_message({error_response, Id, _Code, Msg, _ErrData},
                      _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {thread_then_turn, _Prompt, _Opts}} ->
            maybe_span_exception(Data, {thread_start_failed, Msg}),
            Pending1 = maps:remove(Id, Data#data.pending),
            ErrorMsg =
                #{type => error,
                  content => Msg,
                  timestamp => erlang:system_time(millisecond)},
            Data1 =
                Data#data{pending = Pending1,
                          query_start_time = undefined},
            deliver_or_enqueue(ErrorMsg, Data1,
                               fun(D) ->
                                      {next_state, ready,
                                       D#data{consumer = undefined,
                                              query_ref = undefined}}
                               end);
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state,
             Data#data{pending = Pending1},
             [{reply, From, {error, Msg}}]};
        {ok, turn_start} ->
            maybe_span_exception(Data, {turn_start_failed, Msg}),
            Pending1 = maps:remove(Id, Data#data.pending),
            ErrorMsg =
                #{type => error,
                  content => Msg,
                  timestamp => erlang:system_time(millisecond)},
            Data1 =
                Data#data{pending = Pending1,
                          query_start_time = undefined},
            deliver_or_enqueue(ErrorMsg, Data1,
                               fun(D) ->
                                      {next_state, ready,
                                       D#data{consumer = undefined,
                                              query_ref = undefined}}
                               end);
        _ ->
            process_active_buffer(Data)
    end;
handle_active_message(_Other, _Raw, Data) ->
    process_active_buffer(Data).
-spec do_send_query(gen_statem:from(), binary(), map(), #data{}) ->
                       state_callback_result().
do_send_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime =
        beam_agent_telemetry_core:span_start(codex, query,
                                        #{prompt => Prompt}),
    MergedOpts = merge_turn_opts(Params, Data),
    Data1 = Data#data{query_start_time = StartTime},
    case Data1#data.thread_id of
        undefined ->
            do_create_thread_and_turn(From, Ref, Prompt, MergedOpts,
                                      Data1);
        ThreadId ->
            do_start_turn(From, Ref, ThreadId, Prompt, MergedOpts,
                          Data1)
    end.
-spec do_create_thread_and_turn(gen_statem:from(),
                                reference(),
                                binary(),
                                map(),
                                #data{}) ->
                                   state_callback_result().
do_create_thread_and_turn(From, Ref, Prompt, Opts, Data) ->
    ThreadId1 = beam_agent_jsonrpc:next_id(),
    ThreadParams = codex_protocol:thread_start_params(Opts),
    send_json(beam_agent_jsonrpc:encode_request(ThreadId1,
                                                <<"thread/start">>,
                                                ThreadParams),
              Data),
    Data1 =
        Data#data{consumer = From,
                  query_ref = Ref,
                  msg_queue = queue:new(),
                  pending =
                      (Data#data.pending)#{ThreadId1 =>
                                               {thread_then_turn,
                                                Prompt, Opts}}},
    {next_state, active_turn, Data1, [{reply, From, {ok, Ref}}]}.
-spec do_start_turn(gen_statem:from(),
                    reference(),
                    binary(),
                    binary(),
                    map(),
                    #data{}) ->
                       state_callback_result().
do_start_turn(From, Ref, ThreadId, Prompt, Opts, Data) ->
    Id = beam_agent_jsonrpc:next_id(),
    TurnParams =
        codex_protocol:turn_start_params(ThreadId, Prompt, Opts),
    send_json(beam_agent_jsonrpc:encode_request(Id,
                                                <<"turn/start">>,
                                                TurnParams),
              Data),
    Data1 =
        Data#data{consumer = From,
                  query_ref = Ref,
                  msg_queue = queue:new(),
                  pending = (Data#data.pending)#{Id => turn_start}},
    {next_state, active_turn, Data1, [{reply, From, {ok, Ref}}]}.
-spec merge_turn_opts(map(), #data{}) -> map().
merge_turn_opts(Params, Data) ->
    M0 = Params,
    M1 =
        case Data#data.model of
            undefined ->
                M0;
            Model ->
                put_new(model, Model, M0)
        end,
    M2 =
        case Data#data.approval_policy of
            undefined ->
                M1;
            AP ->
                put_new(approval_policy, AP, M1)
        end,
    case Data#data.sandbox_mode of
        undefined ->
            M2;
        SM ->
            put_new(sandbox_mode, SM, M2)
    end.
-spec put_new(term(), term(), map()) -> map().
put_new(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true ->
            Map;
        false ->
            Map#{Key => Value}
    end.
-spec do_send_control(gen_statem:from(), binary(), map(), #data{}) ->
                         state_callback_result().
do_send_control(From, Method, Params, Data) ->
    Id = beam_agent_jsonrpc:next_id(),
    send_json(beam_agent_jsonrpc:encode_request(Id, Method, Params),
              Data),
    TimerRef = erlang:send_after(35000, self(), {pending_timeout, Id}),
    Pending = (Data#data.pending)#{Id => {From, TimerRef}},
    {keep_state, Data#data{pending = Pending}}.
-spec do_respond_request(gen_statem:from(),
                         binary() | integer(),
                         map(),
                         #data{}) ->
                            state_callback_result().
do_respond_request(From, RequestId, Params, Data) ->
    RequestIdBin = request_id_binary(RequestId),
    case maps:find(RequestIdBin, Data#data.server_requests) of
        {ok, {WireId, Method}} ->
            ResponseMap = build_request_response(Method, Params),
            send_json(beam_agent_jsonrpc:encode_response(WireId,
                                                         ResponseMap),
                      Data),
            SessionId = session_store_id(Data),
            _ = beam_agent_control_core:resolve_pending_request(SessionId,
                                                           RequestIdBin,
                                                           ResponseMap),
            Requests1 =
                maps:remove(RequestIdBin, Data#data.server_requests),
            {keep_state,
             Data#data{server_requests = Requests1},
             [{reply, From, {ok, ResponseMap}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end.
-spec build_request_response(binary(), map()) -> map().
build_request_response(<<"item/tool/requestUserInput">>, Params) ->
    codex_protocol:request_user_input_response(Params);
build_request_response(_Method, Params) ->
    Params.
-spec handle_server_request(integer(),
                            binary(),
                            map() | undefined,
                            #data{}) ->
                               #data{}.
handle_server_request(Id,
                      <<"mcp/message">>,
                      Params,
                      #data{sdk_mcp_registry = Registry} = Data)
    when is_map(Registry) ->
    SafeParams =
        case Params of
            undefined ->
                #{};
            P ->
                P
        end,
    ServerName = maps:get(<<"server_name">>, SafeParams, <<>>),
    Message = maps:get(<<"message">>, SafeParams, #{}),
    case
        beam_agent_mcp_core:handle_mcp_message(ServerName, Message, Registry)
    of
        {ok, McpResponse} ->
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         McpResponse),
                      Data),
            Data;
        {error, ErrMsg} ->
            ErrResponse = #{<<"error">> => ErrMsg},
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         ErrResponse),
                      Data),
            Data
    end;
handle_server_request(Id,
                      <<"item/tool/requestUserInput">>,
                      Params, Data) ->
    handle_user_input_request(Id,
                              normalize_server_request_params(Params),
                              Data);
handle_server_request(Id, <<"item/tool/call">>, Params, Data) ->
    handle_dynamic_tool_call_request(Id,
                                     normalize_server_request_params(Params),
                                     Data);
handle_server_request(Id,
                      <<"account/chatgptAuthTokens/refresh">>,
                      Params, Data) ->
    RequestId = integer_to_binary(Id),
    Request =
        #{method => <<"account/chatgptAuthTokens/refresh">>,
          params => normalize_server_request_params(Params),
          kind => auth_refresh},
    queue_pending_server_request(Id, RequestId, Request, Data);
handle_server_request(Id, Method, Params, Data) ->
    SafeParams =
        case Params of
            undefined ->
                #{};
            P ->
                P
        end,
    HookCtx =
        #{event => pre_tool_use,
          tool_name => Method,
          tool_input => SafeParams},
    case fire_hook(pre_tool_use, HookCtx, Data) of
        {deny, _Reason} ->
            ResponseMap = #{<<"decision">> => <<"decline">>},
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         ResponseMap),
                      Data),
            Data;
        ok ->
            Decision = call_approval_handler(Method, SafeParams, Data),
            ResponseMap = build_approval_response(Method, Decision),
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         ResponseMap),
                      Data),
            Data
    end.
-spec call_approval_handler(binary(), map(), #data{}) ->
                               codex_protocol:approval_decision().
call_approval_handler(_Method, _Params,
                      #data{approval_handler = undefined, opts = Opts}) ->
    case maps:get(permission_default, Opts, deny) of
        allow ->
            accept;
        _ ->
            decline
    end;
call_approval_handler(Method, Params, #data{approval_handler = Handler}) ->
    try Handler(Method, Params, #{}) of
        Decision when is_atom(Decision) ->
            Decision;
        _ ->
            accept
    catch
        _:_ ->
            decline
    end.
-spec build_approval_response(binary(),
                              codex_protocol:approval_decision()) ->
                                 map().
build_approval_response(<<"item/commandExecution/requestApproval">>,
                        Decision) ->
    codex_protocol:command_approval_response(Decision);
build_approval_response(<<"item/fileChange/requestApproval">>, Decision) ->
    codex_protocol:file_approval_response(Decision);
build_approval_response(_, Decision) ->
    codex_protocol:command_approval_response(Decision).
-spec handle_user_input_request(integer(), map(), #data{}) -> #data{}.
handle_user_input_request(Id, Params,
                          #data{user_input_handler = Handler} = Data)
    when is_function(Handler, 2) ->
    RequestId = integer_to_binary(Id),
    SessionId = session_store_id(Data),
    Request =
        #{method => <<"item/tool/requestUserInput">>,
          params => Params,
          kind => user_input},
    ok =
        beam_agent_control_core:store_pending_request(SessionId, RequestId,
                                                 Request),
    Ctx =
        #{session_id => SessionId,
          thread_id => Data#data.thread_id,
          turn_id => Data#data.turn_id},
    case safe_user_input_response(Handler, Params, Ctx) of
        {ok, ResponseMap} ->
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         ResponseMap),
                      Data),
            _ = beam_agent_control_core:resolve_pending_request(SessionId,
                                                           RequestId,
                                                           ResponseMap),
            Data;
        {error, _Reason} ->
            queue_pending_server_request(Id, RequestId, Request, Data)
    end;
handle_user_input_request(Id, Params, Data) ->
    RequestId = integer_to_binary(Id),
    Request =
        #{method => <<"item/tool/requestUserInput">>,
          params => Params,
          kind => user_input},
    queue_pending_server_request(Id, RequestId, Request, Data).
-spec handle_dynamic_tool_call_request(integer(), map(), #data{}) ->
                                          #data{}.
handle_dynamic_tool_call_request(Id, Params,
                                 #data{sdk_mcp_registry = Registry} =
                                     Data)
    when is_map(Registry) ->
    ToolName = maps:get(<<"tool">>, Params, <<>>),
    Arguments =
        normalize_dynamic_tool_arguments(maps:get(<<"arguments">>,
                                                  Params,
                                                  #{})),
    case
        beam_agent_mcp_core:call_tool_by_name(ToolName, Arguments, Registry)
    of
        {ok, ContentItems} ->
            ResponseMap = dynamic_tool_call_response(ContentItems),
            send_json(beam_agent_jsonrpc:encode_response(Id,
                                                         ResponseMap),
                      Data),
            Data;
        {error, _Reason} ->
            queue_dynamic_tool_call(Id, Params, Data)
    end;
handle_dynamic_tool_call_request(Id, Params, Data) ->
    queue_dynamic_tool_call(Id, Params, Data).
-spec queue_dynamic_tool_call(integer(), map(), #data{}) -> #data{}.
queue_dynamic_tool_call(Id, Params, Data) ->
    RequestId = integer_to_binary(Id),
    Request =
        #{method => <<"item/tool/call">>,
          params => Params,
          kind => dynamic_tool_call},
    queue_pending_server_request(Id, RequestId, Request, Data).
-spec safe_user_input_response(fun((map(), map()) ->
                                       {ok, map()} | {error, term()}),
                               map(),
                               map()) ->
                                  {ok, map()} | {error, term()}.
safe_user_input_response(Handler, Params, Ctx) ->
    try Handler(Params, Ctx) of
        {ok, Result} when is_map(Result) ->
            {ok, codex_protocol:request_user_input_response(Result)};
        {error, _} = Err ->
            Err
    catch
        Class:Reason:Stack ->
            logger:error("codex user_input_handler crashed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, handler_crashed}
    end.
-spec queue_pending_server_request(integer(), binary(), map(), #data{}) ->
                                      #data{}.
queue_pending_server_request(Id, RequestId, Request, Data) ->
    SessionId = session_store_id(Data),
    ok =
        beam_agent_control_core:store_pending_request(SessionId, RequestId,
                                                 Request),
    Msg =
        #{type => control_request,
          request_id => RequestId,
          request => Request,
          subtype => request_subtype(Request),
          timestamp => erlang:system_time(millisecond)},
    Data1 =
        Data#data{server_requests =
                      (Data#data.server_requests)#{RequestId =>
                                                       {Id,
                                                        maps:get(method,
                                                                 Request)}}},
    case
        deliver_or_enqueue(Msg, Data1,
                           fun(D) ->
                                  {keep_state, D}
                           end)
    of
        {keep_state, NewData} ->
            NewData;
        {keep_state, NewData, _Actions} ->
            NewData;
        {next_state, _State, NewData} ->
            NewData;
        {next_state, _State, NewData, _Actions} ->
            NewData
    end.
-spec request_subtype(#{kind := auth_refresh | dynamic_tool_call | user_input,
                        method := <<_:64, _:_*8>>,
                        params := map()}) -> <<_:64, _:_*8>>.
request_subtype(#{kind := user_input}) ->
    <<"user_input">>;
request_subtype(#{kind := dynamic_tool_call}) ->
    <<"dynamic_tool_call">>;
request_subtype(#{kind := auth_refresh}) ->
    <<"auth_refresh">>.
-spec normalize_dynamic_tool_arguments(term()) -> map().
normalize_dynamic_tool_arguments(Args) when is_map(Args) ->
    Args;
normalize_dynamic_tool_arguments(_) ->
    #{}.
-spec dynamic_tool_call_response([beam_agent_mcp_core:content_result()]) ->
                                    map().
dynamic_tool_call_response(ContentItems) ->
    #{<<"success">> => true,
      <<"contentItems">> =>
          [ 
           dynamic_tool_content_item(Item) ||
               Item <- ContentItems
          ]}.
-spec dynamic_tool_content_item(beam_agent_mcp_core:content_result()) ->
                                   map().
dynamic_tool_content_item(#{type := text, text := Text}) ->
    #{<<"type">> => <<"inputText">>, <<"text">> => Text};
dynamic_tool_content_item(#{type := image, data := Data}) ->
    #{<<"type">> => <<"inputImage">>, <<"imageUrl">> => Data};
dynamic_tool_content_item(Other) ->
    #{<<"type">> => <<"inputText">>,
      <<"text">> =>
          unicode:characters_to_binary(io_lib:format("~p", [Other]))}.
-spec try_deliver_message(gen_statem:from(), #data{}) ->
                             state_callback_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state,
             Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            Data1 = Data#data{consumer = From},
            case beam_agent_jsonl:extract_line(Data1#data.buffer) of
                none ->
                    {keep_state, Data1};
                {ok, Line, Rest} ->
                    Data2 = Data1#data{buffer = Rest},
                    case beam_agent_jsonl:decode_line(Line) of
                        {ok, Map} ->
                            handle_active_message(beam_agent_jsonrpc:decode(Map),
                                                  Map, Data2);
                        {error, _} ->
                            {keep_state, Data2}
                    end
            end
    end.
-spec deliver_or_enqueue(beam_agent_core:message(),
                         #data{},
                         fun((#data{}) -> state_callback_result())) ->
                            state_callback_result().
deliver_or_enqueue(Msg,
                   #data{consumer = undefined, msg_queue = Q} = Data,
                   Continue) ->
    _ = track_message(Msg, Data),
    Q1 = queue:in(Msg, Q),
    Continue(Data#data{msg_queue = Q1});
deliver_or_enqueue(Msg, #data{consumer = From} = Data, Continue) ->
    _ = track_message(Msg, Data),
    Data1 = Data#data{consumer = undefined},
    case Continue(Data1) of
        {next_state, NewState, NewData} ->
            {next_state, NewState, NewData, [{reply, From, {ok, Msg}}]};
        {next_state, NewState, NewData, Actions} ->
            {next_state, NewState, NewData,
             [{reply, From, {ok, Msg}} | Actions]};
        {keep_state, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}}]};
        {keep_state, NewData, Actions} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}} | Actions]}
    end.
-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(),
                #data{}) ->
                   ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).
-spec fire_notification_hooks(binary(),
                              map(),
                              beam_agent_core:message(),
                              #data{}) ->
                                 #data{}.
fire_notification_hooks(<<"item/completed">>, Params, _Msg, Data) ->
    Item = maps:get(<<"item">>, Params, #{}),
    ToolName =
        maps:get(<<"command">>,
                 Item,
                 maps:get(<<"filePath">>, Item, <<>>)),
    _ = fire_hook(post_tool_use,
                  #{event => post_tool_use,
                    tool_name => ToolName,
                    content => maps:get(<<"output">>, Item, <<>>)},
                  Data),
    Data;
fire_notification_hooks(_, _, _, Data) ->
    Data.
-spec apply_notification_side_effects(binary(), map(), #data{}) ->
                                         #data{}.
apply_notification_side_effects(<<"serverRequest/resolved">>,
                                Params, Data) ->
    RequestId =
        request_id_binary(maps:get(<<"requestId">>,
                                   Params,
                                   maps:get(requestId, Params, <<>>))),
    case maps:take(RequestId, Data#data.server_requests) of
        {{_WireId, _Method}, Requests1} ->
            SessionId = session_store_id(Data),
            _ = beam_agent_control_core:resolve_pending_request(SessionId,
                                                           RequestId,
                                                           #{<<"resolve"
                                                               "d">> =>
                                                                 true}),
            Data#data{server_requests = Requests1};
        error ->
            Data
    end;
apply_notification_side_effects(<<"thread/closed">>, _Params, Data) ->
    SessionId = session_store_id(Data),
    _ = beam_agent_threads_core:clear_active_thread(SessionId),
    Data#data{thread_id = undefined, turn_id = undefined};
apply_notification_side_effects(_, _Params, Data) ->
    Data.
-spec build_hook_registry(map()) ->
                             beam_agent_hooks_core:hook_registry() |
                             undefined.
build_hook_registry(Opts) ->
    beam_agent_hooks_core:build_registry(maps:get(sdk_hooks, Opts, undefined)).
-spec build_mcp_registry(map()) ->
                            beam_agent_mcp_core:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    beam_agent_mcp_core:build_registry(maps:get(sdk_mcp_servers, Opts,
                                           undefined)).
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    SessionId =
        case Data#data.thread_id of
            undefined ->
                maps:get(session_id, Data#data.opts, undefined);
            ThreadId ->
                ThreadId
        end,
    #{session_id => SessionId,
      adapter => codex,
      backend => codex,
      thread_id => Data#data.thread_id,
      turn_id => Data#data.turn_id,
      server_info => Data#data.server_info,
      system_info => Data#data.server_info,
      init_response => Data#data.server_info,
      model => Data#data.model,
      approval_policy => Data#data.approval_policy,
      sandbox_mode => Data#data.sandbox_mode}.
-spec normalize_server_request_params(map() | undefined) -> map().
normalize_server_request_params(undefined) ->
    #{};
normalize_server_request_params(Params) when is_map(Params) ->
    Params.
-spec request_id_binary(binary() | integer()) -> binary().
request_id_binary(RequestId) when is_binary(RequestId) ->
    RequestId;
request_id_binary(RequestId) when is_integer(RequestId) ->
    integer_to_binary(RequestId).
-spec track_message(beam_agent_core:message(), #data{}) -> ok.
track_message(Msg, Data) ->
    SessionId = session_store_id(Data),
    ok =
        beam_agent_session_store_core:register_session(SessionId,
                                                  #{adapter => codex}),
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
session_store_id(#data{thread_id = ThreadId})
    when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
    ThreadId;
session_store_id(#data{opts = Opts}) ->
    case maps:get(session_id, Opts, undefined) of
        SessionId when is_binary(SessionId), byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(pid_to_list(self()))
    end.
-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
                              beam_agent_core:message().
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.
-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(codex, query, StartTime).
-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(codex, query, Reason).
