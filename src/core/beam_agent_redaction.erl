-module(beam_agent_redaction).
-moduledoc false.

-export([
    map/1,
    pending_entry/1,
    provider_config/1,
    reason/1,
    runtime_state/1,
    stacktrace/1
]).

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
    lists:member(Current, beam_agent_sensitive_keys:redaction_match_keys()) orelse
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
