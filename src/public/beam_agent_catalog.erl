-module(beam_agent_catalog).
-moduledoc """
Catalog accessors for tools, skills, plugins, MCP servers, and agents.

This module provides a read-only view of the extensions available to a
live session. It queries the session's backend for native catalog listings
when available, and falls back to normalized metadata extracted from the
session info map otherwise.

The catalog is always specific to a session (identified by pid). Different
sessions may expose different catalogs depending on their backend, MCP
server configuration, and installed extensions.

## Getting Started

```erlang
%% List all available tools for a session
{ok, Tools} = beam_agent_catalog:list_tools(Session),

%% Look up a specific tool by name or ID
{ok, Tool} = beam_agent_catalog:get_tool(Session, <<"file_read">>),

%% Check which agent is currently selected
{ok, AgentId} = beam_agent_catalog:current_agent(Session),

%% Override the default agent for future queries
ok = beam_agent_catalog:set_default_agent(Session, <<"claude-sonnet-4-6">>).
```

## Key Concepts

  - Catalog Entries: Each entry is a map with at least an id or name key.
    The exact shape depends on the backend, but entries are normalized to
    ensure consistent lookup by id, name, or path.

  - Native vs Fallback: Backends that expose native listing functions (e.g.,
    Claude's skills_list, Copilot's list_server_agents) are queried first.
    When native listings are unavailable, the catalog falls back to metadata
    extracted from the session info's system_info map.

  - Default Agent: The one mutable operation in the catalog -- setting the
    default agent. This is supported because agent selection is already part
    of the unified query option shape and can be merged into future requests
    without backend-specific logic.

## Architecture

```
beam_agent_catalog (public API)
        |
        v
beam_agent_catalog_core (native listing, fallback metadata, entry lookup)
        |
        +-- beam_agent_raw_core (native backend calls)
        +-- beam_agent_runtime_core (agent state)
        +-- gen_statem:call (session_info fallback)
```

== Core concepts ==

The catalog is the directory of everything a session can use: tools
(functions the agent can call), skills (higher-level capabilities),
plugins (extensions), MCP servers (tool providers), and agents
(AI model identities).

Use list_tools/1 to see all available tools, get_tool/2 to look up a
specific one by name or ID. The catalog is populated automatically when
a session starts -- the backend tells the SDK what is available, and
the catalog stores it for easy lookup.

Each session has its own catalog. Different sessions may have different
tools available depending on their backend and MCP server configuration.

== Architecture deep dive ==

Catalog data is stored in ETS tables managed by beam_agent_catalog_core.
The tables are populated during session init and updated in handle_data
as the backend reports new tool registrations or changes.

Native catalog queries go through beam_agent_raw_core:call/3 first. If
the backend does not support native listing, the fallback extracts
metadata from the session info system_info map. Registration order is
preserved in the ETS tables.

The default agent is the sole mutable operation -- it updates
beam_agent_runtime_core state and merges into future query options.

## See Also

  - `beam_agent` -- Main SDK entry point
  - `beam_agent_runtime` -- Provider and agent state management
  - `beam_agent_control` -- Session configuration and permissions
  - `beam_agent_catalog_core` -- Core implementation (internal)

## Backend Integration

The catalog stores tool, skill, plugin, and agent definitions in ETS tables
managed by the session engine. Backend handlers populate the catalog during
init and handle_data. See docs/guides/backend_integration_guide.md for how
catalog population works.
""".

-export([
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
    clear_default_agent/1
]).

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
