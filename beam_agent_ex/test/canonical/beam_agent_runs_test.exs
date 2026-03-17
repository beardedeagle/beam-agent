defmodule BeamAgent.RunsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Runs)
    :ok
  end

  test "exports the canonical runs surface" do
    assert function_exported?(BeamAgent.Runs, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Runs, :clear, 0)
    assert function_exported?(BeamAgent.Runs, :start_run, 2)
    assert function_exported?(BeamAgent.Runs, :get_run, 1)
    assert function_exported?(BeamAgent.Runs, :list_runs, 0)
    assert function_exported?(BeamAgent.Runs, :list_runs, 1)
    assert function_exported?(BeamAgent.Runs, :complete_run, 2)
    assert function_exported?(BeamAgent.Runs, :fail_run, 2)
    assert function_exported?(BeamAgent.Runs, :cancel_run, 2)
    assert function_exported?(BeamAgent.Runs, :start_step, 2)
    assert function_exported?(BeamAgent.Runs, :get_step, 2)
    assert function_exported?(BeamAgent.Runs, :list_steps, 1)
    assert function_exported?(BeamAgent.Runs, :complete_step, 3)
    assert function_exported?(BeamAgent.Runs, :fail_step, 3)
    assert function_exported?(BeamAgent.Runs, :cancel_step, 3)
  end

  test "records runs and steps through the Elixir wrapper" do
    session = "beam-agent-runs-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, run} =
             BeamAgent.Runs.start_run(%{session_id: session, thread_id: "thread-1"}, %{
               kind: :workflow,
               input: %{goal: "ship"}
             })

    assert {:ok, step} = BeamAgent.Runs.start_step(run.run_id, %{kind: :review})

    assert {:ok, completed_step} =
             BeamAgent.Runs.complete_step(run.run_id, step.step_id, %{ok: true})

    assert completed_step.status == :completed

    assert {:ok, completed_run} = BeamAgent.Runs.complete_run(run.run_id, %{summary: "done"})
    assert completed_run.status == :completed

    assert {:ok, [listed_run]} = BeamAgent.Runs.list_runs(%{session_id: session})
    assert listed_run.run_id == run.run_id

    assert {:ok, [listed_step]} = BeamAgent.Runs.list_steps(run.run_id)
    assert listed_step.step_id == step.step_id
  end
end
