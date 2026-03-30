%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_journal_core.
%%%-------------------------------------------------------------------
-module(beam_agent_journal_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    ok = beam_agent_journal_core:ensure_tables(),
    ok = beam_agent_journal_core:ensure_tables(),
    ok = beam_agent_journal_core:ensure_tables(),
    reset().

append_roundtrip_and_filtering_test() ->
    reset(),
    SessionId = unique_binary("journal-session"),
    RunId = unique_binary("journal-run"),
    Before = erlang:system_time(millisecond),
    {ok, Entry} = beam_agent_journal_core:append(<<"custom_event">>, #{
        session_id => SessionId,
        run_id => RunId,
        tags => [custom, <<"alpha">>],
        payload => #{ok => true}
    }),
    ?assertMatch(<<"event_", _/binary>>, maps:get(event_id, Entry)),
    ?assertEqual(<<"custom_event">>, maps:get(event_type, Entry)),
    ?assertEqual(SessionId, maps:get(session_id, Entry)),
    ?assertEqual(RunId, maps:get(run_id, Entry)),
    ?assert(lists:member(custom, maps:get(tags, Entry))),
    ?assert(maps:get(timestamp, Entry) >= Before),
    {ok, Entry} = beam_agent_journal_core:get(maps:get(event_id, Entry)),
    {ok, [ByType]} = beam_agent_journal_core:list(#{event_type => <<"custom_event">>}),
    ?assertEqual(maps:get(event_id, Entry), maps:get(event_id, ByType)),
    {ok, [ByTag]} = beam_agent_journal_core:list(#{tag => custom}),
    ?assertEqual(maps:get(event_id, Entry), maps:get(event_id, ByTag)),
    reset().

stream_from_returns_entries_after_cursor_oldest_first_test() ->
    reset(),
    SessionId = unique_binary("journal-stream"),
    {ok, First} = beam_agent_journal_core:append(<<"one">>, #{
        session_id => SessionId,
        tags => [journal],
        payload => #{index => 1}
    }),
    {ok, Second} = beam_agent_journal_core:append(<<"two">>, #{
        session_id => SessionId,
        tags => [journal],
        payload => #{index => 2}
    }),
    {ok, Third} = beam_agent_journal_core:append(<<"three">>, #{
        session_id => SessionId,
        tags => [journal],
        payload => #{index => 3}
    }),
    {ok, [ListedFirst, ListedSecond, ListedThird]} =
        beam_agent_journal_core:list(#{session_id => SessionId}),
    ?assertEqual(maps:get(event_id, First), maps:get(event_id, ListedFirst)),
    ?assertEqual(maps:get(event_id, Second), maps:get(event_id, ListedSecond)),
    ?assertEqual(maps:get(event_id, Third), maps:get(event_id, ListedThird)),
    {ok, [ReplaySecond, ReplayThird]} =
        beam_agent_journal_core:stream_from(maps:get(sequence, First), #{session_id => SessionId}),
    ?assertEqual(maps:get(event_id, Second), maps:get(event_id, ReplaySecond)),
    ?assertEqual(maps:get(event_id, Third), maps:get(event_id, ReplayThird)),
    {ok, [Limited]} = beam_agent_journal_core:stream_from(
        maps:get(sequence, First),
        #{session_id => SessionId, limit => 1}
    ),
    ?assertEqual(maps:get(event_id, Second), maps:get(event_id, Limited)),
    reset().

ack_is_idempotent_and_requires_existing_event_test() ->
    reset(),
    {ok, Entry} = beam_agent_journal_core:append(<<"ack_test">>, #{
        tags => [ack],
        payload => #{done => false}
    }),
    ?assertEqual(ok, beam_agent_journal_core:ack(<<"consumer-1">>, maps:get(event_id, Entry))),
    ?assertEqual(ok, beam_agent_journal_core:ack(<<"consumer-1">>, maps:get(event_id, Entry))),
    ?assertEqual({error, not_found},
        beam_agent_journal_core:ack(<<"consumer-1">>, <<"missing-event">>)),
    reset().

get_ack_returns_not_found_for_missing_test() ->
    reset(),
    ?assertEqual({error, not_found},
        beam_agent_journal_core:get_ack(<<"no-consumer">>, <<"no-event">>)),
    reset().

get_ack_returns_ok_after_ack_test() ->
    reset(),
    {ok, Entry} = beam_agent_journal_core:append(<<"get_ack_test">>, #{
        tags => [ack_read],
        payload => #{done => true}
    }),
    EventId = maps:get(event_id, Entry),
    ConsumerId = <<"consumer-get-ack">>,
    ok = beam_agent_journal_core:ack(ConsumerId, EventId),
    {ok, Ack} = beam_agent_journal_core:get_ack(ConsumerId, EventId),
    ?assertEqual(ConsumerId, maps:get(consumer_id, Ack)),
    ?assertEqual(EventId, maps:get(event_id, Ack)),
    ?assert(is_integer(maps:get(acknowledged_at, Ack))),
    reset().

get_ack_is_idempotent_test() ->
    reset(),
    {ok, Entry} = beam_agent_journal_core:append(<<"idem_ack_test">>, #{
        tags => [ack_read],
        payload => #{ok => true}
    }),
    EventId = maps:get(event_id, Entry),
    ConsumerId = <<"consumer-idem">>,
    ok = beam_agent_journal_core:ack(ConsumerId, EventId),
    {ok, Ack1} = beam_agent_journal_core:get_ack(ConsumerId, EventId),
    ok = beam_agent_journal_core:ack(ConsumerId, EventId),
    {ok, Ack2} = beam_agent_journal_core:get_ack(ConsumerId, EventId),
    ?assertEqual(maps:get(event_id, Ack1), maps:get(event_id, Ack2)),
    reset().

list_acks_empty_for_unknown_consumer_test() ->
    reset(),
    ?assertEqual({ok, []},
        beam_agent_journal_core:list_acks(<<"unknown-consumer">>)),
    reset().

list_acks_returns_newest_first_test() ->
    reset(),
    {ok, E1} = beam_agent_journal_core:append(<<"list_ack_1">>, #{
        tags => [ack_order], payload => #{i => 1}
    }),
    {ok, E2} = beam_agent_journal_core:append(<<"list_ack_2">>, #{
        tags => [ack_order], payload => #{i => 2}
    }),
    {ok, E3} = beam_agent_journal_core:append(<<"list_ack_3">>, #{
        tags => [ack_order], payload => #{i => 3}
    }),
    ConsumerId = <<"consumer-order">>,
    ok = beam_agent_journal_core:ack(ConsumerId, maps:get(event_id, E1)),
    ok = beam_agent_journal_core:ack(ConsumerId, maps:get(event_id, E2)),
    ok = beam_agent_journal_core:ack(ConsumerId, maps:get(event_id, E3)),
    {ok, Acks} = beam_agent_journal_core:list_acks(ConsumerId),
    ?assertEqual(3, length(Acks)),
    %% Verify newest-first ordering: each acknowledged_at >= the next.
    AckTimes = [maps:get(acknowledged_at, A) || A <- Acks],
    ?assertEqual(AckTimes, lists:reverse(lists:sort(AckTimes))),
    %% All three event ids present.
    AckIds = [maps:get(event_id, A) || A <- Acks],
    ?assertEqual(lists:sort([maps:get(event_id, E1),
                             maps:get(event_id, E2),
                             maps:get(event_id, E3)]),
                 lists:sort(AckIds)),
    reset().

append_rejects_thread_without_session_test() ->
    reset(),
    ?assertEqual({error, session_id_required_for_thread},
        beam_agent_journal_core:append(<<"bad_event">>, #{
            thread_id => <<"thread-only">>,
            payload => #{bad => true}
        })),
    reset().

reset() ->
    ok = beam_agent_journal_core:clear().

unique_binary(Prefix) ->
    list_to_binary(io_lib:format("~s-~p", [Prefix,
        erlang:unique_integer([positive, monotonic])])).
