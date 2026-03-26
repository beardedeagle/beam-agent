-module(beam_agent_slash_registry).
-moduledoc """
Global slash command registry for the BEAM Agent SDK.

Provides a shared, process-free ETS store for registered slash commands.
All sessions see the same command set. Mutations emit
`{beam_agent_reload, commands, Version}` via the reload bus so live
sessions can react without restart.

Slash commands are stored as maps keyed by a unique binary name
(without the leading `/`). The registry does not interpret command
definitions — it is a typed key-value store with lifecycle notifications.

## Usage

```erlang
%% During application init:
ok = beam_agent_slash_registry:ensure_table().

%% Register a slash command:
ok = beam_agent_slash_registry:register(<<"review">>, #{
    name => <<"review">>,
    description => <<"Run a code review on the current changes">>,
    handler => fun beam_agent_review:run/1
}).

%% List all registered slash commands:
Commands = beam_agent_slash_registry:list().

%% Unregister:
ok = beam_agent_slash_registry:unregister(<<"review">>).
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

-export_type([command_def/0, command_handler/0]).

-doc "Callback invoked when a slash command is executed.".
-type command_handler() :: fun((map()) -> {ok, map()} | {error, term()}).

-doc """
A registered slash command definition.

Required fields:
- `id` — unique command name (set automatically from the registration key)
- `name` — display name (defaults to `id`)

Optional fields:
- `description` — free-text description shown in help/autocomplete
- `handler` — callback function invoked on execution
- `enabled` — whether the command is available (defaults to `true`)
- `config` — arbitrary command-specific configuration
""".
-type command_def() :: #{
    id          := binary(),
    name        := binary(),
    description => binary(),
    handler     => command_handler(),
    enabled     := boolean(),
    config      => map()
}.

-define(TABLE, beam_agent_global_slash_commands).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc "Create the global slash commands ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE,
        [set, named_table, {read_concurrency, true}]).

%%--------------------------------------------------------------------
%% Registration
%%--------------------------------------------------------------------

-doc """
Register a slash command globally.

The `Id` becomes the `id` field in the stored definition. If a command
with the same id already exists, it is overwritten. `Opts` may include
any fields from `command_def()` except `id`, which is set from the key.

Emits a `commands` reload notification.
""".
-spec register(binary(), map()) -> ok.
register(Id, Opts) when is_binary(Id), is_map(Opts) ->
    ok = ensure_table(),
    Entry = build_entry(Id, Opts),
    beam_agent_ets:insert(?TABLE, {Id, Entry}),
    beam_agent_reload_bus:notify(commands),
    ok.

-doc """
Unregister a slash command by id.

Idempotent — unregistering a non-existent command is a no-op.
Emits a `commands` reload notification.
""".
-spec unregister(binary()) -> ok.
unregister(Id) when is_binary(Id) ->
    ok = ensure_table(),
    beam_agent_ets:delete(?TABLE, Id),
    beam_agent_reload_bus:notify(commands),
    ok.

%%--------------------------------------------------------------------
%% Query
%%--------------------------------------------------------------------

-doc "Fetch a single slash command by id.".
-spec get(binary()) -> {ok, command_def()} | {error, not_found}.
get(Id) when is_binary(Id) ->
    ok = ensure_table(),
    case ets:lookup(?TABLE, Id) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-doc "List all registered slash commands.".
-spec list() -> [command_def()].
list() ->
    ok = ensure_table(),
    [Entry || {_, Entry} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-doc """
Remove all registered slash commands.

Emits a `commands` reload notification.
""".
-spec clear() -> ok.
clear() ->
    ok = ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    beam_agent_reload_bus:notify(commands),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec build_entry(binary(), map()) -> command_def().
build_entry(Id, Opts) ->
    Base = #{
        id      => Id,
        name    => maps:get(name, Opts, Id),
        enabled => maps:get(enabled, Opts, true)
    },
    with_optional(description, Opts,
        with_optional(handler, Opts,
            with_optional(config, Opts, Base))).

-spec with_optional(atom(), map(), command_def()) -> command_def().
with_optional(Key, Opts, Map) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Map#{Key => Value};
        error       -> Map
    end.
