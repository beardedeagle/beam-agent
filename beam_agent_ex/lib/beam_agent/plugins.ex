defmodule BeamAgent.Plugins do
  @moduledoc """
  Plugin management for the BeamAgent SDK.

  This module provides global plugin registration -- listing, registering,
  unregistering, and querying plugins that are shared across all sessions.
  Mutations notify the reload bus so live sessions react without restart.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with plugins through `BeamAgent`. Use this module
  directly when you need focused access to plugin operations -- for example,
  in a plugin management UI, a plugin marketplace browser, or a configuration
  tool that bulk-enables/disables plugins.

  ## Quick example

  ```elixir
  # Register a plugin:
  :ok = BeamAgent.Plugins.register("my-plugin", %{
    name: "My Plugin",
    description: "Does cool stuff",
    version: "1.0.0",
    enabled: true
  })

  # List all plugins:
  plugins = BeamAgent.Plugins.list()
  for p <- plugins, do: IO.puts(p.name)

  # Unregister:
  :ok = BeamAgent.Plugins.unregister("my-plugin")
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_plugins` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying plugin data is stored in the unified ETS table managed by
  `:beam_agent_registry`.

  See also: `BeamAgent`, `BeamAgent.Skills`, `BeamAgent.Agents`.
  """

  @doc """
  Create the global plugins ETS table. Idempotent.
  """
  @spec ensure_table() :: :ok
  defdelegate ensure_table(), to: :beam_agent_plugins

  @doc """
  Register a plugin globally (shared across all sessions).

  ## Parameters

  - `id` -- unique binary identifier for the plugin.
  - `opts` -- map of plugin options (`:name`, `:description`, `:version`, `:enabled`, `:config`).
  """
  @spec register(binary(), map()) :: :ok
  defdelegate register(id, opts), to: :beam_agent_plugins

  @doc """
  Unregister a plugin by id. Idempotent.
  """
  @spec unregister(binary()) :: :ok
  defdelegate unregister(id), to: :beam_agent_plugins

  @doc """
  Fetch a single plugin by id.
  """
  @spec get(binary()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get(id), to: :beam_agent_plugins

  @doc """
  List all registered plugins.
  """
  @spec list() :: [map()]
  defdelegate list(), to: :beam_agent_plugins

  @doc """
  Remove all registered plugins.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_plugins
end
