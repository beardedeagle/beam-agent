defmodule BeamAgent.SearchTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Search)
    :ok
  end

  test "exports the canonical search surface" do
    assert function_exported?(BeamAgent.Search, :fuzzy, 2)
    assert function_exported?(BeamAgent.Search, :fuzzy, 3)
    assert function_exported?(BeamAgent.Search, :session_start, 3)
    assert function_exported?(BeamAgent.Search, :session_update, 3)
    assert function_exported?(BeamAgent.Search, :session_stop, 2)
  end
end
