defmodule BeamAgent.SessionStoreTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.SessionStore)
    :ok
  end

  test "exports the canonical session store surface" do
    assert function_exported?(BeamAgent.SessionStore, :ensure_tables, 0)
    assert function_exported?(BeamAgent.SessionStore, :clear, 0)
    assert function_exported?(BeamAgent.SessionStore, :register_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :update_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :list_sessions, 0)
    assert function_exported?(BeamAgent.SessionStore, :list_sessions, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :delete_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :fork_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :revert_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :unrevert_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :share_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :share_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :unshare_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_share, 1)
    assert function_exported?(BeamAgent.SessionStore, :summarize_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :summarize_session, 2)
    assert function_exported?(BeamAgent.SessionStore, :get_summary, 1)
    assert function_exported?(BeamAgent.SessionStore, :record_message, 2)
    assert function_exported?(BeamAgent.SessionStore, :record_messages, 2)
    assert function_exported?(BeamAgent.SessionStore, :get_session_messages, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_session_messages, 2)
    assert function_exported?(BeamAgent.SessionStore, :list_native_sessions, 0)
    assert function_exported?(BeamAgent.SessionStore, :list_native_sessions, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_native_session_messages, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_native_session_messages, 2)
    assert function_exported?(BeamAgent.SessionStore, :session_count, 0)
    assert function_exported?(BeamAgent.SessionStore, :message_count, 1)
    assert function_exported?(BeamAgent.SessionStore, :export_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :import_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :import_session, 2)
  end

  test "ensure_tables, clear, then list returns empty" do
    :ok = BeamAgent.SessionStore.ensure_tables()
    :ok = BeamAgent.SessionStore.clear()
    assert {:ok, []} = BeamAgent.SessionStore.list_sessions()
  end
end
