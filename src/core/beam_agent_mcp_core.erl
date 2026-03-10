-module(beam_agent_mcp_core).
-moduledoc """
In-process MCP server support for the BEAM Agent SDK.

Enables users to define custom tools as Erlang functions that
Claude can call in-process via the mcp_message control request
protocol. Cross-referenced against TS SDK v0.2.66
createSdkMcpServer() and Python SDK create_sdk_mcp_server().

Usage:
```erlang
Tool = beam_agent_mcp_core:tool(<<"greet">>, <<"Greet a user">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end),
Server = beam_agent_mcp_core:server(<<"my-tools">>, [Tool]),
%% Pass to session:
claude_agent_session:start_link(#{sdk_mcp_servers => [Server]})
```
""".

-export([
    %% Constructors
    tool/4,
    server/2,
    server/3,
    %% Registry management
    new_registry/0,
    register_server/2,
    server_names/1,
    %% CLI integration
    servers_for_cli/1,
    servers_for_init/1,
    %% JSON-RPC dispatch
    handle_mcp_message/3,
    handle_mcp_message/4,
    %% Flat tool dispatch (no server context)
    call_tool_by_name/3,
    call_tool_by_name/4,
    all_tool_definitions/1,
    %% Convenience: build registry from session opts
    build_registry/1,
    %% Runtime management (universal features)
    server_status/1,
    set_servers/2,
    toggle_server/3,
    reconnect_server/2,
    unregister_server/2,
    %% Session-scoped registry (ETS-backed for universal access)
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

%% new_registry/0 returns #{} typed as mcp_registry() (intentional supertype).
%% format_content/1 returns specific key binaries, spec uses binary() (intentional).
-dialyzer({nowarn_function, [new_registry/0, format_content/1]}).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Handler function invoked when Claude calls an in-process tool.
%% Receives the tool arguments map, returns content results or error.
-type tool_handler() :: fun((map()) ->
    {ok, [content_result()]} | {error, binary()}).

%% Content result from a tool handler.
-type content_result() :: #{type := text, text := binary()}
                        | #{type := image, data := binary(),
                            mime_type := binary()}.

%% Tool definition with name, description, JSON schema, and handler.
-type tool_def() :: #{
    name := binary(),
    description := binary(),
    input_schema := map(),
    handler := tool_handler()
}.

%% An SDK MCP server grouping one or more tools under a name.
-type sdk_mcp_server() :: #{
    name := binary(),
    version => binary(),
    tools := [tool_def()]
}.

%% Registry mapping server names to their definitions.
-type mcp_registry() :: #{binary() => sdk_mcp_server()}.

%% Default tool handler timeout (30 seconds).
-define(DEFAULT_HANDLER_TIMEOUT, 30000).

%%--------------------------------------------------------------------
%% Constructors
%%--------------------------------------------------------------------

-doc "Create a tool definition.".
-spec tool(binary(), binary(), map(), tool_handler()) -> tool_def().
tool(Name, Description, InputSchema, Handler)
  when is_binary(Name), is_binary(Description),
       is_map(InputSchema), is_function(Handler, 1) ->
    #{name => Name, description => Description,
      input_schema => InputSchema, handler => Handler}.

-doc "Create an SDK MCP server with default version \"1.0.0\".".
-spec server(binary(), [tool_def()]) -> sdk_mcp_server().
server(Name, Tools) ->
    server(Name, Tools, <<"1.0.0">>).

-doc "Create an SDK MCP server with explicit version.".
-spec server(binary(), [tool_def()], binary()) -> sdk_mcp_server().
server(Name, Tools, Version)
  when is_binary(Name), is_list(Tools), is_binary(Version) ->
    #{name => Name, tools => Tools, version => Version}.

%%--------------------------------------------------------------------
%% Registry Management
%%--------------------------------------------------------------------

-doc "Create an empty MCP server registry.".
-spec new_registry() -> mcp_registry().
new_registry() -> #{}.

-doc "Register an SDK MCP server in the registry.".
-spec register_server(sdk_mcp_server(), mcp_registry()) -> mcp_registry().
register_server(#{name := Name} = Server, Registry) ->
    Registry#{Name => Server}.

-doc "Get the list of server names in the registry.".
-spec server_names(mcp_registry()) -> [binary()].
server_names(Registry) ->
    maps:keys(Registry).

%%--------------------------------------------------------------------
%% CLI Integration
%%--------------------------------------------------------------------

-doc """
Build the --mcp-config JSON map for CLI invocation.

Produces the wire format expected by Claude Code CLI:
`#{<<"mcpServers">> => #{Name => #{<<"type">> => <<"sdk">>, <<"name">> => Name}}}`
""".
-spec servers_for_cli(mcp_registry()) -> map().
servers_for_cli(Registry) ->
    ServerConfigs = maps:fold(fun(Name, _Server, Acc) ->
        Acc#{Name => #{<<"type">> => <<"sdk">>, <<"name">> => Name}}
    end, #{}, Registry),
    #{<<"mcpServers">> => ServerConfigs}.

-doc "Build the sdkMcpServers list for the initialize control_request.".
-spec servers_for_init(mcp_registry()) -> [binary()].
servers_for_init(Registry) ->
    maps:keys(Registry).

%%--------------------------------------------------------------------
%% JSON-RPC Dispatch
%%--------------------------------------------------------------------

-doc "Handle an MCP JSON-RPC message for a named server. Uses default handler timeout of 30 seconds.".
-spec handle_mcp_message(binary(), map(), mcp_registry()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry) ->
    handle_mcp_message(ServerName, Message, Registry, #{}).

-doc """
Handle an MCP JSON-RPC message for a named server with options.

Dispatches to the appropriate handler based on the method.

Options:
  - `handler_timeout` -- timeout in ms for tool handlers (default: 30000)

Supported methods:
  - `"initialize"` -- capabilities + server info
  - `"notifications/initialized"` -- no-op acknowledgment
  - `"tools/list"` -- tool definitions in MCP format
  - `"tools/call"` -- execute handler, wrap result
  - unknown -- JSON-RPC -32601 error
""".
-spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry, Opts) ->
    case maps:find(ServerName, Registry) of
        {ok, #{enabled := false}} ->
            {error, <<"MCP server disabled: ", ServerName/binary>>};
        {ok, Server} ->
            Timeout = maps:get(handler_timeout, Opts, ?DEFAULT_HANDLER_TIMEOUT),
            dispatch_jsonrpc(Message, Server, Timeout);
        error ->
            {error, <<"Unknown MCP server: ", ServerName/binary>>}
    end.

%%--------------------------------------------------------------------
%% Flat Tool Dispatch
%%--------------------------------------------------------------------

-doc "Call a tool by name, searching across all servers in the registry. Uses default handler timeout of 30 seconds.".
-spec call_tool_by_name(binary(), map(), mcp_registry()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry) ->
    call_tool_by_name(ToolName, Arguments, Registry, #{}).

-doc """
Call a tool by name with options.

Searches across all servers in the registry.
Used by adapters that receive flat tool calls without server context
(e.g. Copilot `tool.call`, Codex MCP dispatch).

Options:
  - `handler_timeout` -- timeout in ms for tool handlers (default: 30000)
""".
-spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry, Opts) ->
    Timeout = maps:get(handler_timeout, Opts, ?DEFAULT_HANDLER_TIMEOUT),
    case find_tool_in_registry(ToolName, Registry) of
        {ok, #{handler := Handler}} ->
            call_handler(Handler, Arguments, Timeout);
        error ->
            {error, <<"Unknown tool: ", ToolName/binary>>}
    end.

-doc "Get all tool definitions from the registry, flattened across servers. Useful for advertising available tools during session setup.".
-spec all_tool_definitions(mcp_registry()) -> [tool_def()].
all_tool_definitions(Registry) ->
    lists:append(maps:fold(fun(_Name, #{tools := Tools}, Acc) ->
        [Tools | Acc]
    end, [], Registry)).

%%--------------------------------------------------------------------
%% Convenience: Build Registry from Session Opts
%%--------------------------------------------------------------------

-doc """
Build an MCP registry from a list of SDK MCP server definitions.

Returns `undefined` when no servers are configured (empty list
or `undefined`). Used by all adapter session modules during init.
""".
-spec build_registry([sdk_mcp_server()] | undefined) ->
    mcp_registry() | undefined.
build_registry(undefined) -> undefined;
build_registry([]) -> undefined;
build_registry(Servers) when is_list(Servers) ->
    lists:foldl(fun(S, Reg) ->
        register_server(S, Reg)
    end, new_registry(), Servers).

%%--------------------------------------------------------------------
%% Runtime Management (Universal Features)
%%--------------------------------------------------------------------

-doc """
Get status of all registered MCP servers.

Returns a map of server name to status info (name, version,
tool count, enabled state).
""".
-spec server_status(mcp_registry() | undefined) ->
    {ok, #{binary() => map()}}.
server_status(undefined) ->
    {ok, #{}};
server_status(Registry) when is_map(Registry) ->
    Status = maps:map(fun(Name, Server) ->
        Tools = maps:get(tools, Server, []),
        Enabled = maps:get(enabled, Server, true),
        Version = maps:get(version, Server, <<"1.0.0">>),
        #{
            name => Name,
            version => Version,
            tool_count => length(Tools),
            enabled => Enabled
        }
    end, Registry),
    {ok, Status}.

-doc """
Replace the entire server registry with new servers.

Returns the new registry. Existing servers not in the new
list are removed.
""".
-spec set_servers([sdk_mcp_server()], mcp_registry() | undefined) ->
    mcp_registry().
set_servers(Servers, _OldRegistry) when is_list(Servers) ->
    build_registry(Servers);
set_servers(_, OldRegistry) ->
    OldRegistry.

-doc """
Enable or disable an MCP server by name.

Returns the updated registry. Disabled servers are retained
but excluded from dispatch.
""".
-spec toggle_server(binary(), boolean(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
toggle_server(_Name, _Enabled, undefined) ->
    {error, not_found};
toggle_server(Name, Enabled, Registry)
  when is_binary(Name), is_boolean(Enabled), is_map(Registry) ->
    case maps:find(Name, Registry) of
        {ok, Server} ->
            Updated = Server#{enabled => Enabled},
            {ok, Registry#{Name => Updated}};
        error ->
            {error, not_found}
    end.

-doc """
Reconnect (re-register) an MCP server by name.

Resets the server's state by re-inserting it into the registry.
In practice this clears any cached state the server may hold.
""".
-spec reconnect_server(binary(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
reconnect_server(_Name, undefined) ->
    {error, not_found};
reconnect_server(Name, Registry)
  when is_binary(Name), is_map(Registry) ->
    case maps:find(Name, Registry) of
        {ok, Server} ->
            %% Reset enabled state and re-insert
            Reconnected = Server#{enabled => true},
            {ok, Registry#{Name => Reconnected}};
        error ->
            {error, not_found}
    end.

-doc "Remove an MCP server from the registry by name.".
-spec unregister_server(binary(), mcp_registry()) -> mcp_registry().
unregister_server(Name, Registry)
  when is_binary(Name), is_map(Registry) ->
    maps:remove(Name, Registry).

%%--------------------------------------------------------------------
%% Session-Scoped Registry (ETS-backed)
%%--------------------------------------------------------------------

%% ETS table for session-scoped MCP registries.
-define(SESSION_REGISTRY_TABLE, beam_agent_mcp_registries).

-doc "Ensure the session registry ETS table exists. Idempotent.".
-spec ensure_registry_table() -> ok.
ensure_registry_table() ->
    case ets:whereis(?SESSION_REGISTRY_TABLE) of
        undefined ->
            try
                _ = ets:new(?SESSION_REGISTRY_TABLE,
                    [set, public, named_table, {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.

-doc """
Register an MCP registry for a session (keyed by session pid).

Called by adapters during session init to make their MCP
registry accessible for runtime management.
""".
-spec register_session_registry(pid(), mcp_registry() | undefined) -> ok.
register_session_registry(_Pid, undefined) -> ok;
register_session_registry(Pid, Registry)
  when is_pid(Pid), is_map(Registry) ->
    ensure_registry_table(),
    ets:insert(?SESSION_REGISTRY_TABLE, {Pid, Registry}),
    ok.

-doc "Get the MCP registry for a session by pid.".
-spec get_session_registry(pid()) ->
    {ok, mcp_registry()} | {error, not_found}.
get_session_registry(Pid) when is_pid(Pid) ->
    ensure_registry_table(),
    case ets:lookup(?SESSION_REGISTRY_TABLE, Pid) of
        [{_, Registry}] -> {ok, Registry};
        [] -> {error, not_found}
    end.

-doc """
Update the MCP registry for a session.

Uses a fun to transform the existing registry atomically.
""".
-spec update_session_registry(pid(),
    fun((mcp_registry()) -> mcp_registry())) -> ok | {error, not_found}.
update_session_registry(Pid, UpdateFun)
  when is_pid(Pid), is_function(UpdateFun, 1) ->
    ensure_registry_table(),
    case ets:lookup(?SESSION_REGISTRY_TABLE, Pid) of
        [{_, Registry}] ->
            Updated = UpdateFun(Registry),
            ets:insert(?SESSION_REGISTRY_TABLE, {Pid, Updated}),
            ok;
        [] ->
            {error, not_found}
    end.

-doc "Remove a session's MCP registry (called on session termination).".
-spec unregister_session_registry(pid()) -> ok.
unregister_session_registry(Pid) when is_pid(Pid) ->
    ensure_registry_table(),
    ets:delete(?SESSION_REGISTRY_TABLE, Pid),
    ok.

%%--------------------------------------------------------------------
%% Internal: JSON-RPC Method Dispatch
%%--------------------------------------------------------------------

-spec dispatch_jsonrpc(map(), sdk_mcp_server(), pos_integer()) -> {ok, map()}.
dispatch_jsonrpc(#{<<"method">> := <<"initialize">>} = Msg, Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Version = maps:get(version, Server, <<"1.0.0">>),
    Name = maps:get(name, Server),
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{
            <<"protocolVersion">> => beam_agent_mcp_protocol:protocol_version(),
            <<"capabilities">> => #{<<"tools">> => #{}},
            <<"serverInfo">> => #{
                <<"name">> => Name,
                <<"version">> => Version
            }
        }
    }};

dispatch_jsonrpc(#{<<"method">> := <<"notifications/initialized">>}, _Server, _Timeout) ->
    %% No response needed for notifications, return empty ack
    {ok, #{}};

dispatch_jsonrpc(#{<<"method">> := <<"tools/list">>} = Msg, Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Tools = maps:get(tools, Server, []),
    ToolDefs = [tool_to_mcp_format(T) || T <- Tools],
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{<<"tools">> => ToolDefs}
    }};

dispatch_jsonrpc(#{<<"method">> := <<"tools/call">>} = Msg, Server, Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Params = maps:get(<<"params">>, Msg, #{}),
    ToolName = maps:get(<<"name">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Tools = maps:get(tools, Server, []),
    case find_tool(ToolName, Tools) of
        {ok, #{handler := Handler}} ->
            case call_handler(Handler, Arguments, Timeout) of
                {ok, ContentResults} ->
                    {ok, #{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => #{
                            <<"content">> =>
                                [format_content(C) || C <- ContentResults]
                        }
                    }};
                {error, Reason} ->
                    {ok, #{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => #{
                            <<"content">> => [#{
                                <<"type">> => <<"text">>,
                                <<"text">> => Reason
                            }],
                            <<"isError">> => true
                        }
                    }}
            end;
        error ->
            {ok, #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => Id,
                <<"error">> => #{
                    <<"code">> => -32602,
                    <<"message">> =>
                        <<"Unknown tool: ", ToolName/binary>>
                }
            }}
    end;

dispatch_jsonrpc(Msg, _Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Method = maps:get(<<"method">>, Msg, <<"unknown">>),
    MethodBin = if is_binary(Method) -> Method; true -> <<"unknown">> end,
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => -32601,
            <<"message">> =>
                <<"Method not found: ", MethodBin/binary>>
        }
    }}.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

%% Convert a tool_def to MCP wire format for tools/list.
-spec tool_to_mcp_format(tool_def()) -> map().
tool_to_mcp_format(#{name := Name, description := Desc,
                      input_schema := Schema}) ->
    #{<<"name">> => Name,
      <<"description">> => Desc,
      <<"inputSchema">> => Schema}.

%% Find a tool by name in the tools list.
-spec find_tool(binary(), [tool_def()]) -> {ok, tool_def()} | error.
find_tool(_Name, []) -> error;
find_tool(Name, [#{name := Name} = Tool | _]) -> {ok, Tool};
find_tool(Name, [_ | Rest]) -> find_tool(Name, Rest).

%% Find a tool by name across all servers in the registry.
-spec find_tool_in_registry(binary(), mcp_registry()) -> {ok, tool_def()} | error.
find_tool_in_registry(ToolName, Registry) ->
    maps:fold(fun
        (_ServerName, #{enabled := false}, Acc) ->
            Acc;
        (_ServerName, #{tools := Tools}, error) ->
            find_tool(ToolName, Tools);
        (_ServerName, _Server, {ok, _} = Found) ->
            Found
    end, error, Registry).

%% Execute a tool handler with crash protection and configurable timeout.
%% Spawns a monitored process to isolate handler crashes from
%% the gen_statem.
-spec call_handler(tool_handler(), map(), pos_integer()) ->
    {ok, [content_result()]} | {error, binary()}.
call_handler(Handler, Input, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Result = try Handler(Input) of
            R -> R
        catch
            Class:Reason:Stack ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("Handler ~p:~p~n~p",
                                  [Class, Reason, Stack])),
                {error, ErrMsg}
        end,
        Self ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, iolist_to_binary(
                io_lib:format("Handler crashed: ~p", [Reason]))}
    after Timeout ->
        demonitor(MRef, [flush]),
        exit(Pid, kill),
        %% Flush any result message sent before the kill took effect
        receive {Ref, _} -> ok after 0 -> ok end,
        TimeoutSecs = Timeout div 1000,
        {error, iolist_to_binary(
            io_lib:format("Tool handler timed out after ~B seconds", [TimeoutSecs]))}
    end.

%% Format a content_result for the MCP wire protocol.
-spec format_content(content_result()) -> #{binary() => binary()}.
format_content(#{type := text, text := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_content(#{type := image, data := Data, mime_type := MimeType}) ->
    #{<<"type">> => <<"image">>, <<"data">> => Data,
      <<"mimeType">> => MimeType}.
