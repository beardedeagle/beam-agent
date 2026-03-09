-module(beam_agent_catalog).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for catalog and metadata accessors inside the consolidated package.".

-export([
    list_tools/1,
    list_skills/1,
    list_plugins/1,
    list_mcp_servers/1,
    list_agents/1,
    get_tool/2,
    get_skill/2,
    get_plugin/2,
    get_agent/2,
    current_agent/1,
    set_default_agent/2,
    clear_default_agent/1
]).

list_tools(Session) -> beam_agent_catalog_core:list_tools(Session).
list_skills(Session) -> beam_agent_catalog_core:list_skills(Session).
list_plugins(Session) -> beam_agent_catalog_core:list_plugins(Session).
list_mcp_servers(Session) -> beam_agent_catalog_core:list_mcp_servers(Session).
list_agents(Session) -> beam_agent_catalog_core:list_agents(Session).
get_tool(Session, ToolId) -> beam_agent_catalog_core:get_tool(Session, ToolId).
get_skill(Session, SkillId) -> beam_agent_catalog_core:get_skill(Session, SkillId).
get_plugin(Session, PluginId) -> beam_agent_catalog_core:get_plugin(Session, PluginId).
get_agent(Session, AgentId) -> beam_agent_catalog_core:get_agent(Session, AgentId).
current_agent(Session) -> beam_agent_catalog_core:current_agent(Session).
set_default_agent(Session, AgentId) -> beam_agent_catalog_core:set_default_agent(Session, AgentId).
clear_default_agent(Session) -> beam_agent_catalog_core:clear_default_agent(Session).
