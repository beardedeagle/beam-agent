-module(codex_session_handler).
-moduledoc """
Codex CLI session handler for the beam_agent_session_engine.

Implements `beam_agent_session_handler` callbacks to provide all
Codex-specific logic:

  - CLI subprocess launch via `beam_agent_transport_port` (line mode)
  - JSON-RPC over JSONL encoding/decoding
  - Init handshake (initialize request → response → initialized notification)
  - Thread/turn lifecycle (thread/start, turn/start, turn/completed)
  - Server request handling (approval, user input, dynamic tool calls, MCP)
  - SIGINT-based interrupt and turn/interrupt protocol message
  - SDK hook and MCP registry integration
  - Session tracking via beam_agent_session_store_core and
    beam_agent_threads_core

## Architecture

```
beam_agent_session_engine (gen_statem)
  → codex_session_handler (this module, callbacks)
    → beam_agent_transport_port (byte I/O, line mode)
```

Zero additional processes. The engine gen_statem IS the session process.
""".

-behaviour(beam_agent_session_handler).

%% Required callbacks
-export([
    backend_name/0,
    init_handler/1,
    handle_data/2,
    encode_query/3,
    build_session_info/1,
    terminate_handler/2
]).

%% Optional callbacks
-export([
    transport_started/2,
    handle_initializing/2,
    encode_interrupt/1,
    handle_control/4,
    on_state_enter/3,
    is_query_complete/2,
    handle_custom_call/3
]).

%%--------------------------------------------------------------------
%% Handler state
%%--------------------------------------------------------------------

-record(hstate, {
    %% Transport ref (stored via transport_started/2 for SIGINT)
    port_ref            :: port() | undefined,

    %% Pending JSON-RPC requests: Id => {From, TimerRef} | init |
    %%                                   turn_start |
    %%                                   {thread_then_turn, Prompt, Opts}
    pending = #{}       :: #{integer() => term()},

    %% Thread/turn identity
    thread_id           :: binary() | undefined,
    turn_id             :: binary() | undefined,

    %% Server info from initialize response
    server_info = #{}   :: map(),

    %% Pending server requests (approval, user input, etc.)
    %% RequestIdBin => {WireId, Method}
    server_requests = #{} :: #{binary() => {integer(), binary()}},

    %% Session configuration
    session_id          :: binary() | undefined,
    opts                :: map(),
    cli_path            :: string(),
    model               :: binary() | undefined,
    approval_policy     :: binary() | undefined,
    sandbox_mode        :: binary() | undefined,

    %% Permission & input handlers
    approval_handler    :: fun((binary(), map(), map()) ->
                               codex_protocol:approval_decision()) | undefined,
    user_input_handler  :: fun((map(), map()) ->
                               {ok, map()} | {error, term()}) | undefined,

    %% SDK registries
    sdk_hook_registry   :: beam_agent_hooks_core:hook_registry() | undefined,
    sdk_mcp_registry    :: beam_agent_mcp_core:mcp_registry() | undefined
}).

-dialyzer({no_underspecs, [
    build_approval_response/2,
    put_new/3,
    safe_user_input_response/3,
    dynamic_tool_call_response/1,
    dynamic_tool_content_item/1
]}).
-dialyzer({nowarn_function, [{call_approval_handler, 3}]}).

%%====================================================================
%% Required callbacks
%%====================================================================

-doc "Return the backend identifier atom.".
-spec backend_name() -> codex.
backend_name() -> codex.

-doc """
Initialize the handler.

Builds transport spec for `beam_agent_transport_port` with `mode => line`,
constructs CLI args, and initializes hook/MCP registries.
""".
-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    CliPath = maps:get(cli_path, Opts,
                       os:getenv("CODEX_CLI_PATH", "codex")),
    SessionId = maps:get(session_id, Opts, undefined),
    Model = maps:get(model, Opts, undefined),
    ApprovalPolicy = encode_approval_policy(
                         maps:get(approval_policy, Opts, undefined)),
    SandboxMode = encode_sandbox_mode(
                      maps:get(sandbox_mode, Opts, undefined)),
    ApprovalHandler = maps:get(approval_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    HookRegistry = beam_agent_hooks_core:build_registry(
                       maps:get(sdk_hooks, Opts, undefined)),
    McpRegistry = beam_agent_mcp_core:build_registry(
                      maps:get(sdk_mcp_servers, Opts, undefined)),
    TransportOpts = #{
        executable  => CliPath,
        args        => ["--app-server"],
        env         => [{"CODEX_SDK_VERSION", "0.1.0"}
                        | maps:get(env, Opts, [])],
        cd          => maps:get(work_dir, Opts, undefined),
        mode        => line,
        line_buffer => 65536
    },
    HState = #hstate{
        session_id       = SessionId,
        cli_path         = CliPath,
        opts             = Opts,
        model            = Model,
        approval_policy  = ApprovalPolicy,
        sandbox_mode     = SandboxMode,
        approval_handler = ApprovalHandler,
        user_input_handler = UserInputHandler,
        sdk_hook_registry  = HookRegistry,
        sdk_mcp_registry   = McpRegistry
    },
    {ok, #{
        transport_spec => {beam_agent_transport_port, TransportOpts},
        initial_state  => initializing,
        handler_state  => HState
    }}.

-doc """
Decode incoming transport data into normalized messages.

Extracts JSONL lines from buffer, decodes JSON-RPC messages, handles
responses/requests/notifications, and returns deliverable messages.
""".
-spec handle_data(binary(), #hstate{}) ->
    beam_agent_session_handler:data_result().
handle_data(Buffer, HState) ->
    extract_messages(Buffer, HState, [], []).

-doc """
Encode a query for the Codex backend.

Fires the `user_prompt_submit` hook, then encodes either a
`thread/start` + `turn/start` pair (new thread) or just `turn/start`
(existing thread) as JSON-RPC requests.
""".
-spec encode_query(binary(), beam_agent_core:query_opts(), #hstate{}) ->
    {ok, iodata(), #hstate{}} | {error, term()}.
encode_query(Prompt, Params,
             #hstate{sdk_hook_registry = HookReg,
                     session_id = SessionId} = HState) ->
    HookCtx = #{event => user_prompt_submit,
                prompt => Prompt,
                params => Params,
                session_id => SessionId},
    case beam_agent_hooks_core:fire(user_prompt_submit, HookCtx, HookReg) of
        {deny, Reason} ->
            {error, {hook_denied, Reason}};
        ok ->
            do_encode_query(Prompt, Params, HState)
    end.

-doc "Build the handler's contribution to session_info.".
-spec build_session_info(#hstate{}) -> map().
build_session_info(#hstate{thread_id = ThreadId,
                            turn_id = TurnId,
                            server_info = ServerInfo,
                            model = Model,
                            approval_policy = ApprovalPolicy,
                            sandbox_mode = SandboxMode}) ->
    #{adapter => codex,
      thread_id => ThreadId,
      turn_id => TurnId,
      server_info => ServerInfo,
      system_info => ServerInfo,
      init_response => ServerInfo,
      model => Model,
      approval_policy => ApprovalPolicy,
      sandbox_mode => SandboxMode}.

-doc "Clean up handler resources on termination.".
-spec terminate_handler(term(), #hstate{}) -> ok.
terminate_handler(Reason, #hstate{sdk_hook_registry = HookReg,
                                   session_id = SessionId}) ->
    _ = beam_agent_hooks_core:fire(session_end,
            #{event => session_end,
              session_id => SessionId,
              reason => Reason},
            HookReg),
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-doc "Store the transport ref for SIGINT delivery.".
-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started(TRef, HState) ->
    HState#hstate{port_ref = TRef}.

-doc """
Handle transport events during the initializing phase.

Processes the init handshake: extracts JSONL lines from the buffer,
waits for the initialize response, then sends the `initialized`
notification and transitions to `ready`.
""".
-spec handle_initializing(beam_agent_session_handler:transport_event(),
                          #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_initializing({data, RawData}, HState) ->
    process_initializing_data(RawData, HState);
handle_initializing(init_timeout, HState) ->
    {error_state, {timeout, initializing}, HState};
handle_initializing({exit, Status}, HState) ->
    {error_state, {cli_exit_during_init, Status}, HState};
handle_initializing(_Event, HState) ->
    {keep_state, [], HState}.

-doc """
Encode an interrupt signal.

Sends a `turn/interrupt` JSON-RPC request if there is an active turn.
Also sends SIGINT to the port process for immediate effect.
""".
-spec encode_interrupt(#hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} |
    not_supported.
encode_interrupt(#hstate{turn_id = undefined}) ->
    not_supported;
encode_interrupt(#hstate{port_ref = Port} = HState)
  when Port =/= undefined ->
    Id = beam_agent_jsonrpc:next_id(),
    Params = #{<<"turnId">> => HState#hstate.turn_id},
    Encoded = beam_agent_jsonrpc:encode_request(Id,
                                                 <<"turn/interrupt">>,
                                                 Params),
    send_sigint(Port),
    {ok, [{send, Encoded}], HState};
encode_interrupt(_HState) ->
    not_supported.

-doc """
Handle `send_control/3` calls.

Encodes the control method as a JSON-RPC request, stores the pending
caller for deferred reply when the response arrives.
""".
-spec handle_control(binary(), map(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
handle_control(Method, Params, From,
               #hstate{pending = Pending} = HState) ->
    Id = beam_agent_jsonrpc:next_id(),
    Encoded = beam_agent_jsonrpc:encode_request(Id, Method, Params),
    TimerRef = erlang:send_after(35000, self(), {pending_timeout, Id}),
    Pending1 = Pending#{Id => {From, TimerRef}},
    {noreply, [{send, Encoded}], HState#hstate{pending = Pending1}}.

-doc """
Fire lifecycle hooks on state transitions.

Fires `session_start` hook on transition to `ready`.
""".
-spec on_state_enter(beam_agent_session_handler:state_name(),
                     beam_agent_session_handler:state_name() | undefined,
                     #hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}}.
on_state_enter(initializing, _OldState, HState) ->
    %% Send initialize request when entering initializing
    Id = beam_agent_jsonrpc:next_id(),
    InitParams = codex_protocol:initialize_params(HState#hstate.opts),
    Encoded = beam_agent_jsonrpc:encode_request(Id,
                                                 <<"initialize">>,
                                                 InitParams),
    Pending = (HState#hstate.pending)#{Id => init},
    {ok, [{send, Encoded}], HState#hstate{pending = Pending}};
on_state_enter(ready, _OldState,
               #hstate{sdk_hook_registry = HookReg,
                       session_id = SessionId,
                       server_info = ServerInfo} = HState) ->
    _ = beam_agent_hooks_core:fire(session_start,
            #{event => session_start,
              session_id => SessionId,
              system_info => ServerInfo},
            HookReg),
    {ok, [], HState};
on_state_enter(_State, _OldState, HState) ->
    {ok, [], HState}.

-doc "Detect whether a message signals query completion.".
-spec is_query_complete(beam_agent_core:message(), #hstate{}) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(_Msg, _HState) -> false.

-doc """
Handle `respond_request` calls (Codex-specific).

Looks up the server request by ID, builds the appropriate response,
and sends it back to the CLI.
""".
-spec handle_custom_call(term(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
handle_custom_call({respond_request, RequestId, Params}, _From, HState) ->
    do_respond_request(RequestId, Params, HState);
handle_custom_call(_Request, _From, _HState) ->
    {error, unsupported}.

%%====================================================================
%% Internal: initializing handshake
%%====================================================================

-spec process_initializing_data(binary(), #hstate{}) ->
    beam_agent_session_handler:phase_result().
process_initializing_data(RawData, HState) ->
    %% The engine passes combined buffer + new data. We extract JSONL
    %% lines and look for the initialize response.
    process_init_buffer(RawData, HState).

-spec process_init_buffer(binary(), #hstate{}) ->
    beam_agent_session_handler:phase_result().
process_init_buffer(Buffer, HState) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {keep_state, [], HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_init_message(
                        beam_agent_jsonrpc:decode(Map), Rest, HState);
                {error, _} ->
                    process_init_buffer(Rest, HState)
            end
    end.

-spec handle_init_message(beam_agent_jsonrpc:jsonrpc_msg(), binary(),
                          #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_init_message({response, Id, Result}, Rest, HState) ->
    case maps:find(Id, HState#hstate.pending) of
        {ok, init} ->
            Pending1 = maps:remove(Id, HState#hstate.pending),
            HState1 = HState#hstate{pending = Pending1,
                                     server_info = Result},
            %% Send initialized notification
            InitializedMsg = beam_agent_jsonrpc:encode_notification(
                                 <<"initialized">>, undefined),
            %% Transition to ready, pass leftover buffer to engine
            {next_state, ready, [{send, InitializedMsg}], HState1, Rest};
        _ ->
            process_init_buffer(Rest, HState)
    end;
handle_init_message({error_response, Id, _Code, Msg, _ErrData},
                    _Rest, HState) ->
    Pending1 = maps:remove(Id, HState#hstate.pending),
    logger:error("Codex initialize failed: ~s", [Msg]),
    {error_state, {init_failed, Msg}, HState#hstate{pending = Pending1}};
handle_init_message(_Other, Rest, HState) ->
    process_init_buffer(Rest, HState).

%%====================================================================
%% Internal: message extraction (handle_data)
%%====================================================================

-spec extract_messages(binary(), #hstate{},
                       [beam_agent_core:message()],
                       [beam_agent_session_handler:handler_action()]) ->
    beam_agent_session_handler:data_result().
extract_messages(Buffer, HState, MsgsAcc, ActionsAcc) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {ok, lists:reverse(MsgsAcc), Buffer,
             lists:reverse(ActionsAcc), HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    classify_and_handle(
                        beam_agent_jsonrpc:decode(Map), Map, Rest,
                        HState, MsgsAcc, ActionsAcc);
                {error, _} ->
                    extract_messages(Rest, HState, MsgsAcc, ActionsAcc)
            end
    end.

-spec classify_and_handle(beam_agent_jsonrpc:jsonrpc_msg(), map(), binary(),
                          #hstate{},
                          [beam_agent_core:message()],
                          [beam_agent_session_handler:handler_action()]) ->
    beam_agent_session_handler:data_result().
classify_and_handle({notification, Method, Params}, _Raw, Rest,
                    HState, MsgsAcc, ActionsAcc) ->
    SafeParams = safe_params(Params),
    HState1 = apply_notification_side_effects(Method, SafeParams, HState),
    Msg = codex_protocol:normalize_notification(Method, SafeParams),
    HState2 = fire_notification_hooks(Method, SafeParams, Msg, HState1),
    _ = track_message(Msg, HState2),
    extract_messages(Rest, HState2, [Msg | MsgsAcc], ActionsAcc);
classify_and_handle({request, Id, Method, Params}, _Raw, Rest,
                    HState, MsgsAcc, ActionsAcc) ->
    {HState1, NewActions, NewMsgs} =
        handle_server_request(Id, Method, Params, HState),
    extract_messages(Rest, HState1,
                     NewMsgs ++ MsgsAcc,
                     NewActions ++ ActionsAcc);
classify_and_handle({response, Id, Result}, _Raw, Rest,
                    HState, MsgsAcc, ActionsAcc) ->
    {HState1, NewActions, NewMsgs} =
        handle_response(Id, Result, HState),
    extract_messages(Rest, HState1,
                     NewMsgs ++ MsgsAcc,
                     NewActions ++ ActionsAcc);
classify_and_handle({error_response, Id, _Code, Msg, _ErrData}, _Raw, Rest,
                    HState, MsgsAcc, ActionsAcc) ->
    {HState1, NewActions, NewMsgs} =
        handle_error_response(Id, Msg, HState),
    extract_messages(Rest, HState1,
                     NewMsgs ++ MsgsAcc,
                     NewActions ++ ActionsAcc);
classify_and_handle(_Other, _Raw, Rest, HState, MsgsAcc, ActionsAcc) ->
    extract_messages(Rest, HState, MsgsAcc, ActionsAcc).

%%====================================================================
%% Internal: response handling
%%====================================================================

-spec handle_response(integer(), term(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
handle_response(Id, Result, #hstate{pending = Pending} = HState) ->
    case maps:find(Id, Pending) of
        {ok, {thread_then_turn, Prompt, Opts}} ->
            %% thread/start succeeded — now send turn/start
            Pending1 = maps:remove(Id, Pending),
            ThreadId = maps:get(<<"threadId">>, Result, undefined),
            HState1 = HState#hstate{pending = Pending1,
                                     thread_id = ThreadId},
            TurnReqId = beam_agent_jsonrpc:next_id(),
            TurnParams = codex_protocol:turn_start_params(
                             ThreadId, Prompt, Opts),
            Encoded = beam_agent_jsonrpc:encode_request(
                          TurnReqId, <<"turn/start">>, TurnParams),
            HState2 = HState1#hstate{
                pending = (HState1#hstate.pending)#{
                    TurnReqId => turn_start}},
            {HState2, [{send, Encoded}], []};
        {ok, turn_start} ->
            Pending1 = maps:remove(Id, Pending),
            ThreadId = maps:get(<<"threadId">>, Result,
                                HState#hstate.thread_id),
            TurnId = maps:get(<<"turnId">>, Result,
                              HState#hstate.turn_id),
            HState1 = HState#hstate{pending = Pending1,
                                     thread_id = ThreadId,
                                     turn_id = TurnId},
            {HState1, [], []};
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Pending),
            ThreadId = maps:get(<<"threadId">>, Result,
                                HState#hstate.thread_id),
            TurnId = maps:get(<<"turnId">>, Result,
                              HState#hstate.turn_id),
            HState1 = HState#hstate{pending = Pending1,
                                     thread_id = ThreadId,
                                     turn_id = TurnId},
            gen_statem:reply(From, {ok, Result}),
            {HState1, [], []};
        _ ->
            {HState, [], []}
    end.

-spec handle_error_response(integer(), binary(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
handle_error_response(Id, Msg, #hstate{pending = Pending} = HState) ->
    case maps:find(Id, Pending) of
        {ok, {thread_then_turn, _Prompt, _Opts}} ->
            Pending1 = maps:remove(Id, Pending),
            ErrorMsg = #{type => error,
                         content => Msg,
                         timestamp => erlang:system_time(millisecond)},
            HState1 = HState#hstate{pending = Pending1},
            _ = track_message(ErrorMsg, HState1),
            {HState1, [], [ErrorMsg]};
        {ok, turn_start} ->
            Pending1 = maps:remove(Id, Pending),
            ErrorMsg = #{type => error,
                         content => Msg,
                         timestamp => erlang:system_time(millisecond)},
            HState1 = HState#hstate{pending = Pending1},
            _ = track_message(ErrorMsg, HState1),
            {HState1, [], [ErrorMsg]};
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Pending),
            gen_statem:reply(From, {error, Msg}),
            {HState#hstate{pending = Pending1}, [], []};
        _ ->
            {HState, [], []}
    end.

%%====================================================================
%% Internal: query encoding
%%====================================================================

-spec do_encode_query(binary(), map(), #hstate{}) ->
    {ok, iodata(), #hstate{}} | {error, term()}.
do_encode_query(Prompt, Params, HState) ->
    MergedOpts = merge_turn_opts(Params, HState),
    case HState#hstate.thread_id of
        undefined ->
            encode_create_thread_and_turn(Prompt, MergedOpts, HState);
        ThreadId ->
            encode_start_turn(ThreadId, Prompt, MergedOpts, HState)
    end.

-spec encode_create_thread_and_turn(binary(), map(), #hstate{}) ->
    {ok, iodata(), #hstate{}}.
encode_create_thread_and_turn(Prompt, Opts, HState) ->
    ThreadReqId = beam_agent_jsonrpc:next_id(),
    ThreadParams = codex_protocol:thread_start_params(Opts),
    ThreadEncoded = beam_agent_jsonrpc:encode_request(
                        ThreadReqId, <<"thread/start">>, ThreadParams),
    Pending = (HState#hstate.pending)#{
        ThreadReqId => {thread_then_turn, Prompt, Opts}},
    {ok, ThreadEncoded, HState#hstate{pending = Pending}}.

-spec encode_start_turn(binary(), binary(), map(), #hstate{}) ->
    {ok, iodata(), #hstate{}}.
encode_start_turn(ThreadId, Prompt, Opts, HState) ->
    Id = beam_agent_jsonrpc:next_id(),
    TurnParams = codex_protocol:turn_start_params(ThreadId, Prompt, Opts),
    Encoded = beam_agent_jsonrpc:encode_request(Id, <<"turn/start">>,
                                                 TurnParams),
    Pending = (HState#hstate.pending)#{Id => turn_start},
    {ok, Encoded, HState#hstate{pending = Pending}}.

-spec merge_turn_opts(map(), #hstate{}) -> map().
merge_turn_opts(Params, HState) ->
    M0 = Params,
    M1 = case HState#hstate.model of
        undefined -> M0;
        Model     -> put_new(model, Model, M0)
    end,
    M2 = case HState#hstate.approval_policy of
        undefined -> M1;
        AP        -> put_new(approval_policy, AP, M1)
    end,
    case HState#hstate.sandbox_mode of
        undefined -> M2;
        SM        -> put_new(sandbox_mode, SM, M2)
    end.

%%====================================================================
%% Internal: respond_request (custom call)
%%====================================================================

-spec do_respond_request(binary() | integer(), map(), #hstate{}) ->
    beam_agent_session_handler:control_result().
do_respond_request(RequestId, Params, HState) ->
    RequestIdBin = request_id_binary(RequestId),
    case maps:find(RequestIdBin, HState#hstate.server_requests) of
        {ok, {WireId, Method}} ->
            ResponseMap = build_request_response(Method, Params),
            Encoded = beam_agent_jsonrpc:encode_response(WireId, ResponseMap),
            SessionId = session_store_id(HState),
            _ = beam_agent_control_core:resolve_pending_request(
                    SessionId, RequestIdBin, ResponseMap),
            Requests1 = maps:remove(RequestIdBin,
                                     HState#hstate.server_requests),
            HState1 = HState#hstate{server_requests = Requests1},
            {reply, ResponseMap, [{send, Encoded}], HState1};
        error ->
            {error, not_found}
    end.

-spec build_request_response(binary(), map()) -> map().
build_request_response(<<"item/tool/requestUserInput">>, Params) ->
    codex_protocol:request_user_input_response(Params);
build_request_response(_Method, Params) ->
    Params.

%%====================================================================
%% Internal: server request handling
%%====================================================================

-spec handle_server_request(integer(), binary(), map() | undefined,
                            #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
handle_server_request(Id, <<"mcp/message">>, Params,
                      #hstate{sdk_mcp_registry = Registry} = HState)
  when is_map(Registry) ->
    SafeParams = safe_params(Params),
    ServerName = maps:get(<<"server_name">>, SafeParams, <<>>),
    Message = maps:get(<<"message">>, SafeParams, #{}),
    Action = case beam_agent_mcp_core:handle_mcp_message(
                      ServerName, Message, Registry) of
        {ok, McpResponse} ->
            [{send, beam_agent_jsonrpc:encode_response(Id, McpResponse)}];
        {error, ErrMsg} ->
            ErrResponse = #{<<"error">> => ErrMsg},
            [{send, beam_agent_jsonrpc:encode_response(Id, ErrResponse)}]
    end,
    {HState, Action, []};
handle_server_request(Id, <<"item/tool/requestUserInput">>, Params,
                      HState) ->
    handle_user_input_request(Id, safe_params(Params), HState);
handle_server_request(Id, <<"item/tool/call">>, Params, HState) ->
    handle_dynamic_tool_call_request(Id, safe_params(Params), HState);
handle_server_request(Id, <<"account/chatgptAuthTokens/refresh">>,
                      Params, HState) ->
    RequestId = integer_to_binary(Id),
    Request = #{method => <<"account/chatgptAuthTokens/refresh">>,
                params => safe_params(Params),
                kind => auth_refresh},
    queue_pending_server_request(Id, RequestId, Request, HState);
handle_server_request(Id, Method, Params, HState) ->
    SafeParams = safe_params(Params),
    HookCtx = #{event => pre_tool_use,
                tool_name => Method,
                tool_input => SafeParams},
    case fire_hook(pre_tool_use, HookCtx, HState) of
        {deny, _Reason} ->
            ResponseMap = #{<<"decision">> => <<"decline">>},
            Action = [{send, beam_agent_jsonrpc:encode_response(
                                 Id, ResponseMap)}],
            {HState, Action, []};
        ok ->
            Decision = call_approval_handler(Method, SafeParams, HState),
            ResponseMap = build_approval_response(Method, Decision),
            Action = [{send, beam_agent_jsonrpc:encode_response(
                                 Id, ResponseMap)}],
            {HState, Action, []}
    end.

%%====================================================================
%% Internal: approval handling
%%====================================================================

-spec call_approval_handler(binary(), map(), #hstate{}) ->
    codex_protocol:approval_decision().
call_approval_handler(_Method, _Params,
                      #hstate{approval_handler = undefined,
                              opts = Opts}) ->
    case maps:get(permission_default, Opts, deny) of
        allow -> accept;
        _     -> decline
    end;
call_approval_handler(Method, Params,
                      #hstate{approval_handler = Handler}) ->
    try Handler(Method, Params, #{}) of
        Decision when is_atom(Decision) -> Decision;
        _                               -> accept
    catch
        _:_ -> decline
    end.

-spec build_approval_response(binary(),
                              codex_protocol:approval_decision()) -> map().
build_approval_response(<<"item/commandExecution/requestApproval">>,
                        Decision) ->
    codex_protocol:command_approval_response(Decision);
build_approval_response(<<"item/fileChange/requestApproval">>, Decision) ->
    codex_protocol:file_approval_response(Decision);
build_approval_response(_, Decision) ->
    codex_protocol:command_approval_response(Decision).

%%====================================================================
%% Internal: user input request handling
%%====================================================================

-spec handle_user_input_request(integer(), map(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
handle_user_input_request(Id, Params,
                          #hstate{user_input_handler = Handler} = HState)
  when is_function(Handler, 2) ->
    RequestId = integer_to_binary(Id),
    SessionId = session_store_id(HState),
    Request = #{method => <<"item/tool/requestUserInput">>,
                params => Params,
                kind => user_input},
    ok = beam_agent_control_core:store_pending_request(
             SessionId, RequestId, Request),
    Ctx = #{session_id => SessionId,
            thread_id => HState#hstate.thread_id,
            turn_id => HState#hstate.turn_id},
    case safe_user_input_response(Handler, Params, Ctx) of
        {ok, ResponseMap} ->
            Action = [{send, beam_agent_jsonrpc:encode_response(
                                 Id, ResponseMap)}],
            _ = beam_agent_control_core:resolve_pending_request(
                    SessionId, RequestId, ResponseMap),
            {HState, Action, []};
        {error, _Reason} ->
            queue_pending_server_request(Id, RequestId, Request, HState)
    end;
handle_user_input_request(Id, Params, HState) ->
    RequestId = integer_to_binary(Id),
    Request = #{method => <<"item/tool/requestUserInput">>,
                params => Params,
                kind => user_input},
    queue_pending_server_request(Id, RequestId, Request, HState).

%%====================================================================
%% Internal: dynamic tool call handling
%%====================================================================

-spec handle_dynamic_tool_call_request(integer(), map(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
handle_dynamic_tool_call_request(Id, Params,
                                 #hstate{sdk_mcp_registry = Registry} =
                                     HState)
  when is_map(Registry) ->
    ToolName = maps:get(<<"tool">>, Params, <<>>),
    Arguments = normalize_dynamic_tool_arguments(
                    maps:get(<<"arguments">>, Params, #{})),
    case beam_agent_mcp_core:call_tool_by_name(
             ToolName, Arguments, Registry) of
        {ok, ContentItems} ->
            ResponseMap = dynamic_tool_call_response(ContentItems),
            Action = [{send, beam_agent_jsonrpc:encode_response(
                                 Id, ResponseMap)}],
            {HState, Action, []};
        {error, _Reason} ->
            queue_dynamic_tool_call(Id, Params, HState)
    end;
handle_dynamic_tool_call_request(Id, Params, HState) ->
    queue_dynamic_tool_call(Id, Params, HState).

-spec queue_dynamic_tool_call(integer(), map(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
queue_dynamic_tool_call(Id, Params, HState) ->
    RequestId = integer_to_binary(Id),
    Request = #{method => <<"item/tool/call">>,
                params => Params,
                kind => dynamic_tool_call},
    queue_pending_server_request(Id, RequestId, Request, HState).

%%====================================================================
%% Internal: pending server request queue
%%====================================================================

-spec queue_pending_server_request(integer(), binary(), map(), #hstate{}) ->
    {#hstate{}, [beam_agent_session_handler:handler_action()],
     [beam_agent_core:message()]}.
queue_pending_server_request(Id, RequestId, Request, HState) ->
    SessionId = session_store_id(HState),
    ok = beam_agent_control_core:store_pending_request(
             SessionId, RequestId, Request),
    Msg = #{type => control_request,
            request_id => RequestId,
            request => Request,
            subtype => request_subtype(Request),
            timestamp => erlang:system_time(millisecond)},
    ServerRequests = (HState#hstate.server_requests)#{
        RequestId => {Id, maps:get(method, Request)}},
    HState1 = HState#hstate{server_requests = ServerRequests},
    _ = track_message(Msg, HState1),
    {HState1, [], [Msg]}.

-spec request_subtype(map()) -> binary().
request_subtype(#{kind := user_input}) -> <<"user_input">>;
request_subtype(#{kind := dynamic_tool_call}) -> <<"dynamic_tool_call">>;
request_subtype(#{kind := auth_refresh}) -> <<"auth_refresh">>.

%%====================================================================
%% Internal: notification side effects
%%====================================================================

-spec apply_notification_side_effects(binary(), map(), #hstate{}) ->
    #hstate{}.
apply_notification_side_effects(<<"serverRequest/resolved">>,
                                Params, HState) ->
    RequestId = request_id_binary(
                    maps:get(<<"requestId">>,
                             Params,
                             maps:get(requestId, Params, <<>>))),
    case maps:take(RequestId, HState#hstate.server_requests) of
        {{_WireId, _Method}, Requests1} ->
            SessionId = session_store_id(HState),
            _ = beam_agent_control_core:resolve_pending_request(
                    SessionId, RequestId, #{<<"resolved">> => true}),
            HState#hstate{server_requests = Requests1};
        error ->
            HState
    end;
apply_notification_side_effects(<<"thread/closed">>, _Params, HState) ->
    SessionId = session_store_id(HState),
    _ = beam_agent_threads_core:clear_active_thread(SessionId),
    HState#hstate{thread_id = undefined, turn_id = undefined};
apply_notification_side_effects(_, _Params, HState) ->
    HState.

%%====================================================================
%% Internal: notification hooks
%%====================================================================

-spec fire_notification_hooks(binary(), map(),
                              beam_agent_core:message(), #hstate{}) ->
    #hstate{}.
fire_notification_hooks(<<"item/completed">>, Params, _Msg, HState) ->
    Item = maps:get(<<"item">>, Params, #{}),
    ToolName = maps:get(<<"command">>, Item,
                        maps:get(<<"filePath">>, Item, <<>>)),
    _ = fire_hook(post_tool_use,
                  #{event => post_tool_use,
                    tool_name => ToolName,
                    content => maps:get(<<"output">>, Item, <<>>)},
                  HState),
    HState;
fire_notification_hooks(<<"turn/completed">>, Params, _Msg, HState) ->
    _ = fire_hook(stop,
                  #{event => stop,
                    stop_reason =>
                        maps:get(<<"status">>, Params, <<>>)},
                  HState),
    HState;
fire_notification_hooks(_, _, _, HState) ->
    HState.

%%====================================================================
%% Internal: hook firing
%%====================================================================

-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(),
                #hstate{}) ->
    ok | {deny, binary()}.
fire_hook(Event, Context, #hstate{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).

%%====================================================================
%% Internal: message tracking
%%====================================================================

-spec track_message(beam_agent_core:message(), #hstate{}) -> ok.
track_message(Msg, HState) ->
    SessionId = session_store_id(HState),
    ok = beam_agent_session_store_core:register_session(
             SessionId, #{adapter => codex}),
    StoredMsg = maybe_tag_session_id(Msg, SessionId),
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(
                SessionId, ThreadId, StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(
                SessionId, StoredMsg)
    end,
    ok.

-spec session_store_id(#hstate{}) -> binary().
session_store_id(#hstate{thread_id = ThreadId})
  when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
    ThreadId;
session_store_id(#hstate{session_id = SessionId})
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_) ->
    unicode:characters_to_binary(pid_to_list(self())).

-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
    beam_agent_core:message().
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.

%%====================================================================
%% Internal: transport helpers
%%====================================================================

-spec send_sigint(port()) -> ok.
send_sigint(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill -INT " ++ integer_to_list(OsPid)),
            ok;
        undefined ->
            ok
    end.

%%====================================================================
%% Internal: utility helpers
%%====================================================================

-spec safe_params(map() | undefined) -> map().
safe_params(undefined) -> #{};
safe_params(Params) when is_map(Params) -> Params.

-spec put_new(term(), term(), map()) -> map().
put_new(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true  -> Map;
        false -> Map#{Key => Value}
    end.

-spec request_id_binary(binary() | integer()) -> binary().
request_id_binary(RequestId) when is_binary(RequestId) -> RequestId;
request_id_binary(RequestId) when is_integer(RequestId) ->
    integer_to_binary(RequestId).

-spec safe_user_input_response(fun((map(), map()) ->
                                       {ok, map()} | {error, term()}),
                               map(), map()) ->
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

-spec normalize_dynamic_tool_arguments(term()) -> map().
normalize_dynamic_tool_arguments(Args) when is_map(Args) -> Args;
normalize_dynamic_tool_arguments(_) -> #{}.

-spec dynamic_tool_call_response([beam_agent_mcp_core:content_result()]) ->
    map().
dynamic_tool_call_response(ContentItems) ->
    #{<<"success">> => true,
      <<"contentItems">> =>
          [dynamic_tool_content_item(Item) || Item <- ContentItems]}.

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

-spec encode_approval_policy(atom() | binary() | undefined) ->
    binary() | undefined.
encode_approval_policy(undefined) -> undefined;
encode_approval_policy(AP) when is_atom(AP) ->
    codex_protocol:encode_ask_for_approval(AP);
encode_approval_policy(AP) when is_binary(AP) -> AP.

-spec encode_sandbox_mode(atom() | binary() | undefined) ->
    binary() | undefined.
encode_sandbox_mode(undefined) -> undefined;
encode_sandbox_mode(SM) when is_atom(SM) ->
    codex_protocol:encode_sandbox_mode(SM);
encode_sandbox_mode(SM) when is_binary(SM) -> SM.
