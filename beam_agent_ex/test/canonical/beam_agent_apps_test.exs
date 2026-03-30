defmodule BeamAgent.AppsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Apps)
    :ok
  end

  test "exports the canonical apps surface" do
    assert function_exported?(BeamAgent.Apps, :list, 1)
    assert function_exported?(BeamAgent.Apps, :list, 2)
    assert function_exported?(BeamAgent.Apps, :info, 1)
    assert function_exported?(BeamAgent.Apps, :init, 1)
    assert function_exported?(BeamAgent.Apps, :log, 2)
    assert function_exported?(BeamAgent.Apps, :modes, 1)
  end
end
