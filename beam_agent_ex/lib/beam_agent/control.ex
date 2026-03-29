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
    dispatch protocol. Each registered task also creates a linked
    `BeamAgent.Runs` record so task history survives after the live task entry
    is removed.

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
  `feedback`, `callbacks`, and `pending`. Task registration is bridged into
  `BeamAgent.Runs`, so the live task table can stay ephemeral while durable run
  history remains queryable.

  See also: `BeamAgent.Runtime`, `BeamAgent.Catalog`, `BeamAgent`.
  """

  @doc """
  Ensure all control ETS tables exist.

  Creates the config, tasks, feedback, callbacks, and pending tables if they do
  not already exist. Idempotent and safe to call from any process.

  Returns `:ok`.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_control

  @doc """
  Clear all control state across every session.

  Deletes all objects from every control ETS table. Use this for test cleanup
  or node-wide reset. Individual session cleanup should use `clear_config/1`,
  `clear_feedback/1`, and `clear_session_callbacks/1` instead.

  Returns `:ok`.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_control

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
          {:ok, %{optional(:model) => atom() | binary() | map(), optional(:permission_mode) => atom() | binary()}}
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
  @spec get_config(binary(), atom()) :: {:ok, atom() | binary() | map() | pos_integer()} | {:error, :not_set}
  defdelegate get_config(session_id, key), to: :beam_agent_control

  @doc """
  Set a configuration value for a session.

  Stores an arbitrary term under the given atom key, scoped to the session ID.
  Overwrites any previous value for the same key.
  """
  @spec set_config(binary(), atom(), atom() | binary() | map()) :: :ok
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

  Each registered task also creates a linked canonical run. `list_tasks/1`
  exposes that linkage through the optional `:run_id` field.

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
  Stopping a task also cancels its linked run in `BeamAgent.Runs`.
  """
  @spec stop_task(binary(), binary()) :: :ok | {:error, :not_found}
  defdelegate stop_task(session_id, task_id), to: :beam_agent_control

  @doc """
  List all tasks registered for a session.

  Returns `{:ok, tasks}` where each task map contains `:task_id`, `:session_id`,
  `:pid`, `:started_at` (millisecond timestamp), `:status` (`:running` or
  `:stopped`), and an optional `:run_id`. Stopped tasks also carry
  `:stopped_at`.
  """
  @spec list_tasks(binary()) :: {:ok, [:beam_agent_control_core.task_meta()]}
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
  Register callback handlers for a session.

  The `opts` map may contain:
  - `:permission_handler` — `fun(method, params, context)` returning a
    permission result tuple
  - `:permission_default` — `:allow` or `:deny` (default `:deny`)
  - `:approval_handler` — `fun(method, params, context)` returning
    `:accept`, `:accept_for_session`, `:decline`, or `:cancel`
  - `:user_input_handler` — `fun(request, context)` returning
    `{:ok, response}` or any term

  Returns `:ok`.
  """
  @spec register_session_callbacks(binary(), map()) :: :ok
  defdelegate register_session_callbacks(session_id, opts), to: :beam_agent_control

  @doc """
  Clear all callback handlers for a session.

  Removes every registered callback handler stored for `session_id`. After
  this call, the session operates as if no callbacks were ever registered; the
  `permission_default` reverts to `:deny`.

  Returns `:ok`.
  """
  @spec clear_session_callbacks(binary()) :: :ok
  defdelegate clear_session_callbacks(session_id), to: :beam_agent_control

  @doc """
  Request permission through the session's callback broker.

  Invokes the registered `permission_handler` (or falls back to the
  `approval_handler` adapted to permission semantics, or the
  `permission_default`). The handler is called safely — exceptions are caught
  and the default is returned.

  Returns a permission result:
  - `{:allow, params}` — permission granted
  - `{:allow, params, override_default}` — granted, with updated session default
  - `{:deny, reason}` — permission denied
  - `{:deny, reason, cancelled}` — denied, with cancellation flag
  """
  @spec request_permission(binary(), binary(), map(), map()) ::
          :beam_agent_core.permission_result()
  defdelegate request_permission(session_id, method, params, context),
    to: :beam_agent_control

  @doc """
  Request an approval decision through the session's callback broker.

  Invokes the registered `approval_handler` (or adapts the
  `permission_handler` to approval semantics).

  Returns `:accept`, `:accept_for_session`, `:decline`, or `:cancel`.
  """
  @spec request_approval(binary(), binary(), map(), map()) ::
          :accept | :accept_for_session | :decline | :cancel
  defdelegate request_approval(session_id, method, params, context),
    to: :beam_agent_control

  @doc """
  Request user input through the session's callback broker.

  Stores a pending request, then invokes the registered `user_input_handler`
  if one exists. If the handler responds, the pending request is resolved
  immediately. If no handler is registered or the handler fails, the request
  remains pending for external resolution via `resolve_pending_request/3`.

  Returns `{:ok, response}` when the handler responds, or `{:ok, pending_info}`
  when the request is awaiting external resolution.
  """
  @spec request_user_input(binary(), map(), map()) :: {:ok, map()}
  defdelegate request_user_input(session_id, request, context), to: :beam_agent_control

  @doc """
  Clear all universal collaboration state (review and realtime sessions).

  Returns `:ok`.
  """
  @spec clear_collaboration() :: :ok
  defdelegate clear_collaboration(), to: :beam_agent_control

  @doc """
  Start a universal realtime session for a thread (storage layer).

  Use `thread_realtime_start/2` for the session-pid-based API with native
  backend routing. This function operates directly on a `session_id` binary and
  stores the realtime session in ETS via the universal collaboration layer.

  Returns `{:ok, realtime_session}`.
  """
  @spec start_realtime(binary(), map()) ::
          {:ok,
           %{
             required(:backend) => any(),
             required(:event_count) => 1,
             required(:input_summary) => %{required(:audio_chunks) => 0, required(:text_chunks) => 0},
             required(:inputs) => [],
             required(:mode) => any(),
             required(:output_events) => [map(), ...],
             required(:params) => map(),
             required(:realtime_id) => binary(),
             required(:session_id) => binary(),
             required(:source) => :universal,
             required(:started_at) => integer(),
             required(:status) => :active,
             required(:thread_id) => binary(),
             required(:transport) => any(),
             required(:transport_metadata) => map(),
             required(:updated_at) => integer(),
             required(:voice_enabled) => boolean()
           }}
  defdelegate start_realtime(session_id, params), to: :beam_agent_control

  @doc """
  Append text to an active realtime session (storage layer).

  Use `thread_realtime_append_text/3` for the session-pid-based API. This
  function operates directly on a `session_id` binary.

  Returns `{:ok, result}`.
  """
  @spec append_realtime_text(binary(), binary(), map()) :: {:ok, map()}
  defdelegate append_realtime_text(session_id, thread_id, params), to: :beam_agent_control

  @doc """
  Append audio to an active realtime session (storage layer).

  Use `thread_realtime_append_audio/3` for the session-pid-based API. This
  function operates directly on a `session_id` binary.

  Returns `{:ok, result}`.
  """
  @spec append_realtime_audio(binary(), binary(), map()) :: {:ok, map()}
  defdelegate append_realtime_audio(session_id, thread_id, params), to: :beam_agent_control

  @doc """
  Stop and tear down an active realtime session (storage layer).

  Use `thread_realtime_stop/2` for the session-pid-based API. This function
  operates directly on a `session_id` binary.

  Returns `{:ok, result}`.
  """
  @spec stop_realtime(binary(), binary()) :: {:ok, map()}
  defdelegate stop_realtime(session_id, thread_id), to: :beam_agent_control

  @doc """
  List canonical collaboration modes (storage layer).

  Use `collaboration_mode_list/1` for the session-pid-based API with native
  backend routing. This function operates directly on a `session_id` binary
  and returns only the universal collaboration modes.

  Returns `{:ok, %{session_id: binary(), source: :universal, modes: [map()]}}`.
  """
  @spec collaboration_modes(binary()) ::
          {:ok,
           %{
             required(:modes) => [map(), ...],
             required(:session_id) => binary(),
             required(:source) => :universal
           }}
  defdelegate collaboration_modes(session_id), to: :beam_agent_control

  @doc """
  List universal experimental features (storage layer).

  Use `experimental_feature_list/1` or `experimental_feature_list/2` for the
  session-pid-based API with native backend routing. This function operates
  directly on a `session_id` binary and returns only the universal feature set.

  Returns `{:ok, %{session_id: binary(), source: :universal, features: [map()]}}`.
  """
  @spec experimental_features(binary(), map()) ::
          {:ok,
           %{
             required(:features) => [map(), ...],
             required(:session_id) => binary(),
             required(:source) => :universal
           }}
  defdelegate experimental_features(session_id, opts), to: :beam_agent_control

  @doc """
  Start a universal code review session (storage layer).

  Use `review_start/2` for the session-pid-based API with native backend
  routing. This function operates directly on a `session_id` binary and stores
  the review session in ETS via the universal collaboration layer.

  `params` may include `:files`, `:diff`, `:review_type`, `:mode`, `:target`,
  `:participants`, `:comments`, `:issues`, and `:resolutions`.

  Returns `{:ok, review_session}`.
  """
  @spec start_review(binary(), map()) ::
          {:ok,
           %{
             required(:backend) => any(),
             required(:comments) => [map()],
             required(:created_at) => integer(),
             required(:issues) => [map()],
             required(:mode) => any(),
             required(:params) => map(),
             required(:participants) => [map()],
             required(:resolutions) => [map()],
             required(:review_id) => binary(),
             required(:review_metrics) => %{
               required(:comment_count) => non_neg_integer(),
               required(:issue_count) => non_neg_integer(),
               required(:participant_count) => non_neg_integer(),
               required(:resolution_count) => non_neg_integer()
             },
             required(:session_id) => binary(),
             required(:source) => any(),
             required(:stage) => any(),
             required(:stage_history) => [map(), ...],
             required(:status) => :active,
             required(:target) => any(),
             required(:thread_id) => binary(),
             required(:updated_at) => integer()
           }}
  defdelegate start_review(session_id, params), to: :beam_agent_control

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
  `:created_at`, and optionally `:response` and `:resolved_at`. Sensitive fields
  inside request/response payloads are redacted for display-safe reads.
  """
  @spec list_pending_requests(binary()) ::
          {:ok, [:beam_agent_control_core.pending_request()]}
  defdelegate list_pending_requests(session_id), to: :beam_agent_control

  # ---------------------------------------------------------------------------
  # Session-scoped control operations (realtime, review, server management)
  # ---------------------------------------------------------------------------

  @doc """
  Steer an active turn by injecting additional input mid-conversation.

  Allows you to redirect or refine the agent's current turn within a thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary identifier of the active turn.
  - `input` -- steering input (binary prompt or list of content block maps).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec turn_steer(pid(), binary(), binary(), binary() | [map()]) ::
          {:ok, map()} | {:error, term()}
  defdelegate turn_steer(session, thread_id, turn_id, input), to: :beam_agent_control

  @doc """
  Steer an active turn with additional options.

  Same as `turn_steer/4` but accepts backend-specific options such as
  `:model` or `:system_prompt` overrides for the steered response.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary turn identifier.
  - `input` -- steering input.
  - `opts` -- backend-specific options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec turn_steer(pid(), binary(), binary(), binary() | [map()], map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate turn_steer(session, thread_id, turn_id, input, opts), to: :beam_agent_control

  @doc """
  Interrupt an active turn in a thread.

  Cancels the agent's in-progress response for the specified turn.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary turn identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec turn_interrupt(pid() | binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate turn_interrupt(session, thread_id, turn_id), to: :beam_agent_control

  @doc """
  Start a realtime thread for audio/text streaming.

  Initiates a WebSocket or streaming connection for real-time interactions.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- realtime session options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec thread_realtime_start(pid() | binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_realtime_start(session, opts), to: :beam_agent_control

  @doc """
  Append audio data to an active realtime thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- audio data options (contains encoded audio bytes).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec thread_realtime_append_audio(pid() | binary(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_realtime_append_audio(session, thread_id, opts), to: :beam_agent_control

  @doc """
  Append text data to an active realtime thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- text data options (contains the text to append).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec thread_realtime_append_text(pid() | binary(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_realtime_append_text(session, thread_id, opts), to: :beam_agent_control

  @doc """
  Stop an active realtime thread.

  Closes the streaming connection and finalizes the realtime session.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec thread_realtime_stop(pid() | binary(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_realtime_stop(session, thread_id), to: :beam_agent_control

  @doc """
  Start a code review session.

  Initialises a review workflow where the agent reviews code changes.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- review options map (e.g., `:diff`, `:branch`, `:files`).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec review_start(pid() | binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate review_start(session, opts), to: :beam_agent_control

  @doc """
  List available collaboration modes.

  Returns the modes supported by the backend (e.g., pair programming,
  review, teaching).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, modes}` or `{:error, reason}`.
  """
  @spec collaboration_mode_list(pid() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate collaboration_mode_list(session), to: :beam_agent_control

  @doc """
  List available experimental features.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, features}` or `{:error, reason}`.
  """
  @spec experimental_feature_list(pid() | binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate experimental_feature_list(session), to: :beam_agent_control

  @doc """
  List experimental features with filter options.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map.

  ## Returns

  - `{:ok, features}` or `{:error, reason}`.
  """
  @spec experimental_feature_list(pid() | binary(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate experimental_feature_list(session, opts), to: :beam_agent_control

  @doc """
  List all persisted sessions known to the backend server.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  @spec list_server_sessions(pid() | binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_server_sessions(session), to: :beam_agent_control

  @doc """
  Retrieve a single persisted session by its identifier.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, session_map}` or `{:error, :not_found}`.
  """
  @spec get_server_session(pid() | binary(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate get_server_session(session, session_id), to: :beam_agent_control

  @doc """
  Delete a persisted session from the backend server.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier to delete.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec delete_server_session(pid() | binary(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate delete_server_session(session, session_id), to: :beam_agent_control

  @doc """
  List all sub-agents registered on the backend server.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agents}` or `{:error, reason}`.
  """
  @spec list_server_agents(pid() | binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_server_agents(session), to: :beam_agent_control

  @doc """
  Check the health of the backend server.

  Returns a status map with health indicators including the backend name,
  session identifier, and uptime in milliseconds.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, health_map}` or `{:error, reason}`.
  """
  @spec server_health(pid() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate server_health(session), to: :beam_agent_control
end
