defmodule BeamAgent.MCP do
  @moduledoc """
  In-process MCP (Model Context Protocol) support for the BeamAgent SDK.

  MCP is an open protocol that lets AI sessions discover and call structured
  tools, read resources, and retrieve prompt templates. Instead of embedding tool
  logic inside prompts, you define tools as Elixir functions, group them into a
  named server, and pass the server to the session at startup — the backend calls
  them in-process over a well-defined JSON-RPC 2.0 wire format.

  ## When to use directly vs through `BeamAgent`

  Pass an MCP server via `:sdk_mcp_servers` in `BeamAgent.start_session/1` for
  normal usage. Use this module directly when you need to:
  - Build and inspect registries programmatically
  - Implement the full MCP server or client state machine (e.g. for a custom
    transport layer)
  - Toggle or reconnect servers at runtime

  ## Quick example — defining and registering tools

  ```elixir
  # 1. Define a tool
  greet_tool = BeamAgent.MCP.tool(
    "greet",
    "Greet a user by name",
    %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
    fn input ->
      name = Map.get(input, "name", "world")
      {:ok, [%{type: :text, text: "Hello, \#{name}!"}]}
    end
  )

  # 2. Group into a named MCP server
  my_server = BeamAgent.MCP.server("my-tools", [greet_tool])

  # 3. Register at session start
  {:ok, session} = BeamAgent.start_session(%{
    backend: :claude,
    sdk_mcp_servers: [my_server]
  })
  ```

  ## The 4 subsystems

  This module re-exports from four underlying core modules:

  ### 1. Tool registry (`beam_agent_tool_registry`)

  Manages named MCP servers and their tools within a session. Key functions:
  `tool/4`, `server/2,3`, `new_registry/0`, `build_registry/1`,
  `register_server/2`, `call_tool_by_name/3,4`, `all_tool_definitions/1`,
  `handle_mcp_message/3,4`.

  Runtime management: `toggle_server/3`, `reconnect_server/2`,
  `unregister_server/2`, `set_servers/2`.

  Session-scoped ETS registry: `register_session_registry/2`,
  `get_session_registry/1`, `update_session_registry/2`,
  `unregister_session_registry/1`, `ensure_registry_table/0`.

  ### 2. Protocol (`beam_agent_mcp_protocol`)

  Pure functions for MCP spec 2025-06-18. `protocol_version/0` returns the
  version string.

  ### 3. Server-side dispatch (`beam_agent_mcp_dispatch`)

  Full MCP server state machine. Use `new_dispatch/3` to create server state,
  `dispatch_message/2` to process incoming JSON-RPC messages.

  ```elixir
  state0 = BeamAgent.MCP.new_dispatch(
    %{name: "my-server", version: "1.0.0"},
    %{tools: %{}},
    %{}
  )
  {reply, state1} = BeamAgent.MCP.dispatch_message(init_msg, state0)
  ```

  ### 4. Client-side dispatch (`beam_agent_mcp_client_dispatch`)

  Full MCP client state machine. Drive the handshake and method calls:

  ```elixir
  state0 = BeamAgent.MCP.new_client(
    %{name: "beam-agent-client", version: "1.0.0"},
    %{roots: %{}},
    %{}
  )
  {init_msg, state1} = BeamAgent.MCP.client_send_initialize(state0)
  # ... send init_msg over transport, receive response ...
  {:ok, state2} = BeamAgent.MCP.client_handle_message(server_response, state1)
  {ack_msg, state3} = BeamAgent.MCP.client_send_initialized(state2)
  ```

  ## Architecture: session-scoped ETS registries

  Each session process registers its `mcp_registry()` in a global ETS table via
  `register_session_registry/2`. This allows other processes (e.g. the transport
  layer, universal fallback handlers) to look up and atomically update the session
  registry without holding a reference to the session process state directly. The
  table is initialised once via `ensure_registry_table/0` during application
  startup.
  """

  @typedoc """
  Handler function type for in-process MCP tools.

  A 1-arity function that receives the tool's input arguments as a map and
  returns `{:ok, [content_result()]}` on success or `{:error, reason}` on
  failure.

  ```elixir
  handler = fn input ->
    value = Map.get(input, "x", 0)
    {:ok, [%{type: :text, text: Integer.to_string(value * 2)}]}
  end
  ```
  """
  @type tool_handler() :: (map() -> {:ok, [content_result()]} | {:error, binary()})

  @typedoc """
  Content result returned by a tool handler.

  Either a text result `%{type: :text, text: binary()}` or an image result
  `%{type: :image, data: binary(), mime_type: binary()}`.
  """
  @type content_result() ::
          %{required(:type) => :text, required(:text) => binary()}
          | %{
              required(:type) => :image,
              required(:data) => binary(),
              required(:mime_type) => binary()
            }

  @typedoc """
  A complete tool definition map as produced by `tool/4`.

  Contains `:name`, `:description`, `:input_schema` (a JSON Schema map), and
  `:handler` (the `tool_handler()` function).
  """
  @type tool_def() :: %{
          required(:name) => binary(),
          required(:description) => binary(),
          required(:input_schema) => map(),
          required(:handler) => tool_handler()
        }

  @typedoc """
  An SDK MCP server grouping one or more tools under a name.

  Contains `:name`, `:tools`, and optionally `:version`.
  """
  @type sdk_mcp_server() :: %{
          required(:name) => binary(),
          optional(:version) => binary(),
          required(:tools) => [tool_def()]
        }

  @typedoc """
  A registry mapping server name binaries to their `sdk_mcp_server()` definitions.

  Constructed via `new_registry/0` or `build_registry/1`.
  """
  @type mcp_registry() :: %{binary() => sdk_mcp_server()}

  @typedoc "Opaque state record for the MCP server-side dispatch state machine."
  @type dispatch_state() :: %{
          required(:lifecycle) => :uninitialized | :initializing | :ready,
          required(:server_info) => implementation_info(),
          required(:server_capabilities) => map(),
          optional(:session_capabilities) => map(),
          optional(:tool_registry) => mcp_registry(),
          optional(:handler_timeout) => pos_integer(),
          optional(:provider) => module(),
          optional(:provider_state) => term()
        }

  @typedoc """
  Result type from `dispatch_message/2`.

  Typically `{response_map, new_state}` where `response_map` is a JSON-RPC map
  to send back over the transport, or `{:noreply, new_state}` for notifications
  that require no response.
  """
  @type dispatch_result() :: {map() | :noreply, dispatch_state()}

  @typedoc "Opaque state record for the MCP client-side dispatch state machine."
  @type client_state() :: %{
          required(:lifecycle) => :uninitialized | :initializing | :ready,
          required(:client_info) => implementation_info(),
          required(:client_capabilities) => map(),
          optional(:server_capabilities) => map(),
          optional(:session_capabilities) => map(),
          required(:next_id) => pos_integer(),
          required(:pending) => %{request_id() => pending_request()},
          required(:default_timeout) => pos_integer(),
          optional(:handler) => module(),
          optional(:handler_state) => term()
        }

  @typedoc """
  Result type from `client_handle_message/2`.

  Tagged tuple variants for different server message types:
  - `{:response, id, result, state}` — successful response
  - `{:error_response, id, code, message, state}` — error response
  - `{:server_request, msg, state}` — server-initiated request
  - `{:notification, method, params, state}` — server notification
  - `{:noreply, state}` — no reply needed
  """
  @type client_result() ::
          {:response, request_id(), term(), client_state()}
          | {:error_response, request_id(), integer(), binary(), client_state()}
          | {:server_request, map(), client_state()}
          | {:notification, binary(), map(), client_state()}
          | {:noreply, client_state()}

  @typedoc """
  Describes a request that timed out in the client pending-request queue.

  Contains at minimum the request ID and the method name. Returned from
  `client_check_timeouts/2`.
  """
  @type timed_out_request() :: %{
          required(:id) => request_id(),
          required(:method) => binary(),
          required(:sent_at) => integer()
        }

  @typedoc "MCP implementation info identifying a client or server."
  @type implementation_info() :: %{
          required(:name) => binary(),
          required(:version) => binary(),
          optional(:title) => binary()
        }

  @typedoc "A pending request awaiting a server response."
  @type pending_request() :: %{
          required(:method) => binary(),
          required(:deadline) => integer(),
          required(:sent_at) => integer()
        }

  @typedoc "MCP request identifier."
  @type request_id() :: binary() | integer() | nil

  @typedoc "MCP progress token."
  @type progress_token() :: binary() | integer()

  @typedoc "MCP completion reference."
  @type completion_ref() ::
          %{required(:type) => binary(), required(:name) => binary()}
          | %{required(:type) => binary(), required(:uri) => binary()}

  @typedoc "MCP log level."
  @type log_level() ::
          :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency

  # Tool registry — constructors

  @doc """
  Create a tool definition for use in an in-process MCP server.

  Parameters:
  - `name` — unique tool name binary, e.g. `"search_files"`
  - `description` — human-readable description shown to the AI
  - `input_schema` — JSON Schema map describing the tool's input object
  - `handler` — `tool_handler()` function invoked when the AI calls the tool

  ## Example

  ```elixir
  tool = BeamAgent.MCP.tool(
    "read_file",
    "Read the contents of a file",
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    },
    fn %{"path" => path} ->
      case File.read(path) do
        {:ok, bin} -> {:ok, [%{type: :text, text: bin}]}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  )
  ```
  """
  @spec tool(binary(), binary(), map(), tool_handler()) :: tool_def()
  defdelegate tool(name, description, input_schema, handler), to: :beam_agent_mcp

  @doc """
  Create a named MCP server containing a list of tool definitions.

  Uses default version `"1.0.0"`. Pass the returned `sdk_mcp_server()` in the
  `:sdk_mcp_servers` option when starting a session, or register it at runtime
  with `register_server/2`.

  ## Example

  ```elixir
  server = BeamAgent.MCP.server("file-tools", [read_file_tool, list_dir_tool])
  ```
  """
  @spec server(binary(), [tool_def()]) :: sdk_mcp_server()
  defdelegate server(name, tools), to: :beam_agent_mcp

  @doc """
  Create a named MCP server with an explicit version string.

  Use this variant when the backend or client requires a specific server version
  for capability negotiation.

  ## Example

  ```elixir
  server = BeamAgent.MCP.server("file-tools", [tool], "2.1.0")
  ```
  """
  @spec server(binary(), [tool_def()], binary()) :: sdk_mcp_server()
  defdelegate server(name, tools, version), to: :beam_agent_mcp

  # Tool registry — registry management

  @doc """
  Create a new empty MCP registry.

  An `mcp_registry()` is a map from server-name binary to `sdk_mcp_server()`.
  Use `register_server/2` to add servers, or `build_registry/1` to construct one
  directly from a list of servers.

  ## Example

  ```elixir
  registry = BeamAgent.MCP.new_registry()
  ```
  """
  @dialyzer {:nowarn_function, new_registry: 0}
  @spec new_registry() :: mcp_registry()
  defdelegate new_registry(), to: :beam_agent_mcp

  @doc """
  Add a server to a registry, returning the updated registry.

  If a server with the same name already exists it is replaced.

  ## Example

  ```elixir
  registry =
    BeamAgent.MCP.new_registry()
    |> BeamAgent.MCP.register_server(my_server)
  ```
  """
  @spec register_server(sdk_mcp_server(), mcp_registry()) :: mcp_registry()
  defdelegate register_server(server, registry), to: :beam_agent_mcp

  @doc """
  Return the list of server name binaries registered in a registry.
  """
  @spec server_names(mcp_registry()) :: [binary()]
  defdelegate server_names(registry), to: :beam_agent_mcp

  @doc """
  Project the registry into the CLI-integration format expected by backend adapters.

  Returns a map suitable for passing as the `mcp_servers` field in CLI invocation
  opts. Internal use by session handlers.
  """
  @spec servers_for_cli(mcp_registry()) :: map()
  defdelegate servers_for_cli(registry), to: :beam_agent_mcp

  @doc """
  Return the list of server name binaries to advertise in the MCP initialize handshake.

  Internal use by session handlers during the MCP initialization sequence.
  """
  @spec servers_for_init(mcp_registry()) :: [binary()]
  defdelegate servers_for_init(registry), to: :beam_agent_mcp

  # Tool registry — dispatch

  @doc """
  Dispatch an incoming MCP JSON-RPC message to the named server in the registry.

  `server_name` identifies which in-process server should handle the message.
  `message` is a decoded JSON-RPC map (e.g. a `tools/call` request).

  Returns `{:ok, response_map}` or `{:error, reason}`.
  """
  @spec handle_mcp_message(binary(), map(), mcp_registry()) ::
          {:ok, map()} | {:error, binary()}
  defdelegate handle_mcp_message(server_name, message, registry), to: :beam_agent_mcp

  @doc """
  Dispatch an MCP JSON-RPC message with additional call options.

  `opts` may include a `:timeout` key controlling the maximum handler execution
  time in milliseconds (default: 30_000 ms).
  """
  @spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ::
          {:ok, map()} | {:error, binary()}
  defdelegate handle_mcp_message(server_name, message, registry, opts), to: :beam_agent_mcp

  @doc """
  Call a tool by name across all servers in the registry.

  Searches all registered servers for a tool matching `tool_name` and invokes its
  handler with `arguments`. Returns `{:ok, [content_result()]}` on success, or
  `{:error, "tool not found"}` if no server in the registry has a tool with that
  name.
  """
  @spec call_tool_by_name(binary(), map(), mcp_registry()) ::
          {:ok, [content_result()]} | {:error, binary()}
  defdelegate call_tool_by_name(tool_name, arguments, registry), to: :beam_agent_mcp

  @doc """
  Call a tool by name with additional options.

  Same as `call_tool_by_name/3` but accepts an `opts` map (e.g.
  `%{timeout: 5000}`).
  """
  @spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ::
          {:ok, [content_result()]} | {:error, binary()}
  defdelegate call_tool_by_name(tool_name, arguments, registry, opts), to: :beam_agent_mcp

  @doc """
  Return the flat list of all tool definitions across all servers in the registry.

  Useful for building a `tools/list` MCP response or inspecting what tools are
  available in a given session.
  """
  @spec all_tool_definitions(mcp_registry()) :: [tool_def()]
  defdelegate all_tool_definitions(registry), to: :beam_agent_mcp

  @doc """
  Build an `mcp_registry()` from a list of servers, or return `nil`.

  Accepts either a list of `sdk_mcp_server()` values or `nil`. This is the
  canonical way to construct a registry from the `:sdk_mcp_servers` session
  option.

  ## Example

  ```elixir
  registry = BeamAgent.MCP.build_registry([server1, server2])
  ```
  """
  @spec build_registry([sdk_mcp_server()] | :undefined) :: mcp_registry() | :undefined
  defdelegate build_registry(servers), to: :beam_agent_mcp

  # Tool registry — runtime management

  @doc """
  Return a status map for every server in the registry.

  Returns `{:ok, %{server_name => status_map}}` where each `status_map`
  describes the server's current state (e.g. enabled/disabled, tool count).
  Pass `nil` to get `{:ok, %{}}`.
  """
  @spec server_status(mcp_registry() | :undefined) :: {:ok, %{binary() => map()}}
  defdelegate server_status(registry), to: :beam_agent_mcp

  @doc """
  Replace the full set of servers in a registry.

  Merges new servers over the old registry, preserving runtime state
  (enabled/disabled flags) for servers that existed before.
  """
  @spec set_servers([sdk_mcp_server()], mcp_registry() | :undefined) :: mcp_registry()
  defdelegate set_servers(servers, old_registry), to: :beam_agent_mcp

  @doc """
  Enable or disable a named server in the registry at runtime.

  `enabled` is `true` to enable or `false` to disable.

  Returns `{:ok, updated_registry}` or `{:error, :not_found}`.
  """
  @spec toggle_server(binary(), boolean(), mcp_registry() | :undefined) ::
          {:ok, mcp_registry()} | {:error, :not_found}
  defdelegate toggle_server(name, enabled, registry), to: :beam_agent_mcp

  @doc """
  Mark a named server as reconnected in the registry.

  Resets any error state on the server entry.

  Returns `{:ok, updated_registry}` or `{:error, :not_found}`.
  """
  @spec reconnect_server(binary(), mcp_registry() | :undefined) ::
          {:ok, mcp_registry()} | {:error, :not_found}
  defdelegate reconnect_server(name, registry), to: :beam_agent_mcp

  @doc """
  Remove a named server from the registry.

  No-ops if the server is not present. Returns the updated registry.
  """
  @spec unregister_server(binary(), mcp_registry()) :: mcp_registry()
  defdelegate unregister_server(name, registry), to: :beam_agent_mcp

  # Tool registry — session-scoped registry (ETS-backed)

  @doc """
  Store a session's MCP registry in the global ETS session registry table.

  Associates `registry` (or `nil`) with the session `pid` so that other processes
  can retrieve it via `get_session_registry/1` without holding a reference to the
  session process state. Called by session handlers during initialisation.
  """
  @spec register_session_registry(pid(), mcp_registry() | :undefined) :: :ok
  defdelegate register_session_registry(pid, registry), to: :beam_agent_mcp

  @doc """
  Retrieve the MCP registry for a session from the global ETS table.

  Returns `{:ok, registry}` if the session is registered, or
  `{:error, :not_found}` if no entry exists for `pid`.
  """
  @spec get_session_registry(pid()) :: {:ok, mcp_registry()} | {:error, :not_found}
  defdelegate get_session_registry(pid), to: :beam_agent_mcp

  @doc """
  Atomically update the MCP registry for a session in the ETS table.

  Applies `update_fun` to the current registry and stores the result. This is the
  safe way to add or modify servers while the session is running.

  Returns `:ok` or `{:error, :not_found}` if the session is not registered.

  ## Example

  ```elixir
  :ok = BeamAgent.MCP.update_session_registry(pid, fn reg ->
    BeamAgent.MCP.register_server(new_server, reg)
  end)
  ```
  """
  @spec update_session_registry(pid(), (mcp_registry() -> mcp_registry())) ::
          :ok | {:error, :not_found}
  defdelegate update_session_registry(pid, update_fun), to: :beam_agent_mcp

  @doc """
  Remove the MCP registry entry for a session from the global ETS table.

  Called by session handlers during termination to clean up ETS state.
  """
  @spec unregister_session_registry(pid()) :: :ok
  defdelegate unregister_session_registry(pid), to: :beam_agent_mcp

  @doc """
  Ensure the global ETS session-registry table exists, creating it if necessary.

  This is idempotent and safe to call multiple times. Call it once during
  application startup (or OTP supervisor init) before any sessions are started.
  """
  @spec ensure_registry_table() :: :ok
  defdelegate ensure_registry_table(), to: :beam_agent_mcp

  # Protocol (beam_agent_mcp_protocol)

  @doc """
  Return the MCP protocol version string this SDK implements.

  Returns a binary such as `"2025-06-18"`. Used during the MCP `initialize`
  handshake to advertise protocol compatibility.
  """
  @spec protocol_version() :: <<_::80>>
  defdelegate protocol_version(), to: :beam_agent_mcp

  # Full-spec server dispatch (beam_agent_mcp_dispatch)

  @doc """
  Create a new MCP server-side dispatch state machine.

  Parameters:
  - `server_info` — implementation info map, e.g. `%{name: "srv", version: "1.0"}`
  - `server_caps` — server capabilities map, e.g. `%{tools: %{}, resources: %{}}`
  - `opts` — additional options (pass `%{}` for defaults)

  Returns an opaque `dispatch_state()` to be threaded through `dispatch_message/2`.

  ## Example

  ```elixir
  state = BeamAgent.MCP.new_dispatch(
    %{name: "my-server", version: "1.0.0"},
    %{tools: %{}},
    %{}
  )
  ```
  """
  @spec new_dispatch(implementation_info(), map(), map()) :: dispatch_state()
  defdelegate new_dispatch(server_info, server_caps, opts), to: :beam_agent_mcp

  @doc """
  Process an incoming JSON-RPC message through the MCP server dispatch state machine.

  `msg` is a decoded JSON-RPC map received from the client. Returns a
  `dispatch_result()` — typically `{response_map, new_state}` for requests or
  `{:noreply, new_state}` for notifications.

  Thread `new_state` into the next `dispatch_message/2` call.
  """
  @spec dispatch_message(map(), dispatch_state()) :: dispatch_result()
  defdelegate dispatch_message(msg, state), to: :beam_agent_mcp

  @doc """
  Return the current lifecycle state of the server dispatch state machine.

  Returns an atom such as `:uninitialized`, `:initializing`, or `:ready`.
  """
  @spec dispatch_lifecycle_state(dispatch_state()) :: :uninitialized | :initializing | :ready
  defdelegate dispatch_lifecycle_state(state), to: :beam_agent_mcp

  @doc """
  Return the negotiated session capabilities from the server dispatch state.

  Only meaningful after the MCP initialize handshake completes (lifecycle `:ready`).
  """
  @spec dispatch_session_capabilities(dispatch_state()) :: map()
  defdelegate dispatch_session_capabilities(state), to: :beam_agent_mcp

  # Client-side dispatch (beam_agent_mcp_client_dispatch)

  @doc """
  Create a new MCP client-side dispatch state machine.

  Parameters:
  - `client_info` — implementation info map, e.g. `%{name: "my-client", version: "1.0.0"}`
  - `client_caps` — client capabilities map, e.g. `%{roots: %{listChanged: true}}`
  - `opts` — additional options (pass `%{}` for defaults)

  Returns an opaque `client_state()`. Drive the MCP handshake by calling
  `client_send_initialize/1` next.

  ## Example

  ```elixir
  state = BeamAgent.MCP.new_client(
    %{name: "beam-agent-client", version: "1.0.0"},
    %{roots: %{}},
    %{}
  )
  ```
  """
  @spec new_client(implementation_info(), map(), map()) :: client_state()
  defdelegate new_client(client_info, client_caps, opts), to: :beam_agent_mcp

  @doc """
  Return the current lifecycle state of the MCP client dispatch state machine.

  Returns an atom such as `:uninitialized`, `:initializing`, or `:ready`.
  """
  @spec client_lifecycle_state(client_state()) :: :uninitialized | :initializing | :ready
  defdelegate client_lifecycle_state(state), to: :beam_agent_mcp

  @doc """
  Return the server capabilities advertised by the MCP server during the handshake.

  Only meaningful after the initialize/initialized handshake completes.
  """
  @spec client_server_capabilities(client_state()) :: map()
  defdelegate client_server_capabilities(state), to: :beam_agent_mcp

  @doc """
  Return the negotiated session capabilities from the client state.
  """
  @spec client_session_capabilities(client_state()) :: map()
  defdelegate client_session_capabilities(state), to: :beam_agent_mcp

  @doc """
  Build and return an MCP `initialize` request message.

  This is the first message to send in the MCP handshake. Returns
  `{msg, new_state}` where `msg` is the JSON-RPC map to send over the transport.
  """
  @spec client_send_initialize(client_state()) :: {map(), client_state()}
  defdelegate client_send_initialize(state), to: :beam_agent_mcp

  @doc """
  Build and return an MCP `initialized` notification message.

  Send this after receiving a successful `initialize` response from the server.
  Returns `{msg, new_state}`.
  """
  @spec client_send_initialized(client_state()) :: {map(), client_state()}
  defdelegate client_send_initialized(state), to: :beam_agent_mcp

  @doc """
  Build and return an MCP `ping` request message.

  Use to verify the server connection is alive. Returns `{msg, new_state}`.
  """
  @spec client_send_ping(client_state()) :: {map(), client_state()}
  defdelegate client_send_ping(state), to: :beam_agent_mcp

  @doc """
  Build and return a `tools/list` request (no cursor, first page).
  """
  @spec client_send_tools_list(client_state()) :: {map(), client_state()}
  defdelegate client_send_tools_list(state), to: :beam_agent_mcp

  @doc """
  Build and return a `tools/list` request with a pagination cursor.

  Pass `cursor` from a previous `tools/list` response to fetch the next page.
  """
  @spec client_send_tools_list(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_tools_list(cursor, state), to: :beam_agent_mcp

  @doc """
  Build and return a `tools/call` request.

  Parameters:
  - `tool_name` — name of the tool to invoke
  - `arguments` — map of input arguments matching the tool's JSON Schema
  """
  @spec client_send_tools_call(binary(), map(), client_state()) :: {map(), client_state()}
  defdelegate client_send_tools_call(tool_name, arguments, state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/list` request (no cursor, first page).
  """
  @spec client_send_resources_list(client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_list(state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/list` request with a pagination cursor.
  """
  @spec client_send_resources_list(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_list(cursor, state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/read` request for a specific resource URI.
  """
  @spec client_send_resources_read(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_read(uri, state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/templates/list` request (no cursor).
  """
  @spec client_send_resources_templates_list(client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_templates_list(state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/templates/list` request with a pagination cursor.
  """
  @spec client_send_resources_templates_list(binary(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_resources_templates_list(cursor, state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/subscribe` request for a resource URI.

  Subscribe to change notifications for the resource at `uri`.
  """
  @spec client_send_resources_subscribe(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_subscribe(uri, state), to: :beam_agent_mcp

  @doc """
  Build and return a `resources/unsubscribe` request for a resource URI.
  """
  @spec client_send_resources_unsubscribe(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_resources_unsubscribe(uri, state), to: :beam_agent_mcp

  @doc """
  Build and return a `prompts/list` request (no cursor).
  """
  @spec client_send_prompts_list(client_state()) :: {map(), client_state()}
  defdelegate client_send_prompts_list(state), to: :beam_agent_mcp

  @doc """
  Build and return a `prompts/list` request with a pagination cursor.
  """
  @spec client_send_prompts_list(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_prompts_list(cursor, state), to: :beam_agent_mcp

  @doc """
  Build and return a `prompts/get` request by prompt name (no arguments).
  """
  @spec client_send_prompts_get(binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_prompts_get(name, state), to: :beam_agent_mcp

  @doc """
  Build and return a `prompts/get` request with template arguments.

  `arguments` is a map of variable bindings for the prompt template.
  """
  @spec client_send_prompts_get(binary(), map(), client_state()) :: {map(), client_state()}
  defdelegate client_send_prompts_get(name, arguments, state), to: :beam_agent_mcp

  @doc """
  Build and return a `completion/complete` request (no context).

  `ref` identifies the completion reference (prompt or resource URI).
  `argument` is the argument map with the partial value to complete.
  """
  @spec client_send_completion_complete(completion_ref(), map(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_completion_complete(ref, argument, state), to: :beam_agent_mcp

  @doc """
  Build and return a `completion/complete` request with context.

  `context` is an optional map of additional context for the completion.
  """
  @spec client_send_completion_complete(completion_ref(), map(), map(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_completion_complete(ref, argument, context, state), to: :beam_agent_mcp

  @doc """
  Build and return a `logging/setLevel` request.

  `level` is one of the MCP log level atoms such as `:debug`, `:info`,
  `:warning`, or `:error`.
  """
  @spec client_send_logging_set_level(log_level(), client_state()) :: {map(), client_state()}
  defdelegate client_send_logging_set_level(level, state), to: :beam_agent_mcp

  @doc """
  Build and return an arbitrary MCP request by method name.

  Use this for MCP methods not covered by the typed send functions. `method` is
  the JSON-RPC method string and `params` is the params map.
  """
  @spec client_send_request(binary(), map(), client_state()) :: {map(), client_state()}
  defdelegate client_send_request(method, params, state), to: :beam_agent_mcp

  @doc """
  Build and return a `cancelled` notification for a pending request (no reason).
  """
  @spec client_send_cancelled(request_id(), client_state()) :: {map(), client_state()}
  defdelegate client_send_cancelled(request_id, state), to: :beam_agent_mcp

  @doc """
  Build and return a `cancelled` notification with a human-readable reason.
  """
  @spec client_send_cancelled(request_id(), binary(), client_state()) :: {map(), client_state()}
  defdelegate client_send_cancelled(request_id, reason, state), to: :beam_agent_mcp

  @doc """
  Build and return a `progress` notification (progress value only).

  `token` is the progress token from the original request.
  `progress` is the current progress value (0.0–1.0 or an absolute count).
  """
  @spec client_send_progress(progress_token(), number(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_progress(token, progress, state), to: :beam_agent_mcp

  @doc """
  Build and return a `progress` notification with a total value.

  `total` is the total work units, allowing clients to display a percentage.
  """
  @spec client_send_progress(progress_token(), number(), number(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_progress(token, progress, total, state), to: :beam_agent_mcp

  @doc """
  Build and return a `progress` notification with total and a status message.

  `message` is a human-readable binary describing the current step.
  """
  @spec client_send_progress(progress_token(), number(), number(), binary(), client_state()) ::
          {map(), client_state()}
  defdelegate client_send_progress(token, progress, total, message, state), to: :beam_agent_mcp

  @doc """
  Build and return a `roots/list_changed` notification.

  Send this when the client's root list has changed so the server can re-fetch it.
  """
  @spec client_send_roots_list_changed(client_state()) :: {map(), client_state()}
  defdelegate client_send_roots_list_changed(state), to: :beam_agent_mcp

  @doc """
  Process an incoming JSON-RPC message from the MCP server through the client state machine.

  `msg` is a decoded map received from the server (a response or notification).
  Returns `{:ok, new_state}` on success. Thread `new_state` into the next call.
  """
  @spec client_handle_message(map(), client_state()) :: client_result()
  defdelegate client_handle_message(msg, state), to: :beam_agent_mcp

  @doc """
  Check for timed-out pending requests and purge them from the client state.

  `now` is a monotonic timestamp (e.g. from `:erlang.monotonic_time(:millisecond)`).
  Returns `{timed_out_list, new_state}` where `timed_out_list` is a list of
  `timed_out_request()` values for requests that exceeded their deadline.

  Call this periodically (e.g. from a `gen_statem` timeout event) to clean up
  stale pending requests.
  """
  @spec client_check_timeouts(integer(), client_state()) ::
          {[timed_out_request()], client_state()}
  defdelegate client_check_timeouts(now, state), to: :beam_agent_mcp

  @doc """
  Return the number of pending (in-flight) requests in the client state.

  A non-zero count means there are requests awaiting responses from the server.
  """
  @spec client_pending_count(client_state()) :: non_neg_integer()
  defdelegate client_pending_count(state), to: :beam_agent_mcp
end
