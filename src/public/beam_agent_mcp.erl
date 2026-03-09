-module(beam_agent_mcp).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for in-process MCP support inside `beam_agent`.".

-export([
    tool/4,
    server/2,
    server/3,
    new_registry/0,
    register_server/2,
    server_names/1,
    servers_for_cli/1,
    servers_for_init/1,
    handle_mcp_message/3,
    handle_mcp_message/4,
    call_tool_by_name/3,
    call_tool_by_name/4,
    all_tool_definitions/1,
    build_registry/1,
    server_status/1,
    set_servers/2,
    toggle_server/3,
    reconnect_server/2,
    unregister_server/2,
    register_session_registry/2,
    get_session_registry/1,
    update_session_registry/2,
    unregister_session_registry/1,
    ensure_registry_table/0
]).

-export_type([
    tool_handler/0,
    content_result/0,
    tool_def/0,
    sdk_mcp_server/0,
    mcp_registry/0
]).

-type tool_handler() :: beam_agent_mcp_core:tool_handler().
-type content_result() :: beam_agent_mcp_core:content_result().
-type tool_def() :: beam_agent_mcp_core:tool_def().
-type sdk_mcp_server() :: beam_agent_mcp_core:sdk_mcp_server().
-type mcp_registry() :: beam_agent_mcp_core:mcp_registry().

tool(Name, Description, InputSchema, Handler) ->
    beam_agent_mcp_core:tool(Name, Description, InputSchema, Handler).
server(Name, Tools) -> beam_agent_mcp_core:server(Name, Tools).
server(Name, Tools, Version) -> beam_agent_mcp_core:server(Name, Tools, Version).
new_registry() -> beam_agent_mcp_core:new_registry().
register_server(Server, Registry) -> beam_agent_mcp_core:register_server(Server, Registry).
server_names(Registry) -> beam_agent_mcp_core:server_names(Registry).
servers_for_cli(Registry) -> beam_agent_mcp_core:servers_for_cli(Registry).
servers_for_init(Registry) -> beam_agent_mcp_core:servers_for_init(Registry).
handle_mcp_message(SessionId, Message, Registry) ->
    beam_agent_mcp_core:handle_mcp_message(SessionId, Message, Registry).
handle_mcp_message(SessionId, Message, Registry, Timeout) ->
    beam_agent_mcp_core:handle_mcp_message(SessionId, Message, Registry, Timeout).
call_tool_by_name(SessionId, Name, Input) -> beam_agent_mcp_core:call_tool_by_name(SessionId, Name, Input).
call_tool_by_name(SessionId, Name, Input, Timeout) ->
    beam_agent_mcp_core:call_tool_by_name(SessionId, Name, Input, Timeout).
all_tool_definitions(Registry) -> beam_agent_mcp_core:all_tool_definitions(Registry).
build_registry(Opts) -> beam_agent_mcp_core:build_registry(Opts).
server_status(SessionId) -> beam_agent_mcp_core:server_status(SessionId).
set_servers(SessionId, Servers) -> beam_agent_mcp_core:set_servers(SessionId, Servers).
toggle_server(SessionId, ServerName, Enabled) ->
    beam_agent_mcp_core:toggle_server(SessionId, ServerName, Enabled).
reconnect_server(SessionId, ServerName) ->
    beam_agent_mcp_core:reconnect_server(SessionId, ServerName).
unregister_server(SessionId, ServerName) ->
    beam_agent_mcp_core:unregister_server(SessionId, ServerName).
register_session_registry(SessionId, Registry) ->
    beam_agent_mcp_core:register_session_registry(SessionId, Registry).
get_session_registry(SessionId) -> beam_agent_mcp_core:get_session_registry(SessionId).
update_session_registry(SessionId, Registry) ->
    beam_agent_mcp_core:update_session_registry(SessionId, Registry).
unregister_session_registry(SessionId) -> beam_agent_mcp_core:unregister_session_registry(SessionId).
ensure_registry_table() -> beam_agent_mcp_core:ensure_registry_table().
