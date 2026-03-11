-module(beam_agent_mcp).
-moduledoc """
Public wrapper for in-process MCP support inside `beam_agent`.

This module re-exports the MCP tool registry and dispatch APIs from
`beam_agent_tool_registry`, and provides access to the MCP protocol layer
(`beam_agent_mcp_protocol`), full-spec server dispatch (`beam_agent_mcp_dispatch`),
and client-side dispatch (`beam_agent_mcp_client_dispatch`).
""".

-export([
    %% Tool registry (beam_agent_tool_registry)
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
    client_send_initialized/1,
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
    dispatch_result/0,
    client_state/0,
    client_result/0,
    timed_out_request/0
]).

-type tool_handler() :: beam_agent_tool_registry:tool_handler().
-type content_result() :: beam_agent_tool_registry:content_result().
-type tool_def() :: beam_agent_tool_registry:tool_def().
-type sdk_mcp_server() :: beam_agent_tool_registry:sdk_mcp_server().
-type mcp_registry() :: beam_agent_tool_registry:mcp_registry().
-type dispatch_state() :: beam_agent_mcp_dispatch:dispatch_state().
-type dispatch_result() :: beam_agent_mcp_dispatch:dispatch_result().
-type client_state() :: beam_agent_mcp_client_dispatch:client_state().
-type client_result() :: beam_agent_mcp_client_dispatch:client_result().
-type timed_out_request() :: beam_agent_mcp_client_dispatch:timed_out_request().

%%====================================================================
%% Tool Registry (beam_agent_tool_registry)
%%====================================================================

-doc "See `beam_agent_tool_registry:tool/4`.".
-spec tool(binary(), binary(), map(), tool_handler()) -> tool_def().
tool(Name, Description, InputSchema, Handler) ->
    beam_agent_tool_registry:tool(Name, Description, InputSchema, Handler).

-doc "See `beam_agent_tool_registry:server/2`.".
-spec server(binary(), [tool_def()]) -> sdk_mcp_server().
server(Name, Tools) ->
    beam_agent_tool_registry:server(Name, Tools).

-doc "See `beam_agent_tool_registry:server/3`.".
-spec server(binary(), [tool_def()], binary()) -> sdk_mcp_server().
server(Name, Tools, Version) ->
    beam_agent_tool_registry:server(Name, Tools, Version).

-doc "See `beam_agent_tool_registry:new_registry/0`.".
-spec new_registry() -> mcp_registry().
new_registry() ->
    beam_agent_tool_registry:new_registry().

-doc "See `beam_agent_tool_registry:register_server/2`.".
-spec register_server(sdk_mcp_server(), mcp_registry()) -> mcp_registry().
register_server(Server, Registry) ->
    beam_agent_tool_registry:register_server(Server, Registry).

-doc "See `beam_agent_tool_registry:server_names/1`.".
-spec server_names(mcp_registry()) -> [binary()].
server_names(Registry) ->
    beam_agent_tool_registry:server_names(Registry).

-doc "See `beam_agent_tool_registry:servers_for_cli/1`.".
-spec servers_for_cli(mcp_registry()) -> map().
servers_for_cli(Registry) ->
    beam_agent_tool_registry:servers_for_cli(Registry).

-doc "See `beam_agent_tool_registry:servers_for_init/1`.".
-spec servers_for_init(mcp_registry()) -> [binary()].
servers_for_init(Registry) ->
    beam_agent_tool_registry:servers_for_init(Registry).

-doc "See `beam_agent_tool_registry:handle_mcp_message/3`.".
-spec handle_mcp_message(binary(), map(), mcp_registry()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry) ->
    beam_agent_tool_registry:handle_mcp_message(ServerName, Message, Registry).

-doc "See `beam_agent_tool_registry:handle_mcp_message/4`.".
-spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry, Opts) ->
    beam_agent_tool_registry:handle_mcp_message(ServerName, Message, Registry, Opts).

-doc "See `beam_agent_tool_registry:call_tool_by_name/3`.".
-spec call_tool_by_name(binary(), map(), mcp_registry()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry) ->
    beam_agent_tool_registry:call_tool_by_name(ToolName, Arguments, Registry).

-doc "See `beam_agent_tool_registry:call_tool_by_name/4`.".
-spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry, Opts) ->
    beam_agent_tool_registry:call_tool_by_name(ToolName, Arguments, Registry, Opts).

-doc "See `beam_agent_tool_registry:all_tool_definitions/1`.".
-spec all_tool_definitions(mcp_registry()) -> [tool_def()].
all_tool_definitions(Registry) ->
    beam_agent_tool_registry:all_tool_definitions(Registry).

-doc "See `beam_agent_tool_registry:build_registry/1`.".
-spec build_registry([sdk_mcp_server()] | undefined) -> mcp_registry() | undefined.
build_registry(Servers) ->
    beam_agent_tool_registry:build_registry(Servers).

-doc "See `beam_agent_tool_registry:server_status/1`.".
-spec server_status(mcp_registry() | undefined) -> {ok, #{binary() => map()}}.
server_status(Registry) ->
    beam_agent_tool_registry:server_status(Registry).

-doc "See `beam_agent_tool_registry:set_servers/2`.".
-spec set_servers([sdk_mcp_server()], mcp_registry() | undefined) -> mcp_registry().
set_servers(Servers, OldRegistry) ->
    beam_agent_tool_registry:set_servers(Servers, OldRegistry).

-doc "See `beam_agent_tool_registry:toggle_server/3`.".
-spec toggle_server(binary(), boolean(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
toggle_server(Name, Enabled, Registry) ->
    beam_agent_tool_registry:toggle_server(Name, Enabled, Registry).

-doc "See `beam_agent_tool_registry:reconnect_server/2`.".
-spec reconnect_server(binary(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
reconnect_server(Name, Registry) ->
    beam_agent_tool_registry:reconnect_server(Name, Registry).

-doc "See `beam_agent_tool_registry:unregister_server/2`.".
-spec unregister_server(binary(), mcp_registry()) -> mcp_registry().
unregister_server(Name, Registry) ->
    beam_agent_tool_registry:unregister_server(Name, Registry).

-doc "See `beam_agent_tool_registry:register_session_registry/2`.".
-spec register_session_registry(pid(), mcp_registry() | undefined) -> ok.
register_session_registry(Pid, Registry) ->
    beam_agent_tool_registry:register_session_registry(Pid, Registry).

-doc "See `beam_agent_tool_registry:get_session_registry/1`.".
-spec get_session_registry(pid()) -> {ok, mcp_registry()} | {error, not_found}.
get_session_registry(Pid) ->
    beam_agent_tool_registry:get_session_registry(Pid).

-doc "See `beam_agent_tool_registry:update_session_registry/2`.".
-spec update_session_registry(pid(),
    fun((mcp_registry()) -> mcp_registry())) -> ok | {error, not_found}.
update_session_registry(Pid, UpdateFun) ->
    beam_agent_tool_registry:update_session_registry(Pid, UpdateFun).

-doc "See `beam_agent_tool_registry:unregister_session_registry/1`.".
-spec unregister_session_registry(pid()) -> ok.
unregister_session_registry(Pid) ->
    beam_agent_tool_registry:unregister_session_registry(Pid).

-doc "See `beam_agent_tool_registry:ensure_registry_table/0`.".
-spec ensure_registry_table() -> ok.
ensure_registry_table() ->
    beam_agent_tool_registry:ensure_registry_table().

%%====================================================================
%% Protocol (beam_agent_mcp_protocol)
%%====================================================================

-doc "See `beam_agent_mcp_protocol:protocol_version/0`.".
-spec protocol_version() -> binary().
protocol_version() ->
    beam_agent_mcp_protocol:protocol_version().

%%====================================================================
%% Full-spec server dispatch (beam_agent_mcp_dispatch)
%%====================================================================

-doc "See `beam_agent_mcp_dispatch:new/3`.".
-spec new_dispatch(beam_agent_mcp_protocol:implementation_info(),
                   map(), map()) -> dispatch_state().
new_dispatch(ServerInfo, ServerCaps, Opts) ->
    beam_agent_mcp_dispatch:new(ServerInfo, ServerCaps, Opts).

-doc "See `beam_agent_mcp_dispatch:handle_message/2`.".
-spec dispatch_message(map(), dispatch_state()) -> dispatch_result().
dispatch_message(Msg, State) ->
    beam_agent_mcp_dispatch:handle_message(Msg, State).

-doc "See `beam_agent_mcp_dispatch:lifecycle_state/1`.".
-spec dispatch_lifecycle_state(dispatch_state()) -> atom().
dispatch_lifecycle_state(State) ->
    beam_agent_mcp_dispatch:lifecycle_state(State).

-doc "See `beam_agent_mcp_dispatch:session_capabilities/1`.".
-spec dispatch_session_capabilities(dispatch_state()) -> map().
dispatch_session_capabilities(State) ->
    beam_agent_mcp_dispatch:session_capabilities(State).

%%====================================================================
%% Client-side dispatch (beam_agent_mcp_client_dispatch)
%%====================================================================

-doc "See `beam_agent_mcp_client_dispatch:new/3`.".
-spec new_client(beam_agent_mcp_protocol:implementation_info(),
                 map(), map()) -> client_state().
new_client(ClientInfo, ClientCaps, Opts) ->
    beam_agent_mcp_client_dispatch:new(ClientInfo, ClientCaps, Opts).

-doc "See `beam_agent_mcp_client_dispatch:lifecycle_state/1`.".
-spec client_lifecycle_state(client_state()) -> atom().
client_lifecycle_state(State) ->
    beam_agent_mcp_client_dispatch:lifecycle_state(State).

-doc "See `beam_agent_mcp_client_dispatch:server_capabilities/1`.".
-spec client_server_capabilities(client_state()) -> map().
client_server_capabilities(State) ->
    beam_agent_mcp_client_dispatch:server_capabilities(State).

-doc "See `beam_agent_mcp_client_dispatch:session_capabilities/1`.".
-spec client_session_capabilities(client_state()) -> map().
client_session_capabilities(State) ->
    beam_agent_mcp_client_dispatch:session_capabilities(State).

-doc "See `beam_agent_mcp_client_dispatch:send_initialize/1`.".
-spec client_send_initialize(client_state()) -> {map(), client_state()}.
client_send_initialize(State) ->
    beam_agent_mcp_client_dispatch:send_initialize(State).

-doc "See `beam_agent_mcp_client_dispatch:send_initialized/1`.".
-spec client_send_initialized(client_state()) -> {map(), client_state()}.
client_send_initialized(State) ->
    beam_agent_mcp_client_dispatch:send_initialized(State).

-doc "See `beam_agent_mcp_client_dispatch:send_ping/1`.".
-spec client_send_ping(client_state()) -> {map(), client_state()}.
client_send_ping(State) ->
    beam_agent_mcp_client_dispatch:send_ping(State).

-doc "See `beam_agent_mcp_client_dispatch:send_tools_list/1`.".
-spec client_send_tools_list(client_state()) -> {map(), client_state()}.
client_send_tools_list(State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(State).

-doc "See `beam_agent_mcp_client_dispatch:send_tools_list/2`.".
-spec client_send_tools_list(beam_agent_mcp_protocol:cursor(),
                             client_state()) -> {map(), client_state()}.
client_send_tools_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(Cursor, State).

-doc "See `beam_agent_mcp_client_dispatch:send_tools_call/3`.".
-spec client_send_tools_call(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_tools_call(ToolName, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_tools_call(ToolName, Arguments, State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_list/1`.".
-spec client_send_resources_list(client_state()) -> {map(), client_state()}.
client_send_resources_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_list/2`.".
-spec client_send_resources_list(beam_agent_mcp_protocol:cursor(),
                                 client_state()) -> {map(), client_state()}.
client_send_resources_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(Cursor, State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_read/2`.".
-spec client_send_resources_read(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_read(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_read(Uri, State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_templates_list/1`.".
-spec client_send_resources_templates_list(client_state()) ->
    {map(), client_state()}.
client_send_resources_templates_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_templates_list/2`.".
-spec client_send_resources_templates_list(beam_agent_mcp_protocol:cursor(),
                                           client_state()) ->
    {map(), client_state()}.
client_send_resources_templates_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(Cursor, State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_subscribe/2`.".
-spec client_send_resources_subscribe(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_subscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_subscribe(Uri, State).

-doc "See `beam_agent_mcp_client_dispatch:send_resources_unsubscribe/2`.".
-spec client_send_resources_unsubscribe(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_unsubscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_unsubscribe(Uri, State).

-doc "See `beam_agent_mcp_client_dispatch:send_prompts_list/1`.".
-spec client_send_prompts_list(client_state()) -> {map(), client_state()}.
client_send_prompts_list(State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(State).

-doc "See `beam_agent_mcp_client_dispatch:send_prompts_list/2`.".
-spec client_send_prompts_list(beam_agent_mcp_protocol:cursor(),
                               client_state()) -> {map(), client_state()}.
client_send_prompts_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(Cursor, State).

-doc "See `beam_agent_mcp_client_dispatch:send_prompts_get/2`.".
-spec client_send_prompts_get(binary(), client_state()) ->
    {map(), client_state()}.
client_send_prompts_get(Name, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, State).

-doc "See `beam_agent_mcp_client_dispatch:send_prompts_get/3`.".
-spec client_send_prompts_get(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_prompts_get(Name, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, Arguments, State).

-doc "See `beam_agent_mcp_client_dispatch:send_completion_complete/3`.".
-spec client_send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                                      map(), client_state()) ->
    {map(), client_state()}.
client_send_completion_complete(Ref, Argument, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, State).

-doc "See `beam_agent_mcp_client_dispatch:send_completion_complete/4`.".
-spec client_send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                                      map(), map(), client_state()) ->
    {map(), client_state()}.
client_send_completion_complete(Ref, Argument, Context, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, Context, State).

-doc "See `beam_agent_mcp_client_dispatch:send_logging_set_level/2`.".
-spec client_send_logging_set_level(beam_agent_mcp_protocol:log_level(),
                                    client_state()) ->
    {map(), client_state()}.
client_send_logging_set_level(Level, State) ->
    beam_agent_mcp_client_dispatch:send_logging_set_level(Level, State).

-doc "See `beam_agent_mcp_client_dispatch:send_request/3`.".
-spec client_send_request(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_request(Method, Params, State) ->
    beam_agent_mcp_client_dispatch:send_request(Method, Params, State).

-doc "See `beam_agent_mcp_client_dispatch:send_cancelled/2`.".
-spec client_send_cancelled(beam_agent_mcp_protocol:request_id(),
                            client_state()) -> {map(), client_state()}.
client_send_cancelled(RequestId, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, State).

-doc "See `beam_agent_mcp_client_dispatch:send_cancelled/3`.".
-spec client_send_cancelled(beam_agent_mcp_protocol:request_id(), binary(),
                            client_state()) -> {map(), client_state()}.
client_send_cancelled(RequestId, Reason, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, Reason, State).

-doc "See `beam_agent_mcp_client_dispatch:send_progress/3`.".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, State) ->
    beam_agent_mcp_client_dispatch:send_progress(Token, Progress, State).

-doc "See `beam_agent_mcp_client_dispatch:send_progress/4`.".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), number(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, Total, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, State).

-doc "See `beam_agent_mcp_client_dispatch:send_progress/5`.".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), number(), binary(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, Total, Message, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, Message, State).

-doc "See `beam_agent_mcp_client_dispatch:send_roots_list_changed/1`.".
-spec client_send_roots_list_changed(client_state()) ->
    {map(), client_state()}.
client_send_roots_list_changed(State) ->
    beam_agent_mcp_client_dispatch:send_roots_list_changed(State).

-doc "See `beam_agent_mcp_client_dispatch:handle_message/2`.".
-spec client_handle_message(map(), client_state()) -> client_result().
client_handle_message(Msg, State) ->
    beam_agent_mcp_client_dispatch:handle_message(Msg, State).

-doc "See `beam_agent_mcp_client_dispatch:check_timeouts/2`.".
-spec client_check_timeouts(integer(), client_state()) ->
    {[timed_out_request()], client_state()}.
client_check_timeouts(Now, State) ->
    beam_agent_mcp_client_dispatch:check_timeouts(Now, State).

-doc "See `beam_agent_mcp_client_dispatch:pending_count/1`.".
-spec client_pending_count(client_state()) -> non_neg_integer().
client_pending_count(State) ->
    beam_agent_mcp_client_dispatch:pending_count(State).
