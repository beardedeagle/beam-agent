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
