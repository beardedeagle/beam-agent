defmodule BeamAgent.Routines do
  @moduledoc """
  Canonical routines and scheduled execution for BeamAgent.

  `BeamAgent.Routines` manages durable job records for delayed or recurring
  work. It intentionally does not start a scheduler daemon inside BeamAgent.
  Instead, callers create jobs, inspect due work, and invoke `run_due/1` from
  a process they already own.

  Supported schedules:

  - one-shot (`type: :once`)
  - interval (`type: :interval`)

  Supported targets:

  - `:run` for canonical run creation without backend execution
  - `:query` for live-session or routed-session prompt execution
  """

  @type schedule() ::
          %{required(:type) => :once, required(:at) => integer()}
          | %{
              required(:type) => :interval,
              required(:every_ms) => pos_integer(),
              optional(:start_at) => integer(),
              optional(:catch_up) => boolean()
            }

  @type retry_policy() :: %{
          optional(:max_attempts) => pos_integer(),
          optional(:backoff_ms) => non_neg_integer()
        }

  @type session_target() ::
          %{required(:kind) => :live, required(:ref) => pid()}
          | %{required(:kind) => :routed, required(:opts) => map()}

  @type thread_target() ::
          %{required(:thread_id) => binary()}
          | %{required(:start) => map()}

  @type target() ::
          %{
            required(:type) => :run,
            optional(:scope) => binary() | map(),
            optional(:run_opts) => map()
          }
          | %{
              required(:type) => :query,
              required(:session) => session_target(),
              required(:prompt) => binary(),
              optional(:query_opts) => map(),
              optional(:thread) => thread_target(),
              optional(:stop_session) => boolean()
            }

  @type job_input() :: %{
          optional(:job_id) => binary(),
          required(:schedule) => schedule(),
          required(:target) => target(),
          optional(:payload) => term(),
          optional(:metadata) => map(),
          optional(:routing_policy) => map(),
          optional(:retry_policy) => retry_policy(),
          optional(:idempotency_key) => binary(),
          optional(:state) => :active | :paused,
          optional(:next_run_at) => integer()
        }

  @type job_patch() :: %{
          optional(:schedule) => schedule(),
          optional(:target) => target(),
          optional(:payload) => term(),
          optional(:metadata) => map(),
          optional(:routing_policy) => map(),
          optional(:retry_policy) => retry_policy(),
          optional(:idempotency_key) => binary(),
          optional(:state) => :active | :paused,
          optional(:next_run_at) => integer()
        }

  @type job_state() ::
          :active | :running | :retry_waiting | :paused | :completed | :exhausted | :cancelled

  @type job_record() :: %{
          required(:job_id) => binary(),
          required(:schedule) => schedule(),
          required(:target) => target(),
          required(:routing_policy) => map(),
          required(:retry_policy) => retry_policy(),
          required(:idempotency_key) => binary(),
          required(:state) => job_state(),
          required(:metadata) => map(),
          required(:attempt_count) => non_neg_integer(),
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          optional(:payload) => term(),
          optional(:next_run_at) => integer(),
          optional(:current_run_id) => binary(),
          optional(:current_slot_at) => integer(),
          optional(:last_run_id) => binary(),
          optional(:last_run_at) => integer(),
          optional(:last_result) => map(),
          optional(:last_error) => term(),
          optional(:cancelled_at) => integer(),
          optional(:completed_at) => integer()
        }

  @type job_filter() :: %{
          optional(:job_id) => binary(),
          optional(:state) => job_state(),
          optional(:schedule_type) => atom(),
          optional(:target_type) => atom(),
          optional(:due_before) => integer(),
          optional(:limit) => pos_integer()
        }

  @type due_filter() :: %{
          optional(:at) => integer(),
          optional(:limit) => pos_integer(),
          optional(:include_claimed) => boolean()
        }

  @type run_due_result() :: %{
          required(:job_id) => binary(),
          required(:run) => BeamAgent.Runs.run(),
          required(:slot_at) => integer()
        }

  @doc """
  Ensure the routines ETS tables exist.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_routines

  @doc """
  Clear all routines state.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_routines

  @doc """
  Create a routine job.
  """
  @spec create(job_input()) :: {:ok, job_record()} | {:error, term()}
  defdelegate create(job), to: :beam_agent_routines

  @doc """
  Update a routine job.
  """
  @spec update(binary(), job_patch()) :: {:ok, job_record()} | {:error, term()}
  defdelegate update(job_id, patch), to: :beam_agent_routines

  @doc """
  Cancel a routine job.
  """
  @spec cancel(binary()) :: :ok
  defdelegate cancel(job_id), to: :beam_agent_routines

  @doc """
  Execute a routine job immediately without changing its normal cadence.
  """
  @spec run_now(binary()) :: {:ok, BeamAgent.Runs.run()} | {:error, :not_found}
  defdelegate run_now(job_id), to: :beam_agent_routines

  @doc """
  Execute all currently due jobs using default runner options.
  """
  @spec run_due() :: {:ok, [run_due_result()]}
  defdelegate run_due(), to: :beam_agent_routines

  @doc """
  Execute currently due jobs from the calling process.
  """
  @spec run_due(map()) :: {:ok, [run_due_result()]}
  defdelegate run_due(opts), to: :beam_agent_routines

  @doc """
  Fetch a routine job by id.
  """
  @spec get(binary()) :: {:ok, job_record()} | {:error, :not_found}
  defdelegate get(job_id), to: :beam_agent_routines

  @doc """
  List all routine jobs.
  """
  @spec list() :: {:ok, [job_record()]}
  defdelegate list(), to: :beam_agent_routines

  @doc """
  List routine jobs with exact-match filters.
  """
  @spec list(job_filter()) :: {:ok, [job_record()]} | {:error, term()}
  defdelegate list(filter), to: :beam_agent_routines

  @doc """
  List jobs currently due as of now.
  """
  @spec list_due() :: {:ok, [job_record()]}
  defdelegate list_due(), to: :beam_agent_routines

  @doc """
  List jobs due according to an explicit due filter.
  """
  @spec list_due(due_filter()) :: {:ok, [job_record()]} | {:error, term()}
  defdelegate list_due(filter), to: :beam_agent_routines

  @doc """
  Return the earliest next-run timestamp in the routines due index.
  """
  @spec next_due_at() :: {:ok, integer()} | {:error, :none}
  defdelegate next_due_at(), to: :beam_agent_routines
end
