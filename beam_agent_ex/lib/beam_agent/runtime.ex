defmodule BeamAgent.Runtime do
  @moduledoc """
  Runtime state management for providers and agents.

  This module is the public API for the BeamAgent runtime layer. It manages
  per-session provider selection, provider configuration, default agent selection,
  and query option merging. All state is ETS-backed, keyed by session pid or
  session ID binary, and persists for the node lifetime or until explicitly
  cleared.

  The runtime layer is backend-agnostic. It stores canonical defaults that can be
  merged into future requests regardless of which backend transport is active.

  ## When to use directly vs through `BeamAgent`

  Use this module directly when you need to inspect or change provider/agent
  selection at runtime — for example, in a multi-provider orchestrator, a dynamic
  model-switching workflow, or a test that validates provider routing.

  ## Quick example

  ```elixir
  # Query the current provider for a session:
  {:ok, "anthropic"} = BeamAgent.Runtime.current_provider(session)

  # Switch provider at runtime:
  :ok = BeamAgent.Runtime.set_provider(session, "openai")

  # Validate a provider config before storing it:
  :ok = BeamAgent.Runtime.validate_provider_config("anthropic", %{api_key: "sk-ant-..."})

  # List all providers visible through the unified runtime layer:
  {:ok, providers} = BeamAgent.Runtime.list_providers(session)
  ```

  ## Core concepts

  - **Providers**: API key sources that supply model access. Each provider has an
    ID (e.g., `"anthropic"`, `"openai"`, `"google"`), authentication methods,
    capabilities, and configuration keys.

  - **Agents**: AI model identities used for queries. The runtime tracks the
    currently selected default agent per session and merges it into query options
    automatically.

  - **Session State**: an ETS-backed map per session holding `:provider_id`,
    `:provider` config, `:model_id`, `:agent`, `:mode`, `:system`, and `:tools`.

  ## Architecture deep dive

  This module delegates every call to `:beam_agent_runtime`. The underlying
  implementation (`:beam_agent_runtime_core`) queries the ETS-backed runtime
  state first, then falls back to native provider listings (for OpenCode) or
  session info inference via `:gen_statem.call`.

  See also: `BeamAgent.Catalog`, `BeamAgent.Control`, `BeamAgent`.
  """

  @doc """
  Return the current runtime state map for a session.

  Returns `{:ok, state}` — always succeeds, returning an empty map if no state
  has been registered.
  """
  @spec get_state(pid() | binary()) ::
          {:ok,
           %{
             optional(:provider_id) => binary(),
             optional(:provider) => map(),
             optional(:model_id) => binary(),
             optional(:agent) => binary(),
             optional(:mode) => binary(),
             optional(:system) => binary() | map(),
             optional(:tools) => map() | list()
           }}
  defdelegate get_state(session), to: :beam_agent_runtime

  @doc """
  Return the currently selected provider for a session.

  Checks the runtime state first. If no provider is explicitly set, attempts to
  infer the provider from the session's backend metadata.

  Returns `{:ok, provider_id}` or `{:error, :not_set}`.
  """
  @spec current_provider(pid() | binary()) :: {:ok, binary()} | {:error, :not_set}
  defdelegate current_provider(session), to: :beam_agent_runtime

  @doc """
  Set the default provider for future queries on a session.

  ## Example

  ```elixir
  :ok = BeamAgent.Runtime.set_provider(session, "anthropic")
  {:ok, "anthropic"} = BeamAgent.Runtime.current_provider(session)
  ```
  """
  @spec set_provider(pid() | binary(), binary()) :: :ok
  defdelegate set_provider(session, provider_id), to: :beam_agent_runtime

  @doc """
  Clear any default provider selection for a session.

  Removes both the provider ID and provider config from the runtime state. After
  clearing, `current_provider/1` will attempt inference from session metadata.
  """
  @spec clear_provider(pid() | binary()) :: :ok
  defdelegate clear_provider(session), to: :beam_agent_runtime

  @doc """
  Read the provider configuration map for a session.

  Returns `{:ok, config}` — an empty map when no config is stored.
  """
  @spec get_provider_config(pid() | binary()) :: {:ok, map()}
  defdelegate get_provider_config(session), to: :beam_agent_runtime

  @doc """
  Set provider configuration for future queries on a session.

  Stores a structured provider config map (API keys, base URLs, etc.) and
  attempts to infer the provider ID from the config.

  Returns `{:error, :invalid_api_key}` if the config contains a malformed API
  key.
  """
  @spec set_provider_config(pid() | binary(), map()) ::
          :ok | {:error, :invalid_api_key | :invalid_provider_config}
  defdelegate set_provider_config(session, config), to: :beam_agent_runtime

  @doc """
  Return the currently selected default agent for a session.

  Checks the runtime state first. If no agent is explicitly set, attempts to
  infer the agent from the session's backend metadata.

  Returns `{:ok, agent_id}` or `{:error, :not_set}`.

  ## Example

  ```elixir
  {:ok, "claude-sonnet-4-6"} = BeamAgent.Runtime.current_agent(session)
  ```
  """
  @spec current_agent(pid() | binary()) :: {:ok, binary()} | {:error, :not_set}
  defdelegate current_agent(session), to: :beam_agent_runtime

  @doc """
  Set the default agent for future queries on a session.
  """
  @spec set_agent(pid() | binary(), binary()) :: :ok
  defdelegate set_agent(session, agent_id), to: :beam_agent_runtime

  @doc """
  Clear any default agent selection for a session.

  After clearing, `current_agent/1` will attempt inference from session metadata.
  """
  @spec clear_agent(pid() | binary()) :: :ok
  defdelegate clear_agent(session), to: :beam_agent_runtime

  @doc """
  List providers visible through the unified runtime layer.

  Prefers native provider listings when the backend exposes them (e.g., OpenCode's
  `provider_list`). Falls back to a best-effort catalog derived from the built-in
  provider registry and current runtime state.
  """
  @spec list_providers(pid() | binary()) :: {:ok, [map()]}
  defdelegate list_providers(session), to: :beam_agent_runtime

  @doc """
  Return high-level provider status for the session's current provider.

  Returns `{:ok, status_map}` with `:provider_id` and current state details. If
  no provider is set, `:provider_id` is `nil`.
  """
  @spec provider_status(pid() | binary()) ::
          {:ok, %{required(:provider_id) => :undefined | binary(), optional(atom()) => term()}}
  defdelegate provider_status(session), to: :beam_agent_runtime

  @doc """
  Return status for a specific provider by ID.

  Includes configured state, authentication methods, capabilities, config keys,
  and whether the provider is the current selection.

  Returns `{:ok, status_map}` with `:provider_id` set.
  """
  @spec provider_status(pid() | binary(), binary()) ::
          {:ok, %{required(:provider_id) => binary(), optional(atom()) => term()}}
  defdelegate provider_status(session, provider_id), to: :beam_agent_runtime

  @doc """
  Validate a provider configuration map.

  Performs conservative validation — checks shape and obvious type errors without
  overfitting to a single backend's schema. Currently validates that any
  `:api_key` present is a non-empty binary.

  Returns `:ok` for valid configs, or `{:error, reason}` for invalid ones.

  ## Example

  ```elixir
  :ok = BeamAgent.Runtime.validate_provider_config("anthropic", %{api_key: "sk-ant-..."})

  {:error, :invalid_api_key} =
    BeamAgent.Runtime.validate_provider_config("anthropic", %{api_key: ""})
  ```
  """
  @spec validate_provider_config(binary() | nil, map()) ::
          :ok | {:error, :invalid_api_key | :invalid_provider_config}
  defdelegate validate_provider_config(provider_id, config), to: :beam_agent_runtime
end
