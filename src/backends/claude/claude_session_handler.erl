-module(claude_session_handler).
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
    on_state_enter/3,
    is_query_complete/2
]).

%% Dialyzer: resume_args/1 and fork_session_args/1 return string literals
%% whose character codes are more specific than [[byte()]]; suppressing
%% since encoding the exact codepoints in a spec is impractical.
-dialyzer({nowarn_function, [resume_args/1, fork_session_args/1]}).

%%--------------------------------------------------------------------
%% Handler state
%%--------------------------------------------------------------------

-record(hstate, {
    %% Transport ref (stored via transport_started/2 for SIGINT)
    port_ref           :: port() | undefined,

    %% Protocol buffer (used during connecting/initializing phases;
    %% engine owns buffer in ready/active_query)
    init_buffer = <<>> :: binary(),

    %% Pending control responses: request_id => gen_statem:from()
    pending = #{}      :: #{binary() => gen_statem:from()},

    %% Session identity
    session_id         :: binary() | undefined,
    system_info = #{}  :: map(),
    init_response = #{} :: map(),

    %% CLI configuration
    cli_path           :: string(),
    opts               :: map(),

    %% Permission & input handlers
    permission_handler :: fun((binary(), map(), map()) ->
                              beam_agent_core:permission_result()) | undefined,
    user_input_handler :: fun((map(), map()) ->
                              {ok, binary()} | {error, term()}) | undefined,

    %% SDK registries
    sdk_mcp_registry   :: beam_agent_tool_registry:mcp_registry() | undefined,
    sdk_hook_registry  :: beam_agent_hooks_core:hook_registry() | undefined,

    %% CLI hook config (sent in init request)
    hook_config = null :: map() | null,
    hook_callbacks = #{} :: #{binary() => fun()},

    %% MCP config temp file path (for cleanup)
    mcp_config_path    :: string() | undefined
}).

%%====================================================================
%% Required callbacks
%%====================================================================

-spec backend_name() -> claude.
backend_name() -> claude.

-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    CliPath = resolve_cli_path(maps:get(cli_path, Opts, "claude")),
    SessionId = maps:get(session_id, Opts, undefined),
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    McpRegistry = beam_agent_tool_registry:build_registry(
                      maps:get(sdk_mcp_servers, Opts, undefined)),
    HookRegistry = beam_agent_hooks_core:build_registry(
                       maps:get(sdk_hooks, Opts, undefined)),
    {HookConfig, HookCallbacks} = build_cli_hooks(
                                      maps:get(hooks, Opts, undefined)),
    McpConfigPath = write_mcp_config(McpRegistry),
    Args = build_cli_args(Opts, McpConfigPath),
    TransportOpts = #{
        executable  => CliPath,
        args        => Args,
        env         => build_env(Opts),
        cd          => maps:get(work_dir, Opts, undefined),
        line_buffer => 1_048_576
    },
    HState = #hstate{
        session_id         = SessionId,
        cli_path           = CliPath,
        opts               = Opts,
        permission_handler = PermHandler,
        user_input_handler = UserInputHandler,
        sdk_mcp_registry   = McpRegistry,
        sdk_hook_registry  = HookRegistry,
        hook_config        = HookConfig,
        hook_callbacks     = HookCallbacks,
        mcp_config_path    = McpConfigPath
    },
    {ok, #{
        transport_spec => {beam_agent_transport_port, TransportOpts},
        initial_state  => connecting,
        handler_state  => HState
    }}.

-spec handle_data(binary(), #hstate{}) ->
    beam_agent_session_handler:data_result().
handle_data(Buffer, #hstate{pending = Pending} = HState) ->
    %% Extract all complete JSONL frames from buffer, normalize messages,
    %% handle internal control traffic, return deliverable messages.
    extract_messages(Buffer, HState, Pending, [], []).

-spec encode_query(binary(), beam_agent_core:query_opts(), #hstate{}) ->
    {ok, iodata(), #hstate{}} | {error, term()}.
encode_query(Prompt, Params, #hstate{sdk_hook_registry = HookReg,
                                      session_id = SessionId} = HState) ->
    %% Fire user_prompt_submit hook before encoding
    HookCtx = #{prompt => Prompt, params => Params,
                session_id => SessionId, event => user_prompt_submit},
    case beam_agent_hooks_core:fire(user_prompt_submit, HookCtx, HookReg) of
        ok ->
            QueryMsg = build_query_message(Prompt, Params),
            Encoded = beam_agent_jsonl:encode_line(QueryMsg),
            {ok, Encoded, HState};
        {deny, Reason} ->
            {error, {hook_denied, Reason}}
    end.

-spec build_session_info(#hstate{}) -> map().
build_session_info(#hstate{system_info = SysInfo,
                            init_response = InitResponse}) ->
    #{adapter => claude,
      system_info => SysInfo,
      init_response => InitResponse}.

-spec terminate_handler(term(), #hstate{}) -> ok.
terminate_handler(Reason, #hstate{sdk_hook_registry = HookReg,
                                   session_id = SessionId,
                                   mcp_config_path = McpConfigPath}) ->
    _ = beam_agent_hooks_core:fire(session_end,
            #{session_id => SessionId, reason => Reason,
              event => session_end},
            HookReg),
    cleanup_mcp_config(McpConfigPath),
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started(TRef, HState) ->
    HState#hstate{port_ref = TRef}.

-spec handle_connecting(beam_agent_session_handler:transport_event(),
                        #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_connecting({data, RawData}, #hstate{init_buffer = Buf} = HState) ->
    %% Accumulate data during connecting, transition to initializing
    NewBuf = <<Buf/binary, RawData/binary>>,
    {next_state, initializing, [],
     HState#hstate{init_buffer = NewBuf}};
handle_connecting({exit, Status}, HState) ->
    {error_state, {cli_exit, Status}, HState};
handle_connecting(connect_timeout, HState) ->
    %% Timeout waiting for first data — transition to initializing anyway
    {next_state, initializing, [], HState};
handle_connecting(_Event, HState) ->
    {keep_state, [], HState}.

-spec handle_initializing(beam_agent_session_handler:transport_event(),
                          #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_initializing({data, RawData}, HState) ->
    do_initializing(RawData, HState);
handle_initializing(init_timeout, HState) ->
    {error_state, {timeout, initializing}, HState};
handle_initializing({exit, Status}, HState) ->
    {error_state, {cli_exit_during_init, Status}, HState};
handle_initializing(_Event, HState) ->
    {keep_state, [], HState}.

-spec encode_interrupt(#hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} |
    not_supported.
encode_interrupt(#hstate{port_ref = Port} = HState)
  when Port =/= undefined ->
    %% Claude uses OS SIGINT, not a protocol message.
    %% Send the signal directly; no transport action needed.
    send_sigint(Port),
    {ok, [], HState};
encode_interrupt(_HState) ->
    not_supported.

-spec handle_control(binary(), map(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
handle_control(Method, Params, From, #hstate{pending = Pending} = HState) ->
    %% Claude uses async control_request/control_response protocol.
    %% Send request now, defer reply until response arrives in handle_data.
    ReqId = beam_agent_core:make_request_id(),
    Request = Params#{<<"subtype">> => Method},
    ControlMsg = #{<<"type">> => <<"control_request">>,
                   <<"request_id">> => ReqId,
                   <<"request">> => Request},
    Encoded = beam_agent_jsonl:encode_line(ControlMsg),
    Pending1 = maps:put(ReqId, From, Pending),
    {noreply, [{send, Encoded}], HState#hstate{pending = Pending1}}.

-spec on_state_enter(beam_agent_session_handler:state_name(),
                     beam_agent_session_handler:state_name() | undefined,
                     #hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}}.
on_state_enter(ready, _OldState, #hstate{sdk_hook_registry = HookReg,
                                          session_id = SessionId,
                                          system_info = SysInfo} = HState) ->
    %% Fire session_start hook on first transition to ready
    _ = beam_agent_hooks_core:fire(session_start,
            #{session_id => SessionId, system_info => SysInfo,
              event => session_start},
            HookReg),
    {ok, [], HState};
on_state_enter(initializing, _OldState, HState) ->
    %% Send init request when entering initializing
    SendActions = build_init_send_actions(HState),
    {ok, SendActions, HState};
on_state_enter(_State, _OldState, HState) ->
    {ok, [], HState}.

-spec is_query_complete(beam_agent_core:message(), #hstate{}) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error}, _HState) -> true;
is_query_complete(_Msg, _HState) -> false.

%%====================================================================
%% Internal: initializing handshake
%%====================================================================

-spec do_initializing(binary(), #hstate{}) ->
    beam_agent_session_handler:phase_result().
do_initializing(RawData, #hstate{init_buffer = Buf} = HState) ->
    NewBuf = <<Buf/binary, RawData/binary>>,
    case try_extract_init_response(NewBuf, HState) of
        {ok, SessionId, Remaining, HState1} ->
            %% Transition to ready, pass leftover buffer to engine
            {next_state, ready, [],
             HState1#hstate{session_id = SessionId,
                            init_buffer = <<>>},
             Remaining};
        {not_ready, Buf2, HState1} ->
            {keep_state, [], HState1#hstate{init_buffer = Buf2}}
    end.

-spec build_init_send_actions(#hstate{}) ->
    [beam_agent_session_handler:handler_action()].
build_init_send_actions(#hstate{opts = Opts,
                                 sdk_mcp_registry = McpReg,
                                 hook_config = HookConfig,
                                 init_buffer = Buf} = HState) ->
    %% Build and send init control_request
    ReqId = beam_agent_core:make_request_id(),
    InitRequest = build_init_request(Opts, McpReg, HookConfig),
    InitMsg = #{<<"type">> => <<"control_request">>,
                <<"request_id">> => ReqId,
                <<"request">> => InitRequest},
    Encoded = beam_agent_jsonl:encode_line(InitMsg),
    %% Also check if init response is already in buffer (from connecting)
    case try_extract_init_response(Buf, HState) of
        {ok, _SessionId, _Remaining, _HState1} ->
            %% Buffer already has init response — still send init request
            %% (the response check happens on next data event)
            [{send, Encoded}];
        {not_ready, _, _} ->
            [{send, Encoded}]
    end.

-spec try_extract_init_response(binary(), #hstate{}) ->
    {ok, binary() | undefined, binary(), #hstate{}} |
    {not_ready, binary(), #hstate{}}.
try_extract_init_response(Buffer, HState) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {not_ready, Buffer, HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, #{<<"type">> := <<"system">>} = SysMsg} ->
                    Normalized = beam_agent_core:normalize_message(SysMsg),
                    SysInfo = maps:get(system_info, Normalized,
                                       HState#hstate.system_info),
                    HState1 = HState#hstate{system_info = SysInfo},
                    try_extract_init_response(Rest, HState1);
                {ok, #{<<"type">> := <<"control_response">>} = Msg} ->
                    Response = maps:get(<<"response">>, Msg, #{}),
                    case maps:get(<<"subtype">>, Response, undefined) of
                        <<"success">> ->
                            SessionId = maps:get(<<"session_id">>,
                                                 Response, undefined),
                            HState1 = HState#hstate{
                                init_response = Response},
                            {ok, SessionId, Rest, HState1};
                        _ ->
                            try_extract_init_response(Rest, HState)
                    end;
                {ok, _OtherMsg} ->
                    try_extract_init_response(Rest, HState);
                {error, _} ->
                    try_extract_init_response(Rest, HState)
            end
    end.

%%====================================================================
%% Internal: message extraction (handle_data)
%%====================================================================

-spec extract_messages(binary(), #hstate{}, #{binary() => gen_statem:from()},
                       [beam_agent_core:message()],
                       [beam_agent_session_handler:handler_action()]) ->
    beam_agent_session_handler:data_result().
extract_messages(Buffer, HState, Pending, MsgsAcc, ActionsAcc) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {ok, lists:reverse(MsgsAcc), Buffer, lists:reverse(ActionsAcc),
             HState#hstate{pending = Pending}};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, RawMsg} ->
                    Msg = beam_agent_core:normalize_message(RawMsg),
                    classify_and_handle(Msg, RawMsg, Rest, HState, Pending,
                                        MsgsAcc, ActionsAcc);
                {error, _} ->
                    %% Malformed line — skip it
                    extract_messages(Rest, HState, Pending,
                                     MsgsAcc, ActionsAcc)
            end
    end.

-spec classify_and_handle(beam_agent_core:message(), map(), binary(),
                          #hstate{}, #{binary() => gen_statem:from()},
                          [beam_agent_core:message()],
                          [beam_agent_session_handler:handler_action()]) ->
    beam_agent_session_handler:data_result().
classify_and_handle(#{type := control_request} = Msg, _RawMsg, Rest,
                    HState, Pending, MsgsAcc, ActionsAcc) ->
    %% Inbound control_request from Claude — handle and respond
    ResponseActions = handle_inbound_control_request(Msg, HState),
    extract_messages(Rest, HState, Pending,
                     MsgsAcc, ResponseActions ++ ActionsAcc);
classify_and_handle(#{type := control_response, request_id := ReqId} = CtrlResp,
                    _RawMsg, Rest, HState, Pending, MsgsAcc, ActionsAcc) ->
    %% Control response — match to pending caller
    case maps:take(ReqId, Pending) of
        {From, Pending1} ->
            gen_statem:reply(From, {ok, CtrlResp}),
            extract_messages(Rest, HState, Pending1, MsgsAcc, ActionsAcc);
        error ->
            %% Orphaned response — discard
            extract_messages(Rest, HState, Pending, MsgsAcc, ActionsAcc)
    end;
classify_and_handle(Msg, _RawMsg, Rest, HState, Pending, MsgsAcc, ActionsAcc) ->
    %% Regular deliverable message — fire hooks and track
    HState1 = maybe_fire_message_hooks(Msg, HState),
    _ = track_message(Msg, HState1),
    extract_messages(Rest, HState1, Pending, [Msg | MsgsAcc], ActionsAcc).

-spec maybe_fire_message_hooks(beam_agent_core:message(), #hstate{}) ->
    #hstate{}.
maybe_fire_message_hooks(#{type := tool_result} = Msg,
                          #hstate{sdk_hook_registry = HookReg,
                                  session_id = SessionId} = HState) ->
    _ = beam_agent_hooks_core:fire(post_tool_use,
            #{tool_name => maps:get(tool_name, Msg, <<>>),
              content => maps:get(content, Msg, <<>>),
              session_id => SessionId,
              event => post_tool_use},
            HookReg),
    HState;
maybe_fire_message_hooks(#{type := result} = Msg,
                          #hstate{sdk_hook_registry = HookReg,
                                  session_id = SessionId} = HState) ->
    _ = beam_agent_hooks_core:fire(stop,
            #{content => maps:get(content, Msg, <<>>),
              stop_reason => maps:get(stop_reason, Msg, undefined),
              duration_ms => maps:get(duration_ms, Msg, undefined),
              session_id => SessionId,
              event => stop},
            HookReg),
    HState;
maybe_fire_message_hooks(_Msg, HState) ->
    HState.

%%====================================================================
%% Internal: inbound control_request handling
%%====================================================================

-spec handle_inbound_control_request(beam_agent_core:message(), #hstate{}) ->
    [beam_agent_session_handler:handler_action()].
handle_inbound_control_request(Msg, HState) ->
    ReqId = maps:get(request_id, Msg, undefined),
    Request = maps:get(request, Msg, #{}),
    Subtype = maps:get(<<"subtype">>, Request, undefined),
    Response = build_inbound_response(Subtype, Request, HState),
    ResponseMsg = #{<<"type">> => <<"control_response">>,
                    <<"request_id">> => ReqId,
                    <<"response">> => Response},
    [{send, beam_agent_jsonl:encode_line(ResponseMsg)}].

-spec build_inbound_response(binary() | undefined, map(), #hstate{}) -> map().
build_inbound_response(<<"can_use_tool">>, Request,
                       #hstate{permission_handler = Handler,
                               sdk_hook_registry = HookReg,
                               session_id = SessionId,
                               opts = Opts}) ->
    ToolName = maps:get(<<"tool_name">>, Request, <<>>),
    ToolInput = maps:get(<<"tool_input">>, Request,
                         maps:get(<<"input">>, Request, #{})),
    ToolUseId = maps:get(<<"tool_use_id">>, Request, <<>>),
    AgentId = maps:get(<<"agent_id">>, Request, undefined),
    PermissionSuggestions = maps:get(<<"permission_suggestions">>,
                                     Request, []),
    BlockedPath = maps:get(<<"blocked_path">>, Request, undefined),
    HookCtx0 = #{tool_name => ToolName,
                  permission_prompt_tool_name => ToolName,
                  tool_input => ToolInput,
                  tool_use_id => ToolUseId,
                  permission_suggestions => PermissionSuggestions},
    HookCtx1 = maybe_put_defined(agent_id, AgentId, HookCtx0),
    HookCtx = maybe_put_defined(session_id, SessionId, HookCtx1),
    case fire_permission_hooks(HookCtx, HookReg) of
        {deny, Reason} ->
            #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
        ok when is_function(Handler, 3) ->
            Options = #{tool_use_id => ToolUseId,
                        agent_id => AgentId,
                        permission_suggestions => PermissionSuggestions,
                        blocked_path => BlockedPath},
            try Handler(ToolName, ToolInput, Options) of
                PermResult ->
                    normalize_permission_handler_response(PermResult,
                                                          ToolInput)
            catch
                Class:CrashReason:Stack ->
                    logger:error("permission_handler crashed: ~p:~p~n~p",
                                 [Class, CrashReason, Stack]),
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> => <<"Permission handler crashed">>}
            end;
        ok ->
            case maps:get(permission_default, Opts, deny) of
                allow ->
                    #{<<"subtype">> => <<"approve">>};
                _ ->
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> =>
                          <<"No permission handler registered">>}
            end
    end;
build_inbound_response(<<"hook_callback">>, Request,
                       #hstate{hook_callbacks = HookCallbacks,
                               session_id = SessionId}) ->
    handle_hook_callback(Request, HookCallbacks, SessionId);
build_inbound_response(<<"mcp_message">>, Request,
                       #hstate{sdk_mcp_registry = Registry})
  when is_map(Registry) ->
    ServerName = maps:get(<<"server_name">>, Request, <<>>),
    Message = maps:get(<<"message">>, Request, #{}),
    case beam_agent_tool_registry:handle_mcp_message(ServerName, Message,
                                                 Registry) of
        {ok, McpResponse} ->
            #{<<"subtype">> => <<"ok">>,
              <<"mcp_response">> => McpResponse};
        {error, _} ->
            #{<<"subtype">> => <<"ok">>}
    end;
build_inbound_response(<<"mcp_message">>, _Request, _HState) ->
    #{<<"subtype">> => <<"ok">>};
build_inbound_response(<<"elicitation">>, Request,
                       #hstate{user_input_handler = Handler,
                               session_id = SessionId})
  when is_function(Handler, 2) ->
    ElicitRequest = #{message => maps:get(<<"message">>, Request, <<>>),
                      schema => maps:get(<<"schema">>, Request, #{}),
                      tool_use_id => maps:get(<<"tool_use_id">>,
                                               Request, undefined),
                      agent_id => maps:get(<<"agent_id">>,
                                            Request, undefined)},
    Ctx = #{session_id => SessionId},
    try Handler(ElicitRequest, Ctx) of
        {ok, Answer} ->
            #{<<"subtype">> => <<"ok">>, <<"result">> => Answer};
        {error, Reason} when is_binary(Reason) ->
            #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
        {error, _} ->
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input denied">>}
    catch
        Class:CrashReason:Stack ->
            logger:error("user_input_handler crashed: ~p:~p~n~p",
                         [Class, CrashReason, Stack]),
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input handler crashed">>}
    end;
build_inbound_response(<<"elicitation">>, _Request, _HState) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => <<"No user input handler registered">>};
build_inbound_response(_, _Request, _HState) ->
    #{<<"subtype">> => <<"ok">>}.

%%====================================================================
%% Internal: permission handling
%%====================================================================

-spec fire_permission_hooks(map(),
                            beam_agent_hooks_core:hook_registry() | undefined) ->
    ok | {deny, binary()}.
fire_permission_hooks(HookCtx, HookReg) ->
    case beam_agent_hooks_core:fire(permission_request,
                                    HookCtx#{event => permission_request},
                                    HookReg) of
        {deny, Reason} ->
            {deny, Reason};
        ok ->
            beam_agent_hooks_core:fire(pre_tool_use,
                                       HookCtx#{event => pre_tool_use},
                                       HookReg)
    end.

-spec normalize_permission_handler_response(
    {allow, map()} | {allow, map(), [map()] | map()} |
    {deny, binary()} | {deny, binary(), boolean()} | map(),
    map()) -> #{<<_:56, _:_*8>> => boolean() | binary() | maybe_improper_list() | map()}.
normalize_permission_handler_response({allow, UpdatedInput}, OriginalInput) ->
    approve_permission_response(UpdatedInput, OriginalInput, #{});
normalize_permission_handler_response({allow, UpdatedInput, Third},
                                      OriginalInput) when is_list(Third) ->
    approve_permission_response(UpdatedInput, OriginalInput,
                                #{<<"updatedPermissions">> => Third});
normalize_permission_handler_response({allow, UpdatedInput, Third},
                                      OriginalInput) when is_map(Third) ->
    approve_permission_response(UpdatedInput, OriginalInput,
                                normalize_permission_result_map(Third));
normalize_permission_handler_response({deny, Reason}, _OriginalInput)
  when is_binary(Reason) ->
    #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
normalize_permission_handler_response({deny, Reason, Interrupt},
                                      _OriginalInput)
  when is_binary(Reason), is_boolean(Interrupt) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => Reason,
      <<"interrupt">> => Interrupt};
normalize_permission_handler_response(Map, OriginalInput) when is_map(Map) ->
    normalize_permission_result_map(Map, OriginalInput);
normalize_permission_handler_response(_, _OriginalInput) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => <<"Invalid permission handler response">>}.

-spec approve_permission_response(
    term(),
    map(),
    #{<<_:56, _:_*8>> => true | binary() | maybe_improper_list() | map()}) ->
    #{<<_:56, _:_*8>> => true | binary() | maybe_improper_list() | map()}.
approve_permission_response(UpdatedInput, OriginalInput, Extra) ->
    Input = case UpdatedInput of
        undefined   -> OriginalInput;
        null        -> OriginalInput;
        M when is_map(M) -> M;
        _           -> OriginalInput
    end,
    maps:merge(#{<<"subtype">> => <<"approve">>,
                 <<"updatedInput">> => Input}, Extra).

-spec normalize_permission_result_map(map()) ->
    #{<<_:56, _:_*8>> => true | binary() | maybe_improper_list() | map()}.
normalize_permission_result_map(Map) ->
    normalize_permission_result_map(Map, #{}).

-spec normalize_permission_result_map(map(), map()) ->
    #{<<_:56, _:_*8>> => true | binary() | maybe_improper_list() | map()}.
normalize_permission_result_map(Map, OriginalInput) ->
    Behavior0 = maps:get(behavior, Map,
                 maps:get(<<"behavior">>, Map,
                 maps:get(permission_decision, Map,
                 maps:get(<<"permissionDecision">>, Map, allow)))),
    Behavior = normalize_permission_behavior(Behavior0),
    UpdatedInput = maps:get(updated_input, Map,
                   maps:get(<<"updatedInput">>, Map,
                   maps:get(input, Map, OriginalInput))),
    Message = maps:get(message, Map,
              maps:get(reason, Map,
              maps:get(<<"message">>, Map,
              maps:get(<<"reason">>, Map, <<>>)))),
    Interrupt = maps:get(interrupt, Map,
                maps:get(<<"interrupt">>, Map, false)),
    UpdatedPermissions = maps:get(updated_permissions, Map,
                        maps:get(<<"updatedPermissions">>, Map, undefined)),
    RuleUpdate = maps:get(rule_update, Map,
                 maps:get(<<"ruleUpdate">>, Map, undefined)),
    case Behavior of
        deny ->
            Response0 = #{<<"subtype">> => <<"deny">>,
                          <<"message">> => ensure_binary(Message)},
            case Interrupt of
                true -> Response0#{<<"interrupt">> => true};
                _    -> Response0
            end;
        _ ->
            Extra0 = case UpdatedPermissions of
                Perms when is_list(Perms) ->
                    #{<<"updatedPermissions">> => Perms};
                _ -> #{}
            end,
            Extra = case RuleUpdate of
                Rule when is_map(Rule) ->
                    Extra0#{<<"ruleUpdate">> => Rule};
                _ -> Extra0
            end,
            approve_permission_response(UpdatedInput, OriginalInput, Extra)
    end.

-spec normalize_permission_behavior(term()) -> allow | deny.
normalize_permission_behavior(allow)        -> allow;
normalize_permission_behavior(approve)      -> allow;
normalize_permission_behavior(<<"allow">>)  -> allow;
normalize_permission_behavior(<<"approve">>) -> allow;
normalize_permission_behavior(deny)         -> deny;
normalize_permission_behavior(block)        -> deny;
normalize_permission_behavior(<<"deny">>)   -> deny;
normalize_permission_behavior(<<"block">>)  -> deny;
normalize_permission_behavior(_)            -> allow.

%%====================================================================
%% Internal: hook callback handling
%%====================================================================

-spec handle_hook_callback(map(), #{binary() => fun()}, binary() | undefined) ->
    map().
handle_hook_callback(Request, HookCallbacks, SessionId) ->
    CallbackId = maps:get(<<"callback_id">>, Request,
                 maps:get(callback_id, Request, undefined)),
    Input = maps:get(<<"input">>, Request,
            maps:get(input, Request, #{})),
    ToolUseId = maps:get(<<"tool_use_id">>, Request,
                maps:get(tool_use_id, Request, undefined)),
    Context = #{session_id => SessionId,
                signal => undefined,
                request => Request},
    case maps:get(CallbackId, HookCallbacks, undefined) of
        undefined ->
            logger:warning("Claude hook callback missing: ~p", [CallbackId]),
            #{<<"decision">> => <<"block">>,
              <<"reason">> => <<"Hook callback not found">>};
        Callback ->
            try invoke_hook_callback(Callback, Input, ToolUseId, Context) of
                Result -> normalize_hook_output(Result)
            catch
                Class:Reason:Stack ->
                    logger:error("hook callback crashed: ~p:~p~n~p",
                                 [Class, Reason, Stack]),
                    #{<<"decision">> => <<"block">>,
                      <<"reason">> => <<"Hook callback crashed">>}
            end
    end.

-spec invoke_hook_callback(fun(), term(), term(),
                          #{request := map(),
                            session_id := undefined | binary(),
                            signal := undefined}) -> any().
invoke_hook_callback(Callback, Input, ToolUseId, Context)
  when is_function(Callback, 3) ->
    Callback(Input, ToolUseId, Context);
invoke_hook_callback(Callback, Input, ToolUseId, Context)
  when is_function(Callback, 1) ->
    Callback(Context#{input => Input, tool_use_id => ToolUseId});
invoke_hook_callback(Callback, _Input, _ToolUseId, _Context) ->
    Callback().

-spec normalize_hook_output(term()) -> map().
normalize_hook_output(ok) -> #{};
normalize_hook_output({ok, Map}) when is_map(Map) ->
    normalize_hook_map(Map, top);
normalize_hook_output({deny, Reason}) when is_binary(Reason) ->
    #{<<"decision">> => <<"block">>, <<"reason">> => Reason};
normalize_hook_output(Map) when is_map(Map) ->
    normalize_hook_map(Map, top);
normalize_hook_output(_) -> #{}.

-spec normalize_hook_map(map(), top | hook_specific | generic) -> map().
normalize_hook_map(Map, Kind) ->
    maps:fold(fun(Key, Value, Acc) ->
        EncodedKey = normalize_hook_key(Key, Kind),
        EncodedValue = normalize_hook_value(EncodedKey, Value, Kind),
        Acc#{EncodedKey => EncodedValue}
    end, #{}, Map).

-spec normalize_hook_key(term(), top | hook_specific | generic) -> binary().
normalize_hook_key(async_, top)                        -> <<"async">>;
normalize_hook_key(async, top)                         -> <<"async">>;
normalize_hook_key(continue_, top)                     -> <<"continue">>;
normalize_hook_key(continue, top)                      -> <<"continue">>;
normalize_hook_key(suppress_output, top)               -> <<"suppressOutput">>;
normalize_hook_key(<<"suppressOutput">>, top)           -> <<"suppressOutput">>;
normalize_hook_key(stop_reason, top)                   -> <<"stopReason">>;
normalize_hook_key(<<"stopReason">>, top)               -> <<"stopReason">>;
normalize_hook_key(system_message, top)                -> <<"systemMessage">>;
normalize_hook_key(<<"systemMessage">>, top)            -> <<"systemMessage">>;
normalize_hook_key(hook_specific_output, top)          -> <<"hookSpecificOutput">>;
normalize_hook_key(<<"hookSpecificOutput">>, top)       -> <<"hookSpecificOutput">>;
normalize_hook_key(hook_event_name, hook_specific)     -> <<"hookEventName">>;
normalize_hook_key(<<"hookEventName">>, hook_specific)  -> <<"hookEventName">>;
normalize_hook_key(permission_decision, hook_specific) -> <<"permissionDecision">>;
normalize_hook_key(<<"permissionDecision">>, hook_specific) -> <<"permissionDecision">>;
normalize_hook_key(permission_decision_reason, hook_specific) -> <<"permissionDecisionReason">>;
normalize_hook_key(<<"permissionDecisionReason">>, hook_specific) -> <<"permissionDecisionReason">>;
normalize_hook_key(updated_input, hook_specific)       -> <<"updatedInput">>;
normalize_hook_key(<<"updatedInput">>, hook_specific)   -> <<"updatedInput">>;
normalize_hook_key(updated_permissions, hook_specific) -> <<"updatedPermissions">>;
normalize_hook_key(<<"updatedPermissions">>, hook_specific) -> <<"updatedPermissions">>;
normalize_hook_key(interrupt, hook_specific)            -> <<"interrupt">>;
normalize_hook_key(<<"interrupt">>, hook_specific)      -> <<"interrupt">>;
normalize_hook_key(additional_context, hook_specific)   -> <<"additionalContext">>;
normalize_hook_key(<<"additionalContext">>, hook_specific) -> <<"additionalContext">>;
normalize_hook_key(updated_mcp_tool_output, hook_specific) -> <<"updatedMCPToolOutput">>;
normalize_hook_key(<<"updatedMCPToolOutput">>, hook_specific) -> <<"updatedMCPToolOutput">>;
normalize_hook_key(Key, _Kind) when is_binary(Key) -> Key;
normalize_hook_key(Key, _Kind) when is_atom(Key) -> atom_to_binary(Key);
normalize_hook_key(Key, _Kind) when is_list(Key) ->
    unicode:characters_to_binary(Key);
normalize_hook_key(Key, _Kind) ->
    unicode:characters_to_binary(io_lib:format("~p", [Key])).

-spec normalize_hook_value(binary(), term(), hook_specific | top) -> any().
normalize_hook_value(<<"hookSpecificOutput">>, Value, _Kind)
  when is_map(Value) ->
    normalize_hook_map(Value, hook_specific);
normalize_hook_value(_Key, Value, _Kind) ->
    normalize_hook_init_value(Value).

-spec normalize_hook_init_value(term()) -> term().
normalize_hook_init_value(Value) when is_map(Value) ->
    maps:fold(fun(Key, Inner, Acc) ->
        NKey = normalize_hook_key(Key, generic),
        Acc#{NKey => normalize_hook_init_value(Inner)}
    end, #{}, Value);
normalize_hook_init_value(Value) when is_list(Value) ->
    case lists:all(fun erlang:is_integer/1, Value) of
        true  -> unicode:characters_to_binary(Value);
        false -> [normalize_hook_init_value(Item) || Item <- Value]
    end;
normalize_hook_init_value(Value)
  when is_atom(Value), Value =/= true, Value =/= false, Value =/= null ->
    atom_to_binary(Value);
normalize_hook_init_value(Value) ->
    Value.

%%====================================================================
%% Internal: CLI hooks config building
%%====================================================================

-spec build_cli_hooks(map() | undefined) -> {map() | null, #{binary() => fun()}}.
build_cli_hooks(undefined) ->
    {null, #{}};
build_cli_hooks(Hooks) when is_map(Hooks) ->
    {Config0, Callbacks} =
        maps:fold(fun build_cli_hook_event/3, {#{}, #{}}, Hooks),
    case map_size(Config0) of
        0 -> {null, Callbacks};
        _ -> {Config0, Callbacks}
    end;
build_cli_hooks(_) ->
    {null, #{}}.

-spec build_cli_hook_event(term(), term(), {map(), #{binary() => fun()}}) ->
    {map(), #{binary() => fun()}}.
build_cli_hook_event(EventKey, Matchers0, {ConfigAcc, CallbackAcc}) ->
    EventName = hook_event_name(EventKey),
    {MatchersRev, Callbacks} = build_cli_hook_matchers(Matchers0),
    Matchers = lists:reverse(MatchersRev),
    case Matchers of
        [] -> {ConfigAcc, maps:merge(CallbackAcc, Callbacks)};
        _  -> {ConfigAcc#{EventName => Matchers},
               maps:merge(CallbackAcc, Callbacks)}
    end.

-spec build_cli_hook_matchers(term()) -> {[map()], #{binary() => fun()}}.
build_cli_hook_matchers(Matchers) when is_list(Matchers) ->
    lists:foldl(fun(Matcher, {MatcherAcc, CallbackAcc}) ->
        case build_cli_hook_matcher(Matcher) of
            skip -> {MatcherAcc, CallbackAcc};
            {Config, Cbs} -> {[Config | MatcherAcc],
                               maps:merge(CallbackAcc, Cbs)}
        end
    end, {[], #{}}, Matchers);
build_cli_hook_matchers(Matcher) ->
    build_cli_hook_matchers([Matcher]).

-spec build_cli_hook_matcher(term()) -> skip | {#{<<_:56, _:_*64>> => _}, #{binary() => fun()}}.
build_cli_hook_matcher(Matcher)
  when is_function(Matcher, 1); is_function(Matcher, 3) ->
    {CallbackId, Callback} = new_hook_callback(Matcher),
    {#{<<"matcher">> => null, <<"hookCallbackIds">> => [CallbackId]},
     #{CallbackId => Callback}};
build_cli_hook_matcher(Matcher) when is_map(Matcher) ->
    HooksValue = maps:get(hooks, Matcher,
                 maps:get(<<"hooks">>, Matcher, [])),
    ExistingIds = maps:get(hookCallbackIds, Matcher,
                  maps:get(<<"hookCallbackIds">>, Matcher, [])),
    {CallbackIdsRev, CallbackMap} =
        build_hook_callback_ids(HooksValue, ExistingIds),
    CallbackIds = lists:reverse(CallbackIdsRev),
    Config0 = case maps:get(matcher, Matcher,
                   maps:get(<<"matcher">>, Matcher, undefined)) of
        undefined -> #{};
        Value     -> #{<<"matcher">> => normalize_hook_init_value(Value)}
    end,
    Config1 = case CallbackIds of
        [] -> Config0;
        _  -> Config0#{<<"hookCallbackIds">> => CallbackIds}
    end,
    Config2 = case maps:get(timeout, Matcher,
                   maps:get(<<"timeout">>, Matcher, undefined)) of
        Timeout when is_integer(Timeout), Timeout > 0 ->
            Config1#{<<"timeout">> => Timeout};
        _ -> Config1
    end,
    case map_size(Config2) of
        0 -> skip;
        _ -> {Config2, CallbackMap}
    end;
build_cli_hook_matcher(_) ->
    skip.

-spec build_hook_callback_ids(term(), term()) ->
    {[binary()], #{binary() => fun()}}.
build_hook_callback_ids(HooksValue, ExistingIds0) ->
    ExistingIds = lists:foldl(fun(Id, Acc) ->
        case normalize_callback_id(Id) of
            NId when is_binary(NId), byte_size(NId) > 0 -> [NId | Acc];
            _ -> Acc
        end
    end, [], normalize_list(ExistingIds0)),
    lists:foldl(fun(Hook, {IdsAcc, CallbackAcc}) ->
        case Hook of
            Fun when is_function(Fun, 1); is_function(Fun, 3) ->
                {CallbackId, Callback} = new_hook_callback(Fun),
                {[CallbackId | IdsAcc],
                 CallbackAcc#{CallbackId => Callback}};
            Id ->
                case normalize_callback_id(Id) of
                    NId when is_binary(NId), byte_size(NId) > 0 ->
                        {[NId | IdsAcc], CallbackAcc};
                    _ ->
                        {IdsAcc, CallbackAcc}
                end
        end
    end, {ExistingIds, #{}}, normalize_list(HooksValue)).

-spec normalize_callback_id(term()) -> binary() | term().
normalize_callback_id(Id) when is_binary(Id) -> Id;
normalize_callback_id(Id) when is_list(Id) ->
    unicode:characters_to_binary(Id);
normalize_callback_id(Id) -> Id.

-spec normalize_list(term()) -> [term()].
normalize_list(undefined)          -> [];
normalize_list(null)               -> [];
normalize_list(List) when is_list(List) -> List;
normalize_list(Value)              -> [Value].

-spec new_hook_callback(fun()) -> {<<_:40, _:_*8>>, fun()}.
new_hook_callback(Callback) ->
    Id = <<"hook_",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {Id, Callback}.

-spec hook_event_name(term()) -> binary().
hook_event_name(Name) when is_binary(Name) -> Name;
hook_event_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name);
hook_event_name(Name) when is_atom(Name) ->
    snake_to_pascal_binary(atom_to_list(Name));
hook_event_name(Name) ->
    unicode:characters_to_binary(io_lib:format("~p", [Name])).

-spec snake_to_pascal_binary(string()) -> binary().
snake_to_pascal_binary(Name) ->
    Parts = string:tokens(Name, "_"),
    iolist_to_binary([capitalize_ascii(Part) || Part <- Parts, Part =/= []]).

-spec capitalize_ascii([byte(), ...]) -> binary().
capitalize_ascii([H | T]) when H >= $a, H =< $z ->
    list_to_binary([H - 32 | T]);
capitalize_ascii(List) ->
    list_to_binary(List).

%%====================================================================
%% Internal: query message building
%%====================================================================

-spec build_query_message(binary(), beam_agent_core:query_opts()) -> map().
build_query_message(Prompt, Params) ->
    Base = #{<<"type">> => <<"user">>,
             <<"message">> =>
                 #{<<"role">> => <<"user">>, <<"content">> => Prompt}},
    maps:fold(fun(system_prompt, V, Acc) when is_binary(V) ->
                      Acc#{<<"system_prompt">> => V};
                 (allowed_tools, V, Acc)    -> Acc#{<<"allowedTools">> => V};
                 (disallowed_tools, V, Acc) -> Acc#{<<"disallowedTools">> => V};
                 (max_tokens, V, Acc)       -> Acc#{<<"maxTokens">> => V};
                 (max_turns, V, Acc)        -> Acc#{<<"maxTurns">> => V};
                 (model, V, Acc)            -> Acc#{<<"model">> => V};
                 (output_format, V, Acc)    -> Acc#{<<"outputFormat">> => V};
                 (effort, V, Acc)           -> Acc#{<<"effort">> => V};
                 (agent, V, Acc)            -> Acc#{<<"agent">> => V};
                 (max_budget_usd, V, Acc)   -> Acc#{<<"maxBudgetUsd">> => V};
                 (_Key, _V, Acc)            -> Acc
              end, Base, Params).

%%====================================================================
%% Internal: init request building
%%====================================================================

-spec build_init_request(map(),
                         beam_agent_tool_registry:mcp_registry() | undefined,
                         map() | null) -> map().
build_init_request(Opts, McpRegistry, HookConfig) ->
    Base = #{<<"subtype">> => <<"initialize">>,
             <<"hooks">> => HookConfig,
             <<"agents">> => encode_value(maps:get(agents, Opts, #{}))},
    Additions = [{output_format, <<"outputFormat">>},
                 {mcp_servers, <<"mcpServers">>},
                 {plugins, <<"plugins">>},
                 {setting_sources, <<"settingSources">>},
                 {thinking, <<"thinking">>},
                 {sandbox, <<"sandbox">>},
                 {betas, <<"betas">>},
                 {effort, <<"effort">>},
                 {enable_file_checkpointing, <<"enableFileCheckpointing">>},
                 {prompt_suggestions, <<"promptSuggestions">>},
                 {include_partial_messages, <<"includePartialMessages">>},
                 {persist_session, <<"persistSession">>}],
    M1 = lists:foldl(fun({OptKey, WireKey}, Acc) ->
        case maps:get(OptKey, Opts, undefined) of
            undefined -> Acc;
            Value     -> Acc#{WireKey => encode_value(Value)}
        end
    end, Base, Additions),
    M2 = case McpRegistry of
        undefined -> M1;
        Reg when is_map(Reg), map_size(Reg) > 0 ->
            Names = beam_agent_tool_registry:servers_for_init(Reg),
            M1#{<<"sdkMcpServers">> => Names};
        _ -> M1
    end,
    case maps:get(system_prompt, Opts, undefined) of
        #{type := preset} = SP ->
            M2#{<<"systemPrompt">> => encode_system_prompt(SP)};
        _ -> M2
    end.

%%====================================================================
%% Internal: CLI args building
%%====================================================================

-spec build_cli_args(map(), string() | undefined) -> [string()].
build_cli_args(Opts, McpConfigPath) ->
    Base = ["--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose"],
    lists:append([Base,
                  session_id_args(Opts),
                  resume_args(Opts),
                  fork_session_args(Opts),
                  model_args(Opts),
                  fallback_model_args(Opts),
                  system_prompt_args(Opts),
                  max_turns_args(Opts),
                  permission_mode_args(Opts),
                  permission_prompt_tool_args(Opts),
                  tool_args(Opts),
                  settings_args(Opts),
                  add_dirs_args(Opts),
                  budget_args(Opts),
                  debug_args(Opts),
                  extra_args(Opts),
                  sdk_mcp_args(McpConfigPath)]).

-spec session_id_args(map()) -> [string()].
session_id_args(Opts) ->
    case maps:get(session_id, Opts, undefined) of
        undefined          -> [];
        Id when is_binary(Id) -> ["--session-id", binary_to_list(Id)];
        Id when is_list(Id)   -> ["--session-id", Id]
    end.

-spec resume_args(map()) -> [[byte()]].
resume_args(Opts) ->
    R = case maps:get(resume, Opts, false) of
            true  -> ["--resume"];
            false -> []
        end,
    C = case maps:get(continue, Opts, false) of
            true  -> ["--continue"];
            false -> []
        end,
    R ++ C.

-spec fork_session_args(map()) -> [[byte()]].
fork_session_args(Opts) ->
    case maps:get(fork_session, Opts, false) of
        true  -> ["--fork-session"];
        false -> []
    end.

-spec model_args(map()) -> [string()].
model_args(Opts) ->
    case maps:get(model, Opts, undefined) of
        undefined             -> [];
        Model when is_binary(Model) -> ["--model", binary_to_list(Model)];
        Model when is_list(Model)   -> ["--model", Model]
    end.

-spec fallback_model_args(map()) -> [string()].
fallback_model_args(Opts) ->
    case maps:get(fallback_model, Opts, undefined) of
        undefined             -> [];
        Model when is_binary(Model) -> ["--fallback-model",
                                         binary_to_list(Model)];
        Model when is_list(Model)   -> ["--fallback-model", Model]
    end.

-spec system_prompt_args(map()) -> [string()].
system_prompt_args(Opts) ->
    case maps:get(system_prompt, Opts, undefined) of
        undefined        -> [];
        #{type := preset} -> [];
        SP when is_binary(SP) -> ["--system-prompt", binary_to_list(SP)];
        SP when is_list(SP)   -> ["--system-prompt", SP]
    end.

-spec max_turns_args(map()) -> [string()].
max_turns_args(Opts) ->
    case maps:get(max_turns, Opts, undefined) of
        undefined               -> [];
        MT when is_integer(MT)  -> ["--max-turns", integer_to_list(MT)]
    end.

-spec permission_mode_args(map()) -> [[byte()]].
permission_mode_args(Opts) ->
    case maps:get(permission_mode, Opts, undefined) of
        undefined        -> [];
        PM when is_atom(PM) ->
            ["--permission-mode",
             binary_to_list(encode_permission_mode(PM))];
        PM when is_binary(PM) ->
            ["--permission-mode", binary_to_list(PM)]
    end.

-spec permission_prompt_tool_args(map()) -> [string()].
permission_prompt_tool_args(Opts) ->
    case maps:get(permission_prompt_tool_name, Opts, undefined) of
        undefined              -> [];
        Tool when is_binary(Tool) -> ["--permission-prompt-tool",
                                       binary_to_list(Tool)];
        Tool when is_list(Tool)   -> ["--permission-prompt-tool", Tool]
    end.

-spec tool_args(map()) -> [string()].
tool_args(Opts) ->
    Tools = case maps:get(tools, Opts, undefined) of
        undefined -> [];
        ToolList when is_list(ToolList) ->
            ["--tools",
             string:join([binary_to_list(T) || T <- ToolList], ",")];
        #{type := preset, preset := _Preset} ->
            ["--tools", "default"];
        Preset when is_binary(Preset) ->
            ["--tools", binary_to_list(Preset)];
        Preset when is_list(Preset) ->
            ["--tools", Preset]
    end,
    AT = case maps:get(allowed_tools, Opts, undefined) of
        undefined -> [];
        ATools when is_list(ATools) ->
            ["--allowedTools",
             binary_to_list(iolist_to_binary(json:encode(ATools)))]
    end,
    DT = case maps:get(disallowed_tools, Opts, undefined) of
        undefined -> [];
        DTools when is_list(DTools) ->
            ["--disallowedTools",
             binary_to_list(iolist_to_binary(json:encode(DTools)))]
    end,
    Tools ++ AT ++ DT.

-spec settings_args(map()) -> [[byte()]].
settings_args(Opts) ->
    case build_settings_value(Opts) of
        undefined -> [];
        Value     -> ["--settings", binary_to_list(Value)]
    end.

-spec add_dirs_args(map()) -> [string()].
add_dirs_args(Opts) ->
    case maps:get(add_dirs, Opts, undefined) of
        undefined -> [];
        Dirs when is_list(Dirs) ->
            lists:append([["--add-dir", resolve_cli_path(Dir)]
                          || Dir <- Dirs]);
        _ -> []
    end.

-spec budget_args(map()) -> [string()].
budget_args(Opts) ->
    case maps:get(max_budget_usd, Opts, undefined) of
        undefined -> [];
        Budget when is_number(Budget) ->
            ["--max-budget-usd",
             float_to_list(Budget * 1.0, [{decimals, 4}])]
    end.

-spec debug_args(map()) -> [[byte()]].
debug_args(Opts) ->
    D = case maps:get(debug, Opts, false) of
            true  -> ["--debug"];
            false -> []
        end,
    DF = case maps:get(debug_file, Opts, undefined) of
        undefined              -> [];
        File when is_binary(File) -> ["--debug-file", binary_to_list(File)]
    end,
    D ++ DF.

-spec extra_args(map()) -> [string()].
extra_args(Opts) ->
    case maps:get(extra_args, Opts, undefined) of
        undefined -> [];
        ExtraMap when is_map(ExtraMap) ->
            maps:fold(fun(Key, null, Acc) ->
                [binary_to_list(iolist_to_binary(["--", Key])) | Acc];
            (Key, Val, Acc) ->
                [binary_to_list(iolist_to_binary(["--", Key])),
                 binary_to_list(Val) | Acc]
            end, [], ExtraMap)
    end.

-spec sdk_mcp_args(nonempty_string() | undefined) -> [nonempty_string()].
sdk_mcp_args(undefined) -> [];
sdk_mcp_args(Path) when is_list(Path) -> ["--mcp-config", Path].

%%====================================================================
%% Internal: settings building
%%====================================================================

-spec build_settings_value(map()) -> binary() | undefined.
build_settings_value(Opts) ->
    Settings = maps:get(settings, Opts, undefined),
    Sandbox = maps:get(sandbox, Opts, undefined),
    case {Settings, Sandbox} of
        {undefined, undefined} -> undefined;
        {Value, undefined} when is_binary(Value) -> Value;
        {Value, undefined} when is_list(Value) -> list_to_binary(Value);
        _ ->
            SettingsObj0 = load_settings_object(Settings),
            SettingsObj = case Sandbox of
                SandboxMap when is_map(SandboxMap) ->
                    SettingsObj0#{<<"sandbox">> =>
                                     normalize_json_map(SandboxMap)};
                _ -> SettingsObj0
            end,
            iolist_to_binary(json:encode(SettingsObj))
    end.

-spec load_settings_object(term()) -> #{binary() => _}.
load_settings_object(undefined)                   -> #{};
load_settings_object(Value) when is_map(Value)    -> normalize_json_map(Value);
load_settings_object(Value) when is_binary(Value) -> load_settings_binary(Value);
load_settings_object(Value) when is_list(Value)   ->
    load_settings_binary(list_to_binary(Value));
load_settings_object(_)                           -> #{}.

-spec load_settings_binary(binary()) ->
    #{binary() => false | null | true | binary() | [any()] | number() | #{binary() => _}}.
load_settings_binary(Value) ->
    Trimmed = string:trim(Value),
    case looks_like_json(Trimmed) of
        true  -> decode_settings_json(Trimmed);
        false ->
            case file:read_file(Trimmed) of
                {ok, Contents} -> decode_settings_json(Contents);
                _              -> #{}
            end
    end.

-spec looks_like_json(binary()) -> boolean().
looks_like_json(<<"{", _/binary>>) -> true;
looks_like_json(_)                 -> false.

-spec decode_settings_json(binary()) ->
    #{binary() => false | null | true | binary() | [any()] | number() | #{binary() => _}}.
decode_settings_json(JsonBin) ->
    try json:decode(JsonBin) of
        Map when is_map(Map) -> Map;
        _                    -> #{}
    catch _:_ -> #{}
    end.

-spec normalize_json_map(map()) -> #{binary() => _}.
normalize_json_map(Map) ->
    maps:from_list([{normalize_json_key(Key), normalize_json_value(Value)}
                    || {Key, Value} <- maps:to_list(Map)]).

-spec normalize_json_value(term()) -> term().
normalize_json_value(Value) when is_map(Value)  -> normalize_json_map(Value);
normalize_json_value(Value) when is_list(Value) ->
    [normalize_json_value(Item) || Item <- Value];
normalize_json_value(Value) when is_atom(Value) -> atom_to_binary(Value);
normalize_json_value(Value)                     -> Value.

-spec normalize_json_key(term()) -> binary().
normalize_json_key(Key) when is_binary(Key) -> Key;
normalize_json_key(Key) when is_atom(Key)   -> atom_to_binary(Key);
normalize_json_key(Key) when is_list(Key)   ->
    unicode:characters_to_binary(Key);
normalize_json_key(Key) ->
    unicode:characters_to_binary(io_lib:format("~p", [Key])).

%%====================================================================
%% Internal: port opts & env
%%====================================================================

-spec build_env(map()) -> [{string(), string()}].
build_env(Opts) ->
    SdkEnv = [{"CLAUDE_CODE_ENTRYPOINT", "sdk-erl"},
              {"CLAUDE_AGENT_SDK_VERSION", "0.1.0"}],
    ClientAppEnv = case maps:get(client_app, Opts, undefined) of
        undefined              -> [];
        App when is_binary(App) ->
            [{"CLAUDE_AGENT_SDK_CLIENT_APP", binary_to_list(App)}]
    end,
    UserEnv = maps:get(env, Opts, []),
    SdkEnv ++ ClientAppEnv ++ UserEnv.

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

-spec resolve_cli_path(file:filename_all()) -> string().
resolve_cli_path(Path) when is_binary(Path) -> binary_to_list(Path);
resolve_cli_path(Path) when is_list(Path)   -> Path;
resolve_cli_path(Path) when is_atom(Path)   -> atom_to_list(Path).

%%====================================================================
%% Internal: MCP config file management
%%====================================================================

-spec write_mcp_config(beam_agent_tool_registry:mcp_registry() | undefined) ->
    string() | undefined.
write_mcp_config(undefined) -> undefined;
write_mcp_config(Registry) when map_size(Registry) =:= 0 -> undefined;
write_mcp_config(Registry) ->
    ConfigMap = beam_agent_tool_registry:servers_for_cli(Registry),
    TmpPath = "/tmp/beam_sdk_mcp_"
              ++ integer_to_list(erlang:unique_integer([positive]))
              ++ ".json",
    JsonBin = iolist_to_binary(json:encode(ConfigMap)),
    ok = file:write_file(TmpPath, JsonBin),
    TmpPath.

-spec cleanup_mcp_config(string() | undefined) -> ok.
cleanup_mcp_config(undefined)                 -> ok;
cleanup_mcp_config(Path) when is_list(Path)   -> _ = file:delete(Path), ok.

%%====================================================================
%% Internal: message tracking
%%====================================================================

-spec track_message(beam_agent_core:message(), #hstate{}) -> ok.
track_message(Msg, #hstate{session_id = SessionId}) ->
    StoreId = session_store_id(SessionId),
    ok = beam_agent_session_store_core:register_session(StoreId,
                                                         #{adapter => claude}),
    StoredMsg = maybe_tag_session_id(Msg, StoreId),
    case beam_agent_threads_core:active_thread(StoreId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(StoreId,
                                                           ThreadId,
                                                           StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(StoreId, StoredMsg)
    end,
    ok.

-spec session_store_id(binary() | undefined) -> binary().
session_store_id(SessionId) when is_binary(SessionId),
                                  byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_) ->
    unicode:characters_to_binary(pid_to_list(self())).

-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
    beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) -> Msg;
maybe_tag_session_id(Msg, SessionId) -> Msg#{session_id => SessionId}.

%%====================================================================
%% Internal: encoding helpers
%%====================================================================

-spec encode_system_prompt(#{preset := _, type := preset, _ => _}) ->
    #{<<_:32, _:_*16>> => _}.
encode_system_prompt(#{type := preset, preset := Preset} = SP) ->
    Base = #{<<"type">> => <<"preset">>, <<"preset">> => Preset},
    case maps:get(append, SP, undefined) of
        undefined -> Base;
        Append    -> Base#{<<"append">> => Append}
    end.

-spec encode_permission_mode(beam_agent_core:permission_mode()) -> <<_:32, _:_*8>>.
encode_permission_mode(default)            -> <<"default">>;
encode_permission_mode(accept_edits)       -> <<"acceptEdits">>;
encode_permission_mode(bypass_permissions) -> <<"bypassPermissions">>;
encode_permission_mode(plan)               -> <<"plan">>;
encode_permission_mode(dont_ask)           -> <<"dontAsk">>.

-spec encode_value(term()) -> term().
encode_value(V) when is_atom(V), V =/= true, V =/= false, V =/= null ->
    atom_to_binary(V);
encode_value(V) -> V.

-spec maybe_put_defined(agent_id | session_id, term(),
                        #{permission_prompt_tool_name := _,
                          permission_suggestions := _,
                          tool_input := _,
                          tool_name := _,
                          tool_use_id := _,
                          agent_id => _,
                          session_id => _}) ->
    #{permission_prompt_tool_name := _,
      permission_suggestions := _,
      tool_input := _,
      tool_name := _,
      tool_use_id := _,
      agent_id => _,
      session_id => _}.
maybe_put_defined(_Key, undefined, Map) -> Map;
maybe_put_defined(Key, Value, Map)      -> Map#{Key => Value}.

-spec ensure_binary(term()) -> binary().
ensure_binary(Value) when is_binary(Value)  -> Value;
ensure_binary(Value) when is_list(Value)    ->
    unicode:characters_to_binary(Value);
ensure_binary(Value) when is_atom(Value)    -> atom_to_binary(Value);
ensure_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
ensure_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).
