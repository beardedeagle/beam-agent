-module(beam_agent_sensitive_keys).
-moduledoc """
Single source of truth for sensitive key definitions.

Every key that must be encrypted in credential storage, redacted from
logs, or both is defined here as a triple:

    {CanonicalName :: atom(), Category :: category(), Handling :: handling()}

The credential and redaction modules derive their match lists from
this module rather than maintaining separate, driftable lists.

## Triple Fields

- `CanonicalName` — Erlang atom in snake_case (e.g., `api_key`).
- `Category` — Classification for documentation and filtering:
  `credential`, `auth`, `session`, or `oauth`.
- `Handling` — What protection the key requires:
  - `encrypt_and_redact` — Encrypt at rest in credential storage
    AND redact from logs/crash diagnostics.
  - `redact_only` — Redact from logs/crash diagnostics but not
    stored in credential maps (e.g., HTTP headers, ephemeral tokens).

## Consumer Integration

`beam_agent_credential` calls `credential_match_keys/0` to get the
flat list of all format variants (atom, camelCase binary, snake_case
binary) for keys that need encryption.

`beam_agent_redaction` calls `redaction_match_keys/0` to get canonical
lowercase binary keys for all sensitive keys after normalisation.
""".

-export([
    all/0,
    credential_match_keys/0,
    redaction_match_keys/0,
    is_sensitive/1
]).

-ifdef(TEST).
-export([
    key_variants/1,
    canonical_form/1,
    normalize_key/1,
    snake_to_camel/1
]).
-endif.

-export_type([key_entry/0, category/0, handling/0]).

-type category() :: credential | auth | session | oauth.
-type handling() :: encrypt_and_redact | redact_only.
-type key_entry() :: {atom(), category(), handling()}.

%%--------------------------------------------------------------------
%% The canonical registry
%%--------------------------------------------------------------------

-doc """
Return the canonical list of sensitive key triples.

Each triple is `{CanonicalName, Category, Handling}`.
""".
-spec all() -> [key_entry(), ...].
all() ->
    %% encrypt_and_redact: encrypted in credential storage + redacted from logs
    [{api_key,            credential, encrypt_and_redact},
     {token,              credential, encrypt_and_redact},
     {access_token,       credential, encrypt_and_redact},
     {refresh_token,      credential, encrypt_and_redact},
     {client_secret,      credential, encrypt_and_redact},
     {secret,             credential, encrypt_and_redact},
     {password,           credential, encrypt_and_redact},
     {private_key,        credential, encrypt_and_redact},
     {github_token,       credential, encrypt_and_redact},
     %% redact_only: stripped from logs/crash diagnostics, not stored in credentials
     {authorization,      auth,       redact_only},
     {authorization_code, oauth,      redact_only},
     {bearer_token,       auth,       redact_only},
     {code_verifier,      oauth,      redact_only},
     {credential_key,     credential, redact_only},
     {id_token,           oauth,      redact_only},
     {oauth_token,        oauth,      redact_only},
     {personal_token,     credential, redact_only},
     {session_token,      session,    redact_only}].

%%--------------------------------------------------------------------
%% Derived match lists
%%--------------------------------------------------------------------

-doc """
Flat list of all format variants for keys that require encryption.

Each multi-word key produces three variants: the atom, a camelCase
binary, and a snake_case binary. Single-word keys produce two: the
atom and a binary.

Used by `beam_agent_credential` to match incoming map keys.
""".
-spec credential_match_keys() -> [atom() | binary()].
credential_match_keys() ->
    lists:flatmap(
        fun({Name, _Cat, encrypt_and_redact}) -> key_variants(Name);
           ({_Name, _Cat, _Other}) -> []
        end,
        all()
    ).

-doc """
Canonical lowercase binary keys (no separators) for all sensitive keys.

Used by `beam_agent_redaction` after it normalises the incoming key
with its `canonical_key/1` function.
""".
-spec redaction_match_keys() -> [binary()].
redaction_match_keys() ->
    [canonical_form(Name) || {Name, _Cat, _Handling} <- all()].

-doc """
Check whether a key (atom or binary, any format) is sensitive.

Normalises the key to canonical lowercase form and checks against
the full redaction match list (superset of credential keys).
""".
-spec is_sensitive(atom() | binary()) -> boolean().
is_sensitive(Key) when is_atom(Key) ->
    is_sensitive(atom_to_binary(Key));
is_sensitive(Key) when is_binary(Key) ->
    lists:member(normalize_key(Key), redaction_match_keys()).

%%--------------------------------------------------------------------
%% Internal: variant generation
%%--------------------------------------------------------------------

%% Generate all format variants for a canonical key name.
%%   api_key     → [api_key, <<"apiKey">>, <<"api_key">>]
%%   token       → [token, <<"token">>]
-spec key_variants(atom()) -> [atom() | binary(), ...].
key_variants(Name) when is_atom(Name) ->
    SnakeBin = atom_to_binary(Name),
    case binary:match(SnakeBin, <<"_">>) of
        nomatch ->
            [Name, SnakeBin];
        _ ->
            CamelBin = snake_to_camel(SnakeBin),
            [Name, CamelBin, SnakeBin]
    end.

%% Canonical form for redaction matching: lowercase, no underscores.
%%   api_key → <<"apikey">>
-spec canonical_form(atom()) -> binary().
canonical_form(Name) when is_atom(Name) ->
    binary:replace(atom_to_binary(Name), <<"_">>, <<>>, [global]).

%% Normalise arbitrary binary key input to canonical form.
%% Lowercases and strips everything except a-z and 0-9.
%% Matches beam_agent_redaction:canonical_key/1 semantics.
-spec normalize_key(binary()) -> binary().
normalize_key(Bin) when is_binary(Bin) ->
    Lower = string:lowercase(Bin),
    << <<C>> || <<C>> <= Lower,
                ((C >= $a andalso C =< $z) orelse
                 (C >= $0 andalso C =< $9)) >>.

%% Convert snake_case binary to camelCase binary.
%%   <<"api_key">> → <<"apiKey">>
-spec snake_to_camel(binary()) -> binary().
snake_to_camel(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<"_">>, [global]) of
        [First | Rest] ->
            iolist_to_binary([First | [capitalize(P) || P <- Rest]]);
        [] ->
            Bin
    end.

-spec capitalize(binary()) -> binary().
capitalize(<<>>) -> <<>>;
capitalize(<<C, Rest/binary>>) when C >= $a, C =< $z ->
    <<(C - 32), Rest/binary>>;
capitalize(Bin) -> Bin.
