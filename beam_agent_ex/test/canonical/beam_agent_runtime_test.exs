defmodule BeamAgent.RuntimeTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Runtime)
    :ok
  end

  test "exports the state management surface" do
    assert function_exported?(BeamAgent.Runtime, :get_state, 1)
    assert function_exported?(BeamAgent.Runtime, :current_provider, 1)
    assert function_exported?(BeamAgent.Runtime, :set_provider, 2)
    assert function_exported?(BeamAgent.Runtime, :clear_provider, 1)
    assert function_exported?(BeamAgent.Runtime, :get_provider_config, 1)
    assert function_exported?(BeamAgent.Runtime, :set_provider_config, 2)
    assert function_exported?(BeamAgent.Runtime, :current_agent, 1)
    assert function_exported?(BeamAgent.Runtime, :set_agent, 2)
    assert function_exported?(BeamAgent.Runtime, :clear_agent, 1)
    assert function_exported?(BeamAgent.Runtime, :list_providers, 1)
    assert function_exported?(BeamAgent.Runtime, :provider_status, 1)
    assert function_exported?(BeamAgent.Runtime, :provider_status, 2)
    assert function_exported?(BeamAgent.Runtime, :validate_provider_config, 2)
  end

  test "exports the table lifecycle surface" do
    assert function_exported?(BeamAgent.Runtime, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Runtime, :clear, 0)
  end

  test "exports the session lifecycle surface" do
    assert function_exported?(BeamAgent.Runtime, :register_session, 2)
    assert function_exported?(BeamAgent.Runtime, :clear_session, 1)
    assert function_exported?(BeamAgent.Runtime, :merge_query_opts, 2)
  end

  test "exports the app registry surface" do
    assert function_exported?(BeamAgent.Runtime, :app_register, 3)
    assert function_exported?(BeamAgent.Runtime, :app_unregister, 2)
    assert function_exported?(BeamAgent.Runtime, :app_ensure_tables, 0)
    assert function_exported?(BeamAgent.Runtime, :app_clear, 0)
    assert function_exported?(BeamAgent.Runtime, :app_info_impl, 1)
    assert function_exported?(BeamAgent.Runtime, :app_init_impl, 1)
    assert function_exported?(BeamAgent.Runtime, :app_modes_impl, 1)
  end

  test "exports the session-scoped runtime operations surface" do
    assert function_exported?(BeamAgent.Runtime, :set_model, 2)
    assert function_exported?(BeamAgent.Runtime, :set_permission_mode, 2)
    assert function_exported?(BeamAgent.Runtime, :interrupt, 1)
    assert function_exported?(BeamAgent.Runtime, :abort, 1)
    assert function_exported?(BeamAgent.Runtime, :send_control, 3)
    assert function_exported?(BeamAgent.Runtime, :get_status, 1)
    assert function_exported?(BeamAgent.Runtime, :get_auth_status, 1)
    assert function_exported?(BeamAgent.Runtime, :get_last_session_id, 1)
    assert function_exported?(BeamAgent.Runtime, :windows_sandbox_setup_start, 2)
    assert function_exported?(BeamAgent.Runtime, :set_max_thinking_tokens, 2)
    assert function_exported?(BeamAgent.Runtime, :stop_task, 2)
  end

  test "exports the account operations surface" do
    assert function_exported?(BeamAgent.Runtime, :account_info, 1)
    assert function_exported?(BeamAgent.Runtime, :account_login, 2)
    assert function_exported?(BeamAgent.Runtime, :account_cancel, 2)
    assert function_exported?(BeamAgent.Runtime, :account_logout, 1)
    assert function_exported?(BeamAgent.Runtime, :account_rate_limits, 1)
  end

  test "exports the app/project operations surface" do
    assert function_exported?(BeamAgent.Runtime, :apps_list, 1)
    assert function_exported?(BeamAgent.Runtime, :apps_list, 2)
    assert function_exported?(BeamAgent.Runtime, :app_info, 1)
    assert function_exported?(BeamAgent.Runtime, :app_init, 1)
    assert function_exported?(BeamAgent.Runtime, :app_log, 2)
    assert function_exported?(BeamAgent.Runtime, :app_modes, 1)
  end

  test "exports the todo operations surface" do
    assert function_exported?(BeamAgent.Runtime, :extract_todos, 1)
    assert function_exported?(BeamAgent.Runtime, :filter_by_status, 2)
    assert function_exported?(BeamAgent.Runtime, :todo_summary, 1)
  end

  test "ensure_tables and clear round-trip" do
    :ok = BeamAgent.Runtime.ensure_tables()
    :ok = BeamAgent.Runtime.clear()
  end
end
