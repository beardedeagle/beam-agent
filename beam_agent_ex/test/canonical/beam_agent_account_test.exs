defmodule BeamAgent.AccountTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Account)
    :ok
  end

  test "exports the canonical account surface" do
    assert function_exported?(BeamAgent.Account, :info, 1)
    assert function_exported?(BeamAgent.Account, :login, 2)
    assert function_exported?(BeamAgent.Account, :cancel, 2)
    assert function_exported?(BeamAgent.Account, :logout, 1)
    assert function_exported?(BeamAgent.Account, :rate_limits, 1)
  end
end
