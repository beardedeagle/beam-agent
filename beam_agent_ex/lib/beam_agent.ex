defmodule BeamAgent do
  @moduledoc """
  Unified public API for the BeamAgent SDK -- an Elixir/OTP wrapper around five
  agentic coder backends: Claude, Codex, Gemini, OpenCode, and Copilot.

  `BeamAgent` is the single stable entry point for all callers. Every
  user-visible feature -- threads, turns, skills, apps, files, MCP, accounts,
  fuzzy search, and more -- works identically across all five backends thanks
  to native-first routing with universal fallbacks.

  ## Quick Start

  Start a session, send a query, and process the response:

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, messages} = BeamAgent.query(session, "What is the BEAM?")

      for %{content: content} <- messages do
        IO.puts(content)
      end

      :ok = BeamAgent.stop(session)

  ## Streaming with Events

  Subscribe to events before sending a query for real-time streaming:

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, ref} = BeamAgent.event_subscribe(session)
      {:ok, _messages} = BeamAgent.query(session, "Explain OTP")

      defp loop(session, ref) do
        case BeamAgent.receive_event(session, ref, 10_000) do
          {:ok, %{type: :result}} ->
            IO.puts("Done.")

          {:ok, %{type: :text, content: content}} ->
            IO.write(content)
            loop(session, ref)

          {:ok, _other} ->
            loop(session, ref)

          {:error, :complete} ->
            IO.puts("Stream complete.")

          {:error, :timeout} ->
            IO.puts("Timed out.")
        end
      end

  Or use the convenience `stream!/3` function for an `Enumerable`:

      session
      |> BeamAgent.stream!("Explain GenServer")
      |> Enum.each(fn msg -> IO.write(msg[:content] || "") end)

  ## Key Concepts

  ### Sessions

  A session is a supervised `gen_statem` process that owns a single transport
  connection to a backend CLI. Sessions are started with `start_session/1`
  and stopped with `stop/1`. Each session has a unique binary `session_id`,
  tracks message history, and can host multiple conversation threads.

  ### Events

  Events provide a streaming view of session activity. Call
  `event_subscribe/1` to register the calling process as a subscriber,
  then `receive_event/2` to pull events one at a time. Events are
  delivered as normalized `t:message/0` maps. The stream ends with an
  `{:error, :complete}` sentinel after a result or error message.

  ### Threads

  Threads group related queries into named conversation contexts within
  a session. Use `thread_start/2` to create a thread, `thread_resume/2` to
  switch to it, and `thread_list/1` to enumerate threads. Each thread
  tracks its own message history as a subset of the session history.

  ### Hooks

  SDK-level lifecycle hooks fire at well-defined points (session start,
  query start, tool use, etc.). Pass hook definitions in session opts
  via the `:sdk_hooks` key. Hooks run in-process and cannot block the
  engine state machine.

  ### MCP (Model Context Protocol)

  MCP lets you define custom tools as Erlang/Elixir functions that the
  backend can invoke in-process. Use `add_mcp_server/2` to register a
  server with its tools, `mcp_status/1` to inspect registered servers,
  and `toggle_mcp_server/3` to enable/disable servers at runtime.

  ### Providers

  Providers represent authentication/API endpoints for a backend. Use
  `current_provider/1` and `set_provider/2` to manage which provider is
  active. Provider management is most relevant for backends that support
  multiple API endpoints (e.g., OpenCode with different LLM providers).

  ## Architecture

  Every public function in this module follows the `native_or` routing
  pattern: it first attempts the backend's native implementation, and if
  the backend returns `{:error, {:unsupported_native_call, _}}`, it falls
  back to a universal implementation in one of the core modules.

  The call chain is: `BeamAgent` -> `:beam_agent` -> `:beam_agent_core` ->
  `:beam_agent_router` -> `:beam_agent_session_engine` -> backend handler.
  This thin wrapper design means `BeamAgent` contains zero business logic --
  it is purely a delegation layer.

  ## Submodules

  - `BeamAgent.Raw` -- escape-hatch functions for backend-native calls
  - `BeamAgent.Hooks` -- SDK lifecycle hook definitions and dispatch
  - `BeamAgent.MCP` -- MCP server/tool definitions and dispatch
  - `BeamAgent.SessionStore` -- session history storage and retrieval
  - `BeamAgent.Threads` -- thread management within sessions

  ## Core concepts

  - **Sessions**: A session is a connection to one AI backend. You start one,
    send queries, and stop it when done. Think of it like a phone call to an AI.
  - **The five backends**: BeamAgent wraps Claude, Codex, Gemini, OpenCode, and
    Copilot. You pick one when starting a session, but the API is the same for
    all of them.
  - **Queries**: `query/2` sends a prompt and waits for the complete response.
    `event_subscribe/1` + `receive_event/2` gives you streaming responses piece
    by piece.
  - **Session pid**: Every session is an Erlang process. The `pid` you get from
    `start_session/1` is how you talk to it. Pass it as the first argument to
    every function.
  - **Native-first routing**: Most functions try the backend's own implementation
    first. If the backend doesn't support a feature natively, BeamAgent uses a
    universal OTP-based fallback. You don't need to think about this — it just
    works.

  ## Architecture deep dive

  - **Delegation chain**: `BeamAgent` delegates to `:beam_agent` (Erlang), which
    delegates to `:beam_agent_core`, which routes through
    `:beam_agent_session_engine` (a `gen_statem`) to the backend handler. Zero
    business logic lives in `BeamAgent` or `:beam_agent`.
  - **Session engine**: Each session is a single `gen_statem` process that owns
    the transport (Erlang port, HTTP client, or WebSocket). No additional
    processes are spawned per session.
  - **native_or pattern**: The Erlang `native_or/4` macro tries
    `AdapterModule:Function(Session, Args...)` and falls back to a closure if
    the adapter doesn't export the function. Universal fallbacks use ETS-backed
    core modules (`beam_agent_*_core`).
  - **Transport architecture**: Three transport types --
    `beam_agent_transport_port` (stdio), `beam_agent_transport_http`
    (HTTP), and `beam_agent_transport_ws` (WebSocket). The handler's
    `init_handler/1` callback selects the transport.
  - **Thick framework, thin adapters**: The session engine handles lifecycle,
    queuing, telemetry, buffering, and consumer management. Backend handlers
    only implement protocol encoding/decoding and message normalization.
  """

  @typedoc """
  Backend identifier atom.

  One of `:claude`, `:codex`, `:gemini`, `:opencode`, or `:copilot`.
  Used throughout the SDK to select which backend adapter handles a session.
  """
  @type backend :: :beam_agent.backend()

  @typedoc """
  The normalized message type tag.

  Values: `:text`, `:assistant`, `:tool_use`, `:tool_result`, `:system`,
  `:result`, `:error`, `:user`, `:control`, `:control_request`,
  `:control_response`, `:stream_event`, `:rate_limit_event`,
  `:tool_progress`, `:tool_use_summary`, `:thinking`, `:auth_status`,
  `:prompt_suggestion`, `:raw`.

  The `:result` type signals query completion. The `:error` type signals
  a backend error. The `:raw` type preserves unrecognized wire messages
  for forward compatibility.
  """
  @type message_type :: :beam_agent.message_type()

  @typedoc """
  Normalized stop reason from the backend.

  Values: `:end_turn` (normal completion), `:max_tokens` (output truncated),
  `:stop_sequence` (custom stop sequence hit), `:refusal` (model declined),
  `:tool_use_stop` (stopped for tool use), `:unknown_stop` (unrecognized).
  Parsed from the binary wire format into atoms for pattern matching.
  """
  @type stop_reason :: :beam_agent.stop_reason()

  @typedoc """
  Permission mode controlling tool and edit approval.

  Values: `:default` (normal approval flow), `:accept_edits` (auto-approve
  file edits), `:bypass_permissions` (approve everything),
  `:plan` (read-only planning mode), `:dont_ask` (TypeScript SDK only,
  auto-approve without prompting).
  """
  @type permission_mode :: :beam_agent.permission_mode()

  @typedoc """
  A normalized message map flowing through the SDK.

  Every message carries a required `:type` field (see `t:message_type/0`) and
  optional fields that vary by type. Common fields present on most messages:
  `:uuid` (unique identifier), `:session_id`, `:content`, and `:timestamp`.

  Result messages additionally carry `:duration_ms`, `:num_turns`,
  `:stop_reason_atom`, `:usage`, and `:total_cost_usd`. Tool-use messages
  carry `:tool_name` and `:tool_input`.
  """
  @type message :: :beam_agent.message()

  @typedoc """
  Result from a permission handler callback.

  Variants:
  - `{:allow, updated_input}` -- approve with optional input modifications
  - `{:deny, reason}` -- deny with a human-readable reason
  - `{:deny, reason, interrupt}` -- deny and request turn interruption
  - `{:allow, updated_input, rule_update}` -- approve with rule/permission updates
  - `map()` -- richer structured result with keys like `:behavior`,
    `:updated_input`, `:updated_permissions`, `:message`, and `:interrupt`
  """
  @type permission_result :: :beam_agent.permission_result()

  @typedoc """
  Function that pulls the next message from a session event stream.

  Signature: `fun(session, ref, timeout) -> {:ok, message()} | {:error, term()}`.
  Used by `collect_messages/4` and `collect_messages/5` to abstract the
  message retrieval mechanism.
  """
  @type receive_fun :: :beam_agent.receive_fun()

  @typedoc """
  Predicate that determines if a message terminates collection.

  Returns `true` for messages that should halt the `collect_messages` loop
  (the halting message is included in the result list). Returns `false`
  for messages that should continue collection. The default predicate
  checks for `type: :result`.
  """
  @type terminal_pred :: :beam_agent.terminal_pred()

  @typedoc """
  Session metadata map returned by `list_sessions/0` and related functions.

  Contains `:session_id`, `:adapter`, `:created_at`, `:cwd`, `:extra`,
  `:message_count`, `:model`, and `:updated_at` fields.
  """
  @type session_info_map :: %{
          :session_id => binary(),
          :adapter => atom(),
          :created_at => integer(),
          :cwd => binary(),
          :extra => map(),
          :message_count => non_neg_integer(),
          :model => binary(),
          :updated_at => integer()
        }

  @typedoc """
  Share metadata map returned by `share_session/1` and `share_session/2`.

  Contains `:created_at`, `:session_id`, `:share_id`, `:status`, and
  `:revoked_at` fields.
  """
  @type share_info_map :: %{
          :created_at => integer(),
          :session_id => binary(),
          :share_id => binary(),
          :status => :active | :revoked,
          :revoked_at => integer()
        }

  @typedoc """
  Summary metadata map returned by `summarize_session/1` and `summarize_session/2`.

  Contains `:content`, `:generated_at`, `:generated_by`, `:message_count`,
  and `:session_id` fields.
  """
  @type summary_info_map :: %{
          :content => binary(),
          :generated_at => integer(),
          :generated_by => binary(),
          :message_count => non_neg_integer(),
          :session_id => binary()
        }

  # ---------------------------------------------------------------------------
  # Session Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start a new agent session connected to a backend.

  Launches a supervised `gen_statem` process that owns a transport connection
  to the specified backend CLI. The session is ready to accept queries once
  this call returns successfully.

  ## Parameters

  - `opts` -- session configuration map. The `:backend` key is required and
    must be one of `:claude`, `:codex`, `:gemini`, `:opencode`, or `:copilot`.

  ## Returns

  - `{:ok, pid}` on success where `pid` is the session process.
  - `{:error, reason}` if the session could not be started.

  ## Examples

      {:ok, session} = BeamAgent.start_session(%{
        backend: :claude,
        model: "claude-sonnet-4-20250514",
        system_prompt: "You are a helpful assistant.",
        permission_mode: :default
      })
  """
  defdelegate start_session(opts), to: :beam_agent

  @doc """
  Build a supervisor child spec for embedding a session in a supervision tree.

  Returns an OTP child_spec map suitable for passing to
  `Supervisor.start_child/2` or including in a supervisor `init/1` return value.

  ## Parameters

  - `opts` -- session configuration map (same as `start_session/1`).

  ## Examples

      child_spec = BeamAgent.child_spec(%{backend: :claude})
      {:ok, _pid} = Supervisor.start_child(MySupervisor, child_spec)
  """
  defdelegate child_spec(opts), to: :beam_agent

  @doc """
  Stop a running session and close its transport connection.

  Gracefully shuts down the session `gen_statem`, closes the underlying
  transport (port, HTTP, or WebSocket), and cleans up session state.

  ## Parameters

  - `session` -- pid of a running session process.

  ## Returns

  `:ok`
  """
  defdelegate stop(session), to: :beam_agent

  @doc """
  Send a synchronous query to the session with default parameters.

  Blocks until the backend produces a complete response (a result-type
  message). All intermediate messages (text chunks, tool use, thinking,
  etc.) are collected and returned as a list.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.

  ## Returns

  - `{:ok, messages}` where `messages` is a list of normalized `t:message/0`
    maps in chronological order.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, messages} = BeamAgent.query(session, "What is Erlang?")
      result = List.last(messages)
      IO.puts(result[:content])
  """
  defdelegate query(session, prompt), to: :beam_agent

  @doc """
  Send a synchronous query with explicit parameters.

  Like `query/2` but accepts a query options map to control model selection,
  tool permissions, timeout, output format, and other query-level settings.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- query options map. Keys include `:model`, `:max_turns`,
    `:permission_mode`, `:timeout`, `:max_tokens`, `:system_prompt`,
    `:allowed_tools`, `:disallowed_tools`, `:output_format`, `:thinking`,
    `:max_budget_usd`, `:agent`, and `:attachments`.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.

  ## Examples

      {:ok, messages} = BeamAgent.query(session, "Refactor this module", %{
        model: "claude-sonnet-4-20250514",
        max_turns: 5,
        permission_mode: :accept_edits,
        timeout: 120_000
      })
  """
  defdelegate query(session, prompt, params), to: :beam_agent

  @doc """
  Subscribe the calling process to streaming events from a session.

  After subscribing, the caller receives events via `receive_event/2` or
  `receive_event/3`. Events are normalized `t:message/0` maps delivered in
  real time as the backend produces them. The stream ends with an
  `{:error, :complete}` sentinel after a result or error message.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, ref}` where `ref` is a unique subscription reference.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, ref} = BeamAgent.event_subscribe(session)
      {:ok, _messages} = BeamAgent.query(session, "Hello")
      {:ok, event} = BeamAgent.receive_event(session, ref, 5_000)
  """
  defdelegate event_subscribe(session), to: :beam_agent

  @doc """
  Receive the next event from a subscription with a 5-second default timeout.

  Equivalent to `receive_event(session, ref, 5000)`.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.

  ## Returns

  - `{:ok, event}` where `event` is a `t:message/0` map.
  - `{:error, :complete}` when the stream has ended.
  - `{:error, :timeout}` if no event arrives within 5 seconds.
  - `{:error, :bad_ref}` if the subscription is invalid.
  """
  defdelegate receive_event(session, ref), to: :beam_agent

  @doc """
  Receive the next event from a subscription with an explicit timeout.

  Blocks the calling process until an event arrives, the stream completes,
  or the timeout expires.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.
  - `timeout` -- maximum wait time in milliseconds.

  ## Returns

  - `{:ok, event}` -- a `t:message/0` map.
  - `{:error, :complete}` -- stream has ended.
  - `{:error, :timeout}` -- no event within the timeout.
  - `{:error, :bad_ref}` -- invalid subscription reference.
  """
  defdelegate receive_event(session, ref, timeout), to: :beam_agent

  @doc """
  Remove an event subscription and flush any pending events from the mailbox.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.

  ## Returns

  - `{:ok, :ok}` on success.
  - `{:error, :bad_ref}` if the reference is invalid.
  """
  defdelegate event_unsubscribe(session, ref), to: :beam_agent

  @doc """
  Retrieve metadata about a running session.

  Returns a map containing `:session_id`, `:backend`, `:model`, current state,
  working directory, and handler-specific metadata merged from the backend's
  `build_session_info` callback.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, info_map}` or `{:error, reason}`.
  """
  defdelegate session_info(session), to: :beam_agent

  @doc """
  Return the current health state of a session as an atom.

  Possible values depend on the session engine state: `:connecting`,
  `:initializing`, `:ready`, `:active_query`, `:error`, or `:unknown`.

  ## Parameters

  - `session` -- pid of a running session.
  """
  defdelegate health(session), to: :beam_agent

  @doc """
  Resolve the backend identifier for a running session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, backend}` where `backend` is an atom like `:claude`, `:codex`,
    `:gemini`, `:opencode`, or `:copilot`.
  - `{:error, reason}` if the backend cannot be determined.
  """
  defdelegate backend(session), to: :beam_agent

  @doc """
  List all registered backend identifiers.

  Returns a list of atoms representing the backends available in this
  build of the SDK (e.g., `[:claude, :codex, :gemini, :opencode, :copilot]`).

  ## Examples

      iex> backends = BeamAgent.list_backends()
      iex> :claude in backends
      true
  """
  defdelegate list_backends(), to: :beam_agent

  @doc """
  Change the model for a running session.

  Sends a `set_model` control message to the session engine. The backend
  handler may process this natively (e.g., sending a protocol message)
  or the engine stores it in its own state.

  ## Parameters

  - `session` -- pid of a running session.
  - `model` -- binary model identifier (e.g., `"claude-sonnet-4-20250514"`).

  ## Returns

  - `{:ok, model}` on success.
  - `{:error, reason}` on failure.
  """
  defdelegate set_model(session, model), to: :beam_agent

  @doc """
  Change the permission mode for a running session.

  Controls how the backend handles tool execution and file edit approval.
  See `t:permission_mode/0` for valid values.

  ## Parameters

  - `session` -- pid of a running session.
  - `mode` -- binary permission mode (e.g., `"default"`, `"accept_edits"`).

  ## Returns

  - `{:ok, mode}` on success.
  - `{:error, reason}` on failure.
  """
  defdelegate set_permission_mode(session, mode), to: :beam_agent

  @doc """
  Interrupt the currently active query on a session.

  Sends an interrupt signal to the backend. If the backend supports
  native interrupts (e.g., sending a protocol-level cancel), it uses
  that; otherwise falls back to an OS-level signal for port-based transports.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `:ok` if the interrupt was sent.
  - `{:error, :not_supported}` if the backend does not support interrupts.
  - `{:error, reason}` on failure.
  """
  defdelegate interrupt(session), to: :beam_agent

  @doc """
  Abort the currently active query and reset the session to ready state.

  Stronger than `interrupt/1`: forcibly cancels the query and transitions
  the session engine back to the ready state.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `:ok` or `{:error, reason}`.
  """
  defdelegate abort(session), to: :beam_agent

  @doc """
  Send a backend-specific control message to a session.

  Control messages provide a generic extension point for features not
  covered by the typed API. The `method` string identifies the operation
  and `params` carries its arguments.

  ## Parameters

  - `session` -- pid of a running session.
  - `method` -- binary method name (e.g., `"mcp_message"`, `"set_config"`).
  - `params` -- map of method-specific parameters.

  ## Returns

  - `{:ok, result}` on success.
  - `{:error, :not_supported}` if the backend does not handle this method.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, result} = BeamAgent.send_control(session,
        "mcp_message",
        %{server: "my-tools", method: "tools/list"})
  """
  defdelegate send_control(session, method, params), to: :beam_agent

  @doc """
  Return the static list of CLI commands that the session's backend supports.

  Each backend advertises a fixed set of commands it can handle (e.g.,
  `"query"`, `"interrupt"`, `"config"`). Use this to discover what
  operations are available before attempting them, or to build dynamic
  command palettes in a UI.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, commands}` where `commands` is a list of command maps, each
    containing `:name` (binary command identifier) and `:description`
    (human-readable summary of the command).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, commands} = BeamAgent.supported_commands(session)
      for cmd <- commands, do: IO.puts("\#{cmd.name}: \#{cmd.description}")
  """
  defdelegate supported_commands(session), to: :beam_agent

  @doc """
  Return the static list of LLM models available for the session's backend.

  Each backend exposes its own set of models with varying capabilities
  (context window sizes, tool use support, vision, etc.). Use this to
  present model selection options or validate a model identifier before
  passing it to `set_model/2`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, models}` where `models` is a list of model maps, each
    containing `:name` (binary model identifier) and `:capabilities`
    (map describing features like context length and tool support).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, models} = BeamAgent.supported_models(session)
      for m <- models, do: IO.puts(m.name)
  """
  defdelegate supported_models(session), to: :beam_agent

  @doc """
  Return the static list of sub-agents that the session's backend exposes.

  Sub-agents are specialized assistants that handle focused tasks such as
  code review, test generation, or documentation writing. The primary agent
  can delegate work to a sub-agent via `set_agent/2`. Use this function to
  discover which sub-agents are available for the current backend.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agents}` where `agents` is a list of agent maps, each containing
    `:name` (binary identifier), `:description` (what the sub-agent
    specializes in), and `:capabilities` (list of capability atoms).
  - `{:error, reason}` on failure.
  """
  defdelegate supported_agents(session), to: :beam_agent

  @doc """
  Retrieve account and authentication information for the session's backend.

  Returns details about the authenticated user including identity,
  subscription plan, usage quotas, and the authentication method in use.
  Useful for displaying account dashboards, checking remaining quota
  before expensive operations, or verifying that credentials are valid.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, info_map}` where `info_map` contains `:account_id` (binary),
    `:email` (binary), `:plan` (binary plan name), `:usage` (map with
    quota/consumption data), and `:auth_method` (atom such as `:api_key`
    or `:oauth`).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, info} = BeamAgent.account_info(session)
      IO.puts("Plan: \#{info.plan}, Email: \#{info.email}")
  """
  defdelegate account_info(session), to: :beam_agent

  @doc """
  List all tools registered with the session.

  Returns every tool the backend makes available, including built-in tools
  (e.g., Bash, Read, Edit, Write, Glob, Grep) and any custom tools added
  via MCP servers. Use this to discover what tools the agent can invoke
  during a query, or to validate tool identifiers before passing them in
  `:allowed_tools` / `:disallowed_tools` query parameters.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, tools}` where `tools` is a list of tool definition maps, each
    containing `:name` (binary tool identifier), `:description` (what the
    tool does), and `:input_schema` (JSON Schema map describing accepted
    parameters).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, tools} = BeamAgent.list_tools(session)
      tool_names = Enum.map(tools, & &1.name)
      IO.inspect(tool_names)
  """
  defdelegate list_tools(session), to: :beam_agent

  @doc """
  List skills registered with the session.

  Skills are reusable prompt templates or multi-step workflows that the
  backend can execute. They encapsulate common patterns (e.g., "write tests
  for this module", "review this PR") as named, parameterizable operations.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, skills}` where `skills` is a list of skill definition maps, each
    containing `:name` (binary skill identifier), `:description` (what the
    skill does), and `:path` (file path to the skill definition).
  - `{:error, reason}` on failure.
  """
  defdelegate list_skills(session), to: :beam_agent

  @doc """
  List plugins extending the session's agent capabilities.

  Plugins are optional extensions that add tools, modify behavior, or
  integrate with external services. Each plugin bundles one or more tools
  and can be enabled or disabled at runtime via configuration.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, plugins}` where `plugins` is a list of plugin definition maps,
    each containing `:name` (binary plugin identifier), `:description`
    (what the plugin provides), `:enabled` (boolean indicating whether
    the plugin is active), and `:tools` (list of tool name binaries
    contributed by this plugin).
  - `{:error, reason}` on failure.
  """
  defdelegate list_plugins(session), to: :beam_agent

  @doc """
  List MCP (Model Context Protocol) servers registered with the session.

  Returns all MCP servers that have been added to this session, whether
  they were configured at session start or added dynamically with
  `add_mcp_server/2`. Use this alongside `mcp_server_status/1` to monitor
  server health, or to enumerate available custom tools.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, servers}` where `servers` is a list of MCP server maps, each
    containing `:name` (binary server identifier), `:status` (atom such
    as `:connected` or `:disconnected`), and `:tools` (list of tool
    definition maps provided by this server).
  - `{:error, reason}` on failure.
  """
  defdelegate list_mcp_servers(session), to: :beam_agent

  @doc """
  List sub-agents registered with the session.

  Sub-agents are specialized assistants that the primary agent can delegate
  to for focused tasks such as code review, test generation, or
  documentation writing. This returns the runtime list of sub-agents,
  which may differ from `supported_agents/1` if agents were added or
  removed dynamically during the session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agents}` where `agents` is a list of agent definition maps,
    each containing `:name` (binary agent identifier), `:description`
    (what the sub-agent specializes in), and `:capabilities` (list of
    capability atoms the sub-agent supports).
  - `{:error, reason}` on failure.
  """
  defdelegate list_agents(session), to: :beam_agent

  @doc """
  Retrieve a specific tool definition by its identifier.

  Looks up a single tool from the session's tool registry. Use this to
  inspect a tool's input schema before invoking it, or to verify that a
  tool exists. Common built-in tool identifiers include `"Bash"`, `"Read"`,
  `"Edit"`, `"Write"`, `"Glob"`, and `"Grep"`.

  ## Parameters

  - `session` -- pid of a running session.
  - `tool_id` -- binary tool identifier (e.g., `"Bash"`, `"Read"`).

  ## Returns

  - `{:ok, tool_map}` where `tool_map` contains `:name` (binary),
    `:description` (binary), and `:input_schema` (JSON Schema map
    describing accepted parameters).
  - `{:error, :not_found}` if no tool with that identifier is registered.
  - `{:error, reason}` on other failures.

  ## Examples

      {:ok, tool} = BeamAgent.get_tool(session, "Bash")
      IO.puts(tool.description)
  """
  defdelegate get_tool(session, tool_id), to: :beam_agent

  @doc """
  Retrieve a specific skill definition by its identifier.

  Looks up a single skill from the session's skill registry. Use this to
  inspect a skill's metadata or verify it exists before referencing it in
  a query or configuration change.

  ## Parameters

  - `session` -- pid of a running session.
  - `skill_id` -- binary skill identifier.

  ## Returns

  - `{:ok, skill_map}` where `skill_map` contains `:name` (binary skill
    identifier), `:description` (what the skill does), and `:path` (file
    path to the skill definition).
  - `{:error, :not_found}` if no skill with that identifier is registered.
  - `{:error, reason}` on other failures.
  """
  defdelegate get_skill(session, skill_id), to: :beam_agent

  @doc """
  Retrieve a specific plugin definition by its identifier.

  Looks up a single plugin from the session's plugin registry. Use this
  to check whether a plugin is enabled, inspect its contributed tools, or
  verify it exists before toggling its state.

  ## Parameters

  - `session` -- pid of a running session.
  - `plugin_id` -- binary plugin identifier.

  ## Returns

  - `{:ok, plugin_map}` where `plugin_map` contains `:name` (binary),
    `:description` (what the plugin provides), `:enabled` (boolean),
    and `:tools` (list of tool name binaries contributed by this plugin).
  - `{:error, :not_found}` if no plugin with that identifier is registered.
  - `{:error, reason}` on other failures.
  """
  defdelegate get_plugin(session, plugin_id), to: :beam_agent

  @doc """
  Retrieve a specific sub-agent definition by its identifier.

  Looks up a single sub-agent from the session's agent registry. Use this
  to inspect a sub-agent's capabilities before delegating work to it via
  `set_agent/2`, or to verify that a sub-agent identifier is valid.

  ## Parameters

  - `session` -- pid of a running session.
  - `agent_id` -- binary agent identifier.

  ## Returns

  - `{:ok, agent_map}` where `agent_map` contains `:name` (binary),
    `:description` (what the sub-agent specializes in), and `:capabilities`
    (list of capability atoms the sub-agent supports).
  - `{:error, :not_found}` if no sub-agent with that identifier exists.
  - `{:error, reason}` on other failures.
  """
  defdelegate get_agent(session, agent_id), to: :beam_agent

  @doc """
  Get the currently active LLM provider for a session.

  Providers represent authentication and API endpoints for LLM services
  (e.g., Anthropic, OpenAI, Google). This is most relevant for backends
  like OpenCode that support routing queries to different LLM providers.
  If no provider has been explicitly set, returns `{:error, :not_set}`
  indicating the backend's default provider is in use.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, provider_id}` where `provider_id` is a binary (e.g.,
    `"anthropic"`, `"openai"`).
  - `{:error, :not_set}` if no provider has been explicitly selected.
  """
  defdelegate current_provider(session), to: :beam_agent

  @doc """
  Set the active LLM provider for a session.

  Changes which LLM service endpoint handles subsequent queries. Use
  `provider_list/1` to discover available providers before calling this.
  The change takes effect immediately for the next query.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`,
    `"openai"`, `"google"`).

  ## Returns

  `:ok`

  ## Examples

      :ok = BeamAgent.set_provider(session, "anthropic")
  """
  defdelegate set_provider(session, provider_id), to: :beam_agent

  @doc """
  Clear the active provider selection and revert to the backend's default.

  Undoes a previous `set_provider/2` call so the session uses the
  backend's default LLM provider for subsequent queries.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  `:ok`
  """
  defdelegate clear_provider(session), to: :beam_agent

  @doc """
  Get the currently active sub-agent for a session.

  Returns the identifier of the sub-agent that is currently handling
  delegated work. When no sub-agent has been explicitly activated via
  `set_agent/2`, this returns `{:error, :not_set}`, meaning the primary
  agent handles all queries directly.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agent_id}` where `agent_id` is a binary sub-agent identifier.
  - `{:error, :not_set}` if no sub-agent is active (primary agent in use).
  """
  defdelegate current_agent(session), to: :beam_agent

  @doc """
  Set the active sub-agent for a session.

  Activates a sub-agent so that subsequent queries are routed through it
  instead of the primary agent. Sub-agents specialize in tasks like code
  review or test generation. Use `supported_agents/1` or `list_agents/1`
  to discover valid identifiers before calling this.

  ## Parameters

  - `session` -- pid of a running session.
  - `agent_id` -- binary sub-agent identifier.

  ## Returns

  `:ok`

  ## Examples

      :ok = BeamAgent.set_agent(session, "code-reviewer")
  """
  defdelegate set_agent(session, agent_id), to: :beam_agent

  @doc """
  Clear the active sub-agent and revert to the primary agent.

  Undoes a previous `set_agent/2` call so that subsequent queries are
  handled directly by the primary agent rather than a sub-agent.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  `:ok`
  """
  defdelegate clear_agent(session), to: :beam_agent

  @doc """
  List all known capabilities across all backends.

  Returns the full capability matrix as a list of capability info maps.
  Each entry describes one capability (e.g., `:query`, `:threads`, `:mcp`)
  with its support level across all five backends.

  ## Examples

      caps = BeamAgent.capabilities()
      for cap <- caps, do: IO.puts(cap[:name])
  """
  defdelegate capabilities(), to: :beam_agent

  @doc """
  List capabilities for a specific session or backend.

  When given a pid, queries the live session for its backend and returns
  that backend's capability set. When given a backend atom or binary,
  returns the static capability set for that backend without requiring
  a running session.

  ## Parameters

  - `value` -- a session pid, backend atom (e.g., `:claude`), or binary.

  ## Returns

  - `{:ok, capabilities}` -- list of capability maps.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, caps} = BeamAgent.capabilities(:claude)
      {:ok, caps} = BeamAgent.capabilities(session)
  """
  defdelegate capabilities(value), to: :beam_agent

  @doc """
  Check whether a backend supports a specific capability.

  ## Parameters

  - `capability` -- capability atom (e.g., `:threads`, `:mcp`, `:query`).
  - `value` -- backend atom (e.g., `:claude`), binary, or other backend-like value.

  ## Returns

  - `{:ok, true}` when the capability is supported.
  - `{:error, {:unsupported_capability, name}}` when not supported.
  - `{:error, {:unknown_backend, backend}}` for unrecognized backends.

  ## Examples

      case BeamAgent.supports(:threads, :claude) do
        {:ok, true} -> IO.puts("Claude supports threads")
        {:error, _} -> IO.puts("Threads not supported")
      end
  """
  defdelegate supports(capability, value), to: :beam_agent

  @doc """
  Normalize a raw wire-format message into the SDK message format.

  Converts a backend-specific message map into the canonical `t:message/0`
  format used throughout the SDK. Applies type detection from the message
  content, normalizes field names, and adds any missing required keys with
  default values.

  ## Parameters

  - `raw` -- a raw message map from the backend wire format.

  ## Returns

  A normalized `t:message/0` map.
  """
  defdelegate normalize_message(raw), to: :beam_agent

  @doc """
  Generate a unique request identifier.

  Produces a binary UUID suitable for use as a control message `request_id`
  or query correlation identifier.

  ## Returns

  A binary UUID string.
  """
  defdelegate make_request_id(), to: :beam_agent

  @doc """
  Parse a raw stop reason value into a `t:stop_reason/0` atom.

  Accepts binaries (`"end_turn"`), strings, or atoms and returns the
  corresponding `t:stop_reason/0` atom for pattern matching. Unrecognized
  values are mapped to `:unknown`.

  ## Parameters

  - `reason` -- the raw stop reason value.

  ## Returns

  A `t:stop_reason/0` atom.
  """
  defdelegate parse_stop_reason(reason), to: :beam_agent

  @doc """
  Parse a raw permission mode value into a `t:permission_mode/0` atom.

  Accepts binaries (`"auto"`), strings, or atoms and returns the
  corresponding `t:permission_mode/0` atom. Unrecognized values are
  mapped to `:default`.

  ## Parameters

  - `mode` -- the raw permission mode value.

  ## Returns

  A `t:permission_mode/0` atom.
  """
  defdelegate parse_permission_mode(mode), to: :beam_agent

  @doc """
  Collect messages from a subscription until a result message or deadline.

  Loops calling `receive_fun` to pull messages from the subscription
  identified by `ref`. Accumulates messages until either a message with
  `type: :result` arrives or the wall-clock `deadline` is reached.
  Returns all collected messages in order.

  This is the building block behind `query/2` synchronous semantics.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference.
  - `deadline` -- monotonic time deadline in milliseconds.
  - `receive_fun` -- a `t:receive_fun/0` that pulls the next message.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate collect_messages(session, ref, deadline, receive_fun), to: :beam_agent

  @doc """
  Collect messages with a custom terminal predicate.

  Same as `collect_messages/4` but stops when `terminal_pred` returns `true`
  for a message instead of checking for `type: :result`. This allows callers
  to define their own completion condition (e.g., stop on the first
  `:tool_use` message, or after N text chunks).

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference.
  - `deadline` -- monotonic time deadline in milliseconds.
  - `receive_fun` -- a `t:receive_fun/0` that pulls the next message.
  - `terminal_pred` -- a `t:terminal_pred/0` function.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate collect_messages(session, ref, deadline, receive_fun, terminal_pred),
    to: :beam_agent

  # ---------------------------------------------------------------------------
  # Streaming (Elixir-only convenience functions)
  # ---------------------------------------------------------------------------

  @doc """
  Stream query responses as an `Enumerable` (raises on errors).

  Sends a query and returns a lazy `Stream` that yields each response
  message as it arrives. Raises on query failure or timeout.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- optional query parameters (keyword list or map).

  ## Returns

  An `Enumerable.t()` of `t:message/0` maps.

  ## Examples

      session
      |> BeamAgent.stream!("Explain GenServer")
      |> Enum.each(fn msg ->
        IO.write(msg[:content] || "")
      end)
  """
  @spec stream!(pid(), binary(), keyword() | map()) :: Enumerable.t()
  def stream!(session, prompt, params \\ %{}) when is_pid(session) and is_binary(prompt) do
    query_params = opts_to_map(params)
    timeout = Map.get(query_params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :beam_agent_router.send_query(session, prompt, query_params, timeout) do
          {:ok, ref} -> {session, ref, deadline, false}
          {:error, reason} -> raise "Query failed: #{inspect(reason)}"
        end
      end,
      fn
        {:done, _, _, _} = done ->
          {:halt, done}

        {sess, ref, dl, received_message?} ->
          remaining = dl - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            raise "Stream error: timeout"
          else
            case :beam_agent_router.receive_message(sess, ref, remaining) do
              {:ok, msg} ->
                {[msg], {sess, ref, dl, true}}

              {:error, :complete} ->
                {:halt, {sess, ref, dl, received_message?}}

              {:error, :no_active_query} when received_message? ->
                {:halt, {sess, ref, dl, received_message?}}

              {:error, reason} ->
                raise "Stream error: #{inspect(reason)}"
            end
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Stream query responses as an `Enumerable` (returns tagged tuples).

  Like `stream!/3` but wraps each message in `{:ok, msg}` and errors in
  `{:error, reason}` instead of raising. Suitable for pipelines that need
  to handle errors gracefully.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- optional query parameters (keyword list or map).

  ## Returns

  An `Enumerable.t()` of `{:ok, message()}` or `{:error, reason}` tuples.

  ## Examples

      session
      |> BeamAgent.stream("Explain OTP")
      |> Enum.each(fn
        {:ok, msg} -> IO.write(msg[:content] || "")
        {:error, reason} -> IO.puts("Error: \#{inspect(reason)}")
      end)
  """
  @spec stream(pid(), binary(), keyword() | map()) :: Enumerable.t()
  def stream(session, prompt, params \\ %{}) when is_pid(session) and is_binary(prompt) do
    query_params = opts_to_map(params)
    timeout = Map.get(query_params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :beam_agent_router.send_query(session, prompt, query_params, timeout) do
          {:ok, ref} -> {session, ref, deadline, false}
          {:error, _} = err -> {:error_init, err}
        end
      end,
      fn
        {:error_init, err} ->
          {[err], :halt_state}

        :halt_state ->
          {:halt, :halt_state}

        {sess, ref, dl, received_message?} ->
          remaining = dl - System.monotonic_time(:millisecond)

          cond do
            remaining <= 0 ->
              {[{:error, :timeout}], :halt_state}

            true ->
              case :beam_agent_router.receive_message(sess, ref, remaining) do
                {:ok, msg} ->
                  {[{:ok, msg}], {sess, ref, dl, true}}

                {:error, :complete} ->
                  {:halt, {sess, ref, dl, received_message?}}

                {:error, :no_active_query} when received_message? ->
                  {:halt, {sess, ref, dl, received_message?}}

                {:error, reason} ->
                  {[{:error, reason}], :halt_state}
              end
          end
      end,
      fn _ -> :ok end
    )
  end

  # ---------------------------------------------------------------------------
  # Session Store Operations
  # ---------------------------------------------------------------------------

  @doc """
  List all tracked sessions from the universal session store.

  Returns session metadata maps sorted by `updated_at` descending.
  Sessions are tracked automatically when messages are recorded.

  ## Returns

  - `{:ok, sessions}` where each entry is a `t:session_info_map/0`.

  ## Examples

      {:ok, sessions} = BeamAgent.list_sessions()
      for s <- sessions do
        IO.puts("\#{s.session_id} (\#{s.model})")
      end
  """
  @spec list_sessions() :: {:ok, [session_info_map()]}
  def list_sessions, do: BeamAgent.SessionStore.list_sessions()

  @doc """
  List tracked sessions with optional filters.

  ## Parameters

  - `opts` -- filter map with optional keys:
    - `:adapter` -- filter by backend atom
    - `:cwd` -- filter by working directory
    - `:model` -- filter by model name
    - `:limit` -- maximum number of results
    - `:since` -- unix millisecond timestamp lower bound on `updated_at`

  ## Returns

  - `{:ok, sessions}` sorted by `updated_at` descending.
  """
  @spec list_sessions(map()) :: {:ok, [session_info_map()]}
  def list_sessions(opts) when is_map(opts), do: BeamAgent.SessionStore.list_sessions(opts)

  @doc """
  List sessions from the backend's native session store (Claude-specific).

  Attempts to call the Claude backend's native session listing. Falls back
  to `list_sessions/0` if the backend does not support native session listing.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  defdelegate list_native_sessions(), to: :beam_agent

  @doc """
  List sessions from the backend's native session store with filters.

  Like `list_native_sessions/0` but passes filter options to the native call.
  Falls back to `list_sessions/1` if native listing is not supported.

  ## Parameters

  - `opts` -- backend-specific filter options map.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  defdelegate list_native_sessions(opts), to: :beam_agent

  @doc """
  Get all messages for a session from the universal store.

  Returns the full message history in chronological order.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, messages}` or `{:error, :not_found}` if no session exists
    with that identifier.

  ## Examples

      {:ok, messages} = BeamAgent.get_session_messages("sess_abc123")
      IO.puts("Total messages: \#{length(messages)}")
  """
  @spec get_session_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id),
    do: BeamAgent.SessionStore.get_session_messages(session_id)

  @doc """
  Get messages for a session with filtering options.

  ## Parameters

  - `session_id` -- binary session identifier.
  - `opts` -- filter map with optional keys:
    - `:limit` -- maximum number of messages to return
    - `:offset` -- skip this many messages from the start
    - `:types` -- list of `t:message_type/0` atoms to include
    - `:include_hidden` -- if `true`, include reverted/hidden messages

  ## Returns

  - `{:ok, messages}` or `{:error, :not_found}`.
  """
  @spec get_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id, opts) when is_map(opts) do
    BeamAgent.SessionStore.get_session_messages(session_id, opts)
  end

  @doc """
  Get messages from the backend's native session store (Claude-specific).

  Falls back to `get_session_messages/1` if native message retrieval is
  not supported by the backend.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate get_native_session_messages(session_id), to: :beam_agent

  @doc """
  Get messages from the backend's native session store with options.

  Falls back to `get_session_messages/2` if native retrieval is not supported.

  ## Parameters

  - `session_id` -- binary session identifier.
  - `opts` -- backend-specific message filter options.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent

  @doc """
  Get metadata for a specific session by identifier.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, session_meta}` or `{:error, :not_found}`.
  """
  @spec get_session(binary()) :: {:ok, session_info_map()} | {:error, :not_found}
  def get_session(session_id), do: BeamAgent.SessionStore.get_session(session_id)

  @doc """
  Delete a session and all its messages from the universal store.

  Also signals completion to any active event subscribers for that session.
  Idempotent -- deleting a nonexistent session is a no-op.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  `:ok`
  """
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: BeamAgent.SessionStore.delete_session(session_id)

  @doc """
  Create a fork (copy) of a session's metadata and message history.

  The new session receives a copy of all messages and metadata from the
  source session.

  ## Parameters

  - `session_or_id` -- pid of the source session.
  - `opts` -- fork options map. Optional keys:
    - `:session_id` -- explicit id for the fork (auto-generated if omitted)
    - `:include_hidden` -- include reverted messages (default `true`)
    - `:extra` -- additional metadata to merge into the fork

  ## Returns

  - `{:ok, fork_meta}` or `{:error, :not_found}`.
  """
  @spec fork_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def fork_session(session_or_id, opts),
    do: BeamAgent.SessionStore.fork_session(session_or_id, opts)

  @doc """
  Revert a session's visible conversation state to a prior boundary.

  The underlying message store remains append-only. Revert changes the
  active view by storing a `visible_message_count` in the session metadata.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `selector` -- boundary selector map. Accepts one of:
    - `%{visible_message_count: n}` -- set boundary to N messages
    - `%{message_id: id}` -- set boundary to the message with this id
    - `%{uuid: id}` -- set boundary to the message with this uuid

  ## Returns

  - `{:ok, updated_meta}` or `{:error, :not_found | :invalid_selector}`.
  """
  @spec revert_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def revert_session(session_or_id, selector),
    do: BeamAgent.SessionStore.revert_session(session_or_id, selector)

  @doc """
  Clear any revert state and restore the full visible message history.

  Undoes a previous `revert_session/2` call so all messages are visible again.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec unrevert_session(pid()) :: {:ok, session_info_map()} | {:error, term()}
  def unrevert_session(session_or_id), do: BeamAgent.SessionStore.unrevert_session(session_or_id)

  @doc """
  Generate a shareable link/state for a session.

  Creates or replaces the active share state with a generated `share_id`.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, share_info}` with `:share_id`, `:session_id`, `:created_at`, and
    `:status` fields.
  - `{:error, :not_found}`.
  """
  @spec share_session(pid()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id), do: BeamAgent.SessionStore.share_session(session_or_id)

  @doc """
  Generate a shareable link/state for a session with options.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `opts` -- options map. Optional keys:
    - `:share_id` -- explicit share identifier (auto-generated if omitted)

  ## Returns

  - `{:ok, share_info}` or `{:error, :not_found}`.
  """
  @spec share_session(pid(), map()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id, opts),
    do: BeamAgent.SessionStore.share_session(session_or_id, opts)

  @doc """
  Revoke the current share state for a session.

  Marks the share as revoked. The `share_id` remains in metadata but its
  status changes to `:revoked`.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `:ok` or `{:error, :not_found}`.
  """
  @spec unshare_session(pid()) :: :ok | {:error, term()}
  def unshare_session(session_or_id), do: BeamAgent.SessionStore.unshare_session(session_or_id)

  @doc """
  Generate and store a summary for a session's conversation history.

  Produces a deterministic summary from the session's messages including
  the first user message and latest agent output.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, summary_map}` with `:content`, `:generated_at`, `:message_count`,
    and `:generated_by` fields.
  - `{:error, :not_found}`.
  """
  @spec summarize_session(pid()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id),
    do: BeamAgent.SessionStore.summarize_session(session_or_id)

  @doc """
  Generate and store a session summary with options.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `opts` -- options map. Optional keys:
    - `:content` / `:summary` -- explicit summary text (skips auto-generation)
    - `:generated_by` -- attribution string (default `"beam_agent_core"`)

  ## Returns

  - `{:ok, summary_map}` or `{:error, :not_found}`.
  """
  @spec summarize_session(pid(), map()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id, opts),
    do: BeamAgent.SessionStore.summarize_session(session_or_id, opts)

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc """
  Start a new conversation thread within a session.

  Creates a named thread that groups related queries. The new thread
  becomes the active thread for the session. Thread messages are stored
  as a subset of the session's message history, tagged with `thread_id`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- thread options map. Optional keys:
    - `:name` -- human-readable thread name (defaults to the `thread_id`)
    - `:thread_id` -- explicit id (auto-generated if omitted)
    - `:metadata` -- arbitrary metadata map
    - `:parent_thread_id` -- id of the parent thread (for fork lineage)

  ## Returns

  - `{:ok, thread_meta}` with `:thread_id`, `:session_id`, `:name`, `:status`,
    and other metadata fields.
  - `{:error, reason}`.

  ## Examples

      {:ok, thread} = BeamAgent.thread_start(session, %{
        name: "refactor-discussion"
      })
      thread_id = thread.thread_id
      {:ok, _messages} = BeamAgent.query(session, "Let's refactor the router")
  """
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_start(session, opts), do: BeamAgent.Threads.thread_start(session, opts)

  @doc """
  Resume an existing thread by its identifier.

  Sets the thread as the active thread for the session and updates its
  status to active. Subsequent queries will be associated with this thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, thread_meta}` or `{:error, :not_found}`.

  ## Examples

      {:ok, thread} = BeamAgent.thread_resume(session, "thread_abc123")
      IO.puts("Resumed: \#{thread.name}")
  """
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id), do: BeamAgent.Threads.thread_resume(session, thread_id)

  @doc """
  Resume an existing thread with backend-specific options.

  Like `thread_resume/2` but passes additional options to the backend's
  native implementation. Falls back to `thread_resume/2` if the backend
  does not support extended resume options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- backend-specific resume options.

  ## Returns

  - `{:ok, thread_meta}` or `{:error, :not_found}`.
  """
  defdelegate thread_resume(session, thread_id, opts), to: :beam_agent

  @doc """
  List all threads for a session, sorted by `updated_at` descending.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, thread_list}` where each entry is a thread metadata map.
  - `{:error, reason}`.
  """
  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, term()}
  def thread_list(session), do: BeamAgent.Threads.thread_list(session)

  @doc """
  List threads for a session with backend-specific options.

  Falls back to `thread_list/1` if the backend does not support filtered
  thread listing.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific listing options.

  ## Returns

  - `{:ok, thread_list}` or `{:error, reason}`.
  """
  defdelegate thread_list(session, opts), to: :beam_agent

  @doc """
  Fork an existing thread, copying its visible message history.

  Creates a new thread with a copy of all visible messages from the source
  thread. Message `thread_id` fields are rewritten to the new thread id.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary identifier of the source thread.

  ## Returns

  - `{:ok, forked_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id), do: BeamAgent.Threads.thread_fork(session, thread_id)

  @doc """
  Fork an existing thread with options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary identifier of the source thread.
  - `opts` -- fork options map. Optional keys:
    - `:thread_id` -- explicit id for the fork
    - `:name` -- name for the forked thread
    - `:parent_thread_id` -- override the parent reference

  ## Returns

  - `{:ok, forked_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id, opts),
    do: BeamAgent.Threads.thread_fork(session, thread_id, opts)

  @doc """
  Read thread metadata and optionally its message history.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, %{thread: thread_meta}}` or `{:error, :not_found}`.
  """
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id), do: BeamAgent.Threads.thread_read(session, thread_id)

  @doc """
  Read thread metadata with options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- options map. Optional keys:
    - `:include_messages` -- if `true`, includes the `:messages` key in the result

  ## Returns

  - `{:ok, %{thread: thread_meta, messages: [message()]}}` or `{:error, :not_found}`.
  """
  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id, opts),
    do: BeamAgent.Threads.thread_read(session, thread_id, opts)

  @doc """
  Archive a thread, marking it as archived and inactive.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_archive(session, thread_id), do: BeamAgent.Threads.thread_archive(session, thread_id)

  @doc """
  Unsubscribe from a thread and clear it as the active thread if applicable.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, result_map}` with `:thread_id` and `:unsubscribed` fields.
  - `{:error, :not_found}`.
  """
  defdelegate thread_unsubscribe(session, thread_id), to: :beam_agent

  @doc """
  Rename a thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `name` -- new thread name as a binary.

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  defdelegate thread_name_set(session, thread_id, name), to: :beam_agent

  @doc """
  Merge a metadata patch into a thread's metadata map.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `metadata_patch` -- map of key-value pairs to merge into the thread's
    existing metadata.

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  defdelegate thread_metadata_update(session, thread_id, metadata_patch), to: :beam_agent

  @doc """
  Unarchive a previously archived thread, restoring it to active status.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_unarchive(session, thread_id),
    do: BeamAgent.Threads.thread_unarchive(session, thread_id)

  @doc """
  Rollback a thread's visible message history to a prior boundary.

  The underlying messages are preserved; only the visible window changes.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `selector` -- boundary selector map. Accepts one of:
    - `%{count: n}` -- hide the last N visible messages
    - `%{visible_message_count: n}` -- set boundary directly
    - `%{message_id: id}` or `%{uuid: id}` -- set boundary to a message

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found | :invalid_selector}`.
  """
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_rollback(session, thread_id, selector),
    do: BeamAgent.Threads.thread_rollback(session, thread_id, selector)

  @doc """
  List loaded (in-memory) threads for a session.

  Returns threads with their active state, optionally filtered by the
  backend's native implementation.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` with `:threads`, `:active_thread_id`, and `:count` fields.
  - `{:error, reason}`.
  """
  defdelegate thread_loaded_list(session), to: :beam_agent

  @doc """
  List loaded threads for a session with filter options.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Optional keys:
    - `:include_archived` -- include archived threads (default `true`)
    - `:thread_id` -- filter to a specific thread
    - `:status` -- filter by thread status
    - `:limit` -- maximum number of results

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  defdelegate thread_loaded_list(session, opts), to: :beam_agent

  @doc """
  Compact a thread by reducing its visible message history.

  Uses `thread_rollback` internally with a selector derived from the
  options map. If no selector is provided, compacts to zero visible messages.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- compaction options map. Optional keys:
    - `:thread_id` -- target thread (defaults to active thread)
    - `:count` -- number of messages to hide from the end
    - `:visible_message_count` -- set boundary directly
    - `:selector` -- explicit rollback selector map

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  defdelegate thread_compact(session, opts), to: :beam_agent

  @doc """
  Steer an active turn by injecting additional input mid-conversation.

  Allows you to redirect or refine the agent's current turn within a
  thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary identifier of the active turn.
  - `input` -- steering input, either a binary prompt or a list of
    structured content block maps.

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  defdelegate turn_steer(session, thread_id, turn_id, input), to: :beam_agent

  @doc """
  Steer an active turn with additional options.

  Like `turn_steer/4` but accepts an options map for backend-specific
  steering parameters.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary identifier of the active turn.
  - `input` -- steering input (binary or structured content blocks).
  - `opts` -- backend-specific options map.

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  defdelegate turn_steer(session, thread_id, turn_id, input, opts), to: :beam_agent

  @doc """
  Interrupt a specific turn within a thread.

  Cancels the identified turn. The universal fallback delegates to
  `interrupt/1` on the session.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `turn_id` -- binary turn identifier.

  ## Returns

  - `{:ok, result_map}` with `status: :interrupted`.
  - `{:error, reason}`.
  """
  defdelegate turn_interrupt(session, thread_id, turn_id), to: :beam_agent

  @doc """
  Start a realtime collaboration thread for voice or audio streaming.

  Creates a dedicated thread optimized for continuous input streaming,
  such as live voice transcription or incremental text input. Once started,
  use `thread_realtime_append_audio/3` or `thread_realtime_append_text/3`
  to feed data into the thread, and `thread_realtime_stop/2` to tear it down.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- realtime session options map. Supported keys:
    - `:mode` -- streaming mode, one of `:voice` or `:text`
    - `:model` -- binary model identifier to use for the realtime session
    - `:encoding` -- audio encoding parameters map (e.g., sample rate, format)

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:thread_id` (binary
    identifier for the new realtime thread) and `:status` (atom, typically
    `:active`).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, rt} = BeamAgent.thread_realtime_start(session, %{mode: :voice})
      thread_id = rt.thread_id
  """
  defdelegate thread_realtime_start(session, opts), to: :beam_agent

  @doc """
  Append encoded audio data to an active realtime thread.

  Sends a chunk of audio to a realtime thread previously started with
  `thread_realtime_start/2`. Audio chunks are processed incrementally,
  enabling live transcription and streaming responses. Call this
  repeatedly as audio data becomes available.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier returned by
    `thread_realtime_start/2`.
  - `opts` -- map containing the audio payload:
    - `:audio_data` -- binary containing the encoded audio bytes
    - `:encoding` -- (optional) encoding metadata map overriding the
      session-level encoding (e.g., `%{format: "pcm", sample_rate: 16000}`)

  ## Returns

  - `{:ok, result_map}` with acknowledgment status.
  - `{:error, reason}` on failure.
  """
  defdelegate thread_realtime_append_audio(session, thread_id, opts), to: :beam_agent

  @doc """
  Append text content to an active realtime stream.

  Sends a text chunk to a realtime thread previously started with
  `thread_realtime_start/2`. Use this for incremental text input in
  text-mode realtime sessions, analogous to `thread_realtime_append_audio/3`
  for voice-mode sessions.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier returned by
    `thread_realtime_start/2`.
  - `opts` -- map containing the text payload:
    - `:text` -- binary string to append to the realtime stream

  ## Returns

  - `{:ok, result_map}` with acknowledgment status.
  - `{:error, reason}` on failure.
  """
  defdelegate thread_realtime_append_text(session, thread_id, opts), to: :beam_agent

  @doc """
  Stop and tear down an active realtime collaboration thread.

  Terminates the realtime streaming session, flushes any buffered data,
  and releases associated resources. After this call, the `thread_id` is
  no longer valid for appending audio or text. Any final results from the
  realtime session are included in the returned status map.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier returned by
    `thread_realtime_start/2`.

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:thread_id` and
    `:status` (atom, typically `:stopped`).
  - `{:error, reason}` on failure.
  """
  defdelegate thread_realtime_stop(session, thread_id), to: :beam_agent

  @doc """
  Start a code review collaboration session.

  Initiates a structured code review workflow where the agent analyzes
  source code for issues, style violations, and improvement opportunities.
  Configure the review scope to target specific files, a git diff range,
  or an entire directory.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- review session options map. Supported keys:
    - `:file_paths` -- list of binary file paths to review
    - `:diff_range` -- binary git diff range (e.g., `"main..HEAD"`)
    - `:review_type` -- atom specifying the review focus (e.g., `:security`,
      `:performance`, `:style`, `:general`)

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:review_id` (binary
    identifier for the review session).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, review} = BeamAgent.review_start(session, %{
        file_paths: ["lib/my_module.ex"],
        review_type: :general
      })
      IO.puts("Review started: \#{review.review_id}")
  """
  defdelegate review_start(session, opts), to: :beam_agent

  @doc """
  List collaboration modes available for the session.

  Collaboration modes are high-level interaction patterns the backend
  supports beyond standard query/response. Common modes include `:review`
  (structured code review), `:realtime` (live voice/text streaming), and
  `:pair` (pair programming). Use this to discover which modes are
  available before starting a collaboration session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, modes_map}` where `modes_map` is a map keyed by mode name atom
    (e.g., `:review`, `:realtime`), with each value being a map of
    capability details describing what the mode supports.
  - `{:error, reason}` on failure.
  """
  defdelegate collaboration_mode_list(session), to: :beam_agent

  @doc """
  List experimental features available for the session with no filters.

  Convenience wrapper that calls `experimental_feature_list/2` with an
  empty options map. Returns all experimental and beta features the backend
  exposes, regardless of category or enabled state.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, features}` where `features` is a list of feature maps, each
    containing `:id` (binary), `:name` (binary), `:description` (binary),
    and `:enabled` (boolean indicating whether the feature is active).
  - `{:error, reason}` on failure.
  """
  defdelegate experimental_feature_list(session), to: :beam_agent

  @doc """
  List experimental and beta features with filter options.

  Experimental features are capabilities that are not yet stable or
  generally available. Use this to discover, inspect, and selectively
  enable beta functionality. Filter by category or name to narrow results.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:category` -- binary category to filter by (e.g., `"ai"`, `"ui"`)
    - `:name` -- binary name or name pattern to match

  ## Returns

  - `{:ok, features}` where `features` is a list of feature maps, each
    containing `:id` (binary), `:name` (binary), `:description` (binary),
    and `:enabled` (boolean).
  - `{:error, reason}` on failure.
  """
  defdelegate experimental_feature_list(session, opts), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Skills
  # ---------------------------------------------------------------------------

  @doc """
  List skills for the session using native-first routing.

  Convenience wrapper that calls `skills_list/2` with empty options.
  Attempts the backend's native skill listing first; if the backend does
  not support native skill listing, falls back to `list_skills/1`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, skills}` where `skills` is a list of skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  defdelegate skills_list(session), to: :beam_agent

  @doc """
  List skills for the session with filter options.

  Returns skills matching the provided filters. Skills are reusable prompt
  templates or multi-step workflows. Use the filter options to narrow
  results by category, enabled state, or name pattern.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:category` -- binary category to filter by
    - `:enabled` -- boolean to filter by enabled/disabled state
    - `:name_pattern` -- binary pattern to match against skill names

  ## Returns

  - `{:ok, skills}` where `skills` is a list of skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  defdelegate skills_list(session, opts), to: :beam_agent

  @doc """
  List skills available from the remote registry.

  Convenience wrapper that calls `skills_remote_list/2` with empty options.
  Queries the remote skill registry for skills that can be imported into
  the session. Remote skills are community or organization-shared
  templates not yet installed locally.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, skills}` where `skills` is a list of remote skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  defdelegate skills_remote_list(session), to: :beam_agent

  @doc """
  List skills from the remote registry with filter options.

  Queries the remote skill registry and filters results. Use this to
  search for specific skills by registry source, category, or name
  before importing them into the session.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:registry` -- binary registry identifier to query
    - `:category` -- binary category to filter by
    - `:name` -- binary name or name pattern to match

  ## Returns

  - `{:ok, skills}` where `skills` is a list of remote skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  defdelegate skills_remote_list(session, opts), to: :beam_agent

  @doc """
  Export a local skill to a remote registry.

  Publishes a skill definition from the session's local skill store to a
  remote registry, making it available for other users or sessions to
  import. The skill must already exist locally.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- export options map. Required keys:
    - `:skill_path` -- binary file path identifying the local skill to export

  ## Returns

  - `{:ok, result_map}` where `result_map` contains export confirmation
    details such as the remote registry URL and export status.
  - `{:error, reason}` on failure.
  """
  defdelegate skills_remote_export(session, opts), to: :beam_agent

  @doc """
  Enable or disable a skill by its file path.

  Writes a configuration entry that controls whether a skill is active.
  When disabled, the skill remains in the registry but is not available
  for use in queries. Re-enable by calling with `enabled: true`.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary file path identifying the skill (as returned in the
    `:path` field of skill maps from `skills_list/1`).
  - `enabled` -- boolean: `true` to enable, `false` to disable.

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:path` (the skill
    path) and `:enabled` (the new boolean state).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, _} = BeamAgent.skills_config_write(session, "/skills/review.md", false)
  """
  defdelegate skills_config_write(session, path, enabled), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Apps
  # ---------------------------------------------------------------------------

  @doc """
  List apps and projects registered for the session.

  Convenience wrapper that calls `apps_list/2` with empty options. Returns
  all known apps/projects associated with the session, both active and
  archived.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, apps}` where `apps` is a list of app maps, each containing
    `:id` (binary), `:name` (binary), `:path` (binary project root),
    and `:status` (atom such as `:active` or `:archived`).
  - `{:error, reason}` on failure.
  """
  defdelegate apps_list(session), to: :beam_agent

  @doc """
  List apps and projects for the session with filter options.

  Returns a filtered list of apps/projects. Use the options to narrow
  results by status or name, for example to show only active projects
  in a selection UI.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:status` -- atom to filter by (`:active` or `:archived`)
    - `:name` -- binary name or name pattern to match

  ## Returns

  - `{:ok, apps}` where `apps` is a list of app maps, each containing
    `:id` (binary), `:name` (binary), `:path` (binary project root),
    and `:status` (atom).
  - `{:error, reason}` on failure.
  """
  defdelegate apps_list(session, opts), to: :beam_agent

  @doc """
  Get information about the current app or project context for a session.

  Returns metadata about the project the session is operating in, including
  the project name, root directory, detected language, and configuration.
  This is populated by `app_init/1` or automatically when the session starts.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, app_info}` where `app_info` is a map containing `:name` (binary
    project name), `:root_path` (binary absolute path to the project root),
    `:language` (binary detected primary language, e.g., `"elixir"`),
    and `:config` (map of project-level configuration).
  - `{:error, reason}` on failure.
  """
  defdelegate app_info(session), to: :beam_agent

  @doc """
  Initialize the app/project context by scanning the working directory.

  Detects the project type, primary language, build system, and other
  project metadata by inspecting files in the session's working directory
  (e.g., `mix.exs` for Elixir, `rebar.config` for Erlang, `package.json`
  for Node.js). The detected context is stored and returned by subsequent
  `app_info/1` calls.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` with the initialized project context.
  - `{:error, reason}` on failure.
  """
  defdelegate app_init(session), to: :beam_agent

  @doc """
  Append a log entry to the session's app log.

  Records a structured log message associated with the current app/project.
  Useful for tracking significant events, warnings, or debugging information
  during an agent session. Log entries are stored in the session's ETS-backed
  app log.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- log entry map. Supported keys:
    - `:message` -- (required) binary log message text
    - `:level` -- (optional) atom log level (e.g., `:info`, `:warn`, `:error`)
    - `:category` -- (optional) binary category for grouping log entries
    - `:metadata` -- (optional) map of additional key-value pairs

  ## Returns

  - `{:ok, %{status: :logged}}` on success.
  - `{:error, reason}` on failure.
  """
  defdelegate app_log(session, body), to: :beam_agent

  @doc """
  List available app modes for the session.

  App modes are configuration presets that change the agent's behavior for
  the current project. Common modes include `:default` (standard operation),
  `:debug` (verbose output with additional diagnostics), and `:verbose`
  (extra logging). Each mode is a named preset that sets multiple
  configuration keys at once.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, modes}` where `modes` is a list of mode maps, each describing
    a named configuration preset with its settings.
  - `{:error, reason}` on failure.
  """
  defdelegate app_modes(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Models
  # ---------------------------------------------------------------------------

  @doc """
  List models available for the session using native-first routing.

  Convenience wrapper that calls `model_list/2` with empty options. Attempts
  the backend's native model listing first; falls back to the static list
  from `supported_models/1` if the backend does not support dynamic model
  listing.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, models}` where `models` is a list of model maps, each
    containing `:name` and `:capabilities`.
  - `{:error, reason}` on failure.
  """
  defdelegate model_list(session), to: :beam_agent

  @doc """
  List models with backend-specific filter options.

  Returns a filtered list of models available for the session. Filters
  are backend-specific and may include capabilities, context window size,
  or model family. Uses native-first routing with a fallback to
  `supported_models/1`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific filter options map.

  ## Returns

  - `{:ok, models}` where `models` is a list of model maps, each
    containing `:name` and `:capabilities`.
  - `{:error, reason}` on failure.
  """
  defdelegate model_list(session, opts), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Status & Auth
  # ---------------------------------------------------------------------------

  @doc """
  Get the overall status of a session including health and metadata.

  Assembles a comprehensive status snapshot combining the session's health
  state, connection status, backend identifier, model, and session metadata.
  The universal fallback constructs this from `session_info/1` and
  `health/1` when the backend lacks a native status endpoint.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status_map}` where `status_map` contains keys such as `:health`
    (atom like `:ready` or `:active_query`), `:backend` (atom),
    `:session_id` (binary), `:model` (binary), and `:connected` (boolean).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, status} = BeamAgent.get_status(session)
      IO.puts("Health: \#{status.health}, Model: \#{status.model}")
  """
  defdelegate get_status(session), to: :beam_agent

  @doc """
  Get the authentication status for the session's active provider.

  Returns whether the session is currently authenticated, which
  authentication method is in use, and token expiration details if
  applicable. The universal fallback derives this from `account_info/1`
  when the backend lacks a native auth status endpoint.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, auth_status}` where `auth_status` is a map containing
    `:authenticated` (boolean), `:auth_method` (atom such as `:api_key`,
    `:oauth`, or `:sso`), and `:expires_at` (integer unix timestamp or
    `nil` if the credential does not expire).
  - `{:error, reason}` on failure.
  """
  defdelegate get_auth_status(session), to: :beam_agent

  @doc """
  Get the backend's own session identifier for a running session.

  Returns the session ID as assigned by the backend (not the BEAM pid).
  This is useful for correlating SDK sessions with backend-side logs,
  dashboards, or support requests. The value is a backend-specific
  binary string.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, session_id}` where `session_id` is a binary backend-assigned
    identifier.
  - `{:error, reason}` on failure.
  """
  defdelegate get_last_session_id(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Server Sessions & Agents
  # ---------------------------------------------------------------------------

  @doc """
  List all persisted sessions known to the backend server.

  Queries the session store for every session associated with the current
  backend. Each entry in the returned list is a map containing at minimum
  a `:session_id` key.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  defdelegate list_server_sessions(session), to: :beam_agent

  @doc """
  Retrieve a single persisted session by its identifier.

  Returns the full session map for `session_id`, including message history
  when the backend supports it.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, session_map}` or `{:error, :not_found}`.
  """
  defdelegate get_server_session(session, session_id), to: :beam_agent

  @doc """
  Delete a persisted session from the backend server.

  Removes the session identified by `session_id` from the session store.
  Does not affect the currently running in-memory session.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier to delete.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate delete_server_session(session, session_id), to: :beam_agent

  @doc """
  List all sub-agents registered on the backend server.

  Returns the set of sub-agents the backend exposes. Sub-agents are
  specialized assistants (e.g., a code reviewer or test writer) that the
  primary agent can delegate to.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agents}` or `{:error, reason}`.
  """
  defdelegate list_server_agents(session), to: :beam_agent

  @doc """
  List commands available for the session using native-first routing.

  Attempts the backend's native command listing first. If the backend does
  not support dynamic command listing, falls back to the static list from
  `supported_commands/1`. The result may include commands added at runtime
  (e.g., via plugins or MCP servers) that are not in the static list.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, commands}` where `commands` is a list of command maps, each
    containing `:name` (binary command identifier) and `:description`
    (human-readable summary).
  - `{:error, reason}` on failure.
  """
  defdelegate list_commands(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  @doc """
  Read the full configuration for a session.

  Returns the merged configuration map that governs the session's
  behavior. This includes model settings, permission mode, system
  prompt, working directory, and any backend-specific keys.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, config_map}` or `{:error, reason}`.
  """
  defdelegate config_read(session), to: :beam_agent

  @doc """
  Read the session configuration with additional options.

  `opts` can filter or transform the returned configuration. The exact
  keys accepted depend on the backend.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter/transform options map.

  ## Returns

  - `{:ok, config_map}` or `{:error, reason}`.
  """
  defdelegate config_read(session, opts), to: :beam_agent

  @doc """
  Update the session configuration with a partial patch.

  Merges `body` into the existing configuration. Only the keys present
  in `body` are changed; all other keys are preserved.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- map of configuration key-value pairs to update.

  ## Returns

  - `{:ok, updated_config}` or `{:error, reason}`.
  """
  defdelegate config_update(session, body), to: :beam_agent

  @doc """
  List the providers available in the session configuration.

  A provider represents an LLM service endpoint (e.g., Anthropic,
  OpenAI, Google).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, providers}` or `{:error, reason}`.
  """
  defdelegate config_providers(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # File Operations
  # ---------------------------------------------------------------------------

  @doc """
  Search for text matching `pattern` in the session's working directory.

  Performs a grep-like search across files under the session's configured
  working directory. `pattern` is a binary string (not a regex). Returns a
  list of match maps, each containing the file path, line number, and
  matching line content.

  ## Parameters

  - `session` -- pid of a running session.
  - `pattern` -- binary search pattern.

  ## Returns

  - `{:ok, matches}` or `{:error, reason}`.

  ## Examples

      {:ok, matches} = BeamAgent.find_text(session, "TODO")
      for m <- matches do
        IO.puts("\#{m.path}:\#{m.line}: \#{m.content}")
      end
  """
  defdelegate find_text(session, pattern), to: :beam_agent

  @doc """
  Find files matching a pattern in the session's working directory.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- search options map. Common keys:
    - `:pattern` -- a glob or name substring to match (e.g., `"*.erl"`)
    - `:max_results` -- maximum number of files to return
    - `:include_hidden` -- whether to include dot-files (default `false`)

  ## Returns

  - `{:ok, files}` or `{:error, reason}`.

  ## Examples

      {:ok, files} = BeamAgent.find_files(session, %{pattern: "*.erl"})
      for f <- files, do: IO.puts(f.path)
  """
  defdelegate find_files(session, opts), to: :beam_agent

  @doc """
  Search for code symbols matching `query` in the session's project.

  Searches for function, module, type, and record definitions whose
  names match `query`. Returns a list of symbol maps with keys such as
  `:name`, `:kind`, `:path`, and `:line`.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- binary symbol name query.

  ## Returns

  - `{:ok, symbols}` or `{:error, reason}`.
  """
  defdelegate find_symbols(session, query), to: :beam_agent

  @doc """
  List files and directories at the given path.

  Returns directory entries as a list of maps. Each entry includes
  the `:name`, `:type` (file or directory), and `:size` where available.
  `path` is resolved relative to the session's working directory when
  it is not absolute.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary directory path.

  ## Returns

  - `{:ok, entries}` or `{:error, reason}`.
  """
  defdelegate file_list(session, path), to: :beam_agent

  @doc """
  Read the contents of a file at the given path.

  Returns the file content as a binary. `path` is resolved relative to
  the session's working directory when it is not absolute.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary file path.

  ## Returns

  - `{:ok, content}` or `{:error, :enoent}` if the file does not exist.
  """
  defdelegate file_read(session, path), to: :beam_agent

  @doc """
  Get the version-control status of files in the session's project.

  Returns a summary of file modifications, additions, and deletions
  relative to the project's version control baseline (typically git).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status}` or `{:error, reason}`.
  """
  defdelegate file_status(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Configuration Value Write
  # ---------------------------------------------------------------------------

  @doc """
  Write a single configuration value at the given key path.

  Convenience wrapper that calls `config_value_write/4` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `key_path` -- dot-separated binary identifying the config key
    (e.g., `"model"`, `"permissions.mode"`).
  - `value` -- the new value to store.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate config_value_write(session, key_path, value), to: :beam_agent

  @doc """
  Write a single configuration value at the given key path with options.

  `key_path` is a dot-separated binary identifying the configuration key.
  `opts` may include backend-specific write options such as scope or
  persistence level.

  ## Parameters

  - `session` -- pid of a running session.
  - `key_path` -- dot-separated binary config key path.
  - `value` -- the new value to store.
  - `opts` -- backend-specific write options map.

  ## Returns

  - `{:ok, result}` on success.
  - `{:error, reason}` if the key is read-only or the value is invalid.
  """
  defdelegate config_value_write(session, key_path, value, opts), to: :beam_agent

  @doc """
  Write multiple configuration values in a single batch.

  Convenience wrapper that calls `config_batch_write/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `edits` -- list of maps, each containing a `:key_path` and `:value`.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate config_batch_write(session, edits), to: :beam_agent

  @doc """
  Write multiple configuration values in a single batch with options.

  All edits are applied atomically when the backend supports it.

  ## Parameters

  - `session` -- pid of a running session.
  - `edits` -- list of maps, each containing a `:key_path` and `:value`.
  - `opts` -- backend-specific write options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}` if any edit fails validation.
  """
  defdelegate config_batch_write(session, edits, opts), to: :beam_agent

  @doc """
  Read the configuration requirements for a session.

  Returns the set of required configuration keys and their constraints
  (types, allowed values, defaults). Useful for building configuration
  UIs or validating user input before calling `config_update/2`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, requirements}` or `{:error, reason}`.
  """
  defdelegate config_requirements_read(session), to: :beam_agent

  @doc """
  Detect external agent configuration files in the project.

  Scans the session's working directory for configuration files from
  other agentic tools (e.g., `.cursorrules`, `CLAUDE.md`, `.github/copilot`).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, configs}` or `{:error, reason}`.
  """
  defdelegate external_agent_config_detect(session), to: :beam_agent

  @doc """
  Detect external agent configuration files with options.

  `opts` may include filters such as a list of specific config formats
  to detect or directories to scan.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- detection options map.

  ## Returns

  - `{:ok, configs}` or `{:error, reason}`.
  """
  defdelegate external_agent_config_detect(session, opts), to: :beam_agent

  @doc """
  Import an external agent configuration into the session.

  Takes a previously detected external config (from
  `external_agent_config_detect/1`) and merges its settings into the
  session configuration.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- import options map (should include the path or identifier
    of the config to import).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate external_agent_config_import(session, opts), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Providers & OAuth
  # ---------------------------------------------------------------------------

  @doc """
  List all available LLM providers for the session.

  Providers represent authentication and API endpoints for different LLM
  services (e.g., Anthropic, OpenAI, Google). Use this to discover which
  providers are configured and available for routing queries via
  `set_provider/2`. Uses native-first routing with a universal fallback.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, providers}` where `providers` is a list of provider maps, each
    containing `:id` (binary provider identifier), `:name` (human-readable
    display name), and `:status` (atom such as `:available` or
    `:unconfigured`).
  - `{:error, reason}` on failure.
  """
  defdelegate provider_list(session), to: :beam_agent

  @doc """
  List authentication methods available for each provider.

  Returns the supported authentication mechanisms (API key, OAuth, SSO)
  for all configured providers. Use this to determine which login flow
  to present to the user, or to check whether OAuth is available before
  calling `provider_oauth_authorize/3`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, auth_methods}` where `auth_methods` is a list of maps, each
    containing a `:provider_id` (binary) and `:methods` (list of method
    atoms such as `:api_key`, `:oauth`, or `:sso`).
  - `{:error, reason}` on failure.
  """
  defdelegate provider_auth_methods(session), to: :beam_agent

  @doc """
  Initiate an OAuth authorization flow for a specific provider.

  Starts the OAuth handshake by generating an authorization URL that the
  user should visit to grant access. After the user authorizes, the
  provider redirects to the specified URI with an authorization code that
  should be passed to `provider_oauth_callback/3` to complete the flow.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`).
  - `body` -- OAuth parameters map. Supported keys:
    - `:redirect_uri` -- binary callback URL for the OAuth redirect
    - `:scope` -- binary or list of OAuth scopes to request

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:authorization_url`
    (binary URL the user should visit to authorize).
  - `{:error, reason}` on failure.
  """
  defdelegate provider_oauth_authorize(session, provider_id, body), to: :beam_agent

  @doc """
  Handle an OAuth callback to complete the authorization flow.

  Exchanges the authorization code received from the OAuth redirect for
  an access token. This is the second step of the OAuth flow started by
  `provider_oauth_authorize/3`. On success, the session is authenticated
  with the provider and ready to route queries.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`).
  - `body` -- OAuth callback parameters map. Required keys:
    - `:code` -- binary authorization code from the OAuth redirect
    - `:state` -- binary state parameter for CSRF verification

  ## Returns

  - `{:ok, result_map}` where `result_map` contains token information
    such as `:access_token`, `:token_type`, and `:expires_in`.
  - `{:error, reason}` on failure (e.g., invalid code or state mismatch).
  """
  defdelegate provider_oauth_callback(session, provider_id, body), to: :beam_agent

  # ---------------------------------------------------------------------------
  # MCP (Model Context Protocol)
  # ---------------------------------------------------------------------------

  @doc """
  Get the status of all MCP (Model Context Protocol) servers.

  Returns a map of server names to their current status (connected,
  disconnected, error). This is a convenience alias for `mcp_server_status/1`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status_map}` or `{:error, reason}`.

  ## Examples

      {:ok, status} = BeamAgent.mcp_status(session)
      for {name, info} <- status do
        IO.puts("\#{name}: \#{info[:status]}")
      end
  """
  defdelegate mcp_status(session), to: :beam_agent

  @doc """
  Register a new MCP tool server with the session.

  `body` describes the server to add. It must contain a `:name` (binary) and
  a `:tools` list (list of tool definition maps). Each tool map should have
  at minimum a `:name` and `:description` key.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- server definition map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.

  ## Examples

      server = %{
        name: "my-tools",
        tools: [
          %{name: "greet", description: "Say hello", parameters: %{}}
        ]
      }
      {:ok, result} = BeamAgent.add_mcp_server(session, server)
  """
  defdelegate add_mcp_server(session, body), to: :beam_agent

  @doc """
  Get the status of all registered MCP servers for a session.

  Returns a map keyed by server name. Each value contains the server's
  connection state and tool count.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status_map}` or `{:error, reason}`.
  """
  defdelegate mcp_server_status(session), to: :beam_agent

  @doc """
  Replace all MCP servers with the given list.

  Overwrites the entire server registry for this session. Any previously
  registered servers not in the new list are removed.

  ## Parameters

  - `session` -- pid of a running session.
  - `servers` -- list of server definition maps (same format as `add_mcp_server/2` body).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate set_mcp_servers(session, servers), to: :beam_agent

  @doc """
  Reconnect a disconnected MCP server by name.

  Attempts to re-establish the connection to the named server.

  ## Parameters

  - `session` -- pid of a running session.
  - `server_name` -- binary server name.

  ## Returns

  - `{:ok, result}` or `{:error, {:server_not_found, server_name}}`.
  """
  defdelegate reconnect_mcp_server(session, server_name), to: :beam_agent

  @doc """
  Enable or disable an MCP server by name.

  When `enabled` is `false`, the server's tools are hidden from the backend
  but the server definition is preserved. Setting `enabled` back to `true`
  restores the tools.

  ## Parameters

  - `session` -- pid of a running session.
  - `server_name` -- binary server name.
  - `enabled` -- boolean.

  ## Returns

  - `{:ok, result}` or `{:error, {:server_not_found, server_name}}`.
  """
  defdelegate toggle_mcp_server(session, server_name, enabled), to: :beam_agent

  @doc """
  Initiate an OAuth login flow for an MCP server.

  This operation requires native backend support; the universal fallback
  returns a `status: :not_supported` result.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- OAuth parameters map (server name, client_id, redirect_uri, scopes).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate mcp_server_oauth_login(session, opts), to: :beam_agent

  @doc """
  Reload all MCP server configurations.

  Forces a refresh of tool definitions from all registered servers.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate mcp_server_reload(session), to: :beam_agent

  @doc """
  List the status of all MCP servers as a single response.

  Alias for `mcp_server_status/1`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status_map}` or `{:error, reason}`.
  """
  defdelegate mcp_server_status_list(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Account Management
  # ---------------------------------------------------------------------------

  @doc """
  Initiate an account login flow.

  `opts` contains credentials or OAuth tokens required by the backend's
  authentication provider. The exact keys depend on the provider (e.g.,
  `:api_key`, `:access_token`, `:email`).

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- credentials/OAuth parameters map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate account_login(session, opts), to: :beam_agent

  @doc """
  Cancel an in-progress account login flow.

  Aborts a login that was started with `account_login/2` but has not yet
  completed (e.g., waiting for OAuth redirect).

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- should match the original login parameters.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate account_login_cancel(session, opts), to: :beam_agent

  @doc """
  Log out of the current account.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate account_logout(session), to: :beam_agent

  @doc """
  Get rate limit information for the current account.

  Falls back to `account_info/1` for backends without native
  rate limit reporting.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, rate_limit_info}` or `{:error, reason}`.
  """
  defdelegate account_rate_limits(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Fuzzy File Search
  # ---------------------------------------------------------------------------

  @doc """
  Fuzzy-search for files by name in the session's project.

  Convenience wrapper that calls `fuzzy_file_search/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- partial file name to match (e.g., `"sess_eng"` matches
    `beam_agent_session_engine.erl`).

  ## Returns

  - `{:ok, matches}` sorted by score descending.
  """
  defdelegate fuzzy_file_search(session, query), to: :beam_agent

  @doc """
  Fuzzy-search for files by name with options.

  Returns up to `:max_results` matches sorted by score descending. Each
  match is a map with `:path`, `:score`, and `:name` keys. The scoring
  algorithm rewards consecutive matches and word-boundary hits.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- partial file name to match.
  - `opts` -- search options map. Optional keys:
    - `:cwd` -- base directory to search under
    - `:max_results` -- maximum matches to return (default 50)
    - `:roots` -- list of root directories to search

  ## Returns

  - `{:ok, matches}` or `{:error, reason}`.
  """
  defdelegate fuzzy_file_search(session, query, opts), to: :beam_agent

  @doc """
  Start a stateful fuzzy file search session.

  Creates a search session identified by `search_session_id` that caches
  file listings from `roots`. Subsequent calls to
  `fuzzy_file_search_session_update/3` reuse this cache for faster
  incremental searches (useful for typeahead UIs). The session persists
  in ETS until explicitly stopped with `fuzzy_file_search_session_stop/2`.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary identifier for the search session.
  - `roots` -- list of root directories to index.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate fuzzy_file_search_session_start(session, search_session_id, roots), to: :beam_agent

  @doc """
  Update a search session with a new query string.

  Runs the fuzzy scoring algorithm against the roots cached in the
  session identified by `search_session_id`. Returns the new set of matches.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary search session identifier.
  - `query` -- new query string.

  ## Returns

  - `{:ok, matches}` or `{:error, :not_found}`.
  """
  defdelegate fuzzy_file_search_session_update(session, search_session_id, query), to: :beam_agent

  @doc """
  Stop and clean up a fuzzy file search session.

  Removes the session identified by `search_session_id` from ETS, freeing
  its cached file listing and results. Safe to call even if the session
  has already been stopped.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary search session identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate fuzzy_file_search_session_stop(session, search_session_id), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Miscellaneous
  # ---------------------------------------------------------------------------

  @doc """
  Start the Windows sandbox setup process.

  Initiates sandbox configuration for backends that run in a Windows
  environment. On non-Windows platforms the universal fallback returns
  `status: :not_applicable`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- setup options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate windows_sandbox_setup_start(session, opts), to: :beam_agent

  @doc """
  Set the maximum number of thinking tokens for the session.

  Controls how many tokens the backend's reasoning model may use for
  internal chain-of-thought before producing a visible response. Higher
  values allow deeper reasoning at the cost of latency and token usage.

  ## Parameters

  - `session` -- pid of a running session.
  - `max_tokens` -- positive integer token limit.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate set_max_thinking_tokens(session, max_tokens), to: :beam_agent

  @doc """
  Rewind files to a previous checkpoint.

  Restores the file state captured at `checkpoint_uuid`. This undoes all
  file modifications made after the checkpoint was created. The session's
  message history is not affected.

  ## Parameters

  - `session` -- pid of a running session.
  - `checkpoint_uuid` -- binary checkpoint identifier.

  ## Returns

  - `{:ok, result}` or `{:error, :not_found}`.
  """
  defdelegate rewind_files(session, checkpoint_uuid), to: :beam_agent

  @doc """
  Stop a running task by its identifier.

  Sends an interrupt to the session and marks the task as stopped.

  ## Parameters

  - `session` -- pid of a running session.
  - `task_id` -- binary task identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate stop_task(session, task_id), to: :beam_agent

  @doc """
  Perform backend-specific session initialization.

  Called after `start_session/1` to complete any additional setup that
  requires an active transport connection.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific initialization parameters map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate session_init(session, opts), to: :beam_agent

  @doc """
  Get all messages for the current session.

  Returns the complete message history for the session's active conversation.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate session_messages(session), to: :beam_agent

  @doc """
  Get messages for the current session with filtering options.

  `opts` may include pagination keys (`:limit`, `:offset`) or filters
  (`:role`, `:type`) to narrow the returned message list.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate session_messages(session, opts), to: :beam_agent

  @doc """
  Send a prompt asynchronously without blocking for the full response.

  Convenience wrapper that calls `prompt_async/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.

  ## Returns

  - `{:ok, result_map}` with a `:request_id` key.
  - `{:error, reason}` on failure.
  """
  defdelegate prompt_async(session, prompt), to: :beam_agent

  @doc """
  Send a prompt asynchronously with options.

  Submits `prompt` to the backend and returns immediately with a result
  map containing a `:request_id`. Use `event_subscribe/1` and
  `receive_event/2` to collect the streamed response.

  Unlike `query/2`, this function does not block until completion. It is
  the preferred approach for UIs and concurrent workflows.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `opts` -- query parameters map (`:system_prompt`, `:model`, etc.).

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  defdelegate prompt_async(session, prompt, opts), to: :beam_agent

  @doc """
  Execute a shell command in the session's working directory.

  Convenience wrapper that calls `shell_command/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary shell command string.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate shell_command(session, command), to: :beam_agent

  @doc """
  Execute a shell command with options.

  Runs `command` as a subprocess in the session's working directory.
  Returns a result map containing `:stdout`, `:stderr`, and `:exit_code`.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary shell command string.
  - `opts` -- options map. Optional keys:
    - `:timeout` -- milliseconds
    - `:env` -- environment variable overrides

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate shell_command(session, command, opts), to: :beam_agent

  @doc """
  Append text to the TUI prompt input buffer.

  Injects `text` into the terminal UI's prompt field as if the user had
  typed it. Only meaningful for backends with a native terminal interface.

  ## Parameters

  - `session` -- pid of a running session.
  - `text` -- binary text to append.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate tui_append_prompt(session, text), to: :beam_agent

  @doc """
  Open the TUI help panel.

  This operation requires a native terminal backend. The universal
  fallback returns a `status: :not_applicable` result.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate tui_open_help(session), to: :beam_agent

  @doc """
  Destroy the current session and clean up all associated state.

  Removes the session from the session store, runtime registry,
  config store, feedback store, callback registry, and tool registry.
  This is a more thorough cleanup than `stop/1`, which only terminates
  the process.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate session_destroy(session), to: :beam_agent

  @doc """
  Destroy a specific session by its identifier.

  Same as `session_destroy/1` but targets a specific `session_id`, which
  may differ from the calling session's own identifier. Useful for
  cleaning up persisted sessions that are no longer needed.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier to destroy.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate session_destroy(session, session_id), to: :beam_agent

  @doc """
  Run a command through the backend's command execution facility.

  Convenience wrapper that calls `command_run/3` with empty options.
  `command` may be a single binary or a list of binaries (command + args).

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command string or list of binary args.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate command_run(session, command), to: :beam_agent

  @doc """
  Run a command through the backend's command execution facility with options.

  Executes `command` via the backend's native command runner (which may
  apply sandboxing, permission checks, or audit logging). Falls back
  to a universal shell executor when the backend does not support native
  command execution.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command string or list of binary args.
  - `opts` -- options map. Optional keys:
    - `:timeout` -- milliseconds
    - `:env` -- environment variable overrides
    - `:cwd` -- working directory override

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate command_run(session, command, opts), to: :beam_agent

  @doc """
  Write data to the stdin of a running command.

  Convenience wrapper that calls `command_write_stdin/4` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `process_id` -- binary process identifier from a previous `command_run/3` call.
  - `stdin` -- binary data to write to stdin.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate command_write_stdin(session, process_id, stdin), to: :beam_agent

  @doc """
  Write data to the stdin of a running command with options.

  Sends `stdin` bytes to the process identified by `process_id`. This
  requires the backend to maintain an active process handle.

  ## Parameters

  - `session` -- pid of a running session.
  - `process_id` -- binary process identifier.
  - `stdin` -- binary data to write.
  - `opts` -- backend-specific options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate command_write_stdin(session, process_id, stdin, opts), to: :beam_agent

  @doc """
  Submit user feedback about the session or a specific response.

  `feedback` is a map that may contain `:rating` (`:thumbs_up`/`:thumbs_down`),
  `:comment` (freeform text), and `:message_id` (to associate feedback with
  a specific response).

  ## Parameters

  - `session` -- pid of a running session.
  - `feedback` -- feedback map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate submit_feedback(session, feedback), to: :beam_agent

  @doc """
  Respond to a turn-based request from the backend.

  Some backends issue permission_request or tool_use_request messages
  that require explicit user approval. `request_id` identifies the pending
  request (from the message's `:request_id` field). `params` contains the
  response payload (e.g., `%{approved: true}` for permissions).

  ## Parameters

  - `session` -- pid of a running session.
  - `request_id` -- binary request identifier.
  - `params` -- response payload map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate turn_respond(session, request_id, params), to: :beam_agent

  @doc """
  Send a named command to the backend.

  A general-purpose dispatch mechanism for backend-specific commands that
  do not have dedicated API functions. Delegates to `send_control/3` in
  the universal fallback.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command name.
  - `params` -- map of command arguments.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  defdelegate send_command(session, command, params), to: :beam_agent

  @doc """
  Check the health of the backend server.

  Returns a status map with health indicators including the backend name,
  session identifier, and uptime in milliseconds.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, health_map}` or `{:error, reason}`.
  """
  defdelegate server_health(session), to: :beam_agent

  # ---------------------------------------------------------------------------
  # Event Streaming (Elixir-only convenience functions)
  # ---------------------------------------------------------------------------

  @doc """
  Stream session events as an `Enumerable` (raises on errors).

  Subscribes to session events and returns a lazy `Stream` that yields
  each event as it arrives. Automatically unsubscribes on stream
  completion. Raises on subscription failure or stream errors.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- optional keyword list or map. Optional keys:
    - `:timeout` -- event receive timeout in milliseconds (default 30,000).

  ## Returns

  An `Enumerable.t()` of `t:message/0` maps.

  ## Examples

      session
      |> BeamAgent.event_stream!()
      |> Enum.take(10)
      |> Enum.each(&IO.inspect/1)
  """
  @spec event_stream!(pid(), keyword() | map()) :: Enumerable.t()
  def event_stream!(session, opts \\ %{}) when is_pid(session) do
    params = opts_to_map(opts)
    timeout = Map.get(params, :timeout, 30_000)

    Stream.resource(
      fn ->
        case event_subscribe(session) do
          {:ok, ref} -> {session, ref, timeout}
          {:error, reason} -> raise "Event subscribe failed: #{inspect(reason)}"
        end
      end,
      fn
        {:done, sess, ref, _timeout} = done ->
          _ = event_unsubscribe(sess, ref)
          {:halt, done}

        {sess, ref, timeout} ->
          case receive_event(sess, ref, timeout) do
            {:ok, msg} ->
              {[msg], {sess, ref, timeout}}

            {:error, :complete} ->
              _ = event_unsubscribe(sess, ref)
              {:halt, {:done, sess, ref, timeout}}

            {:error, reason} ->
              _ = event_unsubscribe(sess, ref)
              raise "Event stream error: #{inspect(reason)}"
          end
      end,
      fn
        {:done, _, _, _} ->
          :ok

        {sess, ref, _timeout} ->
          _ = event_unsubscribe(sess, ref)
          :ok
      end
    )
  end

  @doc """
  Stream session events as an `Enumerable` (returns tagged tuples).

  Like `event_stream!/2` but wraps each event in `{:ok, event}` and errors
  in `{:error, reason}` instead of raising. Suitable for pipelines that
  need to handle errors gracefully.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- optional keyword list or map. Optional keys:
    - `:timeout` -- event receive timeout in milliseconds (default 30,000).

  ## Returns

  An `Enumerable.t()` of `{:ok, message()}` or `{:error, reason}` tuples.
  """
  @spec event_stream(pid(), keyword() | map()) :: Enumerable.t()
  def event_stream(session, opts \\ %{}) when is_pid(session) do
    params = opts_to_map(opts)
    timeout = Map.get(params, :timeout, 30_000)

    Stream.resource(
      fn ->
        case event_subscribe(session) do
          {:ok, ref} -> {session, ref, timeout}
          {:error, reason} -> {:error_init, reason}
        end
      end,
      fn
        {:error_init, reason} ->
          {[{:error, reason}], :halt_state}

        :halt_state ->
          {:halt, :halt_state}

        {sess, ref, timeout} ->
          case receive_event(sess, ref, timeout) do
            {:ok, msg} ->
              {[{:ok, msg}], {sess, ref, timeout}}

            {:error, :complete} ->
              _ = event_unsubscribe(sess, ref)
              {:halt, {sess, ref, timeout}}

            {:error, reason} ->
              _ = event_unsubscribe(sess, ref)
              {[{:error, reason}], :halt_state}
          end
      end,
      fn
        :halt_state ->
          :ok

        {sess, ref, _timeout} ->
          _ = event_unsubscribe(sess, ref)
          :ok
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts
end
