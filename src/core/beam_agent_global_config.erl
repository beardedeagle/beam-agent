-module(beam_agent_global_config).
-moduledoc """
Global SDK configuration store for the BEAM Agent SDK.

Provides a shared, process-free ETS key-value store for SDK-wide
configuration that applies across all sessions. Mutations emit
`{beam_agent_reload, config, Version}` via the reload bus so live
sessions can react without restart.

This module is distinct from `beam_agent_config_core`, which manages
per-session backend configuration (model, provider, OAuth). This
module stores SDK-level settings: feature flags, defaults, and
cross-cutting concerns.

## Usage

```erlang
%% During application init:
ok = beam_agent_global_config:ensure_table().

%% Set a config value:
ok = beam_agent_global_config:set(<<"default_backend">>, claude).

%% Read a config value:
{ok, claude} = beam_agent_global_config:get(<<"default_backend">>).

%% List all config:
Entries = beam_agent_global_config:list().

%% Delete a key:
ok = beam_agent_global_config:delete(<<"default_backend">>).
```
""".

-export([
    ensure_table/0,
    set/2,
    get/1,
    get/2,
    delete/1,
    list/0,
    clear/0
]).

-export_type([config_key/0, config_value/0, config_entry/0]).

-doc "A configuration key — always a binary.".
-type config_key() :: binary().

-doc "A configuration value — any Erlang term.".
-type config_value() :: term().

-doc "A key-value pair as returned by `list/0`.".
-type config_entry() :: #{key := config_key(), value := config_value()}.

-define(TABLE, beam_agent_global_config).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Create the global config ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE,
        [set, named_table, {read_concurrency, true}]).

%%--------------------------------------------------------------------
%% Write Operations
%%--------------------------------------------------------------------

-doc """
Set a global config key-value pair.

Overwrites any existing value for the same key.
Emits a `config` reload notification.
""".
-spec set(config_key(), config_value()) -> ok.
set(Key, Value) when is_binary(Key) ->
    ok = ensure_table(),
    beam_agent_ets:insert(?TABLE, {Key, Value}),
    beam_agent_reload_bus:notify(config),
    ok.

-doc """
Delete a global config key.

Idempotent — deleting a non-existent key is a no-op.
Emits a `config` reload notification.
""".
-spec delete(config_key()) -> ok.
delete(Key) when is_binary(Key) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?TABLE, Key),
    beam_agent_reload_bus:notify(config),
    ok.

%%--------------------------------------------------------------------
%% Read Operations
%%--------------------------------------------------------------------

-doc "Fetch a global config value by key.".
-spec get(config_key()) -> {ok, config_value()} | {error, not_found}.
get(Key) when is_binary(Key) ->
    ok = ensure_table(),
    case ets:lookup(?TABLE, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, not_found}
    end.

-doc "Fetch a global config value by key, returning a default if not found.".
-spec get(config_key(), config_value()) -> config_value().
get(Key, Default) when is_binary(Key) ->
    case ?MODULE:get(Key) of
        {ok, Value} -> Value;
        {error, not_found} -> Default
    end.

-doc "List all global config entries as key-value pair maps.".
-spec list() -> [config_entry()].
list() ->
    ok = ensure_table(),
    [#{key => K, value => V} || {K, V} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc """
Remove all global config entries.

Emits a `config` reload notification.
""".
-spec clear() -> ok.
clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    beam_agent_reload_bus:notify(config),
    ok.
