-module(beam_agent_runtime_core).
-moduledoc """
Shared runtime defaults and provider/agent state for the canonical SDK.

The unified SDK needs some runtime state that is independent of any single
backend transport:

  - provider selection / provider config
  - default agent selection
  - query defaults that can be merged into future requests

This module keeps that state in ETS keyed by the live session pid (or a
session id binary for callers that only have persisted identity). Using ETS
keeps lookups cheap and avoids introducing a central process bottleneck.
""".

-export([
    ensure_tables/0,
    clear/0,
    register_session/2,
    clear_session/1,
    get_state/1,
    provider_catalog/0,
    provider_metadata/1,
    current_provider/1,
    set_provider/2,
    clear_provider/1,
    get_provider_config/1,
    set_provider_config/2,
    current_agent/1,
    set_agent/2,
    clear_agent/1,
    list_providers/1,
    provider_status/1,
    provider_status/2,
    validate_provider_config/2,
    merge_query_opts/2
]).

-export_type([runtime_state/0]).

-dialyzer({no_underspecs, [{provider_catalog, 0},
                           {fallback_provider_entry, 2}]}).

-type runtime_state() :: #{
    provider_id => binary(),
    provider => map(),
    model_id => binary(),
    agent => binary(),
    mode => binary(),
    system => binary() | map(),
    tools => map() | list()
}.

-type provider_entry() :: #{
    id := binary(),
    label => binary(),
    source := runtime | universal_registry,
    auth_methods => [binary()],
    capabilities => [binary()],
    config_keys => [binary()],
    configured => boolean(),
    current => boolean(),
    known_provider => boolean()
}.

-define(RUNTIME_TABLE, beam_agent_runtime_core).

-doc "Ensure the runtime ETS table exists.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    case ets:whereis(?RUNTIME_TABLE) of
        undefined ->
            try
                _ = ets:new(?RUNTIME_TABLE, [set, public, named_table,
                    {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.

-doc "Clear all runtime state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    ets:delete_all_objects(?RUNTIME_TABLE),
    ok.

-doc """
Prime runtime state from session opts.

Only canonical runtime defaults are persisted here; backend selection and
transport options remain outside this table.
""".
-spec register_session(pid() | binary(), map()) -> ok.
register_session(Session, Opts) when is_map(Opts) ->
    Defaults = maps:with([provider_id, provider, model_id, agent, mode, system, tools], Opts),
    case map_size(defaulted_state(Defaults)) of
        0 ->
            ok;
        _ ->
            put_state(Session, Defaults)
    end.

-doc "Delete runtime state for a session pid or session id.".
-spec clear_session(pid() | binary()) -> ok.
clear_session(Session) ->
    ensure_tables(),
    ets:delete(?RUNTIME_TABLE, session_key(Session)),
    ok.

-doc "Read the current runtime state map for a session.".
-spec get_state(pid() | binary()) -> {ok, runtime_state()}.
get_state(Session) ->
    ensure_tables(),
    case ets:lookup(?RUNTIME_TABLE, session_key(Session)) of
        [{_, State}] when is_map(State) ->
            {ok, State};
        [] ->
            {ok, #{}}
    end.

-doc "Return the currently selected provider, if any.".
-spec current_provider(pid() | binary()) -> {ok, binary()} | {error, not_set}.
current_provider(Session) ->
    case get_state(Session) of
        {ok, #{provider_id := ProviderId}} when is_binary(ProviderId),
                byte_size(ProviderId) > 0 ->
            {ok, ProviderId};
        _ ->
            infer_provider(Session)
    end.

-doc "Set the default provider for future queries on this session.".
-spec set_provider(pid() | binary(), binary()) -> ok.
set_provider(Session, ProviderId)
  when is_binary(ProviderId), byte_size(ProviderId) > 0 ->
    put_state(Session, #{provider_id => ProviderId}).

-doc "Return the canonical fallback provider catalog used by shared runtime/config layers.".
-spec provider_catalog() -> [provider_entry()].
provider_catalog() ->
    [
        #{
            id => <<"openai">>,
            label => <<"OpenAI">>,
            source => universal_registry,
            auth_methods => [<<"api_key">>, <<"oauth_callback">>],
            capabilities => [<<"chat">>, <<"attachments">>, <<"config">>],
            config_keys => [<<"api_key">>, <<"base_url">>, <<"organization">>]
        },
        #{
            id => <<"anthropic">>,
            label => <<"Anthropic">>,
            source => universal_registry,
            auth_methods => [<<"api_key">>],
            capabilities => [<<"chat">>, <<"attachments">>, <<"config">>],
            config_keys => [<<"api_key">>, <<"base_url">>]
        },
        #{
            id => <<"google">>,
            label => <<"Google Gemini">>,
            source => universal_registry,
            auth_methods => [<<"api_key">>, <<"oauth_callback">>],
            capabilities => [<<"chat">>, <<"attachments">>, <<"realtime">>],
            config_keys => [<<"api_key">>, <<"project">>, <<"location">>]
        },
        #{
            id => <<"github_copilot">>,
            label => <<"GitHub Copilot">>,
            source => universal_registry,
            auth_methods => [<<"oauth_callback">>, <<"device_code">>],
            capabilities => [<<"chat">>, <<"attachments">>, <<"session">>],
            config_keys => [<<"oauth_callback">>, <<"account">>]
        },
        #{
            id => <<"local">>,
            label => <<"Local / self-hosted">>,
            source => universal_registry,
            auth_methods => [<<"api_key">>],
            capabilities => [<<"chat">>, <<"config">>],
            config_keys => [<<"base_url">>, <<"api_key">>]
        }
    ].

-doc "Look up canonical fallback metadata for a provider id.".
-spec provider_metadata(binary()) -> {ok, provider_entry()} | error.
provider_metadata(ProviderId) when is_binary(ProviderId), byte_size(ProviderId) > 0 ->
    case lists:dropwhile(fun(Entry) -> maps:get(id, Entry) =/= ProviderId end,
                         provider_catalog()) of
        [Entry | _] ->
            {ok, Entry};
        [] ->
            error
    end.

-doc "Clear any default provider selection for this session.".
-spec clear_provider(pid() | binary()) -> ok.
clear_provider(Session) ->
    update_state(Session, fun(State) ->
        maps:without([provider_id, provider], State)
    end).

-doc "Read the provider config map associated with this session.".
-spec get_provider_config(pid() | binary()) -> {ok, map()}.
get_provider_config(Session) ->
    case get_state(Session) of
        {ok, #{provider := Config}} when is_map(Config) ->
            {ok, Config};
        _ ->
            {ok, #{}}
    end.

-doc """
Set provider configuration for future queries on this session.

This is most immediately useful for backends such as Copilot that accept a
structured provider config in the wire protocol. For other backends the config
is still tracked and exposed through the unified surface.
""".
-spec set_provider_config(pid() | binary(), map()) -> ok | {error, term()}.
set_provider_config(Session, Config) when is_map(Config) ->
    case infer_provider_id(Config) of
        {ok, ProviderId} ->
            put_state(Session, #{provider => Config, provider_id => ProviderId});
        error ->
            case validate_provider_config(undefined, Config) of
                ok -> put_state(Session, #{provider => Config});
                {error, _} = Error -> Error
            end
    end.

-doc "Return the currently selected default agent, if any.".
-spec current_agent(pid() | binary()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) ->
    case get_state(Session) of
        {ok, #{agent := Agent}} when is_binary(Agent), byte_size(Agent) > 0 ->
            {ok, Agent};
        _ ->
            infer_agent(Session)
    end.

-doc "Set the default agent to use for future queries on this session.".
-spec set_agent(pid() | binary(), binary()) -> ok.
set_agent(Session, Agent)
  when is_binary(Agent), byte_size(Agent) > 0 ->
    put_state(Session, #{agent => Agent}).

-doc "Clear any default agent selection for this session.".
-spec clear_agent(pid() | binary()) -> ok.
clear_agent(Session) ->
    update_state(Session, fun(State) ->
        maps:without([agent], State)
    end).

-doc """
List providers visible through the unified runtime layer.

Native provider listings are preferred when a backend exposes them. Otherwise
the runtime returns best-effort metadata derived from current runtime state
and session info.
""".
-spec list_providers(pid() | binary()) -> {ok, [map()]}.
list_providers(Session) ->
    case native_provider_list(Session) of
        {ok, Providers} ->
            {ok, Providers};
        {error, _} ->
            fallback_provider_list(Session)
    end.

-doc "Return high-level provider status for the session's current provider.".
-spec provider_status(pid() | binary()) ->
    {ok, #{provider_id := undefined | binary(), _ => _}}.
provider_status(Session) ->
    case current_provider(Session) of
        {ok, ProviderId} ->
            provider_status(Session, ProviderId);
        {error, not_set} ->
            {ok, Config} = get_provider_config(Session),
            {ok, #{provider_id => undefined, configured => (map_size(Config) > 0),
                   provider_config => Config}}
    end.

-doc """
Return status for a specific provider id.

When the backend exposes native provider/admin endpoints the result includes
their payload; otherwise the runtime returns a normalized best-effort summary.
""".
-spec provider_status(pid() | binary(), binary()) ->
    {ok, #{provider_id := binary(), _ => _}}.
provider_status(Session, ProviderId) when is_binary(ProviderId) ->
    case native_provider_status(Session, ProviderId) of
        {ok, Native} ->
            {ok, Native#{provider_id => ProviderId}};
        {error, _} ->
            {ok, State} = get_state(Session),
            Config = config_for_provider(ProviderId, State),
            CurrentProviderId = maps:get(provider_id, State, undefined),
            Metadata = fallback_provider_entry(ProviderId, State),
            {ok, #{
                provider_id => ProviderId,
                configured => (map_size(Config) > 0),
                provider_config => Config,
                source => maps:get(source, Metadata, runtime),
                auth_methods => maps:get(auth_methods, Metadata, []),
                capabilities => maps:get(capabilities, Metadata, []),
                config_keys => maps:get(config_keys, Metadata, []),
                known_provider => maps:get(known_provider, Metadata, false),
                current => (CurrentProviderId =:= ProviderId)
            }}
    end.

-doc """
Validate a provider configuration map.

The validation stays conservative: it checks shape and obvious type errors
without overfitting to a single backend's provider schema.
""".
-spec validate_provider_config(binary() | undefined, map()) -> ok | {error, term()}.
validate_provider_config(_ProviderId, Config) when not is_map(Config) ->
    {error, invalid_provider_config};
validate_provider_config(_ProviderId, Config) ->
    case maps:get(<<"apiKey">>, Config,
           maps:get(api_key, Config, undefined)) of
        undefined ->
            ok;
        ApiKey when is_binary(ApiKey), byte_size(ApiKey) > 0 ->
            ok;
        _ ->
            {error, invalid_api_key}
    end.

-doc """
Merge runtime defaults into query params.

Explicit query params always win over stored runtime defaults.
Nested provider config maps are merged shallowly.
""".
-spec merge_query_opts(pid() | binary(), map()) -> map().
merge_query_opts(Session, Params) when is_map(Params) ->
    {ok, State} = get_state(Session),
    Defaults = maps:with([provider_id, provider, model_id, agent, mode, system, tools], State),
    Merged0 = maps:merge(Defaults, Params),
    case {maps:get(provider, Defaults, undefined), maps:get(provider, Params, undefined)} of
        {ProviderDefault, ProviderParams}
          when is_map(ProviderDefault), is_map(ProviderParams) ->
            Merged0#{provider => maps:merge(ProviderDefault, ProviderParams)};
        _ ->
            Merged0
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec session_key(pid() | binary()) -> pid() | binary().
session_key(Session) when is_pid(Session) ->
    Session;
session_key(SessionId) when is_binary(SessionId) ->
    SessionId.

-spec put_state(pid() | binary(), map()) -> ok.
put_state(Session, Updates) when is_map(Updates) ->
    ensure_tables(),
    Key = session_key(Session),
    State = case ets:lookup(?RUNTIME_TABLE, Key) of
        [{_, Existing}] when is_map(Existing) ->
            maps:merge(Existing, defaulted_state(Updates));
        [] ->
            defaulted_state(Updates)
    end,
    ets:insert(?RUNTIME_TABLE, {Key, State}),
    ok.

-spec update_state(pid() | binary(), fun((map()) -> map())) -> ok.
update_state(Session, Fun) ->
    {ok, State} = get_state(Session),
    ensure_tables(),
    Key = session_key(Session),
    ets:insert(?RUNTIME_TABLE, {Key, defaulted_state(Fun(State))}),
    ok.

-spec infer_provider(pid() | binary()) -> {ok, binary()} | {error, not_set}.
infer_provider(Session) ->
    case maybe_session_info(Session) of
        {ok, Info} ->
            case infer_provider_from_info(Info) of
                {ok, ProviderId} -> {ok, ProviderId};
                error -> {error, not_set}
            end;
        _ ->
            {error, not_set}
    end.

-spec infer_agent(pid() | binary()) -> {ok, binary()} | {error, not_set}.
infer_agent(Session) ->
    case maybe_session_info(Session) of
        {ok, Info} ->
            case maps:get(agent, Info,
                   maps:get(current_agent, Info, undefined)) of
                Agent when is_binary(Agent), byte_size(Agent) > 0 ->
                    {ok, Agent};
                _ ->
                    {error, not_set}
            end;
        _ ->
            {error, not_set}
    end.

-spec maybe_session_info(pid() | binary()) -> {ok, map()} | {error, term()}.
maybe_session_info(Session) when is_pid(Session) ->
    try gen_statem:call(Session, session_info, 5000) of
        {ok, Info} when is_map(Info) -> {ok, Info};
        Other -> {error, {invalid_session_info, Other}}
    catch
        exit:Reason -> {error, Reason}
    end;
maybe_session_info(_SessionId) ->
    {error, unavailable}.

-spec infer_provider_from_info(map()) -> {ok, binary()} | error.
infer_provider_from_info(Info) ->
    case maps:get(provider_id, Info,
           maps:get(providerID, Info,
           maps:get(<<"provider_id">>, Info,
           maps:get(<<"providerID">>, Info, undefined)))) of
        ProviderId when is_binary(ProviderId), byte_size(ProviderId) > 0 ->
            {ok, ProviderId};
        _ ->
            case maps:get(model, Info, undefined) of
                #{provider_id := ProviderId} when is_binary(ProviderId),
                                                byte_size(ProviderId) > 0 ->
                    {ok, ProviderId};
                _ ->
                    error
            end
    end.

-spec infer_provider_id(map()) -> {ok, binary()} | error.
infer_provider_id(Config) ->
    case maps:get(id, Config,
           maps:get(provider_id, Config,
           maps:get(providerID, Config,
           maps:get(<<"id">>, Config,
           maps:get(<<"provider_id">>, Config,
           maps:get(<<"providerID">>, Config, undefined)))))) of
        ProviderId when is_binary(ProviderId), byte_size(ProviderId) > 0 ->
            {ok, ProviderId};
        _ ->
            error
    end.

-spec native_provider_list(pid() | binary()) -> {ok, [map()]} | {error, term()}.
native_provider_list(Session) when is_pid(Session) ->
    case beam_agent_backend:session_backend(Session) of
        {ok, opencode} ->
            normalize_provider_list(beam_agent_raw_core:call(Session, provider_list, []));
        _ ->
            {error, unsupported}
    end;
native_provider_list(_SessionId) ->
    {error, unsupported}.

-spec fallback_provider_list(pid() | binary()) -> {ok, [provider_entry()]}.
fallback_provider_list(Session) ->
    {ok, State} = get_state(Session),
    CurrentProviderId = maps:get(provider_id, State, undefined),
    Catalog = [decorate_provider_entry(Entry, State) || Entry <- provider_catalog()],
    Entries =
        case CurrentProviderId of
            ProviderId when is_binary(ProviderId), byte_size(ProviderId) > 0 ->
                merge_provider_entries([fallback_provider_entry(ProviderId, State) | Catalog]);
            _ ->
                merge_provider_entries(Catalog)
        end,
    {ok, Entries}.

-spec native_provider_status(pid() | binary(), binary()) ->
    {ok, map()} | {error, term()}.
native_provider_status(Session, _ProviderId) when is_pid(Session) ->
    case beam_agent_backend:session_backend(Session) of
        {ok, opencode} ->
            case beam_agent_raw_core:call(Session, config_providers, []) of
                {ok, Status} when is_map(Status) -> {ok, Status};
                {ok, Status} -> {ok, #{native => Status}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, unsupported}
    end;
native_provider_status(_SessionId, _ProviderId) ->
    {error, unsupported}.

-spec normalize_provider_list({ok, term()} | {error, term()}) ->
    {ok, [map()]} | {error, term()}.
normalize_provider_list({ok, Providers}) when is_list(Providers) ->
    {ok, [normalize_provider_entry(P) || P <- Providers]};
normalize_provider_list({ok, #{providers := Providers}}) when is_list(Providers) ->
    {ok, [normalize_provider_entry(P) || P <- Providers]};
normalize_provider_list({ok, #{<<"providers">> := Providers}}) when is_list(Providers) ->
    {ok, [normalize_provider_entry(P) || P <- Providers]};
normalize_provider_list({ok, #{data := Providers}}) when is_list(Providers) ->
    {ok, [normalize_provider_entry(P) || P <- Providers]};
normalize_provider_list({ok, #{<<"data">> := Providers}}) when is_list(Providers) ->
    {ok, [normalize_provider_entry(P) || P <- Providers]};
normalize_provider_list({ok, Provider}) when is_map(Provider) ->
    {ok, [normalize_provider_entry(Provider)]};
normalize_provider_list({error, _} = Error) ->
    Error;
normalize_provider_list({ok, _Other}) ->
    {ok, []}.

-spec normalize_provider_entry(term()) -> map().
normalize_provider_entry(Provider) when is_map(Provider) ->
    Provider;
normalize_provider_entry(ProviderId) when is_binary(ProviderId) ->
    #{id => ProviderId};
normalize_provider_entry(Other) ->
    #{value => Other}.

-spec fallback_provider_entry(binary(), runtime_state()) -> provider_entry().
fallback_provider_entry(ProviderId, State) ->
    Config = config_for_provider(ProviderId, State),
    case provider_metadata(ProviderId) of
        {ok, Entry} ->
            (decorate_provider_entry(Entry, State))#{
                configured => (map_size(Config) > 0)
            };
        error ->
            #{
                id => ProviderId,
                label => ProviderId,
                source => runtime,
                auth_methods => infer_auth_methods(Config),
                capabilities => [<<"chat">>, <<"config">>],
                config_keys => infer_config_keys(Config),
                configured => (map_size(Config) > 0),
                current => (maps:get(provider_id, State, undefined) =:= ProviderId),
                known_provider => false
            }
    end.

-spec decorate_provider_entry(provider_entry(), runtime_state()) -> provider_entry().
decorate_provider_entry(Entry, State) ->
    ProviderId = maps:get(id, Entry),
    Config = config_for_provider(ProviderId, State),
    Entry#{
        configured => (map_size(Config) > 0),
        current => (maps:get(provider_id, State, undefined) =:= ProviderId),
        known_provider => true
    }.

-spec config_for_provider(binary(), runtime_state()) -> map().
config_for_provider(ProviderId, State) ->
    Config = maps:get(provider, State, #{}),
    case infer_provider_id(Config) of
        {ok, ProviderId} ->
            Config;
        _ ->
            case maps:get(provider_id, State, undefined) of
                ProviderId when is_binary(ProviderId) ->
                    Config;
                _ ->
                    #{}
            end
    end.

-spec merge_provider_entries([provider_entry()]) -> [provider_entry()].
merge_provider_entries(Entries) ->
    lists:reverse(
        lists:foldl(fun(Entry, Acc) ->
            ProviderId = maps:get(id, Entry),
            case lists:any(fun(Existing) ->
                     maps:get(id, Existing, undefined) =:= ProviderId
                 end, Acc) of
                true ->
                    [merge_provider_entry(Entry, Acc) | lists:filter(fun(Existing) ->
                         maps:get(id, Existing, undefined) =/= ProviderId
                     end, Acc)];
                false ->
                    [Entry | Acc]
            end
        end, [], Entries)).

-spec merge_provider_entry(provider_entry(), [provider_entry()]) -> provider_entry().
merge_provider_entry(Entry, Entries) ->
    Existing = hd([Item || Item <- Entries, maps:get(id, Item, undefined) =:= maps:get(id, Entry)]),
    Existing#{
        source => case maps:get(source, Existing, runtime) of
            runtime -> maps:get(source, Entry, runtime);
            Source -> Source
        end,
        auth_methods => ordsets:from_list(
            maps:get(auth_methods, Existing, []) ++ maps:get(auth_methods, Entry, [])),
        capabilities => ordsets:from_list(
            maps:get(capabilities, Existing, []) ++ maps:get(capabilities, Entry, [])),
        config_keys => ordsets:from_list(
            maps:get(config_keys, Existing, []) ++ maps:get(config_keys, Entry, [])),
        configured => maps:get(configured, Existing, false) orelse
            maps:get(configured, Entry, false),
        current => maps:get(current, Existing, false) orelse
            maps:get(current, Entry, false),
        known_provider => maps:get(known_provider, Existing, false) orelse
            maps:get(known_provider, Entry, false)
    }.

-spec infer_auth_methods(map()) -> [binary()].
infer_auth_methods(Config) when map_size(Config) =:= 0 ->
    [<<"api_key">>];
infer_auth_methods(Config) ->
    ordsets:from_list(
        lists:flatten([
            case maps:get(oauth_callback, Config, undefined) of
                Callback when is_map(Callback) -> [<<"oauth_callback">>];
                _ -> []
            end,
            case maps:get(api_key, Config,
                   maps:get(<<"apiKey">>, Config, undefined)) of
                ApiKey when is_binary(ApiKey), byte_size(ApiKey) > 0 ->
                    [<<"api_key">>];
                _ ->
                    []
            end
        ])).

-spec infer_config_keys(map()) -> [binary()].
infer_config_keys(Config) ->
    ordsets:from_list([
        normalize_config_key(Key) || Key <- maps:keys(Config)
    ]).

-spec normalize_config_key(term()) -> binary().
normalize_config_key(Key) when is_atom(Key) ->
    atom_to_binary(Key, utf8);
normalize_config_key(Key) when is_binary(Key) ->
    Key;
normalize_config_key(Key) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Key])).

-spec defaulted_state(map()) -> map().
defaulted_state(State) ->
    maps:filter(fun(_Key, Value) ->
        Value =/= undefined andalso Value =/= null
    end, State).
