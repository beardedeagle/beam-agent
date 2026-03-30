defmodule BeamAgent.Journal do
  @moduledoc """
  Durable event journal for BeamAgent.

  `BeamAgent.Journal` stores replayable canonical domain events such as run and
  step lifecycle transitions, artifact changes, and control mutations. It is
  distinct from the live event stream:

  - `BeamAgent.event_subscribe/1` streams transient session activity
  - `BeamAgent.Journal` persists append-only BeamAgent domain events for replay

  This is the Elixir facade over the Erlang `:beam_agent_journal` public
  module. The implementation is ETS-backed and process-free.
  """

  @typedoc """
  Journal event type identifier.
  """
  @type event_type() :: atom() | binary()

  @typedoc """
  Journal tag value.
  """
  @type tag() :: atom() | binary()

  @typedoc """
  Envelope passed to `append/2`.
  """
  @type event_input() :: %{
          optional(:event_id) => binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary(),
          optional(:timestamp) => integer(),
          optional(:tags) => [tag()],
          optional(:payload) => map()
        }

  @typedoc """
  Exact-match filter accepted by `list/1` and `stream_from/2`.
  """
  @type event_filter() :: %{
          optional(:event_id) => binary(),
          optional(:event_type) => event_type(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary(),
          optional(:tag) => tag(),
          optional(:since) => integer(),
          optional(:limit) => pos_integer()
        }

  @typedoc """
  Canonical journal entry.
  """
  @type entry() :: %{
          required(:event_id) => binary(),
          required(:event_type) => event_type(),
          required(:sequence) => pos_integer(),
          required(:timestamp) => integer(),
          required(:payload) => map(),
          required(:tags) => [tag()],
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary()
        }

  @typedoc "Error returned when appending an invalid or inconsistent journal event."
  @type append_error() ::
          :already_exists
          | :session_id_required_for_thread
          | {:invalid_event,
             :event_id | :payload | :run_id | :session_id | :tags | :thread_id | :timestamp}
          | {:invalid_event_type, binary()}

  @doc """
  Ensure the journal ETS tables exist.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_journal

  @doc """
  Clear all journal events and acknowledgements.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_journal

  @doc """
  Append a normalized BeamAgent domain event to the durable journal.
  """
  @spec append(event_type(), event_input()) :: {:ok, entry()} | {:error, append_error()}
  defdelegate append(event_type, event), to: :beam_agent_journal

  @doc """
  List all journal entries, oldest first.
  """
  @spec list() :: {:ok, [entry()]}
  defdelegate list(), to: :beam_agent_journal

  @doc """
  List journal entries with exact-match filters.
  """
  @spec list(event_filter()) :: {:ok, [entry()]} | {:error, term()}
  defdelegate list(filter), to: :beam_agent_journal

  @doc """
  Replay journal entries after the given cursor.
  """
  @spec stream_from(non_neg_integer()) :: {:ok, [entry()]} | {:error, term()}
  defdelegate stream_from(cursor), to: :beam_agent_journal

  @doc """
  Replay journal entries after the given cursor with additional filters.
  """
  @spec stream_from(non_neg_integer(), event_filter()) :: {:ok, [entry()]} | {:error, term()}
  defdelegate stream_from(cursor, filter), to: :beam_agent_journal

  @doc """
  Fetch a journal entry by id.
  """
  @spec get(binary()) :: {:ok, entry()} | {:error, :not_found}
  defdelegate get(event_id), to: :beam_agent_journal

  @doc """
  Acknowledge a journal entry for a consumer id.
  """
  @spec ack(binary(), binary()) :: :ok | {:error, :not_found}
  defdelegate ack(consumer_id, event_id), to: :beam_agent_journal

  @doc """
  Fetch an ack record for a consumer and event.
  """
  @spec get_ack(binary(), binary()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_ack(consumer_id, event_id), to: :beam_agent_journal

  @doc """
  List all ack records for a consumer, newest first.
  """
  @spec list_acks(binary()) :: {:ok, [map()]}
  defdelegate list_acks(consumer_id), to: :beam_agent_journal

  # --- Audit convenience API ---

  @doc """
  List all audit events, oldest first.
  """
  @spec list_events() :: {:ok, [:beam_agent_journal.audit_event()]}
  defdelegate list_events(), to: :beam_agent_journal

  @doc """
  List audit events matching the given filter.
  """
  @spec list_events(:beam_agent_journal.audit_filter()) ::
          {:ok, [:beam_agent_journal.audit_event()]} | {:error, term()}
  defdelegate list_events(filter), to: :beam_agent_journal

  @doc """
  Fetch an audit event by id.
  """
  @spec get_event(binary()) :: {:ok, :beam_agent_journal.audit_event()} | {:error, :not_found}
  defdelegate get_event(event_id), to: :beam_agent_journal
end
