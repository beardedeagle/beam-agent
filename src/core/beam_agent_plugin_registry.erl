-module(beam_agent_plugin_registry).
-moduledoc """
Global plugin registry for the BEAM Agent SDK.

Provides a shared, process-free ETS store for registered plugins.
All sessions see the same plugin set. Mutations emit
`{beam_agent_reload, plugins, Version}` via the reload bus so live
sessions can react without restart.

Plugins are stored as maps keyed by a unique binary id. The registry
does not interpret plugin contents — it is a typed key-value store
with lifecycle notifications.

## Usage

```erlang
%% During application init:
ok = beam_agent_plugin_registry:ensure_table().

%% Register a plugin:
ok = beam_agent_plugin_registry:register(<<"my-plugin">>, #{
    name => <<"My Plugin">>,
    version => <<"1.0.0">>
}).

%% List all registered plugins:
Plugins = beam_agent_plugin_registry:list().

%% Unregister:
ok = beam_agent_plugin_registry:unregister(<<"my-plugin">>).
```
""".

-export([
    ensure_table/0,
    register/2,
    unregister/1,
    get/1,
    list/0,
    clear/0
]).

-export_type([plugin_def/0]).

-doc """
A registered plugin definition.

Required fields:
- `id` — unique plugin identifier (set automatically from the registration key)
- `name` — human-readable plugin name

Optional fields:
- `description` — free-text description
- `version` — semver string
- `enabled` — whether the plugin is active (defaults to `true`)
- `config` — arbitrary plugin-specific configuration
""".
-type plugin_def() :: #{
    id          := binary(),
    name        := binary(),
    description => binary(),
    version     => binary(),
    enabled     := boolean(),
    config      => map()
}.

-define(TABLE, beam_agent_global_plugins).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Create the global plugins ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE,
        [set, named_table, {read_concurrency, true}]).

%%--------------------------------------------------------------------
%% Registration
%%--------------------------------------------------------------------

-doc """
Register a plugin globally.

The `Id` becomes the `id` field in the stored definition. If a plugin
with the same id already exists, it is overwritten. `Opts` may include
any fields from `plugin_def()` except `id`, which is set from the key.

Emits a `plugins` reload notification.
""".
-spec register(binary(), map()) -> ok.
register(Id, Opts) when is_binary(Id), is_map(Opts) ->
    ok = ensure_table(),
    Entry = build_entry(Id, Opts),
    beam_agent_ets:insert(?TABLE, {Id, Entry}),
    beam_agent_reload_bus:notify(plugins),
    ok.

-doc """
Unregister a plugin by id.

Idempotent — unregistering a non-existent plugin is a no-op.
Emits a `plugins` reload notification.
""".
-spec unregister(binary()) -> ok.
unregister(Id) when is_binary(Id) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?TABLE, Id),
    beam_agent_reload_bus:notify(plugins),
    ok.

%%--------------------------------------------------------------------
%% Query
%%--------------------------------------------------------------------

-doc "Fetch a single plugin by id.".
-spec get(binary()) -> {ok, plugin_def()} | {error, not_found}.
get(Id) when is_binary(Id) ->
    ok = ensure_table(),
    case ets:lookup(?TABLE, Id) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-doc "List all registered plugins.".
-spec list() -> [plugin_def()].
list() ->
    ok = ensure_table(),
    [Entry || {_, Entry} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc """
Remove all registered plugins.

Emits a `plugins` reload notification.
""".
-spec clear() -> ok.
clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    beam_agent_reload_bus:notify(plugins),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec build_entry(binary(), map()) -> plugin_def().
build_entry(Id, Opts) ->
    Base = #{
        id      => Id,
        name    => maps:get(name, Opts, Id),
        enabled => maps:get(enabled, Opts, true)
    },
    with_optional(description, Opts,
        with_optional(version, Opts,
            with_optional(config, Opts, Base))).

-spec with_optional(atom(), map(), plugin_def()) -> plugin_def().
with_optional(Key, Opts, Map) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Map#{Key => Value};
        error       -> Map
    end.
