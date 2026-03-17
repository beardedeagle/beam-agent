defmodule BeamAgent.AuditTest do
  use ExUnit.Case, async: false

  setup do
    :ok = :beam_agent_journal_core.clear()
    :ok
  end

  test "exports the canonical audit surface" do
    assert function_exported?(BeamAgent.Audit, :list_events, 0)
    assert function_exported?(BeamAgent.Audit, :list_events, 1)
    assert function_exported?(BeamAgent.Audit, :get_event, 1)
  end

  test "lists and fetches audit events" do
    assert {:ok, event} =
             :beam_agent_audit_core.record(:command, :run, %{run_id: "ex-audit-run"}, %{
               decision: :allow
             })

    event_id = event[:event_id] || event["event_id"]
    assert {:ok, [listed]} = BeamAgent.Audit.list_events(%{run_id: "ex-audit-run"})
    assert (listed[:event_id] || listed["event_id"]) == event_id
    assert {:ok, stored} = BeamAgent.Audit.get_event(event_id)
    assert (stored[:event_type] || stored["event_type"]) == "audit"
  end
end
