defmodule BeamAgent.SlashCommands do
  @moduledoc """
  Slash command management for the BeamAgent SDK.

  This module provides global slash command registration -- listing, registering,
  unregistering, and querying slash commands that are shared across all sessions.
  Mutations notify the reload bus so live sessions react without restart.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with slash commands through `BeamAgent`. Use this module
  directly when you need focused access to slash command operations -- for example,
  in a command palette UI, a command management dashboard, or a configuration
  tool that bulk-enables/disables commands.

  ## Quick example

  ```elixir
  # Register a slash command:
  :ok = BeamAgent.SlashCommands.register("review", %{
    name: "/review",
    description: "Review code in the current file",
    handler: :review_handler,
    enabled: true
  })

  # List all commands:
  commands = BeamAgent.SlashCommands.list()
  for c <- commands, do: IO.puts(c.name)

  # Unregister:
  :ok = BeamAgent.SlashCommands.unregister("review")
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that delegates every call to the
  `:beam_agent_catalog` Erlang module's global registry functions. Zero
  business logic, zero state, zero processes live here -- the Erlang module
  owns the implementation. The underlying command data is stored in the
  unified ETS table managed by `:beam_agent_registry`.

  See also: `BeamAgent`, `BeamAgent.Catalog`, `BeamAgent.Skills`.
  """

  @doc """
  Create the global registry ETS table. Idempotent.
  """
  @spec ensure_table() :: :ok
  defdelegate ensure_table(), to: :beam_agent_catalog, as: :ensure_registry

  @doc """
  Register a slash command globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the command.
  - `opts` -- map of command options (`:name`, `:description`, `:handler`, `:enabled`, `:config`).
  """
  @spec register(binary(), map()) :: :ok
  defdelegate register(id, opts), to: :beam_agent_catalog, as: :register_command

  @doc """
  Unregister a slash command by id. Idempotent.
  """
  @spec unregister(binary()) :: :ok
  defdelegate unregister(id), to: :beam_agent_catalog, as: :unregister_command

  @doc """
  Fetch a single slash command by id.
  """
  @spec get(binary()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get(id), to: :beam_agent_catalog, as: :get_registered_command

  @doc """
  List all registered slash commands.
  """
  @spec list() :: [map()]
  defdelegate list(), to: :beam_agent_catalog, as: :registered_commands

  @doc """
  Remove all registered slash commands.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_catalog, as: :clear_registered_commands
end
