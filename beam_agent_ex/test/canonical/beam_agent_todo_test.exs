defmodule BeamAgent.TodoTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Todo)
    :ok
  end

  test "exports the canonical todo surface" do
    assert function_exported?(BeamAgent.Todo, :extract_todos, 1)
    assert function_exported?(BeamAgent.Todo, :filter_by_status, 2)
    assert function_exported?(BeamAgent.Todo, :todo_summary, 1)
  end
end
