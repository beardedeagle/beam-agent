-module(beam_agent_registry).
-moduledoc """
Unified parameterized registry for agents, plugins, and slash commands.

Provides a shared, process-free ETS store for all registry kinds. Each
entry is keyed by `{Kind, Id}` in a single table, replacing the former
per-kind tables (`beam_agent_agent_registry`, `beam_agent_plugin_registry`,
`beam_agent_slash_registry`).

Mutations emit `{beam_agent_reload, NotifyAtom, Version}` via the reload
bus so live sessions react without restart.

## Supported Kinds

| Kind    | Reload atom | Description                    |
|---------|-------------|--------------------------------|
| `agent` | `agents`   | Registered agent types         |
| `plugin`| `plugins`  | Registered plugins             |
| `slash` | `commands` | Registered slash commands      |

## Usage

```erlang
%% During application init:
ok = beam_agent_registry:ensure_table().

%% Register entries (kind-parameterized):
ok = beam_agent_registry:register(agent, <<"code-reviewer">>, #{
    name => <<"Code Reviewer">>,
    description => <<"Reviews code for quality issues">>
}).
ok = beam_agent_registry:register(slash, <<"review">>, #{
    name => <<"review">>,
    description => <<"Run a code review">>
}).

%% Query by kind:
Agents = beam_agent_registry:list(agent).
{ok, Cmd} = beam_agent_registry:get(slash, <<"review">>).

%% Unregister:
ok = beam_agent_registry:unregister(plugin, <<"my-plugin">>).

%% Clear one kind or all:
ok = beam_agent_registry:clear(agent).
ok = beam_agent_registry:clear().
```

## See Also

  - `beam_agent_catalog` — public API for both session catalog and global registry
""".

-export([
    ensure_table/0,
    register/3,
    unregister/2,
    get/2,
    list/1,
    clear/1,
    clear/0
]).

-export_type([
    kind/0,
    registry_entry/0,
    agent_def/0,
    plugin_def/0,
    command_def/0,
    command_handler/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Registry entry kind discriminator.".
-type kind() :: agent | plugin | slash.

-doc "Callback invoked when a slash command is executed.".
-type command_handler() :: fun((map()) -> {ok, map()} | {error, term()}).

-doc """
A registry entry stored in the unified table.

Required fields:
- `id` — unique identifier within its kind (set from the registration key)
- `name` — human-readable display name (defaults to `id`)
- `kind` — discriminator atom (`agent`, `plugin`, or `slash`)
- `enabled` — whether the entry is active (defaults to `true`)

Optional fields (accepted from registration opts):
- `description` — free-text description
- `role` — agent role atom (agent kind only)
- `version` — semver string (plugin kind only)
- `handler` — execution callback (slash kind only)
- `config` — arbitrary kind-specific configuration
""".
-type registry_entry() :: #{
    id          := binary(),
    name        := binary(),
    kind        := kind(),
    enabled     := boolean(),
    description => binary(),
    role        => atom(),
    version     => binary(),
    handler     => command_handler(),
    config      => map()
}.

-doc "Agent type definition (alias for registry_entry with kind=agent).".
-type agent_def() :: registry_entry().

-doc "Plugin definition (alias for registry_entry with kind=plugin).".
-type plugin_def() :: registry_entry().

-doc "Slash command definition (alias for registry_entry with kind=slash).".
-type command_def() :: registry_entry().

-define(TABLE, beam_agent_registry).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Create the unified registry ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE,
        [set, named_table, {read_concurrency, true}]).

%%--------------------------------------------------------------------
%% Registration
%%--------------------------------------------------------------------

-doc """
Register an entry of the given kind globally.

The `Id` becomes the `id` field in the stored definition. If an entry
with the same kind and id already exists, it is overwritten. `Opts` may
include any optional fields from `registry_entry()` except `id` and
`kind`, which are set automatically.

Emits the appropriate reload notification for the kind.
""".
-spec register(kind(), binary(), map()) -> ok.
register(Kind, Id, Opts)
    when is_atom(Kind), is_binary(Id), is_map(Opts) ->
    ok = ensure_table(),
    Entry = build_entry(Kind, Id, Opts),
    beam_agent_ets:insert(?TABLE, {{Kind, Id}, Entry}),
    beam_agent_reload_bus:notify(reload_atom(Kind)),
    ok.

-doc """
Unregister an entry by kind and id.

Idempotent — unregistering a non-existent entry is a no-op.
Emits the appropriate reload notification for the kind.
""".
-spec unregister(kind(), binary()) -> ok.
unregister(Kind, Id) when is_atom(Kind), is_binary(Id) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?TABLE, {Kind, Id}),
    beam_agent_reload_bus:notify(reload_atom(Kind)),
    ok.

%%--------------------------------------------------------------------
%% Query
%%--------------------------------------------------------------------

-doc "Fetch a single entry by kind and id.".
-spec get(kind(), binary()) -> {ok, registry_entry()} | {error, not_found}.
get(Kind, Id) when is_atom(Kind), is_binary(Id) ->
    ok = ensure_table(),
    case ets:lookup(?TABLE, {Kind, Id}) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-doc "List all entries of a given kind.".
-spec list(kind()) -> [registry_entry()].
list(Kind) when is_atom(Kind) ->
    ok = ensure_table(),
    ets:select(?TABLE, [{{{Kind, '_'}, '$1'}, [], ['$1']}]).

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc """
Remove all entries of a given kind.

Emits the appropriate reload notification for the kind.
""".
-spec clear(kind()) -> ok.
clear(Kind) when is_atom(Kind) ->
    ok = ensure_table(),
    beam_agent_ets:select_delete(?TABLE, [{{{Kind, '_'}, '_'}, [], [true]}]),
    beam_agent_reload_bus:notify(reload_atom(Kind)),
    ok.

-doc """
Remove all entries across all kinds.

Emits reload notifications for all kinds.
""".
-spec clear() -> ok.
clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    beam_agent_reload_bus:notify(agents),
    beam_agent_reload_bus:notify(plugins),
    beam_agent_reload_bus:notify(commands),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec reload_atom(kind()) -> agents | plugins | commands.
reload_atom(agent)  -> agents;
reload_atom(plugin) -> plugins;
reload_atom(slash)  -> commands.

-spec build_entry(kind(), binary(), map()) -> registry_entry().
build_entry(Kind, Id, Opts) ->
    Base = #{
        id      => Id,
        name    => maps:get(name, Opts, Id),
        kind    => Kind,
        enabled => maps:get(enabled, Opts, true)
    },
    optional_fields(Opts, [description, role, version, handler, config], Base).

-spec optional_fields(map(), [atom()], registry_entry()) -> registry_entry().
optional_fields(_Opts, [], Acc) ->
    Acc;
optional_fields(Opts, [Key | Rest], Acc) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> optional_fields(Opts, Rest, Acc#{Key => Value});
        error       -> optional_fields(Opts, Rest, Acc)
    end.
