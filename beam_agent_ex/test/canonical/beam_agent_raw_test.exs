defmodule BeamAgent.RawTest do
  use ExUnit.Case, async: true

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Raw)
    :ok
  end

  test "keeps generic raw helpers available" do
    assert function_exported?(BeamAgent.Raw, :backend, 1)
    assert function_exported?(BeamAgent.Raw, :adapter_module, 1)
    assert function_exported?(BeamAgent.Raw, :call, 3)
    assert function_exported?(BeamAgent.Raw, :call_backend, 3)
  end

  test "exports native session access at the transport level" do
    assert function_exported?(BeamAgent.Raw, :list_native_sessions, 0)
    assert function_exported?(BeamAgent.Raw, :list_native_sessions, 1)
    assert function_exported?(BeamAgent.Raw, :get_native_session_messages, 1)
    assert function_exported?(BeamAgent.Raw, :get_native_session_messages, 2)
  end

  test "exports transport-level health, status, and auth probes" do
    assert function_exported?(BeamAgent.Raw, :server_health, 1)
    assert function_exported?(BeamAgent.Raw, :get_status, 1)
    assert function_exported?(BeamAgent.Raw, :get_auth_status, 1)
    assert function_exported?(BeamAgent.Raw, :get_last_session_id, 1)
  end

  test "exports session destroy at the transport level" do
    assert function_exported?(BeamAgent.Raw, :session_destroy, 1)
    assert function_exported?(BeamAgent.Raw, :session_destroy, 2)
  end
end
