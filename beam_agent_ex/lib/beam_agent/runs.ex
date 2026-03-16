defmodule BeamAgent.Runs do
  @moduledoc """
  Canonical run and step lifecycle for BeamAgent.

  `BeamAgent.Runs` provides durable units of work that sit above transient task
  pids. A run can be scoped to a session, a thread, and an optional parent run.
  A step belongs to a run and inherits its session/thread scope.

  This is the Elixir facade over the Erlang `:beam_agent_runs` public module.
  The underlying implementation is ETS-backed through `:beam_agent_runs_core`
  and `:beam_agent_runs_store`, so the API works uniformly across all BeamAgent
  backends.

  ## Quick example

  ```elixir
  {:ok, run} =
    BeamAgent.Runs.start_run(%{session_id: "sess_001", thread_id: "thread_abc"}, %{
      kind: :workflow,
      input: %{goal: "Ship the feature"}
    })

  {:ok, step} = BeamAgent.Runs.start_step(run.run_id, %{kind: :review})
  {:ok, _step} = BeamAgent.Runs.complete_step(run.run_id, step.step_id, %{status: :ok})
  {:ok, _run} = BeamAgent.Runs.complete_run(run.run_id, %{summary: "Done"})
  ```

  ## Core concepts

  - **Run scope**: runs can reference `:session_id`, `:thread_id`, and
    `:parent_run_id`. Child runs inherit parent scope unless the caller
    provides the same explicit values.

  - **Step inheritance**: every step inherits its parent run's session/thread
    scope and is keyed by `{run_id, step_id}`.

  - **Terminal safety**: runs cannot complete while they still have active
    steps. Failing or cancelling a run cascades terminal state to active steps.
  """

  @typedoc """
  Run status atom.

  Values: `:running`, `:completed`, `:failed`, `:cancelled`.
  """
  @type run_status() :: :running | :completed | :failed | :cancelled

  @typedoc """
  Step status atom.

  Values: `:running`, `:completed`, `:failed`, `:cancelled`.
  """
  @type step_status() :: :running | :completed | :failed | :cancelled

  @typedoc """
  Run scope passed to `start_run/2`.

  Use either a binary session id or a map containing any of
  `:session_id`, `:thread_id`, and `:parent_run_id`.
  """
  @type scope() ::
          binary()
          | %{
              optional(:session_id) => binary(),
              optional(:thread_id) => binary(),
              optional(:parent_run_id) => binary()
            }

  @typedoc """
  Options for `start_run/2`.

  Supported keys:
  - `:run_id` — explicit run identifier
  - `:kind` — atom or binary classifier for the run
  - `:input` — arbitrary input payload
  - `:metadata` — arbitrary metadata map
  """
  @type run_opts() :: %{
          optional(:run_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:input) => term(),
          optional(:metadata) => map()
        }

  @typedoc """
  Options for `start_step/2`.

  Supported keys:
  - `:step_id` — explicit step identifier
  - `:kind` — atom or binary classifier for the step
  - `:input` — arbitrary input payload
  - `:metadata` — arbitrary metadata map
  """
  @type step_opts() :: %{
          optional(:step_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:input) => term(),
          optional(:metadata) => map()
        }

  @typedoc """
  Filter map accepted by `list_runs/1`.

  Supported keys:
  - `:session_id`
  - `:thread_id`
  - `:parent_run_id`
  - `:kind`
  - `:status`
  - `:since`
  - `:limit`
  """
  @type run_filter() :: %{
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:parent_run_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:status) => run_status(),
          optional(:since) => integer(),
          optional(:limit) => pos_integer()
        }

  @typedoc """
  Run record.
  """
  @type run() :: %{
          required(:run_id) => binary(),
          required(:kind) => atom() | binary(),
          required(:status) => run_status(),
          required(:metadata) => map(),
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:parent_run_id) => binary(),
          optional(:input) => term(),
          optional(:output) => term(),
          optional(:error) => term(),
          optional(:cancel_reason) => term(),
          optional(:completed_at) => integer()
        }

  @typedoc """
  Step record.
  """
  @type step() :: %{
          required(:step_id) => binary(),
          required(:run_id) => binary(),
          required(:kind) => atom() | binary(),
          required(:status) => step_status(),
          required(:metadata) => map(),
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:input) => term(),
          optional(:output) => term(),
          optional(:error) => term(),
          optional(:cancel_reason) => term(),
          optional(:completed_at) => integer()
        }

  @doc """
  Ensure the runs ETS tables exist.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_runs

  @doc """
  Clear all run and step data.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_runs

  @doc """
  Start a run with the given scope and options.
  """
  @spec start_run(scope(), run_opts()) :: {:ok, run()} | {:error, term()}
  defdelegate start_run(scope, opts), to: :beam_agent_runs

  @doc """
  Get a run by id.
  """
  @spec get_run(binary()) :: {:ok, run()} | {:error, :not_found}
  defdelegate get_run(run_id), to: :beam_agent_runs

  @doc """
  List all runs without filters.
  """
  @spec list_runs() :: {:ok, [run()]}
  defdelegate list_runs(), to: :beam_agent_runs

  @doc """
  List runs with exact-match filters.
  """
  @spec list_runs(run_filter()) :: {:ok, [run()]} | {:error, term()}
  defdelegate list_runs(filter), to: :beam_agent_runs

  @doc """
  Complete a run once all of its steps are terminal.
  """
  @spec complete_run(binary(), term()) :: {:ok, run()} | {:error, term()}
  defdelegate complete_run(run_id, result), to: :beam_agent_runs

  @doc """
  Fail a run and cascade failure to active steps.
  """
  @spec fail_run(binary(), term()) :: {:ok, run()} | {:error, term()}
  defdelegate fail_run(run_id, error_term), to: :beam_agent_runs

  @doc """
  Cancel a run and cascade cancellation to active steps.
  """
  @spec cancel_run(binary(), term()) :: {:ok, run()} | {:error, term()}
  defdelegate cancel_run(run_id, reason), to: :beam_agent_runs

  @doc """
  Start a step within a run.
  """
  @spec start_step(binary(), step_opts()) :: {:ok, step()} | {:error, term()}
  defdelegate start_step(run_id, opts), to: :beam_agent_runs

  @doc """
  Get a step by run id and step id.
  """
  @spec get_step(binary(), binary()) :: {:ok, step()} | {:error, :not_found}
  defdelegate get_step(run_id, step_id), to: :beam_agent_runs

  @doc """
  List steps for a run, oldest first.
  """
  @spec list_steps(binary()) :: {:ok, [step()]} | {:error, :not_found}
  defdelegate list_steps(run_id), to: :beam_agent_runs

  @doc """
  Complete a running step.
  """
  @spec complete_step(binary(), binary(), term()) :: {:ok, step()} | {:error, term()}
  defdelegate complete_step(run_id, step_id, result), to: :beam_agent_runs

  @doc """
  Fail a running step.
  """
  @spec fail_step(binary(), binary(), term()) :: {:ok, step()} | {:error, term()}
  defdelegate fail_step(run_id, step_id, error_term), to: :beam_agent_runs

  @doc """
  Cancel a running step.
  """
  @spec cancel_step(binary(), binary(), term()) :: {:ok, step()} | {:error, term()}
  defdelegate cancel_step(run_id, step_id, reason), to: :beam_agent_runs
end
