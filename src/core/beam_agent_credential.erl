-module(beam_agent_credential).
-moduledoc """
Symmetric encryption for sensitive credential fields.

The set of keys requiring encryption is defined centrally in
`beam_agent_redaction' — this module encrypts all keys with
`encrypt_and_redact' handling via `credential_match_keys/0'.

Uses AES-256-GCM with a per-node key derived from the BEAM node cookie
via HKDF-SHA256 (RFC 5869). HKDF-Extract produces a pseudorandom key
from the cookie and a fixed salt, then HKDF-Expand stretches it to the
required 32 bytes with a purpose-specific info label.

If no cookie is set (`erlang:get_cookie/0' returns `nocookie'),
the module automatically generates a cryptographically secure cookie,
applies it to the running node via `erlang:set_cookie/2', and logs a
warning with instructions for persisting it across restarts.

## Cookie Setup

For production, pre-configure a cookie so the auto-generated ephemeral
cookie is not used. You do not need full distributed Erlang — just a
cookie set on the local node.

Generate a secure cookie:

```erlang
Cookie = beam_agent_credential:generate_cookie().
```

Then configure it via one of:

  - **vm.args** (releases): `-setcookie <generated_value>'
  - **runtime.exs** (Elixir): `Node.set_cookie(:"<generated_value>")'
  - **CLI flag**: `--cookie <generated_value>'
  - **Programmatic**: `erlang:set_cookie(node(), '<generated_value>')'

Note: This is defense-in-depth, not a security boundary. Any process
with access to the node cookie can derive the key. The goal is to
prevent accidental exposure in logs, crash dumps, and admin UIs.
""".

-export([
    protect/1,
    unprotect/1,
    is_protected/1,
    protect_value/1,
    unprotect_value/1,
    generate_cookie/0
]).

-ifdef(TEST).
-export([
    cookie_to_key/1,
    encrypt_map/2,
    decrypt_map/2,
    encrypt_term/2,
    decrypt_term/4
]).
-endif.

-export_type([protected/0]).

%% Opaque encrypted-value wrapper returned by protect/1 and protect_value/1.
-type protected() :: {beam_agent_protected, binary(), binary(), binary()}.

-define(KDF_SALT, <<"beam_agent_credential_v1">>).
-define(KDF_INFO, <<"aes-256-gcm-key">>).


%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-doc """
Encrypt sensitive fields in a map before ETS storage.

Walks top-level keys and replaces values whose keys match the sensitive
key list with `{beam_agent_protected, Nonce, Ciphertext, Tag}` tuples.
Nested maps under sensitive keys are serialized to binary before encryption.
Non-sensitive keys are left untouched.

If no node cookie is set, one is auto-generated and applied to the
running node. See the module doc for persistent cookie setup.
""".
-spec protect(map()) -> map().
protect(Map) when is_map(Map) ->
    encrypt_map(Map, require_key()).

-doc """
Decrypt previously protected fields in a map after ETS read.

Reverses `protect/1` by decrypting any values stored as
`{beam_agent_protected, Nonce, Ciphertext, Tag}` tuples.
Non-protected values pass through unchanged.

If no node cookie is set, one is auto-generated and applied to the
running node. See the module doc for persistent cookie setup.
""".
-spec unprotect(map()) -> map().
unprotect(Map) when is_map(Map) ->
    decrypt_map(Map, require_key()).

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

If no node cookie is set, one is auto-generated and applied to the
running node. See the module doc for persistent cookie setup.
""".
-spec protect_value(term()) -> protected().
protect_value(Value) ->
    encrypt_term(Value, require_key()).

-doc """
Decrypt a single protected value.  Non-protected values pass through unchanged.

Inverse of `protect_value/1`.

If no node cookie is set, one is auto-generated and applied to the
running node. See the module doc for persistent cookie setup.
""".
-spec unprotect_value(protected()) -> term();
                     (term()) -> term().
unprotect_value({beam_agent_protected, Nonce, Ciphertext, Tag}) ->
    decrypt_term(Nonce, Ciphertext, Tag, require_key());
unprotect_value(Value) ->
    Value.

%%--------------------------------------------------------------------
%% Cookie generation
%%--------------------------------------------------------------------

-doc """
Generate a cryptographically secure node cookie.

Returns an atom suitable for `erlang:set_cookie/1'. The cookie is 32
bytes of randomness encoded as URL-safe base64 (no padding), producing
a 43-character atom with 256 bits of entropy.

## Example

```erlang
Cookie = beam_agent_credential:generate_cookie(),
erlang:set_cookie(node(), Cookie).
```
""".
-spec generate_cookie() -> atom().
generate_cookie() ->
    Bytes = crypto:strong_rand_bytes(32),
    binary_to_atom(urlsafe_base64(Bytes), utf8).

%%--------------------------------------------------------------------
%% Side-effect boundary
%%--------------------------------------------------------------------

%% @private Retrieve the cached encryption key, or derive it from the
%% node cookie on first use. The derived key is stored in persistent_term
%% for O(1) lookups — derive_key/0 (the sole erlang:get_cookie/0 caller)
%% runs at most once per node lifetime.
-spec require_key() -> binary().
require_key() ->
    case persistent_term:get(?MODULE, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        _ -> derive_and_cache_key()
    end.

-spec derive_and_cache_key() -> binary().
derive_and_cache_key() ->
    case derive_key() of
        {ok, Key} ->
            persistent_term:put(?MODULE, Key),
            Key;
        {error, nocookie} ->
            auto_generate_and_cache()
    end.

%% @private No cookie was set — generate one, apply it to the running
%% node, derive the encryption key, and tell the user how to persist it.
%%
%% Serialized via ETS named-table mutex: `ets:new/2` with `named_table`
%% throws `badarg` if the table already exists, so the first process to
%% arrive wins and all others spin on `persistent_term:get/2` until the
%% winner caches the key.
-spec auto_generate_and_cache() -> binary().
auto_generate_and_cache() ->
    try ets:new(beam_agent_credential_init, [named_table]) of
        beam_agent_credential_init ->
            try
                Cookie = generate_cookie(),
                erlang:set_cookie(node(), Cookie),
                {ok, Key} = cookie_to_key(Cookie),
                persistent_term:put(?MODULE, Key),
                logger:warning(
                    "beam_agent: No node cookie was set. A secure ephemeral "
                    "cookie has been generated and applied to this node.~n"
                    "~n"
                    "  This cookie will NOT survive a restart.~n"
                    "  To retrieve it for persistence:~n"
                    "    Erlang:  erlang:get_cookie()~n"
                    "    Elixir:  Node.get_cookie()~n"
                    "~n"
                    "  Then persist via one of:~n"
                    "    vm.args:      -setcookie <value>~n"
                    "    runtime.exs:  Node.set_cookie(:\"<value>\")~n"
                    "    CLI flag:     --cookie <value>~n"),
                Key
            after
                ets:delete(beam_agent_credential_init)
            end
    catch
        error:badarg ->
            %% Another process is generating — wait for the cached key.
            await_cached_key()
    end.

%% @private Spin until the winner caches the key in persistent_term.
%% The critical section completes in microseconds (one
%% `crypto:strong_rand_bytes` + `persistent_term:put`), so this
%% spin is trivially short.  A bounded retry (1000 yields ≈ a few
%% milliseconds) guards against infinite loops if the winner crashes.
-spec await_cached_key() -> binary().
await_cached_key() ->
    await_cached_key(1000).

-spec await_cached_key(pos_integer()) -> binary().
await_cached_key(0) ->
    error(credential_key_init_timeout);
await_cached_key(Remaining) ->
    case persistent_term:get(?MODULE, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        _ ->
            erlang:yield(),
            await_cached_key(Remaining - 1)
    end.

%%--------------------------------------------------------------------
%% Key derivation (pure functions)
%%--------------------------------------------------------------------

-spec cookie_to_key(atom()) -> {ok, binary()} | {error, nocookie}.
cookie_to_key(nocookie) -> {error, nocookie};
cookie_to_key(Cookie) when is_atom(Cookie) -> {ok, do_derive(Cookie)}.

-spec derive_key() -> {ok, binary()} | {error, nocookie}.
derive_key() ->
    cookie_to_key(erlang:get_cookie()).

-spec do_derive(atom()) -> binary().
do_derive(Cookie) ->
    IKM = atom_to_binary(Cookie, utf8),
    %% HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    PRK = crypto:mac(hmac, sha256, ?KDF_SALT, IKM),
    %% HKDF-Expand: OKM = HMAC-SHA256(PRK, info || 0x01) truncated to 32 bytes
    crypto:mac(hmac, sha256, PRK, <<?KDF_INFO/binary, 1>>).

%%--------------------------------------------------------------------
%% Pure crypto functions (no side effects)
%%--------------------------------------------------------------------

-spec is_sensitive(term()) -> boolean().
is_sensitive(Key) ->
    lists:member(Key, beam_agent_redaction:credential_match_keys()).

-spec encrypt_map(map(), binary()) -> map().
encrypt_map(Map, Key) when is_map(Map), is_binary(Key) ->
    maps:map(fun(K, V) ->
        case is_sensitive(K) of
            true -> encrypt_term(V, Key);
            false -> V
        end
    end, Map).

-spec decrypt_map(map(), binary()) -> map().
decrypt_map(Map, Key) when is_map(Map), is_binary(Key) ->
    maps:map(fun(_K, V) ->
        case V of
            {beam_agent_protected, Nonce, Ciphertext, Tag} ->
                decrypt_term(Nonce, Ciphertext, Tag, Key);
            _ ->
                V
        end
    end, Map).

-spec encrypt_term(term(), binary()) -> protected().
encrypt_term(Value, Key) when is_binary(Key) ->
    Nonce = crypto:strong_rand_bytes(12),
    Plaintext = term_to_binary(Value),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, Plaintext, <<>>, true),
    {beam_agent_protected, Nonce, Ciphertext, Tag}.

-spec decrypt_term(binary(), binary(), binary(), binary()) -> term().
decrypt_term(Nonce, Ciphertext, Tag, Key)
  when is_binary(Nonce), is_binary(Ciphertext), is_binary(Tag), is_binary(Key) ->
    case crypto:crypto_one_time_aead(
             aes_256_gcm, Key, Nonce, Ciphertext, <<>>, Tag, false) of
        error ->
            error(credential_decrypt_failed);
        Plaintext ->
            %% [safe] prevents atom-table exhaustion and lambda injection
            binary_to_term(Plaintext, [safe])
    end.

%%--------------------------------------------------------------------
%% Encoding helpers (pure)
%%--------------------------------------------------------------------

%% @private URL-safe base64 encoding without padding (RFC 4648 Section 5).
-spec urlsafe_base64(binary()) -> binary().
urlsafe_base64(Bytes) ->
    << <<(urlsafe_char(C))>> || <<C>> <= base64:encode(Bytes), C =/= $= >>.

-spec urlsafe_char(byte()) -> byte().
urlsafe_char($+) -> $-;
urlsafe_char($/) -> $_;
urlsafe_char(C)  -> C.
