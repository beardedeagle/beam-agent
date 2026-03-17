%%%-------------------------------------------------------------------
%%% @doc Integration tests for policy/audit across canonical BeamAgent domains.
%%%-------------------------------------------------------------------
-module(beam_agent_policy_integration_tests).

-include_lib("eunit/include/eunit.hrl").

command_run_respects_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-command">>, #{
        default => allow,
        rules => [#{
            action => command,
            decision => deny,
            match => '*',
            reason => <<"command blocked">>
        }]
    }),
    ?assertEqual({error, {security, {deny, <<"command blocked">>}}},
        beam_agent_command_core:run(<<"echo blocked">>, #{
            metadata => #{policy_profile_id => <<"deny-command">>}
        })),
    {ok, [Audit]} = beam_agent_audit_core:list_events(#{
        category => command,
        decision => deny
    }),
    ?assertEqual(command, maps:get(category, maps:get(payload, Audit))),
    reset().

control_permission_respects_session_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-approval">>, #{
        default => allow,
        rules => [#{
            action => approval,
            decision => deny,
            match => '*',
            reason => <<"approval blocked">>
        }]
    }),
    SessionId = <<"control-policy-session">>,
    ok = beam_agent_control_core:set_config(SessionId, policy_profile_id, <<"deny-approval">>),
    ?assertEqual({deny, <<"approval blocked">>},
        beam_agent_control_core:request_permission(SessionId, <<"toolUse">>, #{}, #{})),
    reset().

memory_write_respects_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-memory">>, #{
        default => allow,
        rules => [#{
            action => memory_write,
            decision => deny,
            match => '*',
            reason => <<"memory blocked">>
        }]
    }),
    ?assertEqual({error, {policy_denied, <<"memory blocked">>}},
        beam_agent_memory_core:remember(<<"policy-memory-session">>, #{
            content => <<"blocked">>,
            attributes => #{policy_profile_id => <<"deny-memory">>}
        })),
    reset().

routing_respects_backend_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-codex-backend">>, #{
        default => allow,
        rules => [#{
            action => backend,
            decision => deny,
            match => {eq, backend, codex},
            reason => <<"codex backend blocked">>
        }]
    }),
    ?assertEqual({error, {policy_denied, <<"codex backend blocked">>}},
        beam_agent_routing_core:select_backend(#{
            policy => explicit,
            backend => codex,
            policy_profile_id => <<"deny-codex-backend">>
        })),
    reset().

routine_create_respects_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-routine">>, #{
        default => allow,
        rules => [#{
            action => routine,
            decision => deny,
            match => '*',
            reason => <<"routine blocked">>
        }]
    }),
    ?assertEqual({error, {policy_denied, <<"routine blocked">>}},
        beam_agent_routines_core:create(#{
            schedule => #{type => once, at => erlang:system_time(millisecond) + 1000},
            target => #{
                type => run,
                scope => <<"routine-policy-session">>,
                run_opts => #{kind => routine},
                outcome => completed,
                result => ok
            },
            metadata => #{policy_profile_id => <<"deny-routine">>}
        })),
    reset().

orchestrator_spawn_respects_policy_profile_test() ->
    reset(),
    ok = beam_agent_policy_core:put_profile(<<"deny-orchestrator">>, #{
        default => allow,
        rules => [#{
            action => orchestrator,
            decision => deny,
            match => '*',
            reason => <<"delegation blocked">>
        }]
    }),
    SessionId = <<"orchestrator-policy-session">>,
    beam_agent_test_helpers:register_session(SessionId, gemini),
    {ok, ParentRun} = beam_agent_runs:start_run(SessionId, #{kind => parent}),
    ?assertEqual({error, {policy_denied, <<"delegation blocked">>}},
        beam_agent_orchestrator_core:spawn(maps:get(run_id, ParentRun), #{
            metadata => #{policy_profile_id => <<"deny-orchestrator">>}
        })),
    reset().

reset() ->
    ok = beam_agent_policy_core:clear(),
    ok = beam_agent_orchestrator_core:clear(),
    ok = beam_agent_routing_core:clear(),
    ok = beam_agent_routines_core:clear(),
    ok = beam_agent_memory_core:clear(),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_journal_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_session_store_core:clear().
