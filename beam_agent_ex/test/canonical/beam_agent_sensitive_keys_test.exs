defmodule BeamAgent.SensitiveKeysTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.SensitiveKeys)
    :ok
  end

  test "exports the canonical sensitive keys surface" do
    assert function_exported?(BeamAgent.SensitiveKeys, :all, 0)
    assert function_exported?(BeamAgent.SensitiveKeys, :credential_match_keys, 0)
    assert function_exported?(BeamAgent.SensitiveKeys, :redaction_match_keys, 0)
    assert function_exported?(BeamAgent.SensitiveKeys, :is_sensitive, 1)
  end

  test "default_keys returns a non-empty list" do
    keys = BeamAgent.SensitiveKeys.all()
    assert is_list(keys)
    assert length(keys) > 0
  end
end
