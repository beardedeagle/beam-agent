-module(beam_agent_catalog).
-include_lib("kernel/include/file.hrl").
-moduledoc """
Catalog accessors and global registry for tools, skills, plugins, MCP
servers, agents, and slash commands.

This module serves two purposes:

1. **Session Catalog** — a read-only view of the extensions available to a
   live session. It queries the session's backend for native catalog listings
   when available, and falls back to normalized metadata extracted from the
   session info map otherwise.

2. **Global Registry** — CRUD operations for agent types, plugins, and slash
   commands that are shared across all sessions. Mutations notify the reload
   bus so live sessions react without restart. The underlying data is stored
   in a unified ETS table managed by `beam_agent_registry`.

## Getting Started

```erlang
%% --- Session Catalog ---

%% List all available tools for a session
{ok, Tools} = beam_agent_catalog:list_tools(Session),

%% Look up a specific tool by name or ID
{ok, Tool} = beam_agent_catalog:get_tool(Session, <<"file_read">>),

%% Check which agent is currently selected
{ok, AgentId} = beam_agent_catalog:current_agent(Session),

%% Override the default agent for future queries
ok = beam_agent_catalog:set_default_agent(Session, <<"claude-sonnet-4-6">>).

%% --- Global Registry ---

%% Register a global agent type
ok = beam_agent_catalog:register_agent(<<"code-reviewer">>, #{
    name => <<"Code Reviewer">>,
    description => <<"Reviews code for quality">>
}).

%% List all registered plugins
Plugins = beam_agent_catalog:registered_plugins().

%% Unregister a slash command
ok = beam_agent_catalog:unregister_command(<<"review">>).
```

## Key Concepts

  - Catalog Entries: Each entry is a map with at least an id or name key.
    The exact shape depends on the backend, but entries are normalized to
    ensure consistent lookup by id, name, or path.

  - Native vs Fallback: Backends that expose native listing functions (e.g.,
    Claude's skills_list, Copilot's list_server_agents) are queried first.
    When native listings are unavailable, the catalog falls back to metadata
    extracted from the session info's system_info map.

  - Default Agent: Setting the default agent for a session. This is
    supported because agent selection is already part of the unified query
    option shape and can be merged into future requests without
    backend-specific logic.

  - Global Registry: Agent types, plugins, and slash commands registered
    globally via `register_agent/2`, `register_plugin/2`, and
    `register_command/2`. These are stored in `beam_agent_registry` with
    composite keys `{Kind, Id}` and are shared across all sessions.

## Architecture

```
beam_agent_catalog (public API)
        |
        +--- Session Catalog ---+
        |                       |
        v                       v
beam_agent_catalog_core     beam_agent_registry
  (native listing,            (global ETS store,
   fallback metadata,          agent/plugin/slash
   entry lookup)               registration)
        |
        +-- beam_agent_raw_core (native backend calls)
        +-- beam_agent_runtime_core (agent state)
        +-- gen_statem:call (session_info fallback)
```

## See Also

  - `beam_agent` — Main SDK entry point
  - `beam_agent_runtime` — Provider and agent state management
  - `beam_agent_control` — Session configuration and permissions
  - `beam_agent_catalog_core` — Session catalog implementation (internal)
  - `beam_agent_registry` — Unified global registry (internal)
""".

-export([
    %% Session Catalog — per-session queries
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    list_commands/1,
    model_list/1,
    model_list/2,
    list_tools/1,
    list_skills/1,
    list_plugins/1,
    list_mcp_servers/1,
    list_agents/1,
    get_tool/2,
    get_skill/2,
    get_plugin/2,
    get_agent/2,
    current_agent/1,
    set_default_agent/2,
    clear_default_agent/1,
    %% Global Registry — agent types
    ensure_registry/0,
    register_agent/2,
    unregister_agent/1,
    get_registered_agent/1,
    registered_agents/0,
    clear_registered_agents/0,
    %% Global Registry — plugins
    register_plugin/2,
    unregister_plugin/1,
    get_registered_plugin/1,
    registered_plugins/0,
    clear_registered_plugins/0,
    %% Global Registry — slash commands
    register_command/2,
    unregister_command/1,
    get_registered_command/1,
    registered_commands/0,
    clear_registered_commands/0,
    %% File Operations — per-session, native_or routing
    find_text/2,
    find_files/2,
    find_symbols/2,
    file_list/2,
    file_read/2,
    file_status/1,
    %% Fuzzy Search — per-session, native_or routing
    fuzzy_search/2,
    fuzzy_search/3,
    search_session_start/3,
    search_session_update/3,
    search_session_stop/2,
    %% File impl — lower-level delegates for direct access
    file_find_text/2, file_find_text/3,
    file_find_files/1, file_find_files/2,
    file_find_symbols/1, file_find_symbols/2,
    file_list_impl/1, file_list_impl/2,
    file_read_impl/1, file_read_impl/2,
    file_status_impl/0, file_status_impl/1
]).

-export_type([file_search_result/0, file_entry/0, file_search_opts/0]).

%% Internal helpers: specs are deliberately broader than current call sites.
-dialyzer({nowarn_function, [
    file_find_text/2, file_find_text/3,
    file_find_symbols/2,
    file_read_impl/2,
    file_resolve_glob/3
]}).

%%--------------------------------------------------------------------
%% File Core Defines (folded from beam_agent_file_core)
%%--------------------------------------------------------------------

-define(DEFAULT_MAX_RESULTS, 100).
-define(DEFAULT_MAX_FILE_SIZE, 10485760). %% 10 MB
-define(DEFAULT_FILE_EXCLUDES, [<<".git">>, <<"_build">>, <<"node_modules">>, <<"deps">>]).

%%--------------------------------------------------------------------
%% File Core Types (folded from beam_agent_file_core)
%%--------------------------------------------------------------------

-type file_search_result() :: #{
    path    := binary(),
    line    := pos_integer(),
    content := binary()
}.

-type file_entry() :: #{
    path     := binary(),
    type     := file | directory | symlink | other,
    size     => non_neg_integer(),
    modified => calendar:datetime()
}.

-type file_search_opts() :: #{
    cwd            => binary(),
    max_results    => pos_integer(),
    include        => [binary()],
    exclude        => [binary()],
    case_sensitive => boolean()
}.

%%--------------------------------------------------------------------
%% Supported / Static Catalog Functions
%%--------------------------------------------------------------------

-doc """
Return the list of CLI commands the backend supports.

Returns a static list of commands declared by the backend adapter
(e.g., query, edit, review). The list does not change during the
lifetime of a session because it reflects the adapter's compiled
capability table rather than runtime state.

Session is the pid of a running beam_agent session.

Returns {ok, List} of command maps, each containing at minimum a
name and description, or {error, Reason} on failure.
""".
-spec supported_commands(pid()) -> {ok, [map()]} | {error, _}.
supported_commands(Session) -> beam_agent_core:supported_commands(Session).

-doc """
Return the list of LLM models the backend can use.

Queries the backend adapter for its declared model catalog. The
available models depend on the backend: Claude backends list models
such as claude-sonnet and claude-opus, while OpenAI-based backends
list GPT variants.

Session is the pid of a running beam_agent session.

Returns {ok, List} of model maps, each containing at minimum a model
name and its capabilities, or {error, Reason} on failure.
""".
-spec supported_models(pid()) -> {ok, [map()]} | {error, _}.
supported_models(Session) -> beam_agent_core:supported_models(Session).

-doc """
Return the list of sub-agents the backend exposes.

Sub-agents are specialized assistants (e.g., code reviewer, test
writer) that the primary agent can delegate tasks to. This function
returns the static list declared by the backend adapter rather than
any runtime-registered agents.

Session is the pid of a running beam_agent session.

Returns {ok, List} of agent maps, each containing at minimum a name
and description, or {error, Reason} on failure.
""".
-spec supported_agents(pid()) -> {ok, [map()]} | {error, _}.
supported_agents(Session) -> beam_agent_core:supported_agents(Session).

%%--------------------------------------------------------------------
%% Command and Model Listing (native_or routing)
%%--------------------------------------------------------------------

-doc """
List commands available for a session.

Tries the backend-native command listing first; falls back to the
static supported_commands/1 catalog if the backend does not provide
a native implementation. Prefer this over supported_commands/1 when
you want the most accurate view of what is currently available at
runtime.

Session is the pid of a running beam_agent session.

Returns {ok, List} of command maps, each containing at minimum a
name and description, or {error, Reason} on failure.
""".
-spec list_commands(pid()) -> {ok, list()} | {error, term()}.
list_commands(Session) ->
    beam_agent_core:native_or(Session, list_commands, [], fun() -> supported_commands(Session) end).

-doc """
List models available for a session using native-or routing.

Convenience wrapper that calls model_list/2 with an empty options
map. See model_list/2 for full details.

Tries the backend-native model listing first; falls back to the
static supported_models/1 catalog if the backend does not provide
one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of model maps, or {error, Reason} on failure.
""".
-spec model_list(pid()) -> {ok, list()} | {error, term()}.
model_list(Session) ->
    beam_agent_core:native_or(Session, model_list, [], fun() -> supported_models(Session) end).

-doc """
List models available for a session with optional filter criteria.

Tries the backend-native model listing first; falls back to the
static supported_models/1 catalog if the backend does not provide
one. When the fallback is used, filtering is applied client-side.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters that are backend-specific (e.g., capability
requirements, model family).

Returns {ok, List} of model maps on success, or {error, Reason}
on failure.
""".
-spec model_list(pid(), map()) -> {ok, list()} | {error, term()}.
model_list(Session, Opts) ->
    beam_agent_core:native_or(Session, model_list, [Opts], fun() -> supported_models(Session) end).

%%--------------------------------------------------------------------
%% List Functions
%%--------------------------------------------------------------------

-doc """
List all tools available to a session.

Returns catalog entries from the session's tool listing. The exact
contents depend on the backend and any MCP servers connected to
the session.

Example:

```erlang
{ok, Tools} = beam_agent_catalog:list_tools(Session),
lists:foreach(fun(#{name := Name}) ->
    io:format("Tool: ~s~n", [Name])
end, Tools).
```
""".
-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Session) -> beam_agent_catalog_core:list_tools(Session).

-doc """
List all skills available to a session.

Prefers native skill listings from the backend when available,
falling back to skills extracted from session metadata.
""".
-spec list_skills(pid()) -> {ok, [map()]} | {error, term()}.
list_skills(Session) -> beam_agent_catalog_core:list_skills(Session).

-doc """
List all plugins available to a session.

Returns plugin entries from the session's metadata. Plugin
availability depends on the backend's extension model.
""".
-spec list_plugins(pid()) -> {ok, [map()]} | {error, term()}.
list_plugins(Session) -> beam_agent_catalog_core:list_plugins(Session).

-doc """
List all MCP servers connected to a session.

Returns metadata about each MCP server, including server names,
capabilities, and connection status as reported by the backend.
""".
-spec list_mcp_servers(pid()) -> {ok, [map()]} | {error, term()}.
list_mcp_servers(Session) -> beam_agent_catalog_core:list_mcp_servers(Session).

-doc """
List all agents available to a session.

Prefers native agent listings from the backend (e.g., Copilot's
list_server_agents) when available, falling back to agents
extracted from session metadata.
""".
-spec list_agents(pid()) -> {ok, [map()]} | {error, term()}.
list_agents(Session) -> beam_agent_catalog_core:list_agents(Session).

%%--------------------------------------------------------------------
%% Get Functions
%%--------------------------------------------------------------------

-doc """
Look up a single tool by its id, name, or path.

Searches the tool catalog for a matching entry. Returns
{error, not_found} when no tool matches the given identifier.

Example:

```erlang
case beam_agent_catalog:get_tool(Session, <<"file_read">>) of
    {ok, #{name := Name, description := Desc}} ->
        io:format("Found ~s: ~s~n", [Name, Desc]);
    {error, not_found} ->
        io:format("Tool not available~n")
end.
```
""".
-spec get_tool(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_tool(Session, ToolId) -> beam_agent_catalog_core:get_tool(Session, ToolId).

-doc """
Look up a single skill by its id, name, or path.

Searches the skill catalog for a matching entry. Returns
{error, not_found} when no skill matches the given identifier.
""".
-spec get_skill(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_skill(Session, SkillId) -> beam_agent_catalog_core:get_skill(Session, SkillId).

-doc """
Look up a single plugin by its id, name, or path.

Searches the plugin catalog for a matching entry. Returns
{error, not_found} when no plugin matches the given identifier.
""".
-spec get_plugin(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_plugin(Session, PluginId) -> beam_agent_catalog_core:get_plugin(Session, PluginId).

-doc """
Look up a single agent by its id, name, or path.

Searches the agent catalog for a matching entry. Returns
{error, not_found} when no agent matches the given identifier.
""".
-spec get_agent(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_agent(Session, AgentId) -> beam_agent_catalog_core:get_agent(Session, AgentId).

%%--------------------------------------------------------------------
%% Agent Selection
%%--------------------------------------------------------------------

-doc """
Return the currently selected default agent for a session.

Returns the agent ID if one has been explicitly set via
set_default_agent/2, or inferred from the session's backend
metadata. Returns {error, not_set} when no agent is active.
""".
-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) -> beam_agent_catalog_core:current_agent(Session).

-doc """
Set the default agent for future queries on a session.

The agent ID is stored in the runtime state and merged into
future query options automatically. This allows switching between
agents (e.g., different model identities) without restarting the
session.

Example:

```erlang
ok = beam_agent_catalog:set_default_agent(Session, <<"claude-sonnet-4-6">>),
{ok, <<"claude-sonnet-4-6">>} = beam_agent_catalog:current_agent(Session).
```
""".
-spec set_default_agent(pid(), binary()) -> ok.
set_default_agent(Session, AgentId) -> beam_agent_catalog_core:set_default_agent(Session, AgentId).

-doc """
Clear any default agent override for a session.

After clearing, the session will use whatever agent the backend
selects by default or infers from session metadata.
""".
-spec clear_default_agent(pid()) -> ok.
clear_default_agent(Session) -> beam_agent_catalog_core:clear_default_agent(Session).

%%--------------------------------------------------------------------
%% Global Registry
%%--------------------------------------------------------------------

-doc "Create the global registry ETS table. Idempotent.".
-spec ensure_registry() -> ok.
ensure_registry() -> beam_agent_registry:ensure_table().

%%--------------------------------------------------------------------
%% Global Registry — Agent Types
%%--------------------------------------------------------------------

-doc """
Register an agent type globally (shared across all sessions).

The `Id` becomes the `id` field in the stored definition. If an entry
with the same id already exists, it is overwritten. `Opts` may include
any optional fields from `beam_agent_registry:registry_entry()` except
`id` and `kind`, which are set automatically.

Emits `{beam_agent_reload, agents, Version}` via the reload bus.
""".
-spec register_agent(binary(), map()) -> ok.
register_agent(Id, Opts) -> beam_agent_registry:register(agent, Id, Opts).

-doc """
Unregister an agent type by id. Idempotent.

Emits `{beam_agent_reload, agents, Version}` via the reload bus.
""".
-spec unregister_agent(binary()) -> ok.
unregister_agent(Id) -> beam_agent_registry:unregister(agent, Id).

-doc "Fetch a single registered agent type by id.".
-spec get_registered_agent(binary()) ->
    {ok, beam_agent_registry:agent_def()} | {error, not_found}.
get_registered_agent(Id) -> beam_agent_registry:get(agent, Id).

-doc "List all globally registered agent types.".
-spec registered_agents() -> [beam_agent_registry:agent_def()].
registered_agents() -> beam_agent_registry:list(agent).

-doc """
Remove all globally registered agent types.

Emits `{beam_agent_reload, agents, Version}` via the reload bus.
""".
-spec clear_registered_agents() -> ok.
clear_registered_agents() -> beam_agent_registry:clear(agent).

%%--------------------------------------------------------------------
%% Global Registry — Plugins
%%--------------------------------------------------------------------

-doc """
Register a plugin globally (shared across all sessions).

The `Id` becomes the `id` field in the stored definition. If an entry
with the same id already exists, it is overwritten. `Opts` may include
any optional fields from `beam_agent_registry:registry_entry()` except
`id` and `kind`, which are set automatically.

Emits `{beam_agent_reload, plugins, Version}` via the reload bus.
""".
-spec register_plugin(binary(), map()) -> ok.
register_plugin(Id, Opts) -> beam_agent_registry:register(plugin, Id, Opts).

-doc """
Unregister a plugin by id. Idempotent.

Emits `{beam_agent_reload, plugins, Version}` via the reload bus.
""".
-spec unregister_plugin(binary()) -> ok.
unregister_plugin(Id) -> beam_agent_registry:unregister(plugin, Id).

-doc "Fetch a single registered plugin by id.".
-spec get_registered_plugin(binary()) ->
    {ok, beam_agent_registry:plugin_def()} | {error, not_found}.
get_registered_plugin(Id) -> beam_agent_registry:get(plugin, Id).

-doc "List all globally registered plugins.".
-spec registered_plugins() -> [beam_agent_registry:plugin_def()].
registered_plugins() -> beam_agent_registry:list(plugin).

-doc """
Remove all globally registered plugins.

Emits `{beam_agent_reload, plugins, Version}` via the reload bus.
""".
-spec clear_registered_plugins() -> ok.
clear_registered_plugins() -> beam_agent_registry:clear(plugin).

%%--------------------------------------------------------------------
%% Global Registry — Slash Commands
%%--------------------------------------------------------------------

-doc """
Register a slash command globally (shared across all sessions).

The `Id` becomes the `id` field in the stored definition. If an entry
with the same id already exists, it is overwritten. `Opts` may include
any optional fields from `beam_agent_registry:registry_entry()` except
`id` and `kind`, which are set automatically.

Emits `{beam_agent_reload, commands, Version}` via the reload bus.
""".
-spec register_command(binary(), map()) -> ok.
register_command(Id, Opts) -> beam_agent_registry:register(slash, Id, Opts).

-doc """
Unregister a slash command by id. Idempotent.

Emits `{beam_agent_reload, commands, Version}` via the reload bus.
""".
-spec unregister_command(binary()) -> ok.
unregister_command(Id) -> beam_agent_registry:unregister(slash, Id).

-doc "Fetch a single registered slash command by id.".
-spec get_registered_command(binary()) ->
    {ok, beam_agent_registry:command_def()} | {error, not_found}.
get_registered_command(Id) -> beam_agent_registry:get(slash, Id).

-doc "List all globally registered slash commands.".
-spec registered_commands() -> [beam_agent_registry:command_def()].
registered_commands() -> beam_agent_registry:list(slash).

-doc """
Remove all globally registered slash commands.

Emits `{beam_agent_reload, commands, Version}` via the reload bus.
""".
-spec clear_registered_commands() -> ok.
clear_registered_commands() -> beam_agent_registry:clear(slash).

%%--------------------------------------------------------------------
%% File Operations
%%--------------------------------------------------------------------

-doc "Search for text matching Pattern in the session's working directory.".
-spec find_text(pid(), binary()) -> {ok, [file_search_result()]} | {error, term()}.
find_text(Session, Pattern) ->
    beam_agent_core:native_or(Session, find_text, [Pattern], fun() ->
        file_find_text(Pattern, session_file_opts(Session))
    end).

-doc "Find files matching a pattern in the session's working directory.".
-spec find_files(pid(), map()) -> {ok, [file_entry()]} | {error, term()}.
find_files(Session, Opts) ->
    beam_agent_core:native_or(Session, find_files, [Opts], fun() ->
        file_find_files(maps:merge(session_file_opts(Session), Opts))
    end).

-doc "Search for code symbols matching Query in the session's project.".
-spec find_symbols(pid(), binary()) -> {ok, [file_search_result()]} | {error, term()}.
find_symbols(Session, Query) ->
    beam_agent_core:native_or(Session, find_symbols, [Query], fun() ->
        file_find_symbols(Query, session_file_opts(Session))
    end).

-doc "List files and directories at the given Path.".
-spec file_list(pid(), binary()) -> {ok, [file_entry()]} | {error, term()}.
file_list(Session, Path) ->
    beam_agent_core:native_or(Session, file_list, [Path], fun() ->
        file_list_impl(Path)
    end).

-doc "Read the contents of a file at the given Path.".
-spec file_read(pid(), binary()) -> {ok, #{path := binary(), content := binary()}} | {error, term()}.
file_read(Session, Path) ->
    beam_agent_core:native_or(Session, file_read, [Path], fun() ->
        file_read_impl(Path)
    end).

-doc "Get the version-control status of files in the session's project.".
-spec file_status(pid()) -> {ok, #{cwd := binary(), source := git | filesystem, files := [map()]}} | {error, term()}.
file_status(Session) ->
    beam_agent_core:native_or(Session, file_status, [], fun() ->
        file_status_impl(session_file_opts(Session))
    end).

%%--------------------------------------------------------------------
%% Fuzzy Search
%%--------------------------------------------------------------------

-doc "Fuzzy-search for files by name in the session's project.".
-spec fuzzy_search(pid(), binary()) -> {ok, [beam_agent_search_core:search_match()]} | {error, term()}.
fuzzy_search(Session, Query) ->
    fuzzy_search(Session, Query, #{}).

-doc "Fuzzy-search for files by name with options.".
-spec fuzzy_search(pid(), binary(), map()) -> {ok, [beam_agent_search_core:search_match()]} | {error, term()}.
fuzzy_search(Session, Query, Opts) ->
    beam_agent_core:native_or(Session, fuzzy_file_search, [Query, Opts], fun() ->
        beam_agent_search_core:fuzzy_file_search(Query, Opts)
    end).

-doc "Start a stateful fuzzy file search session.".
-spec search_session_start(pid(), binary(), [binary()]) -> {ok, beam_agent_search_core:search_session()} | {error, term()}.
search_session_start(Session, SearchSessionId, Roots) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_start,
              [SearchSessionId, Roots], fun() ->
        beam_agent_search_core:session_start(Session, SearchSessionId, Roots)
    end).

-doc "Update a search session with a new query string.".
-spec search_session_update(pid(), binary(), binary()) -> {ok, [beam_agent_search_core:search_match()]} | {error, term()}.
search_session_update(Session, SearchSessionId, Query) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_update,
              [SearchSessionId, Query], fun() ->
        beam_agent_search_core:session_update(Session, SearchSessionId, Query)
    end).

-doc "Stop and clean up a fuzzy file search session.".
-spec search_session_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
search_session_stop(Session, SearchSessionId) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_stop,
              [SearchSessionId], fun() ->
        beam_agent_search_core:session_stop(Session, SearchSessionId),
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => stopped,
            search_session_id => SearchSessionId})}
    end).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec session_file_opts(pid()) -> file_search_opts().
session_file_opts(Session) ->
    case beam_agent_core:session_info(Session) of
        {ok, Info} ->
            Cwd = maps:get(cwd, Info,
                    maps:get(working_directory, Info,
                    maps:get(project_path, Info, undefined))),
            case Cwd of
                CwdBin when is_binary(CwdBin), byte_size(CwdBin) > 0 ->
                    #{cwd => CwdBin};
                _ ->
                    #{}
            end;
        {error, _} ->
            #{}
    end.

%%--------------------------------------------------------------------
%% File Core Implementation (folded from beam_agent_file_core)
%%--------------------------------------------------------------------

%% find_text

-spec file_find_text(binary(), file_search_opts()) ->
    {ok, [file_search_result()]} | {error, {invalid_pattern, string(), non_neg_integer()}}.
file_find_text(Pattern, Opts) when is_binary(Pattern), is_map(Opts) ->
    file_find_text(Pattern, <<"**/*">>, Opts).

-spec file_find_text(binary(), binary(), file_search_opts()) ->
    {ok, [file_search_result()]} | {error, {invalid_pattern, term(), non_neg_integer()}}.
file_find_text(Pattern, FileGlob, Opts)
  when is_binary(Pattern), is_binary(FileGlob), is_map(Opts) ->
    CaseSensitive = maps:get(case_sensitive, Opts, true),
    REOpts = case CaseSensitive of
        true  -> [];
        false -> [caseless]
    end,
    case re:compile(Pattern, REOpts) of
        {ok, CompiledRE} ->
            Cwd = file_cwd_binary(Opts),
            Files = file_resolve_glob(FileGlob, Cwd, Opts),
            MaxResults = maps:get(max_results, Opts, ?DEFAULT_MAX_RESULTS),
            Results = file_search_files(CompiledRE, Files, MaxResults, []),
            {ok, Results};
        {error, {Reason, Pos}} ->
            {error, {invalid_pattern, Reason, Pos}}
    end.

%% find_files

-spec file_find_files(file_search_opts()) -> {ok, [file_entry()]}.
file_find_files(Opts) when is_map(Opts) ->
    file_find_files(<<"**/*">>, Opts).

-spec file_find_files(binary(), file_search_opts()) -> {ok, [file_entry()]}.
file_find_files(Pattern, Opts) when is_binary(Pattern), is_map(Opts) ->
    Cwd = file_cwd_binary(Opts),
    Files = file_resolve_glob(Pattern, Cwd, Opts),
    Entries = [file_to_entry(Cwd, F) || F <- Files],
    Sorted = lists:sort(fun(A, B) ->
        maps:get(path, A) =< maps:get(path, B)
    end, Entries),
    {ok, Sorted}.

%% find_symbols

-spec file_find_symbols(file_search_opts()) ->
    {ok, [file_search_result()]} | {error, {invalid_pattern, string(), non_neg_integer()}}.
file_find_symbols(Opts) when is_map(Opts) ->
    file_find_symbols(<<>>, Opts).

-spec file_find_symbols(binary(), file_search_opts()) ->
    {ok, [file_search_result()]} | {error, term()}.
file_find_symbols(Query, Opts) when is_binary(Query), is_map(Opts) ->
    Q = re:replace(Query, <<"[\\^$.|?*+(){}\\[\\]\\\\]">>, <<"\\\\&">>,
                   [global, {return, binary}]),
    Pattern = case Q of
        <<>> ->
            <<"(-spec |^[a-z_][a-zA-Z0-9_]*\\(|"
              "def |defp |defmodule |"
              "class |function )">>;
        _ ->
            Parts = [
                <<"(-spec ", Q/binary, "\\()">>,
                <<"(^", Q/binary, "\\()">>,
                <<"(def ", Q/binary, "\\b)">>,
                <<"(defp ", Q/binary, "\\b)">>,
                <<"(defmodule ", Q/binary, "\\b)">>,
                <<"(class ", Q/binary, "\\b)">>,
                <<"(function ", Q/binary, "\\b)">>,
                <<"(const ", Q/binary, "\\s*=)">>
            ],
            file_join_binary(Parts, <<"|">>)
    end,
    file_find_text(Pattern, <<"**/*">>, Opts#{case_sensitive => true}).

%% file_list

-spec file_list_impl(binary()) -> {ok, [file_entry()]} | {error, term()}.
file_list_impl(Path) when is_binary(Path) ->
    file_list_impl(Path, #{}).

-spec file_list_impl(binary(), file_search_opts()) ->
    {ok, [file_entry()]} | {error, term()}.
file_list_impl(Path, Opts) when is_binary(Path), is_map(Opts) ->
    PathStr = unicode:characters_to_list(Path),
    case file:list_dir(PathStr) of
        {ok, Names} ->
            Sorted = lists:sort(Names),
            Entries = [file_to_entry(Path, list_to_binary(N)) || N <- Sorted],
            _ = Opts,
            {ok, Entries};
        {error, Reason} ->
            {error, {list_dir_failed, Path, Reason}}
    end.

%% file_read

-spec file_read_impl(binary()) ->
    {ok, #{path := binary(), content := binary()}}
    | {error, {file_too_large, binary()}}
    | {error, {read_failed, binary(), atom()}}.
file_read_impl(Path) when is_binary(Path) ->
    file_read_impl(Path, #{}).

-spec file_read_impl(binary(), file_search_opts()) ->
    {ok, #{path := binary(), content := binary()}}
    | {error, {file_too_large, binary()}}
    | {error, {read_failed, binary(), term()}}.
file_read_impl(Path, Opts) when is_binary(Path), is_map(Opts) ->
    PathStr = unicode:characters_to_list(Path),
    case file:read_file_info(PathStr) of
        {ok, #file_info{size = Size}} ->
            MaxSize = maps:get(max_file_size, Opts, ?DEFAULT_MAX_FILE_SIZE),
            case Size > MaxSize of
                true ->
                    {error, {file_too_large, Path}};
                false ->
                    case file:read_file(PathStr) of
                        {ok, Content} ->
                            {ok, #{path => Path, content => Content}};
                        {error, Reason} ->
                            {error, {read_failed, Path, Reason}}
                    end
            end;
        {error, Reason} ->
            {error, {read_failed, Path, Reason}}
    end.

%% file_status

-spec file_status_impl() ->
    {ok, #{cwd := binary(), source := git | filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), atom() | {_, _}}}.
file_status_impl() ->
    file_status_impl(#{}).

-spec file_status_impl(file_search_opts()) ->
    {ok, #{cwd := binary(), source := git | filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), term()}}.
file_status_impl(Opts) when is_map(Opts) ->
    Cwd = file_cwd_binary(Opts),
    CmdOpts = #{cwd => Cwd, timeout => 10000},
    case beam_agent_command_core:run(<<"git status --porcelain">>, CmdOpts) of
        {ok, #{exit_code := 0, output := Output}} ->
            Lines = binary:split(Output, <<"\n">>, [global, trim]),
            Files = [parse_git_status_line(L) || L <- Lines, L =/= <<>>],
            {ok, #{cwd => Cwd, source => git, files => Files}};
        _ ->
            file_fallback_status(Cwd)
    end.

%% File core internal helpers

-spec file_cwd_binary(file_search_opts()) -> binary().
file_cwd_binary(Opts) ->
    case maps:find(cwd, Opts) of
        {ok, Dir} when is_binary(Dir) ->
            Dir;
        {ok, Dir} when is_list(Dir) ->
            unicode:characters_to_binary(Dir);
        error ->
            case file:get_cwd() of
                {ok, Cwd} -> unicode:characters_to_binary(Cwd);
                {error, _} -> <<".">>
            end
    end.

-spec file_resolve_glob(binary(), binary(), file_search_opts()) -> [binary()].
file_resolve_glob(Glob, Cwd, Opts) ->
    GlobStr = unicode:characters_to_list(Glob),
    CwdStr = unicode:characters_to_list(Cwd),
    RawPaths = filelib:wildcard(GlobStr, CwdStr),
    Excludes = maps:get(exclude, Opts, ?DEFAULT_FILE_EXCLUDES),
    AbsFiles = [begin
        Abs = filename:join(CwdStr, P),
        unicode:characters_to_binary(Abs)
    end || P <- RawPaths, filelib:is_regular(filename:join(CwdStr, P))],
    [F || F <- AbsFiles, not file_is_excluded(F, Excludes)].

-spec file_is_excluded(binary(), [binary()]) -> boolean().
file_is_excluded(Path, Excludes) ->
    lists:any(fun(Pat) ->
        binary:match(Path, Pat) =/= nomatch
    end, Excludes).

-spec file_search_files(re:mp(), [binary()], pos_integer(), [file_search_result()]) ->
    [file_search_result()].
file_search_files(_RE, [], _MaxResults, Acc) ->
    lists:reverse(Acc);
file_search_files(_RE, _Files, MaxResults, Acc)
  when length(Acc) >= MaxResults ->
    lists:reverse(Acc);
file_search_files(RE, [File | Rest], MaxResults, Acc) ->
    Remaining = MaxResults - length(Acc),
    NewAcc = case file:read_file(unicode:characters_to_list(File)) of
        {ok, Content} when byte_size(Content) =< ?DEFAULT_MAX_FILE_SIZE ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            file_search_lines(RE, File, Lines, 1, Remaining, Acc);
        {ok, _TooBig} ->
            Acc;
        {error, _} ->
            Acc
    end,
    file_search_files(RE, Rest, MaxResults, NewAcc).

-spec file_search_lines(re:mp(), binary(), [binary()], pos_integer(),
                   pos_integer(), [file_search_result()]) -> [file_search_result()].
file_search_lines(_RE, _File, [], _LineNum, _Remaining, Acc) ->
    Acc;
file_search_lines(_RE, _File, _Lines, _LineNum, 0, Acc) ->
    Acc;
file_search_lines(RE, File, [Line | Rest], LineNum, Remaining, Acc) ->
    case re:run(Line, RE, [{capture, none}]) of
        match ->
            Result = #{path => File, line => LineNum, content => Line},
            file_search_lines(RE, File, Rest, LineNum + 1, Remaining - 1,
                         [Result | Acc]);
        nomatch ->
            file_search_lines(RE, File, Rest, LineNum + 1, Remaining, Acc)
    end.

-spec file_to_entry(binary(), binary()) -> file_entry().
file_to_entry(BasePath, Name) ->
    FullPath = case binary:last(BasePath) of
        $/ -> <<BasePath/binary, Name/binary>>;
        _  -> <<BasePath/binary, "/", Name/binary>>
    end,
    PathStr = unicode:characters_to_list(FullPath),
    Base = #{path => FullPath},
    case file:read_file_info(PathStr, [{time, local}]) of
        {ok, #file_info{size = Size, type = RawType, mtime = Mtime}} ->
            Type = file_normalize_type(RawType),
            Base#{type => Type, size => Size, modified => Mtime};
        {error, _} ->
            Base#{type => other}
    end.

-spec file_normalize_type(device | directory | other | regular | symlink) -> file | directory | symlink | other.
file_normalize_type(regular)   -> file;
file_normalize_type(directory) -> directory;
file_normalize_type(symlink)   -> symlink;
file_normalize_type(_)         -> other.

-spec parse_git_status_line(binary()) -> #{status := <<_:_*16>>, path := binary()}.
parse_git_status_line(Line) when byte_size(Line) >= 3 ->
    <<XY:2/binary, _Space:1/binary, Rest/binary>> = Line,
    #{status => XY, path => Rest};
parse_git_status_line(Line) ->
    #{status => <<>>, path => Line}.

-spec file_fallback_status(binary()) ->
    {ok, #{cwd := binary(), source := filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), term()}}.
file_fallback_status(Cwd) ->
    CwdStr = unicode:characters_to_list(Cwd),
    case file:list_dir(CwdStr) of
        {ok, Names} ->
            Entries = lists:filtermap(fun(Name) ->
                FullStr = filename:join(CwdStr, Name),
                FullBin = unicode:characters_to_binary(FullStr),
                case file:read_file_info(FullStr, [{time, local}]) of
                    {ok, #file_info{mtime = Mtime}} ->
                        {true, #{path => FullBin, modified => Mtime}};
                    {error, _} ->
                        false
                end
            end, lists:sort(Names)),
            {ok, #{cwd => Cwd, source => filesystem, files => Entries}};
        {error, Reason} ->
            {error, {list_dir_failed, Cwd, Reason}}
    end.

-spec file_join_binary([binary(), ...], binary()) -> binary().
file_join_binary([H], _Sep) -> H;
file_join_binary([H | T], Sep) ->
    lists:foldl(fun(Part, Acc) ->
        <<Acc/binary, Sep/binary, Part/binary>>
    end, H, T).
