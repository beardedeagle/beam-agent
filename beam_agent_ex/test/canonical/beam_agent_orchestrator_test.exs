defmodule BeamAgent.OrchestratorTest do
  use ExUnit.Case, async: false

  setup do
    :ok = :beam_agent_orchestrator.clear()
    :ok = :beam_agent_runs.clear()
    :ok = :beam_agent_journal.clear()
    :ok = :beam_agent_threads.clear()
    :ok = :beam_agent_runtime_core.clear()
    :ok = :beam_agent_session_store_core.clear()
    :ok
  end

  test "exports the canonical orchestrator surface" do
    assert function_exported?(BeamAgent.Orchestrator, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Orchestrator, :clear, 0)
    assert function_exported?(BeamAgent.Orchestrator, :spawn, 2)
    assert function_exported?(BeamAgent.Orchestrator, :delegate, 3)
    assert function_exported?(BeamAgent.Orchestrator, :await, 2)
    assert function_exported?(BeamAgent.Orchestrator, :collect, 2)
    assert function_exported?(BeamAgent.Orchestrator, :cancel, 2)
    assert function_exported?(BeamAgent.Orchestrator, :status, 1)
    assert function_exported?(BeamAgent.Orchestrator, :list_children, 1)
  end

  test "spawns a child thread and tracks it under the parent run" do
    session = "ex-orchestrator-session-#{System.unique_integer([:positive])}"
    :ok =
      :beam_agent_session_store_core.register_session(session, %{
        session_id: session,
        backend: :gemini,
        adapter: :gemini
      })

    assert {:ok, parent} = BeamAgent.Runs.start_run(session, %{kind: :parent})
    parent_run_id = parent[:run_id] || parent["run_id"]

    assert {:ok, child} =
             BeamAgent.Orchestrator.spawn(parent_run_id, %{
               thread: %{start: %{name: "ex-child-thread"}}
             })

    run = child[:run] || child["run"]
    child_run_id = run[:run_id] || run["run_id"]
    assert (child[:substrate] || child["substrate"]) == :thread
    assert is_binary(run[:thread_id] || run["thread_id"])

    assert {:ok, delegated} =
             BeamAgent.Orchestrator.delegate(parent_run_id, %{task: "review"}, %{})

    delegated_run_id = delegated[:run_id] || delegated["run_id"]
    assert {:error, :timeout} = BeamAgent.Orchestrator.await(delegated_run_id, 0)
    assert {:ok, _completed} = BeamAgent.Runs.complete_run(delegated_run_id, %{ok: true})
    assert {:ok, awaited} = BeamAgent.Orchestrator.await(delegated_run_id, 10)
    assert (awaited[:status] || awaited["status"]) == :completed

    assert {:ok, collected} =
             BeamAgent.Orchestrator.collect(child_run_id, %{include_journal: true})

    assert is_list(collected[:journal] || collected["journal"])
    assert {:ok, children} = BeamAgent.Orchestrator.list_children(parent_run_id)
    assert Enum.any?(children, fn entry ->
             child_run = entry[:run] || entry["run"]
             (child_run[:run_id] || child_run["run_id"]) == child_run_id
           end)
  end
end
