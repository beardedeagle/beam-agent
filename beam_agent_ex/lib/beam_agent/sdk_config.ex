defmodule BeamAgent.SDKConfig do
  @moduledoc """
  Global SDK configuration for the BeamAgent SDK.

  This module provides global SDK configuration management -- a shared
  key-value store for SDK-wide settings that apply across all sessions.
  Mutations notify the reload bus so live sessions react without restart.

  This module is distinct from `BeamAgent.Config`, which manages
  per-session backend configuration (model, provider, OAuth).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with SDK config through `BeamAgent`. Use this module
  directly when you need focused access to global configuration -- for example,
  in a settings UI, a configuration management tool, or during application
  startup to set SDK-wide defaults.

  ## Quick example

  ```elixir
  # Set a global config value:
  :ok = BeamAgent.SDKConfig.set("max_retries", 3)

  # Get a config value:
  {:ok, 3} = BeamAgent.SDKConfig.get("max_retries")

  # Get with default:
  5000 = BeamAgent.SDKConfig.get("timeout_ms", 5000)

  # List all config entries:
  entries = BeamAgent.SDKConfig.list()
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_sdk_config` module. Zero business logic, zero state,
  zero processes live here -- the Erlang module owns the implementation. The
  underlying config data is stored in ETS tables managed by
  `:beam_agent_global_config`.

  See also: `BeamAgent`, `BeamAgent.Config`, `BeamAgent.Skills`.
  """

  @doc """
  Create the global SDK config ETS table. Idempotent.
  """
  @spec ensure_table() :: :ok
  defdelegate ensure_table(), to: :beam_agent_sdk_config

  @doc """
  Set a global config key-value pair.

  ## Parameters

  - `key` -- binary config key.
  - `value` -- any term to store.
  """
  @spec set(binary(), term()) :: :ok
  defdelegate set(key, value), to: :beam_agent_sdk_config

  @doc """
  Fetch a global config value by key.
  """
  @spec get(binary()) :: {:ok, term()} | {:error, :not_found}
  defdelegate get(key), to: :beam_agent_sdk_config

  @doc """
  Fetch a global config value by key, returning a default if not found.
  """
  @spec get(binary(), term()) :: term()
  defdelegate get(key, default), to: :beam_agent_sdk_config

  @doc """
  Delete a global config key. Idempotent.
  """
  @spec delete(binary()) :: :ok
  defdelegate delete(key), to: :beam_agent_sdk_config

  @doc """
  List all global config entries.
  """
  @spec list() :: [map()]
  defdelegate list(), to: :beam_agent_sdk_config

  @doc """
  Remove all global config entries.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_sdk_config
end
