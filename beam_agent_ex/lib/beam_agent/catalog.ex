defmodule BeamAgent.Catalog do
  @moduledoc "Catalog and metadata accessors for the canonical `BeamAgent` package."

  defdelegate list_tools(session), to: :beam_agent_catalog
  defdelegate list_skills(session), to: :beam_agent_catalog
  defdelegate list_plugins(session), to: :beam_agent_catalog
  defdelegate list_mcp_servers(session), to: :beam_agent_catalog
  defdelegate list_agents(session), to: :beam_agent_catalog
  defdelegate get_tool(session, tool_id), to: :beam_agent_catalog
  defdelegate get_skill(session, skill_id), to: :beam_agent_catalog
  defdelegate get_plugin(session, plugin_id), to: :beam_agent_catalog
  defdelegate get_agent(session, agent_id), to: :beam_agent_catalog
  defdelegate current_agent(session), to: :beam_agent_catalog
  defdelegate set_default_agent(session, agent_id), to: :beam_agent_catalog
  defdelegate clear_default_agent(session), to: :beam_agent_catalog
end
