defmodule BeamAgent.Artifacts do
  @moduledoc """
  Canonical artifact and context store for BeamAgent.

  Artifacts are durable runtime outputs such as plans, diffs, reviews,
  summaries, approval packets, benchmark reports, and transcript snapshots.
  They are stored independently of live session processes and can be linked to
  sessions, threads, runs, and other typed references.

  This is the Elixir facade over the Erlang `:beam_agent_artifacts` public
  module. The implementation is ETS-backed and process-free, following the same
  BeamAgent pattern used by the runs and control stores.
  """

  @typedoc """
  Scope passed to `put/2`.

  Use either a binary session id or a map containing any of `:session_id`,
  `:thread_id`, and `:run_id`.
  """
  @type scope() ::
          binary()
          | %{
              optional(:session_id) => binary(),
              optional(:thread_id) => binary(),
              optional(:run_id) => binary()
            }

  @typedoc """
  Source reference stored on an artifact.
  """
  @type source_ref() :: %{
          required(:type) => atom() | binary(),
          required(:id) => binary(),
          optional(:metadata) => map()
        }

  @typedoc """
  Input map accepted by `put/1,2`.
  """
  @type artifact_input() :: %{
          optional(:artifact_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:title) => binary(),
          optional(:body) => term(),
          optional(:format) => atom() | binary(),
          optional(:source_refs) => [source_ref()],
          optional(:metadata) => map(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary()
        }

  @typedoc """
  Exact-match filter accepted by `list/1` and `search/2`.
  """
  @type artifact_filter() :: %{
          optional(:artifact_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:format) => atom() | binary(),
          optional(:title) => binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary(),
          optional(:source_ref_type) => atom() | binary(),
          optional(:source_ref_id) => binary(),
          optional(:limit) => pos_integer(),
          optional(:since) => integer()
        }

  @typedoc """
  Canonical artifact record.
  """
  @type artifact() :: %{
          required(:artifact_id) => binary(),
          required(:kind) => atom() | binary(),
          required(:title) => binary(),
          required(:body) => term(),
          required(:format) => atom() | binary(),
          required(:source_refs) => [source_ref()],
          required(:metadata) => map(),
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary()
        }

  @doc """
  Ensure the artifacts ETS table exists.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_artifacts

  @doc """
  Clear all artifacts.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_artifacts

  @doc """
  Insert or update an artifact using embedded scope.
  """
  @spec put(artifact_input()) :: {:ok, artifact()} | {:error, term()}
  defdelegate put(artifact), to: :beam_agent_artifacts

  @doc """
  Insert or update an artifact with explicit scope.
  """
  @spec put(scope(), artifact_input()) :: {:ok, artifact()} | {:error, term()}
  defdelegate put(scope, artifact), to: :beam_agent_artifacts

  @doc """
  Fetch an artifact by id.
  """
  @spec get(binary()) :: {:ok, artifact()} | {:error, :not_found}
  defdelegate get(artifact_id), to: :beam_agent_artifacts

  @doc """
  List all artifacts without filters.
  """
  @spec list() :: {:ok, [artifact()]}
  defdelegate list(), to: :beam_agent_artifacts

  @doc """
  List artifacts with exact-match filters.
  """
  @spec list(artifact_filter()) :: {:ok, [artifact()]} | {:error, term()}
  defdelegate list(filter), to: :beam_agent_artifacts

  @doc """
  Search artifacts with a case-insensitive tokenized query.
  """
  @spec search(binary()) :: {:ok, [artifact()]}
  defdelegate search(query), to: :beam_agent_artifacts

  @doc """
  Search artifacts with a query plus exact-match filters.
  """
  @spec search(binary(), artifact_filter()) :: {:ok, [artifact()]} | {:error, term()}
  defdelegate search(query, filter), to: :beam_agent_artifacts

  @doc """
  Attach a typed source reference to an existing artifact.
  """
  @spec attach(binary(), atom() | binary(), binary()) ::
          :ok
          | {:error,
             :inconsistent_run_scope
             | :inconsistent_scope
             | :not_found
             | :run_not_found
             | :session_id_required_for_thread}
  defdelegate attach(artifact_id, ref_type, ref_id), to: :beam_agent_artifacts

  @doc """
  Delete an artifact by id.
  """
  @spec delete(binary()) :: :ok | {:error, :not_found}
  defdelegate delete(artifact_id), to: :beam_agent_artifacts
end
