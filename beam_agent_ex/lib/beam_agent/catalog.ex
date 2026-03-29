defmodule BeamAgent.Catalog do
  @moduledoc """
  Catalog accessors and global registry for tools, skills, plugins, MCP
  servers, agents, and slash commands.

  This module serves two purposes:

  1. **Session Catalog** -- a read-only view of the extensions available to a
     live session. It queries the session's backend for native catalog listings
     when available, and falls back to normalised metadata extracted from the
     session info map otherwise.

  2. **Global Registry** -- CRUD operations for agent types, plugins, and slash
     commands that are shared across all sessions. Mutations notify the reload
     bus so live sessions react without restart.

  ## When to use directly vs through `BeamAgent`

  Use this module directly when you need to inspect or switch the tooling
  available to a session, or when you need focused access to global registry
  operations -- for example, in a capability-discovery UI, an orchestrator that
  selects agents dynamically, a plugin marketplace, or a command palette.

  ## Quick example

  ```elixir
  # --- Session Catalog ---

  # List all available tools for a session:
  {:ok, tools} = BeamAgent.Catalog.list_tools(session)

  # Look up a specific tool by name or ID:
  {:ok, tool} = BeamAgent.Catalog.get_tool(session, "file_read")

  # --- Global Registry ---

  # Register an agent type globally:
  :ok = BeamAgent.Catalog.register_agent("code-reviewer", %{
    name: "Code Reviewer",
    description: "Reviews code for quality"
  })

  # List all registered plugins:
  plugins = BeamAgent.Catalog.registered_plugins()
  ```

  ## Core concepts

  - **Catalog entries**: each entry is a map with at least an `:id` or `:name`
    key. The exact shape depends on the backend, but entries are normalised to
    ensure consistent lookup by id, name, or path.

  - **Native vs fallback**: backends that expose native listing functions are
    queried first. When native listings are unavailable, the catalog falls back to
    metadata extracted from the session info's `system_info` map.

  - **Default agent**: setting the default agent for a session. This is supported
    because agent selection is part of the unified query option shape and can be
    merged into future requests without backend-specific logic.

  - **Global registry**: agent types, plugins, and slash commands registered
    globally via `register_agent/2`, `register_plugin/2`, and
    `register_command/2`. These are stored in `:beam_agent_registry` with
    composite keys `{Kind, Id}` and are shared across all sessions.

  ## Architecture deep dive

  This module delegates every call to `:beam_agent_catalog`. Session catalog
  queries go through `:beam_agent_catalog_core` (native backend APIs with
  `:gen_statem.call` fallback). Global registry operations go through
  `:beam_agent_registry` (unified ETS store).

  See also: `BeamAgent.Runtime`, `BeamAgent.Control`, `BeamAgent`.
  """

  @typedoc "A registry entry stored in the global agent/plugin/slash-command table."
  @type registry_entry() :: %{
          required(:id) => binary(),
          required(:name) => binary(),
          required(:kind) => :agent | :plugin | :slash,
          required(:enabled) => boolean(),
          optional(:description) => binary(),
          optional(:role) => atom(),
          optional(:version) => binary(),
          optional(:handler) => (map() -> {:ok, map()} | {:error, term()}),
          optional(:config) => map()
        }

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

  # -------------------------------------------------------------------
  # Global Registry — Agent Types
  # -------------------------------------------------------------------

  @doc """
  Create the global registry ETS table. Idempotent.
  """
  @spec ensure_registry() :: :ok
  defdelegate ensure_registry(), to: :beam_agent_catalog

  @doc """
  Register an agent type globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the agent type.
  - `opts` -- map of agent options (`:name`, `:description`, `:role`, `:enabled`, `:config`).
  """
  @spec register_agent(binary(), map()) :: :ok
  defdelegate register_agent(id, opts), to: :beam_agent_catalog

  @doc """
  Unregister an agent type by id. Idempotent.
  """
  @spec unregister_agent(binary()) :: :ok
  defdelegate unregister_agent(id), to: :beam_agent_catalog

  @doc """
  Fetch a single registered agent type by id.
  """
  @spec get_registered_agent(binary()) :: {:ok, registry_entry()} | {:error, :not_found}
  defdelegate get_registered_agent(id), to: :beam_agent_catalog

  @doc """
  List all globally registered agent types.
  """
  @spec registered_agents() :: [registry_entry()]
  defdelegate registered_agents(), to: :beam_agent_catalog

  @doc """
  Remove all globally registered agent types.
  """
  @spec clear_registered_agents() :: :ok
  defdelegate clear_registered_agents(), to: :beam_agent_catalog

  # -------------------------------------------------------------------
  # Global Registry — Plugins
  # -------------------------------------------------------------------

  @doc """
  Register a plugin globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the plugin.
  - `opts` -- map of plugin options (`:name`, `:description`, `:version`, `:enabled`, `:config`).
  """
  @spec register_plugin(binary(), map()) :: :ok
  defdelegate register_plugin(id, opts), to: :beam_agent_catalog

  @doc """
  Unregister a plugin by id. Idempotent.
  """
  @spec unregister_plugin(binary()) :: :ok
  defdelegate unregister_plugin(id), to: :beam_agent_catalog

  @doc """
  Fetch a single registered plugin by id.
  """
  @spec get_registered_plugin(binary()) :: {:ok, registry_entry()} | {:error, :not_found}
  defdelegate get_registered_plugin(id), to: :beam_agent_catalog

  @doc """
  List all globally registered plugins.
  """
  @spec registered_plugins() :: [registry_entry()]
  defdelegate registered_plugins(), to: :beam_agent_catalog

  @doc """
  Remove all globally registered plugins.
  """
  @spec clear_registered_plugins() :: :ok
  defdelegate clear_registered_plugins(), to: :beam_agent_catalog

  # -------------------------------------------------------------------
  # Global Registry — Slash Commands
  # -------------------------------------------------------------------

  @doc """
  Register a slash command globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the command.
  - `opts` -- map of command options (`:name`, `:description`, `:handler`, `:enabled`, `:config`).
  """
  @spec register_command(binary(), map()) :: :ok
  defdelegate register_command(id, opts), to: :beam_agent_catalog

  @doc """
  Unregister a slash command by id. Idempotent.
  """
  @spec unregister_command(binary()) :: :ok
  defdelegate unregister_command(id), to: :beam_agent_catalog

  @doc """
  Fetch a single registered slash command by id.
  """
  @spec get_registered_command(binary()) :: {:ok, registry_entry()} | {:error, :not_found}
  defdelegate get_registered_command(id), to: :beam_agent_catalog

  @doc """
  List all globally registered slash commands.
  """
  @spec registered_commands() :: [registry_entry()]
  defdelegate registered_commands(), to: :beam_agent_catalog

  @doc """
  Remove all globally registered slash commands.
  """
  @spec clear_registered_commands() :: :ok
  defdelegate clear_registered_commands(), to: :beam_agent_catalog

  # -------------------------------------------------------------------
  # File Operations — per-session, native_or routing
  # -------------------------------------------------------------------

  @doc """
  Search for text matching `pattern` in the session's working directory.
  """
  @spec find_text(pid(), binary()) :: {:ok, [:beam_agent_catalog.file_search_result()]} | {:error, term()}
  defdelegate find_text(session, pattern), to: :beam_agent_catalog

  @doc """
  Find files matching a pattern in the session's working directory.
  """
  @spec find_files(pid(), map()) :: {:ok, [:beam_agent_catalog.file_entry()]} | {:error, term()}
  defdelegate find_files(session, opts), to: :beam_agent_catalog

  @doc """
  Search for code symbols matching `query` in the session's project.
  """
  @spec find_symbols(pid(), binary()) :: {:ok, [:beam_agent_catalog.file_search_result()]} | {:error, term()}
  defdelegate find_symbols(session, query), to: :beam_agent_catalog

  @doc """
  List files and directories at the given path.
  """
  @spec file_list(pid(), binary()) :: {:ok, [:beam_agent_catalog.file_entry()]} | {:error, term()}
  defdelegate file_list(session, path), to: :beam_agent_catalog

  @doc """
  Read the contents of a file at the given path.
  """
  @spec file_read(pid(), binary()) :: {:ok, %{path: binary(), content: binary()}} | {:error, :enoent | term()}
  defdelegate file_read(session, path), to: :beam_agent_catalog

  @doc """
  Get the version-control status of files in the session's project.
  """
  @spec file_status(pid()) ::
          {:ok, %{cwd: binary(), source: :git | :filesystem, files: [map()]}}
          | {:error, term()}
  defdelegate file_status(session), to: :beam_agent_catalog

  # -------------------------------------------------------------------
  # Fuzzy Search — per-session, native_or routing
  # -------------------------------------------------------------------

  @doc """
  Fuzzy-search for files by name in the session's project.
  """
  @spec fuzzy_search(pid(), binary()) :: {:ok, [:beam_agent_search_core.search_match()]} | {:error, term()}
  defdelegate fuzzy_search(session, query), to: :beam_agent_catalog

  @doc """
  Fuzzy-search for files by name with options.
  """
  @spec fuzzy_search(pid(), binary(), map()) :: {:ok, [:beam_agent_search_core.search_match()]} | {:error, term()}
  defdelegate fuzzy_search(session, query, opts), to: :beam_agent_catalog

  @doc """
  Start a stateful fuzzy file search session.
  """
  @spec search_session_start(pid(), binary(), [binary()]) :: {:ok, :beam_agent_search_core.search_session()} | {:error, term()}
  defdelegate search_session_start(session, search_session_id, roots), to: :beam_agent_catalog

  @doc """
  Update a search session with a new query string.
  """
  @spec search_session_update(pid(), binary(), binary()) :: {:ok, [:beam_agent_search_core.search_match()]} | {:error, term()}
  defdelegate search_session_update(session, search_session_id, query), to: :beam_agent_catalog

  @doc """
  Stop and clean up a fuzzy file search session.
  """
  @spec search_session_stop(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate search_session_stop(session, search_session_id), to: :beam_agent_catalog

  # -------------------------------------------------------------------
  # Session Catalog — Static Listings
  # -------------------------------------------------------------------

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
