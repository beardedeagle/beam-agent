%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_policy.
%%%-------------------------------------------------------------------
-module(beam_agent_policy_tests).

-include_lib("eunit/include/eunit.hrl").

exports_policy_surface_test() ->
    {module, beam_agent_policy} = code:ensure_loaded(beam_agent_policy),
    ?assert(erlang:function_exported(beam_agent_policy, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, put_profile, 2)),
    ?assert(erlang:function_exported(beam_agent_policy, get_profile, 1)),
    ?assert(erlang:function_exported(beam_agent_policy, list_profiles, 0)),
    ?assert(erlang:function_exported(beam_agent_policy, evaluate, 3)).

public_policy_roundtrip_test() ->
    ok = beam_agent_policy:clear(),
    ok = beam_agent_policy:put_profile(<<"public-policy">>, #{
        default => deny,
        rules => [#{
            action => approval,
            decision => allow,
            match => {eq, method, <<"ok">>}
        }]
    }),
    ?assertEqual(allow,
        beam_agent_policy:evaluate(<<"public-policy">>, approval, #{method => <<"ok">>})),
    ok = beam_agent_policy:clear().
