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
    ?assert(erlang:function_exported(beam_agent_journal, ack, 2)).

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
