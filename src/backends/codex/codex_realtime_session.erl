-module(codex_realtime_session).
-behaviour(gen_statem).

-export([start_link/1, send_query/4, receive_message/3, health/1, stop/1]).
-export([thread_realtime_start/2,
         thread_realtime_append_audio/3,
         thread_realtime_append_text/3,
         thread_realtime_stop/2,
         send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2]).
-export([callback_mode/0, init/1, terminate/3]).
-export([connecting/3, ready/3, active_query/3, error/3]).

-dialyzer({no_underspecs,
           [{make_session_id, 0},
            {send_messages, 2},
            {build_session_info, 1}]}).

-record(data, {
    gun_module = gun :: module(),
    conn_pid :: pid() | undefined,
    conn_monitor :: reference() | undefined,
    ws_ref :: reference() | undefined,
    session_id :: binary(),
    host :: binary(),
    port :: inet:port_number(),
    path :: binary(),
    scheme :: binary(),
    api_key :: binary(),
    model :: binary(),
    voice :: binary() | undefined,
    opts = #{} :: map(),
    consumer :: gen_statem:from() | undefined,
    query_ref :: reference() | undefined,
    msg_queue = queue:new() :: queue:queue(),
    output_buffer = <<>> :: binary(),
    active_threads = #{} :: #{binary() => map()},
    query_start_time :: integer() | undefined
}).

-type state_name() :: connecting | ready | active_query | error.
-type state_result() ::
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).

-spec start_link(beam_agent_core:session_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-spec send_query(pid(), binary(), map(), timeout()) -> {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

-spec receive_message(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

-spec health(pid()) -> ready | connecting | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).

-spec thread_realtime_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Pid, Params) ->
    gen_statem:call(Pid, {thread_realtime_start, Params}, 30000).

-spec thread_realtime_append_audio(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_append_audio(Pid, ThreadId, Params) ->
    gen_statem:call(Pid, {thread_realtime_append_audio, ThreadId, Params}, 30000).

-spec thread_realtime_append_text(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_append_text(Pid, ThreadId, Params) ->
    gen_statem:call(Pid, {thread_realtime_append_text, ThreadId, Params}, 30000).

-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Pid, ThreadId) ->
    gen_statem:call(Pid, {thread_realtime_stop, ThreadId}, 30000).

-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 30000).

-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).

-spec set_model(pid(), binary()) -> {ok, binary()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).

-spec set_permission_mode(pid(), binary()) -> {ok, binary()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5000).

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(connecting) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    GunModule = maps:get(gun_module, Opts, gun),
    SessionId = maps:get(session_id, Opts, make_session_id()),
    Model = maps:get(model, Opts, codex_realtime_protocol:default_model()),
    Voice = maps:get(voice, Opts, undefined),
    ApiKey = resolve_api_key(Opts),
    case ApiKey of
        <<>> ->
            {stop, missing_api_key};
        _ ->
            {Scheme, Host, Port, Path} = resolve_ws_target(Opts, Model),
            OpenOpts = case Scheme of
                <<"wss">> -> #{transport => tls, protocols => [http]};
                _ -> #{protocols => [http]}
            end,
            case GunModule:open(binary_to_list(Host), Port, OpenOpts) of
                {ok, ConnPid} ->
                    Data = #data{
                        gun_module = GunModule,
                        conn_pid = ConnPid,
                        conn_monitor = erlang:monitor(process, ConnPid),
                        session_id = SessionId,
                        host = Host,
                        port = Port,
                        path = Path,
                        scheme = Scheme,
                        api_key = ApiKey,
                        model = Model,
                        voice = Voice,
                        opts = Opts
                    },
                    {ok, connecting, Data, [{state_timeout, 15000, connect_timeout}]};
                {error, Reason} ->
                    {stop, {gun_open_failed, Reason}}
            end
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, #data{gun_module = GunModule, conn_pid = ConnPid}) ->
    maybe_close(GunModule, ConnPid),
    ok.

-spec connecting(gen_statem:event_type(), term(), #data{}) -> state_result().
connecting(enter, _OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, undefined, connecting),
    keep_state_and_data;
connecting(info, {gun_up, ConnPid, _Protocol},
           #data{conn_pid = ConnPid,
                 gun_module = GunModule,
                 path = Path,
                 api_key = ApiKey,
                 opts = Opts} = Data) ->
    Headers = codex_realtime_protocol:build_headers(ApiKey, maps:get(realtime_headers, Opts, #{})),
    WsRef = GunModule:ws_upgrade(ConnPid, binary_to_list(Path), Headers),
    {keep_state, Data#data{ws_ref = WsRef}};
connecting(info, {gun_upgrade, ConnPid, WsRef, _Protocols, _Headers},
           #data{conn_pid = ConnPid, ws_ref = WsRef} = Data) ->
    ok = send_messages(codex_realtime_protocol:session_update_messages(Data#data.opts, #{}), Data),
    {next_state, ready, Data};
connecting(info, {gun_down, ConnPid, _Protocol, Reason, _Killed},
           #data{conn_pid = ConnPid} = Data) ->
    {next_state, error, Data#data{conn_pid = undefined},
     [{next_event, internal, {connection_error, Reason}}]};
connecting(info, {'DOWN', MonRef, process, ConnPid, Reason},
           #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    {next_state, error, Data#data{conn_pid = undefined},
     [{next_event, internal, {connection_error, Reason}}]};
connecting(state_timeout, connect_timeout, Data) ->
    {next_state, error, Data, [{next_event, internal, connect_timeout}]};
connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};
connecting({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
connecting({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, connecting}}]}.

-spec ready(gen_statem:event_type(), term(), #data{}) -> state_result().
ready(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, ready),
    keep_state_and_data;
ready(info, Event, Data) ->
    handle_transport_info(Event, ready, Data);
ready({call, From}, {send_query, Prompt, _Params}, Data) ->
    ThreadId = ensure_active_thread(Data),
    Ref = make_ref(),
    StartTime = beam_agent_telemetry_core:span_start(codex, query, #{prompt => Prompt}),
    case send_messages(codex_realtime_protocol:text_messages(Prompt), Data) of
        ok ->
            {next_state, active_query,
             Data#data{
                 query_ref = Ref,
                 consumer = undefined,
                 msg_queue = queue:new(),
                 output_buffer = <<>>,
                 query_start_time = StartTime
             },
             [{reply, From, {ok, Ref}},
              {next_event, internal, {query_thread, ThreadId}}]};
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
ready({call, From}, {thread_realtime_start, Params}, Data) ->
    {ok, ThreadInfo, Data1} = start_realtime_thread(Params, Data),
    {keep_state, Data1, [{reply, From, {ok, ThreadInfo}}]};
ready({call, From}, {thread_realtime_append_audio, ThreadId, Params}, Data) ->
    {Reply, Data1} = append_audio(ThreadId, Params, Data),
    {keep_state, Data1, [{reply, From, Reply}]};
ready({call, From}, {thread_realtime_append_text, ThreadId, Params}, Data) ->
    {Reply, Data1} = append_text(ThreadId, Params, Data),
    {keep_state, Data1, [{reply, From, Reply}]};
ready({call, From}, {thread_realtime_stop, ThreadId}, Data) ->
    {Reply, Data1} = stop_realtime_thread(ThreadId, Data),
    {keep_state, Data1, [{reply, From, Reply}]};
ready({call, From}, {send_control, <<"session.update">>, Params}, Data) ->
    case send_messages(codex_realtime_protocol:session_update_messages(Data#data.opts, Params), Data) of
        ok -> {keep_state_and_data, [{reply, From, {ok, Params}}]};
        {error, _} = Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;
ready({call, From}, {send_control, _Method, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, {unsupported_native_call, send_control}}}]};
ready({call, From}, interrupt, Data) ->
    case send_messages([codex_realtime_protocol:interrupt_message()], Data) of
        ok -> {keep_state_and_data, [{reply, From, ok}]};
        {error, _} = Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;
ready({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {set_model, Model}, Data) ->
    Data1 = Data#data{model = Model},
    case send_messages(codex_realtime_protocol:session_update_messages(Data1#data.opts, #{model => Model}), Data1) of
        ok -> {keep_state, Data1, [{reply, From, {ok, Model}}]};
        {error, _} = Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;
ready({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state, Data#data{opts = (Data#data.opts)#{permission_mode => Mode}},
     [{reply, From, {ok, Mode}}]};
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, {receive_message, Ref}, #data{query_ref = Ref, msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            Data1 = case queue:is_empty(Q1) of
                true -> Data#data{msg_queue = Q1, query_ref = undefined};
                false -> Data#data{msg_queue = Q1}
            end,
            {keep_state, Data1, [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state_and_data, [{reply, From, {error, complete}}]}
    end;
ready({call, From}, {receive_message, _Ref}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
ready({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unsupported}}]}.

-spec active_query(gen_statem:event_type(), term(), #data{}) -> state_result().
active_query(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, active_query),
    keep_state_and_data;
active_query(info, Event, Data) ->
    handle_transport_info(Event, active_query, Data);
active_query(internal, {query_thread, _ThreadId}, _Data) ->
    keep_state_and_data;
active_query({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, interrupt, Data) ->
    case send_messages([codex_realtime_protocol:interrupt_message()], Data) of
        ok ->
            {next_state, ready,
             Data#data{query_ref = undefined, consumer = undefined, query_start_time = undefined},
             [{reply, From, ok}]};
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
active_query({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.

-spec error(gen_statem:event_type(), term(), #data{}) -> state_result().
error(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(codex, OldState, error),
    keep_state_and_data;
error(internal, _Reason, _Data) ->
    keep_state_and_data;
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};
error({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec resolve_api_key(map()) -> binary().
resolve_api_key(Opts) ->
    case maps:get(api_key, Opts, undefined) of
        Key when is_binary(Key), byte_size(Key) > 0 ->
            Key;
        _ ->
            EnvKey = os:getenv("CODEX_API_KEY", os:getenv("OPENAI_API_KEY", "")),
            unicode:characters_to_binary(EnvKey)
    end.

-spec resolve_ws_target(map(), binary()) -> {binary(), binary(), inet:port_number(), binary()}.
resolve_ws_target(Opts, Model) ->
    Url = maps:get(realtime_url, Opts,
        <<"wss://api.openai.com", (codex_realtime_protocol:build_ws_path(Model))/binary>>),
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
        _ -> <<Path0/binary, "?", Query/binary>>
    end,
    {Scheme, Host, Port, Path}.

-spec normalize_binary(term()) -> binary().
normalize_binary(Value) when is_binary(Value) -> Value;
normalize_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_binary(Value) -> iolist_to_binary(io_lib:format("~tp", [Value])).

-spec make_session_id() -> binary().
make_session_id() ->
    <<"codex-realtime-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

-spec ensure_active_thread(#data{}) -> binary().
ensure_active_thread(Data) ->
    SessionId = Data#data.session_id,
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            ThreadId;
        {error, none} ->
            {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{name => <<"codex-realtime">>}),
            maps:get(thread_id, Thread)
    end.

-spec start_realtime_thread(map(), #data{}) -> {ok, map(), #data{}}.
start_realtime_thread(Params, Data) ->
    SessionId = Data#data.session_id,
    ThreadId = case maps:get(thread_id, Params, undefined) of
        Id when is_binary(Id), byte_size(Id) > 0 -> Id;
        _ ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, Existing} -> Existing;
                {error, none} ->
                    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{
                        name => maps:get(name, Params, <<"codex-realtime">>)
                    }),
                    maps:get(thread_id, Thread)
            end
    end,
    ok = maybe_update_session(Params, Data),
    ThreadInfo = #{
        thread_id => ThreadId,
        session_id => SessionId,
        status => active,
        source => direct_realtime,
        mode => maps:get(mode, Params, <<"voice">>)
    },
    {ok, ThreadInfo,
     Data#data{active_threads = (Data#data.active_threads)#{ThreadId => ThreadInfo}}}.

-spec append_audio(binary(), map(), #data{}) -> {{ok, map()} | {error, term()}, #data{}}.
append_audio(ThreadId, Params, Data) ->
    case maps:is_key(ThreadId, Data#data.active_threads) orelse thread_exists(Data#data.session_id, ThreadId) of
        false ->
            {{error, not_found}, Data};
        true ->
            Audio = maps:get(audio, Params, maps:get(data, Params, <<>>)),
            Commit = maps:get(commit, Params, maps:get(final, Params, false)),
            case send_messages(codex_realtime_protocol:audio_messages(Audio, Commit), Data) of
                ok ->
                    {{ok, #{thread_id => ThreadId, appended => true, commit => Commit}}, Data};
                {error, _} = Error ->
                    {Error, Data}
            end
    end.

-spec append_text(binary(), map(), #data{}) -> {{ok, map()} | {error, term()}, #data{}}.
append_text(ThreadId, Params, Data) ->
    case maps:is_key(ThreadId, Data#data.active_threads) orelse thread_exists(Data#data.session_id, ThreadId) of
        false ->
            {{error, not_found}, Data};
        true ->
            Text = maps:get(text, Params, maps:get(content, Params, <<>>)),
            case send_messages(codex_realtime_protocol:text_messages(Text), Data) of
                ok ->
                    {{ok, #{thread_id => ThreadId, appended => true}}, Data};
                {error, _} = Error ->
                    {Error, Data}
            end
    end.

-spec stop_realtime_thread(binary(), #data{}) -> {{ok, map()} | {error, term()}, #data{}}.
stop_realtime_thread(ThreadId, Data) ->
    case maps:is_key(ThreadId, Data#data.active_threads) orelse thread_exists(Data#data.session_id, ThreadId) of
        false ->
            {{error, not_found}, Data};
        true ->
            case send_messages([codex_realtime_protocol:interrupt_message()], Data) of
                ok ->
                    Threads1 = maps:remove(ThreadId, Data#data.active_threads),
                    {{ok, #{thread_id => ThreadId, stopped => true}}, Data#data{active_threads = Threads1}};
                {error, _} = Error ->
                    {Error, Data}
            end
    end.

-spec maybe_update_session(map(), #data{}) -> ok | {error, term()}.
maybe_update_session(Params, Data) ->
    case codex_realtime_protocol:session_update_messages(Data#data.opts, Params) of
        [] -> ok;
        Messages -> send_messages(Messages, Data)
    end.

-spec thread_exists(binary(), binary()) -> boolean().
thread_exists(SessionId, ThreadId) ->
    case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.

-spec send_messages([map()], #data{}) -> ok | {error, term()}.
send_messages(Messages, #data{gun_module = GunModule, conn_pid = ConnPid, ws_ref = WsRef}) ->
    send_message_list(normalize_messages(Messages), GunModule, ConnPid, WsRef).

normalize_messages(Messages) when is_list(Messages) -> Messages.

-spec send_message_list([map()], module(), pid() | undefined, reference() | undefined) ->
    ok | {error, term()}.
send_message_list(_Messages, _GunModule, undefined, _WsRef) ->
    {error, not_connected};
send_message_list(_Messages, _GunModule, _ConnPid, undefined) ->
    {error, not_connected};
send_message_list(Messages, GunModule, ConnPid, WsRef) ->
    lists:foldl(fun(Message, Acc) ->
        case Acc of
            ok ->
                Json = iolist_to_binary(json:encode(Message)),
                case GunModule:ws_send(ConnPid, WsRef, {text, Json}) of
                    ok -> ok;
                    {error, _} = Error -> Error;
                    Other -> {error, {ws_send_failed, Other}}
                end;
            Error ->
                Error
        end
    end, ok, Messages).

-spec handle_transport_info(term(), state_name(), #data{}) -> state_result().
handle_transport_info({gun_ws, ConnPid, WsRef, {text, Payload}},
                      StateName,
                      #data{conn_pid = ConnPid, ws_ref = WsRef} = Data) ->
    handle_ws_payload(Payload, StateName, Data);
handle_transport_info({gun_down, ConnPid, _Protocol, Reason, _Killed},
                      _StateName,
                      #data{conn_pid = ConnPid} = Data) ->
    {next_state, error, Data#data{conn_pid = undefined},
     [{next_event, internal, {connection_error, Reason}}]};
handle_transport_info({'DOWN', MonRef, process, ConnPid, Reason},
                      _StateName,
                      #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    {next_state, error, Data#data{conn_pid = undefined},
     [{next_event, internal, {connection_error, Reason}}]};
handle_transport_info(_Other, _StateName, _Data) ->
    keep_state_and_data.

-spec handle_ws_payload(binary(), state_name(), #data{}) -> state_result().
handle_ws_payload(Payload, StateName, Data) ->
    try json:decode(Payload) of
        Json when is_map(Json) ->
            case maps:get(<<"type">>, Json, <<>>) of
                <<"response.done">> ->
                    handle_response_done(Json, Data);
                _ ->
                    Messages = codex_realtime_protocol:normalize_server_event(Json),
                    handle_messages(Messages, StateName, Data)
            end;
        _ ->
            keep_state_and_data
    catch
        _:_ ->
            keep_state_and_data
    end.

-spec handle_response_done(map(), #data{}) -> state_result().
handle_response_done(Json, Data) ->
    Status = maps:get(<<"status">>, maps:get(<<"response">>, Json, #{}), <<"completed">>),
    case Status of
        <<"failed">> ->
            Error = #{
                type => error,
                content => <<"realtime response failed">>,
                raw => Json,
                timestamp => erlang:system_time(millisecond)
            },
            finish_query(Error, Data);
        _ ->
            Result = #{
                type => result,
                content => Data#data.output_buffer,
                stop_reason => Status,
                raw => Json,
                timestamp => erlang:system_time(millisecond)
            },
            finish_query(Result, Data)
    end.

-spec finish_query(beam_agent_core:message(), #data{}) -> state_result().
finish_query(Message, Data) ->
    _ = maybe_span_stop(Data),
    track_message(Message, Data),
    case Data#data.consumer of
        undefined ->
            Q1 = queue:in(Message, Data#data.msg_queue),
            {next_state, ready,
             Data#data{
                 msg_queue = Q1,
                 output_buffer = <<>>,
                 query_start_time = undefined
             }};
        From ->
            {next_state, ready,
             Data#data{
                 consumer = undefined,
                 query_ref = undefined,
                 output_buffer = <<>>,
                 query_start_time = undefined
             },
             [{reply, From, {ok, Message}}]}
    end.

-spec handle_messages([beam_agent_core:message()], state_name(), #data{}) -> state_result().
handle_messages([], _StateName, _Data) ->
    keep_state_and_data;
handle_messages(Messages, ready, Data) ->
    lists:foreach(fun(Msg) -> track_message(Msg, Data) end, Messages),
    {keep_state, accumulate_output(Messages, Data)};
handle_messages(Messages, active_query, Data) ->
    Data1 = accumulate_output(Messages, Data),
    lists:foldl(fun(Msg, {keep_state, AccData}) ->
        track_message(Msg, AccData),
        case AccData#data.consumer of
            undefined ->
                {keep_state, AccData#data{msg_queue = queue:in(Msg, AccData#data.msg_queue)}};
            From ->
                {keep_state,
                 AccData#data{consumer = undefined},
                 [{reply, From, {ok, Msg}}]}
        end;
        (_Msg, Acc) ->
            Acc
    end, {keep_state, Data1}, Messages).

-spec accumulate_output([beam_agent_core:message()], #data{}) -> #data{}.
accumulate_output(Messages, Data) ->
    Content = lists:foldl(fun
        (#{type := text, content := Text}, Acc) when is_binary(Text) ->
            <<Acc/binary, Text/binary>>;
        (_, Acc) ->
            Acc
    end, Data#data.output_buffer, Messages),
    Data#data{output_buffer = Content}.

-spec try_deliver_message(gen_statem:from(), #data{}) -> state_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1}, [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state, Data#data{consumer = From}}
    end.

-spec track_message(beam_agent_core:message(), #data{}) -> ok.
track_message(Msg, Data) ->
    SessionId = Data#data.session_id,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        adapter => codex,
        model => Data#data.model,
        extra => #{transport => realtime}
    }),
    Stored = maybe_tag_session_id(Msg, SessionId),
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Stored);
        {error, none} ->
            beam_agent_session_store_core:record_message(SessionId, Stored)
    end,
    ok.

-spec maybe_tag_session_id(beam_agent_core:message(), binary()) -> beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.

-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{
        session_id => Data#data.session_id,
        model => Data#data.model,
        transport => realtime,
        adapter => codex,
        backend => codex,
        system_info => #{
            host => Data#data.host,
            port => Data#data.port,
            path => Data#data.path,
            scheme => Data#data.scheme,
            voice => Data#data.voice
        }
    }.

-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(codex, query, StartTime).

-spec maybe_close(module(), pid() | undefined) -> ok.
maybe_close(_GunModule, undefined) ->
    ok;
maybe_close(GunModule, ConnPid) ->
    catch GunModule:close(ConnPid),
    ok.
