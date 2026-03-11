%%%-------------------------------------------------------------------
%%% @doc EUnit tests for Codex Realtime session (engine + handler + WS transport).
%%%
%%% Uses `test_ws_client` — a dependency-injected client replacement that
%%% captures outgoing WebSocket frames and lets the test simulate
%%% incoming transport events. No mocking (meck) is used.
%%%
%%% Tests cover:
%%%   - Full session lifecycle (connect → WS upgrade → ready → query → result)
%%%   - Health state transitions through connecting → ready → active_query
%%%   - Session info with backend metadata
%%%   - Realtime thread lifecycle (start, append text, append audio, stop)
%%%   - Query encoding and response.done detection
%%%   - Output buffer accumulation across streaming events
%%%   - Error response handling (response.done with failed status)
%%%   - Interrupt via response.cancel
%%%   - Missing API key rejection
%%%   - Thread not found error
%%%   - Set model via session.update
%%% @end
%%%-------------------------------------------------------------------
-module(codex_realtime_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Full lifecycle test — single sequential test covering happy path
%%====================================================================

realtime_thread_lifecycle_and_query_test() ->
    ensure_started(),
    test_ws_client:setup(),
    try
        run_lifecycle()
    after
        test_ws_client:teardown()
    end.

run_lifecycle() ->
    {ok, Pid} = start_session(),
    ConnPid = test_ws_client:conn_pid(),

    %% 1. Engine starts in connecting state
    ?assertEqual(connecting, codex_realtime_session:health(Pid)),

    %% 2. Session info available even in connecting state
    {ok, Info} = codex_realtime_session:session_info(Pid),
    ?assertEqual(codex, maps:get(backend, Info)),
    ?assertEqual(realtime, maps:get(transport, Info)),
    ?assertEqual(<<"gpt-4o-realtime-preview">>, maps:get(model, Info)),

    %% 3. Simulate TCP connected → handler calls ws_upgrade, stays connecting
    Pid ! {transport_up, ConnPid, http},

    %% 4. Simulate WS upgrade confirmed → handler sends session.update, goes ready
    Pid ! {ws_upgraded, ConnPid, make_ref(), [<<"websocket">>], []},
    wait_for_state(Pid, ready),
    ?assertEqual(ready, codex_realtime_session:health(Pid)),
    ?assert(received_ws_type(<<"session.update">>)),

    %% 5. Start a realtime thread
    {ok, ThreadInfo} = codex_realtime_session:thread_realtime_start(Pid, #{
        mode  => <<"voice">>,
        voice => <<"alloy">>
    }),
    ThreadId = maps:get(thread_id, ThreadInfo),
    ?assertMatch(#{thread_id := _, source := direct_realtime}, ThreadInfo),
    ?assert(received_ws_type(<<"session.update">>)),

    %% 6. Append text → conversation.item.create + response.create
    {ok, TextResult} = codex_realtime_session:thread_realtime_append_text(
        Pid, ThreadId, #{text => <<"hello realtime">>}),
    ?assertMatch(#{appended := true}, TextResult),
    ?assert(received_ws_type(<<"conversation.item.create">>)),
    ?assert(received_ws_type(<<"response.create">>)),

    %% 7. Append audio with commit → append + commit frames
    {ok, AudioResult} = codex_realtime_session:thread_realtime_append_audio(
        Pid, ThreadId, #{audio => <<1, 2, 3>>, commit => true}),
    ?assertMatch(#{appended := true, commit := true}, AudioResult),
    ?assert(received_ws_type(<<"input_audio_buffer.append">>)),
    ?assert(received_ws_type(<<"input_audio_buffer.commit">>)),

    %% 8. Send query → transitions to active_query
    {ok, Ref} = codex_realtime_session:send_query(Pid, <<"Ping">>, #{}, 5000),
    ?assert(received_ws_type(<<"conversation.item.create">>)),
    ?assert(received_ws_type(<<"response.create">>)),

    %% 9. Simulate streaming text event from server
    send_ws_event(Pid, ConnPid, #{
        <<"type">> => <<"conversation.item.created">>,
        <<"item">> => #{
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"Pong">>}
            ]
        }
    }),
    {ok, TextMsg} = codex_realtime_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(text, maps:get(type, TextMsg)),
    ?assertEqual(<<"Pong">>, maps:get(content, TextMsg)),

    %% 10. Simulate response.done → result with accumulated output
    send_ws_event(Pid, ConnPid, #{
        <<"type">> => <<"response.done">>,
        <<"response">> => #{<<"status">> => <<"completed">>}
    }),
    {ok, ResultMsg} = codex_realtime_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(result, maps:get(type, ResultMsg)),
    ?assertEqual(<<"Pong">>, maps:get(content, ResultMsg)),
    ?assertEqual(<<"completed">>, maps:get(stop_reason, ResultMsg)),

    %% 11. Back to ready after result
    wait_for_state(Pid, ready),

    %% 12. Thread stop sends response.cancel
    drain_mailbox(),
    {ok, StopResult} = codex_realtime_session:thread_realtime_stop(
        Pid, ThreadId),
    ?assertMatch(#{stopped := true}, StopResult),
    ?assert(received_ws_type(<<"response.cancel">>)),

    %% 13. Clean shutdown
    ok = codex_realtime_session:stop(Pid).

%%====================================================================
%% Error case: missing API key
%%====================================================================

missing_api_key_test() ->
    ensure_started(),
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try
        process_flag(trap_exit, true),
        Result = codex_realtime_session:start_link(#{
            api_key    => <<>>,
            client_module => test_ws_client
        }),
        %% Drain the EXIT signal from the linked process termination
        receive {'EXIT', _, _} -> ok after 100 -> ok end,
        process_flag(trap_exit, false),
        ?assertMatch({error, missing_api_key}, Result)
    after
        logger:set_primary_config(level, OldLevel)
    end.

%%====================================================================
%% Error case: thread not found
%%====================================================================

thread_not_found_test() ->
    ensure_started(),
    test_ws_client:setup(),
    try
        {ok, Pid} = start_session(),
        ConnPid = test_ws_client:conn_pid(),
        bring_to_ready(Pid, ConnPid),

        ?assertMatch({error, not_found},
            codex_realtime_session:thread_realtime_append_text(
                Pid, <<"nonexistent">>, #{text => <<"hi">>})),

        ?assertMatch({error, not_found},
            codex_realtime_session:thread_realtime_append_audio(
                Pid, <<"nonexistent">>, #{audio => <<1>>, commit => false})),

        ?assertMatch({error, not_found},
            codex_realtime_session:thread_realtime_stop(
                Pid, <<"nonexistent">>)),

        ok = codex_realtime_session:stop(Pid)
    after
        test_ws_client:teardown()
    end.

%%====================================================================
%% Error case: failed response
%%====================================================================

error_response_test() ->
    ensure_started(),
    test_ws_client:setup(),
    try
        {ok, Pid} = start_session(),
        ConnPid = test_ws_client:conn_pid(),
        bring_to_ready(Pid, ConnPid),

        {ok, Ref} = codex_realtime_session:send_query(
            Pid, <<"fail">>, #{}, 5000),
        drain_mailbox(),

        send_ws_event(Pid, ConnPid, #{
            <<"type">> => <<"response.done">>,
            <<"response">> => #{<<"status">> => <<"failed">>}
        }),
        {ok, Msg} = codex_realtime_session:receive_message(Pid, Ref, 5000),
        ?assertEqual(error, maps:get(type, Msg)),
        ?assertEqual(true, maps:get(is_error, Msg)),
        ?assertEqual(<<"realtime response failed">>, maps:get(content, Msg)),

        wait_for_state(Pid, ready),
        ok = codex_realtime_session:stop(Pid)
    after
        test_ws_client:teardown()
    end.

%%====================================================================
%% Interrupt sends response.cancel
%%====================================================================

interrupt_test() ->
    ensure_started(),
    test_ws_client:setup(),
    try
        {ok, Pid} = start_session(),
        ConnPid = test_ws_client:conn_pid(),
        bring_to_ready(Pid, ConnPid),

        {ok, _Ref} = codex_realtime_session:send_query(
            Pid, <<"slow query">>, #{}, 5000),
        drain_mailbox(),

        ok = codex_realtime_session:interrupt(Pid),
        ?assert(received_ws_type(<<"response.cancel">>)),

        wait_for_state(Pid, ready),
        ok = codex_realtime_session:stop(Pid)
    after
        test_ws_client:teardown()
    end.

%%====================================================================
%% set_model sends session.update with new model
%%====================================================================

set_model_test() ->
    ensure_started(),
    test_ws_client:setup(),
    try
        {ok, Pid} = start_session(),
        ConnPid = test_ws_client:conn_pid(),
        bring_to_ready(Pid, ConnPid),

        {ok, <<"gpt-4o-mini">>} = codex_realtime_session:set_model(
            Pid, <<"gpt-4o-mini">>),
        ?assert(received_ws_type(<<"session.update">>)),

        {ok, Info} = codex_realtime_session:session_info(Pid),
        ?assertEqual(<<"gpt-4o-mini">>, maps:get(model, Info)),

        ok = codex_realtime_session:stop(Pid)
    after
        test_ws_client:teardown()
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec ensure_started() -> ok.
ensure_started() ->
    _ = application:ensure_all_started(telemetry),
    ok.

-spec start_session() -> {ok, pid()}.
start_session() ->
    codex_realtime_session:start_link(#{
        api_key      => <<"test-key">>,
        model        => <<"gpt-4o-realtime-preview">>,
        realtime_url => <<"ws://example.test:8080/v1/realtime?model=gpt-4o-realtime-preview">>,
        client_module   => test_ws_client
    }).

-spec bring_to_ready(pid(), pid()) -> ok.
bring_to_ready(Pid, ConnPid) ->
    Pid ! {transport_up, ConnPid, http},
    Pid ! {ws_upgraded, ConnPid, make_ref(), [<<"websocket">>], []},
    wait_for_state(Pid, ready),
    drain_mailbox(),
    ok.

-spec wait_for_state(pid(), atom()) -> ok.
wait_for_state(Pid, State) ->
    wait_for_state(Pid, State, 100).

-spec wait_for_state(pid(), atom(), non_neg_integer()) -> ok.
wait_for_state(_Pid, _State, 0) ->
    error(timeout_waiting_for_state);
wait_for_state(Pid, State, N) ->
    case codex_realtime_session:health(Pid) of
        State -> ok;
        _ -> timer:sleep(5), wait_for_state(Pid, State, N - 1)
    end.

-spec send_ws_event(pid(), pid(), map()) -> ok.
send_ws_event(SessionPid, ConnPid, Json) ->
    Payload = iolist_to_binary(json:encode(Json)),
    SessionPid ! {ws_frame, ConnPid, make_ref(), {text, Payload}},
    ok.

-spec received_ws_type(binary()) -> boolean().
received_ws_type(Type) ->
    received_ws_type(Type, 500).

-spec received_ws_type(binary(), non_neg_integer()) -> boolean().
received_ws_type(Type, Timeout) ->
    receive
        {ws_send, {text, JsonBin}} ->
            Json = json:decode(JsonBin),
            case maps:get(<<"type">>, Json, <<>>) of
                Type -> true;
                _Other -> received_ws_type(Type, Timeout)
            end
    after Timeout ->
        false
    end.

-spec drain_mailbox() -> ok.
drain_mailbox() ->
    receive _ -> drain_mailbox()
    after 0 -> ok
    end.
