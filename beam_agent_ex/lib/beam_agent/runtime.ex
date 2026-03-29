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
  has been registered. Secret-bearing provider fields are redacted in the public
  view.
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
  Read the provider configuration view for a session.

  Returns a redacted config map suitable for display and status surfaces. Secret
  values such as API keys and OAuth callback fields are replaced with
  `:redacted` markers. Returns `{:ok, config}` or an empty map when no config is
  stored.
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
  no provider is set, `:provider_id` is `nil` and any config in the public view
  remains redacted.
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

  # ---------------------------------------------------------------------------
  # Session-scoped runtime operations
  # ---------------------------------------------------------------------------

  @doc """
  Change the LLM model for a running session.

  Sends a model-switch command to the backend. If the backend supports
  native model switching, it is used directly; otherwise the runtime core
  stores it in its own state.

  ## Parameters

  - `session` -- pid of a running session.
  - `model` -- binary model identifier (e.g., `"claude-sonnet-4-20250514"`).

  ## Returns

  - `{:ok, model}` on success.
  - `{:error, reason}` on failure.
  """
  @spec set_model(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  defdelegate set_model(session, model), to: :beam_agent_runtime

  @doc """
  Change the permission mode for a running session.

  Controls how the backend handles tool execution and file edit approval.

  ## Parameters

  - `session` -- pid of a running session.
  - `mode` -- binary permission mode (e.g., `"default"`, `"accept_edits"`).

  ## Returns

  - `{:ok, mode}` on success.
  - `{:error, reason}` on failure.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  defdelegate set_permission_mode(session, mode), to: :beam_agent_runtime

  @doc """
  Interrupt the currently active query on a session.

  Sends an interrupt signal to the backend. If the backend supports
  native interrupts, it uses that; otherwise falls back to an OS-level
  signal for port-based transports.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `:ok` if the interrupt was sent.
  - `{:error, :not_supported}` if the backend does not support interrupts.
  - `{:error, reason}` on failure.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  defdelegate interrupt(session), to: :beam_agent_runtime

  @doc """
  Abort the currently active query and reset the session to ready state.

  Stronger than `interrupt/1`: forcibly cancels the query and transitions
  the session engine back to the ready state.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `:ok` or `{:error, reason}`.
  """
  @spec abort(pid()) :: :ok | {:error, term()}
  defdelegate abort(session), to: :beam_agent_runtime

  @doc """
  Send a backend-specific control message to a session.

  Control messages provide a generic extension point for features not
  covered by the typed API.

  ## Parameters

  - `session` -- pid of a running session.
  - `method` -- binary method name (e.g., `"mcp_message"`, `"set_config"`).
  - `params` -- map of method-specific parameters.

  ## Returns

  - `{:ok, result}` on success.
  - `{:error, :not_supported}` if the backend does not handle this method.
  - `{:error, reason}` on failure.
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate send_control(session, method, params), to: :beam_agent_runtime

  @doc """
  Get the overall status of a session including health and metadata.

  Assembles a comprehensive status snapshot combining the session's health
  state, connection status, backend identifier, model, and session metadata.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status_map}` containing keys such as `:health`, `:backend`,
    `:session_id`, `:model`, and `:connected`.
  - `{:error, reason}` on failure.
  """
  @spec get_status(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate get_status(session), to: :beam_agent_runtime

  @doc """
  Get the authentication status for the session's active provider.

  Returns whether the session is currently authenticated, which
  authentication method is in use, and token expiration details.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, auth_status}` containing `:authenticated`, `:auth_method`,
    and `:expires_at`.
  - `{:error, reason}` on failure.
  """
  @spec get_auth_status(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate get_auth_status(session), to: :beam_agent_runtime

  @doc """
  Get the backend's own session identifier for a running session.

  Returns the session ID as assigned by the backend (not the BEAM pid).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, session_id}` where `session_id` is a binary.
  - `{:error, reason}` on failure.
  """
  @spec get_last_session_id(pid()) :: {:ok, binary()} | {:error, term()}
  defdelegate get_last_session_id(session), to: :beam_agent_runtime

  @doc """
  Start the Windows sandbox setup process.

  Initiates sandbox configuration for backends that run in a Windows
  environment. On non-Windows platforms the universal fallback returns
  `status: :not_applicable`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- setup options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec windows_sandbox_setup_start(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate windows_sandbox_setup_start(session, opts), to: :beam_agent_runtime

  @doc """
  Set the maximum number of thinking tokens for the session.

  Controls how many tokens the backend's reasoning model may use for
  internal chain-of-thought before producing a visible response.

  ## Parameters

  - `session` -- pid of a running session.
  - `max_tokens` -- positive integer token limit.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec set_max_thinking_tokens(pid(), pos_integer()) :: {:ok, term()} | {:error, term()}
  defdelegate set_max_thinking_tokens(session, max_tokens), to: :beam_agent_runtime

  @doc """
  Stop a running task by its identifier.

  Sends an interrupt to the session and marks the task as stopped.

  ## Parameters

  - `session` -- pid of a running session.
  - `task_id` -- binary task identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec stop_task(pid(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate stop_task(session, task_id), to: :beam_agent_runtime

  # ---------------------------------------------------------------------------
  # Account operations
  # ---------------------------------------------------------------------------

  @doc """
  Retrieve account and authentication information for the session's backend.

  Returns details about the authenticated user including identity,
  subscription plan, usage quotas, and the authentication method in use.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, info_map}` or `{:error, reason}`.
  """
  @spec account_info(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate account_info(session), to: :beam_agent_runtime

  @doc """
  Initiate an account login flow.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- credentials/OAuth parameters map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec account_login(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate account_login(session, opts), to: :beam_agent_runtime

  @doc """
  Cancel an in-progress account login flow.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- should match the original login parameters.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec account_cancel(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate account_cancel(session, opts), to: :beam_agent_runtime

  @doc """
  Log out of the current account.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec account_logout(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate account_logout(session), to: :beam_agent_runtime

  @doc """
  Get rate limit information for the current account.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, rate_limit_info}` or `{:error, reason}`.
  """
  @spec account_rate_limits(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate account_rate_limits(session), to: :beam_agent_runtime

  # ---------------------------------------------------------------------------
  # App/project operations
  # ---------------------------------------------------------------------------

  @doc """
  List apps and projects registered for the session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, apps}` or `{:error, reason}`.
  """
  @spec apps_list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate apps_list(session), to: :beam_agent_runtime

  @doc """
  List apps and projects for the session with filter options.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map.

  ## Returns

  - `{:ok, apps}` or `{:error, reason}`.
  """
  @spec apps_list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate apps_list(session, opts), to: :beam_agent_runtime

  @doc """
  Get information about the current app or project context.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, app_info}` or `{:error, reason}`.
  """
  @spec app_info(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate app_info(session), to: :beam_agent_runtime

  @doc """
  Initialize the app/project context by scanning the working directory.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  @spec app_init(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate app_init(session), to: :beam_agent_runtime

  @doc """
  Append a log entry to the session's app log.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- log entry map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec app_log(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate app_log(session, body), to: :beam_agent_runtime

  @doc """
  List available app modes for the session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, modes}` or `{:error, reason}`.
  """
  @spec app_modes(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate app_modes(session), to: :beam_agent_runtime

  # ---------------------------------------------------------------------------
  # Todo operations
  # ---------------------------------------------------------------------------

  @doc """
  Extract all todo items from a flat list of messages.

  Scans the message list for messages that carry todo arrays and returns
  all todo items in order. Pure function -- no ETS, no side effects.

  ## Parameters

  - `messages` -- list of session messages.

  ## Returns

  A list of todo item maps.
  """
  @spec extract_todos([BeamAgent.message()]) :: [map()]
  defdelegate extract_todos(messages), to: :beam_agent_runtime

  @doc """
  Filter a todo list by status.

  ## Parameters

  - `todos` -- list of todo item maps.
  - `status` -- atom (`:pending`, `:in_progress`, or `:completed`).

  ## Returns

  Filtered list of todo items.
  """
  @spec filter_by_status([map()], atom()) :: [map()]
  defdelegate filter_by_status(todos, status), to: :beam_agent_runtime

  @doc """
  Summarize a todo list as a count map.

  ## Parameters

  - `todos` -- list of todo item maps.

  ## Returns

  A map with `:total` and one key per distinct status.
  """
  @spec todo_summary([map()]) :: %{:total => non_neg_integer(), atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: :beam_agent_runtime
end
