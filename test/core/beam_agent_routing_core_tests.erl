%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_routing_core.
%%%-------------------------------------------------------------------
-module(beam_agent_routing_core_tests).

-include_lib("eunit/include/eunit.hrl").

explicit_policy_selects_backend_and_journals_decision_test() ->
    reset(),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        policy => explicit,
        backend => <<"codex">>
    }),
    ?assertEqual(codex, maps:get(backend, Decision)),
    {ok, [Event]} = beam_agent_journal_core:list(#{
        event_type => <<"routing_selected">>,
        limit => 1
    }),
    Payload = maps:get(payload, Event),
    JournalDecision = maps:get(decision, Payload),
    ?assertEqual(codex, maps:get(backend, JournalDecision)),
    reset().

preferred_then_fallback_respects_exclusions_test() ->
    reset(),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        policy => preferred_then_fallback,
        preferred_backends => [gemini, codex],
        fallback_backends => [claude],
        excluded_backends => [gemini]
    }),
    ?assertEqual(codex, maps:get(backend, Decision)),
    ?assert(lists:prefix([claude], maps:get(fallback_chain, Decision))),
    reset().

round_robin_cycles_candidates_test() ->
    reset(),
    Request = #{
        policy => round_robin,
        preferred_backends => [claude, codex]
    },
    {ok, First} = beam_agent_routing_core:select_backend(Request),
    {ok, Second} = beam_agent_routing_core:select_backend(Request),
    ?assertEqual(claude, maps:get(backend, First)),
    ?assertEqual(codex, maps:get(backend, Second)),
    reset().

sticky_policy_reuses_affinity_backend_test() ->
    reset(),
    {ok, First} = beam_agent_routing_core:select_backend(#{
        policy => sticky,
        affinity_key => <<"workspace-a">>,
        preferred_backends => [claude, codex]
    }),
    {ok, Second} = beam_agent_routing_core:select_backend(#{
        policy => sticky,
        affinity_key => <<"workspace-a">>,
        preferred_backends => [codex, claude]
    }),
    ?assertEqual(maps:get(backend, First), maps:get(backend, Second)),
    ?assertEqual(<<"workspace-a">>, maps:get(affinity_key, Second)),
    reset().

failover_deprioritizes_last_backend_test() ->
    reset(),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        policy => failover,
        preferred_backends => [codex, gemini, claude],
        last_backend => codex
    }),
    ?assertEqual(gemini, maps:get(backend, Decision)),
    ?assert(lists:prefix([claude], maps:get(fallback_chain, Decision))),
    ?assertEqual(codex, lists:last(maps:get(fallback_chain, Decision))),
    reset().

capability_validation_rejects_unknown_capability_test() ->
    reset(),
    ?assertEqual({error, {unknown_capability, bogus_capability}},
        beam_agent_routing_core:select_backend(#{
            policy => capability_first,
            capabilities => [bogus_capability]
        })),
    reset().

health_filter_excludes_unhealthy_backends_test() ->
    reset(),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        policy => preferred_then_fallback,
        preferred_backends => [claude, codex],
        health => #{claude => unhealthy, codex => healthy}
    }),
    ?assertEqual(codex, maps:get(backend, Decision)),
    reset().

request_merge_from_session_opts_test() ->
    reset(),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        backend => auto,
        routing => #{
            policy => preferred_then_fallback,
            preferred_backends => [gemini, codex]
        }
    }, #{}),
    ?assertEqual(gemini, maps:get(backend, Decision)),
    reset().

reset() ->
    ok = beam_agent_routing_core:clear(),
    ok = beam_agent_journal_core:clear(),
    ok.
