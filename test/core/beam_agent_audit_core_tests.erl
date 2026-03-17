%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_audit_core.
%%%-------------------------------------------------------------------
-module(beam_agent_audit_core_tests).

-include_lib("eunit/include/eunit.hrl").

record_list_and_get_audit_event_test() ->
    reset(),
    {ok, Event} = beam_agent_audit_core:record(routing, decision, #{
        run_id => <<"run-audit-1">>,
        profile_id => <<"profile-audit-1">>
    }, #{
        decision => allow,
        backend => codex
    }),
    EventId = maps:get(event_id, Event),
    {ok, [Listed]} = beam_agent_audit_core:list_events(#{run_id => <<"run-audit-1">>}),
    ?assertEqual(EventId, maps:get(event_id, Listed)),
    {ok, Stored} = beam_agent_audit_core:get_event(EventId),
    ?assertEqual(<<"audit">>, maps:get(event_type, Stored)),
    reset().

list_events_filters_by_payload_fields_test() ->
    reset(),
    {ok, _} = beam_agent_audit_core:record(command, run, #{}, #{
        decision => deny,
        reason => <<"blocked">>
    }),
    {ok, _} = beam_agent_audit_core:record(command, run, #{}, #{
        decision => allow
    }),
    {ok, [Denied]} = beam_agent_audit_core:list_events(#{
        category => command,
        decision => deny
    }),
    ?assertEqual(deny, maps:get(decision, maps:get(payload, Denied))),
    reset().

reset() ->
    ok = beam_agent_journal_core:clear().
