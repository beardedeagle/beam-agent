-module(beam_agent_config).
-moduledoc false.

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

-define(RUNTIME_KEYS, [provider_id, provider, model_id, model, agent, mode, system, tools]).
-define(CONTROL_KEYS, [permission_mode, max_thinking_tokens]).

-type runtime_key() :: agent | mode | model | model_id | provider |
    provider_id | system | tools.
-type control_key() :: max_thinking_tokens | permission_mode.
-type config_scope() :: control | runtime.
-type scoped_config_key() ::
    {control, control_key()} |
    {runtime, runtime_key()}.
-type runtime_config() :: #{
    agent => binary(),
    mode => binary(),
    model_id => binary(),
    provider => map(),
    provider_id => binary(),
    system => binary() | map(),
    tools => [any()] | map()
}.
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

-dialyzer({no_underspecs, [value/3,
                           {provider_oauth_authorize, 3},
                           {auth_methods_for_provider, 1},
                           {provider_summary, 1}]}).

-doc "Read the universal config/provider view for a live session.".
-spec config_read(pid()) -> {ok, config_view()} | {error, term()}.
config_read(Session) when is_pid(Session) ->
    SessionId = session_identity(Session),
    {ok, Runtime} = beam_agent_runtime_core:get_state(Session),
    {ok, Control} = beam_agent_control_core:get_all_config(SessionId),
    case beam_agent_router:session_info(Session) of
        {ok, Info} ->
            {ok, #{
                runtime => Runtime,
                control => Control,
                session => Info
            }};
        {error, _} = Error ->
            Error
    end.

-doc "Apply universal config updates for backends without native config APIs.".
-spec config_update(pid(), map()) -> {ok, config_view()} | {error, term()}.
config_update(Session, Body) when is_pid(Session), is_map(Body) ->
    SessionId = session_identity(Session),
    RuntimeUpdates = runtime_updates(Body),
    ControlUpdates = control_updates(Body),
    ok = apply_runtime_updates(Session, RuntimeUpdates),
    ok = apply_control_updates(SessionId, ControlUpdates),
    config_read(Session).

-doc "Write a single universal config value.".
-spec config_value_write(pid(), binary(), term(), map()) -> {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value, _Opts)
  when is_pid(Session), is_binary(KeyPath) ->
    case classify_key_path(KeyPath) of
        {runtime, Key} ->
            config_update(Session, #{runtime => #{Key => Value}});
        {control, Key} ->
            config_update(Session, #{control => #{Key => Value}});
        error ->
            {error, unsupported_key_path}
    end.

-doc "Apply a batch of universal config writes.".
-spec config_batch_write(pid(), [map()], map()) -> {ok, map()} | {error, term()}.
config_batch_write(Session, Edits, Opts)
  when is_pid(Session), is_list(Edits), is_map(Opts) ->
    lists:foldl(fun
        (_Edit, {error, _} = Error) ->
            Error;
        (Edit, {ok, _}) when is_map(Edit) ->
            KeyPath = value(Edit, [key_path, <<"key_path">>, <<"keyPath">>], undefined),
            Value = value(Edit, [value, <<"value">>], undefined),
            case KeyPath of
                Path when is_binary(Path) ->
                    config_value_write(Session, Path, Value, Opts);
                _ ->
                    {error, invalid_edit}
            end;
        (_, {ok, _}) ->
            {error, invalid_edit}
    end, {ok, #{}}, Edits).

-doc "Describe the universal config keys supported by the canonical fallback.".
-spec config_requirements_read(pid()) -> {ok, map()}.
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
-spec external_agent_config_detect(pid(), map()) -> {ok, map()} | {error, term()}.
external_agent_config_detect(Session, _Opts) when is_pid(Session) ->
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
-spec external_agent_config_import(pid(), map()) ->
    {ok, config_view()} | {error, term()}.
external_agent_config_import(Session, Opts) when is_pid(Session), is_map(Opts) ->
    ImportMap = case value(Opts, [config, <<"config">>, settings, <<"settings">>], undefined) of
        Map when is_map(Map) -> Map;
        _ -> Opts
    end,
    config_update(Session, ImportMap).

-doc "Describe provider auth methods available through the universal fallback.".
-spec provider_auth_methods(pid()) -> {ok, [map()]}.
provider_auth_methods(Session) ->
    {ok,
     case beam_agent_runtime_core:current_provider(Session) of
         {ok, ProviderId} ->
             auth_methods_for_provider(ProviderId);
         {error, not_set} ->
             union_auth_methods()
     end}.

-doc "Start a universal provider auth flow when native OAuth is unavailable.".
-spec provider_oauth_authorize(pid(), binary(), map()) ->
    {ok, provider_oauth_authorize_result()}.
provider_oauth_authorize(Session, ProviderId, Body)
  when is_pid(Session), is_binary(ProviderId), is_map(Body) ->
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
-spec provider_oauth_callback(pid(), binary(), map()) ->
    {ok, provider_oauth_callback_result()} |
    {error, invalid_api_key | invalid_provider_config}.
provider_oauth_callback(Session, ProviderId, Body)
  when is_pid(Session), is_binary(ProviderId), is_map(Body) ->
    RequestId = value(Body, [request_id, <<"request_id">>, state, <<"state">>], undefined),
    _ = maybe_resolve_request(Session, RequestId, Body),
    {ok, ProviderConfig} = beam_agent_runtime_core:get_provider_config(Session),
    CallbackConfig = maps:merge(ProviderConfig, #{
        provider_id => ProviderId,
        oauth_callback => Body,
        source => universal
    }),
    case beam_agent_runtime_core:set_provider_config(Session, CallbackConfig) of
        ok ->
            {ok, #{
                provider_id => ProviderId,
                provider => CallbackConfig,
                auth_method => <<"oauth_callback">>,
                status => configured,
                source => universal
            }};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

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

-spec apply_runtime_updates(pid(), map()) -> ok.
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
        (Key, Value) ->
            ok = beam_agent_control_core:set_config(SessionId, Key, Value)
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

-spec maybe_resolve_request(pid(), binary() | undefined, map()) -> ok.
maybe_resolve_request(_Session, undefined, _Body) ->
    ok;
maybe_resolve_request(Session, RequestId, Body) ->
    SessionId = session_identity(Session),
    case beam_agent_control_core:resolve_pending_request(SessionId, RequestId, Body) of
        ok -> ok;
        {error, _} -> ok
    end.

-spec session_identity(pid()) -> binary().
session_identity(Session) ->
    case beam_agent_router:session_info(Session) of
        {ok, #{session_id := SessionId}} when is_binary(SessionId),
                                              byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(erlang:pid_to_list(Session))
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
