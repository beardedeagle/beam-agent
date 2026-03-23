%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_credential.
%%%
%%% Tests cover:
%%%   - protect/unprotect roundtrip preserves values
%%%   - protect replaces sensitive keys with tuples
%%%   - unprotect restores original values
%%%   - non-sensitive keys are untouched
%%%   - nested maps under sensitive keys are handled
%%%   - is_protected/1
%%%-------------------------------------------------------------------
-module(beam_agent_credential_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Roundtrip tests
%%====================================================================

roundtrip_preserves_api_key_test() ->
    Original = #{api_key => <<"sk-abc123">>},
    Protected = beam_agent_credential:protect(Original),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).

roundtrip_preserves_binary_keys_test() ->
    Original = #{<<"apiKey">> => <<"key1">>,
                 <<"token">> => <<"tok1">>,
                 <<"access_token">> => <<"at1">>},
    Protected = beam_agent_credential:protect(Original),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).

roundtrip_preserves_all_sensitive_keys_test() ->
    Original = #{
        api_key => <<"k1">>,
        <<"apiKey">> => <<"k2">>,
        <<"api_key">> => <<"k3">>,
        token => <<"t1">>,
        <<"token">> => <<"t2">>,
        access_token => <<"at1">>,
        <<"accessToken">> => <<"at2">>,
        <<"access_token">> => <<"at3">>,
        refresh_token => <<"rt1">>,
        <<"refreshToken">> => <<"rt2">>,
        <<"refresh_token">> => <<"rt3">>,
        client_secret => <<"cs1">>,
        <<"clientSecret">> => <<"cs2">>,
        <<"client_secret">> => <<"cs3">>,
        secret => <<"s1">>,
        <<"secret">> => <<"s2">>,
        password => <<"p1">>,
        <<"password">> => <<"p2">>,
        private_key => <<"pk1">>,
        <<"privateKey">> => <<"pk2">>,
        <<"private_key">> => <<"pk3">>,
        github_token => <<"gt1">>,
        <<"githubToken">> => <<"gt2">>,
        <<"github_token">> => <<"gt3">>
    },
    Protected = beam_agent_credential:protect(Original),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).

roundtrip_empty_map_test() ->
    Original = #{},
    Protected = beam_agent_credential:protect(Original),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).

%%====================================================================
%% Protection tests
%%====================================================================

protect_replaces_sensitive_with_tuples_test() ->
    Original = #{api_key => <<"sk-abc123">>, base_url => <<"https://api.test">>},
    Protected = beam_agent_credential:protect(Original),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(api_key, Protected)),
    ?assertEqual(<<"https://api.test">>, maps:get(base_url, Protected)).

protect_handles_atom_sensitive_keys_test() ->
    Original = #{token => <<"my-token">>, password => <<"my-pass">>},
    Protected = beam_agent_credential:protect(Original),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(token, Protected)),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(password, Protected)).

protect_handles_binary_sensitive_keys_test() ->
    Original = #{<<"apiKey">> => <<"key">>, <<"refreshToken">> => <<"rt">>},
    Protected = beam_agent_credential:protect(Original),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(<<"apiKey">>, Protected)),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(<<"refreshToken">>, Protected)).

%%====================================================================
%% Non-sensitive key tests
%%====================================================================

non_sensitive_keys_untouched_test() ->
    Original = #{
        base_url => <<"https://api.test">>,
        organization => <<"org-123">>,
        provider_id => <<"openai">>,
        model_id => <<"gpt-5">>
    },
    Protected = beam_agent_credential:protect(Original),
    ?assertEqual(Original, Protected).

%%====================================================================
%% Nested map tests
%%====================================================================

nested_map_under_sensitive_key_roundtrips_test() ->
    Original = #{api_key => #{inner => <<"nested-secret">>}},
    Protected = beam_agent_credential:protect(Original),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(api_key, Protected)),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).

%%====================================================================
%% is_protected tests
%%====================================================================

is_protected_empty_map_test() ->
    ?assertEqual(false, beam_agent_credential:is_protected(#{})).

is_protected_unprotected_map_test() ->
    ?assertEqual(false, beam_agent_credential:is_protected(#{
        base_url => <<"https://api.test">>,
        provider_id => <<"openai">>
    })).

is_protected_protected_map_test() ->
    Protected = beam_agent_credential:protect(#{api_key => <<"sk-abc">>}),
    ?assertEqual(true, beam_agent_credential:is_protected(Protected)).

is_protected_mixed_map_test() ->
    Protected = beam_agent_credential:protect(#{
        api_key => <<"sk-abc">>,
        base_url => <<"https://api.test">>
    }),
    ?assertEqual(true, beam_agent_credential:is_protected(Protected)).

%%====================================================================
%% Unique nonces test
%%====================================================================

each_protect_call_uses_unique_nonce_test() ->
    Map = #{api_key => <<"same-key">>},
    {beam_agent_protected, Nonce1, _, _} = maps:get(api_key, beam_agent_credential:protect(Map)),
    {beam_agent_protected, Nonce2, _, _} = maps:get(api_key, beam_agent_credential:protect(Map)),
    ?assertNotEqual(Nonce1, Nonce2).
