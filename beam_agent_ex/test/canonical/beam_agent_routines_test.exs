defmodule BeamAgent.RoutinesTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Routines)
    :ok
  end

  test "exports the canonical routines surface" do
    assert function_exported?(BeamAgent.Routines, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Routines, :clear, 0)
    assert function_exported?(BeamAgent.Routines, :create, 1)
    assert function_exported?(BeamAgent.Routines, :update, 2)
    assert function_exported?(BeamAgent.Routines, :cancel, 1)
    assert function_exported?(BeamAgent.Routines, :get, 1)
    assert function_exported?(BeamAgent.Routines, :list, 0)
    assert function_exported?(BeamAgent.Routines, :list, 1)
    assert function_exported?(BeamAgent.Routines, :due, 0)
    assert function_exported?(BeamAgent.Routines, :due, 1)
    assert function_exported?(BeamAgent.Routines, :next_due_at, 0)
    assert function_exported?(BeamAgent.Routines, :run_now, 1)
    assert function_exported?(BeamAgent.Routines, :run_due, 0)
    assert function_exported?(BeamAgent.Routines, :run_due, 1)
  end
end
