defmodule BeamAgent.Audit do
  @moduledoc """
  Canonical BeamAgent audit records.

  Audit entries are persisted through the durable journal and can be listed or
  fetched independently from the live event bus.
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

  @type audit_event() :: map()

  @spec list_events() :: {:ok, [audit_event()]}
  defdelegate list_events(), to: :beam_agent_audit

  @spec list_events(audit_filter()) :: {:ok, [audit_event()]} | {:error, term()}
  defdelegate list_events(filter), to: :beam_agent_audit

  @spec get_event(binary()) :: {:ok, audit_event()} | {:error, :not_found}
  defdelegate get_event(event_id), to: :beam_agent_audit
end
