defmodule BeamAgent.CredentialTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Credential)
    :ok
  end

  test "exports the canonical credential surface" do
    assert function_exported?(BeamAgent.Credential, :generate_cookie, 0)
  end
end
