defmodule BeamAgent.Orchestrator do
  @moduledoc """
  Canonical BeamAgent orchestration primitives.

  `BeamAgent.Orchestrator` exposes process-free parent-child execution
  mechanics over canonical runs, sessions, threads, and the durable journal.
  It does not start a worker pool or scheduler inside BeamAgent.

  Child execution truth still lives in `BeamAgent.Runs`. The orchestrator layer
  adds explicit cross-session lineage and convenience APIs for delegation,
  collection, and cancellation.
  """

  @type parent() :: binary() | BeamAgent.Runs.run()

  @type session_target() ::
          :inherit
          | :none
          | binary()
          | pid()
          | %{
              required(:kind) => :live,
              required(:ref) => pid(),
              optional(:stop_session) => boolean()
            }
          | %{required(:kind) => :session_id, required(:id) => binary()}
          | %{
              required(:kind) => :routed,
              required(:opts) => map(),
              optional(:stop_session) => boolean()
            }

  @type thread_target() ::
          :inherit
          | :none
          | binary()
          | %{required(:thread_id) => binary()}
          | %{required(:start) => map()}

  @type spawn_opts() :: %{
          optional(:run_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:input) => term(),
          optional(:metadata) => map(),
          optional(:session) => session_target(),
          optional(:thread) => thread_target()
        }

  @type child() :: %{
          required(:relation) => :spawned | :delegated,
          required(:substrate) => :run | :session | :thread | :session_thread,
          required(:parent_run_id) => binary(),
          required(:run) => BeamAgent.Runs.run(),
          required(:metadata) => map(),
          optional(:task) => term(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:session_ref) => pid(),
          optional(:owns_session) => boolean(),
          optional(:stop_session) => boolean(),
          optional(:thread) => map()
        }

  @type child_status() :: %{
          required(:run) => BeamAgent.Runs.run(),
          required(:step_count) => non_neg_integer(),
          required(:active_step_count) => non_neg_integer(),
          required(:child_count) => non_neg_integer(),
          required(:active_child_count) => non_neg_integer(),
          required(:awaitable) => boolean(),
          optional(:relation) => :spawned | :delegated,
          optional(:parent_run_id) => binary(),
          optional(:substrate) => :run | :session | :thread | :session_thread,
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:metadata) => map(),
          optional(:task) => term()
        }

  @type collect_opts() :: %{
          optional(:include_steps) => boolean(),
          optional(:include_journal) => boolean(),
          optional(:include_descendants) => boolean()
        }

  @type collect_result() :: %{
          required(:run) => BeamAgent.Runs.run(),
          required(:children) => [child()],
          optional(:descendants) => [child()],
          optional(:steps) => [BeamAgent.Runs.step()],
          optional(:journal) => [BeamAgent.Journal.entry()],
          optional(:link) => map()
        }

  @type await_result() :: %{
          required(:status) => :completed | :failed | :cancelled,
          required(:run) => BeamAgent.Runs.run(),
          optional(:output) => term(),
          optional(:error) => term(),
          optional(:cancel_reason) => term()
        }

  @doc """
  Ensure the orchestrator ETS tables exist.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_orchestrator

  @doc """
  Clear all orchestrator lineage state.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_orchestrator

  @doc """
  Create a child orchestration record, optionally opening a child session or thread substrate.
  """
  @spec spawn(parent(), spawn_opts()) :: {:ok, child()} | {:error, term()}
  defdelegate spawn(parent, opts), to: :beam_agent_orchestrator

  @doc """
  Create a delegated child run under a parent run.
  """
  @spec delegate(parent(), term(), map()) :: {:ok, BeamAgent.Runs.run()} | {:error, term()}
  defdelegate delegate(parent, task, opts), to: :beam_agent_orchestrator

  @doc """
  Wait for a run to reach a terminal state by polling the canonical run store.
  """
  @spec await(binary(), non_neg_integer()) ::
          {:ok, await_result()} | {:error, :timeout | :not_found | term()}
  defdelegate await(run_id, timeout), to: :beam_agent_orchestrator

  @doc """
  Collect the canonical orchestration view for a run.
  """
  @spec collect(binary(), collect_opts()) :: {:ok, collect_result()} | {:error, term()}
  defdelegate collect(run_id, opts), to: :beam_agent_orchestrator

  @doc """
  Cancel a run and any active orchestrated descendants.
  """
  @spec cancel(binary(), term()) :: :ok | {:error, term()}
  defdelegate cancel(run_id, reason), to: :beam_agent_orchestrator

  @doc """
  Return a summary status map for a run and its direct children.
  """
  @spec status(binary()) :: {:ok, child_status()} | {:error, :not_found}
  defdelegate status(run_id), to: :beam_agent_orchestrator

  @doc """
  List direct orchestrator children for a parent run.
  """
  @spec list_children(parent()) ::
          {:ok, [child()]} | {:error, :parent_not_found | {:invalid_parent, binary()}}
  defdelegate list_children(parent), to: :beam_agent_orchestrator
end
