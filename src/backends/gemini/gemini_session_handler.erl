-module(gemini_session_handler).
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
    handle_initializing/2,
    encode_interrupt/1,
    handle_set_permission_mode/2,
    on_state_enter/3,
    is_query_complete/2
]).

%%--------------------------------------------------------------------
%% Handler state
%%--------------------------------------------------------------------

-type pending_entry() ::
    init
  | auth
  | session_start
  | prompt
  | {set_mode, gen_statem:from() | undefined, binary()}
  | {set_mode_auto, binary()}.

-record(hstate, {
    %% Transport ref (stored via transport_started/2 for SIGINT)
    port_ref              :: port() | undefined,

    %% Pending JSON-RPC responses: request_id => pending_entry()
    pending = #{}         :: #{integer() => pending_entry()},

    %% Gemini session identity (from session/start response)
    session_id            :: binary() | undefined,

    %% CLI configuration
    cli_path              :: string(),
    opts                  :: map(),
    model                 :: binary() | undefined,

    %% Approval / permission mode
    approval_mode         :: binary() | undefined,
    current_mode          :: binary() | undefined,
    available_modes = []  :: [map()],

    %% Model metadata
    current_model         :: binary() | undefined,
    available_models = [] :: [map()],

    %% Session metadata
    available_commands = [] :: [map()],
    title                 :: binary() | undefined,
    updated_at            :: binary() | undefined,

    %% Init response (from initialize request)
    init_response = #{}   :: map(),

    %% SDK registries
    sdk_mcp_registry      :: beam_agent_tool_registry:mcp_registry() | undefined,
    sdk_hook_registry     :: beam_agent_hooks_core:hook_registry() | undefined,

    %% Cancel tracking
    cancel_requested = false :: boolean()
}).

%%====================================================================
%% Required callbacks
%%====================================================================

-doc "Return the backend identifier.".
-spec backend_name() -> gemini.
backend_name() -> gemini.

-doc "Initialize the handler — build transport spec and handler state.".
-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    CliPath = maps:get(cli_path, Opts,
                       os:getenv("GEMINI_CLI_PATH", "gemini")),
    Model = maps:get(model, Opts, undefined),
    ApprovalMode = normalize_approval_mode(
                       maps:get(approval_mode, Opts,
                                maps:get(permission_mode, Opts, undefined))),
    McpRegistry = beam_agent_tool_registry:build_registry(
                      maps:get(sdk_mcp_servers, Opts, undefined)),
    HookRegistry = beam_agent_hooks_core:build_registry(
                       maps:get(sdk_hooks, Opts, undefined)),
    Args = build_cli_args(Model, ApprovalMode, Opts),
    TransportOpts = #{
        executable => CliPath,
        args       => Args,
        env        => [{"GEMINI_CLI_SDK_VERSION", "beam-0.1.0"},
                       {"NO_COLOR", "1"}]
                      ++ maps:get(env, Opts, []),
        cd         => maps:get(work_dir, Opts, undefined),
        mode       => line,
        line_buffer => 65_536
    },
    HState = #hstate{
        cli_path          = CliPath,
        opts              = Opts,
        model             = Model,
        approval_mode     = ApprovalMode,
        current_mode      = ApprovalMode,
        sdk_mcp_registry  = McpRegistry,
        sdk_hook_registry = HookRegistry
    },
    {ok, #{
        transport_spec => {beam_agent_transport_port, TransportOpts},
        initial_state  => initializing,
        handler_state  => HState
    }}.

-doc "Decode incoming JSONL data into normalized messages.".
-spec handle_data(binary(), #hstate{}) ->
    beam_agent_session_handler:data_result().
handle_data(Buffer, HState) ->
    extract_messages(Buffer, HState, [], []).

-doc "Encode a query as a session/prompt JSON-RPC request.".
-spec encode_query(binary(), beam_agent_core:query_opts(), #hstate{}) ->
    {ok, iodata(), #hstate{}} | {error, term()}.
encode_query(Prompt, Params,
             #hstate{sdk_hook_registry = HookReg,
                     session_id = SessionId} = HState) ->
    HookCtx = #{prompt => Prompt, params => Params,
                session_id => SessionId, event => user_prompt_submit},
    case beam_agent_hooks_core:fire(user_prompt_submit, HookCtx, HookReg) of
        ok ->
            case SessionId of
                undefined ->
                    {error, not_ready};
                _ ->
                    {ModeData, HState1} =
                        maybe_apply_query_mode(Params, HState),
                    PromptId = beam_agent_jsonrpc:next_id(),
                    Blocks = prompt_blocks(Prompt, Params),
                    PromptData = beam_agent_jsonrpc:encode_request(
                                     PromptId,
                                     <<"session/prompt">>,
                                     beam_agent_gemini_wire:prompt_params(
                                         SessionId, Blocks)),
                    Pending = (HState1#hstate.pending)#{
                                  PromptId => prompt},
                    HState2 = HState1#hstate{pending = Pending,
                                             cancel_requested = false},
                    {ok, [ModeData, PromptData], HState2}
            end;
        {deny, Reason} ->
            {error, {hook_denied, Reason}}
    end.

-doc "Build the session info map.".
-spec build_session_info(#hstate{}) -> map().
build_session_info(#hstate{session_id = SessionId,
                            init_response = InitResponse,
                            available_modes = AvailModes,
                            current_mode = CurMode,
                            available_models = AvailModels,
                            current_model = CurModel,
                            title = Title,
                            updated_at = UpdatedAt,
                            available_commands = AvailCmds,
                            opts = Opts}) ->
    #{adapter => gemini,
      transport => gemini_cli,
      protocol => acp,
      gemini_session_id => SessionId,
      init_response => InitResponse,
      modes => #{available_modes => AvailModes,
                 current_mode_id => CurMode},
      models => #{available_models => AvailModels,
                  current_model_id => CurModel},
      title => Title,
      updated_at => UpdatedAt,
      system_info =>
          #{settings_file => maps:get(settings_file, Opts, undefined),
            sandbox => maps:get(sandbox, Opts, false),
            allowed_tools => maps:get(allowed_tools, Opts, []),
            allowed_mcp_server_names =>
                maps:get(allowed_mcp_server_names, Opts, []),
            extensions => maps:get(extensions, Opts, []),
            include_directories =>
                maps:get(include_directories, Opts, []),
            extra_args => maps:get(extra_args, Opts, undefined),
            work_dir => maps:get(work_dir, Opts, undefined),
            slash_commands => AvailCmds,
            available_commands => AvailCmds}}.

-doc "Clean up handler resources.".
-spec terminate_handler(term(), #hstate{}) -> ok.
terminate_handler(Reason, #hstate{sdk_hook_registry = HookReg,
                                   session_id = SessionId}) ->
    StoreId = session_store_id(SessionId),
    _ = beam_agent_hooks_core:fire(session_end,
            #{session_id => StoreId, reason => Reason,
              event => session_end},
            HookReg),
    beam_agent_control_core:clear_session_callbacks(StoreId),
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-doc "Store the transport port ref for SIGINT-based cancel.".
-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started(TRef, HState) ->
    HState#hstate{port_ref = TRef}.

-doc """
Handle transport events during the initializing phase.

Multi-step init: process initialize response → maybe auth → session/start → ready.
""".
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

-doc "Encode an interrupt as a session/cancel notification + SIGINT.".
-spec encode_interrupt(#hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} |
    not_supported.
encode_interrupt(#hstate{session_id = SessionId,
                          port_ref = Port} = HState)
  when SessionId =/= undefined ->
    CancelData = beam_agent_jsonrpc:encode_notification(
                     <<"session/cancel">>,
                     beam_agent_gemini_wire:cancel_params(SessionId)),
    HState1 = HState#hstate{cancel_requested = true},
    Actions = [{send, CancelData}],
    %% Also send OS SIGINT if port is available
    _ = maybe_send_sigint(Port),
    {ok, Actions, HState1};
encode_interrupt(_HState) ->
    not_supported.

-doc """
Handle set_permission_mode — send session/set_mode JSON-RPC request.

If the mode is available on the server, sends a JSON-RPC request and
defers the reply until the response arrives in handle_data.
""".
-spec handle_set_permission_mode(binary(), #hstate{}) ->
    {ok, 'undefined' | binary(), [beam_agent_session_handler:handler_action()], #hstate{}}.
handle_set_permission_mode(Mode, HState) ->
    RequestedMode = normalize_approval_mode(Mode),
    case {HState#hstate.session_id,
          mode_available(RequestedMode, HState)} of
        {undefined, _} ->
            HState1 = HState#hstate{approval_mode = RequestedMode,
                                    current_mode = RequestedMode},
            HState2 = update_session_meta(HState1),
            {ok, RequestedMode, [], HState2};
        {_SessionId, false} ->
            HState1 = HState#hstate{approval_mode = RequestedMode,
                                    current_mode = RequestedMode},
            HState2 = update_session_meta(HState1),
            {ok, RequestedMode, [], HState2};
        {SessionId, true} ->
            Id = beam_agent_jsonrpc:next_id(),
            Encoded = beam_agent_jsonrpc:encode_request(
                          Id,
                          <<"session/set_mode">>,
                          beam_agent_gemini_wire:set_mode_params(
                              SessionId, RequestedMode)),
            Pending = (HState#hstate.pending)#{
                          Id => {set_mode, undefined, RequestedMode}},
            %% NOTE: The engine will see {ok, ...} and reply immediately.
            %% For deferred reply we would need handle_control, but the
            %% engine's handle_set_permission_mode doesn't pass From.
            %% So we optimistically update and send the request.
            HState1 = HState#hstate{pending = Pending,
                                    approval_mode = RequestedMode,
                                    current_mode = RequestedMode},
            HState2 = update_session_meta(HState1),
            {ok, RequestedMode, [{send, Encoded}], HState2}
    end.

-doc """
Perform side effects on state transitions.

On entering initializing: send the initialize JSON-RPC request.
On entering ready from initializing: fire session_start hook, register session.
""".
-spec on_state_enter(beam_agent_session_handler:state_name(),
                     beam_agent_session_handler:state_name() | undefined,
                     #hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}}.
on_state_enter(initializing, _OldState, HState) ->
    {Actions, HState1} = send_initialize(HState),
    {ok, Actions, HState1};
on_state_enter(ready, initializing, HState) ->
    register_ready_session(HState),
    {ok, [], HState};
on_state_enter(_State, _OldState, HState) ->
    {ok, [], HState}.

-doc "Detect whether a message signals query completion.".
-spec is_query_complete(beam_agent_core:message(), #hstate{}) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error}, _HState) -> true;
is_query_complete(_Msg, _HState) -> false.

%%====================================================================
%% Internal: initializing handshake
%%====================================================================

-spec do_initializing(binary(), #hstate{}) ->
    beam_agent_session_handler:phase_result().
do_initializing(RawData, HState) ->
    process_init_lines(RawData, HState).

-spec process_init_lines(binary(), #hstate{}) ->
    beam_agent_session_handler:phase_result().
process_init_lines(Buffer, HState) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            %% No complete line yet — stay in initializing
            {keep_state, [], HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    case handle_init_frame(
                             beam_agent_gemini_wire:decode_message(Map),
                             HState) of
                        {ready, Actions, HState1} ->
                            %% Transition to ready, pass leftover buffer
                            {next_state, ready, Actions, HState1, Rest};
                        {continue, Actions, HState1} ->
                            %% Still initializing — process more lines
                            case Actions of
                                [] ->
                                    process_init_lines(Rest, HState1);
                                _ ->
                                    %% Send actions, then continue with rest
                                    process_init_lines_with_actions(
                                        Rest, HState1, Actions)
                            end;
                        {error, Reason, HState1} ->
                            {error_state, Reason, HState1}
                    end;
                {error, _} ->
                    process_init_lines(Rest, HState)
            end
    end.

-spec process_init_lines_with_actions(binary(), #hstate{},
                                      [beam_agent_session_handler:handler_action()]) ->
    beam_agent_session_handler:phase_result().
process_init_lines_with_actions(Buffer, HState, PriorActions) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {keep_state, PriorActions, HState};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, Map} ->
                    case handle_init_frame(
                             beam_agent_gemini_wire:decode_message(Map),
                             HState) of
                        {ready, Actions, HState1} ->
                            {next_state, ready,
                             PriorActions ++ Actions, HState1, Rest};
                        {continue, Actions, HState1} ->
                            process_init_lines_with_actions(
                                Rest, HState1, PriorActions ++ Actions);
                        {error, Reason, HState1} ->
                            {error_state, Reason, HState1}
                    end;
                {error, _} ->
                    process_init_lines_with_actions(Rest, HState, PriorActions)
            end
    end.

-spec handle_init_frame(beam_agent_gemini_wire:decoded_message(), #hstate{}) ->
    {ready, [beam_agent_session_handler:handler_action()], #hstate{}}
  | {continue, [beam_agent_session_handler:handler_action()], #hstate{}}
  | {error, term(), #hstate{}}.
handle_init_frame({response, Id, Result}, HState) ->
    case maps:take(Id, HState#hstate.pending) of
        {init, Pending1} ->
            InitResponse = normalize_map(Result),
            HState1 = HState#hstate{pending = Pending1,
                                    init_response = InitResponse},
            {Actions, HState2} = maybe_send_auth_or_start(HState1),
            {continue, Actions, HState2};
        {auth, Pending1} ->
            HState1 = HState#hstate{pending = Pending1},
            {Actions, HState2} = send_session_start(HState1),
            {continue, Actions, HState2};
        {session_start, Pending1} ->
            HState1 = apply_session_start(
                          normalize_map(Result),
                          HState#hstate{pending = Pending1}),
            {ready, [], HState1};
        error ->
            {continue, [], HState}
    end;
handle_init_frame({error_response, Id, _Code, _Message, _ErrData}, HState) ->
    case maps:take(Id, HState#hstate.pending) of
        {_Entry, Pending1} ->
            {error, {init_error_response, _Code, _Message},
             HState#hstate{pending = Pending1}};
        error ->
            {continue, [], HState}
    end;
handle_init_frame(_Frame, HState) ->
    %% Ignore unexpected frames during init
    {continue, [], HState}.

-spec send_initialize(#hstate{}) ->
    {[beam_agent_session_handler:handler_action()], #hstate{}}.
send_initialize(HState) ->
    Id = beam_agent_jsonrpc:next_id(),
    Encoded = beam_agent_jsonrpc:encode_request(
                  Id,
                  <<"initialize">>,
                  beam_agent_gemini_wire:initialize_params()),
    Pending = (HState#hstate.pending)#{Id => init},
    {[{send, Encoded}], HState#hstate{pending = Pending}}.

-spec maybe_send_auth_or_start(#hstate{}) ->
    {[beam_agent_session_handler:handler_action()], #hstate{}}.
maybe_send_auth_or_start(#hstate{opts = Opts} = HState) ->
    case gemini_cli_protocol:should_authenticate(Opts) of
        true ->
            Methods = maps:get(<<"authMethods">>,
                               HState#hstate.init_response, []),
            Id = beam_agent_jsonrpc:next_id(),
            Encoded = beam_agent_jsonrpc:encode_request(
                          Id,
                          <<"authenticate">>,
                          gemini_cli_protocol:authenticate_params(
                              Opts, Methods)),
            Pending = (HState#hstate.pending)#{Id => auth},
            {[{send, Encoded}], HState#hstate{pending = Pending}};
        false ->
            send_session_start(HState)
    end.

-spec send_session_start(#hstate{}) ->
    {[beam_agent_session_handler:handler_action()], #hstate{}}.
send_session_start(#hstate{opts = Opts} = HState) ->
    Id = beam_agent_jsonrpc:next_id(),
    Method = beam_agent_gemini_wire:session_start_method(Opts),
    Encoded = beam_agent_jsonrpc:encode_request(
                  Id,
                  Method,
                  beam_agent_gemini_wire:session_start_params(Opts, [])),
    Pending = (HState#hstate.pending)#{Id => session_start},
    {[{send, Encoded}], HState#hstate{pending = Pending}}.

-spec apply_session_start(map(), #hstate{}) -> #hstate{}.
apply_session_start(Result, HState) ->
    Parsed = beam_agent_gemini_wire:parse_start_result(Result),
    SessionId = maps:get(session_id, Parsed, undefined),
    Modes = maps:get(modes, Parsed, undefined),
    Models = maps:get(models, Parsed, undefined),
    update_session_meta(
        HState#hstate{
            session_id = SessionId,
            available_modes = extract_available_modes(Modes),
            current_mode = extract_current_mode(
                               Modes, HState#hstate.current_mode),
            current_model = extract_current_model(
                                Models, HState#hstate.model),
            available_models = extract_available_models(Models)}).

-spec register_ready_session(#hstate{}) -> ok.
register_ready_session(#hstate{session_id = SessionId,
                                opts = Opts,
                                sdk_hook_registry = HookReg} = HState) ->
    StoreId = session_store_id(SessionId),
    ok = beam_agent_control_core:register_session_callbacks(StoreId, Opts),
    _ = beam_agent_hooks_core:fire(session_start,
            #{event => session_start,
              session_id => StoreId,
              system_info => build_session_info(HState)},
            HookReg),
    ok.

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
                    {NewMsgs, NewActions, HState1} =
                        handle_runtime_frame(
                            beam_agent_gemini_wire:decode_message(Map),
                            HState),
                    extract_messages(Rest, HState1,
                                    lists:reverse(NewMsgs) ++ MsgsAcc,
                                    lists:reverse(NewActions) ++ ActionsAcc);
                {error, _} ->
                    extract_messages(Rest, HState, MsgsAcc, ActionsAcc)
            end
    end.

-spec handle_runtime_frame(beam_agent_gemini_wire:decoded_message(),
                           #hstate{}) ->
    {[beam_agent_core:message()],
     [beam_agent_session_handler:handler_action()],
     #hstate{}}.
handle_runtime_frame({response, Id, Result}, HState) ->
    handle_response(Id, normalize_map(Result), HState);
handle_runtime_frame({error_response, Id, Code, Message, ErrData}, HState) ->
    handle_error_response(Id, Code, Message, ErrData, HState);
handle_runtime_frame({notification, <<"session/update">>, Params}, HState) ->
    handle_session_update(normalize_map(Params), HState);
handle_runtime_frame({request, Id, <<"session/request_permission">>, Params},
                     HState) ->
    Actions = handle_permission_request(Id, normalize_map(Params), HState),
    {[], Actions, HState};
handle_runtime_frame({request, Id, Method, _Params}, HState) ->
    %% Unknown reverse request — respond with method_not_found
    ErrorResp = beam_agent_jsonrpc:encode_error(
                    Id, -32601, <<"method_not_found">>, Method),
    {[], [{send, ErrorResp}], HState};
handle_runtime_frame(_Frame, HState) ->
    {[], [], HState}.

%%--------------------------------------------------------------------
%% Response handling
%%--------------------------------------------------------------------

-spec handle_response(integer(), map(), #hstate{}) ->
    {[beam_agent_core:message()],
     [beam_agent_session_handler:handler_action()],
     #hstate{}}.
handle_response(Id, Result, HState) ->
    case maps:take(Id, HState#hstate.pending) of
        {prompt, Pending1} ->
            Result1 = case HState#hstate.cancel_requested of
                          true  -> Result#{<<"stopReason">> => <<"cancelled">>};
                          false -> Result
                      end,
            StoreId = session_store_id(HState#hstate.session_id),
            Msg = beam_agent_gemini_translate:prompt_result_message(
                      StoreId, Result1),
            HState1 = HState#hstate{pending = Pending1,
                                    cancel_requested = false},
            Msgs = observe_and_track([Msg], HState1),
            {Msgs, [], HState1};
        {{set_mode, From, RequestedMode}, Pending1} ->
            HState1 = update_session_meta(
                          HState#hstate{pending = Pending1,
                                        approval_mode = RequestedMode,
                                        current_mode = RequestedMode}),
            %% If From is defined, reply
            case From of
                undefined -> ok;
                _ -> gen_statem:reply(From, {ok, RequestedMode})
            end,
            {[], [], HState1};
        {{set_mode_auto, RequestedMode}, Pending1} ->
            HState1 = update_session_meta(
                          HState#hstate{pending = Pending1,
                                        approval_mode = RequestedMode,
                                        current_mode = RequestedMode}),
            {[], [], HState1};
        error ->
            {[], [], HState}
    end.

-spec handle_error_response(integer(), integer(), binary(),
                            term(), #hstate{}) ->
    {[beam_agent_core:message()],
     [beam_agent_session_handler:handler_action()],
     #hstate{}}.
handle_error_response(Id, Code, Message, ErrData, HState) ->
    case maps:take(Id, HState#hstate.pending) of
        {prompt, Pending1} ->
            Msg = rpc_error_message(Code, Message, ErrData),
            HState1 = HState#hstate{pending = Pending1},
            Msgs = observe_and_track([Msg], HState1),
            {Msgs, [], HState1};
        {{set_mode, From, _RequestedMode}, Pending1} ->
            case From of
                undefined -> ok;
                _ -> gen_statem:reply(
                         From, {error, {set_mode_failed, Code, Message}})
            end,
            {[], [], HState#hstate{pending = Pending1}};
        {{set_mode_auto, _RequestedMode}, Pending1} ->
            {[], [], HState#hstate{pending = Pending1}};
        error ->
            {[], [], HState}
    end.

%%--------------------------------------------------------------------
%% Session update handling
%%--------------------------------------------------------------------

-spec handle_session_update(map(), #hstate{}) ->
    {[beam_agent_core:message()],
     [beam_agent_session_handler:handler_action()],
     #hstate{}}.
handle_session_update(Params, HState) ->
    case beam_agent_gemini_wire:parse_session_update(Params) of
        {ok, SessionId, Kind, Update} ->
            HState1 = maybe_set_session_id(SessionId, HState),
            HState2 = apply_update_meta(Kind, Update, HState1),
            Messages = beam_agent_gemini_translate:session_update_messages(
                           SessionId, Update),
            TrackedMsgs = observe_and_track(Messages, HState2),
            {TrackedMsgs, [], HState2};
        {error, _} ->
            {[], [], HState}
    end.

%%--------------------------------------------------------------------
%% Permission request handling
%%--------------------------------------------------------------------

-spec handle_permission_request(integer(), map(), #hstate{}) ->
    [beam_agent_session_handler:handler_action()].
handle_permission_request(Id, Params, _HState) ->
    case beam_agent_gemini_wire:parse_permission_request(Params) of
        {ok, SessionId, ToolCall, Options} ->
            Response = beam_agent_gemini_reverse_requests:permission_response(
                           SessionId, ToolCall, Options),
            [{send, beam_agent_jsonrpc:encode_response(Id, Response)}];
        {error, Reason} ->
            [{send, beam_agent_jsonrpc:encode_error(
                        Id, -32602, <<"invalid_permission_request">>,
                        Reason)}]
    end.

%%====================================================================
%% Internal: message observation and tracking
%%====================================================================

-spec observe_and_track([beam_agent_core:message()], #hstate{}) ->
    [beam_agent_core:message()].
observe_and_track(Messages, HState) ->
    [observe_message(Msg, HState) || Msg <- Messages].

-spec observe_message(beam_agent_core:message(), #hstate{}) ->
    beam_agent_core:message().
observe_message(Msg, HState) ->
    track_message(Msg, HState),
    maybe_fire_message_hooks(Msg, HState),
    Msg.

-spec track_message(beam_agent_core:message(), #hstate{}) -> ok.
track_message(Msg, #hstate{session_id = SessionId} = HState) ->
    StoreId = session_store_id(SessionId),
    StoredMsg = maybe_tag_session_id(Msg, StoreId),
    ok = beam_agent_session_store_core:update_session(
             StoreId, session_meta(HState)),
    case beam_agent_threads_core:active_thread(StoreId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(
                StoreId, ThreadId, StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(StoreId, StoredMsg)
    end,
    beam_agent_events:publish(StoreId, StoredMsg),
    ok.

-spec maybe_fire_message_hooks(beam_agent_core:message(), #hstate{}) -> ok.
maybe_fire_message_hooks(#{type := tool_result} = Msg,
                          #hstate{sdk_hook_registry = HookReg,
                                  session_id = SessionId}) ->
    StoreId = session_store_id(SessionId),
    _ = beam_agent_hooks_core:fire(post_tool_use,
            #{tool_use_id => maps:get(tool_use_id, Msg, <<>>),
              content => maps:get(content, Msg, <<>>),
              session_id => StoreId,
              event => post_tool_use},
            HookReg),
    ok;
maybe_fire_message_hooks(#{type := result} = Msg,
                          #hstate{sdk_hook_registry = HookReg,
                                  session_id = SessionId}) ->
    StoreId = session_store_id(SessionId),
    _ = beam_agent_hooks_core:fire(stop,
            #{content => maps:get(content, Msg, <<>>),
              stop_reason => maps:get(stop_reason, Msg, undefined),
              session_id => StoreId,
              event => stop},
            HookReg),
    ok;
maybe_fire_message_hooks(_Msg, _HState) ->
    ok.

%%====================================================================
%% Internal: metadata helpers
%%====================================================================

-spec apply_update_meta(binary(), map(), #hstate{}) -> #hstate{}.
apply_update_meta(<<"current_mode_update">>, Update, HState) ->
    Mode = maps:get(<<"currentModeId">>, Update, HState#hstate.current_mode),
    update_session_meta(HState#hstate{current_mode = Mode,
                                      approval_mode = Mode});
apply_update_meta(<<"session_info_update">>, Update, HState) ->
    update_session_meta(
        HState#hstate{
            title = maps:get(<<"title">>, Update, HState#hstate.title),
            updated_at = maps:get(<<"updatedAt">>, Update,
                                  HState#hstate.updated_at)});
apply_update_meta(<<"available_commands_update">>, Update, HState) ->
    update_session_meta(
        HState#hstate{
            available_commands = maps:get(<<"availableCommands">>, Update,
                                         HState#hstate.available_commands)});
apply_update_meta(_Kind, _Update, HState) ->
    HState.

-spec update_session_meta(#hstate{}) -> #hstate{}.
update_session_meta(HState) ->
    StoreId = session_store_id(HState#hstate.session_id),
    ok = beam_agent_session_store_core:update_session(
             StoreId, session_meta(HState)),
    HState.

-spec session_meta(#hstate{}) -> map().
session_meta(HState) ->
    #{adapter => gemini,
      backend => gemini,
      transport => gemini_cli,
      cwd => session_cwd(HState#hstate.opts),
      model => effective_model(HState),
      extra =>
          #{approval_mode => effective_mode(HState),
            title => HState#hstate.title,
            updated_at => HState#hstate.updated_at}}.

-spec session_store_id(binary() | undefined) -> binary().
session_store_id(SessionId)
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_) ->
    unicode:characters_to_binary(pid_to_list(self())).

-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
    beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.

-spec maybe_set_session_id(binary(), #hstate{}) -> #hstate{}.
maybe_set_session_id(SessionId, HState)
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    update_session_meta(HState#hstate{session_id = SessionId});
maybe_set_session_id(_SessionId, HState) ->
    HState.

-spec effective_model(#hstate{}) -> binary() | undefined.
effective_model(#hstate{current_model = Current})
  when is_binary(Current) ->
    Current;
effective_model(#hstate{model = Model}) ->
    Model.

-spec effective_mode(#hstate{}) -> binary() | undefined.
effective_mode(#hstate{current_mode = Current})
  when is_binary(Current) ->
    Current;
effective_mode(#hstate{approval_mode = Mode}) ->
    Mode.

%%====================================================================
%% Internal: query helpers
%%====================================================================

-spec prompt_blocks(binary(), map()) -> [map()].
prompt_blocks(_Prompt, #{beam_agent_prompt_blocks := Blocks})
  when is_list(Blocks) ->
    Blocks;
prompt_blocks(Prompt, _Params) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Prompt}].

-spec maybe_apply_query_mode(map(), #hstate{}) ->
    {iodata(), #hstate{}}.
maybe_apply_query_mode(Params, HState) ->
    RequestedMode = normalize_approval_mode(
                        maps:get(approval_mode, Params,
                                 maps:get(permission_mode, Params,
                                          HState#hstate.approval_mode))),
    case {RequestedMode,
          RequestedMode =:= HState#hstate.current_mode,
          mode_available(RequestedMode, HState),
          HState#hstate.session_id} of
        {undefined, _, _, _} ->
            {[], HState};
        {_, true, _, _} ->
            {[], HState};
        {_, _, true, SessionId} when is_binary(SessionId) ->
            Id = beam_agent_jsonrpc:next_id(),
            ModeEncoded = beam_agent_jsonrpc:encode_request(
                              Id,
                              <<"session/set_mode">>,
                              beam_agent_gemini_wire:set_mode_params(
                                  SessionId, RequestedMode)),
            Pending = (HState#hstate.pending)#{
                          Id => {set_mode_auto, RequestedMode}},
            {ModeEncoded, HState#hstate{pending = Pending}};
        _ ->
            HState1 = update_session_meta(
                          HState#hstate{approval_mode = RequestedMode,
                                        current_mode = RequestedMode}),
            {[], HState1}
    end.

%%====================================================================
%% Internal: mode/model extraction
%%====================================================================

-spec mode_available(binary() | undefined, #hstate{}) -> boolean().
mode_available(undefined, _HState) ->
    false;
mode_available(_Mode, #hstate{available_modes = []}) ->
    false;
mode_available(Mode, #hstate{available_modes = Modes}) ->
    lists:any(fun(#{<<"id">> := Id}) when Id =:= Mode -> true;
                 (_) -> false
              end, Modes).

-spec extract_available_modes(map() | undefined) -> [map()].
extract_available_modes(#{<<"availableModes">> := Modes})
  when is_list(Modes) ->
    Modes;
extract_available_modes(_) ->
    [].

-spec extract_current_mode(map() | undefined, binary() | undefined) ->
    binary() | undefined.
extract_current_mode(#{<<"currentModeId">> := Mode}, _Default) ->
    Mode;
extract_current_mode(_, Default) ->
    Default.

-spec extract_available_models(map() | undefined) -> [map()].
extract_available_models(#{<<"availableModels">> := Models})
  when is_list(Models) ->
    Models;
extract_available_models(_) ->
    [].

-spec extract_current_model(map() | undefined, binary() | undefined) ->
    binary() | undefined.
extract_current_model(#{<<"currentModelId">> := Model}, _Default) ->
    Model;
extract_current_model(_, Default) ->
    Default.

%%====================================================================
%% Internal: CLI args building
%%====================================================================

-spec build_cli_args(binary() | undefined, binary() | undefined, map()) ->
    [string()].
build_cli_args(Model, ApprovalMode, Opts) ->
    Base = ["--experimental-acp"],
    WithModel = case Model of
        undefined -> Base;
        M when is_binary(M) -> Base ++ ["--model", binary_to_list(M)]
    end,
    WithApproval = case ApprovalMode of
        undefined -> WithModel;
        AM -> WithModel ++ ["--approval-mode", binary_to_list(AM)]
    end,
    WithSandbox = case maps:get(sandbox, Opts, false) of
        true  -> WithApproval ++ ["--sandbox"];
        _     -> WithApproval
    end,
    WithSettings = case maps:get(settings_file, Opts, undefined) of
        SF when is_binary(SF) ->
            WithSandbox ++ ["--settings-file", binary_to_list(SF)];
        _ ->
            WithSandbox
    end,
    WithExtensions = lists:foldl(
        fun(Ext, Acc) when is_binary(Ext) ->
                Acc ++ ["--extensions", binary_to_list(Ext)];
           (_, Acc) ->
                Acc
        end, WithSettings, maps:get(extensions, Opts, [])),
    WithIncludeDirs = case maps:get(include_directories, Opts, []) of
        [] ->
            WithExtensions;
        Dirs when is_list(Dirs) ->
            DirBins = [binary_to_list(Dir) || Dir <- Dirs, is_binary(Dir)],
            case DirBins of
                [] -> WithExtensions;
                _  -> WithExtensions ++
                      ["--include-directories", string:join(DirBins, ",")]
            end
    end,
    append_extra_args(WithIncludeDirs,
                      maps:get(extra_args, Opts, undefined)).

-spec append_extra_args([string()], term()) -> [string()].
append_extra_args(Args, undefined) ->
    Args;
append_extra_args(Args, Extra) when is_list(Extra) ->
    Args ++ [ensure_list(Arg) || Arg <- Extra];
append_extra_args(Args, Extra) when is_binary(Extra) ->
    Args ++ [binary_to_list(Extra)];
append_extra_args(Args, Extra) ->
    Args ++ [ensure_list(Extra)].

%%====================================================================
%% Internal: approval mode normalization
%%====================================================================

-spec normalize_approval_mode(term()) -> binary() | undefined.
normalize_approval_mode(undefined)             -> undefined;
normalize_approval_mode(default)               -> <<"default">>;
normalize_approval_mode(accept_edits)          -> <<"autoEdit">>;
normalize_approval_mode(bypass_permissions)    -> <<"yolo">>;
normalize_approval_mode(plan)                  -> <<"plan">>;
normalize_approval_mode(dont_ask)              -> <<"yolo">>;
normalize_approval_mode(auto_edit)             -> <<"autoEdit">>;
normalize_approval_mode(yolo)                  -> <<"yolo">>;
normalize_approval_mode(Value) when is_binary(Value) ->
    case Value of
        <<"default">>             -> <<"default">>;
        <<"acceptEdits">>         -> <<"autoEdit">>;
        <<"accept_edits">>        -> <<"autoEdit">>;
        <<"auto_edit">>           -> <<"autoEdit">>;
        <<"autoEdit">>            -> <<"autoEdit">>;
        <<"bypassPermissions">>   -> <<"yolo">>;
        <<"bypass_permissions">>  -> <<"yolo">>;
        <<"yolo">>                -> <<"yolo">>;
        <<"plan">>                -> <<"plan">>;
        Other                     -> Other
    end;
normalize_approval_mode(Value) when is_atom(Value) ->
    normalize_approval_mode(atom_to_binary(Value, utf8));
normalize_approval_mode(Value) ->
    ensure_binary(Value).

%%====================================================================
%% Internal: error message building
%%====================================================================

-spec rpc_error_message(integer(), binary(), term()) ->
    beam_agent_core:message().
rpc_error_message(Code, Message, ErrData) ->
    Detail = case ErrData of
        undefined -> <<>>;
        _ -> iolist_to_binary(io_lib:format(" (~tp)", [ErrData]))
    end,
    #{type => error,
      content => iolist_to_binary(
                     io_lib:format("gemini acp error ~p: ~s~s",
                                   [Code, Message, Detail])),
      raw => #{code => Code, message => Message, data => ErrData},
      timestamp => erlang:system_time(millisecond)}.

%%====================================================================
%% Internal: utility helpers
%%====================================================================

-spec session_cwd(map()) -> binary().
session_cwd(Opts) ->
    case maps:get(work_dir, Opts, undefined) of
        undefined ->
            case file:get_cwd() of
                {ok, Cwd} -> unicode:characters_to_binary(Cwd);
                _         -> <<".">>
            end;
        Dir when is_binary(Dir) ->
            Dir;
        Dir when is_list(Dir) ->
            unicode:characters_to_binary(Dir)
    end.

-spec maybe_send_sigint(port() | undefined) -> ok.
maybe_send_sigint(undefined) ->
    ok;
maybe_send_sigint(Port) when is_port(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill -INT " ++ integer_to_list(OsPid)),
            ok;
        undefined ->
            ok
    end.

-spec normalize_map(term()) -> map().
normalize_map(Map) when is_map(Map) -> Map;
normalize_map(_) -> #{}.

-spec ensure_binary(term()) -> binary().
ensure_binary(Value) when is_binary(Value) -> Value;
ensure_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
ensure_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
ensure_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Value])).

-spec ensure_list(term()) -> string().
ensure_list(Value) when is_list(Value) -> Value;
ensure_list(Value) when is_binary(Value) -> binary_to_list(Value);
ensure_list(Value) when is_atom(Value) -> atom_to_list(Value);
ensure_list(Value) -> lists:flatten(io_lib:format("~tp", [Value])).
