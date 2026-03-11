defmodule BeamAgent.Control do
  @moduledoc """
  Control plane for session configuration, permissions, tasks, and feedback.

  This module is the public API for the BeamAgent control layer. It manages
  per-session configuration state, permission and approval workflows, task
  lifecycle tracking, user feedback collection, and pending request/response
  handling for turn-based agent interactions.

  All state is ETS-backed, keyed by session ID, and persists for the node
  lifetime or until explicitly cleared. The control layer works identically
  across all five backends (Claude, Codex, Gemini, OpenCode, Copilot).

  ## When to use directly vs through `BeamAgent`

  Use this module directly when you need to configure runtime session settings,
  manage background tasks, submit feedback, or handle turn-based pending
  requests without going through the higher-level `BeamAgent` API.

  ## Quick example

  ```elixir
  # Set session permission mode:
  :ok = BeamAgent.Control.set_permission_mode(session_id, "acceptEdits")

  # Configure thinking token budget:
  :ok = BeamAgent.Control.set_max_thinking_tokens(session_id, 8192)

  # Dispatch a named control method:
  {:ok, _} = BeamAgent.Control.dispatch(session_id, "setModel", %{
    "model" => "claude-sonnet-4-6"
  })

  # Register and stop a background task:
  :ok = BeamAgent.Control.register_task(session_id, "task-abc", self())
  :ok = BeamAgent.Control.stop_task(session_id, "task-abc")
  ```

  ## Core concepts

  - **Session Config**: an ETS-backed key-value store scoped to a session ID.
    Arbitrary atom keys map to arbitrary term values. Convenience accessors exist
    for common keys (`:permission_mode`, `:max_thinking_tokens`).

  - **Task Registration**: long-running background tasks can be registered with a
    session so that they can be listed, monitored, and stopped via the control
    dispatch protocol.

  - **Callback Broker**: sessions can register callback functions for permission
    handling, approval decisions, and user input prompts. The broker invokes
    these callbacks safely (catching exceptions) and falls back to configured
    defaults when no handler is registered.

  - **Pending Requests**: turn-based interaction protocol where the agent stores a
    pending request (e.g., asking for user input) and the consumer resolves it
    later with a response.

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to
  `:beam_agent_control`. The underlying implementation lives in
  `:beam_agent_control_core`, which owns five ETS tables: `config`, `tasks`,
  `feedback`, `callbacks`, and `pending`.

  See also: `BeamAgent.Runtime`, `BeamAgent.Catalog`, `BeamAgent`.
  """

  @doc """
  Dispatch a named control method to the appropriate handler.

  Supported methods:
  - `"setModel"` — set the model; requires `"model"` key in params
  - `"setPermissionMode"` — set the permission mode; requires `"permissionMode"` key
  - `"setMaxThinkingTokens"` — set the thinking token budget; requires `"maxThinkingTokens"` key
  - `"stopTask"` — stop a running background task; requires `"taskId"` key

  Returns `{:ok, result_map}` or `{:error, reason}`.

  ## Example

  ```elixir
  {:ok, %{model: "claude-sonnet-4-6"}} =
    BeamAgent.Control.dispatch(session_id, "setModel", %{"model" => "claude-sonnet-4-6"})

  {:error, {:unknown_method, "noSuchMethod"}} =
    BeamAgent.Control.dispatch(session_id, "noSuchMethod", %{})
  ```
  """
  @spec dispatch(binary(), binary(), map()) ::
          {:ok,
           %{
             optional(:model) => term(),
             optional(:permission_mode) => binary() | atom(),
             optional(:max_thinking_tokens) => pos_integer()
           }}
          | {:error,
             :not_found
             | {:invalid_param, :max_thinking_tokens}
             | {:missing_param, :max_thinking_tokens | :model | :permission_mode | :task_id}
             | {:unknown_method, binary()}}
  defdelegate dispatch(session_id, method, params), to: :beam_agent_control

  @doc """
  Get a configuration value for a session.

  Returns `{:ok, value}` or `{:error, :not_set}` when the key has not been
  written.
  """
  @spec get_config(binary(), atom()) :: {:ok, term()} | {:error, :not_set}
  defdelegate get_config(session_id, key), to: :beam_agent_control

  @doc """
  Set a configuration value for a session.

  Stores an arbitrary term under the given atom key, scoped to the session ID.
  Overwrites any previous value for the same key.
  """
  @spec set_config(binary(), atom(), term()) :: :ok
  defdelegate set_config(session_id, key, value), to: :beam_agent_control

  @doc """
  Get all configuration for a session as a map.

  Returns `{:ok, map}` — an empty map when nothing is set.
  """
  @spec get_all_config(binary()) :: {:ok, map()}
  defdelegate get_all_config(session_id), to: :beam_agent_control

  @doc """
  Clear all configuration for a session.
  """
  @spec clear_config(binary()) :: :ok
  defdelegate clear_config(session_id), to: :beam_agent_control

  @doc """
  Set the permission mode for a session.

  The permission mode controls how the agent handles tool execution approvals.
  Common values include `"acceptEdits"`, `"auto"`, and `"manual"`. The exact
  interpretation depends on the backend.

  ## Example

  ```elixir
  :ok = BeamAgent.Control.set_permission_mode(session_id, "acceptEdits")
  ```
  """
  @spec set_permission_mode(binary(), binary() | atom()) :: :ok
  defdelegate set_permission_mode(session_id, mode), to: :beam_agent_control

  @doc """
  Get the permission mode for a session.

  Returns `{:ok, mode}` or `{:error, :not_set}` when no mode has been configured.
  """
  @spec get_permission_mode(binary()) :: {:ok, binary() | atom()} | {:error, :not_set}
  defdelegate get_permission_mode(session_id), to: :beam_agent_control

  @doc """
  Set the maximum thinking token budget for a session.

  `tokens` must be a positive integer. Used by backends that support extended
  thinking (e.g., Claude) to cap the number of tokens the model may use for
  internal reasoning.
  """
  @spec set_max_thinking_tokens(binary(), pos_integer()) :: :ok
  defdelegate set_max_thinking_tokens(session_id, tokens), to: :beam_agent_control

  @doc """
  Get the maximum thinking token budget for a session.

  Returns `{:ok, tokens}` or `{:error, :not_set}` when no budget has been
  configured.
  """
  @spec get_max_thinking_tokens(binary()) :: {:ok, pos_integer()} | {:error, :not_set}
  defdelegate get_max_thinking_tokens(session_id), to: :beam_agent_control

  @doc """
  Register an active task for a session.

  Associates a task ID and owning process with the session. The task is initially
  marked as running. Use `stop_task/2` to signal the task to stop, and
  `unregister_task/2` to remove it after completion.

  ## Example

  ```elixir
  :ok = BeamAgent.Control.register_task(session_id, "task-abc-123", self())
  {:ok, [%{task_id: "task-abc-123", status: :running}]} =
    BeamAgent.Control.list_tasks(session_id)
  ```
  """
  @spec register_task(binary(), binary(), pid()) :: :ok
  defdelegate register_task(session_id, task_id, pid), to: :beam_agent_control

  @doc """
  Unregister a task, removing it from the session's task list.

  Use this after a task has completed or been cleaned up.
  """
  @spec unregister_task(binary(), binary()) :: :ok
  defdelegate unregister_task(session_id, task_id), to: :beam_agent_control

  @doc """
  Stop a running task by sending an interrupt to its process.

  Attempts a `gen_statem` interrupt call first, falling back to
  `Process.exit(pid, :shutdown)` if the call fails.

  Returns `:ok` if the task was found and signaled, or `{:error, :not_found}`.
  """
  @spec stop_task(binary(), binary()) :: :ok | {:error, :not_found}
  defdelegate stop_task(session_id, task_id), to: :beam_agent_control

  @doc """
  List all tasks registered for a session.

  Returns `{:ok, tasks}` where each task map contains `:task_id`, `:session_id`,
  `:pid`, `:started_at` (millisecond timestamp), and `:status` (`:running` or
  `:stopped`).
  """
  @spec list_tasks(binary()) ::
          {:ok,
           [
             %{
               required(:task_id) => binary(),
               required(:session_id) => binary(),
               required(:pid) => pid(),
               required(:started_at) => integer(),
               required(:status) => :running | :stopped
             }
           ]}
  defdelegate list_tasks(session_id), to: :beam_agent_control

  @doc """
  Submit feedback for a session.

  Feedback entries are accumulated in submission order. Each entry is augmented
  with a `submitted_at` timestamp, `session_id`, and sequence number.
  """
  @spec submit_feedback(binary(), map()) :: :ok
  defdelegate submit_feedback(session_id, feedback), to: :beam_agent_control

  @doc """
  Get all feedback entries for a session, in submission order.
  """
  @spec get_feedback(binary()) :: {:ok, [map()]}
  defdelegate get_feedback(session_id), to: :beam_agent_control

  @doc """
  Clear all feedback entries for a session.
  """
  @spec clear_feedback(binary()) :: :ok
  defdelegate clear_feedback(session_id), to: :beam_agent_control

  @doc """
  Store a pending request from the agent.

  Called when the agent asks for user input or needs a response before it can
  continue. A `pending_request_stored` event is published on the session's event
  bus.
  """
  @spec store_pending_request(binary(), binary(), map()) :: :ok
  defdelegate store_pending_request(session_id, request_id, request), to: :beam_agent_control

  @doc """
  Resolve a pending request with a response.

  Marks the pending request as resolved and publishes a
  `pending_request_resolved` event.

  Returns `:ok`, `{:error, :not_found}`, or `{:error, :already_resolved}`.
  """
  @spec resolve_pending_request(binary(), binary(), map()) ::
          :ok | {:error, :not_found | :already_resolved}
  defdelegate resolve_pending_request(session_id, request_id, response),
    to: :beam_agent_control

  @doc """
  Get the response for a pending request.

  Returns `{:ok, response_map}` if resolved, `{:error, :pending}` if still
  awaiting a response, or `{:error, :not_found}` if no such request exists.
  """
  @spec get_pending_response(binary(), binary()) ::
          {:ok, map()} | {:error, :pending | :not_found}
  defdelegate get_pending_response(session_id, request_id), to: :beam_agent_control

  @doc """
  List all pending requests for a session, sorted oldest first.

  Each entry is a map with `:request_id`, `:session_id`, `:request`, `:status`,
  `:created_at`, and optionally `:response` and `:resolved_at`.
  """
  @spec list_pending_requests(binary()) ::
          {:ok,
           [
             %{
               required(:request_id) => binary(),
               required(:session_id) => binary(),
               required(:request) => map(),
               required(:status) => :pending | :resolved,
               optional(:response) => map(),
               required(:created_at) => integer(),
               optional(:resolved_at) => integer()
             }
           ]}
  defdelegate list_pending_requests(session_id), to: :beam_agent_control
end
