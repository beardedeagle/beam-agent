defmodule BeamAgent.MCP do
  @moduledoc """
  In-process MCP helpers for the canonical `BeamAgent` package.

  Provides the tool registry API (constructors, dispatch, session registry)
  and access to the full MCP 2025-06-18 protocol layer, server dispatch,
  and client-side dispatch.
  """

  # Tool registry — constructors
  defdelegate tool(name, description, input_schema, handler), to: :beam_agent_mcp
  defdelegate server(name, tools), to: :beam_agent_mcp
  defdelegate server(name, tools, version), to: :beam_agent_mcp

  # Tool registry — registry management
  defdelegate new_registry(), to: :beam_agent_mcp
  defdelegate register_server(server, registry), to: :beam_agent_mcp
  defdelegate server_names(registry), to: :beam_agent_mcp
  defdelegate servers_for_cli(registry), to: :beam_agent_mcp
  defdelegate servers_for_init(registry), to: :beam_agent_mcp

  # Tool registry — dispatch
  defdelegate handle_mcp_message(server_name, message, registry), to: :beam_agent_mcp
  defdelegate handle_mcp_message(server_name, message, registry, opts), to: :beam_agent_mcp
  defdelegate call_tool_by_name(tool_name, arguments, registry), to: :beam_agent_mcp
  defdelegate call_tool_by_name(tool_name, arguments, registry, opts), to: :beam_agent_mcp
  defdelegate all_tool_definitions(registry), to: :beam_agent_mcp
  defdelegate build_registry(servers), to: :beam_agent_mcp

  # Tool registry — runtime management
  defdelegate server_status(registry), to: :beam_agent_mcp
  defdelegate set_servers(servers, old_registry), to: :beam_agent_mcp
  defdelegate toggle_server(name, enabled, registry), to: :beam_agent_mcp
  defdelegate reconnect_server(name, registry), to: :beam_agent_mcp
  defdelegate unregister_server(name, registry), to: :beam_agent_mcp

  # Tool registry — session-scoped registry (ETS-backed)
  defdelegate register_session_registry(pid, registry), to: :beam_agent_mcp
  defdelegate get_session_registry(pid), to: :beam_agent_mcp
  defdelegate update_session_registry(pid, update_fun), to: :beam_agent_mcp
  defdelegate unregister_session_registry(pid), to: :beam_agent_mcp
  defdelegate ensure_registry_table(), to: :beam_agent_mcp

  # Protocol (beam_agent_mcp_protocol)
  defdelegate protocol_version(), to: :beam_agent_mcp

  # Full-spec server dispatch (beam_agent_mcp_dispatch)
  defdelegate new_dispatch(server_info, server_caps, opts), to: :beam_agent_mcp
  defdelegate dispatch_message(msg, state), to: :beam_agent_mcp
  defdelegate dispatch_lifecycle_state(state), to: :beam_agent_mcp
  defdelegate dispatch_session_capabilities(state), to: :beam_agent_mcp

  # Client-side dispatch (beam_agent_mcp_client_dispatch)
  defdelegate new_client(client_info, client_caps, opts), to: :beam_agent_mcp
  defdelegate client_lifecycle_state(state), to: :beam_agent_mcp
  defdelegate client_server_capabilities(state), to: :beam_agent_mcp
  defdelegate client_session_capabilities(state), to: :beam_agent_mcp
  defdelegate client_send_initialize(state), to: :beam_agent_mcp
  defdelegate client_send_initialized(state), to: :beam_agent_mcp
  defdelegate client_send_ping(state), to: :beam_agent_mcp
  defdelegate client_send_tools_list(state), to: :beam_agent_mcp
  defdelegate client_send_tools_list(cursor, state), to: :beam_agent_mcp
  defdelegate client_send_tools_call(tool_name, arguments, state), to: :beam_agent_mcp
  defdelegate client_send_resources_list(state), to: :beam_agent_mcp
  defdelegate client_send_resources_list(cursor, state), to: :beam_agent_mcp
  defdelegate client_send_resources_read(uri, state), to: :beam_agent_mcp
  defdelegate client_send_resources_templates_list(state), to: :beam_agent_mcp
  defdelegate client_send_resources_templates_list(cursor, state), to: :beam_agent_mcp
  defdelegate client_send_resources_subscribe(uri, state), to: :beam_agent_mcp
  defdelegate client_send_resources_unsubscribe(uri, state), to: :beam_agent_mcp
  defdelegate client_send_prompts_list(state), to: :beam_agent_mcp
  defdelegate client_send_prompts_list(cursor, state), to: :beam_agent_mcp
  defdelegate client_send_prompts_get(name, state), to: :beam_agent_mcp
  defdelegate client_send_prompts_get(name, arguments, state), to: :beam_agent_mcp
  defdelegate client_send_completion_complete(ref, argument, state), to: :beam_agent_mcp
  defdelegate client_send_completion_complete(ref, argument, context, state), to: :beam_agent_mcp
  defdelegate client_send_logging_set_level(level, state), to: :beam_agent_mcp
  defdelegate client_send_request(method, params, state), to: :beam_agent_mcp
  defdelegate client_send_cancelled(request_id, state), to: :beam_agent_mcp
  defdelegate client_send_cancelled(request_id, reason, state), to: :beam_agent_mcp
  defdelegate client_send_progress(token, progress, state), to: :beam_agent_mcp
  defdelegate client_send_progress(token, progress, total, state), to: :beam_agent_mcp
  defdelegate client_send_progress(token, progress, total, message, state), to: :beam_agent_mcp
  defdelegate client_send_roots_list_changed(state), to: :beam_agent_mcp
  defdelegate client_handle_message(msg, state), to: :beam_agent_mcp
  defdelegate client_check_timeouts(now, state), to: :beam_agent_mcp
  defdelegate client_pending_count(state), to: :beam_agent_mcp
end
