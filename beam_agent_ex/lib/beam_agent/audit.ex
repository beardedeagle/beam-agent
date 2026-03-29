defmodule BeamAgent.Audit do
  @moduledoc """
  Canonical BeamAgent audit records.

  Audit entries are persisted through the durable journal and can be listed or
  fetched independently from the live event bus.

  Use this module when you need durable evidence of policy decisions or
  higher-level actions taken by control, routing, routines, memory, and
  orchestration flows.
  """

  @type category() :: atom() | binary()
  @type action() :: atom() | binary()

  @type audit_filter() :: %{
          optional(:event_id) => binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary(),
          optional(:category) => category(),
          optional(:action) => action(),
          optional(:decision) => atom() | binary(),
          optional(:profile_id) => binary(),
          optional(:since) => integer(),
          optional(:limit) => pos_integer()
        }

  @type audit_event() :: %{
          required(:event_id) => binary(),
          required(:event_type) => atom() | binary(),
          required(:payload) => map(),
          required(:sequence) => pos_integer(),
          required(:tags) => [atom() | binary()],
          required(:timestamp) => integer(),
          optional(:run_id) => binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary()
        }

  @type listed_audit_event() :: %{
          required(:event_id) => binary(),
          required(:event_type) => atom() | binary(),
          required(:payload) => map(),
          required(:sequence) => pos_integer(),
          required(:tags) => [term()],
          required(:timestamp) => integer(),
          optional(:run_id) => binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary()
        }

  @spec list_events() :: {:ok, [listed_audit_event()]}
  defdelegate list_events(), to: :beam_agent_journal

  @spec list_events(audit_filter()) ::
          {:ok, [:beam_agent_journal.audit_event()]}
          | {:error, term()}
  defdelegate list_events(filter), to: :beam_agent_journal

  @spec get_event(binary()) :: {:ok, audit_event()} | {:error, :not_found}
  defdelegate get_event(event_id), to: :beam_agent_journal
end
