%%%-------------------------------------------------------------------
%%% @doc Test setup module for beam-agent.
%%%
%%% Seeds the credential encryption key via persistent_term so that
%%% test modules can call protect/unprotect without requiring a
%%% distributed node. This module must be loaded before any test that
%%% exercises credential encryption through the public API.
%%%
%%% For tests that use the pure functions (encrypt_map/2, decrypt_map/2,
%%% etc.) directly, this setup is not needed.
%%%-------------------------------------------------------------------
-module(beam_agent_test_setup).

-include_lib("eunit/include/eunit.hrl").

-export([ensure_test_key/0]).

%% @doc Seed the credential key in persistent_term.
%%
%% Idempotent — safe to call multiple times. Uses `cookie_to_key/1`
%% with a fixed test atom to produce a deterministic 32-byte AES key
%% without requiring Erlang distribution.
-spec ensure_test_key() -> binary().
ensure_test_key() ->
    case persistent_term:get(beam_agent_credential, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        _ ->
            {ok, Key} = beam_agent_credential:cookie_to_key(beam_agent_test_cookie),
            persistent_term:put(beam_agent_credential, Key),
            Key
    end.

%%====================================================================
%% EUnit test — runs during suite to ensure key is seeded
%%====================================================================

seed_credential_key_test() ->
    Key = ensure_test_key(),
    ?assertEqual(32, byte_size(Key)),
    %% Verify the public API works after seeding
    Original = #{api_key => <<"test-key">>},
    Protected = beam_agent_credential:protect(Original),
    ?assert(beam_agent_credential:is_protected(Protected)),
    Restored = beam_agent_credential:unprotect(Protected),
    ?assertEqual(Original, Restored).
