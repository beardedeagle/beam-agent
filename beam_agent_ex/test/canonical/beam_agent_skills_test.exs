defmodule BeamAgent.SkillsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Skills)
    :ok
  end

  test "exports the canonical skills surface" do
    assert function_exported?(BeamAgent.Skills, :list, 1)
    assert function_exported?(BeamAgent.Skills, :list, 2)
    assert function_exported?(BeamAgent.Skills, :remote_list, 1)
    assert function_exported?(BeamAgent.Skills, :remote_list, 2)
    assert function_exported?(BeamAgent.Skills, :remote_export, 2)
    assert function_exported?(BeamAgent.Skills, :config_write, 3)
    assert function_exported?(BeamAgent.Skills, :ensure_global_table, 0)
    assert function_exported?(BeamAgent.Skills, :register_global, 2)
    assert function_exported?(BeamAgent.Skills, :unregister_global, 1)
    assert function_exported?(BeamAgent.Skills, :get_global, 1)
    assert function_exported?(BeamAgent.Skills, :list_global, 0)
    assert function_exported?(BeamAgent.Skills, :list_global, 1)
    assert function_exported?(BeamAgent.Skills, :clear_global, 0)
  end
end
