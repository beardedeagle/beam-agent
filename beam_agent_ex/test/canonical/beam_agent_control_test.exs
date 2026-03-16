defmodule BeamAgent.ControlTest do
  use ExUnit.Case, async: false

  setup do
    :ok = :beam_agent_control.clear()
    :ok = :beam_agent_runs.clear()
    :ok = :beam_agent_journal.clear()

    on_exit(fn ->
      :ok = :beam_agent_control.clear()
      :ok = :beam_agent_runs.clear()
      :ok = :beam_agent_journal.clear()
    end)

    :ok
  end

  test "register_task creates a linked canonical run" do
    session = "beam-agent-control-#{System.unique_integer([:positive, :monotonic])}"
    pid = spawn(fn -> Process.sleep(60_000) end)

    assert :ok = BeamAgent.Control.register_task(session, "task-1", pid)
    assert {:ok, [task]} = BeamAgent.Control.list_tasks(session)
    assert is_binary(task.run_id)

    assert {:ok, run} = BeamAgent.Runs.get_run(task.run_id)
    assert run.status == :running
    assert run.kind == :task
    assert run.metadata == %{task_id: "task-1", source: :control_task}

    Process.exit(pid, :kill)
  end

  test "stop_task cancels the linked run and preserves the task entry until unregister" do
    session = "beam-agent-control-stop-#{System.unique_integer([:positive, :monotonic])}"
    pid = spawn(fn -> :ok end)
    Process.sleep(10)

    assert :ok = BeamAgent.Control.register_task(session, "task-stop", pid)
    assert {:ok, [task_before_stop]} = BeamAgent.Control.list_tasks(session)

    assert :ok = BeamAgent.Control.stop_task(session, "task-stop")
    assert {:ok, [task_after_stop]} = BeamAgent.Control.list_tasks(session)
    assert task_after_stop.status == :stopped
    assert is_integer(task_after_stop.stopped_at)
    assert task_after_stop.run_id == task_before_stop.run_id

    assert {:ok, run} = BeamAgent.Runs.get_run(task_after_stop.run_id)
    assert run.status == :cancelled
    assert run.cancel_reason == %{reason: :task_stopped, source: :control_task, task_id: "task-stop"}
  end

  test "unregister_task removes the task entry and completes the linked run" do
    session = "beam-agent-control-unregister-#{System.unique_integer([:positive, :monotonic])}"
    pid = spawn(fn -> Process.sleep(60_000) end)

    assert :ok = BeamAgent.Control.register_task(session, "task-unregister", pid)
    assert {:ok, [task]} = BeamAgent.Control.list_tasks(session)
    assert :ok = BeamAgent.Control.unregister_task(session, "task-unregister")
    assert {:ok, []} = BeamAgent.Control.list_tasks(session)

    assert {:ok, run} = BeamAgent.Runs.get_run(task.run_id)
    assert run.status == :completed
    assert run.output == %{source: :control_task, task_id: "task-unregister", terminal_status: :completed}

    Process.exit(pid, :kill)
  end
end
