-module(beam_agent_mcp).
-compile([nowarn_missing_spec]).
-moduledoc """
Public wrapper for in-process MCP support inside `beam_agent`.

This module re-exports the MCP tool registry and dispatch APIs from
`beam_agent_mcp_core`, and provides access to the MCP protocol layer
(`beam_agent_mcp_protocol`), full-spec server dispatch (`beam_agent_mcp_dispatch`),
and client-side dispatch (`beam_agent_mcp_client_dispatch`).
""".

-export([
    %% Tool registry (beam_agent_mcp_core)
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
    ensure_registry_table/0,

    %% Protocol (beam_agent_mcp_protocol)
    protocol_version/0,

    %% Full-spec server dispatch (beam_agent_mcp_dispatch)
    new_dispatch/3,
    dispatch_message/2,
    dispatch_lifecycle_state/1,
    dispatch_session_capabilities/1,

    %% Client-side dispatch (beam_agent_mcp_client_dispatch)
    new_client/3,
    client_lifecycle_state/1,
    client_server_capabilities/1,
    client_session_capabilities/1,
    client_send_initialize/1,
    client_send_ping/1,
    client_send_tools_list/1,
    client_send_tools_list/2,
    client_send_tools_call/3,
    client_send_resources_list/1,
    client_send_resources_list/2,
    client_send_resources_read/2,
    client_send_resources_templates_list/1,
    client_send_resources_templates_list/2,
    client_send_resources_subscribe/2,
    client_send_resources_unsubscribe/2,
    client_send_prompts_list/1,
    client_send_prompts_list/2,
    client_send_prompts_get/2,
    client_send_prompts_get/3,
    client_send_completion_complete/3,
    client_send_completion_complete/4,
    client_send_logging_set_level/2,
    client_send_request/3,
    client_send_cancelled/2,
    client_send_cancelled/3,
    client_send_progress/3,
    client_send_progress/4,
    client_send_progress/5,
    client_send_roots_list_changed/1,
    client_handle_message/2,
    client_check_timeouts/2,
    client_pending_count/1
]).

-export_type([
    tool_handler/0,
    content_result/0,
    tool_def/0,
    sdk_mcp_server/0,
    mcp_registry/0,
    dispatch_state/0,
    client_state/0,
    client_result/0,
    timed_out_request/0
]).

-type tool_handler() :: beam_agent_mcp_core:tool_handler().
-type content_result() :: beam_agent_mcp_core:content_result().
-type tool_def() :: beam_agent_mcp_core:tool_def().
-type sdk_mcp_server() :: beam_agent_mcp_core:sdk_mcp_server().
-type mcp_registry() :: beam_agent_mcp_core:mcp_registry().
-type dispatch_state() :: beam_agent_mcp_dispatch:dispatch_state().
-type client_state() :: beam_agent_mcp_client_dispatch:client_state().
-type client_result() :: beam_agent_mcp_client_dispatch:client_result().
-type timed_out_request() :: beam_agent_mcp_client_dispatch:timed_out_request().

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

%%--------------------------------------------------------------------
%% Protocol (beam_agent_mcp_protocol)
%%--------------------------------------------------------------------

protocol_version() -> beam_agent_mcp_protocol:protocol_version().

%%--------------------------------------------------------------------
%% Full-spec server dispatch (beam_agent_mcp_dispatch)
%%--------------------------------------------------------------------

new_dispatch(ServerInfo, ServerCaps, Opts) ->
    beam_agent_mcp_dispatch:new(ServerInfo, ServerCaps, Opts).
dispatch_message(Msg, State) ->
    beam_agent_mcp_dispatch:handle_message(Msg, State).
dispatch_lifecycle_state(State) ->
    beam_agent_mcp_dispatch:lifecycle_state(State).
dispatch_session_capabilities(State) ->
    beam_agent_mcp_dispatch:session_capabilities(State).

%%--------------------------------------------------------------------
%% Client-side dispatch (beam_agent_mcp_client_dispatch)
%%--------------------------------------------------------------------

new_client(ClientInfo, ClientCaps, Opts) ->
    beam_agent_mcp_client_dispatch:new(ClientInfo, ClientCaps, Opts).
client_lifecycle_state(State) ->
    beam_agent_mcp_client_dispatch:lifecycle_state(State).
client_server_capabilities(State) ->
    beam_agent_mcp_client_dispatch:server_capabilities(State).
client_session_capabilities(State) ->
    beam_agent_mcp_client_dispatch:session_capabilities(State).
client_send_initialize(State) ->
    beam_agent_mcp_client_dispatch:send_initialize(State).
client_send_ping(State) ->
    beam_agent_mcp_client_dispatch:send_ping(State).
client_send_tools_list(State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(State).
client_send_tools_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(Cursor, State).
client_send_tools_call(ToolName, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_tools_call(ToolName, Arguments, State).
client_send_resources_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(State).
client_send_resources_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(Cursor, State).
client_send_resources_read(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_read(Uri, State).
client_send_resources_templates_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(State).
client_send_resources_templates_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(Cursor, State).
client_send_resources_subscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_subscribe(Uri, State).
client_send_resources_unsubscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_unsubscribe(Uri, State).
client_send_prompts_list(State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(State).
client_send_prompts_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(Cursor, State).
client_send_prompts_get(Name, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, State).
client_send_prompts_get(Name, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, Arguments, State).
client_send_completion_complete(Ref, Argument, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, State).
client_send_completion_complete(Ref, Argument, Context, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, Context, State).
client_send_logging_set_level(Level, State) ->
    beam_agent_mcp_client_dispatch:send_logging_set_level(Level, State).
client_send_request(Method, Params, State) ->
    beam_agent_mcp_client_dispatch:send_request(Method, Params, State).
client_send_cancelled(RequestId, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, State).
client_send_cancelled(RequestId, Reason, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, Reason, State).
client_send_progress(Token, Progress, State) ->
    beam_agent_mcp_client_dispatch:send_progress(Token, Progress, State).
client_send_progress(Token, Progress, Total, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, State).
client_send_progress(Token, Progress, Total, Message, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, Message, State).
client_send_roots_list_changed(State) ->
    beam_agent_mcp_client_dispatch:send_roots_list_changed(State).
client_handle_message(Msg, State) ->
    beam_agent_mcp_client_dispatch:handle_message(Msg, State).
client_check_timeouts(Now, State) ->
    beam_agent_mcp_client_dispatch:check_timeouts(Now, State).
client_pending_count(State) ->
    beam_agent_mcp_client_dispatch:pending_count(State).
