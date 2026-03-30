defmodule BeamAgent.CapabilitiesTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Capabilities)
    :ok
  end

  test "exports the canonical capabilities surface" do
    assert function_exported?(BeamAgent.Capabilities, :all, 0)
    assert function_exported?(BeamAgent.Capabilities, :backends, 0)
    assert function_exported?(BeamAgent.Capabilities, :capability_ids, 0)
    assert function_exported?(BeamAgent.Capabilities, :for_backend, 1)
    assert function_exported?(BeamAgent.Capabilities, :for_session, 1)
    assert function_exported?(BeamAgent.Capabilities, :status, 2)
    assert function_exported?(BeamAgent.Capabilities, :supports, 2)
    assert function_exported?(BeamAgent.Capabilities, :assert_capability, 2)
    assert function_exported?(BeamAgent.Capabilities, :capabilities, 0)
    assert function_exported?(BeamAgent.Capabilities, :capabilities, 1)
    assert function_exported?(BeamAgent.Capabilities, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Capabilities, :reset, 0)
    assert function_exported?(BeamAgent.Capabilities, :register_backend, 2)
    assert function_exported?(BeamAgent.Capabilities, :register_capability, 3)
    assert function_exported?(BeamAgent.Capabilities, :unregister_backend, 1)
  end
end
