defmodule BeamAgent.ContextTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Context)
    :ok
  end

  test "exports the canonical context surface" do
    assert function_exported?(BeamAgent.Context, :context_status, 1)
    assert function_exported?(BeamAgent.Context, :budget_estimate, 1)
    assert function_exported?(BeamAgent.Context, :compact_now, 2)
    assert function_exported?(BeamAgent.Context, :maybe_compact, 2)
  end
end

