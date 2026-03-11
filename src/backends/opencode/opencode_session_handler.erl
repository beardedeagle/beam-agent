-module(opencode_session_handler).
-moduledoc """
OpenCode session handler — backend protocol logic for OpenCode.

Implements `beam_agent_session_handler` by managing the OpenCode
dual-channel architecture: SSE for streaming events + REST for commands,
both over a single HTTP connection.

The transport (`beam_agent_transport_http`) manages the HTTP connection
lifecycle. This handler performs all protocol-level I/O:

  - SSE stream setup and event parsing
  - REST request dispatch and response accumulation
  - Event subscription management
  - Permission handling (fail-closed)
  - ~30 REST endpoint operations

HTTP messages (`http_response`, `http_data`) are processed through
`handle_info/3` since the transport cannot distinguish SSE from REST
streams without handler state context.

## Architecture

```
opencode_session (thin wrapper)
  → beam_agent_session_engine (gen_statem)
    → opencode_session_handler (this module, callbacks)
    → beam_agent_transport_http (HTTP connection)
```
""".

-behaviour(beam_agent_session_handler).

%%--------------------------------------------------------------------
%% Behaviour exports
%%--------------------------------------------------------------------

-export([
    backend_name/0,
    init_handler/1,
    handle_data/2,
    encode_query/3,
    build_session_info/1,
    terminate_handler/2,
    transport_started/2,
    handle_connecting/2,
    handle_initializing/2,
    encode_interrupt/1,
    handle_set_model/2,
    on_state_enter/3,
    is_query_complete/2,
    handle_custom_call/3,
    handle_info/3
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type rest_purpose() ::
    create_session | send_message | abort_query | permission_reply |
    app_info | app_init | app_log | app_modes |
    list_sessions | get_session | delete_session |
    config_read | config_update | config_providers |
    find_text | find_files | find_symbols |
    file_list | file_read | file_status |
    provider_list | provider_auth_methods |
    provider_oauth_authorize | provider_oauth_callback |
    list_commands | mcp_status | add_mcp_server | list_agents |
    revert_session | unrevert_session | share_session | unshare_session |
    summarize_session | session_init | session_messages |
    prompt_async | shell_command |
    tui_append_prompt | tui_open_help |
    send_command | server_health.

-record(hstate, {
    %% HTTP client (stored from transport_started)
    client_module         :: module(),
    conn_pid           :: pid() | undefined,

    %% SSE stream
    sse_ref            :: reference() | undefined,
    sse_state          :: opencode_sse:parse_state(),

    %% REST request tracking: Ref => {Purpose, From | undefined, AccChunks}
    rest_pending = #{} :: #{reference() =>
                            {rest_purpose(),
                             gen_statem:from() | undefined,
                             [binary()]}},

    %% Event subscription (independent of query consumer)
    event_ref          :: reference() | undefined,
    event_consumer     :: gen_statem:from() | undefined,
    event_queue        :: queue:queue(),

    %% Session metadata
    session_id         :: binary() | undefined,
    directory          :: binary(),
    opts               :: map(),
    host               :: binary(),
    port               :: inet:port_number(),
    base_path = <<>>   :: binary(),
    auth               :: {basic, binary()} | none,
    model              :: binary() | map() | undefined,
    buffer_max         :: pos_integer(),
    permission_handler :: fun((binary(), map(), map()) ->
                              beam_agent_core:permission_result()) |
                          undefined,
    sdk_mcp_registry   :: beam_agent_tool_registry:mcp_registry() | undefined,
    sdk_hook_registry  :: beam_agent_hooks_core:hook_registry() | undefined,

    %% State tracking (for custom call state checks)
    current_state = connecting :: beam_agent_session_handler:state_name()
}).

-dialyzer({no_underspecs,
           [{do_post_json, 5},
            {do_patch_json, 5},
            {do_get_request, 4},
            {do_delete_request, 4},
            {build_sse_path, 1},
            {build_sse_headers, 1},
            {dispatch_sse_events, 2},
            {fire_hook, 3},
            {maybe_reply, 2},
            {build_summarize_body, 2}]}).
-dialyzer({nowarn_function, [{handle_permission, 3}]}).
%% Dialyzer: recursive JSON value types cannot be precisely expressed
%% in Erlang type specs.
-dialyzer({nowarn_function, [decode_json_result/1]}).

%%====================================================================
%% Required callbacks
%%====================================================================

-spec backend_name() -> opencode.
backend_name() -> opencode.

-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    BaseUrl = maps:get(base_url, Opts, "http://localhost:4096"),
    Directory = maps:get(directory, Opts, <<".">>),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    Model = maps:get(model, Opts, undefined),
    PermissionHandler = maps:get(permission_handler, Opts, undefined),
    McpRegistry = beam_agent_tool_registry:build_registry(
                      maps:get(sdk_mcp_servers, Opts, undefined)),
    HookRegistry = beam_agent_hooks_core:build_registry(
                       maps:get(sdk_hooks, Opts, undefined)),
    Auth = case maps:get(auth, Opts, none) of
        none                                 -> none;
        {basic, U, P}                        -> opencode_http:encode_basic_auth(U, P);
        {basic, Encoded} when is_binary(Encoded) -> {basic, Encoded}
    end,
    {Host, Port, BasePath} = opencode_http:parse_base_url(BaseUrl),
    ClientMod = maps:get(client_module, Opts, beam_agent_http_client),
    HState = #hstate{
        client_module         = ClientMod,
        sse_state          = opencode_sse:new_state(),
        rest_pending       = #{},
        event_queue        = queue:new(),
        directory          = Directory,
        opts               = Opts,
        host               = Host,
        port               = Port,
        base_path          = BasePath,
        auth               = Auth,
        model              = Model,
        buffer_max         = BufferMax,
        permission_handler = PermissionHandler,
        sdk_mcp_registry   = McpRegistry,
        sdk_hook_registry  = HookRegistry,
        current_state      = connecting
    },
    {ok, #{
        transport_spec => {beam_agent_transport_http, #{
            client_module => ClientMod,
            host       => Host,
            port       => Port
        }},
        initial_state  => connecting,
        handler_state  => HState
    }}.

-doc "Stub — HTTP transport never produces {data, Binary} events.".
-spec handle_data(binary(), term()) ->
    beam_agent_session_handler:data_result().
handle_data(_Buffer, HState) ->
    {ok, [], <<>>, [], HState}.

-spec encode_query(binary(), beam_agent_core:query_opts(), term()) ->
    {ok, term(), term()} | {error, term()}.
encode_query(Prompt, Params, #hstate{opts = Opts} = HState) ->
    HookCtx = #{event => user_prompt_submit,
                prompt => Prompt,
                params => Params},
    case fire_hook(user_prompt_submit, HookCtx, HState) of
        {deny, Reason} ->
            {error, {hook_denied, Reason}};
        ok ->
            SessionId = HState#hstate.session_id,
            Path = <<"/session/", SessionId/binary, "/message">>,
            MergedOpts0 = case HState#hstate.model of
                undefined -> Params;
                Model     -> maps:put(model, Model, Params)
            end,
            MergedOpts = merge_query_defaults(MergedOpts0, Opts),
            Body = opencode_protocol:build_prompt_input(Prompt, MergedOpts),
            HState1 = do_post_json(Path, Body, send_message, undefined, HState),
            {ok, noop, HState1}
    end.

-spec build_session_info(#hstate{}) -> map().
build_session_info(#hstate{} = HState) ->
    #{session_id  => HState#hstate.session_id,
      adapter     => opencode,
      backend     => opencode,
      directory   => HState#hstate.directory,
      model       => HState#hstate.model,
      provider_id => maps:get(provider_id, HState#hstate.opts, undefined),
      model_id    => maps:get(model_id, HState#hstate.opts, undefined),
      agent       => maps:get(agent, HState#hstate.opts, undefined),
      host        => HState#hstate.host,
      port        => HState#hstate.port,
      transport   => http}.

-spec terminate_handler(_, #hstate{}) -> ok.
terminate_handler(Reason, #hstate{} = HState) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  HState),
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started({ConnPid, _MonRef, ClientMod}, #hstate{} = HState) ->
    HState#hstate{conn_pid = ConnPid, client_module = ClientMod}.

-spec handle_connecting(beam_agent_session_handler:transport_event(),
                        term()) ->
    beam_agent_session_handler:phase_result().
handle_connecting(connected, #hstate{client_module = ClientMod,
                                     conn_pid = ConnPid} = HState) ->
    SsePath = build_sse_path(HState),
    SseHeaders = build_sse_headers(HState),
    SseRef = ClientMod:get(ConnPid, SsePath, SseHeaders),
    {keep_state, [], HState#hstate{sse_ref = SseRef}};
handle_connecting(connect_timeout, HState) ->
    logger:error("OpenCode connection timed out"),
    {error_state, connect_timeout, HState};
handle_connecting({disconnected, Reason}, HState) ->
    logger:error("OpenCode HTTP connection down in connecting: ~p", [Reason]),
    {error_state, {disconnected, Reason},
     HState#hstate{conn_pid = undefined, sse_ref = undefined}};
handle_connecting({exit, _}, HState) ->
    logger:error("OpenCode HTTP client process crashed in connecting"),
    {error_state, client_process_crash,
     HState#hstate{conn_pid = undefined, sse_ref = undefined}}.

-spec handle_initializing(beam_agent_session_handler:transport_event(),
                          term()) ->
    beam_agent_session_handler:phase_result().
handle_initializing(init_timeout, HState) ->
    logger:error("OpenCode initialization timed out"),
    {error_state, init_timeout, HState};
handle_initializing({disconnected, Reason}, HState) ->
    logger:error("OpenCode HTTP connection down in initializing: ~p", [Reason]),
    {error_state, {disconnected, Reason},
     HState#hstate{conn_pid = undefined, sse_ref = undefined}};
handle_initializing({exit, _}, HState) ->
    logger:error("OpenCode HTTP client process crashed in initializing"),
    {error_state, client_process_crash,
     HState#hstate{conn_pid = undefined, sse_ref = undefined}}.

-spec encode_interrupt(_) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} |
    not_supported.
encode_interrupt(#hstate{session_id = SessionId} = HState)
  when is_binary(SessionId) ->
    Path = <<"/session/", SessionId/binary, "/abort">>,
    HState1 = do_post_json(Path, #{}, abort_query, undefined, HState),
    {ok, [], HState1};
encode_interrupt(_HState) ->
    not_supported.

-spec handle_set_model(binary(), #hstate{}) ->
    {ok, 'undefined' | binary() | map(), [], #hstate{}}.
handle_set_model(Model, #hstate{} = HState) ->
    {ok, Model, [], HState#hstate{model = Model}}.

-spec on_state_enter(beam_agent_session_handler:state_name(),
                     beam_agent_session_handler:state_name() | undefined,
                     term()) ->
    {ok, [beam_agent_session_handler:handler_action()], term()}.
on_state_enter(initializing, _OldState, #hstate{} = HState) ->
    Body = build_session_create_body(HState),
    HState1 = do_post_json(<<"/session">>, Body, create_session,
                           undefined, HState),
    {ok, [], HState1#hstate{current_state = initializing}};
on_state_enter(NewState, _OldState, HState) ->
    {ok, [], HState#hstate{current_state = NewState}}.

-spec is_query_complete(beam_agent_core:message(), term()) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error}, _HState)  -> true;
is_query_complete(_, _HState)                 -> false.

%%====================================================================
%% handle_custom_call — event subscription + REST endpoints
%%====================================================================

-spec handle_custom_call(term(), gen_statem:from(), term()) ->
    beam_agent_session_handler:control_result().

%% Event subscription (works in any state)
handle_custom_call(subscribe_events, _From, #hstate{} = HState) ->
    Ref = make_ref(),
    HState1 = HState#hstate{event_ref      = Ref,
                            event_consumer = undefined,
                            event_queue    = queue:new()},
    {reply, {ok, Ref}, [], HState1};
handle_custom_call({receive_event, Ref}, From,
                   #hstate{event_ref = Ref} = HState) ->
    try_deliver_event(From, HState);
handle_custom_call({receive_event, _WrongRef}, _From, _HState) ->
    {error, bad_ref};
handle_custom_call({unsubscribe_events, Ref}, _From,
                   #hstate{event_ref = Ref} = HState) ->
    {reply, ok, [], clear_event_subscription(HState)};
handle_custom_call({unsubscribe_events, _WrongRef}, _From, _HState) ->
    {error, bad_ref};

%% REST endpoints (require ready state)
handle_custom_call(Request, From,
                   #hstate{current_state = ready} = HState) ->
    dispatch_rest_endpoint(Request, From, HState);
handle_custom_call(_Request, _From,
                   #hstate{current_state = active_query}) ->
    {error, query_in_progress};
handle_custom_call(_Request, _From, _HState) ->
    {error, not_ready}.

%%====================================================================
%% handle_info — unclassified transport messages
%%====================================================================

-spec handle_info(term(), beam_agent_session_handler:state_name(),
                  term()) ->
    beam_agent_session_handler:info_result().
handle_info(Msg, StateName, #hstate{} = HState) ->
    case classify_info(Msg, HState) of
        {sse_response, _Status} ->
            %% SSE stream response header — just acknowledge
            {keep_state, [], HState};
        {sse_error, Status} ->
            logger:error("OpenCode SSE stream got unexpected status ~p",
                         [Status]),
            {error_state, {sse_error, Status}, HState};
        {sse_data, RawData} ->
            handle_sse_data(RawData, StateName, HState);
        {rest_response, Ref, IsFin, _Status} ->
            handle_rest_response_headers(Ref, IsFin, HState);
        {rest_data, Ref, IsFin, Body} ->
            handle_rest_body(Ref, IsFin, Body, StateName, HState);
        unknown ->
            ignore
    end.

%%====================================================================
%% Internal: info message classification
%%====================================================================

-spec classify_info(term(), #hstate{}) ->
    {sse_response, integer()} | {sse_error, integer()} |
    {sse_data, binary()} |
    {rest_response, reference(), fin | nofin, integer()} |
    {rest_data, reference(), fin | nofin, binary()} |
    unknown.

%% SSE stream response (200 = ok, other = error)
classify_info({http_response, ConnPid, SseRef, nofin, 200, _Headers},
              #hstate{conn_pid = ConnPid, sse_ref = SseRef}) ->
    {sse_response, 200};
classify_info({http_response, ConnPid, SseRef, _IsFin, Status, _Headers},
              #hstate{conn_pid = ConnPid, sse_ref = SseRef}) ->
    {sse_error, Status};

%% SSE stream data
classify_info({http_data, ConnPid, SseRef, _IsFin, RawData},
              #hstate{conn_pid = ConnPid, sse_ref = SseRef}) ->
    {sse_data, iolist_to_binary(RawData)};

%% REST response headers
classify_info({http_response, ConnPid, Ref, IsFin, Status, _Headers},
              #hstate{conn_pid = ConnPid, rest_pending = Pending}) ->
    case maps:is_key(Ref, Pending) of
        true  -> {rest_response, Ref, IsFin, Status};
        false -> unknown
    end;

%% REST response body
classify_info({http_data, ConnPid, Ref, IsFin, Body},
              #hstate{conn_pid = ConnPid, rest_pending = Pending}) ->
    case maps:is_key(Ref, Pending) of
        true  -> {rest_data, Ref, IsFin, iolist_to_binary(Body)};
        false -> unknown
    end;

classify_info(_, _) ->
    unknown.

%%====================================================================
%% Internal: SSE data handling
%%====================================================================

-spec handle_sse_data(binary(),
                      beam_agent_session_handler:state_name(),
                      #hstate{}) ->
    beam_agent_session_handler:info_result().
handle_sse_data(RawData, StateName, #hstate{} = HState) ->
    case safe_parse_sse(RawData, HState) of
        {ok, Events, NewSseState} ->
            HState1 = HState#hstate{sse_state = NewSseState},
            case StateName of
                connecting ->
                    HState2 = observe_sse_events(Events, HState1),
                    case check_server_connected(Events) of
                        true  -> {next_state, initializing, [], HState2};
                        false -> {keep_state, [], HState2}
                    end;
                active_query ->
                    {Msgs, HState2} = dispatch_sse_events(Events, HState1),
                    {messages, Msgs, [], HState2};
                _Other ->
                    HState2 = observe_sse_events(Events, HState1),
                    {keep_state, [], HState2}
            end;
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in ~p", [StateName]),
            {error_state, buffer_overflow, HState}
    end.

%%====================================================================
%% Internal: REST response handling
%%====================================================================

-spec handle_rest_response_headers(reference(), fin | nofin,
                                   #hstate{}) ->
    beam_agent_session_handler:info_result().
handle_rest_response_headers(Ref, fin, #hstate{rest_pending = Pending} = HState) ->
    case maps:find(Ref, Pending) of
        {ok, {Purpose, From, AccChunks}} ->
            Pending1 = maps:remove(Ref, Pending),
            FinalBody = iolist_to_binary(lists:reverse(AccChunks)),
            complete_rest(Purpose, From, FinalBody,
                          HState#hstate{rest_pending = Pending1});
        error ->
            {keep_state, [], HState}
    end;
handle_rest_response_headers(_Ref, nofin, HState) ->
    {keep_state, [], HState}.

-spec handle_rest_body(reference(), fin | nofin, binary(),
                       beam_agent_session_handler:state_name(),
                       #hstate{}) ->
    beam_agent_session_handler:info_result().
handle_rest_body(Ref, IsFin, Body, _StateName,
                 #hstate{rest_pending = Pending} = HState) ->
    case maps:find(Ref, Pending) of
        {ok, {Purpose, From, AccChunks}} ->
            NewAcc = [Body | AccChunks],
            case IsFin of
                nofin ->
                    Pending1 = maps:put(Ref, {Purpose, From, NewAcc},
                                        Pending),
                    {keep_state, [],
                     HState#hstate{rest_pending = Pending1}};
                fin ->
                    Pending1 = maps:remove(Ref, Pending),
                    FinalBody = iolist_to_binary(lists:reverse(NewAcc)),
                    complete_rest(Purpose, From, FinalBody,
                                  HState#hstate{rest_pending = Pending1})
            end;
        error ->
            {keep_state, [], HState}
    end.

-spec complete_rest(rest_purpose(), gen_statem:from() | undefined,
                    binary(), #hstate{}) ->
    beam_agent_session_handler:info_result().

%% Session creation (may trigger state transition)
complete_rest(create_session, _From, Body,
              #hstate{current_state = initializing} = HState) ->
    case decode_json_result(Body) of
        {ok, SessionMap} when is_map(SessionMap) ->
            SessionId = maps:get(<<"id">>, SessionMap, undefined),
            HState1 = HState#hstate{session_id = SessionId},
            _ = fire_hook(session_start,
                          #{event => session_start,
                            session_id => SessionId},
                          HState1),
            {next_state, ready, [], HState1};
        _ ->
            logger:error("OpenCode: failed to decode session create "
                         "response"),
            {error_state, session_create_failed, HState}
    end;
complete_rest(create_session, _From, Body, HState) ->
    %% Late-arriving create_session in non-initializing state
    logger:debug("OpenCode: late create_session response in state ~p",
                 [HState#hstate.current_state]),
    case decode_json_result(Body) of
        {ok, SessionMap} when is_map(SessionMap) ->
            SessionId = maps:get(<<"id">>, SessionMap,
                                 HState#hstate.session_id),
            {keep_state, [], HState#hstate{session_id = SessionId}};
        _ ->
            {keep_state, [], HState}
    end;

%% Fire-and-forget purposes (no caller to reply to)
complete_rest(send_message, _From, _Body, HState) ->
    {keep_state, [], HState};
complete_rest(abort_query, _From, _Body, HState) ->
    {keep_state, [], HState};
complete_rest(permission_reply, _From, _Body, HState) ->
    {keep_state, [], HState};

%% Special reply formats
complete_rest(delete_session, From, _Body, HState) ->
    maybe_reply(From, {ok, deleted}),
    {keep_state, [], HState};
complete_rest(unshare_session, From, _Body, HState) ->
    maybe_reply(From, {ok, deleted}),
    {keep_state, [], HState};
complete_rest(prompt_async, From, _Body, HState) ->
    maybe_reply(From, {ok, accepted}),
    {keep_state, [], HState};

%% Default: decode JSON and reply
complete_rest(_Purpose, From, Body, HState) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, [], HState}.

%%====================================================================
%% Internal: SSE event processing
%%====================================================================

-spec safe_parse_sse(binary(), #hstate{}) ->
    {ok, [opencode_sse:sse_event()], opencode_sse:parse_state()} |
    {error, buffer_overflow}.
safe_parse_sse(Bin, #hstate{sse_state = SseState,
                            buffer_max = BufferMax}) ->
    CurrentSize = opencode_sse:buffer_size(SseState),
    IncomingSize = byte_size(Bin),
    case CurrentSize + IncomingSize > BufferMax of
        true ->
            beam_agent_telemetry_core:buffer_overflow(
                CurrentSize + IncomingSize, BufferMax),
            {error, buffer_overflow};
        false ->
            {Events, NewState} = opencode_sse:parse_chunk(Bin, SseState),
            {ok, Events, NewState}
    end.

-spec normalize_sse_event(opencode_sse:sse_event()) ->
    beam_agent_core:message() | skip.
normalize_sse_event(SseEvent) ->
    RawData = maps:get(data, SseEvent, <<>>),
    Payload = case RawData of
        <<>> -> #{};
        Json ->
            try json:decode(Json)
            catch _:_ ->
                logger:warning("OpenCode: failed to decode SSE event JSON: ~p",
                               [Json]),
                #{}
            end
    end,
    opencode_protocol:normalize_event(SseEvent#{data => Payload}).

-spec check_server_connected([opencode_sse:sse_event()]) -> boolean().
check_server_connected([]) ->
    false;
check_server_connected([#{event := <<"server.connected">>} | _]) ->
    true;
check_server_connected([_ | Rest]) ->
    check_server_connected(Rest).

-doc "Process SSE events for side effects only (event queue, permissions).".
-spec observe_sse_events([opencode_sse:sse_event()], #hstate{}) ->
    #hstate{}.
observe_sse_events([], HState) ->
    HState;
observe_sse_events([SseEvent | Rest], HState) ->
    HState1 = case normalize_sse_event(SseEvent) of
        skip ->
            HState;
        #{type := control_request,
          request_id := PermId,
          request := Meta} = Msg ->
            handle_permission(PermId, Meta, enqueue_event(Msg, HState));
        Msg ->
            enqueue_event(Msg, HState)
    end,
    observe_sse_events(Rest, HState1).

-doc "Process SSE events and produce consumer messages (active_query).".
-spec dispatch_sse_events([opencode_sse:sse_event()], #hstate{}) ->
    {[beam_agent_core:message()], #hstate{}}.
dispatch_sse_events(Events, HState) ->
    dispatch_sse_events(Events, [], HState).

-spec dispatch_sse_events([opencode_sse:sse_event()],
                          [beam_agent_core:message()],
                          #hstate{}) ->
    {[beam_agent_core:message()], #hstate{}}.
dispatch_sse_events([], Acc, HState) ->
    {lists:reverse(Acc), HState};
dispatch_sse_events([SseEvent | Rest], Acc, HState) ->
    case normalize_sse_event(SseEvent) of
        skip ->
            dispatch_sse_events(Rest, Acc, HState);
        #{type := control_request,
          request_id := PermId,
          request := Meta} = Msg ->
            HState1 = handle_permission(PermId, Meta,
                                        enqueue_event(Msg, HState)),
            dispatch_sse_events(Rest, Acc, HState1);
        #{type := result} = ResultMsg ->
            _ = fire_hook(stop,
                          #{event => stop, stop_reason => idle},
                          HState),
            _ = track_message(ResultMsg, HState),
            HState1 = enqueue_event(ResultMsg, HState),
            %% Stop processing after result
            {lists:reverse([ResultMsg | Acc]), HState1};
        #{type := error} = ErrMsg ->
            _ = track_message(ErrMsg, HState),
            HState1 = enqueue_event(ErrMsg, HState),
            %% Stop processing after error
            {lists:reverse([ErrMsg | Acc]), HState1};
        Msg ->
            _ = track_message(Msg, HState),
            HState1 = enqueue_event(Msg, HState),
            dispatch_sse_events(Rest, [Msg | Acc], HState1)
    end.

%%====================================================================
%% Internal: event subscription
%%====================================================================

-spec try_deliver_event(gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
try_deliver_event(From, #hstate{event_queue = Q} = HState) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {reply, {ok, Msg}, [], HState#hstate{event_queue = Q1}};
        {empty, _} ->
            {noreply, [], HState#hstate{event_consumer = From}}
    end.

-spec clear_event_subscription(#hstate{}) -> #hstate{}.
clear_event_subscription(HState) ->
    HState#hstate{event_ref      = undefined,
                  event_consumer = undefined,
                  event_queue    = queue:new()}.

-spec enqueue_event(beam_agent_core:message(), #hstate{}) -> #hstate{}.
enqueue_event(_Msg, #hstate{event_ref = undefined} = HState) ->
    HState;
enqueue_event(Msg, #hstate{event_consumer = undefined,
                           event_queue = Q} = HState) ->
    HState#hstate{event_queue = queue:in(Msg, Q)};
enqueue_event(Msg, #hstate{event_consumer = From} = HState) ->
    gen_statem:reply(From, {ok, Msg}),
    HState#hstate{event_consumer = undefined}.

%%====================================================================
%% Internal: permission handling
%%====================================================================

-spec handle_permission(binary(), map(), #hstate{}) -> #hstate{}.
handle_permission(PermId, Metadata, #hstate{} = HState) ->
    Decision = case HState#hstate.permission_handler of
        undefined ->
            <<"deny">>;
        Handler ->
            try Handler(PermId, Metadata, #{}) of
                {allow, _}    -> <<"allow">>;
                {allow, _, _} -> <<"allow">>;
                {deny, _}     -> <<"deny">>;
                _Other        -> <<"deny">>
            catch
                _:_ -> <<"deny">>
            end
    end,
    Body = opencode_protocol:build_permission_reply(PermId, Decision),
    Path = <<"/permission/", PermId/binary, "/reply">>,
    do_post_json(Path, Body, permission_reply, undefined, HState).

%%====================================================================
%% Internal: REST request helpers
%%====================================================================

-spec do_post_json(binary(), map(), rest_purpose(),
                   gen_statem:from() | undefined, #hstate{}) ->
    #hstate{}.
do_post_json(EndpointPath, Body, Purpose, From,
             #hstate{client_module = ClientMod, conn_pid = ConnPid,
                     base_path = BasePath, auth = Auth,
                     directory = Dir,
                     rest_pending = Pending} = HState) ->
    FullPath = opencode_http:build_path(BasePath, EndpointPath),
    Headers = opencode_http:common_headers(Auth, Dir),
    Encoded = json:encode(Body),
    Ref = ClientMod:post(ConnPid, binary_to_list(FullPath), Headers, Encoded),
    HState#hstate{rest_pending = maps:put(Ref, {Purpose, From, []},
                                          Pending)}.

-spec do_get_request(binary(), rest_purpose(), gen_statem:from(),
                     #hstate{}) ->
    #hstate{}.
do_get_request(EndpointPath, Purpose, From,
               #hstate{client_module = ClientMod, conn_pid = ConnPid,
                       base_path = BasePath, auth = Auth,
                       directory = Dir,
                       rest_pending = Pending} = HState) ->
    FullPath = opencode_http:build_path(BasePath, EndpointPath),
    Headers = opencode_http:common_headers(Auth, Dir),
    Ref = ClientMod:get(ConnPid, binary_to_list(FullPath), Headers),
    HState#hstate{rest_pending = maps:put(Ref, {Purpose, From, []},
                                          Pending)}.

-spec do_patch_json(binary(), map(), rest_purpose(), gen_statem:from(),
                    #hstate{}) ->
    #hstate{}.
do_patch_json(EndpointPath, Body, Purpose, From,
              #hstate{client_module = ClientMod, conn_pid = ConnPid,
                      base_path = BasePath, auth = Auth,
                      directory = Dir,
                      rest_pending = Pending} = HState) ->
    FullPath = opencode_http:build_path(BasePath, EndpointPath),
    Headers = opencode_http:common_headers(Auth, Dir),
    Encoded = json:encode(Body),
    Ref = ClientMod:patch(ConnPid, binary_to_list(FullPath), Headers, Encoded),
    HState#hstate{rest_pending = maps:put(Ref, {Purpose, From, []},
                                          Pending)}.

-spec do_delete_request(binary(), rest_purpose(), gen_statem:from(),
                        #hstate{}) ->
    #hstate{}.
do_delete_request(EndpointPath, Purpose, From,
                  #hstate{client_module = ClientMod, conn_pid = ConnPid,
                          base_path = BasePath, auth = Auth,
                          directory = Dir,
                          rest_pending = Pending} = HState) ->
    FullPath = opencode_http:build_path(BasePath, EndpointPath),
    Headers = opencode_http:common_headers(Auth, Dir),
    Ref = ClientMod:delete(ConnPid, binary_to_list(FullPath), Headers),
    HState#hstate{rest_pending = maps:put(Ref, {Purpose, From, []},
                                          Pending)}.

%%====================================================================
%% Internal: REST endpoint dispatch
%%====================================================================

-spec dispatch_rest_endpoint(term(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().

%% App operations
dispatch_rest_endpoint(app_info, From, HState) ->
    {noreply, [], do_get_request(<<"/app">>, app_info, From, HState)};
dispatch_rest_endpoint(app_init, From, HState) ->
    {noreply, [], do_post_json(<<"/app/init">>, #{}, app_init,
                               From, HState)};
dispatch_rest_endpoint({app_log, Body}, From, HState)
  when is_map(Body) ->
    {noreply, [], do_post_json(<<"/log">>, Body, app_log, From, HState)};
dispatch_rest_endpoint(app_modes, From, HState) ->
    {noreply, [], do_get_request(<<"/mode">>, app_modes, From, HState)};

%% Session operations
dispatch_rest_endpoint(list_sessions, From, HState) ->
    {noreply, [], do_get_request(<<"/session">>, list_sessions,
                                 From, HState)};
dispatch_rest_endpoint({get_session, Id}, From, HState) ->
    Path = <<"/session/", Id/binary>>,
    {noreply, [], do_get_request(Path, get_session, From, HState)};
dispatch_rest_endpoint({delete_session, Id}, From, HState) ->
    Path = <<"/session/", Id/binary>>,
    {noreply, [], do_delete_request(Path, delete_session, From, HState)};

%% Config operations
dispatch_rest_endpoint(config_read, From, HState) ->
    {noreply, [], do_get_request(<<"/config">>, config_read,
                                 From, HState)};
dispatch_rest_endpoint({config_update, Body}, From, HState)
  when is_map(Body) ->
    {noreply, [], do_patch_json(<<"/config">>, Body, config_update,
                                From, HState)};
dispatch_rest_endpoint(config_providers, From, HState) ->
    {noreply, [], do_get_request(<<"/config/providers">>, config_providers,
                                 From, HState)};

%% Find operations
dispatch_rest_endpoint({find_text, Pattern}, From, HState)
  when is_binary(Pattern) ->
    Path = build_query_path(<<"/find">>, #{pattern => Pattern}),
    {noreply, [], do_get_request(Path, find_text, From, HState)};
dispatch_rest_endpoint({find_files, Opts}, From, HState)
  when is_map(Opts) ->
    Path = build_query_path(<<"/find/file">>, Opts),
    {noreply, [], do_get_request(Path, find_files, From, HState)};
dispatch_rest_endpoint({find_symbols, Query}, From, HState)
  when is_binary(Query) ->
    Path = build_query_path(<<"/find/symbol">>, #{query => Query}),
    {noreply, [], do_get_request(Path, find_symbols, From, HState)};

%% File operations
dispatch_rest_endpoint({file_list, PathValue}, From, HState)
  when is_binary(PathValue) ->
    Path = build_query_path(<<"/file">>, #{path => PathValue}),
    {noreply, [], do_get_request(Path, file_list, From, HState)};
dispatch_rest_endpoint({file_read, PathValue}, From, HState)
  when is_binary(PathValue) ->
    Path = build_query_path(<<"/file/content">>, #{path => PathValue}),
    {noreply, [], do_get_request(Path, file_read, From, HState)};
dispatch_rest_endpoint(file_status, From, HState) ->
    {noreply, [], do_get_request(<<"/file/status">>, file_status,
                                 From, HState)};

%% Provider operations
dispatch_rest_endpoint(provider_list, From, HState) ->
    {noreply, [], do_get_request(<<"/provider">>, provider_list,
                                 From, HState)};
dispatch_rest_endpoint(provider_auth_methods, From, HState) ->
    {noreply, [], do_get_request(<<"/provider/auth">>,
                                 provider_auth_methods, From, HState)};
dispatch_rest_endpoint({provider_oauth_authorize, ProviderId, Body},
                       From, HState)
  when is_binary(ProviderId), is_map(Body) ->
    Path = <<"/provider/", ProviderId/binary, "/oauth/authorize">>,
    {noreply, [], do_post_json(Path, Body, provider_oauth_authorize,
                               From, HState)};
dispatch_rest_endpoint({provider_oauth_callback, ProviderId, Body},
                       From, HState)
  when is_binary(ProviderId), is_map(Body) ->
    Path = <<"/provider/", ProviderId/binary, "/oauth/callback">>,
    {noreply, [], do_post_json(Path, Body, provider_oauth_callback,
                               From, HState)};

%% Command / MCP / Agent
dispatch_rest_endpoint(list_commands, From, HState) ->
    {noreply, [], do_get_request(<<"/command">>, list_commands,
                                 From, HState)};
dispatch_rest_endpoint(mcp_status, From, HState) ->
    {noreply, [], do_get_request(<<"/mcp">>, mcp_status, From, HState)};
dispatch_rest_endpoint({add_mcp_server, Body}, From, HState)
  when is_map(Body) ->
    {noreply, [], do_post_json(<<"/mcp">>, Body, add_mcp_server,
                               From, HState)};
dispatch_rest_endpoint(list_agents, From, HState) ->
    {noreply, [], do_get_request(<<"/agent">>, list_agents,
                                 From, HState)};

%% Session management
dispatch_rest_endpoint({revert_session, Selector}, From,
                       #hstate{session_id = SessionId} = HState) ->
    case build_revert_body(Selector) of
        {ok, Body} ->
            Path = <<"/session/", SessionId/binary, "/revert">>,
            {noreply, [], do_post_json(Path, Body, revert_session,
                                       From, HState)};
        {error, _} = Err ->
            {error, Err}
    end;
dispatch_rest_endpoint(unrevert_session, From,
                       #hstate{session_id = SessionId} = HState) ->
    Path = <<"/session/", SessionId/binary, "/unrevert">>,
    {noreply, [], do_post_json(Path, #{}, unrevert_session, From, HState)};
dispatch_rest_endpoint(share_session, From,
                       #hstate{session_id = SessionId} = HState) ->
    Path = <<"/session/", SessionId/binary, "/share">>,
    {noreply, [], do_post_json(Path, #{}, share_session, From, HState)};
dispatch_rest_endpoint(unshare_session, From,
                       #hstate{session_id = SessionId} = HState) ->
    Path = <<"/session/", SessionId/binary, "/share">>,
    {noreply, [], do_delete_request(Path, unshare_session, From, HState)};
dispatch_rest_endpoint({summarize_session, Opts}, From,
                       #hstate{session_id = SessionId,
                               model = Model} = HState) ->
    case build_summarize_body(Opts, Model) of
        {ok, Body} ->
            Path = <<"/session/", SessionId/binary, "/summarize">>,
            {noreply, [], do_post_json(Path, Body, summarize_session,
                                       From, HState)};
        {error, _} = Err ->
            {error, Err}
    end;

%% Session init / messages
dispatch_rest_endpoint({session_init, Opts}, From,
                       #hstate{session_id = SessionId,
                               opts = SessionOpts} = HState)
  when is_binary(SessionId), is_map(Opts) ->
    case opencode_protocol:build_session_init_input(
             maps:merge(SessionOpts, Opts)) of
        {ok, Body} ->
            Path = <<"/session/", SessionId/binary, "/init">>,
            {noreply, [], do_post_json(Path, Body, session_init,
                                       From, HState)};
        {error, _} = Err ->
            {error, Err}
    end;
dispatch_rest_endpoint(session_messages, From,
                       #hstate{session_id = SessionId} = HState)
  when is_binary(SessionId) ->
    Path = <<"/session/", SessionId/binary, "/message">>,
    {noreply, [], do_get_request(Path, session_messages, From, HState)};
dispatch_rest_endpoint({session_messages, Opts}, From,
                       #hstate{session_id = SessionId} = HState)
  when is_binary(SessionId), is_map(Opts) ->
    Path0 = <<"/session/", SessionId/binary, "/message">>,
    Path = build_query_path(Path0, Opts),
    {noreply, [], do_get_request(Path, session_messages, From, HState)};

%% Prompt async / shell / command
dispatch_rest_endpoint({prompt_async, Prompt, Params}, From,
                       #hstate{session_id = SessionId,
                               opts = SessionOpts} = HState)
  when is_binary(SessionId), is_binary(Prompt), is_map(Params) ->
    Path = <<"/session/", SessionId/binary, "/prompt_async">>,
    Body = opencode_protocol:build_prompt_input(
               Prompt, merge_query_defaults(Params, SessionOpts)),
    {noreply, [], do_post_json(Path, Body, prompt_async, From, HState)};
dispatch_rest_endpoint({shell_command, Command, Opts}, From,
                       #hstate{session_id = SessionId,
                               opts = SessionOpts} = HState)
  when is_binary(SessionId), is_binary(Command), is_map(Opts) ->
    case opencode_protocol:build_shell_input(
             Command, maps:merge(SessionOpts, Opts)) of
        {ok, Body} ->
            Path = <<"/session/", SessionId/binary, "/shell">>,
            {noreply, [], do_post_json(Path, Body, shell_command,
                                       From, HState)};
        {error, _} = Err ->
            {error, Err}
    end;

%% TUI operations
dispatch_rest_endpoint({tui_append_prompt, Text}, From, HState)
  when is_binary(Text) ->
    {noreply, [], do_post_json(<<"/tui/append-prompt">>,
                               #{<<"text">> => Text},
                               tui_append_prompt, From, HState)};
dispatch_rest_endpoint(tui_open_help, From, HState) ->
    {noreply, [], do_post_json(<<"/tui/open-help">>, #{},
                               tui_open_help, From, HState)};

%% Send command
dispatch_rest_endpoint({send_command, Command, Params}, From,
                       #hstate{session_id = SessionId} = HState) ->
    Path = <<"/session/", SessionId/binary, "/command">>,
    Body = Params#{<<"command">> => Command},
    {noreply, [], do_post_json(Path, Body, send_command, From, HState)};

%% Server health
dispatch_rest_endpoint(server_health, From, HState) ->
    {noreply, [], do_get_request(<<"/health">>, server_health,
                                 From, HState)};

%% Unknown request
dispatch_rest_endpoint(_Unknown, _From, _HState) ->
    {error, unsupported}.

%%====================================================================
%% Internal: general helpers
%%====================================================================

-spec decode_json_result(binary()) -> {ok, false | null | true | binary() | [any()] | number() | #{binary() => _}} | {error, decode_failed}.
decode_json_result(<<>>) ->
    {ok, #{}};
decode_json_result(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        _:_ -> {error, decode_failed}
    end.

-spec maybe_reply(gen_statem:from() | undefined, term()) -> ok.
maybe_reply(undefined, _Result) ->
    ok;
maybe_reply(From, Result) ->
    gen_statem:reply(From, Result).

-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(),
                #hstate{}) ->
    ok | {deny, binary()}.
fire_hook(Event, Context,
          #hstate{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).

-spec track_message(beam_agent_core:message(), #hstate{}) -> ok.
track_message(Msg, #hstate{} = HState) ->
    StoreId = session_store_id(HState),
    ok = beam_agent_session_store_core:register_session(
             StoreId, #{adapter => opencode}),
    StoredMsg = maybe_tag_session_id(Msg, StoreId),
    case beam_agent_threads_core:active_thread(StoreId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(
                StoreId, ThreadId, StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(
                StoreId, StoredMsg)
    end,
    ok.

-spec session_store_id(#hstate{}) -> binary().
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

-spec build_sse_path(#hstate{}) -> string().
build_sse_path(#hstate{base_path = Base}) ->
    binary_to_list(<<Base/binary, "/event">>).

-spec build_sse_headers(#hstate{}) -> [{binary(), binary()}].
build_sse_headers(#hstate{auth = Auth, directory = Dir}) ->
    [{<<"accept">>, <<"text/event-stream">>},
     {<<"cache-control">>, <<"no-cache">>},
     {<<"x-opencode-directory">>, Dir} |
     opencode_http:auth_headers(Auth)].

-spec build_session_create_body(#hstate{}) -> map().
build_session_create_body(#hstate{opts = Opts, directory = Dir}) ->
    Base = #{<<"directory">> => Dir},
    case maps:get(model, Opts, undefined) of
        undefined                  -> Base;
        Model when is_map(Model)   -> Base#{<<"model">> => Model};
        Model when is_binary(Model) -> Base#{<<"model">> => Model};
        _                          -> Base
    end.

-spec build_query_path(binary(), map()) -> binary().
build_query_path(EndpointPath, Query) when is_map(Query) ->
    Pairs = [{normalize_query_key(Key), normalize_query_value(Value)}
             || {Key, Value} <- maps:to_list(Query),
                Value =/= undefined,
                Value =/= null],
    case Pairs of
        [] ->
            EndpointPath;
        _ ->
            QueryString = unicode:characters_to_binary(
                              uri_string:compose_query(Pairs)),
            <<EndpointPath/binary, "?", QueryString/binary>>
    end.

-spec normalize_query_key(term()) -> unicode:chardata().
normalize_query_key(Key) when is_atom(Key)   -> atom_to_list(Key);
normalize_query_key(Key) when is_binary(Key) -> binary_to_list(Key);
normalize_query_key(Key) when is_list(Key)   -> Key;
normalize_query_key(Key) ->
    binary_to_list(iolist_to_binary(io_lib:format("~p", [Key]))).

-spec normalize_query_value(term()) -> unicode:chardata().
normalize_query_value(true)                    -> "true";
normalize_query_value(false)                   -> "false";
normalize_query_value(Value) when is_integer(Value) ->
    integer_to_list(Value);
normalize_query_value(Value) when is_float(Value) ->
    binary_to_list(iolist_to_binary(io_lib:format("~g", [Value])));
normalize_query_value(Value) when is_atom(Value) ->
    atom_to_list(Value);
normalize_query_value(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_query_value(Value) when is_list(Value) ->
    Value;
normalize_query_value(Value) ->
    binary_to_list(iolist_to_binary(io_lib:format("~p", [Value]))).

-spec merge_query_defaults(map(), map()) -> map().
merge_query_defaults(Params, Opts) ->
    Defaults = [
        {provider_id, maps:get(provider_id, Opts, undefined)},
        {model_id, maps:get(model_id, Opts, undefined)},
        {mode, maps:get(mode, Opts, undefined)},
        {agent, maps:get(agent, Opts, undefined)},
        {system, maps:get(system, Opts,
                          maps:get(system_prompt, Opts, undefined))},
        {tools, maps:get(tools, Opts, undefined)}
    ],
    lists:foldl(fun({_Key, undefined}, Acc) -> Acc;
                   ({Key, Value}, Acc) ->
                       case maps:is_key(Key, Acc) of
                           true  -> Acc;
                           false -> Acc#{Key => Value}
                       end
                end, Params, Defaults).

-spec build_revert_body(map()) -> {ok, map()} | {error, invalid_selector}.
build_revert_body(Selector) when is_map(Selector) ->
    MessageId = maps:get(message_id, Selector,
                    maps:get(messageID, Selector,
                        maps:get(uuid, Selector, undefined))),
    case MessageId of
        Bin when is_binary(Bin) ->
            Body0 = #{<<"messageID">> => Bin},
            Body1 = case maps:get(part_id, Selector,
                            maps:get(partID, Selector, undefined)) of
                PartId when is_binary(PartId) ->
                    Body0#{<<"partID">> => PartId};
                _ ->
                    Body0
            end,
            {ok, Body1};
        _ ->
            {error, invalid_selector}
    end;
build_revert_body(_) ->
    {error, invalid_selector}.

-spec build_summarize_body(map(), binary() | map() | undefined) ->
    {ok, map()} | {error, invalid_summary_opts}.
build_summarize_body(Opts, Model) when is_map(Opts) ->
    ModelId = maps:get(model_id, Opts,
                  maps:get(modelID, Opts, extract_model_id(Model))),
    ProviderId = maps:get(provider_id, Opts,
                     maps:get(providerID, Opts,
                              extract_provider_id(Model))),
    case {ModelId, ProviderId} of
        {MId, PId} when is_binary(MId), is_binary(PId) ->
            Body0 = #{<<"modelID">> => MId,
                      <<"providerID">> => PId},
            Body1 = case maps:get(message_id, Opts,
                            maps:get(messageID, Opts, undefined)) of
                MsgId when is_binary(MsgId) ->
                    Body0#{<<"messageID">> => MsgId};
                _ ->
                    Body0
            end,
            {ok, Body1};
        _ ->
            {error, invalid_summary_opts}
    end.

-spec extract_model_id(binary() | map() | undefined) -> binary() | undefined.
extract_model_id(#{<<"id">> := Id}) when is_binary(Id)       -> Id;
extract_model_id(#{id := Id}) when is_binary(Id)             -> Id;
extract_model_id(#{<<"modelID">> := Id}) when is_binary(Id)  -> Id;
extract_model_id(_)                                          -> undefined.

-spec extract_provider_id(binary() | map() | undefined) -> binary() | undefined.
extract_provider_id(#{<<"providerID">> := Id}) when is_binary(Id) -> Id;
extract_provider_id(#{provider_id := Id}) when is_binary(Id)      -> Id;
extract_provider_id(#{providerID := Id}) when is_binary(Id)       -> Id;
extract_provider_id(_)                                            -> undefined.
