defmodule BeamAgent.Catalog do
  @moduledoc """
  Catalog accessors for tools, skills, plugins, MCP servers, and agents.

  This module provides a read-only view of the extensions available to a live
  session. It queries the session's backend for native catalog listings when
  available, and falls back to normalised metadata extracted from the session
  info map otherwise.

  The catalog is always specific to a session (identified by pid). Different
  sessions may expose different catalogs depending on their backend, MCP server
  configuration, and installed extensions.

  ## When to use directly vs through `BeamAgent`

  Use this module directly when you need to inspect or switch the tooling
  available to a session — for example, in a capability-discovery UI, an
  orchestrator that selects agents dynamically, or a test that verifies tool
  availability.

  ## Quick example

  ```elixir
  # List all available tools for a session:
  {:ok, tools} = BeamAgent.Catalog.list_tools(session)

  # Look up a specific tool by name or ID:
  {:ok, tool} = BeamAgent.Catalog.get_tool(session, "file_read")

  # Check which agent is currently selected:
  {:ok, agent_id} = BeamAgent.Catalog.current_agent(session)

  # Override the default agent for future queries:
  :ok = BeamAgent.Catalog.set_default_agent(session, "claude-sonnet-4-6")
  ```

  ## Core concepts

  - **Catalog entries**: each entry is a map with at least an `:id` or `:name`
    key. The exact shape depends on the backend, but entries are normalised to
    ensure consistent lookup by id, name, or path.

  - **Native vs fallback**: backends that expose native listing functions are
    queried first. When native listings are unavailable, the catalog falls back to
    metadata extracted from the session info's `system_info` map.

  - **Default agent**: the one mutable operation in the catalog — setting the
    default agent. This is supported because agent selection is part of the
    unified query option shape and can be merged into future requests without
    backend-specific logic.

  ## Architecture deep dive

  This module delegates every call to `:beam_agent_catalog`. The underlying
  implementation (`:beam_agent_catalog_core`) queries native backend APIs first
  and falls back to `:gen_statem.call` session info extraction. The `session`
  argument is always a pid pointing to a live session process.

  See also: `BeamAgent.Runtime`, `BeamAgent.Control`, `BeamAgent`.
  """

  @doc """
  List all tools available to a session.

  Returns catalog entries from the session's tool listing. The exact contents
  depend on the backend and any MCP servers connected to the session.

  ## Example

  ```elixir
  {:ok, tools} = BeamAgent.Catalog.list_tools(session)
  Enum.each(tools, fn %{name: name} -> IO.puts("Tool: \#{name}") end)
  ```
  """
  @spec list_tools(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_tools(session), to: :beam_agent_catalog

  @doc """
  List all skills available to a session.

  Prefers native skill listings from the backend when available, falling back to
  skills extracted from session metadata.
  """
  @spec list_skills(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_skills(session), to: :beam_agent_catalog

  @doc """
  List all plugins available to a session.

  Returns plugin entries from the session's metadata. Plugin availability depends
  on the backend's extension model.
  """
  @spec list_plugins(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_plugins(session), to: :beam_agent_catalog

  @doc """
  List all MCP servers connected to a session.

  Returns metadata about each MCP server, including server names, capabilities,
  and connection status as reported by the backend.
  """
  @spec list_mcp_servers(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_mcp_servers(session), to: :beam_agent_catalog

  @doc """
  List all agents available to a session.

  Prefers native agent listings from the backend (e.g., Copilot's
  `list_server_agents`) when available, falling back to agents extracted from
  session metadata.
  """
  @spec list_agents(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_agents(session), to: :beam_agent_catalog

  @doc """
  Look up a single tool by its id, name, or path.

  Returns `{:error, :not_found}` when no tool matches the given identifier.

  ## Example

  ```elixir
  case BeamAgent.Catalog.get_tool(session, "file_read") do
    {:ok, %{name: name, description: desc}} -> IO.puts("Found " <> name <> ": " <> desc)
    {:error, :not_found} -> IO.puts("Tool not available")
  end
  ```
  """
  @spec get_tool(pid(), binary()) :: {:ok, map()} | {:error, :not_found | term()}
  defdelegate get_tool(session, tool_id), to: :beam_agent_catalog

  @doc """
  Look up a single skill by its id, name, or path.

  Returns `{:error, :not_found}` when no skill matches the given identifier.
  """
  @spec get_skill(pid(), binary()) :: {:ok, map()} | {:error, :not_found | term()}
  defdelegate get_skill(session, skill_id), to: :beam_agent_catalog

  @doc """
  Look up a single plugin by its id, name, or path.

  Returns `{:error, :not_found}` when no plugin matches the given identifier.
  """
  @spec get_plugin(pid(), binary()) :: {:ok, map()} | {:error, :not_found | term()}
  defdelegate get_plugin(session, plugin_id), to: :beam_agent_catalog

  @doc """
  Look up a single agent by its id, name, or path.

  Returns `{:error, :not_found}` when no agent matches the given identifier.
  """
  @spec get_agent(pid(), binary()) :: {:ok, map()} | {:error, :not_found | term()}
  defdelegate get_agent(session, agent_id), to: :beam_agent_catalog

  @doc """
  Return the currently selected default agent for a session.

  Returns `{:ok, agent_id}` if one has been set or inferred, or
  `{:error, :not_set}` when no agent is active.
  """
  @spec current_agent(pid()) :: {:ok, binary()} | {:error, :not_set}
  defdelegate current_agent(session), to: :beam_agent_catalog

  @doc """
  Set the default agent for future queries on a session.

  The agent ID is stored in the runtime state and merged into future query
  options automatically. Allows switching between agents without restarting the
  session.

  ## Example

  ```elixir
  :ok = BeamAgent.Catalog.set_default_agent(session, "claude-sonnet-4-6")
  {:ok, "claude-sonnet-4-6"} = BeamAgent.Catalog.current_agent(session)
  ```
  """
  @spec set_default_agent(pid(), binary()) :: :ok
  defdelegate set_default_agent(session, agent_id), to: :beam_agent_catalog

  @doc """
  Clear any default agent override for a session.

  After clearing, the session will use whatever agent the backend selects by
  default or infers from session metadata.
  """
  @spec clear_default_agent(pid()) :: :ok
  defdelegate clear_default_agent(session), to: :beam_agent_catalog

  @doc """
  Return the static list of CLI commands that the session's backend supports.

  Each backend advertises a fixed set of commands it can handle (e.g.,
  `"query"`, `"interrupt"`, `"config"`). Use this to discover what operations
  are available before attempting them, or to build dynamic command palettes.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, commands}` where `commands` is a list of command maps, each
    containing `:name` and `:description`.
  - `{:error, reason}` on failure.
  """
  @spec supported_commands(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate supported_commands(session), to: :beam_agent_catalog

  @doc """
  Return the static list of LLM models available for the session's backend.

  Use this to present model selection options or validate a model identifier
  before passing it to `BeamAgent.Runtime.set_model/2`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, models}` where `models` is a list of model maps, each containing
    `:name` and `:capabilities`.
  - `{:error, reason}` on failure.
  """
  @spec supported_models(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate supported_models(session), to: :beam_agent_catalog

  @doc """
  Return the static list of sub-agents that the session's backend exposes.

  Sub-agents are specialized assistants that handle focused tasks such as
  code review, test generation, or documentation writing.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agents}` where `agents` is a list of agent maps, each containing
    `:name`, `:description`, and `:capabilities`.
  - `{:error, reason}` on failure.
  """
  @spec supported_agents(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate supported_agents(session), to: :beam_agent_catalog

  @doc """
  List models available for the session using native-first routing.

  Convenience wrapper that calls `model_list/2` with empty options.
  Attempts the backend's native model listing first; falls back to
  `supported_models/1` if the backend does not support dynamic listing.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, models}` where `models` is a list of model maps.
  - `{:error, reason}` on failure.
  """
  @spec model_list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate model_list(session), to: :beam_agent_catalog

  @doc """
  List models with backend-specific filter options.

  Filters are backend-specific and may include capabilities, context window
  size, or model family. Uses native-first routing with a fallback to
  `supported_models/1`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific filter options map.

  ## Returns

  - `{:ok, models}` or `{:error, reason}`.
  """
  @spec model_list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate model_list(session, opts), to: :beam_agent_catalog

  @doc """
  List commands available for the session using native-first routing.

  Attempts the backend's native command listing first. Falls back to
  `supported_commands/1` if the backend does not support dynamic listing.
  The result may include commands added at runtime (e.g., via plugins or
  MCP servers).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, commands}` where `commands` is a list of command maps.
  - `{:error, reason}` on failure.
  """
  @spec list_commands(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_commands(session), to: :beam_agent_catalog
end
