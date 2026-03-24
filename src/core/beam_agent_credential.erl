-module(beam_agent_credential).
-moduledoc """
Symmetric encryption for sensitive credential fields.

Uses AES-256-GCM with a per-node key derived from the BEAM node cookie
via HKDF-SHA256 (RFC 5869). HKDF-Extract produces a pseudorandom key
from the cookie and a fixed salt, then HKDF-Expand stretches it to the
required 32 bytes with a purpose-specific info label.

Note: This is defense-in-depth, not a security boundary. Any process
with access to the node cookie can derive the key. The goal is to
prevent accidental exposure in logs, crash dumps, and admin UIs.
""".

-export([
    protect/1,
    unprotect/1,
    is_protected/1,
    protect_value/1,
    unprotect_value/1
]).

-export_type([protected/0]).

%% Opaque encrypted-value wrapper returned by protect/1 and protect_value/1.
-type protected() :: {beam_agent_protected, binary(), binary(), binary()}.

-define(KDF_SALT, <<"beam_agent_credential_v1">>).
-define(KDF_INFO, <<"aes-256-gcm-key">>).

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

-doc """
Encrypt a single value directly.

Unlike `protect/1`, which walks a map's keys, this encrypts any term and
returns a `{beam_agent_protected, Nonce, Ciphertext, Tag}` tuple.  Use this
for individual credential values stored outside of maps (e.g., record fields).
""".
-spec protect_value(term()) -> protected().
protect_value(Value) ->
    encrypt_value(Value).

-doc """
Decrypt a single protected value.  Non-protected values pass through unchanged.

Inverse of `protect_value/1`.
""".
-spec unprotect_value(protected()) -> term();
                     (term()) -> term().
unprotect_value({beam_agent_protected, Nonce, Ciphertext, Tag}) ->
    decrypt_value(Nonce, Ciphertext, Tag);
unprotect_value(Value) ->
    Value.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec is_sensitive(term()) -> boolean().
is_sensitive(Key) ->
    lists:member(Key, ?SENSITIVE_KEYS).

-spec derive_key() -> binary().
derive_key() ->
    case erlang:get_cookie() of
        nocookie ->
            logger:warning("beam_agent_credential: deriving key from 'nocookie' — "
                           "credential encryption provides no protection without "
                           "a real distribution cookie"),
            do_derive(nocookie);
        Cookie ->
            do_derive(Cookie)
    end.

-spec do_derive(atom()) -> binary().
do_derive(Cookie) ->
    IKM = atom_to_binary(Cookie, utf8),
    %% HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    PRK = crypto:mac(hmac, sha256, ?KDF_SALT, IKM),
    %% HKDF-Expand: OKM = HMAC-SHA256(PRK, info || 0x01) truncated to 32 bytes
    crypto:mac(hmac, sha256, PRK, <<?KDF_INFO/binary, 1>>).

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
