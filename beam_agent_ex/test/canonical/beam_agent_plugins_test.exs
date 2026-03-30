defmodule BeamAgent.PluginsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Plugins)
    :ok
  end

  test "exports the canonical plugins surface" do
    assert function_exported?(BeamAgent.Plugins, :ensure_table, 0)
    assert function_exported?(BeamAgent.Plugins, :register, 2)
    assert function_exported?(BeamAgent.Plugins, :unregister, 1)
    assert function_exported?(BeamAgent.Plugins, :get, 1)
    assert function_exported?(BeamAgent.Plugins, :list, 0)
    assert function_exported?(BeamAgent.Plugins, :clear, 0)
  end

  test "ensure_table and clear round-trip" do
    :ok = BeamAgent.Plugins.ensure_table()
    :ok = BeamAgent.Plugins.clear()
    assert BeamAgent.Plugins.list() == []
  end
end
