%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_credential.
%%%
%%% Tests cover:
%%%   - protect/unprotect roundtrip via pure encrypt_map/decrypt_map
%%%   - protect replaces sensitive keys with tuples
%%%   - unprotect restores original values
%%%   - non-sensitive keys are untouched
%%%   - nested maps under sensitive keys are handled
%%%   - is_protected/1
%%%   - nocookie key derivation refusal (S1 hardening)
%%%   - decrypt failure with tampered ciphertext
%%%   - protect_value/unprotect_value via encrypt_term/decrypt_term
%%%
%%% All encryption tests use the pure key-accepting functions
%%% (encrypt_map/2, decrypt_map/2, encrypt_term/2, decrypt_term/4)
%%% with a test-derived key. This avoids requiring distribution
%%% and follows pure functional testing — no mocks, no side effects.
%%%-------------------------------------------------------------------
-module(beam_agent_credential_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test key helper — pure, no distribution required
%%====================================================================

test_key() ->
    {ok, Key} = beam_agent_credential:cookie_to_key(beam_agent_test_cookie),
    Key.

%%====================================================================
%% Roundtrip tests (pure functions)
%%====================================================================

roundtrip_preserves_api_key_test() ->
    Key = test_key(),
    Original = #{api_key => <<"sk-abc123">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
    ?assertEqual(Original, Restored).

roundtrip_preserves_binary_keys_test() ->
    Key = test_key(),
    Original = #{<<"apiKey">> => <<"key1">>,
                 <<"token">> => <<"tok1">>,
                 <<"access_token">> => <<"at1">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
    ?assertEqual(Original, Restored).

roundtrip_preserves_all_sensitive_keys_test() ->
    Key = test_key(),
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
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
    ?assertEqual(Original, Restored).

roundtrip_empty_map_test() ->
    Key = test_key(),
    Original = #{},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
    ?assertEqual(Original, Restored).

%%====================================================================
%% Protection tests
%%====================================================================

protect_replaces_sensitive_with_tuples_test() ->
    Key = test_key(),
    Original = #{api_key => <<"sk-abc123">>, base_url => <<"https://api.test">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(api_key, Protected)),
    ?assertEqual(<<"https://api.test">>, maps:get(base_url, Protected)).

protect_handles_atom_sensitive_keys_test() ->
    Key = test_key(),
    Original = #{token => <<"my-token">>, password => <<"my-pass">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(token, Protected)),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(password, Protected)).

protect_handles_binary_sensitive_keys_test() ->
    Key = test_key(),
    Original = #{<<"apiKey">> => <<"key">>, <<"refreshToken">> => <<"rt">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(<<"apiKey">>, Protected)),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(<<"refreshToken">>, Protected)).

%%====================================================================
%% Non-sensitive key tests
%%====================================================================

non_sensitive_keys_untouched_test() ->
    Key = test_key(),
    Original = #{
        base_url => <<"https://api.test">>,
        organization => <<"org-123">>,
        provider_id => <<"openai">>,
        model_id => <<"gpt-5">>
    },
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    ?assertEqual(Original, Protected).

%%====================================================================
%% Nested map tests
%%====================================================================

nested_map_under_sensitive_key_roundtrips_test() ->
    Key = test_key(),
    Original = #{api_key => #{inner => <<"nested-secret">>}},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(api_key, Protected)),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
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
    Key = test_key(),
    Protected = beam_agent_credential:encrypt_map(#{api_key => <<"sk-abc">>}, Key),
    ?assertEqual(true, beam_agent_credential:is_protected(Protected)).

is_protected_mixed_map_test() ->
    Key = test_key(),
    Protected = beam_agent_credential:encrypt_map(#{
        api_key => <<"sk-abc">>,
        base_url => <<"https://api.test">>
    }, Key),
    ?assertEqual(true, beam_agent_credential:is_protected(Protected)).

%%====================================================================
%% Unique nonces test
%%====================================================================

each_protect_call_uses_unique_nonce_test() ->
    Key = test_key(),
    Map = #{api_key => <<"same-key">>},
    {beam_agent_protected, Nonce1, _, _} =
        maps:get(api_key, beam_agent_credential:encrypt_map(Map, Key)),
    {beam_agent_protected, Nonce2, _, _} =
        maps:get(api_key, beam_agent_credential:encrypt_map(Map, Key)),
    ?assertNotEqual(Nonce1, Nonce2).

%%====================================================================
%% Nocookie key derivation refusal tests (S1 hardening)
%%====================================================================

cookie_to_key_nocookie_returns_error_test() ->
    ?assertEqual({error, nocookie}, beam_agent_credential:cookie_to_key(nocookie)).

cookie_to_key_real_cookie_returns_32_byte_key_test() ->
    {ok, Key} = beam_agent_credential:cookie_to_key(test_cookie),
    ?assertEqual(32, byte_size(Key)).

cookie_to_key_different_cookies_produce_different_keys_test() ->
    {ok, Key1} = beam_agent_credential:cookie_to_key(cookie_alpha),
    {ok, Key2} = beam_agent_credential:cookie_to_key(cookie_beta),
    ?assertNotEqual(Key1, Key2).

cookie_to_key_same_cookie_is_deterministic_test() ->
    {ok, Key1} = beam_agent_credential:cookie_to_key(deterministic_test),
    {ok, Key2} = beam_agent_credential:cookie_to_key(deterministic_test),
    ?assertEqual(Key1, Key2).

%%====================================================================
%% Decrypt failure tests (tampered ciphertext)
%%====================================================================

decrypt_map_with_tampered_ciphertext_raises_test() ->
    Key = test_key(),
    Original = #{api_key => <<"sk-secret">>},
    Protected = beam_agent_credential:encrypt_map(Original, Key),
    {beam_agent_protected, Nonce, _Ciphertext, Tag} = maps:get(api_key, Protected),
    Tampered = Protected#{api_key => {beam_agent_protected, Nonce, <<"bad">>, Tag}},
    ?assertError(credential_decrypt_failed,
                 beam_agent_credential:decrypt_map(Tampered, Key)).

decrypt_term_with_tampered_tag_raises_test() ->
    Key = test_key(),
    Protected = beam_agent_credential:encrypt_term(<<"my-secret">>, Key),
    {beam_agent_protected, Nonce, Ciphertext, _Tag} = Protected,
    ?assertError(credential_decrypt_failed,
                 beam_agent_credential:decrypt_term(Nonce, Ciphertext, <<"bad-tag">>, Key)).

%%====================================================================
%% Cross-key decrypt failure test
%%====================================================================

decrypt_with_wrong_key_raises_test() ->
    {ok, Key1} = beam_agent_credential:cookie_to_key(key_one),
    {ok, Key2} = beam_agent_credential:cookie_to_key(key_two),
    {beam_agent_protected, Nonce, Ciphertext, Tag} =
        beam_agent_credential:encrypt_term(<<"secret">>, Key1),
    ?assertError(credential_decrypt_failed,
                 beam_agent_credential:decrypt_term(Nonce, Ciphertext, Tag, Key2)).

%%====================================================================
%% encrypt_term / decrypt_term roundtrip tests
%%====================================================================

encrypt_term_roundtrip_test() ->
    Key = test_key(),
    Original = {basic, <<"user:pass">>},
    {beam_agent_protected, Nonce, Ciphertext, Tag} =
        beam_agent_credential:encrypt_term(Original, Key),
    Restored = beam_agent_credential:decrypt_term(Nonce, Ciphertext, Tag, Key),
    ?assertEqual(Original, Restored).

unprotect_value_passthrough_for_non_protected_test() ->
    Plain = <<"just-a-string">>,
    ?assertEqual(Plain, beam_agent_credential:unprotect_value(Plain)).

%%====================================================================
%% generate_cookie tests
%%====================================================================

generate_cookie_returns_atom_test() ->
    Cookie = beam_agent_credential:generate_cookie(),
    ?assert(is_atom(Cookie)).

generate_cookie_produces_43_char_atom_test() ->
    %% 32 bytes -> base64url without padding = 43 characters
    Cookie = beam_agent_credential:generate_cookie(),
    ?assertEqual(43, length(atom_to_list(Cookie))).

generate_cookie_produces_unique_values_test() ->
    Cookie1 = beam_agent_credential:generate_cookie(),
    Cookie2 = beam_agent_credential:generate_cookie(),
    ?assertNotEqual(Cookie1, Cookie2).

generate_cookie_derives_valid_key_test() ->
    Cookie = beam_agent_credential:generate_cookie(),
    {ok, Key} = beam_agent_credential:cookie_to_key(Cookie),
    ?assertEqual(32, byte_size(Key)).

generate_cookie_is_urlsafe_base64_test() ->
    Cookie = beam_agent_credential:generate_cookie(),
    Chars = atom_to_list(Cookie),
    %% URL-safe base64 alphabet: [A-Za-z0-9_-], no +, /, or =
    Valid = lists:all(fun(C) ->
        (C >= $A andalso C =< $Z) orelse
        (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $- orelse C =:= $_
    end, Chars),
    ?assert(Valid).
