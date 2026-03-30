-module(beam_agent_redaction).
-moduledoc """
Redaction utilities for maps, crash reasons, and stacktrace frames.

Also serves as the single source of truth for sensitive key definitions.
Every key that must be encrypted in credential storage, redacted from
logs, or both is defined here as a triple:

    {CanonicalName :: atom(), Category :: category(), Handling :: handling()}

The credential module derives its match list from `credential_match_keys/0`
rather than maintaining a separate, driftable list.

## Triple Fields

- `CanonicalName` — Erlang atom in snake_case (e.g., `api_key`).
- `Category` — Classification for documentation and filtering:
  `credential`, `auth`, `session`, or `oauth`.
- `Handling` — What protection the key requires:
  - `encrypt_and_redact` — Encrypt at rest in credential storage
    AND redact from logs/crash diagnostics.
  - `redact_only` — Redact from logs/crash diagnostics but not
    stored in credential maps (e.g., HTTP headers, ephemeral tokens).
""".

-export([
    map/1,
    pending_entry/1,
    provider_config/1,
    reason/1,
    runtime_state/1,
    stacktrace/1
]).

-export([
    all/0,
    credential_match_keys/0,
    redaction_match_keys/0,
    is_sensitive/1
]).

-ifdef(TEST).
-export([
    canonical_form/1,
    normalize_key/1,
    snake_to_camel/1
]).
-endif.

-export_type([key_entry/0, category/0, handling/0]).

-type category() :: credential | auth | session | oauth.
-type handling() :: encrypt_and_redact | redact_only.
-type key_entry() :: {atom(), category(), handling()}.

%%====================================================================
%% Redaction: maps, crash reasons, stacktrace frames
%%====================================================================

-spec runtime_state(map()) -> map().
runtime_state(State) when is_map(State) ->
    case maps:find(provider, State) of
        {ok, ProviderConfig} when is_map(ProviderConfig) ->
            State#{provider => provider_config(ProviderConfig)};
        _ ->
            State
    end.

-spec provider_config(map()) -> map().
provider_config(Config) when is_map(Config) ->
    map(Config).

-spec pending_entry(map()) -> map().
pending_entry(Entry) when is_map(Entry) ->
    redact_optional_map(response,
        redact_optional_map(request, Entry)).

-spec redact_optional_map(request | response, map()) -> map().
redact_optional_map(Key, Entry) ->
    case maps:find(Key, Entry) of
        {ok, Value} when is_map(Value) ->
            Entry#{Key => map(Value)};
        _ ->
            Entry
    end.

-spec map(map()) -> map().
map(Map) when is_map(Map) ->
    redact_map(Map, []).

-spec redact_map(map(), [binary()]) -> map().
redact_map(Map, Path) ->
    maps:from_list([{Key, redact_key_value(Key, Value, Path)} ||
        {Key, Value} <- maps:to_list(Map)]).

-spec redact_key_value(term(), term(), [binary()]) -> term().
redact_key_value(Key, Value, Path) ->
    KeyPath = [canonical_key(Key) | Path],
    case is_sensitive_key_path(KeyPath) of
        true ->
            redacted;
        false ->
            redact_term(Value, KeyPath)
    end.

-spec redact_term(term(), [binary(), ...]) -> term().
redact_term(Value, Path) when is_map(Value) ->
    redact_map(Value, Path);
redact_term(Value, Path) when is_list(Value) ->
    [redact_term(Item, Path) || Item <- Value];
redact_term(Value, _Path) ->
    Value.

-spec is_sensitive_key_path([binary(), ...]) -> boolean().
is_sensitive_key_path([Current | Ancestors]) ->
    lists:member(Current, redaction_match_keys()) orelse
        %% Context-dependent: "code" is sensitive only under oauthcallback.
        (Current =:= <<"code">> andalso lists:member(<<"oauthcallback">>, Ancestors)).

-spec canonical_key(term()) -> binary().
canonical_key(Key) when is_atom(Key) ->
    canonical_key(atom_to_binary(Key, utf8));
canonical_key(Key) when is_list(Key) ->
    canonical_key(unicode:characters_to_binary(Key));
canonical_key(Key) when is_binary(Key) ->
    Lower = unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Key))),
    << <<Char>> || <<Char>> <= Lower,
                  ((Char >= $a andalso Char =< $z) orelse
                   (Char >= $0 andalso Char =< $9)) >>;
canonical_key(Key) ->
    canonical_key(unicode:characters_to_binary(io_lib:format("~tp", [Key]))).

%% @doc Redact a crash reason before logging.
%%
%% Map-shaped reasons are walked through `map/1' to strip sensitive
%% keys.  Non-map reasons (atoms, binaries, tuples) are left as-is
%% since they carry no keyed secrets.
-spec reason(term()) -> term().
reason(Reason) when is_map(Reason) ->
    map(Reason);
reason(Reason) ->
    Reason.

%% @doc Strip function arguments from stacktrace frames.
%%
%% Replaces argument lists with the arity integer, preserving the
%% diagnostic value of the trace (module, function, arity, location)
%% while preventing callback arguments from leaking into log output.
-spec stacktrace([{module(), atom(), non_neg_integer() | [term()], [tuple()]}]) ->
    [{module(), atom(), non_neg_integer(), [tuple()]}].
stacktrace(Frames) ->
    [redact_frame(Frame) || Frame <- Frames].

-spec redact_frame({module(), atom(), non_neg_integer() | [term()], [tuple()]}) ->
    {module(), atom(), non_neg_integer(), [tuple()]}.
redact_frame({M, F, Args, Loc}) when is_list(Args) ->
    {M, F, length(Args), Loc};
redact_frame({M, F, Arity, Loc}) ->
    {M, F, Arity, Loc}.

%%====================================================================
%%==== Sensitive Keys ====
%%====================================================================

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

-doc """
Flat list of all format variants for keys that require encryption.

Each multi-word key produces three variants: the atom, a camelCase
binary, and a snake_case binary. Single-word keys produce two: the
atom and a binary.

Used by `beam_agent_credential` to match incoming map keys.
""".
-spec credential_match_keys() -> [atom() | binary()].
credential_match_keys() ->
    case persistent_term:get({?MODULE, credential}, undefined) of
        undefined ->
            Value = derive_credential_match_keys(),
            persistent_term:put({?MODULE, credential}, Value),
            Value;
        Value ->
            Value
    end.

-doc """
Canonical lowercase binary keys (no separators) for all sensitive keys.

Used internally after normalising the incoming key with `canonical_key/1`.
""".
-spec redaction_match_keys() -> [binary()].
redaction_match_keys() ->
    case persistent_term:get({?MODULE, redaction}, undefined) of
        undefined ->
            Value = derive_redaction_match_keys(),
            persistent_term:put({?MODULE, redaction}, Value),
            Value;
        Value ->
            Value
    end.

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
%% Matches canonical_key/1 semantics.
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

%%--------------------------------------------------------------------
%% Internal: derivation (cached by public callers above)
%%--------------------------------------------------------------------

-spec derive_credential_match_keys() -> [atom() | binary()].
derive_credential_match_keys() ->
    lists:flatmap(
        fun({Name, _Cat, encrypt_and_redact}) -> key_variants(Name);
           ({_Name, _Cat, _Other}) -> []
        end,
        all()
    ).

-spec derive_redaction_match_keys() -> [binary()].
derive_redaction_match_keys() ->
    [canonical_form(Name) || {Name, _Cat, _Handling} <- all()].
