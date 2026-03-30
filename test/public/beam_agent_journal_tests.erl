%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_journal.
%%%-------------------------------------------------------------------
-module(beam_agent_journal_tests).

-include_lib("eunit/include/eunit.hrl").

exports_journal_surface_test() ->
    {module, beam_agent_journal} = code:ensure_loaded(beam_agent_journal),
    ?assert(erlang:function_exported(beam_agent_journal, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, append, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, list, 0)),
    ?assert(erlang:function_exported(beam_agent_journal, list, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, stream_from, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, stream_from, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, get, 1)),
    ?assert(erlang:function_exported(beam_agent_journal, ack, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, get_ack, 2)),
    ?assert(erlang:function_exported(beam_agent_journal, list_acks, 1)).

public_journal_roundtrip_test() ->
    beam_agent_journal:clear(),
    SessionId = <<"public-journal-session">>,
    {ok, Entry} = beam_agent_journal:append(<<"public_event">>, #{
        session_id => SessionId,
        tags => [public],
        payload => #{ok => true}
    }),
    {ok, [Listed]} = beam_agent_journal:list(#{session_id => SessionId}),
    ?assertEqual(maps:get(event_id, Entry), maps:get(event_id, Listed)),
    ?assertEqual(ok, beam_agent_journal:ack(<<"consumer-public">>, maps:get(event_id, Entry))),
    beam_agent_journal:clear().

public_ack_read_roundtrip_test() ->
    beam_agent_journal:clear(),
    {ok, E1} = beam_agent_journal:append(<<"ack_read_1">>, #{
        tags => [ack_read], payload => #{i => 1}
    }),
    {ok, E2} = beam_agent_journal:append(<<"ack_read_2">>, #{
        tags => [ack_read], payload => #{i => 2}
    }),
    Consumer = <<"consumer-ack-read">>,
    %% get_ack before ack → not_found
    ?assertEqual({error, not_found},
        beam_agent_journal:get_ack(Consumer, maps:get(event_id, E1))),
    %% list_acks before any ack → empty
    ?assertEqual({ok, []}, beam_agent_journal:list_acks(Consumer)),
    %% Ack both events
    ok = beam_agent_journal:ack(Consumer, maps:get(event_id, E1)),
    ok = beam_agent_journal:ack(Consumer, maps:get(event_id, E2)),
    %% get_ack returns the record
    {ok, Ack1} = beam_agent_journal:get_ack(Consumer, maps:get(event_id, E1)),
    ?assertEqual(maps:get(event_id, E1), maps:get(event_id, Ack1)),
    %% list_acks returns both, newest first
    {ok, Acks} = beam_agent_journal:list_acks(Consumer),
    ?assertEqual(2, length(Acks)),
    AckTimes = [maps:get(acknowledged_at, A) || A <- Acks],
    ?assertEqual(AckTimes, lists:reverse(lists:sort(AckTimes))),
    AckIds = [maps:get(event_id, A) || A <- Acks],
    ?assertEqual(lists:sort([maps:get(event_id, E1),
                             maps:get(event_id, E2)]),
                 lists:sort(AckIds)),
    beam_agent_journal:clear().
