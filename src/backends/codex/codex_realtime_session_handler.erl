-module(codex_realtime_session_handler).
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
    encode_interrupt/1,
    is_query_complete/2,
    handle_custom_call/3,
    handle_set_model/2,
    handle_set_permission_mode/2
]).

%% Dialyzer: ws_send_actions/2 uses #hstate{} in the spec; the record
%% fields are intentionally broader than the single call-site infers.
-dialyzer({nowarn_function, [ws_send_actions/2]}).

-record(hstate, {
    %% Transport access (from transport_started callback)
    client_module          :: module(),
    conn_pid            :: pid() | undefined,
    ws_ref              :: reference() | undefined,
    path                :: binary(),
    headers             :: [{binary(), binary()}],

    %% Session config
    session_id          :: binary(),
    model               :: binary(),
    voice               :: binary() | undefined,
    opts                :: map(),

    %% Query accumulation
    output_buffer = <<>> :: binary(),

    %% Thread tracking
    active_threads = #{} :: #{binary() => map()}
}).

%%====================================================================
%% Required callbacks
%%====================================================================

-spec backend_name() -> codex.
backend_name() -> codex.

-spec init_handler(beam_agent_core:session_opts()) ->
    beam_agent_session_handler:init_result().
init_handler(Opts) ->
    ClientMod = maps:get(client_module, Opts, beam_agent_ws_client),
    ApiKey = resolve_api_key(Opts),
    case ApiKey of
        <<>> ->
            {stop, missing_api_key};
        _ ->
            Model = maps:get(model, Opts,
                             codex_realtime_protocol:default_model()),
            Voice = maps:get(voice, Opts, undefined),
            SessionId = maps:get(session_id, Opts),
            {Scheme, Host, Port, Path} = resolve_ws_target(Opts, Model),
            Headers = codex_realtime_protocol:build_headers(
                          ApiKey, maps:get(realtime_headers, Opts, #{})),
            TransportOpts = #{
                client_module => ClientMod,
                host       => Host,
                port       => Port,
                scheme     => Scheme
            },
            HState = #hstate{
                client_module     = ClientMod,
                path           = Path,
                headers        = Headers,
                session_id     = SessionId,
                model          = Model,
                voice          = Voice,
                opts           = Opts
            },
            {ok, #{
                transport_spec => {beam_agent_transport_ws, TransportOpts},
                initial_state  => connecting,
                handler_state  => HState
            }}
    end.

-spec handle_data(binary(), #hstate{}) ->
    beam_agent_session_handler:data_result().
handle_data(<<>>, HState) ->
    {ok, [], <<>>, [], HState};
handle_data(Buffer, HState) ->
    try json:decode(Buffer) of
        Json when is_map(Json) ->
            case maps:get(<<"type">>, Json, <<>>) of
                <<"response.done">> ->
                    {Msg, HState1} = handle_response_done(Json, HState),
                    HState2 = HState1#hstate{output_buffer = <<>>},
                    {ok, [Msg], <<>>, [], HState2};
                _ ->
                    Messages = codex_realtime_protocol:normalize_server_event(Json),
                    HState1 = accumulate_output(Messages, HState),
                    {ok, Messages, <<>>, [], HState1}
            end;
        _ ->
            {ok, [], <<>>, [], HState}
    catch
        _:_ ->
            {ok, [], <<>>, [], HState}
    end.

-spec encode_query(binary(), beam_agent_core:query_opts(), #hstate{}) ->
    {ok, term(), #hstate{}} | {error, term()}.
encode_query(_Prompt, _Params, #hstate{ws_ref = undefined}) ->
    {error, not_connected};
encode_query(Prompt, _Params, #hstate{ws_ref = WsRef,
                                      session_id = SessionId} = HState) ->
    _ThreadId = ensure_active_thread(SessionId),
    Messages = codex_realtime_protocol:text_messages(Prompt),
    HState1 = HState#hstate{output_buffer = <<>>},
    {ok, {ws_frames, WsRef, Messages}, HState1}.

-spec build_session_info(#hstate{}) ->
    #{adapter := codex,
      backend := codex,
      model := binary(),
      session_id := binary(),
      system_info := #{host := _, port := _, scheme := _, voice := undefined | binary()},
      transport := realtime}.
build_session_info(#hstate{session_id = SessionId,
                           model = Model,
                           voice = Voice,
                           opts = Opts}) ->
    #{
        session_id  => SessionId,
        model       => Model,
        transport   => realtime,
        adapter     => codex,
        backend     => codex,
        system_info => #{
            host   => maps:get(host, Opts, undefined),
            port   => maps:get(port, Opts, undefined),
            scheme => maps:get(scheme, Opts, undefined),
            voice  => Voice
        }
    }.

-spec terminate_handler(term(), #hstate{}) -> ok.
terminate_handler(_Reason, _HState) ->
    ok.

%%====================================================================
%% Optional callbacks
%%====================================================================

-spec transport_started(beam_agent_transport:transport_ref(), #hstate{}) ->
    #hstate{}.
transport_started({ConnPid, _MonRef, ClientMod}, HState) ->
    HState#hstate{conn_pid = ConnPid, client_module = ClientMod}.

-spec handle_connecting(beam_agent_session_handler:transport_event(),
                        #hstate{}) ->
    beam_agent_session_handler:phase_result().
handle_connecting(connected, #hstate{ws_ref = undefined,
                                     client_module = ClientMod,
                                     conn_pid = ConnPid,
                                     path = Path,
                                     headers = Headers} = HState) ->
    %% TCP connected — initiate WebSocket upgrade
    WsRef = ClientMod:ws_upgrade(ConnPid, binary_to_list(Path), Headers),
    {keep_state, [], HState#hstate{ws_ref = WsRef}};
handle_connecting(connected, #hstate{ws_ref = WsRef,
                                     opts = Opts} = HState)
  when WsRef =/= undefined ->
    %% WebSocket upgrade confirmed — send session.update and go ready
    Msgs = codex_realtime_protocol:session_update_messages(Opts, #{}),
    Actions = case Msgs of
        [] -> [];
        _  -> [{send, {ws_frames, WsRef, Msgs}}]
    end,
    {next_state, ready, Actions, HState};
handle_connecting({disconnected, Reason}, HState) ->
    {error_state, {connection_failed, Reason}, HState};
handle_connecting({exit, _Status}, HState) ->
    {error_state, connection_lost, HState};
handle_connecting(connect_timeout, HState) ->
    {error_state, connect_timeout, HState};
handle_connecting(_Event, HState) ->
    {keep_state, [], HState}.

-spec encode_interrupt(#hstate{}) ->
    {ok, [beam_agent_session_handler:handler_action()], #hstate{}} | not_supported.
encode_interrupt(#hstate{ws_ref = undefined}) ->
    not_supported;
encode_interrupt(#hstate{ws_ref = WsRef} = HState) ->
    Msg = codex_realtime_protocol:interrupt_message(),
    {ok, [{send, {ws_frames, WsRef, [Msg]}}], HState}.

-spec is_query_complete(beam_agent_core:message(), #hstate{}) -> boolean().
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error, is_error := true}, _HState) -> true;
is_query_complete(_, _HState) -> false.

-spec handle_custom_call(term(), gen_statem:from(), #hstate{}) ->
    beam_agent_session_handler:control_result().
handle_custom_call({thread_realtime_start, Params}, _From, HState) ->
    {ok, ThreadInfo, HState1} = start_realtime_thread(Params, HState),
    Actions = session_update_actions(Params, HState1),
    {reply, {ok, ThreadInfo}, Actions, HState1};
handle_custom_call({thread_realtime_append_audio, ThreadId, Params},
                   _From, HState) ->
    case thread_exists(ThreadId, HState) of
        false ->
            {error, not_found};
        true ->
            Audio = maps:get(audio, Params, maps:get(data, Params, <<>>)),
            Commit = maps:get(commit, Params, maps:get(final, Params, false)),
            Msgs = codex_realtime_protocol:audio_messages(Audio, Commit),
            Actions = ws_send_actions(HState, Msgs),
            {reply, {ok, #{thread_id => ThreadId, appended => true,
                           commit => Commit}},
             Actions, HState}
    end;
handle_custom_call({thread_realtime_append_text, ThreadId, Params},
                   _From, HState) ->
    case thread_exists(ThreadId, HState) of
        false ->
            {error, not_found};
        true ->
            Text = maps:get(text, Params, maps:get(content, Params, <<>>)),
            Msgs = codex_realtime_protocol:text_messages(Text),
            Actions = ws_send_actions(HState, Msgs),
            {reply, {ok, #{thread_id => ThreadId, appended => true}},
             Actions, HState}
    end;
handle_custom_call({thread_realtime_stop, ThreadId}, _From, HState) ->
    case thread_exists(ThreadId, HState) of
        false ->
            {error, not_found};
        true ->
            Msg = codex_realtime_protocol:interrupt_message(),
            Actions = ws_send_actions(HState, [Msg]),
            Threads1 = maps:remove(ThreadId, HState#hstate.active_threads),
            {reply, {ok, #{thread_id => ThreadId, stopped => true}},
             Actions, HState#hstate{active_threads = Threads1}}
    end;
handle_custom_call(_Request, _From, _HState) ->
    {error, unsupported}.

-spec handle_set_model(binary(), #hstate{}) ->
    {ok, binary(), [beam_agent_session_handler:handler_action()], #hstate{}}.
handle_set_model(Model, #hstate{opts = Opts} = HState) ->
    HState1 = HState#hstate{model = Model},
    Msgs = codex_realtime_protocol:session_update_messages(
               Opts, #{model => Model}),
    Actions = ws_send_actions(HState1, Msgs),
    {ok, Model, Actions, HState1}.

-spec handle_set_permission_mode(binary(), #hstate{}) ->
    {ok, binary(), [], #hstate{}}.
handle_set_permission_mode(Mode, #hstate{opts = Opts} = HState) ->
    HState1 = HState#hstate{opts = Opts#{permission_mode => Mode}},
    {ok, Mode, [], HState1}.

%%====================================================================
%% Internal: response.done handling
%%====================================================================

-spec handle_response_done(map(), #hstate{}) ->
    {beam_agent_core:message(), #hstate{}}.
handle_response_done(Json, HState) ->
    Status = maps:get(<<"status">>,
                      maps:get(<<"response">>, Json, #{}),
                      <<"completed">>),
    case Status of
        <<"failed">> ->
            Msg = #{
                type      => error,
                is_error  => true,
                content   => <<"realtime response failed">>,
                raw       => Json,
                timestamp => erlang:system_time(millisecond)
            },
            {Msg, HState};
        _ ->
            Msg = #{
                type        => result,
                content     => HState#hstate.output_buffer,
                stop_reason => Status,
                raw         => Json,
                timestamp   => erlang:system_time(millisecond)
            },
            {Msg, HState}
    end.

%%====================================================================
%% Internal: output accumulation
%%====================================================================

-spec accumulate_output([beam_agent_core:message()], #hstate{}) -> #hstate{}.
accumulate_output(Messages, HState) ->
    Content = lists:foldl(fun
        (#{type := text, content := Text}, Acc) when is_binary(Text) ->
            <<Acc/binary, Text/binary>>;
        (_, Acc) ->
            Acc
    end, HState#hstate.output_buffer, Messages),
    HState#hstate{output_buffer = Content}.

%%====================================================================
%% Internal: thread management
%%====================================================================

-spec ensure_active_thread(binary()) -> binary().
ensure_active_thread(SessionId) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            ThreadId;
        {error, none} ->
            {ok, Thread} = beam_agent_threads_core:start_thread(
                               SessionId,
                               #{name => <<"codex-realtime">>}),
            maps:get(thread_id, Thread)
    end.

-spec start_realtime_thread(map(), #hstate{}) -> {ok, map(), #hstate{}}.
start_realtime_thread(Params, #hstate{session_id = SessionId} = HState) ->
    ThreadId = case maps:get(thread_id, Params, undefined) of
        Id when is_binary(Id), byte_size(Id) > 0 -> Id;
        _ ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, Existing} -> Existing;
                {error, none} ->
                    {ok, Thread} = beam_agent_threads_core:start_thread(
                                       SessionId,
                                       #{name => maps:get(name, Params,
                                                          <<"codex-realtime">>)}),
                    maps:get(thread_id, Thread)
            end
    end,
    ThreadInfo = #{
        thread_id  => ThreadId,
        session_id => SessionId,
        status     => active,
        source     => direct_realtime,
        mode       => maps:get(mode, Params, <<"voice">>)
    },
    HState1 = HState#hstate{
        active_threads = (HState#hstate.active_threads)#{
            ThreadId => ThreadInfo
        }
    },
    {ok, ThreadInfo, HState1}.

-spec thread_exists(binary(), #hstate{}) -> boolean().
thread_exists(ThreadId, #hstate{session_id = SessionId,
                                active_threads = Threads}) ->
    maps:is_key(ThreadId, Threads) orelse
        case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
            {ok, _} -> true;
            {error, not_found} -> false
        end.

%%====================================================================
%% Internal: send helpers
%%====================================================================

-spec ws_send_actions(#hstate{}, [#{binary() => binary() | map()}]) ->
    [{send, {ws_frames, reference(), [any()]}}].
ws_send_actions(#hstate{ws_ref = undefined}, _Msgs) ->
    [];
ws_send_actions(#hstate{ws_ref = WsRef}, Msgs) ->
    [{send, {ws_frames, WsRef, Msgs}}].

-spec session_update_actions(map(), #hstate{}) ->
    [beam_agent_session_handler:handler_action()].
session_update_actions(Params, #hstate{opts = Opts} = HState) ->
    case codex_realtime_protocol:session_update_messages(Opts, Params) of
        [] -> [];
        Msgs -> ws_send_actions(HState, Msgs)
    end.

%%====================================================================
%% Internal: configuration
%%====================================================================

-spec resolve_api_key(map()) -> binary().
resolve_api_key(Opts) ->
    case maps:get(api_key, Opts, undefined) of
        Key when is_binary(Key), byte_size(Key) > 0 ->
            Key;
        _ ->
            EnvKey = os:getenv("CODEX_API_KEY",
                               os:getenv("OPENAI_API_KEY", "")),
            unicode:characters_to_binary(EnvKey)
    end.

-spec resolve_ws_target(map(), binary()) ->
    {binary(), binary(), inet:port_number(), binary()}.
resolve_ws_target(Opts, Model) ->
    Url = maps:get(realtime_url, Opts,
        <<"wss://api.openai.com",
          (codex_realtime_protocol:build_ws_path(Model))/binary>>),
    Parsed = uri_string:parse(Url),
    Scheme = normalize_binary(maps:get(scheme, Parsed, <<"wss">>)),
    Host = normalize_binary(maps:get(host, Parsed, <<"api.openai.com">>)),
    Port = case maps:get(port, Parsed, undefined) of
        undefined when Scheme =:= <<"wss">> -> 443;
        undefined -> 80;
        Value -> Value
    end,
    Path0 = normalize_binary(maps:get(path, Parsed, <<"/">>)),
    Query = normalize_binary(maps:get(query, Parsed, <<>>)),
    Path = case Query of
        <<>> -> Path0;
        _    -> <<Path0/binary, "?", Query/binary>>
    end,
    {Scheme, Host, Port, Path}.

-spec normalize_binary(term()) -> binary().
normalize_binary(Value) when is_binary(Value) -> Value;
normalize_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
normalize_binary(Value) ->
    iolist_to_binary(io_lib:format("~tp", [Value])).
