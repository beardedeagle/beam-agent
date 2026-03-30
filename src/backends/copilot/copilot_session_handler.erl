-module(copilot_session_handler).
-moduledoc false.

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
    handle_connecting/2,
    handle_initializing/2,
    encode_interrupt/1,
    handle_control/4,
    redact_handler_state/1,
    handle_set_model/2,
    handle_set_permission_mode/2,
    on_state_enter/3,
    is_query_complete/2
]).

%%--------------------------------------------------------------------
%% Handler state
%%--------------------------------------------------------------------

-record(hstate, {
    %% Transport ref (stored via transport_started/2)
    port_ref              :: port() | undefined,

    %% Pending JSON-RPC responses: RequestId => {From | internal | internal_create | internal_resume, TimerRef}
    pending = #{}         :: #{binary() =>
                                {gen_statem:from() |
                                 internal | internal_create | internal_resume,
                                 reference() | undefined}},

    %% Monotonic request ID counter
    next_id = 1           :: pos_integer(),

    %% Session identity
    session_id            :: binary() | undefined,
    copilot_session_id    :: binary() | undefined,

    %% Configuration
    opts                  :: map(),
    cli_path              :: string(),
    model                 :: binary() | undefined,

    %% SDK registries
    sdk_mcp_registry      :: beam_agent_tool_registry:mcp_registry() | undefined,
    sdk_hook_registry     :: beam_agent_hooks_core:hook_registry() | undefined,

    %% Permission & input handlers
    permission_handler    :: fun() | undefined,
    user_input_handler    :: fun() | undefined,

    %% Init-phase buffer for accumulating partial Content-Length frames
    init_buffer = <<>>    :: binary()
}).

%%--------------------------------------------------------------------
%% Dialyzer suppressions
%%--------------------------------------------------------------------

-dialyzer({no_underspecs,
           [{build_session_info, 1},
            {call_permission_handler, 3},
            {call_hook_handler, 4},
            {call_user_input_handler, 3},
            {format_mcp_content, 1}]}).
-dialyzer({nowarn_function,
           [call_permission_handler/3,
            call_hook_handler/4,
            call_user_input_handler/3]}).

%%====================================================================
%% Required callbacks
%%====================================================================

-doc "Return the backend identifier for telemetry and session registration.".
-spec backend_name() -> copilot.
backend_name() -> copilot.

-doc "Initialize the handler — build transport spec, init registries.".
-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    CliPath = resolve_cli_path(Opts),
    %% Resume session ID — distinct from engine's auto-generated session_id.
    %% Only set when the user explicitly provides a Copilot session to resume.
    ResumeSessionId = maps:get(copilot_session_id, Opts,
                               maps:get(resume_session_id, Opts, undefined)),
    HookRegistry = beam_agent_hooks_core:build_registry(
                       maps:get(sdk_hooks, Opts, undefined)),
    McpRegistry = build_mcp_registry(Opts),
    Opts1 = maybe_inject_sdk_tools(McpRegistry, Opts),
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    Args = copilot_protocol:build_cli_args(Opts1),
    Env = copilot_protocol:build_env(Opts1),
    WorkDir = maps:get(work_dir, Opts1,
                       maps:get(cwd, Opts1, undefined)),
    TransportOpts = #{
        executable      => CliPath,
        args            => Args,
        env             => Env,
        mode            => raw,
        extra_port_opts => [hide]
    },
    TransportOpts1 = case WorkDir of
        undefined -> TransportOpts;
        Dir when is_binary(Dir) -> TransportOpts#{cd => binary_to_list(Dir)};
        Dir when is_list(Dir) -> TransportOpts#{cd => Dir}
    end,
    HState = #hstate{
        session_id         = ResumeSessionId,
        cli_path           = CliPath,
        opts               = Opts1,
        model              = maps:get(model, Opts1, undefined),
        permission_handler = PermHandler,
        user_input_handler = UserInputHandler,
        sdk_mcp_registry   = McpRegistry,
        sdk_hook_registry  = HookRegistry
    },
    {ok, #{
        transport_spec => {beam_agent_transport_port, TransportOpts1},
        initial_state  => connecting,
        handler_state  => HState
    }}.

-doc """
Decode incoming transport data into normalized messages.

Uses `copilot_frame:extract_messages/1` for Content-Length framing,
then dispatches each JSON-RPC message: responses update pending map,
notifications yield normalized events, requests get handled inline.
""".
-spec handle_data(binary(), #hstate{}) ->
    beam_agent_session_handler:data_result().
handle_data(Buffer, HState) ->
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Buffer),
    {Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    Messages = [copilot_protocol:normalize_event(E) || E <- Events],
    {DeliverMsgs, Actions, HState2} =
        process_normalized_messages(Messages, HState1, [], []),
    {ok, DeliverMsgs, RestBuf, Actions, HState2}.

-doc """
Encode an outgoing query — fire hook, build session.send request.

Model is a session-level setting — per-query model overrides in params are
not honored by the Copilot CLI. Use `set_model/2` to switch models.
""".
-spec encode_query(binary(), beam_agent_core:query_opts(), #hstate{}) ->
    {ok, iodata(), #hstate{}} | {error, term()}.
encode_query(_Prompt, _Params,
             #hstate{copilot_session_id = undefined}) ->
    {error, no_session};
encode_query(Prompt, Params,
             #hstate{copilot_session_id = SessionId} = HState) ->
    HookCtx = #{event => user_prompt_submit,
                prompt => Prompt,
                params => Params,
                session_id => SessionId},
    case fire_hook(user_prompt_submit, HookCtx, HState) of
        {deny, Reason} ->
            {error, {hook_denied, Reason}};
        {ask, Reason} ->
            {error, {hook_ask, Reason}};
        {ok, FinalCtx} ->
            FinalPrompt = maps:get(prompt, FinalCtx),
            FinalParams = maps:get(params, FinalCtx),
            ReqId = make_request_id(HState),
            SendParams = copilot_protocol:build_session_send_params(
                             SessionId, FinalPrompt, FinalParams),
            Msg = copilot_protocol:encode_request(
                      ReqId, <<"session.send">>, SendParams),
            Encoded = copilot_frame:encode_message(Msg),
            HState1 = HState#hstate{
                next_id = HState#hstate.next_id + 1,
                pending = maps:put(ReqId, {internal, undefined},
                                   HState#hstate.pending)
            },
            {ok, Encoded, HState1}
    end.

-doc "Build the session info map.".
-spec build_session_info(#hstate{}) -> map().
build_session_info(#hstate{copilot_session_id = CopilotSId,
                            cli_path = CliPath,
                            model = Model}) ->
    Base = #{adapter => copilot,
             model => Model,
             cli_path => list_to_binary(CliPath)},
    case CopilotSId of
        undefined -> Base;
        SId -> Base#{copilot_session_id => SId}
    end.

-doc "Clean up handler resources — fire session_end hook, reply to pending callers.".
-spec terminate_handler(term(), #hstate{}) -> ok.
terminate_handler(Reason, #hstate{pending = Pending} = HState) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason,
                    session_id => HState#hstate.copilot_session_id},
                  HState),
    %% Reply to all pending callers
    maps:foreach(
        fun(_Id, {From, TRef}) ->
            cancel_timer(TRef),
            case From of
                internal -> ok;
                internal_create -> ok;
                internal_resume -> ok;
                _ -> gen_statem:reply(From, {error, session_terminated})
            end
        end,
        Pending),
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-doc "Store the transport ref for direct port access.".
-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started(TRef, HState) ->
    HState#hstate{port_ref = TRef}.

-doc """
Handle transport events during the connecting phase.

Extracts frames from data, checks if the ping response has been
received (pending map empty after response dispatch), and transitions
to initializing when ping completes.
""".
-spec handle_connecting(beam_agent_session_handler:transport_event(),
                        #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_connecting({data, RawData}, HState) ->
    %% Accumulate with init buffer, then extract frames
    Combined = <<(HState#hstate.init_buffer)/binary, RawData/binary>>,
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Combined),
    {_Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    HState2 = HState1#hstate{init_buffer = RestBuf},
    %% Check if ping response cleared pending
    case maps:size(HState2#hstate.pending) of
        0 ->
            {next_state, initializing, [],
             HState2#hstate{init_buffer = <<>>}, RestBuf};
        _ ->
            {keep_state, [], HState2}
    end;
handle_connecting({exit, Status}, HState) ->
    {error_state, {cli_exit, Status}, HState};
handle_connecting(connect_timeout, HState) ->
    {error_state, {timeout, connecting}, HState};
handle_connecting(_Event, HState) ->
    {keep_state, [], HState}.

-doc """
Handle transport events during the initializing phase.

Extracts frames, dispatches JSON-RPC to process session.create/resume
response. When copilot_session_id is set (by handle_response), fires
session_start hook and transitions to ready.
""".
-spec handle_initializing(beam_agent_session_handler:transport_event(),
                          #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_initializing({data, RawData}, HState) ->
    %% Accumulate with init buffer, then extract frames
    Combined = <<(HState#hstate.init_buffer)/binary, RawData/binary>>,
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Combined),
    {_Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    HState2 = HState1#hstate{init_buffer = RestBuf},
    case HState2#hstate.copilot_session_id of
        undefined ->
            {keep_state, [], HState2};
        _SessionId ->
            {next_state, ready, [],
             HState2#hstate{init_buffer = <<>>}, RestBuf}
    end;
handle_initializing({exit, Status}, HState) ->
    {error_state, {cli_exit_during_init, Status}, HState};
handle_initializing(init_timeout, HState) ->
    {error_state, {timeout, initializing}, HState};
handle_initializing(_Event, HState) ->
    {keep_state, [], HState}.

-doc "Encode a session.abort interrupt request.".
-spec encode_interrupt(#hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} |
    not_supported.
encode_interrupt(#hstate{copilot_session_id = undefined}) ->
    not_supported;
encode_interrupt(#hstate{copilot_session_id = SessionId} = HState) ->
    ReqId = make_request_id(HState),
    Params = #{<<"sessionId">> => SessionId},
    Msg = copilot_protocol:encode_request(ReqId, <<"session.abort">>, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1}.

-doc "Handle send_control/3 calls — send arbitrary JSON-RPC request with pending tracking.".
-spec handle_control(binary(), map(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
handle_control(Method, Params, From, HState) ->
    ReqId = make_request_id(HState),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {From, undefined},
                           HState#hstate.pending)
    },
    {noreply, [{send, Encoded}], HState1}.

-doc """
Handle set_model/2 — send session.model.switchTo request with pending tracking.

Accepts either a binary model ID or a map with model and optional
reasoningEffort: `#{model => <<"model-id">>, reasoning_effort => <<"high">>}`.
""".
-spec handle_set_model(binary() | map(), #hstate{}) ->
    {ok, term(), [beam_agent_session_handler:handler_action()], #hstate{}} |
    {error, term()}.
handle_set_model(_Model, #hstate{copilot_session_id = undefined}) ->
    {error, no_session};
handle_set_model(ModelSpec, #hstate{copilot_session_id = SessionId} = HState)
  when is_map(ModelSpec) ->
    ModelId = maps:get(model, ModelSpec, maps:get(<<"model">>, ModelSpec, <<>>)),
    ReqId = make_request_id(HState),
    Base = #{<<"sessionId">> => SessionId, <<"modelId">> => ModelId},
    Params = case maps:find(reasoning_effort, ModelSpec) of
        {ok, Effort} -> Base#{<<"reasoningEffort">> => Effort};
        error ->
            case maps:find(<<"reasoningEffort">>, ModelSpec) of
                {ok, Effort} -> Base#{<<"reasoningEffort">> => Effort};
                error -> Base
            end
    end,
    Msg = copilot_protocol:encode_request(
              ReqId, <<"session.model.switchTo">>, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending),
        model = ModelId
    },
    {ok, ModelId, [{send, Encoded}], HState1};
handle_set_model(Model, HState) when is_binary(Model) ->
    handle_set_model(#{model => Model}, HState).

-doc "Handle set_permission_mode/2 — send session.mode.set request with pending tracking.".
-spec handle_set_permission_mode(binary(), #hstate{}) ->
    {ok, binary(), [beam_agent_session_handler:handler_action()], #hstate{}} |
    {error, term()}.
handle_set_permission_mode(_Mode, #hstate{copilot_session_id = undefined}) ->
    {error, no_session};
handle_set_permission_mode(Mode, #hstate{copilot_session_id = SessionId} = HState) ->
    ReqId = make_request_id(HState),
    Params = #{<<"sessionId">> => SessionId, <<"mode">> => Mode},
    Msg = copilot_protocol:encode_request(
              ReqId, <<"session.mode.set">>, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, Mode, [{send, Encoded}], HState1}.

-doc """
Handle state enter events.

- connecting: send ping request
- initializing: send session.create or session.resume request
- ready (from initializing): fire session_start hook
""".
-spec on_state_enter(beam_agent_session_handler:state_name(),
                     beam_agent_session_handler:state_name() | undefined,
                     #hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}}.
on_state_enter(connecting, _OldState, HState) ->
    %% Send ping request
    ReqId = make_request_id(HState),
    PingMsg = copilot_protocol:encode_request(
                  ReqId, <<"ping">>, #{<<"message">> => <<"hello">>}),
    Encoded = copilot_frame:encode_message(PingMsg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1};
on_state_enter(initializing, _OldState, HState) ->
    %% Send session.create or session.resume request
    {Method, Params, PendingTag} = init_request(HState),
    ReqId = make_request_id(HState),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {PendingTag, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1};
on_state_enter(ready, OldState, HState)
  when OldState =:= initializing; OldState =:= connecting ->
    %% Fire session_start hook on first transition to ready
    SessionId = HState#hstate.copilot_session_id,
    _ = fire_hook(session_start,
                  #{event => session_start, session_id => SessionId},
                  HState),
    {ok, [], HState};
on_state_enter(_State, _OldState, HState) ->
    {ok, [], HState}.

-doc "Check for result/error terminal messages.".
-spec is_query_complete(beam_agent_core:message(), #hstate{}) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error, is_error := true}, _HState) -> true;
is_query_complete(_Msg, _HState) -> false.

%%====================================================================
%% Engine format_status redaction
%%====================================================================

-doc false.
-spec redact_handler_state(#hstate{} | term()) -> #hstate{} | term().
redact_handler_state(#hstate{} = HState) ->
    HState#hstate{opts = beam_agent_redaction:map(HState#hstate.opts)};
redact_handler_state(Other) ->
    Other.

%%====================================================================
%% Internal: JSON-RPC dispatch
%%====================================================================

-spec dispatch_jsonrpc([map()], #hstate{}, [map()]) -> {[map()], #hstate{}}.
dispatch_jsonrpc([], HState, Acc) ->
    {lists:reverse(Acc), HState};
dispatch_jsonrpc([Msg | Rest], HState, Acc) ->
    case beam_agent_jsonrpc:decode(Msg) of
        {response, Id, Result} ->
            HState1 = handle_response(Id, {ok, Result}, HState),
            dispatch_jsonrpc(Rest, HState1, Acc);
        {error_response, Id, Code, ErrMsg, ErrData} ->
            HState1 = handle_response(
                           Id, {error, {Code, ErrMsg, ErrData}}, HState),
            dispatch_jsonrpc(Rest, HState1, Acc);
        {notification, <<"session.event">>, Params} ->
            Event = maps:get(<<"event">>, Params, Params),
            dispatch_jsonrpc(Rest, HState, [Event | Acc]);
        {notification, _Method, _Params} ->
            dispatch_jsonrpc(Rest, HState, Acc);
        {request, ReqId, Method, Params} ->
            HState1 = handle_server_request(ReqId, Method, Params, HState),
            dispatch_jsonrpc(Rest, HState1, Acc);
        {unknown, _} ->
            dispatch_jsonrpc(Rest, HState, Acc)
    end.

%%====================================================================
%% Internal: JSON-RPC response handling
%%====================================================================

-spec handle_response(binary() | integer(),
                      {ok, term()} | {error, term()},
                      #hstate{}) -> #hstate{}.
handle_response(Id, Result, HState) ->
    BinId = ensure_binary_id(Id),
    case maps:take(BinId, HState#hstate.pending) of
        {{internal, TRef}, NewPending} ->
            cancel_timer(TRef),
            HState#hstate{pending = NewPending};
        {{internal_create, TRef}, NewPending} ->
            cancel_timer(TRef),
            SessionId = extract_response_session_id(Result),
            HState#hstate{pending = NewPending,
                          copilot_session_id = SessionId};
        {{internal_resume, TRef}, NewPending} ->
            cancel_timer(TRef),
            SessionId = extract_response_session_id(Result),
            HState#hstate{pending = NewPending,
                          copilot_session_id = SessionId};
        {{From, TRef}, NewPending} ->
            cancel_timer(TRef),
            gen_statem:reply(From, Result),
            HState#hstate{pending = NewPending};
        error ->
            HState
    end.

%%====================================================================
%% Internal: init request building
%%====================================================================

-spec init_request(#hstate{}) ->
    {binary(), map(), internal_create | internal_resume}.
init_request(#hstate{opts = Opts, session_id = SessionId}) ->
    ResumeRequested = maps:get(resume, Opts, SessionId =/= undefined),
    case {ResumeRequested, SessionId} of
        {true, ResumeId}
            when is_binary(ResumeId), byte_size(ResumeId) > 0 ->
            {<<"session.resume">>,
             copilot_protocol:build_session_resume_params(ResumeId, Opts),
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
    when is_binary(SId) -> SId;
extract_response_session_id({ok, #{<<"session_id">> := SId}})
    when is_binary(SId) -> SId;
extract_response_session_id({ok, #{session_id := SId}})
    when is_binary(SId) -> SId;
extract_response_session_id(_) -> undefined.

%%====================================================================
%% Internal: server-side JSON-RPC request handling
%%====================================================================

-dialyzer({nowarn_function, {handle_server_request, 4}}).

-spec handle_server_request(binary() | integer(), binary(),
                            map() | undefined, #hstate{}) -> #hstate{}.
handle_server_request(ReqId, <<"tool.call">>, Params,
                      #hstate{sdk_mcp_registry = Registry} = HState)
  when is_map(Registry) ->
    ToolName = maps:get(<<"toolName">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Result = beam_agent_tool_registry:call_tool_by_name(
                 ToolName, Arguments, Registry),
    Response = case Result of
        {ok, Content} ->
            WireContent = [format_mcp_content(C) || C <- Content],
            copilot_protocol:encode_response(
                ReqId,
                #{<<"resultType">> => <<"success">>,
                  <<"content">> => WireContent});
        {error, ErrMsg} ->
            copilot_protocol:encode_response(
                ReqId,
                #{<<"resultType">> => <<"failure">>,
                  <<"error">> => ErrMsg})
    end,
    send_via_port(Response, HState),
    HState;
handle_server_request(ReqId, <<"tool.call">>, _Params, HState) ->
    Response = copilot_protocol:encode_response(
                   ReqId,
                   #{<<"resultType">> => <<"failure">>,
                     <<"error">> => <<"No MCP servers registered">>}),
    send_via_port(Response, HState),
    HState;
handle_server_request(ReqId, <<"permission.request">>, Params, HState) ->
    Request = maps:get(<<"request">>, Params, Params),
    _Invocation = maps:get(<<"invocation">>, Params, #{}),
    call_permission_handler(ReqId, Request, HState);
handle_server_request(ReqId, <<"hooks.invoke">>, Params, HState) ->
    HookType = maps:get(<<"hookType">>, Params, <<>>),
    Input = maps:get(<<"input">>, Params, #{}),
    call_hook_handler(ReqId, HookType, Input, HState);
handle_server_request(ReqId, <<"user_input.request">>, Params, HState) ->
    call_user_input_handler(ReqId, Params, HState);
handle_server_request(ReqId, <<"userInput.request">>, Params, HState) ->
    call_user_input_handler(ReqId, Params, HState);
handle_server_request(ReqId, <<"systemMessage.transform">>, Params, HState) ->
    Sections = maps:get(<<"sections">>, Params, []),
    Response = copilot_protocol:encode_response(
                   ReqId, #{<<"sections">> => Sections}),
    send_via_port(Response, HState),
    HState;
handle_server_request(ReqId, Method, _Params, HState) ->
    logger:warning("Unknown Copilot server request: ~s", [Method]),
    Response = copilot_protocol:encode_error_response(
                   ReqId, -32601,
                   <<"Method not found: ", Method/binary>>),
    send_via_port(Response, HState),
    HState.

%%====================================================================
%% Internal: permission handling
%%====================================================================

-spec call_permission_handler(binary() | integer(), map(), #hstate{}) ->
    #hstate{}.
call_permission_handler(ReqId, Request, HState) ->
    Result = case HState#hstate.permission_handler of
        undefined ->
            copilot_protocol:build_permission_result(
                #{<<"kind">> =>
                    <<"denied-no-approval-rule-and-could-not-request-from-user">>});
        Handler ->
            try
                Invocation = #{session_id => HState#hstate.copilot_session_id},
                case Handler(Request, Invocation) of
                    PermResult ->
                        copilot_protocol:build_permission_result(PermResult)
                end
            catch
                _:_ ->
                    copilot_protocol:build_permission_result(
                #{<<"kind">> =>
                    <<"denied-no-approval-rule-and-could-not-request-from-user">>})
            end
    end,
    Response = copilot_protocol:encode_response(ReqId, Result),
    send_via_port(Response, HState),
    HState.

%%====================================================================
%% Internal: hook handling
%%====================================================================

-spec call_hook_handler(binary() | integer(), binary(), map(), #hstate{}) ->
    #hstate{}.
call_hook_handler(ReqId, HookType, Input, HState) ->
    Result = case HState#hstate.sdk_hook_registry of
        undefined ->
            #{};
        _Registry ->
            Event = case HookType of
                <<"preToolUse">>           -> pre_tool_use;
                <<"postToolUse">>          -> post_tool_use;
                <<"userPromptSubmitted">>  -> user_prompt_submit;
                <<"sessionStart">>         -> session_start;
                <<"sessionEnd">>           -> session_end;
                <<"errorOccurred">>        -> post_tool_use_failure;
                _                          -> unknown_hook
            end,
            case Event of
                unknown_hook ->
                    #{};
                _ ->
                    case fire_hook(Event, Input#{event => Event}, HState) of
                        {ok, _FinalCtx} ->
                            #{};
                        {deny, Reason} ->
                            #{<<"permissionDecision">> => <<"deny">>,
                              <<"permissionDecisionReason">> => Reason};
                        {ask, Reason} ->
                            #{<<"permissionDecision">> => <<"deny">>,
                              <<"permissionDecisionReason">> => Reason}
                    end
            end
    end,
    WireResult = copilot_protocol:build_hook_result(Result),
    Response = copilot_protocol:encode_response(ReqId, WireResult),
    send_via_port(Response, HState),
    HState.

%%====================================================================
%% Internal: user input handling
%%====================================================================

-spec call_user_input_handler(binary() | integer(), map(), #hstate{}) ->
    #hstate{}.
call_user_input_handler(ReqId, Params, HState) ->
    case HState#hstate.user_input_handler of
        undefined ->
            Response = copilot_protocol:encode_error_response(
                           ReqId, -32603,
                           <<"No user input handler registered">>),
            send_via_port(Response, HState),
            HState;
        Handler ->
            try
                Request = #{
                    question => maps:get(<<"question">>, Params, <<>>),
                    choices => maps:get(<<"choices">>, Params, []),
                    allow_freeform =>
                        maps:get(<<"allowFreeform">>, Params, true)
                },
                Ctx = #{session_id => HState#hstate.copilot_session_id},
                case Handler(Request, Ctx) of
                    InputResult when is_map(InputResult) ->
                        WireResult =
                            copilot_protocol:build_user_input_result(
                                InputResult),
                        Resp = copilot_protocol:encode_response(
                                   ReqId, WireResult),
                        send_via_port(Resp, HState),
                        HState
                end
            catch
                Class:Reason:_Stack ->
                    ErrMsg = iolist_to_binary(
                                 io_lib:format(
                                     "User input handler error: ~p:~p",
                                     [Class, Reason])),
                    ErrResp = copilot_protocol:encode_error_response(
                                  ReqId, -32603, ErrMsg),
                    send_via_port(ErrResp, HState),
                    HState
            end
    end.

%%====================================================================
%% Internal: normalized message processing (hooks + tracking)
%%====================================================================

-spec process_normalized_messages([beam_agent_core:message()], #hstate{},
                                  [beam_agent_core:message()],
                                  [beam_agent_session_handler:handler_action()]) ->
    {[beam_agent_core:message()],
     [beam_agent_session_handler:handler_action()],
     #hstate{}}.
process_normalized_messages([], HState, MsgsAcc, ActionsAcc) ->
    {lists:reverse(MsgsAcc), lists:reverse(ActionsAcc), HState};
%% v3 broadcast: external_tool.requested — dispatch tool call, send response RPC
process_normalized_messages(
    [#{type := tool_use, request_id := ReqId} = Msg | Rest],
    HState, MsgsAcc, ActionsAcc)
  when ReqId =/= undefined ->
    HState1 = handle_v3_tool_call(ReqId, Msg, HState),
    HState2 = maybe_fire_message_hooks(Msg, HState1),
    _ = track_message(Msg, HState2),
    process_normalized_messages(Rest, HState2, [Msg | MsgsAcc], ActionsAcc);
%% v3 broadcast: permission.requested — dispatch permission, send response RPC
process_normalized_messages(
    [#{type := control_request, subtype := <<"permission">>,
       request_id := ReqId} = Msg | Rest],
    HState, MsgsAcc, ActionsAcc)
  when ReqId =/= undefined ->
    HState1 = handle_v3_permission_request(ReqId, Msg, HState),
    HState2 = maybe_fire_message_hooks(Msg, HState1),
    _ = track_message(Msg, HState2),
    process_normalized_messages(Rest, HState2, [Msg | MsgsAcc], ActionsAcc);
%% All other messages — hooks + tracking only
process_normalized_messages([Msg | Rest], HState, MsgsAcc, ActionsAcc) ->
    HState1 = maybe_fire_message_hooks(Msg, HState),
    _ = track_message(Msg, HState1),
    process_normalized_messages(Rest, HState1, [Msg | MsgsAcc], ActionsAcc).

%%====================================================================
%% Internal: v3 broadcast response RPCs
%%====================================================================

-spec handle_v3_tool_call(binary(), beam_agent_core:message(), #hstate{}) ->
    #hstate{}.
handle_v3_tool_call(ToolReqId, Msg,
                    #hstate{sdk_mcp_registry = Registry} = HState)
  when is_map(Registry) ->
    ToolName = maps:get(tool_name, Msg, <<>>),
    ToolInput = maps:get(tool_input, Msg, #{}),
    Result = beam_agent_tool_registry:call_tool_by_name(
                 ToolName, ToolInput, Registry),
    ResultParams = case Result of
        {ok, Content} ->
            WireContent = [format_mcp_content(C) || C <- Content],
            #{<<"toolCallId">> => ToolReqId,
              <<"resultType">> => <<"success">>,
              <<"content">> => WireContent};
        {error, ErrMsg} ->
            #{<<"toolCallId">> => ToolReqId,
              <<"resultType">> => <<"failure">>,
              <<"error">> => ErrMsg}
    end,
    send_v3_rpc(<<"session.tools.handlePendingToolCall">>,
                ResultParams, HState);
handle_v3_tool_call(_ToolReqId, _Msg, HState) ->
    %% No MCP registry registered — nothing to dispatch
    HState.

-spec handle_v3_permission_request(binary(), beam_agent_core:message(),
                                   #hstate{}) -> #hstate{}.
handle_v3_permission_request(PermReqId, Msg, HState) ->
    Request = maps:get(request, Msg, #{}),
    PermResult = case HState#hstate.permission_handler of
        undefined ->
            copilot_protocol:build_permission_result(
                #{<<"kind">> =>
                    <<"denied-no-approval-rule-and-could-not-request-from-user">>});
        Handler ->
            try
                Invocation = #{session_id =>
                                   HState#hstate.copilot_session_id},
                case Handler(Request, Invocation) of
                    R -> copilot_protocol:build_permission_result(R)
                end
            catch
                _:_ ->
                    copilot_protocol:build_permission_result(
                #{<<"kind">> =>
                    <<"denied-no-approval-rule-and-could-not-request-from-user">>})
            end
    end,
    Params = PermResult#{<<"permissionRequestId">> => PermReqId},
    send_v3_rpc(
        <<"session.permissions.handlePendingPermissionRequest">>,
        Params, HState).

-spec send_v3_rpc(binary(), map(), #hstate{}) -> #hstate{}.
send_v3_rpc(Method, Params, HState) ->
    ReqId = make_request_id(HState),
    Request = copilot_protocol:encode_request(ReqId, Method, Params),
    send_via_port(Request, HState),
    HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    }.

%%====================================================================
%% Internal: message hooks
%%====================================================================

%% Copilot uses dual-dispatch for hooks:
%%   1. Wire protocol hooks (blocking) — `call_hook_callback/3` handles
%%      `<<"preToolUse">>` requests from the copilot CLI, where the SDK
%%      responds with allow/deny.  That is the real blocking gate.
%%   2. SDK-level observation hooks (below) — fire as notifications when
%%      messages arrive, so SDK hooks can observe tool lifecycle without
%%      blocking the wire protocol flow.  Result is intentionally
%%      discarded because the blocking decision was already made in (1).
-spec maybe_fire_message_hooks(beam_agent_core:message(), #hstate{}) ->
    #hstate{}.
maybe_fire_message_hooks(#{type := tool_use} = Msg, HState) ->
    _ = fire_hook(pre_tool_use,
                  #{event => pre_tool_use,
                    tool_name => maps:get(tool_name, Msg, <<>>),
                    tool_input => maps:get(tool_input, Msg, #{}),
                    tool_use_id => maps:get(tool_use_id, Msg, <<>>)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := tool_result} = Msg, HState) ->
    _ = fire_hook(post_tool_use,
                  #{event => post_tool_use,
                    tool_name => maps:get(tool_name, Msg, <<>>),
                    content => maps:get(content, Msg, <<>>),
                    tool_use_id => maps:get(tool_use_id, Msg, <<>>)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := error} = Msg, HState) ->
    _ = fire_hook(post_tool_use_failure,
                  #{event => post_tool_use_failure,
                    content => maps:get(content, Msg, <<>>)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := result} = Msg, HState) ->
    _ = fire_hook(stop,
                  #{event => stop,
                    content => maps:get(content, Msg, <<>>),
                    stop_reason => maps:get(stop_reason, Msg, <<>>)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := system,
                           subtype := <<"subagent_started">>} = Msg,
                          HState) ->
    Data = maps:get(content, Msg, #{}),
    _ = fire_hook(subagent_start,
                  #{event => subagent_start,
                    agent_id => extract_agent_id(Data),
                    metadata => ensure_map(Data)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := system,
                           subtype := <<"subagent_completed">>} = Msg,
                          HState) ->
    Data = maps:get(content, Msg, #{}),
    _ = fire_hook(subagent_stop,
                  #{event => subagent_stop,
                    agent_id => extract_agent_id(Data),
                    metadata => ensure_map(Data)},
                  HState),
    HState;
maybe_fire_message_hooks(#{type := system} = Msg, HState) ->
    _ = fire_hook(notification,
                  #{event => notification,
                    content => ensure_binary(maps:get(content, Msg, <<>>))},
                  HState),
    HState;
maybe_fire_message_hooks(_Msg, HState) ->
    HState.

%%====================================================================
%% Internal: message tracking
%%====================================================================

-spec track_message(beam_agent_core:message(), #hstate{}) -> ok.
track_message(Msg, HState) ->
    SessionId = session_store_id(HState),
    _ = beam_agent_session_store_core:register_session(
             SessionId, #{adapter => copilot}),
    StoredMsg = maybe_tag_session_id(Msg, SessionId),
    _ = case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(
                SessionId, ThreadId, StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(
                SessionId, StoredMsg)
    end,
    ok.

-spec session_store_id(#hstate{}) -> binary().
session_store_id(#hstate{copilot_session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(#hstate{session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_HState) ->
    unicode:characters_to_binary(pid_to_list(self())).

-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
    beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.

%%====================================================================
%% Internal: hook context helpers
%%====================================================================

%% Extract agent_id from subagent event data (wire key <<"agentId">>).
-spec extract_agent_id(map() | term()) -> binary().
extract_agent_id(Data) when is_map(Data) ->
    maps:get(<<"agentId">>, Data, <<>>);
extract_agent_id(_) ->
    <<>>.

%% Ensure content is binary for hook contexts.
%% Copilot normalize_event/1 sets content to raw Data maps for some
%% system events; hook_context() types content as binary().
-spec ensure_binary(term()) -> binary().
ensure_binary(Content) when is_binary(Content) -> Content;
ensure_binary(_) -> <<>>.

%% Ensure value is a map for metadata fields.
-spec ensure_map(term()) -> map().
ensure_map(Data) when is_map(Data) -> Data;
ensure_map(_) -> #{}.

%%====================================================================
%% Internal: hook firing
%%====================================================================

-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(), #hstate{}) ->
    {ok, beam_agent_hooks_core:hook_context()}
  | {deny, binary()}
  | {ask, binary()}.
fire_hook(Event, Context, #hstate{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).

%%====================================================================
%% Internal: transport helpers
%%====================================================================

-spec send_via_port(map(), #hstate{}) -> ok.
send_via_port(Response, #hstate{port_ref = Port}) when Port =/= undefined ->
    try
        port_command(Port, copilot_frame:encode_message(Response)),
        ok
    catch
        error:badarg -> ok
    end;
send_via_port(_Response, _HState) ->
    ok.

%%====================================================================
%% Internal: MCP content formatting
%%====================================================================

-type mcp_wire_content() :: map().

-spec format_mcp_content(beam_agent_tool_registry:content_result()) ->
    mcp_wire_content().
format_mcp_content(#{type := text, text := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_mcp_content(#{type := image, data := ImgData, mime_type := Mime}) ->
    #{<<"type">> => <<"image">>,
      <<"data">> => ImgData,
      <<"mimeType">> => Mime}.

%%====================================================================
%% Internal: utility helpers
%%====================================================================

-spec make_request_id(#hstate{}) -> binary().
make_request_id(#hstate{next_id = N}) ->
    integer_to_binary(N).

-spec ensure_binary_id(binary() | integer()) -> binary().
ensure_binary_id(Id) when is_binary(Id) -> Id;
ensure_binary_id(Id) when is_integer(Id) -> integer_to_binary(Id).

-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

-spec resolve_cli_path(map()) -> string().
resolve_cli_path(Opts) ->
    case maps:get(cli_path, Opts, undefined) of
        undefined                -> "copilot";
        Path when is_binary(Path) -> binary_to_list(Path);
        Path when is_list(Path)   -> Path
    end.

-spec build_mcp_registry(map()) ->
    beam_agent_tool_registry:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    beam_agent_tool_registry:build_registry(
        maps:get(sdk_mcp_servers, Opts, undefined)).

-spec maybe_inject_sdk_tools(beam_agent_tool_registry:mcp_registry() | undefined,
                             map()) -> map().
maybe_inject_sdk_tools(undefined, Opts) -> Opts;
maybe_inject_sdk_tools(Reg, Opts) ->
    case beam_agent_tool_registry:all_tool_definitions(Reg) of
        [] -> Opts;
        ToolDefs -> Opts#{sdk_tools => ToolDefs}
    end.
