-module(beam_agent_credential).
-moduledoc """
Symmetric encryption for sensitive credential fields stored in ETS.

Uses AES-256-GCM with a per-node key derived from the BEAM node cookie
or a configured secret. This prevents casual ets:tab2list reads from
exposing plaintext API keys.

Note: This is defense-in-depth, not a security boundary. Any process
with access to the node cookie can derive the key. The goal is to
prevent accidental exposure in logs, crash dumps, and admin UIs.
""".

-export([
    protect/1,
    unprotect/1,
    is_protected/1
]).

-define(SENSITIVE_KEYS, [api_key, <<"apiKey">>, <<"api_key">>,
                         token, <<"token">>,
                         access_token, <<"accessToken">>, <<"access_token">>,
                         refresh_token, <<"refreshToken">>, <<"refresh_token">>,
                         client_secret, <<"clientSecret">>, <<"client_secret">>,
                         secret, <<"secret">>,
                         password, <<"password">>,
                         private_key, <<"privateKey">>, <<"private_key">>,
                         github_token, <<"githubToken">>, <<"github_token">>]).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-doc """
Encrypt sensitive fields in a map before ETS storage.

Walks top-level keys and replaces values whose keys match the sensitive
key list with `{beam_agent_protected, Nonce, Ciphertext, Tag}` tuples.
Nested maps under sensitive keys are serialized to binary before encryption.
Non-sensitive keys are left untouched.
""".
-spec protect(map()) -> map().
protect(Map) when is_map(Map) ->
    maps:map(fun(Key, Value) ->
        case is_sensitive(Key) of
            true -> encrypt_value(Value);
            false -> Value
        end
    end, Map).

-doc """
Decrypt previously protected fields in a map after ETS read.

Reverses `protect/1` by decrypting any values stored as
`{beam_agent_protected, Nonce, Ciphertext, Tag}` tuples.
Non-protected values pass through unchanged.
""".
-spec unprotect(map()) -> map().
unprotect(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) ->
        case Value of
            {beam_agent_protected, Nonce, Ciphertext, Tag} ->
                decrypt_value(Nonce, Ciphertext, Tag);
            _ ->
                Value
        end
    end, Map).

-doc """
Check whether a map contains any protected (encrypted) values.

Returns `true` if at least one value is a `{beam_agent_protected, _, _, _}`
tuple.
""".
-spec is_protected(map()) -> boolean().
is_protected(Map) when is_map(Map) ->
    maps:fold(fun
        (_Key, {beam_agent_protected, _, _, _}, _Acc) -> true;
        (_Key, _Value, Acc) -> Acc
    end, false, Map).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec is_sensitive(term()) -> boolean().
is_sensitive(Key) ->
    lists:member(Key, ?SENSITIVE_KEYS).

-spec derive_key() -> binary().
derive_key() ->
    Cookie = erlang:get_cookie(),
    crypto:hash(sha256, atom_to_binary(Cookie, utf8)).

-spec encrypt_value(term()) -> {beam_agent_protected, binary(), binary(), binary()}.
encrypt_value(Value) ->
    Key = derive_key(),
    Nonce = crypto:strong_rand_bytes(12),
    Plaintext = term_to_binary(Value),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, Plaintext, <<>>, true),
    {beam_agent_protected, Nonce, Ciphertext, Tag}.

-spec decrypt_value(binary(), binary(), binary()) -> term().
decrypt_value(Nonce, Ciphertext, Tag) ->
    Key = derive_key(),
    case crypto:crypto_one_time_aead(
             aes_256_gcm, Key, Nonce, Ciphertext, <<>>, Tag, false) of
        error ->
            error(credential_decrypt_failed);
        Plaintext ->
            %% [safe] prevents atom-table exhaustion and lambda injection
            binary_to_term(Plaintext, [safe])
    end.
