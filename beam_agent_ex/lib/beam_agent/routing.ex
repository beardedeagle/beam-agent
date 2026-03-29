defmodule BeamAgent.Routing do
  @moduledoc """
  Elixir facade for canonical BeamAgent backend routing.

  This module chooses a backend according to reusable routing policy instead of
  forcing callers to hard-code backend choice on every session start.

  Supported policies are `:explicit`, `:sticky`, `:round_robin`, `:failover`,
  `:capability_first`, and `:preferred_then_fallback`. Sticky affinity and
  round-robin cursors are stored as canonical BeamAgent state, but the module
  itself stays process-free.

  The module also acts as the primary session router — starting, stopping,
  querying, and managing unified sessions after resolving the backend via
  routing policy.
  """

  @typedoc """
  Routing policy name.

  Supported values are `:explicit`, `:sticky`, `:round_robin`, `:failover`,
  `:capability_first`, and `:preferred_then_fallback`.
  """
  @type route_policy :: :beam_agent_routing.route_policy()

  @typedoc """
  Fallback behavior after preferred candidates are exhausted.

  Supported values are `:none` and `:available`.
  """
  @type fallback_policy :: :beam_agent_routing.fallback_policy()

  @typedoc """
  Backend health override for routing.

  Supported values are `:healthy`, `:degraded`, `:unhealthy`, and `:down`.
  """
  @type health_status :: :beam_agent_routing.health_status()

  @typedoc """
  Routing request map.
  """
  @type route_request :: :beam_agent_routing.route_request()

  @typedoc """
  Routing decision map.
  """
  @type route_decision :: :beam_agent_routing.route_decision()

  # ---------------------------------------------------------------------------
  # Policy Routing
  # ---------------------------------------------------------------------------

  @doc """
  Ensure routing state tables exist. Idempotent.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_routing

  @doc """
  Clear sticky affinity and round-robin routing state.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_routing

  @doc """
  Select a backend using a normalized routing request.
  """
  @spec select_backend(route_request()) :: {:ok, route_decision()} | {:error, any()}
  defdelegate select_backend(route_request), to: :beam_agent_routing

  @doc """
  Select a backend after deriving defaults from a session identity or session opts.
  """
  @spec select_backend(pid() | binary() | map(), route_request()) ::
          {:ok, route_decision()} | {:error, any()}
  defdelegate select_backend(session_or_opts, route_request), to: :beam_agent_routing

  # ---------------------------------------------------------------------------
  # Session Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start a unified session after resolving explicit or policy-based backend routing.
  """
  @spec start_session(:beam_agent_core.session_opts()) :: {:ok, pid()} | {:error, any()}
  defdelegate start_session(opts), to: :beam_agent_routing

  @doc """
  Return a child spec for a unified session after resolving backend routing.
  """
  @spec child_spec(:beam_agent_core.session_opts()) :: :supervisor.child_spec()
  defdelegate child_spec(opts), to: :beam_agent_routing

  @doc """
  Stop a live unified session.
  """
  @spec stop(pid()) :: :ok
  defdelegate stop(session), to: :beam_agent_routing

  @doc """
  Send a blocking query with default params.
  """
  @spec query(pid(), binary()) :: {:ok, [:beam_agent.message()]} | {:error, any()}
  defdelegate query(session, prompt), to: :beam_agent_routing

  @doc """
  Send a blocking query through the canonical router.
  """
  @spec query(pid(), binary(), map()) :: {:ok, [:beam_agent.message()]} | {:error, any()}
  defdelegate query(session, prompt, params), to: :beam_agent_routing

  @doc """
  Send a query and return the live query reference.
  """
  @spec send_query(pid(), binary(), :beam_agent_core.query_opts(), timeout()) ::
          {:ok, reference()} | {:error, any()}
  defdelegate send_query(session, prompt, params, timeout), to: :beam_agent_routing

  @doc """
  Pull the next message from a live query.
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, :beam_agent.message()} | {:error, any()}
  defdelegate receive_message(session, ref, timeout), to: :beam_agent_routing

  @doc """
  Query session info for a live session.
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate session_info(session), to: :beam_agent_routing

  @doc """
  Return the health state for a live session.
  """
  @spec health(pid()) :: atom()
  defdelegate health(session), to: :beam_agent_routing

  @doc """
  Resolve the backend for a live session.
  """
  @spec backend(pid()) ::
          {:ok, :beam_agent_backend.backend()}
          | {:error, :beam_agent_backend.backend_lookup_error()}
  defdelegate backend(session), to: :beam_agent_routing

  @doc """
  Resolve the adapter facade module for a live session.
  """
  @spec adapter_module(pid()) ::
          {:ok, module()} | {:error, :beam_agent_backend.backend_lookup_error()}
  defdelegate adapter_module(session), to: :beam_agent_routing

  @doc """
  Change the model at runtime.
  """
  @spec set_model(pid(), binary()) :: {:ok, binary()} | {:error, any()}
  defdelegate set_model(session, model), to: :beam_agent_routing

  @doc """
  Change the permission mode at runtime.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, binary() | map()} | {:error, any()}
  defdelegate set_permission_mode(session, mode), to: :beam_agent_routing

  @doc """
  Interrupt active work on the session.
  """
  @spec interrupt(pid()) :: :ok | {:error, any()}
  defdelegate interrupt(session), to: :beam_agent_routing

  @doc """
  Abort active work on the session.
  """
  @spec abort(pid()) :: :ok | {:error, any()}
  defdelegate abort(session), to: :beam_agent_routing

  @doc """
  Send a control message through the appropriate native or shared path.
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate send_control(session, method, params), to: :beam_agent_routing

  # ---------------------------------------------------------------------------
  # Session Store
  # ---------------------------------------------------------------------------

  @doc """
  List all tracked sessions in the shared store.
  """
  @spec list_sessions() :: {:ok, [BeamAgent.SessionStore.session_meta()]}
  defdelegate list_sessions(), to: :beam_agent_routing

  @doc """
  List tracked sessions with filters.
  """
  @spec list_sessions(BeamAgent.SessionStore.list_opts()) ::
          {:ok, [BeamAgent.SessionStore.session_meta()]}
  defdelegate list_sessions(opts), to: :beam_agent_routing

  @doc """
  Get all visible messages for a session id.
  """
  @spec get_session_messages(binary()) ::
          {:ok, [:beam_agent.message()]} | {:error, :not_found}
  defdelegate get_session_messages(session_id), to: :beam_agent_routing

  @doc """
  Get visible messages for a session id with options.
  """
  @spec get_session_messages(binary(), BeamAgent.SessionStore.message_opts()) ::
          {:ok, [:beam_agent.message()]} | {:error, :not_found}
  defdelegate get_session_messages(session_id, opts), to: :beam_agent_routing

  @doc """
  Read shared session metadata by session id.
  """
  @spec get_session(binary()) ::
          {:ok, BeamAgent.SessionStore.session_meta()} | {:error, :not_found}
  defdelegate get_session(session_id), to: :beam_agent_routing

  @doc """
  Delete a tracked session from the shared store.
  """
  @spec delete_session(binary()) :: :ok
  defdelegate delete_session(session_id), to: :beam_agent_routing

  # ---------------------------------------------------------------------------
  # Session Mutation
  # ---------------------------------------------------------------------------

  @doc """
  Fork a live session.
  """
  @spec fork_session(pid(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate fork_session(session, opts), to: :beam_agent_routing

  @doc """
  Revert a live session.
  """
  @spec revert_session(pid(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate revert_session(session, selector), to: :beam_agent_routing

  @doc """
  Clear a session revert state.
  """
  @spec unrevert_session(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate unrevert_session(session), to: :beam_agent_routing

  @doc """
  Share a live session with default opts.
  """
  @spec share_session(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate share_session(session), to: :beam_agent_routing

  @doc """
  Share a live session.
  """
  @spec share_session(pid(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate share_session(session, opts), to: :beam_agent_routing

  @doc """
  Revoke sharing for a live session.
  """
  @spec unshare_session(pid()) :: :ok | {:error, any()}
  defdelegate unshare_session(session), to: :beam_agent_routing

  @doc """
  Summarize a live session with default opts.
  """
  @spec summarize_session(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate summarize_session(session), to: :beam_agent_routing

  @doc """
  Summarize a live session.
  """
  @spec summarize_session(pid(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate summarize_session(session, opts), to: :beam_agent_routing

  # ---------------------------------------------------------------------------
  # Thread Management
  # ---------------------------------------------------------------------------

  @doc """
  Start a thread for a live session.
  """
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_start(session, opts), to: :beam_agent_routing

  @doc """
  Resume a thread.
  """
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_resume(session, thread_id), to: :beam_agent_routing

  @doc """
  List threads for a live session.
  """
  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, any()}
  defdelegate thread_list(session), to: :beam_agent_routing

  @doc """
  Fork a thread with default opts.
  """
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_fork(session, thread_id), to: :beam_agent_routing

  @doc """
  Fork a thread.
  """
  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_fork(session, thread_id, opts), to: :beam_agent_routing

  @doc """
  Read a thread with default opts.
  """
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_read(session, thread_id), to: :beam_agent_routing

  @doc """
  Read a thread.
  """
  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_read(session, thread_id, opts), to: :beam_agent_routing

  @doc """
  Archive a thread.
  """
  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_archive(session, thread_id), to: :beam_agent_routing

  @doc """
  Unarchive a thread.
  """
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_unarchive(session, thread_id), to: :beam_agent_routing

  @doc """
  Rollback a thread.
  """
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, any()}
  defdelegate thread_rollback(session, thread_id, selector), to: :beam_agent_routing

  # ---------------------------------------------------------------------------
  # Metadata Accessors
  # ---------------------------------------------------------------------------

  @doc """
  List slash commands from session init data.
  """
  @spec supported_commands(pid()) :: {:ok, list()} | {:error, any()}
  defdelegate supported_commands(session), to: :beam_agent_routing

  @doc """
  List models from session init data.
  """
  @spec supported_models(pid()) :: {:ok, list()} | {:error, any()}
  defdelegate supported_models(session), to: :beam_agent_routing

  @doc """
  List agents from session init data.
  """
  @spec supported_agents(pid()) :: {:ok, list()} | {:error, any()}
  defdelegate supported_agents(session), to: :beam_agent_routing

  @doc """
  Get account info from session init data.
  """
  @spec account_info(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate account_info(session), to: :beam_agent_routing

  @doc """
  Return high-level server health details when a backend exposes them.
  """
  @spec server_health(pid()) :: {:ok, map()} | {:error, any()}
  defdelegate server_health(session), to: :beam_agent_routing
end
