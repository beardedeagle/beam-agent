defmodule BeamAgent.HooksTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Hooks)
    :ok
  end

  test "exports the canonical hooks surface" do
    assert function_exported?(BeamAgent.Hooks, :hook, 2)
    assert function_exported?(BeamAgent.Hooks, :hook, 3)
    assert function_exported?(BeamAgent.Hooks, :new_registry, 0)
    assert function_exported?(BeamAgent.Hooks, :register_hook, 2)
    assert function_exported?(BeamAgent.Hooks, :register_hooks, 2)
    assert function_exported?(BeamAgent.Hooks, :fire, 3)
    assert function_exported?(BeamAgent.Hooks, :build_registry, 1)
    assert function_exported?(BeamAgent.Hooks, :ensure_global_table, 0)
    assert function_exported?(BeamAgent.Hooks, :register_global, 1)
    assert function_exported?(BeamAgent.Hooks, :unregister_global, 1)
    assert function_exported?(BeamAgent.Hooks, :global_registry, 0)
  end

  test "new_registry returns empty map, fire on empty registry returns ok" do
    registry = BeamAgent.Hooks.new_registry()
    assert registry == %{}

    ctx = %{event: :session_start}
    assert {:ok, ^ctx} = BeamAgent.Hooks.fire(:session_start, ctx, registry)
  end
end
