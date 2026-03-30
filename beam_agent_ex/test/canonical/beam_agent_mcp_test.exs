defmodule BeamAgent.MCPTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.MCP)
    :ok
  end

  test "exports the tool registry constructor surface" do
    assert function_exported?(BeamAgent.MCP, :tool, 4)
    assert function_exported?(BeamAgent.MCP, :server, 2)
    assert function_exported?(BeamAgent.MCP, :server, 3)
  end

  test "exports the registry management surface" do
    assert function_exported?(BeamAgent.MCP, :new_registry, 0)
    assert function_exported?(BeamAgent.MCP, :register_server, 2)
    assert function_exported?(BeamAgent.MCP, :server_names, 1)
    assert function_exported?(BeamAgent.MCP, :servers_for_cli, 1)
    assert function_exported?(BeamAgent.MCP, :servers_for_init, 1)
    assert function_exported?(BeamAgent.MCP, :build_registry, 1)
  end

  test "exports the dispatch surface" do
    assert function_exported?(BeamAgent.MCP, :handle_mcp_message, 3)
    assert function_exported?(BeamAgent.MCP, :handle_mcp_message, 4)
    assert function_exported?(BeamAgent.MCP, :call_tool_by_name, 3)
    assert function_exported?(BeamAgent.MCP, :call_tool_by_name, 4)
    assert function_exported?(BeamAgent.MCP, :all_tool_definitions, 1)
  end

  test "exports the runtime management surface" do
    assert function_exported?(BeamAgent.MCP, :server_status, 1)
    assert function_exported?(BeamAgent.MCP, :set_servers, 2)
    assert function_exported?(BeamAgent.MCP, :toggle_server, 3)
    assert function_exported?(BeamAgent.MCP, :reconnect_server, 2)
    assert function_exported?(BeamAgent.MCP, :unregister_server, 2)
  end

  test "exports the session-scoped ETS registry surface" do
    assert function_exported?(BeamAgent.MCP, :register_session_registry, 2)
    assert function_exported?(BeamAgent.MCP, :get_session_registry, 1)
    assert function_exported?(BeamAgent.MCP, :update_session_registry, 2)
    assert function_exported?(BeamAgent.MCP, :unregister_session_registry, 1)
    assert function_exported?(BeamAgent.MCP, :ensure_registry_table, 0)
  end

  test "exports the protocol surface" do
    assert function_exported?(BeamAgent.MCP, :protocol_version, 0)
  end

  test "exports the server-side dispatch surface" do
    assert function_exported?(BeamAgent.MCP, :new_dispatch, 3)
    assert function_exported?(BeamAgent.MCP, :dispatch_message, 2)
    assert function_exported?(BeamAgent.MCP, :dispatch_lifecycle_state, 1)
    assert function_exported?(BeamAgent.MCP, :dispatch_session_capabilities, 1)
    assert function_exported?(BeamAgent.MCP, :dispatch_mark_error, 2)
    assert function_exported?(BeamAgent.MCP, :dispatch_mark_shutting_down, 1)
    assert function_exported?(BeamAgent.MCP, :dispatch_reset, 1)
    assert function_exported?(BeamAgent.MCP, :dispatch_error_info, 1)
    assert function_exported?(BeamAgent.MCP, :dispatch_is_operational, 1)
  end

  test "exports the client-side dispatch surface" do
    assert function_exported?(BeamAgent.MCP, :new_client, 3)
    assert function_exported?(BeamAgent.MCP, :client_lifecycle_state, 1)
    assert function_exported?(BeamAgent.MCP, :client_server_capabilities, 1)
    assert function_exported?(BeamAgent.MCP, :client_session_capabilities, 1)
    assert function_exported?(BeamAgent.MCP, :client_mark_error, 2)
    assert function_exported?(BeamAgent.MCP, :client_mark_disconnected, 2)
    assert function_exported?(BeamAgent.MCP, :client_mark_shutting_down, 1)
    assert function_exported?(BeamAgent.MCP, :client_reset, 1)
    assert function_exported?(BeamAgent.MCP, :client_error_info, 1)
    assert function_exported?(BeamAgent.MCP, :client_is_operational, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_initialize, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_initialized, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_ping, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_tools_list, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_tools_list, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_tools_call, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_list, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_list, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_read, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_templates_list, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_templates_list, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_subscribe, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_resources_unsubscribe, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_prompts_list, 1)
    assert function_exported?(BeamAgent.MCP, :client_send_prompts_list, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_prompts_get, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_prompts_get, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_completion_complete, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_completion_complete, 4)
    assert function_exported?(BeamAgent.MCP, :client_send_logging_set_level, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_request, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_cancelled, 2)
    assert function_exported?(BeamAgent.MCP, :client_send_cancelled, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_progress, 3)
    assert function_exported?(BeamAgent.MCP, :client_send_progress, 4)
    assert function_exported?(BeamAgent.MCP, :client_send_progress, 5)
    assert function_exported?(BeamAgent.MCP, :client_send_roots_list_changed, 1)
    assert function_exported?(BeamAgent.MCP, :client_handle_message, 2)
    assert function_exported?(BeamAgent.MCP, :client_check_timeouts, 2)
    assert function_exported?(BeamAgent.MCP, :client_pending_count, 1)
  end

  test "exports the session-scoped MCP management surface" do
    assert function_exported?(BeamAgent.MCP, :status, 1)
    assert function_exported?(BeamAgent.MCP, :add_server, 2)
    assert function_exported?(BeamAgent.MCP, :session_server_status, 1)
    assert function_exported?(BeamAgent.MCP, :session_set_servers, 2)
    assert function_exported?(BeamAgent.MCP, :session_reconnect_server, 2)
    assert function_exported?(BeamAgent.MCP, :session_toggle_server, 3)
    assert function_exported?(BeamAgent.MCP, :server_oauth_login, 2)
    assert function_exported?(BeamAgent.MCP, :server_reload, 1)
    assert function_exported?(BeamAgent.MCP, :status_list, 1)
  end

  test "exports the global MCP server registration surface" do
    assert function_exported?(BeamAgent.MCP, :ensure_global_table, 0)
    assert function_exported?(BeamAgent.MCP, :register_global_server, 2)
    assert function_exported?(BeamAgent.MCP, :unregister_global_server, 1)
    assert function_exported?(BeamAgent.MCP, :get_global_server, 1)
    assert function_exported?(BeamAgent.MCP, :list_global_servers, 0)
    assert function_exported?(BeamAgent.MCP, :clear_global_servers, 0)
  end
end
