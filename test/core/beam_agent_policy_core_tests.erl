%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_policy_core.
%%%-------------------------------------------------------------------
-module(beam_agent_policy_core_tests).

-include_lib("eunit/include/eunit.hrl").

put_get_and_list_profiles_roundtrip_test() ->
    reset(),
    ProfileId = <<"policy-roundtrip">>,
    ok = beam_agent_policy_core:put_profile(ProfileId, #{
        default => allow,
        metadata => #{owner => test},
        rules => [
            #{
                action => approval,
                decision => deny,
                match => '*',
                reason => <<"blocked">>
            }
        ]
    }),
    {ok, Profile} = beam_agent_policy_core:get_profile(ProfileId),
    ?assertEqual(ProfileId, maps:get(profile_id, Profile)),
    {ok, [Listed]} = beam_agent_policy_core:list_profiles(),
    ?assertEqual(ProfileId, maps:get(profile_id, Listed)),
    reset().

deny_wins_over_allow_rules_test() ->
    reset(),
    ProfileId = <<"policy-deny-wins">>,
    ok = beam_agent_policy_core:put_profile(ProfileId, #{
        default => allow,
        rules => [
            #{action => backend, decision => allow, match => '*'},
            #{action => backend, decision => deny, match => {eq, backend, codex},
              reason => <<"codex blocked">>}
        ]
    }),
    ?assertEqual({deny, <<"codex blocked">>},
        beam_agent_policy_core:evaluate(ProfileId, backend, #{backend => codex})),
    ?assertEqual(allow,
        beam_agent_policy_core:evaluate(ProfileId, backend, #{backend => gemini})),
    reset().

path_prefix_match_normalizes_slashes_test() ->
    reset(),
    ProfileId = <<"policy-path-prefix">>,
    ok = beam_agent_policy_core:put_profile(ProfileId, #{
        default => allow,
        rules => [
            #{action => command, decision => deny,
              match => {path_prefix, [metadata, cwd], <<"/tmp/secret">>},
              reason => <<"secret cwd blocked">>}
        ]
    }),
    ?assertEqual({deny, <<"secret cwd blocked">>},
        beam_agent_policy_core:evaluate(ProfileId, command, #{
            metadata => #{cwd => <<"\\tmp\\secret\\nested">>}
        })),
    reset().

undefined_profile_id_allows_test() ->
    ?assertEqual(allow,
        beam_agent_policy_core:evaluate(undefined, approval, #{})).

reset() ->
    ok = beam_agent_policy_core:clear().
