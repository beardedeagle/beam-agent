defmodule BeamAgent.AgentsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Agents)
    :ok
  end

  test "exports the canonical agents surface" do
    assert function_exported?(BeamAgent.Agents, :ensure_table, 0)
    assert function_exported?(BeamAgent.Agents, :register, 2)
    assert function_exported?(BeamAgent.Agents, :unregister, 1)
    assert function_exported?(BeamAgent.Agents, :get, 1)
    assert function_exported?(BeamAgent.Agents, :list, 0)
    assert function_exported?(BeamAgent.Agents, :clear, 0)
  end
end
