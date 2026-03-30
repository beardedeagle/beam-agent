defmodule BeamAgent.ProviderTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Provider)
    :ok
  end

  test "exports the canonical provider surface" do
    assert function_exported?(BeamAgent.Provider, :current, 1)
    assert function_exported?(BeamAgent.Provider, :set, 2)
    assert function_exported?(BeamAgent.Provider, :clear, 1)
    assert function_exported?(BeamAgent.Provider, :current_agent, 1)
    assert function_exported?(BeamAgent.Provider, :set_agent, 2)
    assert function_exported?(BeamAgent.Provider, :clear_agent, 1)
    assert function_exported?(BeamAgent.Provider, :list, 1)
    assert function_exported?(BeamAgent.Provider, :auth_methods, 1)
    assert function_exported?(BeamAgent.Provider, :oauth_authorize, 3)
    assert function_exported?(BeamAgent.Provider, :oauth_callback, 3)
  end
end
