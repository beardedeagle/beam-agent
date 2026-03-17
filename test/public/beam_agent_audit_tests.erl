%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_audit.
%%%-------------------------------------------------------------------
-module(beam_agent_audit_tests).

-include_lib("eunit/include/eunit.hrl").

exports_audit_surface_test() ->
    {module, beam_agent_audit} = code:ensure_loaded(beam_agent_audit),
    ?assert(erlang:function_exported(beam_agent_audit, list_events, 0)),
    ?assert(erlang:function_exported(beam_agent_audit, list_events, 1)),
    ?assert(erlang:function_exported(beam_agent_audit, get_event, 1)).

public_audit_roundtrip_test() ->
    ok = beam_agent_journal_core:clear(),
    {ok, Event} = beam_agent_audit_core:record(orchestrator, delegated, #{
        run_id => <<"public-audit-run">>
    }, #{
        decision => allow
    }),
    EventId = maps:get(event_id, Event),
    {ok, [Listed]} = beam_agent_audit:list_events(#{run_id => <<"public-audit-run">>}),
    ?assertEqual(EventId, maps:get(event_id, Listed)),
    {ok, Stored} = beam_agent_audit:get_event(EventId),
    ?assertEqual(<<"audit">>, maps:get(event_type, Stored)),
    ok = beam_agent_journal_core:clear().
