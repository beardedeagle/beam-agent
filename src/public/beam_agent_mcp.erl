-module(beam_agent_mcp).
-moduledoc """
Public API for in-process MCP (Model Context Protocol) support inside `beam_agent`.

MCP is an open protocol that lets AI sessions discover and call structured tools,
read resources, and retrieve prompt templates. Instead of embedding tool logic
inside prompts, you define tools as Erlang functions and register them with a
session — the backend calls them in-process over a well-defined JSON-RPC 2.0
wire format.

## For newcomers: defining and registering tools

A tool is a named Erlang function the AI can call. You build tools with
`tool/4`, group them into a server with `server/2`, and pass the server to
the session at startup:

```erlang
%% 1. Define a tool
GreetTool = beam_agent_mcp:tool(
    <<"greet">>,
    <<"Greet a user by name">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"name">> => #{<<"type">> => <<"string">>}
      }},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end
),

%% 2. Group into a named MCP server
MyServer = beam_agent_mcp:server(<<"my-tools">>, [GreetTool]),

%% 3. Register at session start
{ok, Session} = beam_agent:start_session(#{
    backend          => claude,
    sdk_mcp_servers  => [MyServer]
}).
```

## The 4 subsystems

This module re-exports from four underlying core modules:

### 1. Tool registry (beam_agent_tool_registry)

Manages named MCP servers and their tools within a session. Each session keeps
its own `mcp_registry()` — a map from server name to server definition. Key
functions: `tool/4`, `server/2,3`, `new_registry/0`, `build_registry/1`,
`register_server/2`, `server_names/1`, `call_tool_by_name/3,4`,
`all_tool_definitions/1`, `handle_mcp_message/3,4`.

Runtime management (toggle, reconnect, unregister) is also here:
`toggle_server/3`, `reconnect_server/2`, `unregister_server/2`, `set_servers/2`.

Session-scoped ETS registry (for cross-process access): `register_session_registry/2`,
`get_session_registry/1`, `update_session_registry/2`, `unregister_session_registry/1`,
`ensure_registry_table/0`.

### 2. Protocol (beam_agent_mcp_protocol)

Pure functions for MCP spec 2025-06-18. Only one function is re-exported:
`protocol_version/0` which returns the version string.

### 3. Server-side dispatch (beam_agent_mcp_dispatch)

Full MCP server state machine. Use `new_dispatch/3` to create server state,
`dispatch_message/2` to process incoming JSON-RPC messages, and the inspector
functions `dispatch_lifecycle_state/1`, `dispatch_session_capabilities/1` to
observe server state.

```erlang
ServerInfo = #{name => <<"my-server">>, version => <<"1.0.0">>},
ServerCaps = #{tools => #{}},
State0 = beam_agent_mcp:new_dispatch(ServerInfo, ServerCaps, #{}),
{Reply, State1} = beam_agent_mcp:dispatch_message(InitMsg, State0).
```

### 4. Client-side dispatch (beam_agent_mcp_client_dispatch)

Full MCP client state machine. Use `new_client/3` to create client state, then
drive the MCP handshake and method calls:

```erlang
ClientInfo = #{name => <<"my-client">>, version => <<"1.0.0">>},
ClientCaps = #{roots => #{listChanged => true}},
State0 = beam_agent_mcp:new_client(ClientInfo, ClientCaps, #{}),

%% Drive the initialize handshake
{InitMsg, State1} = beam_agent_mcp:client_send_initialize(State0),
%% ... send InitMsg over transport, receive response ...
{ok, State2} = beam_agent_mcp:client_handle_message(ServerInitResponse, State1),
{AckMsg, State3} = beam_agent_mcp:client_send_initialized(State2),

%% List tools
{ListMsg, State4} = beam_agent_mcp:client_send_tools_list(State3),
%% ... send ListMsg, receive response ...
{ok, State5} = beam_agent_mcp:client_handle_message(ToolsListResponse, State4).
```

## Core concepts

MCP (Model Context Protocol) is a standard for connecting AI tools. It
lets you define Erlang functions that the AI agent can call during a
conversation. You wrap functions as tools, group tools into servers,
and register servers with a session.

This module handles both sides of MCP. The server side (your tools that
the agent calls) uses tool/4 to define tools and server/2 to group them.
The client side (connecting to external tool providers) uses new_client/3
and the client_send_* functions to drive the MCP handshake.

The wire protocol is JSON-RPC 2.0 -- structured request/response messages.
You do not need to handle the protocol directly; the dispatch and client
state machines manage it for you.

## Architecture deep dive

This module re-exports from four core modules: beam_agent_tool_registry
(tool and server management), beam_agent_mcp_protocol (wire format),
beam_agent_mcp_dispatch (server-side state machine), and
beam_agent_mcp_client_dispatch (client-side state machine).

The server-side dispatch runs inside the session engine process as a
nested state machine (dispatch_state). The client-side dispatch is a
separate state machine (client_state) for outbound MCP connections.
Both follow JSON-RPC 2.0 with the MCP spec 2025-06-18 extensions.

Tool registration populates catalog ETS tables via
register_session_registry/2. The registry table allows cross-process
access so transports and universal fallback handlers can look up tools
without holding a reference to the session process state.

## Architecture: session-scoped ETS registries

Each session process registers its `mcp_registry()` in a global ETS table via
`register_session_registry/2`. This allows other processes (e.g. the transport
layer, universal fallback handlers) to look up and atomically update the session
registry without holding a reference to the session process state directly.
The table is initialised once via `ensure_registry_table/0`, called during
application startup.
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

-doc """
Handler function type for in-process MCP tools.

A `tool_handler()` is a 1-arity fun that receives the tool's input arguments as
a map and returns either `{ok, [content_result()]}` on success or
`{error, Reason}` on failure.

```erlang
Handler = fun(Input) ->
    Value = maps:get(<<"x">>, Input, 0),
    {ok, [#{type => text, text => integer_to_binary(Value * 2)}]}
end.
```
""".
-type tool_handler() :: beam_agent_tool_registry:tool_handler().

-doc """
Content result returned by a tool handler.

Either a text result `#{type => text, text => binary()}` or an image result
`#{type => image, data => binary(), mime_type => binary()}`.
""".
-type content_result() :: beam_agent_tool_registry:content_result().

-doc """
A complete tool definition map as produced by `tool/4`.

Contains `name`, `description`, `input_schema` (a JSON Schema map), and
`handler` (the `tool_handler()` fun).
""".
-type tool_def() :: beam_agent_tool_registry:tool_def().

-doc """
An SDK MCP server grouping one or more tools under a name.

Contains `name`, `tools`, and optionally `version`.
""".
-type sdk_mcp_server() :: beam_agent_tool_registry:sdk_mcp_server().

-doc """
A registry mapping server name binaries to their `sdk_mcp_server()` definitions.

Constructed via `new_registry/0` or `build_registry/1`.
""".
-type mcp_registry() :: beam_agent_tool_registry:mcp_registry().

-doc """
Opaque state record for the MCP server-side dispatch state machine.

Holds pending request tracking, the tool registry, and sequencing
state across calls to dispatch_message/2. Callers must not inspect
or construct this value directly -- use new_dispatch_state/1 to
obtain an initial value and pass it through successive dispatch calls.
""".
-type dispatch_state() :: beam_agent_mcp_dispatch:dispatch_state().

-doc """
Result type from `dispatch_message/2`.

Typically `{Response, NewState}` where `Response` is a JSON-RPC map to send
back over the transport, or `{noreply, NewState}` for notifications that
require no response.
""".
-type dispatch_result() :: beam_agent_mcp_dispatch:dispatch_result().

-doc """
Opaque state record for the MCP client-side dispatch state machine.

Holds the pending-request map (request ID to caller), the next
request ID counter, and timeout configuration across calls to
client_handle_message/2. Callers must not inspect or construct this
value directly -- use new_client_state/1 to obtain an initial value
and pass it through successive client dispatch calls.
""".
-type client_state() :: beam_agent_mcp_client_dispatch:client_state().

-doc """
Result type from `client_handle_message/2`.

Either `{ok, NewState}` when the message was processed successfully, or
`{error, Reason, NewState}` when the server reported an error.
""".
-type client_result() :: beam_agent_mcp_client_dispatch:client_result().

-doc """
Describes a request that timed out in the client pending-request queue.

Contains at minimum the request ID and the method name. Returned from
`client_check_timeouts/2`.
""".
-type timed_out_request() :: beam_agent_mcp_client_dispatch:timed_out_request().

%%====================================================================
%% Tool Registry (beam_agent_tool_registry)
%%====================================================================

-doc """
Create a tool definition for use in an in-process MCP server.

Parameters:
- `Name` — unique tool name binary, e.g. `<<"search_files">>`
- `Description` — human-readable description shown to the AI
- `InputSchema` — JSON Schema map describing the tool's input object
- `Handler` — `tool_handler()` fun invoked when the AI calls the tool

```erlang
Tool = beam_agent_mcp:tool(
    <<"read_file">>,
    <<"Read the contents of a file">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"path">> => #{<<"type">> => <<"string">>}
      },
      <<"required">> => [<<"path">>]},
    fun(#{<<"path">> := Path}) ->
        case file:read_file(Path) of
            {ok, Bin} -> {ok, [#{type => text, text => Bin}]};
            {error, R} -> {error, atom_to_binary(R)}
        end
    end
).
```
""".
-spec tool(binary(), binary(), map(), tool_handler()) -> tool_def().
tool(Name, Description, InputSchema, Handler) ->
    beam_agent_tool_registry:tool(Name, Description, InputSchema, Handler).

-doc """
Create a named MCP server containing a list of tool definitions.

Uses default version `<<"1.0.0">>`. Pass the returned `sdk_mcp_server()` in
the `sdk_mcp_servers` option when starting a session, or register it at runtime
with `register_server/2`.

```erlang
Server = beam_agent_mcp:server(<<"file-tools">>, [ReadFileTool, ListDirTool]).
```
""".
-spec server(binary(), [tool_def()]) -> sdk_mcp_server().
server(Name, Tools) ->
    beam_agent_tool_registry:server(Name, Tools).

-doc """
Create a named MCP server with an explicit version string.

Use this variant when the backend or client requires a specific server version
for capability negotiation.

```erlang
Server = beam_agent_mcp:server(<<"file-tools">>, [Tool], <<"2.1.0">>).
```
""".
-spec server(binary(), [tool_def()], binary()) -> sdk_mcp_server().
server(Name, Tools, Version) ->
    beam_agent_tool_registry:server(Name, Tools, Version).

-doc """
Create a new empty MCP registry.

An `mcp_registry()` is a map from server-name binary to `sdk_mcp_server()`.
Use `register_server/2` to add servers, or `build_registry/1` to construct
one directly from a list of servers.

```erlang
Registry = beam_agent_mcp:new_registry().
```
""".
-spec new_registry() -> mcp_registry().
new_registry() ->
    beam_agent_tool_registry:new_registry().

-doc """
Add a server to a registry, returning the updated registry.

If a server with the same name already exists it is replaced.

```erlang
R0 = beam_agent_mcp:new_registry(),
R1 = beam_agent_mcp:register_server(MyServer, R0).
```
""".
-spec register_server(sdk_mcp_server(), mcp_registry()) -> mcp_registry().
register_server(Server, Registry) ->
    beam_agent_tool_registry:register_server(Server, Registry).

-doc """
Return the list of server name binaries registered in a registry.
""".
-spec server_names(mcp_registry()) -> [binary()].
server_names(Registry) ->
    beam_agent_tool_registry:server_names(Registry).

-doc """
Project the registry into the CLI-integration format expected by backend adapters.

Returns a map suitable for passing as the `mcp_servers` field in CLI invocation
opts. Internal use by session handlers.
""".
-spec servers_for_cli(mcp_registry()) -> map().
servers_for_cli(Registry) ->
    beam_agent_tool_registry:servers_for_cli(Registry).

-doc """
Return the list of server name binaries to advertise in the MCP initialize handshake.

Internal use by session handlers during the MCP initialization sequence.
""".
-spec servers_for_init(mcp_registry()) -> [binary()].
servers_for_init(Registry) ->
    beam_agent_tool_registry:servers_for_init(Registry).

-doc """
Dispatch an incoming MCP JSON-RPC message to the named server in the registry.

`ServerName` identifies which in-process server should handle the message.
`Message` is a decoded JSON-RPC map (e.g. a `tools/call` request). Returns
`{ok, ResponseMap}` or `{error, Reason}`.

This is the core dispatch used by session handlers when they receive an
`mcp_message` control request from the backend.
""".
-spec handle_mcp_message(binary(), map(), mcp_registry()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry) ->
    beam_agent_tool_registry:handle_mcp_message(ServerName, Message, Registry).

-doc """
Dispatch an MCP JSON-RPC message with additional call options.

`Opts` may include a `timeout` key controlling the maximum handler execution
time in milliseconds (default: 30 000 ms).
""".
-spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry, Opts) ->
    beam_agent_tool_registry:handle_mcp_message(ServerName, Message, Registry, Opts).

-doc """
Call a tool by name across all servers in the registry.

Searches all registered servers for a tool matching `ToolName` and invokes its
handler with `Arguments`. Returns `{ok, [content_result()]}` on success.

Returns `{error, <<"tool not found">>}` if no server in the registry has a
tool with that name.
""".
-spec call_tool_by_name(binary(), map(), mcp_registry()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry) ->
    beam_agent_tool_registry:call_tool_by_name(ToolName, Arguments, Registry).

-doc """
Call a tool by name with additional options.

Same as `call_tool_by_name/3` but accepts an `Opts` map (e.g. `#{timeout => 5000}`).
""".
-spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry, Opts) ->
    beam_agent_tool_registry:call_tool_by_name(ToolName, Arguments, Registry, Opts).

-doc """
Return the flat list of all tool definitions across all servers in the registry.

Useful for building a `tools/list` MCP response or for inspecting what tools
are available in a given session.
""".
-spec all_tool_definitions(mcp_registry()) -> [tool_def()].
all_tool_definitions(Registry) ->
    beam_agent_tool_registry:all_tool_definitions(Registry).

-doc """
Build an `mcp_registry()` from a list of servers, or return `undefined`.

Accepts either a list of `sdk_mcp_server()` values or `undefined`. Returns
`undefined` when the input is `undefined`. This is the canonical way to
construct a registry from the `sdk_mcp_servers` session option.

```erlang
Registry = beam_agent_mcp:build_registry([Server1, Server2]).
```
""".
-spec build_registry([sdk_mcp_server()] | undefined) -> mcp_registry() | undefined.
build_registry(Servers) ->
    beam_agent_tool_registry:build_registry(Servers).

-doc """
Return a status map for every server in the registry.

Returns `{ok, #{ServerName => StatusMap}}` where each `StatusMap` describes
the server's current state (e.g. enabled/disabled, tool count). Pass
`undefined` to get `{ok, #{}}`.
""".
-spec server_status(mcp_registry() | undefined) -> {ok, #{binary() => map()}}.
server_status(Registry) ->
    beam_agent_tool_registry:server_status(Registry).

-doc """
Replace the full set of servers in a registry.

Merges new servers over the old registry, preserving runtime state
(enabled/disabled flags) for servers that existed before. Returns the updated
registry.
""".
-spec set_servers([sdk_mcp_server()], mcp_registry() | undefined) -> mcp_registry().
set_servers(Servers, OldRegistry) ->
    beam_agent_tool_registry:set_servers(Servers, OldRegistry).

-doc """
Enable or disable a named server in the registry at runtime.

`Name` is the server name binary. `Enabled` is `true` to enable or `false` to
disable. Returns `{ok, UpdatedRegistry}` or `{error, not_found}`.
""".
-spec toggle_server(binary(), boolean(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
toggle_server(Name, Enabled, Registry) ->
    beam_agent_tool_registry:toggle_server(Name, Enabled, Registry).

-doc """
Mark a named server as reconnected in the registry.

Resets any error state on the server entry. Returns `{ok, UpdatedRegistry}` or
`{error, not_found}`.
""".
-spec reconnect_server(binary(), mcp_registry() | undefined) ->
    {ok, mcp_registry()} | {error, not_found}.
reconnect_server(Name, Registry) ->
    beam_agent_tool_registry:reconnect_server(Name, Registry).

-doc """
Remove a named server from the registry.

Returns the updated registry with the named server entry deleted. No-ops if
the server is not present.
""".
-spec unregister_server(binary(), mcp_registry()) -> mcp_registry().
unregister_server(Name, Registry) ->
    beam_agent_tool_registry:unregister_server(Name, Registry).

-doc """
Store a session's MCP registry in the global ETS session registry table.

Associates `Registry` (or `undefined`) with the session `Pid` so that other
processes can retrieve it via `get_session_registry/1` without holding a
reference to the session process state.

Called by session handlers during session initialisation.
""".
-spec register_session_registry(pid(), mcp_registry() | undefined) -> ok.
register_session_registry(Pid, Registry) ->
    beam_agent_tool_registry:register_session_registry(Pid, Registry).

-doc """
Retrieve the MCP registry for a session from the global ETS table.

Returns `{ok, Registry}` if the session is registered, or
`{error, not_found}` if no entry exists for `Pid`.
""".
-spec get_session_registry(pid()) -> {ok, mcp_registry()} | {error, not_found}.
get_session_registry(Pid) ->
    beam_agent_tool_registry:get_session_registry(Pid).

-doc """
Atomically update the MCP registry for a session in the ETS table.

Applies `UpdateFun` to the current registry and stores the result. This is the
safe way to add or modify servers while the session is running. Returns `ok` on
success or `{error, not_found}` if the session is not registered.

```erlang
ok = beam_agent_mcp:update_session_registry(Pid, fun(Reg) ->
    beam_agent_mcp:register_server(NewServer, Reg)
end).
```
""".
-spec update_session_registry(pid(),
    fun((mcp_registry()) -> mcp_registry())) -> ok | {error, not_found}.
update_session_registry(Pid, UpdateFun) ->
    beam_agent_tool_registry:update_session_registry(Pid, UpdateFun).

-doc """
Remove the MCP registry entry for a session from the global ETS table.

Called by session handlers during termination to clean up ETS state.
""".
-spec unregister_session_registry(pid()) -> ok.
unregister_session_registry(Pid) ->
    beam_agent_tool_registry:unregister_session_registry(Pid).

-doc """
Ensure the global ETS session-registry table exists, creating it if necessary.

This is idempotent and safe to call multiple times. Call it once during
application startup (or OTP supervisor init) before any sessions are started.
""".
-spec ensure_registry_table() -> ok.
ensure_registry_table() ->
    beam_agent_tool_registry:ensure_registry_table().

%%====================================================================
%% Protocol (beam_agent_mcp_protocol)
%%====================================================================

-doc """
Return the MCP protocol version string this SDK implements.

Returns a binary such as `<<"2025-06-18">>`. Used during the MCP
`initialize` handshake to advertise protocol compatibility.
""".
-spec protocol_version() -> <<_:80>>.
protocol_version() ->
    beam_agent_mcp_protocol:protocol_version().

%%====================================================================
%% Full-spec server dispatch (beam_agent_mcp_dispatch)
%%====================================================================

-doc """
Create a new MCP server-side dispatch state machine.

Parameters:
- `ServerInfo` — implementation info map, e.g. `#{name => <<"srv">>, version => <<"1.0">>}`
- `ServerCaps` — server capabilities map, e.g. `#{tools => #{}, resources => #{}}`
- `Opts` — additional options (pass `#{}` for defaults)

Returns an opaque `dispatch_state()` to be threaded through `dispatch_message/2`.

```erlang
State = beam_agent_mcp:new_dispatch(
    #{name => <<"my-server">>, version => <<"1.0.0">>},
    #{tools => #{}},
    #{}
).
```
""".
-spec new_dispatch(beam_agent_mcp_protocol:implementation_info(),
                   map(), map()) -> dispatch_state().
new_dispatch(ServerInfo, ServerCaps, Opts) ->
    beam_agent_mcp_dispatch:new(ServerInfo, ServerCaps, Opts).

-doc """
Process an incoming JSON-RPC message through the MCP server dispatch state machine.

`Msg` is a decoded JSON-RPC map received from the client. Returns a
`dispatch_result()` which is typically `{ResponseMap, NewState}` for requests
or `{noreply, NewState}` for notifications.

Thread `NewState` into the next `dispatch_message/2` call.
""".
-spec dispatch_message(map(), dispatch_state()) -> dispatch_result().
dispatch_message(Msg, State) ->
    beam_agent_mcp_dispatch:handle_message(Msg, State).

-doc """
Return the current lifecycle state of the server dispatch state machine.

Returns an atom such as `uninitialized`, `initializing`, or `ready`.
""".
-spec dispatch_lifecycle_state(dispatch_state()) -> atom().
dispatch_lifecycle_state(State) ->
    beam_agent_mcp_dispatch:lifecycle_state(State).

-doc """
Return the negotiated session capabilities from the server dispatch state.

Returns the capabilities map that was agreed upon during the MCP initialize
handshake. Only meaningful after the handshake completes (lifecycle `ready`).
""".
-spec dispatch_session_capabilities(dispatch_state()) -> map().
dispatch_session_capabilities(State) ->
    beam_agent_mcp_dispatch:session_capabilities(State).

%%====================================================================
%% Client-side dispatch (beam_agent_mcp_client_dispatch)
%%====================================================================

-doc """
Create a new MCP client-side dispatch state machine.

Parameters:
- `ClientInfo` — implementation info map, e.g. `#{name => <<"my-client">>, version => <<"1.0.0">>}`
- `ClientCaps` — client capabilities map, e.g. `#{roots => #{listChanged => true}}`
- `Opts` — additional options (pass `#{}` for defaults)

Returns an opaque `client_state()`. Drive the MCP handshake by calling
`client_send_initialize/1` next.

```erlang
State = beam_agent_mcp:new_client(
    #{name => <<"beam-agent-client">>, version => <<"1.0.0">>},
    #{roots => #{}},
    #{}
).
```
""".
-spec new_client(beam_agent_mcp_protocol:implementation_info(),
                 map(), map()) -> client_state().
new_client(ClientInfo, ClientCaps, Opts) ->
    beam_agent_mcp_client_dispatch:new(ClientInfo, ClientCaps, Opts).

-doc """
Return the current lifecycle state of the MCP client dispatch state machine.

Returns an atom such as `uninitialized`, `initializing`, or `ready`.
""".
-spec client_lifecycle_state(client_state()) -> atom().
client_lifecycle_state(State) ->
    beam_agent_mcp_client_dispatch:lifecycle_state(State).

-doc """
Return the server capabilities advertised by the MCP server during the handshake.

Only meaningful after the initialize/initialized handshake completes.
""".
-spec client_server_capabilities(client_state()) -> map().
client_server_capabilities(State) ->
    beam_agent_mcp_client_dispatch:server_capabilities(State).

-doc """
Return the negotiated session capabilities from the client state.

These are the capabilities agreed upon during the MCP handshake.
""".
-spec client_session_capabilities(client_state()) -> map().
client_session_capabilities(State) ->
    beam_agent_mcp_client_dispatch:session_capabilities(State).

-doc """
Build and return an MCP `initialize` request message.

This is the first message to send in the MCP handshake. Returns `{Msg, NewState}`
where `Msg` is the JSON-RPC map to send over the transport.
""".
-spec client_send_initialize(client_state()) -> {map(), client_state()}.
client_send_initialize(State) ->
    beam_agent_mcp_client_dispatch:send_initialize(State).

-doc """
Build and return an MCP `initialized` notification message.

Send this after receiving a successful `initialize` response from the server.
Returns `{Msg, NewState}`.
""".
-spec client_send_initialized(client_state()) -> {map(), client_state()}.
client_send_initialized(State) ->
    beam_agent_mcp_client_dispatch:send_initialized(State).

-doc """
Build and return an MCP `ping` request message.

Use to verify the server connection is alive. Returns `{Msg, NewState}`.
""".
-spec client_send_ping(client_state()) -> {map(), client_state()}.
client_send_ping(State) ->
    beam_agent_mcp_client_dispatch:send_ping(State).

-doc """
Build and return a `tools/list` request (no cursor, first page).

Returns `{Msg, NewState}`.
""".
-spec client_send_tools_list(client_state()) -> {map(), client_state()}.
client_send_tools_list(State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(State).

-doc """
Build and return a `tools/list` request with a pagination cursor.

Pass `Cursor` from a previous `tools/list` response to fetch the next page.
Returns `{Msg, NewState}`.
""".
-spec client_send_tools_list(beam_agent_mcp_protocol:cursor(),
                             client_state()) -> {map(), client_state()}.
client_send_tools_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_tools_list(Cursor, State).

-doc """
Build and return a `tools/call` request.

Parameters:
- `ToolName` — name of the tool to invoke
- `Arguments` — map of input arguments matching the tool's JSON Schema
- `State` — current client state

Returns `{Msg, NewState}` where `Msg` is the JSON-RPC request to send.
""".
-spec client_send_tools_call(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_tools_call(ToolName, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_tools_call(ToolName, Arguments, State).

-doc """
Build and return a `resources/list` request (no cursor, first page).
""".
-spec client_send_resources_list(client_state()) -> {map(), client_state()}.
client_send_resources_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(State).

-doc """
Build and return a `resources/list` request with a pagination cursor.
""".
-spec client_send_resources_list(beam_agent_mcp_protocol:cursor(),
                                 client_state()) -> {map(), client_state()}.
client_send_resources_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_list(Cursor, State).

-doc """
Build and return a `resources/read` request for a specific resource URI.
""".
-spec client_send_resources_read(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_read(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_read(Uri, State).

-doc """
Build and return a `resources/templates/list` request (no cursor).
""".
-spec client_send_resources_templates_list(client_state()) ->
    {map(), client_state()}.
client_send_resources_templates_list(State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(State).

-doc """
Build and return a `resources/templates/list` request with a pagination cursor.
""".
-spec client_send_resources_templates_list(beam_agent_mcp_protocol:cursor(),
                                           client_state()) ->
    {map(), client_state()}.
client_send_resources_templates_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_resources_templates_list(Cursor, State).

-doc """
Build and return a `resources/subscribe` request for a resource URI.

Subscribe to change notifications for the resource at `Uri`.
""".
-spec client_send_resources_subscribe(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_subscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_subscribe(Uri, State).

-doc """
Build and return a `resources/unsubscribe` request for a resource URI.
""".
-spec client_send_resources_unsubscribe(binary(), client_state()) ->
    {map(), client_state()}.
client_send_resources_unsubscribe(Uri, State) ->
    beam_agent_mcp_client_dispatch:send_resources_unsubscribe(Uri, State).

-doc """
Build and return a `prompts/list` request (no cursor).
""".
-spec client_send_prompts_list(client_state()) -> {map(), client_state()}.
client_send_prompts_list(State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(State).

-doc """
Build and return a `prompts/list` request with a pagination cursor.
""".
-spec client_send_prompts_list(beam_agent_mcp_protocol:cursor(),
                               client_state()) -> {map(), client_state()}.
client_send_prompts_list(Cursor, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_list(Cursor, State).

-doc """
Build and return a `prompts/get` request by prompt name (no arguments).
""".
-spec client_send_prompts_get(binary(), client_state()) ->
    {map(), client_state()}.
client_send_prompts_get(Name, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, State).

-doc """
Build and return a `prompts/get` request with template arguments.

`Arguments` is a map of variable bindings for the prompt template.
""".
-spec client_send_prompts_get(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_prompts_get(Name, Arguments, State) ->
    beam_agent_mcp_client_dispatch:send_prompts_get(Name, Arguments, State).

-doc """
Build and return a `completion/complete` request (no context).

`Ref` identifies the completion reference (prompt or resource URI).
`Argument` is the argument map with the partial value to complete.
""".
-spec client_send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                                      map(), client_state()) ->
    {map(), client_state()}.
client_send_completion_complete(Ref, Argument, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, State).

-doc """
Build and return a `completion/complete` request with context.

`Context` is an optional map of additional context for the completion.
""".
-spec client_send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                                      map(), map(), client_state()) ->
    {map(), client_state()}.
client_send_completion_complete(Ref, Argument, Context, State) ->
    beam_agent_mcp_client_dispatch:send_completion_complete(
        Ref, Argument, Context, State).

-doc """
Build and return a `logging/setLevel` request.

`Level` is one of the MCP log level atoms such as `debug`, `info`, `warning`,
or `error`.
""".
-spec client_send_logging_set_level(beam_agent_mcp_protocol:log_level(),
                                    client_state()) ->
    {map(), client_state()}.
client_send_logging_set_level(Level, State) ->
    beam_agent_mcp_client_dispatch:send_logging_set_level(Level, State).

-doc """
Build and return an arbitrary MCP request by method name.

Use this for MCP methods not covered by the typed send functions. `Method` is
the JSON-RPC method string and `Params` is the params map.
""".
-spec client_send_request(binary(), map(), client_state()) ->
    {map(), client_state()}.
client_send_request(Method, Params, State) ->
    beam_agent_mcp_client_dispatch:send_request(Method, Params, State).

-doc """
Build and return a `cancelled` notification for a pending request (no reason).

`RequestId` is the ID of the in-flight request to cancel.
""".
-spec client_send_cancelled(beam_agent_mcp_protocol:request_id(),
                            client_state()) -> {map(), client_state()}.
client_send_cancelled(RequestId, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, State).

-doc """
Build and return a `cancelled` notification with a human-readable reason.
""".
-spec client_send_cancelled(beam_agent_mcp_protocol:request_id(), binary(),
                            client_state()) -> {map(), client_state()}.
client_send_cancelled(RequestId, Reason, State) ->
    beam_agent_mcp_client_dispatch:send_cancelled(RequestId, Reason, State).

-doc """
Build and return a `progress` notification (progress value only).

`Token` is the progress token from the original request.
`Progress` is the current progress value (0.0–1.0 or an absolute count).
""".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, State) ->
    beam_agent_mcp_client_dispatch:send_progress(Token, Progress, State).

-doc """
Build and return a `progress` notification with a total value.

`Total` is the total work units, allowing clients to display a percentage.
""".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), number(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, Total, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, State).

-doc """
Build and return a `progress` notification with total and a status message.

`Message` is a human-readable binary describing the current step.
""".
-spec client_send_progress(beam_agent_mcp_protocol:progress_token(),
                           number(), number(), binary(), client_state()) ->
    {map(), client_state()}.
client_send_progress(Token, Progress, Total, Message, State) ->
    beam_agent_mcp_client_dispatch:send_progress(
        Token, Progress, Total, Message, State).

-doc """
Build and return a `roots/list_changed` notification.

Send this when the client's root list has changed so the server can re-fetch it.
""".
-spec client_send_roots_list_changed(client_state()) ->
    {map(), client_state()}.
client_send_roots_list_changed(State) ->
    beam_agent_mcp_client_dispatch:send_roots_list_changed(State).

-doc """
Process an incoming JSON-RPC message from the MCP server through the client state machine.

`Msg` is a decoded map received from the server (a response or notification).
Returns `{ok, NewState}` on success. For error responses the result type
carries the error detail. Thread `NewState` into the next call.
""".
-spec client_handle_message(map(), client_state()) -> client_result().
client_handle_message(Msg, State) ->
    beam_agent_mcp_client_dispatch:handle_message(Msg, State).

-doc """
Check for timed-out pending requests and purge them from the client state.

`Now` is a monotonic timestamp (e.g. from `erlang:monotonic_time(millisecond)`).
Returns `{TimedOutList, NewState}` where `TimedOutList` is a list of
`timed_out_request()` values for requests that exceeded their deadline.

Call this periodically (e.g. from a `{timeout, N, check_timeouts}` gen_statem
event) to clean up stale pending requests.
""".
-spec client_check_timeouts(integer(), client_state()) ->
    {[timed_out_request()], client_state()}.
client_check_timeouts(Now, State) ->
    beam_agent_mcp_client_dispatch:check_timeouts(Now, State).

-doc """
Return the number of pending (in-flight) requests in the client state.

A non-zero count means there are requests awaiting responses from the server.
""".
-spec client_pending_count(client_state()) -> non_neg_integer().
client_pending_count(State) ->
    beam_agent_mcp_client_dispatch:pending_count(State).
