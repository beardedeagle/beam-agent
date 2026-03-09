defmodule BeamAgent.MCP do
  @moduledoc "In-process MCP helpers for the canonical `BeamAgent` package."

  defdelegate tool(name, description, input_schema, handler), to: :beam_agent_mcp
  defdelegate server(name, tools), to: :beam_agent_mcp
  defdelegate server(name, tools, version), to: :beam_agent_mcp
  defdelegate new_registry(), to: :beam_agent_mcp
  defdelegate register_server(server, registry), to: :beam_agent_mcp
  defdelegate server_names(registry), to: :beam_agent_mcp
  defdelegate servers_for_cli(registry), to: :beam_agent_mcp
  defdelegate servers_for_init(registry), to: :beam_agent_mcp
  defdelegate handle_mcp_message(session_id, message, registry), to: :beam_agent_mcp
  defdelegate handle_mcp_message(session_id, message, registry, timeout), to: :beam_agent_mcp
  defdelegate call_tool_by_name(session_id, name, input), to: :beam_agent_mcp
  defdelegate call_tool_by_name(session_id, name, input, timeout), to: :beam_agent_mcp
  defdelegate all_tool_definitions(registry), to: :beam_agent_mcp
  defdelegate build_registry(opts), to: :beam_agent_mcp
  defdelegate server_status(session_id), to: :beam_agent_mcp
  defdelegate set_servers(session_id, servers), to: :beam_agent_mcp
  defdelegate toggle_server(session_id, server_name, enabled), to: :beam_agent_mcp
  defdelegate reconnect_server(session_id, server_name), to: :beam_agent_mcp
  defdelegate unregister_server(session_id, server_name), to: :beam_agent_mcp
end
