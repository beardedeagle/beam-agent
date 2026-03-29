defmodule BeamAgent.Agents do
  @moduledoc """
  Agent type management for the BeamAgent SDK.

  This module provides global agent type registration -- listing, registering,
  unregistering, and querying agent types that are shared across all sessions.
  Mutations notify the reload bus so live sessions react without restart.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with agent types through `BeamAgent`. Use this module
  directly when you need focused access to agent type operations -- for example,
  in an agent type management UI, an agent catalog browser, or a configuration
  tool that bulk-enables/disables agent types.

  ## Quick example

  ```elixir
  # Register an agent type:
  :ok = BeamAgent.Agents.register("code-reviewer", %{
    name: "Code Reviewer",
    description: "Reviews code for quality issues",
    role: "reviewer",
    enabled: true
  })

  # List all agent types:
  agents = BeamAgent.Agents.list()
  for a <- agents, do: IO.puts(a.name)

  # Unregister:
  :ok = BeamAgent.Agents.unregister("code-reviewer")
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that delegates every call to the
  `:beam_agent_catalog` Erlang module's global registry functions. Zero
  business logic, zero state, zero processes live here -- the Erlang module
  owns the implementation. The underlying agent type data is stored in the
  unified ETS table managed by `:beam_agent_registry`.

  See also: `BeamAgent`, `BeamAgent.Catalog`, `BeamAgent.Plugins`.
  """

  @typedoc "An agent type definition stored in the global registry."
  @type agent_def() :: %{
          required(:id) => binary(),
          required(:name) => binary(),
          required(:kind) => :agent | :plugin | :slash,
          required(:enabled) => boolean(),
          optional(:description) => binary(),
          optional(:role) => atom(),
          optional(:version) => binary(),
          optional(:config) => map()
        }

  @doc """
  Create the global registry ETS table. Idempotent.
  """
  @spec ensure_table() :: :ok
  defdelegate ensure_table(), to: :beam_agent_catalog, as: :ensure_registry

  @doc """
  Register an agent type globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the agent type.
  - `opts` -- map of agent options (`:name`, `:description`, `:role`, `:enabled`, `:config`).
  """
  @spec register(binary(), map()) :: :ok
  defdelegate register(id, opts), to: :beam_agent_catalog, as: :register_agent

  @doc """
  Unregister an agent type by id. Idempotent.
  """
  @spec unregister(binary()) :: :ok
  defdelegate unregister(id), to: :beam_agent_catalog, as: :unregister_agent

  @doc """
  Fetch a single agent type by id.
  """
  @spec get(binary()) :: {:ok, agent_def()} | {:error, :not_found}
  defdelegate get(id), to: :beam_agent_catalog, as: :get_registered_agent

  @doc """
  List all registered agent types.
  """
  @spec list() :: [agent_def()]
  defdelegate list(), to: :beam_agent_catalog, as: :registered_agents

  @doc """
  Remove all registered agent types.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_catalog, as: :clear_registered_agents
end
