-module(gemini_cli_session).
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).

-export([start_link/1,
         send_query/4,
         receive_message/3,
         health/1,
         stop/1]).
-export([send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2]).
-export([callback_mode/0,
         init/1,
         terminate/3]).
-export([initializing/3,
         ready/3,
         active_query/3,
         error/3]).

-type state_name() :: initializing | ready | active_query | error.
-type pending_entry() ::
          init |
          auth |
          session_start |
          {prompt, reference()} |
          {set_mode, gen_statem:from(), binary()} |
          {set_mode_auto, binary()}.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).

-export_type([state_name/0]).

-record(data, {port :: port() | undefined,
               buffer = <<>> :: binary(),
               buffer_max :: pos_integer(),
               pending = #{} :: #{integer() => pending_entry()},
               consumer :: gen_statem:from() | undefined,
               query_ref :: reference() | undefined,
               msg_queue :: queue:queue() | undefined,
               session_id :: binary() | undefined,
               opts :: map(),
               cli_path :: string(),
               model :: binary() | undefined,
               approval_mode :: binary() | undefined,
               current_mode :: binary() | undefined,
               available_modes = [] :: [map()],
               current_model :: binary() | undefined,
               available_models = [] :: [map()],
               available_commands = [] :: [map()],
               title :: binary() | undefined,
               updated_at :: binary() | undefined,
               init_response = #{} :: map(),
               sdk_mcp_registry ::
                   beam_agent_mcp_core:mcp_registry() | undefined,
               sdk_hook_registry ::
                   beam_agent_hooks_core:hook_registry() | undefined,
               cancel_requested = false :: boolean(),
               query_start_time :: integer() | undefined}).

-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(gemini_cli_session, Opts, []).

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

-spec send_control(pid(), binary(), map()) -> {error, not_supported}.
send_control(_Pid, _Method, _Params) ->
    {error, not_supported}.

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
                             {ok, binary()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5000).

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(initializing) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath =
        maps:get(cli_path, Opts, os:getenv("GEMINI_CLI_PATH", "gemini")),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    Model = maps:get(model, Opts, undefined),
    ApprovalMode =
        normalize_cli_approval_mode(
            maps:get(approval_mode,
                     Opts,
                     maps:get(permission_mode, Opts, undefined))),
    McpRegistry = build_mcp_registry(Opts),
    HookRegistry = build_hook_registry(Opts),
    Data0 =
        #data{opts = Opts,
              cli_path = CliPath,
              buffer_max = BufferMax,
              model = Model,
              approval_mode = ApprovalMode,
              current_mode = ApprovalMode,
              sdk_mcp_registry = McpRegistry,
              sdk_hook_registry = HookRegistry,
              msg_queue = queue:new()},
    case open_port_safe(Data0) of
        {ok, Port} ->
            Data1 = send_initialize(Data0#data{port = Port}),
            {ok, initializing, Data1, [{state_timeout, 15000, init_timeout}]};
        {error, Reason} ->
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = Port} = Data) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  Data),
    maybe_clear_callbacks(Data),
    close_port(Port),
    ok.

-spec initializing(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
initializing(enter, initializing, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, undefined, initializing),
    keep_state_and_data;
initializing(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, OldState, initializing),
    keep_state_and_data;
initializing(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    process_buffer(initializing, buffer_line(Line, Data));
initializing(info, {Port, {data, {noeol, Partial}}},
             #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
initializing(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, Status}},
      {state_timeout, 60000, auto_stop}]};
initializing(info, {'EXIT', _Port, _Reason}, _Data) ->
    keep_state_and_data;
initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data, [{state_timeout, 60000, auto_stop}]};
initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};
initializing({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
initializing({call, From}, {set_model, Model}, Data) ->
    {keep_state, update_session_meta(Data#data{model = Model, current_model = Model}),
     [{reply, From, {ok, Model}}]};
initializing({call, From}, {set_permission_mode, Mode}, Data) ->
    Normalized = normalize_cli_approval_mode(Mode),
    {keep_state,
     update_session_meta(
         Data#data{approval_mode = Normalized, current_mode = Normalized}),
     [{reply, From, {ok, Normalized}}]};
initializing({call, From}, interrupt, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

-spec ready(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
ready(enter, initializing, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, initializing, ready),
    keep_state_and_data;
ready(enter, active_query, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, active_query, ready),
    keep_state_and_data;
ready(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, OldState, ready),
    keep_state_and_data;
ready(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    process_buffer(ready, buffer_line(Line, Data));
ready(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
ready(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {port_exit, Status}},
      {state_timeout, 60000, auto_stop}]};
ready(info, {'EXIT', _Port, _Reason}, _Data) ->
    keep_state_and_data;
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    HookCtx = #{event => user_prompt_submit, prompt => Prompt, params => Params},
    case fire_hook(user_prompt_submit, HookCtx, Data) of
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_send_query(From, Prompt, Params, Data)
    end;
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {set_model, Model}, Data) ->
    {keep_state, update_session_meta(Data#data{model = Model, current_model = Model}),
     [{reply, From, {ok, Model}}]};
ready({call, From}, {set_permission_mode, Mode}, Data) ->
    do_set_permission_mode(From, Mode, ready, Data);
ready({call, From}, interrupt, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
ready({call, From}, {receive_message, Ref},
      #data{query_ref = Ref, msg_queue = Q} = Data) ->
    deliver_from_ready_queue(From, Q, Data);
ready({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.

-spec active_query(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
active_query(enter, ready, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, ready, active_query),
    keep_state_and_data;
active_query(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, OldState, active_query),
    keep_state_and_data;
active_query(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    process_buffer(active_query, buffer_line(Line, Data));
active_query(info, {Port, {data, {noeol, Partial}}},
             #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};
active_query(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    maybe_span_exception(Data, {cli_exit, Status}),
    {next_state, error,
     Data#data{port = undefined, query_start_time = undefined},
     [{next_event, internal, {port_exit, Status}},
      {state_timeout, 60000, auto_stop}]};
active_query(info, {'EXIT', _Port, _Reason}, _Data) ->
    keep_state_and_data;
active_query({call, From}, {receive_message, Ref},
             #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From}, interrupt, Data) ->
    case Data#data.session_id of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
        SessionId ->
            send_json(
                beam_agent_jsonrpc:encode_notification(
                    <<"session/cancel">>,
                    beam_agent_gemini_wire:cancel_params(SessionId)),
                Data),
            {keep_state, Data#data{cancel_requested = true},
             [{reply, From, ok}]}
    end;
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
active_query({call, From}, {set_model, Model}, Data) ->
    {keep_state, update_session_meta(Data#data{model = Model, current_model = Model}),
     [{reply, From, {ok, Model}}]};
active_query({call, From}, {set_permission_mode, Mode}, Data) ->
    do_set_permission_mode(From, Mode, active_query, Data);
active_query({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.

-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(gemini, OldState, error),
    {keep_state_and_data, [{state_timeout, 60000, auto_stop}]};
error(state_timeout, auto_stop, Data) ->
    {stop, normal, Data};
error(internal, {port_exit, _Status}, Data) ->
    {keep_state, Data};
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

process_buffer(OriginalState, Data) ->
    process_buffer_loop(OriginalState, OriginalState, Data, []).

process_buffer_loop(OriginalState, CurrentState, Data, Actions) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            finalize_buffer(OriginalState, CurrentState, Data, Actions);
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    {NextState, Data2, NewActions} =
                        handle_frame(CurrentState,
                                     beam_agent_gemini_wire:decode_message(Map),
                                     Data1),
                    process_buffer_loop(OriginalState,
                                        NextState,
                                        Data2,
                                        Actions ++ NewActions);
                {error, _} ->
                    process_buffer_loop(OriginalState,
                                        CurrentState,
                                        Data1,
                                        Actions)
            end
    end.

finalize_buffer(OriginalState, FinalState, Data, Actions) ->
    case {FinalState =:= OriginalState, Actions} of
        {true, []} -> {keep_state, Data};
        {true, _} -> {keep_state, Data, Actions};
        {false, []} -> {next_state, FinalState, Data};
        {false, _} -> {next_state, FinalState, Data, Actions}
    end.

handle_frame(State, {response, Id, Result}, Data) ->
    handle_response(State, Id, normalize_map(Result), Data);
handle_frame(State, {error_response, Id, Code, Message, ErrData}, Data) ->
    handle_error_response(State, Id, Code, Message, ErrData, Data);
handle_frame(State, {notification, <<"session/update">>, Params}, Data) ->
    handle_session_update(State, normalize_map(Params), Data);
handle_frame(State, {request, Id, <<"session/request_permission">>, Params},
             Data) ->
    {State,
     handle_permission_request(Id, normalize_map(Params), Data),
     []};
handle_frame(State, {request, Id, Method, _Params}, Data) ->
    send_json(beam_agent_jsonrpc:encode_error(Id,
                                              -32601,
                                              <<"method_not_found">>,
                                              Method),
              Data),
    {State, Data, []};
handle_frame(State, _Frame, Data) ->
    {State, Data, []}.

handle_response(initializing, Id, Result, Data) ->
    case maps:take(Id, Data#data.pending) of
        {init, Pending1} ->
            InitResponse = Result,
            Data1 = Data#data{pending = Pending1, init_response = InitResponse},
            Data2 = maybe_send_auth_or_start(Data1),
            {initializing, update_session_meta(Data2), []};
        {auth, Pending1} ->
            Data1 = Data#data{pending = Pending1},
            {initializing, send_session_start(Data1), []};
        {session_start, Pending1} ->
            Data1 = apply_session_start(Result, Data#data{pending = Pending1}),
            register_ready_session(Data1),
            {ready, Data1, []};
        error ->
            {initializing, Data, []}
    end;
handle_response(ready, Id, Result, Data) ->
    handle_runtime_response(ready, Id, Result, Data);
handle_response(active_query, Id, Result, Data) ->
    handle_runtime_response(active_query, Id, Result, Data);
handle_response(error, _Id, _Result, Data) ->
    {error, Data, []}.

handle_runtime_response(State, Id, Result, Data) ->
    case maps:take(Id, Data#data.pending) of
        {{prompt, _Ref}, Pending1} ->
            Result0 =
                case Data#data.cancel_requested of
                    true -> Result#{<<"stopReason">> => <<"cancelled">>};
                    false -> Result
                end,
            Msg = beam_agent_gemini_translate:prompt_result_message(
                      session_store_id(Data), Result0),
            Data1 =
                Data#data{pending = Pending1,
                          cancel_requested = false,
                          query_start_time = undefined},
            emit_messages(ready, [Msg], Data1);
        {{set_mode, From, RequestedMode}, Pending1} ->
            Data1 =
                update_session_meta(
                    Data#data{pending = Pending1,
                              approval_mode = RequestedMode,
                              current_mode = RequestedMode}),
            {State, Data1, [{reply, From, {ok, RequestedMode}}]};
        {{set_mode_auto, RequestedMode}, Pending1} ->
            Data1 =
                update_session_meta(
                    Data#data{pending = Pending1,
                              approval_mode = RequestedMode,
                              current_mode = RequestedMode}),
            {State, Data1, []};
        error ->
            {State, Data, []}
    end.

handle_error_response(initializing, Id, _Code, _Message, _ErrData, Data) ->
    case maps:take(Id, Data#data.pending) of
        {_Entry, Pending1} ->
            {error, Data#data{pending = Pending1}, []};
        error ->
            {initializing, Data, []}
    end;
handle_error_response(State, Id, Code, Message, ErrData, Data) ->
    case maps:take(Id, Data#data.pending) of
        {{prompt, _Ref}, Pending1} ->
            maybe_span_exception(Data, {prompt_error, Code, Message}),
            Msg = rpc_error_message(Code, Message, ErrData),
            emit_messages(ready, [Msg], Data#data{pending = Pending1,
                                                  query_start_time = undefined});
        {{set_mode, From, _RequestedMode}, Pending1} ->
            {State, Data#data{pending = Pending1},
             [{reply, From, {error, {set_mode_failed, Code, Message}}}]};
        {{set_mode_auto, _RequestedMode}, Pending1} ->
            {State, Data#data{pending = Pending1}, []};
        error ->
            {State, Data, []}
    end.

handle_session_update(State, Params, Data) ->
    case beam_agent_gemini_wire:parse_session_update(Params) of
        {ok, SessionId, Kind, Update} ->
            Data1 = apply_update_meta(Kind, Update, maybe_set_session_id(SessionId, Data)),
            Messages = beam_agent_gemini_translate:session_update_messages(SessionId, Update),
            emit_messages(State, Messages, Data1);
        {error, _} ->
            {State, Data, []}
    end.

handle_permission_request(Id, Params, Data) ->
    case beam_agent_gemini_wire:parse_permission_request(Params) of
        {ok, SessionId, ToolCall, Options} ->
            Response =
                beam_agent_gemini_reverse_requests:permission_response(
                    SessionId,
                    ToolCall,
                    Options),
            send_json(beam_agent_jsonrpc:encode_response(Id, Response), Data),
            Data;
        {error, Reason} ->
            send_json(
                beam_agent_jsonrpc:encode_error(
                    Id,
                    -32602,
                    <<"invalid_permission_request">>,
                    Reason),
                Data),
            Data
    end.

do_send_query(From, Prompt, Params, Data) ->
    case Data#data.session_id of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, not_ready}}]};
        SessionId ->
            Data1 = maybe_apply_query_mode(Params, Data),
            Ref = make_ref(),
            PromptId = beam_agent_jsonrpc:next_id(),
            StartTime =
                beam_agent_telemetry_core:span_start(gemini, query,
                                                     #{prompt => Prompt}),
            Blocks = prompt_blocks(Prompt, Params),
            send_json(
                beam_agent_jsonrpc:encode_request(
                    PromptId,
                    <<"session/prompt">>,
                    beam_agent_gemini_wire:prompt_params(SessionId, Blocks)),
                Data1),
            Data2 =
                Data1#data{pending = (Data1#data.pending)#{
                                      PromptId => {prompt, Ref}
                                  },
                           query_ref = Ref,
                           msg_queue = queue:new(),
                           cancel_requested = false,
                           query_start_time = StartTime},
            {next_state, active_query, Data2, [{reply, From, {ok, Ref}}]}
    end.

do_set_permission_mode(From, Mode, _State, Data) ->
    RequestedMode = normalize_cli_approval_mode(Mode),
    case {Data#data.session_id, mode_available(RequestedMode, Data)} of
        {undefined, _} ->
            {keep_state,
             update_session_meta(
                 Data#data{approval_mode = RequestedMode,
                           current_mode = RequestedMode}),
             [{reply, From, {ok, RequestedMode}}]};
        {_SessionId, false} ->
            {keep_state,
             update_session_meta(
                 Data#data{approval_mode = RequestedMode,
                           current_mode = RequestedMode}),
             [{reply, From, {ok, RequestedMode}}]};
        {SessionId, true} ->
            Id = beam_agent_jsonrpc:next_id(),
            send_json(
                beam_agent_jsonrpc:encode_request(
                    Id,
                    <<"session/set_mode">>,
                    beam_agent_gemini_wire:set_mode_params(SessionId,
                                                           RequestedMode)),
                Data),
            {keep_state,
             Data#data{pending = (Data#data.pending)#{
                                      Id => {set_mode, From, RequestedMode}
                                  }}}
    end.

maybe_apply_query_mode(Params, Data) ->
    RequestedMode =
        normalize_cli_approval_mode(
            maps:get(approval_mode,
                     Params,
                     maps:get(permission_mode, Params, Data#data.approval_mode))),
    case {RequestedMode, RequestedMode =:= Data#data.current_mode,
          mode_available(RequestedMode, Data), Data#data.session_id} of
        {undefined, _, _, _} ->
            Data;
        {_, true, _, _} ->
            Data;
        {_, _, true, SessionId} when is_binary(SessionId) ->
            Id = beam_agent_jsonrpc:next_id(),
            send_json(
                beam_agent_jsonrpc:encode_request(
                    Id,
                    <<"session/set_mode">>,
                    beam_agent_gemini_wire:set_mode_params(SessionId,
                                                           RequestedMode)),
                Data),
            Data#data{pending = (Data#data.pending)#{
                                  Id => {set_mode_auto, RequestedMode}
                              }};
        _ ->
            update_session_meta(
                Data#data{approval_mode = RequestedMode,
                          current_mode = RequestedMode})
    end.

emit_messages(State, Messages, Data) ->
    emit_messages_loop(State, Data, Messages, []).

emit_messages_loop(State, Data, [], Actions) ->
    {State, Data, Actions};
emit_messages_loop(State, Data, [Msg | Rest], Actions) ->
    {State1, Data1, Actions1} = emit_message(State, Msg, Data),
    emit_messages_loop(State1, Data1, Rest, Actions ++ Actions1).

emit_message(State, Msg, Data) ->
    Data1 = observe_message(Msg, Data),
    Queue0 =
        case Data1#data.msg_queue of
            undefined -> queue:new();
            Q -> Q
        end,
    case Data1#data.consumer of
        undefined ->
            {State, Data1#data{msg_queue = queue:in(Msg, Queue0)}, []};
        From ->
            {State, Data1#data{consumer = undefined},
             [{reply, From, {ok, Msg}}]}
    end.

observe_message(Msg, Data) ->
    track_message(Msg, Data),
    maybe_fire_post_tool_use(Msg, Data),
    maybe_fire_stop(Msg, Data),
    maybe_span_stop_on_result(Msg, Data),
    Data.

deliver_from_ready_queue(From, undefined, Data) ->
    {keep_state, Data#data{query_ref = undefined},
     [{reply, From, {error, complete}}]};
deliver_from_ready_queue(From, Q, Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state,
             Data#data{query_ref = undefined, msg_queue = undefined},
             [{reply, From, {error, complete}}]}
    end.

try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state, Data#data{consumer = From}}
    end.

maybe_send_auth_or_start(Data) ->
    case gemini_cli_protocol:should_authenticate(Data#data.opts) of
        true ->
            Methods = maps:get(<<"authMethods">>, Data#data.init_response, []),
            Id = beam_agent_jsonrpc:next_id(),
            send_json(
                beam_agent_jsonrpc:encode_request(
                    Id,
                    <<"authenticate">>,
                    gemini_cli_protocol:authenticate_params(Data#data.opts,
                                                            Methods)),
                Data),
            Data#data{pending = (Data#data.pending)#{Id => auth}};
        false ->
            send_session_start(Data)
    end.

send_initialize(Data) ->
    Id = beam_agent_jsonrpc:next_id(),
    send_json(
        beam_agent_jsonrpc:encode_request(
            Id,
            <<"initialize">>,
            beam_agent_gemini_wire:initialize_params()),
        Data),
    Data#data{pending = (Data#data.pending)#{Id => init}}.

send_session_start(Data) ->
    Id = beam_agent_jsonrpc:next_id(),
    Method = beam_agent_gemini_wire:session_start_method(Data#data.opts),
    send_json(
        beam_agent_jsonrpc:encode_request(
            Id,
            Method,
            beam_agent_gemini_wire:session_start_params(Data#data.opts, [])),
        Data),
    Data#data{pending = (Data#data.pending)#{Id => session_start}}.

apply_session_start(Result, Data) ->
    Parsed = beam_agent_gemini_wire:parse_start_result(Result),
    SessionId = maps:get(session_id, Parsed, undefined),
    Modes = maps:get(modes, Parsed, undefined),
    Models = maps:get(models, Parsed, undefined),
    update_session_meta(
        Data#data{session_id = SessionId,
                  available_modes = extract_available_modes(Modes),
                  current_mode = extract_current_mode(Modes, Data#data.current_mode),
                  current_model = extract_current_model(Models, Data#data.model),
                  available_models = extract_available_models(Models)}).

register_ready_session(Data) ->
    SessionId = session_store_id(Data),
    ok = beam_agent_control_core:register_session_callbacks(SessionId,
                                                            Data#data.opts),
    _ = fire_hook(session_start,
                  #{event => session_start,
                    session_id => SessionId,
                    system_info => build_session_info(Data)},
                  Data),
    ok.

apply_update_meta(<<"current_mode_update">>, Update, Data) ->
    Mode = maps:get(<<"currentModeId">>, Update, Data#data.current_mode),
    update_session_meta(Data#data{current_mode = Mode, approval_mode = Mode});
apply_update_meta(<<"session_info_update">>, Update, Data) ->
    update_session_meta(
        Data#data{title = maps:get(<<"title">>, Update, Data#data.title),
                  updated_at = maps:get(<<"updatedAt">>,
                                        Update,
                                        Data#data.updated_at)});
apply_update_meta(<<"available_commands_update">>, Update, Data) ->
    update_session_meta(
        Data#data{available_commands =
                      maps:get(<<"availableCommands">>,
                               Update,
                               Data#data.available_commands)});
apply_update_meta(_Kind, _Update, Data) ->
    Data.

prompt_blocks(_Prompt, #{beam_agent_prompt_blocks := Blocks})
  when is_list(Blocks) ->
    Blocks;
prompt_blocks(Prompt, _Params) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Prompt}].

mode_available(undefined, _Data) ->
    false;
mode_available(_Mode, #data{available_modes = []}) ->
    false;
mode_available(Mode, #data{available_modes = Modes}) ->
    lists:any(fun(#{<<"id">> := Id}) when Id =:= Mode -> true;
                 (_) -> false
              end, Modes).

extract_available_modes(#{<<"availableModes">> := Modes}) when is_list(Modes) ->
    Modes;
extract_available_modes(_) ->
    [].

extract_current_mode(#{<<"currentModeId">> := Mode}, _Default) ->
    Mode;
extract_current_mode(_, Default) ->
    Default.

extract_available_models(#{<<"availableModels">> := Models})
    when is_list(Models) ->
    Models;
extract_available_models(_) ->
    [].

extract_current_model(#{<<"currentModelId">> := Model}, _Default) ->
    Model;
extract_current_model(_, Default) ->
    Default.

track_message(Msg, Data) ->
    SessionId = session_store_id(Data),
    StoredMsg = maybe_tag_session_id(Msg, SessionId),
    ok = beam_agent_session_store_core:update_session(SessionId,
                                                      session_meta(Data)),
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(SessionId,
                                                          ThreadId,
                                                          StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(SessionId, StoredMsg)
    end,
    beam_agent_events:publish(SessionId, StoredMsg),
    ok.

session_meta(Data) ->
    #{adapter => gemini,
      backend => gemini,
      transport => gemini_cli,
      cwd => session_cwd(Data#data.opts),
      model => effective_model(Data),
      extra =>
          #{approval_mode => effective_mode(Data),
            title => Data#data.title,
            updated_at => Data#data.updated_at}}.

build_session_info(Data) ->
    #{session_id => Data#data.session_id,
      model => effective_model(Data),
      approval_mode => effective_mode(Data),
      permission_mode => effective_mode(Data),
      transport => gemini_cli,
      protocol => acp,
      adapter => gemini,
      backend => gemini,
      init_response => Data#data.init_response,
      modes =>
          #{available_modes => Data#data.available_modes,
            current_mode_id => Data#data.current_mode},
      models =>
          #{available_models => Data#data.available_models,
            current_model_id => Data#data.current_model},
      title => Data#data.title,
      updated_at => Data#data.updated_at,
      system_info =>
          #{settings_file => maps:get(settings_file, Data#data.opts, undefined),
            sandbox => maps:get(sandbox, Data#data.opts, false),
            allowed_tools => maps:get(allowed_tools, Data#data.opts, []),
            allowed_mcp_server_names =>
                maps:get(allowed_mcp_server_names, Data#data.opts, []),
            extensions => maps:get(extensions, Data#data.opts, []),
            include_directories =>
                maps:get(include_directories, Data#data.opts, []),
            extra_args => maps:get(extra_args, Data#data.opts, undefined),
            work_dir => maps:get(work_dir, Data#data.opts, undefined),
            slash_commands => Data#data.available_commands,
            available_commands => Data#data.available_commands}}.

effective_model(#data{current_model = Current}) when is_binary(Current) ->
    Current;
effective_model(#data{model = Model}) ->
    Model.

effective_mode(#data{current_mode = Current}) when is_binary(Current) ->
    Current;
effective_mode(#data{approval_mode = Mode}) ->
    Mode.

session_store_id(#data{session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_Data) ->
    unicode:characters_to_binary(pid_to_list(self())).

maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.

maybe_set_session_id(SessionId, Data)
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    update_session_meta(Data#data{session_id = SessionId});
maybe_set_session_id(_SessionId, Data) ->
    Data.

update_session_meta(Data) ->
    ok = beam_agent_session_store_core:update_session(session_store_id(Data),
                                                      session_meta(Data)),
    Data.

maybe_fire_post_tool_use(#{type := tool_result} = Msg, Data) ->
    HookCtx =
        #{event => post_tool_use,
          tool_use_id => maps:get(tool_use_id, Msg, <<>>),
          content => maps:get(content, Msg, <<>>)},
    _ = fire_hook(post_tool_use, HookCtx, Data),
    ok;
maybe_fire_post_tool_use(_Msg, _Data) ->
    ok.

maybe_fire_stop(#{type := result} = Msg, Data) ->
    HookCtx =
        #{event => stop,
          stop_reason => maps:get(stop_reason, Msg, <<>>)},
    _ = fire_hook(stop, HookCtx, Data),
    ok;
maybe_fire_stop(_Msg, _Data) ->
    ok.

fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).

maybe_span_stop_on_result(#{type := result}, Data) ->
    maybe_span_stop(Data);
maybe_span_stop_on_result(_, _Data) ->
    ok.

maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(gemini, query, StartTime).

maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(gemini, query, Reason).

rpc_error_message(Code, Message, ErrData) ->
    Detail =
        case ErrData of
            undefined -> <<>>;
            _ -> iolist_to_binary(io_lib:format(" (~tp)", [ErrData]))
        end,
    #{type => error,
      content =>
          iolist_to_binary(
              io_lib:format("gemini acp error ~p: ~s~s",
                            [Code, Message, Detail])),
      raw => #{code => Code, message => Message, data => ErrData},
      timestamp => erlang:system_time(millisecond)}.

buffer_line(Line, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer =
                  check_buffer_overflow(<<Buffer/binary, Line/binary, "\n">>,
                                        Max)}.

append_buffer(Partial, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer =
                  check_buffer_overflow(<<Buffer/binary, Partial/binary>>,
                                        Max)}.

check_buffer_overflow(Buffer, BufferMax) ->
    case byte_size(Buffer) > BufferMax of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(Buffer),
                                                      BufferMax),
            logger:warning("Gemini ACP buffer overflow (~p bytes), truncating",
                           [byte_size(Buffer)]),
            <<>>;
        false ->
            Buffer
    end.

open_port_safe(Data) ->
    try
        {CliPath, PortOpts} = build_port_opts(Data#data.cli_path, Data),
        {ok, open_port({spawn_executable, CliPath}, PortOpts)}
    catch
        error:Reason ->
            {error, Reason}
    end.

build_port_opts(CliPath, Data) ->
    UserEnv = maps:get(env, Data#data.opts, []),
    Args = build_cli_args(Data),
    BaseOpts =
        [{args, Args},
         {line, 65536},
         binary, exit_status, use_stdio,
         {env,
          [{"GEMINI_CLI_SDK_VERSION", "beam-0.1.0"},
           {"NO_COLOR", "1"}] ++ UserEnv}],
    case maps:get(work_dir, Data#data.opts, undefined) of
        Dir when is_list(Dir); is_binary(Dir) ->
            {CliPath, [{cd, ensure_list(Dir)} | BaseOpts]};
        _ ->
            {CliPath, BaseOpts}
    end.

build_cli_args(Data) ->
    Base = ["--experimental-acp"],
    WithModel =
        case Data#data.model of
            undefined ->
                Base;
            Model when is_binary(Model) ->
                Base ++ ["--model", binary_to_list(Model)]
        end,
    WithApproval =
        case Data#data.approval_mode of
            undefined ->
                WithModel;
            Mode ->
                WithModel ++ ["--approval-mode", binary_to_list(Mode)]
        end,
    WithSandbox =
        case maps:get(sandbox, Data#data.opts, false) of
            true ->
                WithApproval ++ ["--sandbox"];
            _ ->
                WithApproval
        end,
    WithSettings =
        case maps:get(settings_file, Data#data.opts, undefined) of
            SettingsFile when is_binary(SettingsFile) ->
                WithSandbox
                ++
                ["--settings-file", binary_to_list(SettingsFile)];
            _ ->
                WithSandbox
        end,
    WithExtensions =
        lists:foldl(fun(Ext, Acc) when is_binary(Ext) ->
                            Acc ++ ["--extensions", binary_to_list(Ext)];
                       (_, Acc) ->
                            Acc
                    end,
                    WithSettings,
                    maps:get(extensions, Data#data.opts, [])),
    WithIncludeDirs =
        case maps:get(include_directories, Data#data.opts, []) of
            [] ->
                WithExtensions;
            Dirs when is_list(Dirs) ->
                DirBins =
                    [binary_to_list(Dir) || Dir <- Dirs, is_binary(Dir)],
                case DirBins of
                    [] ->
                        WithExtensions;
                    _ ->
                        WithExtensions
                        ++
                        ["--include-directories",
                         string:join(DirBins, ",")]
                end
        end,
    append_extra_args(WithIncludeDirs,
                      maps:get(extra_args, Data#data.opts, undefined)).

append_extra_args(Args, undefined) ->
    Args;
append_extra_args(Args, Extra) when is_list(Extra) ->
    Args ++ [ensure_list(Arg) || Arg <- Extra];
append_extra_args(Args, Extra) when is_binary(Extra) ->
    Args ++ [binary_to_list(Extra)];
append_extra_args(Args, Extra) ->
    Args ++ [ensure_list(Extra)].

send_json(Payload, #data{port = Port}) when is_port(Port) ->
    port_command(Port, Payload),
    ok;
send_json(_Payload, _Data) ->
    ok.

close_port(undefined) ->
    ok;
close_port(Port) ->
    try port_close(Port)
    catch
        error:_ ->
            ok
    end,
    ok.

build_mcp_registry(Opts) ->
    beam_agent_mcp_core:build_registry(
        maps:get(sdk_mcp_servers, Opts, undefined)).

build_hook_registry(Opts) ->
    beam_agent_hooks_core:build_registry(
        maps:get(sdk_hooks, Opts, undefined)).

maybe_clear_callbacks(#data{session_id = undefined}) ->
    ok;
maybe_clear_callbacks(#data{session_id = SessionId}) ->
    beam_agent_control_core:clear_session_callbacks(SessionId).

normalize_map(Map) when is_map(Map) ->
    Map;
normalize_map(undefined) ->
    #{};
normalize_map(_) ->
    #{}.

normalize_cli_approval_mode(undefined) ->
    undefined;
normalize_cli_approval_mode(default) ->
    <<"default">>;
normalize_cli_approval_mode(accept_edits) ->
    <<"autoEdit">>;
normalize_cli_approval_mode(bypass_permissions) ->
    <<"yolo">>;
normalize_cli_approval_mode(plan) ->
    <<"plan">>;
normalize_cli_approval_mode(dont_ask) ->
    <<"yolo">>;
normalize_cli_approval_mode(auto_edit) ->
    <<"autoEdit">>;
normalize_cli_approval_mode(yolo) ->
    <<"yolo">>;
normalize_cli_approval_mode(Value) when is_binary(Value) ->
    case Value of
        <<"default">> -> <<"default">>;
        <<"acceptEdits">> -> <<"autoEdit">>;
        <<"accept_edits">> -> <<"autoEdit">>;
        <<"auto_edit">> -> <<"autoEdit">>;
        <<"autoEdit">> -> <<"autoEdit">>;
        <<"bypassPermissions">> -> <<"yolo">>;
        <<"bypass_permissions">> -> <<"yolo">>;
        <<"yolo">> -> <<"yolo">>;
        <<"plan">> -> <<"plan">>;
        Other -> Other
    end;
normalize_cli_approval_mode(Value) when is_atom(Value) ->
    normalize_cli_approval_mode(atom_to_binary(Value, utf8));
normalize_cli_approval_mode(Value) ->
    ensure_binary(Value).

session_cwd(Opts) ->
    case maps:get(work_dir, Opts, undefined) of
        undefined ->
            case file:get_cwd() of
                {ok, Cwd} ->
                    unicode:characters_to_binary(Cwd);
                _ ->
                    <<".">>
            end;
        Dir when is_binary(Dir) ->
            Dir;
        Dir when is_list(Dir) ->
            unicode:characters_to_binary(Dir)
    end.

ensure_binary(Value) when is_binary(Value) ->
    Value;
ensure_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
ensure_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
ensure_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Value])).

ensure_list(Value) when is_list(Value) ->
    Value;
ensure_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
ensure_list(Value) when is_atom(Value) ->
    atom_to_list(Value);
ensure_list(Value) ->
    lists:flatten(io_lib:format("~tp", [Value])).
