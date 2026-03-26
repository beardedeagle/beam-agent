-module(beam_agent_agent_registry).
-moduledoc """
Global agent type registry for the BEAM Agent SDK.

Provides a shared, process-free ETS store for registered agent types.
All sessions see the same agent catalog. Mutations emit
`{beam_agent_reload, agents, Version}` via the reload bus so live
sessions can react without restart.

Agent types are stored as maps keyed by a unique binary id. The
registry does not interpret agent definitions — it is a typed
key-value store with lifecycle notifications.

## Usage

```erlang
%% During application init:
ok = beam_agent_agent_registry:ensure_table().

%% Register an agent type:
ok = beam_agent_agent_registry:register(<<"code-reviewer">>, #{
    name => <<"Code Reviewer">>,
    description => <<"Reviews code for quality issues">>
}).

%% List all registered agent types:
Agents = beam_agent_agent_registry:list().

%% Unregister:
ok = beam_agent_agent_registry:unregister(<<"code-reviewer">>).
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

-export_type([agent_def/0]).

-doc """
A registered agent type definition.

Required fields:
- `id` — unique agent type identifier (set automatically from the registration key)
- `name` — human-readable agent name

Optional fields:
- `description` — free-text description of what this agent does
- `role` — agent role atom (e.g., `reviewer`, `executor`, `planner`)
- `enabled` — whether the agent type is available (defaults to `true`)
- `config` — arbitrary agent-specific configuration
""".
-type agent_def() :: #{
    id          := binary(),
    name        := binary(),
    description => binary(),
    role        => atom(),
    enabled     := boolean(),
    config      => map()
}.

-define(TABLE, beam_agent_global_agents).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Create the global agents ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE,
        [set, named_table, {read_concurrency, true}]).

%%--------------------------------------------------------------------
%% Registration
%%--------------------------------------------------------------------

-doc """
Register an agent type globally.

The `Id` becomes the `id` field in the stored definition. If an agent
with the same id already exists, it is overwritten. `Opts` may include
any fields from `agent_def()` except `id`, which is set from the key.

Emits an `agents` reload notification.
""".
-spec register(binary(), map()) -> ok.
register(Id, Opts) when is_binary(Id), is_map(Opts) ->
    ok = ensure_table(),
    Entry = build_entry(Id, Opts),
    beam_agent_ets:insert(?TABLE, {Id, Entry}),
    beam_agent_reload_bus:notify(agents),
    ok.

-doc """
Unregister an agent type by id.

Idempotent — unregistering a non-existent agent type is a no-op.
Emits an `agents` reload notification.
""".
-spec unregister(binary()) -> ok.
unregister(Id) when is_binary(Id) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?TABLE, Id),
    beam_agent_reload_bus:notify(agents),
    ok.

%%--------------------------------------------------------------------
%% Query
%%--------------------------------------------------------------------

-doc "Fetch a single agent type by id.".
-spec get(binary()) -> {ok, agent_def()} | {error, not_found}.
get(Id) when is_binary(Id) ->
    ok = ensure_table(),
    case ets:lookup(?TABLE, Id) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-doc "List all registered agent types.".
-spec list() -> [agent_def()].
list() ->
    ok = ensure_table(),
    [Entry || {_, Entry} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc """
Remove all registered agent types.

Emits an `agents` reload notification.
""".
-spec clear() -> ok.
clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    beam_agent_reload_bus:notify(agents),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec build_entry(binary(), map()) -> agent_def().
build_entry(Id, Opts) ->
    Base = #{
        id      => Id,
        name    => maps:get(name, Opts, Id),
        enabled => maps:get(enabled, Opts, true)
    },
    with_optional(description, Opts,
        with_optional(role, Opts,
            with_optional(config, Opts, Base))).

-spec with_optional(atom(), map(), agent_def()) -> agent_def().
with_optional(Key, Opts, Map) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Map#{Key => Value};
        error       -> Map
    end.
