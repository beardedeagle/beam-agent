-module(beam_agent_config).
-moduledoc """
Unified configuration module for the BeamAgent SDK.

Consolidates session-scoped configuration management, global SDK-wide
configuration, and provider auth flows into a single module. Replaces
the former `beam_agent_config_core`, `beam_agent_global_config`, and
`beam_agent_sdk_config` modules.

### Session Configuration

Per-session backend configuration (model, provider, OAuth, permissions).
Public API functions use `native_or` routing: backends with native config
APIs get those calls first, others fall through to universal fallbacks.

### Global Configuration

SDK-wide settings that apply across all sessions. ETS-backed key-value
store with reload-bus notifications on mutation. Access via the `global_*`
family of functions.

### Provider Auth

Universal fallback implementations for provider authentication and OAuth
flows when backends lack native auth APIs.

## Fallback Chain

Session config reads check: session-scoped state first, then global
defaults, then hardcoded defaults. This ensures sensible behavior even
when a session has incomplete configuration.

## See Also

  - `beam_agent_provider`: public provider API with native_or routing
  - `beam_agent_runtime`: runtime state management
  - `beam_agent`: lifecycle entry point
""".

%%--------------------------------------------------------------------
%% Session config: public API (native_or routed)
%%--------------------------------------------------------------------
-export([
    read/1,
    read/2,
    update/2,
    providers/1,
    value_write/3,
    value_write/4,
    batch_write/2,
    batch_write/3,
    requirements_read/1,
    external_agent_detect/1,
    external_agent_detect/2,
    external_agent_import/2
]).

%%--------------------------------------------------------------------
%% Global config API
%%--------------------------------------------------------------------
-export([
    ensure_table/0,
    global_set/2,
    global_get/1,
    global_get/2,
    global_delete/1,
    global_list/0,
    global_clear/0
]).

%%--------------------------------------------------------------------
%% Universal fallback implementations (exported for backend delegates)
%%--------------------------------------------------------------------
-export([
    config_read/1,
    config_update/2,
    config_value_write/4,
    config_batch_write/3,
    config_requirements_read/1,
    external_agent_config_detect/2,
    external_agent_config_import/2,
    provider_auth_methods/1,
    provider_oauth_authorize/3,
    provider_oauth_callback/3
]).

%%--------------------------------------------------------------------
%% Type exports
%%--------------------------------------------------------------------
-export_type([
    config_key/0,
    config_value/0,
    config_entry/0,
    config_view/0,
    config_scope/0,
    runtime_config/0
]).

%%--------------------------------------------------------------------
%% Types — global config
%%--------------------------------------------------------------------

-doc "A global configuration key — always a binary.".
-type config_key() :: binary().

-doc "A global configuration value — any Erlang term.".
-type config_value() :: term().

-doc "A key-value pair as returned by `global_list/0`.".
-type config_entry() :: #{key := config_key(), value := config_value()}.

%%--------------------------------------------------------------------
%% Types — session config
%%--------------------------------------------------------------------

-type runtime_key() :: agent | mode | model | model_id | provider |
    provider_id | system | tools.
-type control_key() :: max_thinking_tokens | permission_mode.
-type config_scope() :: control | runtime.
-type scoped_config_key() ::
    {control, control_key()} |
    {runtime, runtime_key()}.

-doc "Runtime configuration map for a session.".
-type runtime_config() :: #{
    agent => binary(),
    mode => binary(),
    model_id => binary(),
    provider => map(),
    provider_id => binary(),
    system => binary() | map(),
    tools => [any()] | map()
}.

-doc "Full session configuration view: runtime, control, and session metadata.".
-type config_view() :: #{
    control := map(),
    runtime := runtime_config(),
    session := map()
}.

-type provider_oauth_authorize_result() :: #{
    authorize_url := term(),
    auth_method := binary(),
    provider := map(),
    provider_id := binary(),
    request_id := binary(),
    source := universal,
    status := pending
}.
-type provider_oauth_state() :: #{
    oauth_callback := map(),
    provider_id := binary(),
    source := universal
}.
-type provider_oauth_callback_result() :: #{
    auth_method := binary(),
    provider := provider_oauth_state(),
    provider_id := binary(),
    source := universal,
    status := configured
}.
-type value_key() :: authorize_url | config | control | key_path |
    request_id | runtime | settings | state | url | value |
    <<_:24, _:_*8>>.
-type value_default() :: #{} | undefined.

%%--------------------------------------------------------------------
%% Constants
%%--------------------------------------------------------------------

-define(CONFIG_TABLE, beam_agent_config).
-define(RUNTIME_KEYS, [provider_id, provider, model_id, model, agent, mode, system, tools]).
-define(CONTROL_KEYS, [permission_mode, max_thinking_tokens]).

-dialyzer({no_underspecs, [value/3,
                           {provider_oauth_authorize, 3},
                           {auth_methods_for_provider, 1},
                           {provider_summary, 1}]}).

%%====================================================================
%% Session Config — Public API (native_or routed)
%%====================================================================

-doc "Read the full configuration for a session.".
-spec read(pid() | binary()) -> {ok, map()} | {error, term()}.
read(Session) ->
    beam_agent_core:native_or(Session, config_read, [], fun() ->
        config_read(Session)
    end).

-doc "Read the session configuration with additional options.".
-spec read(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
read(Session, Opts) ->
    beam_agent_core:native_or(Session, config_read, [Opts], fun() ->
        config_read(Session)
    end).

-doc "Update the session configuration with a partial patch.".
-spec update(pid() | binary(), map()) -> {ok, term()} | {error, term()}.
update(Session, Body) ->
    beam_agent_core:native_or(Session, config_update, [Body], fun() ->
        config_update(Session, Body)
    end).

-doc "List the providers available in the session configuration.".
-spec providers(pid() | binary()) -> {ok, term()} | {error, term()}.
providers(Session) ->
    beam_agent_core:native_or(Session, config_providers, [], fun() ->
        beam_agent_runtime:list_providers(Session)
    end).

-doc "Write a single configuration value at the given key path.".
-spec value_write(pid() | binary(), binary(), term()) -> {ok, term()} | {error, term()}.
value_write(Session, KeyPath, Value) ->
    value_write(Session, KeyPath, Value, #{}).

-doc "Write a single configuration value with options.".
-spec value_write(pid() | binary(), binary(), term(), map()) -> {ok, term()} | {error, term()}.
value_write(Session, KeyPath, Value, Opts) ->
    beam_agent_core:native_or(Session, config_value_write, [KeyPath, Value, Opts], fun() ->
        config_value_write(Session, KeyPath, Value, Opts)
    end).

-doc "Write multiple configuration values in a single batch.".
-spec batch_write(pid() | binary(), [map()]) -> {ok, term()} | {error, term()}.
batch_write(Session, Edits) ->
    batch_write(Session, Edits, #{}).

-doc "Write multiple configuration values in a batch with options.".
-spec batch_write(pid() | binary(), [map()], map()) -> {ok, term()} | {error, term()}.
batch_write(Session, Edits, Opts) ->
    beam_agent_core:native_or(Session, config_batch_write, [Edits, Opts], fun() ->
        config_batch_write(Session, Edits, Opts)
    end).

-doc "Read the configuration requirements for a session.".
-spec requirements_read(pid() | binary()) -> {ok, term()} | {error, term()}.
requirements_read(Session) ->
    beam_agent_core:native_or(Session, config_requirements_read, [], fun() ->
        config_requirements_read(Session)
    end).

-doc "Detect external agent configuration files in the project.".
-spec external_agent_detect(pid() | binary()) -> {ok, term()} | {error, term()}.
external_agent_detect(Session) ->
    external_agent_detect(Session, #{}).

-doc "Detect external agent configuration files with options.".
-spec external_agent_detect(pid() | binary(), map()) -> {ok, term()} | {error, term()}.
external_agent_detect(Session, Opts) ->
    beam_agent_core:native_or(Session, external_agent_config_detect, [Opts], fun() ->
        external_agent_config_detect(Session, Opts)
    end).

-doc "Import an external agent configuration into the session.".
-spec external_agent_import(pid() | binary(), map()) -> {ok, term()} | {error, term()}.
external_agent_import(Session, Opts) ->
    beam_agent_core:native_or(Session, external_agent_config_import, [Opts], fun() ->
        external_agent_config_import(Session, Opts)
    end).

%%====================================================================
%% Global Config API
%%====================================================================

-doc """
Create the global config ETS table. Idempotent.

Call this during application init or let it be created lazily on first
global config access.
""".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?CONFIG_TABLE,
        [set, named_table, {read_concurrency, true}]).

-doc """
Set a global config key-value pair.

Overwrites any existing value for the same key.
Emits a `config` reload notification.
""".
-spec global_set(config_key(), config_value()) -> ok.
global_set(Key, Value) when is_binary(Key) ->
    ok = ensure_table(),
    beam_agent_ets:insert(?CONFIG_TABLE, {Key, Value}),
    beam_agent_reload_bus:notify(config),
    ok.

-doc "Fetch a global config value by key.".
-spec global_get(config_key()) -> {ok, config_value()} | {error, not_found}.
global_get(Key) when is_binary(Key) ->
    ok = ensure_table(),
    case ets:lookup(?CONFIG_TABLE, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, not_found}
    end.

-doc "Fetch a global config value by key, returning a default if not found.".
-spec global_get(config_key(), config_value()) -> config_value().
global_get(Key, Default) when is_binary(Key) ->
    case global_get(Key) of
        {ok, Value} -> Value;
        {error, not_found} -> Default
    end.

-doc """
Delete a global config key.

Idempotent — deleting a non-existent key is a no-op.
Emits a `config` reload notification.
""".
-spec global_delete(config_key()) -> ok.
global_delete(Key) when is_binary(Key) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?CONFIG_TABLE, Key),
    beam_agent_reload_bus:notify(config),
    ok.

-doc "List all global config entries as key-value pair maps.".
-spec global_list() -> [config_entry()].
global_list() ->
    ok = ensure_table(),
    [#{key => K, value => V} || {K, V} <- ets:tab2list(?CONFIG_TABLE)].

-doc """
Remove all global config entries.

Emits a `config` reload notification.
""".
-spec global_clear() -> ok.
global_clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?CONFIG_TABLE),
    beam_agent_reload_bus:notify(config),
    ok.

%%====================================================================
%% Universal Fallback Implementations
%%====================================================================
%%
%% These functions provide the universal (non-native) config behavior.
%% They are exported so backend facades can delegate to them directly.
%% The public API functions above route through native_or first.

-doc "Read the universal config/provider view for a live session pid or persisted session id.".
-spec config_read(pid() | binary()) -> {ok, config_view()} | {error, term()}.
config_read(Session) when is_pid(Session); is_binary(Session) ->
    SessionId = session_identity(Session),
    {ok, Runtime} = beam_agent_runtime_core:get_state(Session),
    {ok, Control} = beam_agent_control_core:get_all_config(SessionId),
    case beam_agent_core:session_info(Session) of
        {ok, Info} ->
            {ok, #{
                runtime => Runtime,
                control => Control,
                session => Info
            }};
        {error, not_found} when is_binary(Session) ->
            {ok, #{
                runtime => Runtime,
                control => Control,
                session => minimal_session_info(SessionId)
            }};
        {error, _} = Error ->
            Error
    end.

-doc "Apply universal config updates for backends without native config APIs.".
-spec config_update(pid() | binary(), map()) -> {ok, config_view()} | {error, term()}.
config_update(Session, Body) when (is_pid(Session) orelse is_binary(Session)), is_map(Body) ->
    SessionId = session_identity(Session),
    RuntimeUpdates = runtime_updates(Body),
    ControlUpdates = control_updates(Body),
    ok = apply_runtime_updates(Session, RuntimeUpdates),
    ok = apply_control_updates(SessionId, ControlUpdates),
    config_read(Session).

-doc "Write a single universal config value.".
-spec config_value_write(pid() | binary(), binary(), term(), map()) -> {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value, _Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_binary(KeyPath) ->
    case classify_key_path(KeyPath) of
        {runtime, Key} ->
            config_update(Session, #{runtime => #{Key => Value}});
        {control, Key} ->
            config_update(Session, #{control => #{Key => Value}});
        error ->
            {error, unsupported_key_path}
    end.

-doc "Apply a batch of universal config writes.".
-spec config_batch_write(pid() | binary(), [map()], map()) -> {ok, map()} | {error, term()}.
config_batch_write(Session, Edits, Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_list(Edits), is_map(Opts) ->
    lists:foldl(fun
        (_Edit, {error, _} = Error) ->
            Error;
        (Edit, {ok, _}) when is_map(Edit) ->
            KeyPath = value(Edit, [key_path, <<"key_path">>, <<"keyPath">>], undefined),
            Val = value(Edit, [value, <<"value">>], undefined),
            case KeyPath of
                Path when is_binary(Path) ->
                    config_value_write(Session, Path, Val, Opts);
                _ ->
                    {error, invalid_edit}
            end;
        (_, {ok, _}) ->
            {error, invalid_edit}
    end, {ok, #{}}, Edits).

-doc "Describe the universal config keys supported by the canonical fallback.".
-spec config_requirements_read(pid() | binary()) -> {ok, map()}.
config_requirements_read(_Session) ->
    Providers = beam_agent_runtime_core:provider_catalog(),
    {ok, #{
        runtime => #{
            provider_id => binary,
            provider => map,
            model_id => binary,
            agent => binary,
            mode => binary,
            system => [binary, map],
            tools => [map, list]
        },
        control => #{
            permission_mode => [binary, atom],
            max_thinking_tokens => integer
        },
        writable_key_paths => [
            <<"runtime.provider_id">>,
            <<"runtime.provider">>,
            <<"runtime.model_id">>,
            <<"runtime.agent">>,
            <<"runtime.mode">>,
            <<"runtime.system">>,
            <<"runtime.tools">>,
            <<"control.permission_mode">>,
            <<"control.max_thinking_tokens">>
        ],
        config_sources => [runtime, control, session],
        providers => Providers
    }}.

-doc "Detect universal config already materialized for a session.".
-spec external_agent_config_detect(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
external_agent_config_detect(Session, _Opts) when is_pid(Session); is_binary(Session) ->
    case config_read(Session) of
        {ok, Config} ->
            Runtime = maps:get(runtime, Config, #{}),
            Control = maps:get(control, Config, #{}),
            {ok, #{
                detected => (map_size(Runtime) > 0 orelse map_size(Control) > 0),
                source => universal,
                config => Config
            }};
        {error, _} = Error ->
            Error
    end.

-doc "Import universal config material from an already-decoded map.".
-spec external_agent_config_import(pid() | binary(), map()) ->
    {ok, config_view()} | {error, term()}.
external_agent_config_import(Session, Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_map(Opts) ->
    ImportMap = case value(Opts, [config, <<"config">>, settings, <<"settings">>], undefined) of
        Map when is_map(Map) -> Map;
        _ -> Opts
    end,
    config_update(Session, ImportMap).

%%====================================================================
%% Provider Auth — Universal Fallbacks
%%====================================================================

-doc "Describe provider auth methods available through the universal fallback.".
-spec provider_auth_methods(pid() | binary()) -> {ok, [map()]}.
provider_auth_methods(Session) ->
    {ok,
     case beam_agent_runtime_core:current_provider(Session) of
         {ok, ProviderId} ->
             auth_methods_for_provider(ProviderId);
         {error, not_set} ->
             union_auth_methods()
     end}.

-doc "Start a universal provider auth flow when native OAuth is unavailable.".
-spec provider_oauth_authorize(pid() | binary(), binary(), map()) ->
    {ok, provider_oauth_authorize_result()}.
provider_oauth_authorize(Session, ProviderId, Body)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(ProviderId), is_map(Body) ->
    SessionId = session_identity(Session),
    RequestId = beam_agent_core:make_request_id(),
    ProviderMeta = provider_summary(ProviderId),
    Request = #{
        kind => provider_oauth_authorize,
        provider_id => ProviderId,
        auth_method => <<"oauth_callback">>,
        provider => ProviderMeta,
        body => Body,
        source => universal
    },
    ok = beam_agent_control_core:store_pending_request(SessionId, RequestId, Request),
    {ok, #{
        request_id => RequestId,
        provider_id => ProviderId,
        provider => ProviderMeta,
        auth_method => <<"oauth_callback">>,
        authorize_url => value(Body, [authorize_url, <<"authorize_url">>, url, <<"url">>], undefined),
        source => universal,
        status => pending
    }}.

-doc "Complete a universal provider auth flow and persist the callback payload.".
-spec provider_oauth_callback(pid() | binary(), binary(), map()) ->
    {ok, provider_oauth_callback_result()} |
    {error, invalid_api_key | invalid_provider_config}.
provider_oauth_callback(Session, ProviderId, Body)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(ProviderId), is_map(Body) ->
    RequestId = value(Body, [request_id, <<"request_id">>, state, <<"state">>], undefined),
    _ = maybe_resolve_request(Session, RequestId, Body),
    CallbackUpdates = #{
        provider_id => ProviderId,
        oauth_callback => Body,
        source => universal
    },
    case beam_agent_runtime_core:merge_provider_config(Session, CallbackUpdates) of
        ok ->
            {ok, PublicProviderConfig} = beam_agent_runtime_core:get_provider_config(Session),
            {ok, #{
                provider_id => ProviderId,
                provider => PublicProviderConfig,
                auth_method => <<"oauth_callback">>,
                status => configured,
                source => universal
            }};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Internal Helpers — Session Config
%%====================================================================

-spec runtime_updates(map()) -> map().
runtime_updates(Body) ->
    Direct = maps:with(?RUNTIME_KEYS, Body),
    Nested = value(Body, [runtime, <<"runtime">>], #{}),
    normalize_runtime_keys(maps:merge(Direct, normalize_map(Nested))).

-spec control_updates(map()) -> map().
control_updates(Body) ->
    Direct = maps:with(?CONTROL_KEYS, Body),
    Nested = value(Body, [control, <<"control">>], #{}),
    maps:merge(Direct, normalize_map(Nested)).

-spec normalize_runtime_keys(map()) -> map().
normalize_runtime_keys(Updates) ->
    case maps:take(model, Updates) of
        {Model, Rest} ->
            Rest#{model_id => Model};
        error ->
            Updates
    end.

-spec apply_runtime_updates(pid() | binary(), map()) -> ok.
apply_runtime_updates(_Session, Updates) when map_size(Updates) =:= 0 ->
    ok;
apply_runtime_updates(Session, Updates) ->
    case maps:take(provider, Updates) of
        {ProviderConfig, Rest0} when is_map(ProviderConfig) ->
            ok = beam_agent_runtime_core:set_provider_config(Session, ProviderConfig),
            apply_runtime_updates(Session, Rest0);
        error ->
            ok = beam_agent_runtime_core:register_session(Session, Updates),
            ok
    end.

-spec apply_control_updates(binary(), map()) -> ok.
apply_control_updates(_SessionId, Updates) when map_size(Updates) =:= 0 ->
    ok;
apply_control_updates(SessionId, Updates) ->
    maps:foreach(fun
        (permission_mode, Mode) ->
            ok = beam_agent_control_core:set_permission_mode(SessionId, Mode);
        (max_thinking_tokens, Tokens) when is_integer(Tokens), Tokens > 0 ->
            ok = beam_agent_control_core:set_max_thinking_tokens(SessionId, Tokens);
        (Key, Val) ->
            ok = beam_agent_control_core:set_config(SessionId, Key, Val)
    end, Updates),
    ok.

-spec classify_key_path(binary()) -> scoped_config_key() | error.
classify_key_path(KeyPath) ->
    case binary:split(KeyPath, <<".">>, [global]) of
        [<<"runtime">>, Key] ->
            classify_scoped_key(runtime, Key);
        [<<"control">>, Key] ->
            classify_scoped_key(control, Key);
        [Key] ->
            case classify_scoped_key(runtime, Key) of
                {runtime, _} = Runtime ->
                    Runtime;
                error ->
                    classify_scoped_key(control, Key)
            end;
        _ ->
            error
    end.

-spec maybe_resolve_request(pid() | binary(), binary() | undefined, map()) -> ok.
maybe_resolve_request(_Session, undefined, _Body) ->
    ok;
maybe_resolve_request(Session, RequestId, Body) ->
    SessionId = session_identity(Session),
    case beam_agent_control_core:resolve_pending_request(SessionId, RequestId, Body) of
        ok -> ok;
        {error, _} -> ok
    end.

-spec session_identity(pid() | binary()) -> binary().
session_identity(Session) ->
    beam_agent_core:session_identity(Session).

-spec minimal_session_info(binary()) -> #{
    session_id := binary(),
    backend := beam_agent_backend:backend() | undefined,
    adapter := beam_agent_backend:backend() | undefined
}.
minimal_session_info(SessionId) ->
    Base = #{session_id => SessionId, backend => undefined, adapter => undefined},
    case beam_agent_backend:session_backend(SessionId) of
        {ok, Backend} -> Base#{backend => Backend, adapter => Backend};
        {error, _} -> Base
    end.

-spec normalize_map(term()) -> map().
normalize_map(Map) when is_map(Map) ->
    Map;
normalize_map(_) ->
    #{}.

-spec value(map(), [value_key()], value_default()) -> any().
value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Found} ->
            Found;
        error ->
            value(Map, Rest, Default)
    end;
value(_Map, [], Default) ->
    Default.

-spec classify_scoped_key(config_scope(), binary()) ->
    scoped_config_key() | error.
classify_scoped_key(runtime, <<"provider_id">>) -> {runtime, provider_id};
classify_scoped_key(runtime, <<"provider">>) -> {runtime, provider};
classify_scoped_key(runtime, <<"model_id">>) -> {runtime, model_id};
classify_scoped_key(runtime, <<"model">>) -> {runtime, model};
classify_scoped_key(runtime, <<"agent">>) -> {runtime, agent};
classify_scoped_key(runtime, <<"mode">>) -> {runtime, mode};
classify_scoped_key(runtime, <<"system">>) -> {runtime, system};
classify_scoped_key(runtime, <<"tools">>) -> {runtime, tools};
classify_scoped_key(control, <<"permission_mode">>) -> {control, permission_mode};
classify_scoped_key(control, <<"max_thinking_tokens">>) -> {control, max_thinking_tokens};
classify_scoped_key(_Scope, _Key) -> error.

%%====================================================================
%% Internal Helpers — Provider Auth
%%====================================================================

-spec auth_methods_for_provider(binary()) -> [map()].
auth_methods_for_provider(ProviderId) ->
    Provider = provider_summary(ProviderId),
    [#{
         id => Method,
         kind => Method,
         provider_id => ProviderId,
         provider => Provider,
         current => true,
         source => universal
     } || Method <- maps:get(auth_methods, Provider, [<<"api_key">>])].

-spec union_auth_methods() -> [map()].
union_auth_methods() ->
    Providers = beam_agent_runtime_core:provider_catalog(),
    Entries = lists:flatmap(fun(Provider) ->
        ProviderId = maps:get(id, Provider),
        [#{
             id => <<ProviderId/binary, ":", Method/binary>>,
             kind => Method,
             provider_id => ProviderId,
             provider => Provider,
             current => false,
             source => universal
         } || Method <- maps:get(auth_methods, Provider, [])]
    end, Providers),
    dedupe_auth_methods(Entries).

-spec dedupe_auth_methods([map()]) -> [map()].
dedupe_auth_methods(Entries) ->
    lists:reverse(
        lists:foldl(fun(Entry, Acc) ->
            Method = maps:get(kind, Entry),
            ProviderId = maps:get(provider_id, Entry),
            case lists:any(fun(Existing) ->
                     maps:get(kind, Existing) =:= Method andalso
                         maps:get(provider_id, Existing) =:= ProviderId
                 end, Acc) of
                true -> Acc;
                false -> [Entry | Acc]
            end
        end, [], Entries)).

-spec provider_summary(binary()) -> map().
provider_summary(ProviderId) ->
    case beam_agent_runtime_core:provider_metadata(ProviderId) of
        {ok, Provider} ->
            Provider;
        error ->
            #{
                id => ProviderId,
                label => ProviderId,
                source => runtime,
                auth_methods => [<<"api_key">>],
                capabilities => [<<"chat">>, <<"config">>],
                config_keys => []
            }
    end.
