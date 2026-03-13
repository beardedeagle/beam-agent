defmodule ClaudeEx do
  @moduledoc """
  Elixir wrapper for the Claude Code agent SDK.

  Provides idiomatic Elixir access to `claude_agent_session` (Erlang/OTP
  gen_statem) with lazy streaming via `Stream.resource/3`.

  ## Quick Start

      # Start a session
      {:ok, session} = ClaudeEx.start_session(cli_path: "/usr/local/bin/claude")

      # Blocking query — collects all messages
      {:ok, messages} = ClaudeEx.query(session, "What is 2 + 2?")

      # Streaming query — lazy enumerable
      ClaudeEx.stream!(session, "Explain OTP supervision trees")
      |> Enum.each(fn msg ->
        case msg.type do
          :assistant -> Enum.each(msg.content_blocks, &IO.inspect/1)
          :result    -> IO.puts(msg.content)
          _          -> :ok
        end
      end)

  ## Session Options

  - `:cli_path` — Path to the Claude CLI executable (default: `"claude"`)
  - `:work_dir` — Working directory for the CLI subprocess
  - `:env` — Environment variables as `[{key, value}]` charlists
  - `:buffer_max` — Max raw binary buffer in bytes (default: 2MB)
  - `:session_id` — Resume a previous session (binary)
  - `:model` — Model to use (binary, e.g. `"claude-sonnet-4-6"`)
  - `:fallback_model` — Fallback model used by Claude CLI when the primary model is unavailable
  - `:system_prompt` — System prompt (binary or preset map)
  - `:tools` — Base built-in tool preset/list passed via `--tools`
  - `:max_turns` — Maximum number of turns
  - `:resume` — Resume a previous session (boolean)
  - `:fork_session` — Fork from an existing session (boolean)
  - `:permission_mode` — Permission mode (binary or atom)
  - `:permission_prompt_tool_name` — Tool name used by Claude for interactive permission prompts
  - `:permission_handler` — `fn(tool_name, tool_input, options) -> result` callback
  - `:allowed_tools` — List of allowed tool names
  - `:disallowed_tools` — List of disallowed tool names
  - `:settings` — Settings file path or JSON blob passed via `--settings`
  - `:add_dirs` — Extra directories passed via repeated `--add-dir`
  - `:agents` — Subagent configurations (map)
  - `:mcp_servers` — MCP server configurations (map)
  - `:output_format` — Structured output JSON schema (map)
  - `:thinking` — Thinking configuration (map)
  - `:effort` — Effort level (binary)
  - `:max_budget_usd` — Maximum cost budget (number)
  - `:enable_file_checkpointing` — Enable file checkpoints (boolean)
  - `:plugins` — Plugin configurations (list)
  - `:hooks` — Hook configurations (map)
  - `:betas` — Beta features to enable (list)
  - `:sandbox` — Sandbox configuration (map)
  - `:debug` — Enable debug mode (boolean)
  - `:extra_args` — Extra CLI arguments (map)
  - `:client_app` — Client application name (binary)
  - `:user_input_handler` — `fn(request, context) -> {:ok, answer} | {:error, reason}`
    callback for elicitation/user-input requests from the CLI
  - `:sdk_mcp_servers` — In-process MCP servers (list of server maps from `mcp_server/2`)
  - `:sdk_hooks` — SDK lifecycle hooks (list of hook maps from `sdk_hook/2,3`)

  ## In-Process MCP Servers

  Define custom tools as Elixir functions that Claude can call in-process:

      tool = ClaudeEx.mcp_tool("greet", "Greet a user",
        %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
        fn input -> {:ok, [%{type: :text, text: "Hello, \#{input["name"]}!"}]} end
      )
      server = ClaudeEx.mcp_server("my-tools", [tool])
      {:ok, session} = ClaudeEx.start_session(sdk_mcp_servers: [server])

  ## Session History

  Browse past Claude Code sessions without starting a new one:

      {:ok, sessions} = ClaudeEx.list_sessions()
      {:ok, messages} = ClaudeEx.get_session_messages("session-uuid")
  """

  @type session :: pid()

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

  @type share_info_map :: %{
          :created_at => integer(),
          :session_id => binary(),
          :share_id => binary(),
          :status => :active
        }

  @type summary_info_map :: %{
          :content => binary(),
          :generated_at => integer(),
          :generated_by => binary(),
          :message_count => non_neg_integer(),
          :session_id => binary()
        }

  @type thread_info_map :: %{
          :created_at => integer(),
          :message_count => non_neg_integer(),
          :session_id => binary(),
          :status => :active | :archived | :completed | :paused,
          :thread_id => binary(),
          :updated_at => integer(),
          :visible_message_count => non_neg_integer(),
          :archived => boolean(),
          :archived_at => integer(),
          :metadata => map(),
          :name => binary(),
          :parent_thread_id => binary(),
          :summary => map()
        }

  @type thread_read_info_map :: %{
          :thread => thread_info_map(),
          :messages => [map()]
        }

  @type mcp_tool_map :: %{
          :description => binary(),
          :handler => (map() -> {:error, binary()} | {:ok, [any()]}),
          :input_schema => map(),
          :name => binary()
        }

  @type mcp_server_map :: %{
          :name => binary(),
          :tools => [mcp_tool_map()],
          :version => binary()
        }

  @type hook_context :: %{
          :event => atom(),
          :agent_id => binary(),
          :agent_transcript_path => binary(),
          :agent_type => binary(),
          :content => binary(),
          :duration_ms => non_neg_integer(),
          :interrupt => boolean(),
          :params => map(),
          :permission_prompt_tool_name => binary(),
          :permission_suggestions => [any()],
          :prompt => binary(),
          :reason => term(),
          :session_id => binary(),
          :stop_hook_active => boolean(),
          :stop_reason => atom() | binary(),
          :system_info => map(),
          :tool_input => map(),
          :tool_name => binary(),
          :tool_use_id => binary(),
          :updated_permissions => map()
        }

  @type hook_callback :: (hook_context() -> :ok | {:deny, binary()})

  @type hook_map :: %{
          :callback => hook_callback(),
          :event => atom()
        }

  @type hook_with_matcher_map :: %{
          :callback => hook_callback(),
          :event => atom(),
          :matcher => %{:tool_name => binary()},
          :compiled_re => {:re_pattern, term(), term(), term(), term()}
        }

  @type content_block :: %{
          required(:type) => :text | :thinking | :tool_use | :tool_result | :raw,
          optional(:text) => binary(),
          optional(:thinking) => binary(),
          optional(:id) => binary(),
          optional(:name) => binary(),
          optional(:input) => map(),
          optional(:tool_use_id) => binary(),
          optional(:content) => binary(),
          optional(:raw) => map()
        }

  @type stop_reason ::
          :end_turn
          | :max_tokens
          | :stop_sequence
          | :refusal
          | :tool_use_stop
          | :unknown_stop

  @type permission_mode ::
          :default
          | :accept_edits
          | :bypass_permissions
          | :plan
          | :dont_ask

  @type message :: %{
          required(:type) =>
            :text
            | :assistant
            | :tool_use
            | :tool_result
            | :system
            | :result
            | :error
            | :user
            | :control
            | :control_request
            | :control_response
            | :stream_event
            | :rate_limit_event
            | :tool_progress
            | :tool_use_summary
            | :thinking
            | :auth_status
            | :prompt_suggestion
            | :raw,
          optional(:content) => binary(),
          optional(:tool_name) => binary(),
          optional(:tool_input) => map(),
          optional(:raw) => map(),
          optional(:timestamp) => integer(),
          # Common wire fields
          optional(:uuid) => binary(),
          optional(:session_id) => binary(),
          # Assistant message fields
          optional(:content_blocks) => [content_block()],
          optional(:parent_tool_use_id) => binary() | nil,
          optional(:message_id) => binary(),
          optional(:model) => binary(),
          optional(:error_info) => map(),
          # System message fields
          optional(:system_info) => map(),
          # Result enrichment fields
          optional(:duration_ms) => non_neg_integer(),
          optional(:duration_api_ms) => non_neg_integer(),
          optional(:num_turns) => non_neg_integer(),
          optional(:stop_reason) => binary(),
          optional(:stop_reason_atom) => stop_reason(),
          optional(:usage) => map(),
          optional(:model_usage) => map(),
          optional(:total_cost_usd) => number(),
          optional(:is_error) => boolean(),
          optional(:subtype) => binary(),
          optional(:errors) => [binary()],
          optional(:structured_output) => term(),
          optional(:permission_denials) => list(),
          optional(:fast_mode_state) => map(),
          # User message fields
          optional(:is_replay) => boolean(),
          # Control protocol fields
          optional(:request_id) => binary(),
          optional(:request) => map(),
          optional(:response) => map(),
          # Rate limit event fields (TS SDK SDKRateLimitInfo)
          optional(:rate_limit_status) => binary(),
          optional(:resets_at) => number(),
          optional(:rate_limit_type) => binary(),
          optional(:utilization) => number(),
          optional(:overage_status) => binary(),
          optional(:overage_resets_at) => number(),
          optional(:overage_disabled_reason) => binary(),
          optional(:is_using_overage) => boolean(),
          optional(:surpassed_threshold) => number()
        }

  @type session_opt ::
          {:cli_path, Path.t()}
          | {:work_dir, Path.t()}
          | {:env, [{charlist(), charlist()}]}
          | {:buffer_max, pos_integer()}
          | {:session_id, binary()}
          | {:model, binary()}
          | {:fallback_model, binary()}
          | {:system_prompt, binary() | map()}
          | {:tools, [binary()] | map()}
          | {:max_turns, pos_integer()}
          | {:resume, boolean()}
          | {:fork_session, boolean()}
          | {:continue, boolean()}
          | {:persist_session, boolean()}
          | {:permission_mode, binary() | permission_mode()}
          | {:permission_prompt_tool_name, binary()}
          | {:permission_handler, (binary(), map(), map() -> term())}
          | {:allowed_tools, [binary()]}
          | {:disallowed_tools, [binary()]}
          | {:settings, binary()}
          | {:add_dirs, [binary() | String.t() | Path.t()]}
          | {:agents, map()}
          | {:mcp_servers, map()}
          | {:output_format, map()}
          | {:thinking, map()}
          | {:effort, binary()}
          | {:max_budget_usd, number()}
          | {:enable_file_checkpointing, boolean()}
          | {:setting_sources, [binary()]}
          | {:plugins, [map()]}
          | {:hooks, map()}
          | {:betas, [binary()]}
          | {:include_partial_messages, boolean()}
          | {:prompt_suggestions, boolean()}
          | {:sandbox, map()}
          | {:debug, boolean()}
          | {:debug_file, binary()}
          | {:extra_args, map()}
          | {:client_app, binary()}
          | {:sdk_mcp_servers, [map()]}
          | {:sdk_hooks, [map()]}

  @type query_opt ::
          {:system_prompt, binary()}
          | {:tools, [binary()] | map()}
          | {:allowed_tools, [binary()]}
          | {:disallowed_tools, [binary()]}
          | {:max_tokens, pos_integer()}
          | {:max_turns, pos_integer()}
          | {:permission_mode, binary()}
          | {:model, binary()}
          | {:timeout, timeout()}
          | {:output_format, map()}
          | {:thinking, map()}
          | {:effort, binary()}
          | {:max_budget_usd, number()}
          | {:agent, binary()}

  @doc """
  Start a new Claude Code session.

  Returns `{:ok, pid}` on success. The session process can be added
  to your supervision tree via `ClaudeEx.child_spec/1`.

  ## Examples

      {:ok, session} = ClaudeEx.start_session(cli_path: "claude")
      {:ok, session} = ClaudeEx.start_session(work_dir: "/my/project")
      {:ok, session} = ClaudeEx.start_session(
        cli_path: "claude",
        model: "claude-sonnet-4-20250514",
        permission_mode: :accept_edits
      )
  """
  @spec start_session([session_opt()]) :: {:ok, session()} | {:error, term()}
  def start_session(opts \\ []) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :claude)
    |> BeamAgent.start_session()
  end

  @doc """
  Send a query and collect all response messages (blocking).

  Returns the complete list of messages once the query finishes.
  This is the simple, synchronous interface.

  ## Examples

      {:ok, messages} = ClaudeEx.query(session, "Hello!")
      last = List.last(messages)
      IO.puts(last.content)
  """
  @spec query(session(), binary(), [query_opt()]) ::
          {:ok, [message()]} | {:error, term()}
  def query(session, prompt, opts \\ []) do
    BeamAgent.query(session, prompt, opts_to_map(opts))
  end

  @doc """
  Return a lazy `Stream` of messages for the given prompt.

  Uses `Stream.resource/3` to implement demand-driven consumption:
  the gen_statem only parses the next JSONL line when the stream
  consumer requests it. The query is dispatched to the CLI
  immediately when `stream!/3` is called; message *consumption*
  is lazy/pull-based.

  The stream halts automatically when a `:result` or `:error` message
  is received, or when the query completes.

  ## Examples

      ClaudeEx.stream!(session, "Explain GenServer")
      |> Stream.filter(& &1.type == :assistant)
      |> Enum.flat_map(& &1.content_blocks)
      |> Enum.filter(& &1.type == :text)
      |> Enum.map(& &1.text)
      |> Enum.join("")

      # With options
      ClaudeEx.stream!(session, "Hello", system_prompt: "Be brief")
      |> Enum.to_list()
  """
  @spec stream!(session(), binary(), [query_opt()]) :: Enumerable.t()
  def stream!(session, prompt, opts \\ []) do
    BeamAgent.stream!(session, prompt, opts_to_map(opts))
  end

  @doc """
  Return a `Stream` that does not raise on errors.

  Like `stream!/3` but wraps messages in `{:ok, msg}` tuples and
  returns `{:error, reason}` on failure instead of raising.
  """
  @spec stream(session(), binary(), [query_opt()]) :: Enumerable.t()
  def stream(session, prompt, opts \\ []) do
    BeamAgent.stream(session, prompt, opts_to_map(opts))
  end

  @doc """
  Get the current health/state of a session.

  ## Examples

      :ready = ClaudeEx.health(session)
  """
  @spec health(session()) :: :ready | :connecting | :initializing | :active_query | :error
  def health(session) do
    BeamAgent.health(session)
  end

  @doc """
  Gracefully stop a session, closing the CLI subprocess.
  """
  @spec stop(session()) :: :ok
  def stop(session) do
    BeamAgent.stop(session)
  end

  @doc """
  Query session capabilities and initialization data.

  Returns a map with:
  - `:session_id` — the session ID
  - `:system_info` — parsed system init metadata (tools, model, etc.)
  - `:init_response` — raw initialize control_response

  Available in all session states (connecting, initializing, ready, active_query, error).

  ## Examples

      {:ok, info} = ClaudeEx.session_info(session)
      info.system_info.model  # => "claude-sonnet-4-20250514"
      info.system_info.tools  # => ["Read", "Write", "Bash"]
  """
  @spec session_info(session()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    BeamAgent.session_info(session)
  end

  @doc """
  Change the model at runtime during a session.

  ## Examples

      :ok = ClaudeEx.set_model(session, "claude-sonnet-4-20250514")
  """
  @spec set_model(session(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    BeamAgent.Runtime.set_model(session, model)
  end

  @doc """
  Change the permission mode at runtime.

  ## Examples

      :ok = ClaudeEx.set_permission_mode(session, "acceptEdits")
  """
  @spec set_permission_mode(session(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    BeamAgent.Runtime.set_permission_mode(session, mode)
  end

  @doc """
  Revert file changes to a checkpoint identified by UUID.

  Only meaningful when file checkpointing is enabled in session opts.

  ## Examples

      {:ok, _} = ClaudeEx.rewind_files(session, "msg-uuid-123")
  """
  @spec rewind_files(session(), binary()) :: {:ok, term()} | {:error, term()}
  def rewind_files(session, checkpoint_uuid) do
    :claude_agent_sdk.rewind_files(session, checkpoint_uuid)
  end

  @doc """
  Stop a running agent task by task ID.

  ## Examples

      {:ok, _} = ClaudeEx.stop_task(session, "task-abc")
  """
  @spec stop_task(session(), binary()) :: {:ok, term()} | {:error, term()}
  def stop_task(session, task_id) do
    :claude_agent_sdk.stop_task(session, task_id)
  end

  @doc """
  Set the maximum thinking tokens at runtime.

  Controls how many tokens the model can use for its internal
  reasoning/thinking process.

  ## Examples

      {:ok, _} = ClaudeEx.set_max_thinking_tokens(session, 8192)
  """
  @spec set_max_thinking_tokens(session(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def set_max_thinking_tokens(session, max_tokens)
      when is_integer(max_tokens) and max_tokens > 0 do
    :claude_agent_sdk.set_max_thinking_tokens(session, max_tokens)
  end

  @doc """
  Query MCP server health and status.

  Returns connection status, availability, and diagnostics for all
  configured MCP servers in the session.

  ## Examples

      {:ok, status} = ClaudeEx.mcp_server_status(session)
  """
  @spec mcp_server_status(session()) :: {:ok, term()} | {:error, term()}
  def mcp_server_status(session) do
    :claude_agent_sdk.mcp_server_status(session)
  end

  @doc """
  Dynamically add or replace MCP server configurations.

  Accepts a map of server name => server config. Existing servers
  with the same name are replaced; others are unaffected.

  ## Examples

      servers = %{"my_server" => %{"command" => "node", "args" => ["server.js"]}}
      {:ok, _} = ClaudeEx.set_mcp_servers(session, servers)
  """
  @spec set_mcp_servers(session(), map()) :: {:ok, term()} | {:error, term()}
  def set_mcp_servers(session, servers) when is_map(servers) do
    :claude_agent_sdk.set_mcp_servers(session, servers)
  end

  @doc """
  Reconnect a failed MCP server by name.

  ## Examples

      {:ok, _} = ClaudeEx.reconnect_mcp_server(session, "my_server")
  """
  @spec reconnect_mcp_server(session(), binary()) :: {:ok, term()} | {:error, term()}
  def reconnect_mcp_server(session, server_name) when is_binary(server_name) do
    :claude_agent_sdk.reconnect_mcp_server(session, server_name)
  end

  @doc """
  Enable or disable an MCP server at runtime.

  ## Examples

      {:ok, _} = ClaudeEx.toggle_mcp_server(session, "my_server", false)
      {:ok, _} = ClaudeEx.toggle_mcp_server(session, "my_server", true)
  """
  @spec toggle_mcp_server(session(), binary(), boolean()) :: {:ok, term()} | {:error, term()}
  def toggle_mcp_server(session, server_name, enabled)
      when is_binary(server_name) and is_boolean(enabled) do
    :claude_agent_sdk.toggle_mcp_server(session, server_name, enabled)
  end

  @doc """
  List available slash commands from the init response.

  Returns the commands array from the initialize control_response,
  or an empty list if not yet initialized.

  ## Examples

      {:ok, commands} = ClaudeEx.supported_commands(session)
      Enum.each(commands, &IO.inspect/1)
  """
  @spec supported_commands(session()) :: {:ok, list()} | {:error, term()}
  def supported_commands(session) do
    :claude_agent_sdk.supported_commands(session)
  end

  @doc """
  List available models from the init response.

  ## Examples

      {:ok, models} = ClaudeEx.supported_models(session)
  """
  @spec supported_models(session()) :: {:ok, list()} | {:error, term()}
  def supported_models(session) do
    :claude_agent_sdk.supported_models(session)
  end

  @doc """
  List available agents from the init response.

  ## Examples

      {:ok, agents} = ClaudeEx.supported_agents(session)
  """
  @spec supported_agents(session()) :: {:ok, list()} | {:error, term()}
  def supported_agents(session) do
    :claude_agent_sdk.supported_agents(session)
  end

  @doc """
  Get account information from the init response.

  Returns account details (email, org, subscription type, etc.)
  from the initialize control_response.

  ## Examples

      {:ok, account} = ClaudeEx.account_info(session)
      account["email"]  # => "user@example.com"
  """
  @spec account_info(session()) :: {:ok, map()} | {:error, term()}
  def account_info(session) do
    :claude_agent_sdk.account_info(session)
  end

  # ── In-Process MCP Servers ────────────────────────────────────────

  @doc """
  Create an MCP tool definition for in-process tool handling.

  The handler function receives the tool input as a map and must return
  `{:ok, [content_result()]}` or `{:error, binary()}`.

  ## Examples

      tool = ClaudeEx.mcp_tool("echo", "Echo input",
        %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
        fn input -> {:ok, [%{type: :text, text: input["text"]}]} end
      )
  """
  @spec mcp_tool(binary(), binary(), map(), (map() -> {:error, binary()} | {:ok, [map()]})) ::
          mcp_tool_map()
  def mcp_tool(name, description, input_schema, handler) do
    :beam_agent_tool_registry.tool(name, description, input_schema, handler)
  end

  @doc """
  Create an MCP server with a list of tools.

  The server is registered with the session at startup and handles
  JSON-RPC tool calls from Claude in-process.

  ## Examples

      tool = ClaudeEx.mcp_tool("greet", "Greet user", %{"type" => "object"},
        fn _input -> {:ok, [%{type: :text, text: "Hello!"}]} end
      )
      server = ClaudeEx.mcp_server("my-tools", [tool])
      {:ok, session} = ClaudeEx.start_session(sdk_mcp_servers: [server])
  """
  @spec mcp_server(binary(), [mcp_tool_map()]) :: mcp_server_map()
  def mcp_server(name, tools) do
    :beam_agent_tool_registry.server(name, tools)
  end

  # ── SDK Lifecycle Hooks ───────────────────────────────────────────

  @doc """
  Create an SDK lifecycle hook.

  Hooks fire at key session lifecycle points. Events:
  - `:pre_tool_use` — before tool execution (can deny)
  - `:post_tool_use` — after tool result received
  - `:stop` — when result/completion received
  - `:session_start` — when session enters ready state
  - `:session_end` — when session terminates
  - `:user_prompt_submit` — before query sent (can deny)

  ## Examples

      hook = ClaudeEx.sdk_hook(:pre_tool_use, fn ctx ->
        case ctx.tool_name do
          "Bash" -> {:deny, "No shell access"}
          _ -> :ok
        end
      end)
      {:ok, session} = ClaudeEx.start_session(sdk_hooks: [hook])
  """
  @spec sdk_hook(atom(), hook_callback()) :: hook_map()
  def sdk_hook(event, callback) do
    :beam_agent_hooks_core.hook(event, callback)
  end

  @doc """
  Create an SDK lifecycle hook with a matcher filter.

  The matcher's `:tool_name` (exact string or regex) restricts which
  tools trigger the hook. Only relevant for tool-related events.

  ## Examples

      # Only fire on Bash tool
      hook = ClaudeEx.sdk_hook(:pre_tool_use,
        fn _ctx -> {:deny, "blocked"} end,
        %{tool_name: "Bash"})

      # Fire on Read* tools (regex)
      hook = ClaudeEx.sdk_hook(:pre_tool_use,
        fn _ctx -> :ok end,
        %{tool_name: "Read.*"})
  """
  @spec sdk_hook(atom(), hook_callback(), %{:tool_name => binary()}) :: hook_with_matcher_map()
  def sdk_hook(event, callback, matcher) do
    :beam_agent_hooks_core.hook(event, callback, matcher)
  end

  @doc "Abort the current query. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session), do: interrupt(session)

  # ── Universal: Session Store (beam_agent_core) ─────────────────────────

  @doc "List all tracked sessions."
  @spec list_sessions() :: {:ok, [session_info_map()]}
  def list_sessions, do: :claude_agent_sdk.list_sessions()

  @doc "List sessions with filters."
  @spec list_sessions(map()) :: {:ok, [session_info_map()]}
  def list_sessions(opts) when is_map(opts), do: :claude_agent_sdk.list_sessions(opts)

  @doc "Get messages for a session."
  @spec get_session_messages(binary()) :: {:ok, [message()]} | {:error, :not_found}
  def get_session_messages(session_id), do: :claude_agent_sdk.get_session_messages(session_id)

  @doc "Get messages with options."
  @spec get_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, :not_found}
  def get_session_messages(session_id, opts),
    do: :claude_agent_sdk.get_session_messages(session_id, opts)

  @doc "Get session metadata by ID."
  @spec get_session(binary()) :: {:ok, session_info_map()} | {:error, :not_found}
  def get_session(session_id), do: :claude_agent_sdk.get_session(session_id)

  @doc "Delete a session and its messages."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: :claude_agent_sdk.delete_session(session_id)

  @doc "Fork a tracked session into a new session ID."
  @spec fork_session(pid(), map()) :: {:ok, session_info_map()} | {:error, :not_found}
  def fork_session(session, opts), do: :claude_agent_sdk.fork_session(session, opts)

  @doc "Revert the visible session history to a prior boundary."
  @spec revert_session(pid(), map()) ::
          {:ok, session_info_map()} | {:error, :invalid_selector | :not_found}
  def revert_session(session, selector),
    do: :claude_agent_sdk.revert_session(session, selector)

  @doc "Clear any stored session revert state."
  @spec unrevert_session(pid()) :: {:ok, session_info_map()} | {:error, :not_found}
  def unrevert_session(session), do: :claude_agent_sdk.unrevert_session(session)

  @doc "Create or replace share state for the current session."
  @spec share_session(pid()) :: {:ok, share_info_map()} | {:error, :not_found}
  def share_session(session), do: :claude_agent_sdk.share_session(session)

  @spec share_session(pid(), map()) :: {:ok, share_info_map()} | {:error, :not_found}
  def share_session(session, opts), do: :claude_agent_sdk.share_session(session, opts)

  @doc "Revoke share state for the current session."
  @spec unshare_session(pid()) :: :ok | {:error, :not_found}
  def unshare_session(session), do: :claude_agent_sdk.unshare_session(session)

  @doc "Generate and store a summary for the current session."
  @spec summarize_session(pid()) :: {:ok, summary_info_map()} | {:error, :not_found}
  def summarize_session(session), do: :claude_agent_sdk.summarize_session(session)

  @spec summarize_session(pid(), map()) :: {:ok, summary_info_map()} | {:error, :not_found}
  def summarize_session(session, opts),
    do: :claude_agent_sdk.summarize_session(session, opts)

  # ── Native Claude Session Store (disk-based JSONL transcripts) ───

  @doc """
  List past Claude Code session transcripts from disk.

  Scans `~/.claude/projects/` for JSONL transcript files and returns
  metadata (session_id, model, timestamps) sorted by most recent first.

  ## Options

  - `:config_dir` — Override the Claude config directory (default: `~/.claude`)
  - `:cwd` — Filter to sessions for a specific working directory
  - `:limit` — Maximum number of sessions to return

  ## Examples

      {:ok, sessions} = ClaudeEx.list_native_sessions()
      {:ok, sessions} = ClaudeEx.list_native_sessions(limit: 10)
  """
  @spec list_native_sessions([
          {:config_dir, binary()} | {:cwd, binary()} | {:limit, pos_integer()}
        ]) ::
          {:ok,
           [
             %{
               :file_path => binary(),
               :modified_at => integer(),
               :session_id => binary(),
               :cwd => binary(),
               :model => binary()
             }
           ]}
  def list_native_sessions(opts \\ []) do
    :claude_session_store.list_sessions(opts_to_map(opts))
  end

  @doc """
  Read all messages from a past Claude Code session transcript on disk.

  Parses the full JSONL file and returns messages in conversation order.

  ## Options

  - `:config_dir` — Override the Claude config directory (default: `~/.claude`)

  ## Examples

      {:ok, messages} = ClaudeEx.get_native_session_messages("session-uuid-123")
  """
  @spec get_native_session_messages(binary(), [{:config_dir, binary()}]) ::
          {:ok, [map()]} | {:error, term()}
  def get_native_session_messages(session_id, opts \\ []) do
    :claude_session_store.get_session_messages(session_id, opts_to_map(opts))
  end

  # ── Universal: Thread Management (beam_agent_core) ────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), map()) ::
          {:ok,
           %{
             :archived => false,
             :created_at => integer(),
             :message_count => 0,
             :metadata => map(),
             :name => binary(),
             :session_id => binary(),
             :status => :active,
             :thread_id => binary(),
             :updated_at => integer(),
             :visible_message_count => 0,
             :parent_thread_id => binary()
           }}
  def thread_start(session, opts \\ %{}),
    do: :claude_agent_sdk.thread_start(session, opts)

  @doc "Resume an existing thread."
  @spec thread_resume(pid(), binary()) :: {:ok, thread_info_map()} | {:error, :not_found}
  def thread_resume(session, thread_id),
    do: :claude_agent_sdk.thread_resume(session, thread_id)

  @doc "List all threads for this session."
  @spec thread_list(pid()) :: {:ok, [thread_info_map()]}
  def thread_list(session), do: :claude_agent_sdk.thread_list(session)

  @doc "Fork an existing thread."
  @spec thread_fork(pid(), binary()) :: {:ok, thread_info_map()} | {:error, :not_found}
  def thread_fork(session, thread_id),
    do: :claude_agent_sdk.thread_fork(session, thread_id)

  @spec thread_fork(pid(), binary(), map()) :: {:ok, thread_info_map()} | {:error, :not_found}
  def thread_fork(session, thread_id, opts),
    do: :claude_agent_sdk.thread_fork(session, thread_id, opts)

  @doc "Read thread metadata, optionally including visible messages."
  @spec thread_read(pid(), binary()) :: {:ok, thread_read_info_map()} | {:error, :not_found}
  def thread_read(session, thread_id),
    do: :claude_agent_sdk.thread_read(session, thread_id)

  @spec thread_read(pid(), binary(), map()) ::
          {:ok, thread_read_info_map()} | {:error, :not_found}
  def thread_read(session, thread_id, opts),
    do: :claude_agent_sdk.thread_read(session, thread_id, opts)

  @doc "Archive a thread."
  @spec thread_archive(pid(), binary()) :: {:ok, thread_info_map()} | {:error, :not_found}
  def thread_archive(session, thread_id),
    do: :claude_agent_sdk.thread_archive(session, thread_id)

  @doc "Unarchive a thread."
  @spec thread_unarchive(pid(), binary()) :: {:ok, thread_info_map()} | {:error, :not_found}
  def thread_unarchive(session, thread_id),
    do: :claude_agent_sdk.thread_unarchive(session, thread_id)

  @doc "Rollback the visible thread history."
  @spec thread_rollback(pid(), binary(), map()) ::
          {:ok, thread_info_map()} | {:error, :invalid_selector | :not_found}
  def thread_rollback(session, thread_id, selector),
    do: :claude_agent_sdk.thread_rollback(session, thread_id, selector)

  # ── Universal: Session Control (beam_agent_core) ──────────────────────

  @doc "Run a command via universal command execution."
  @spec command_run(pid(), binary(), map()) ::
          {:ok, %{:exit_code => integer(), :output => binary()}}
          | {:error, {:port_exit, term()} | {:port_failed, term()} | {:timeout, timeout()}}
  def command_run(session, command, opts \\ %{}) do
    :claude_agent_sdk.command_run(session, command, opts)
  end

  @doc "Submit feedback via universal feedback tracking."
  @spec submit_feedback(pid(), map()) :: :ok
  def submit_feedback(session, feedback) do
    :claude_agent_sdk.submit_feedback(session, feedback)
  end

  @doc "Respond to an agent request via universal turn response."
  @spec turn_respond(pid(), binary(), map()) :: :ok | {:error, :not_found | :already_resolved}
  def turn_respond(session, request_id, params) do
    :claude_agent_sdk.turn_respond(session, request_id, params)
  end

  @doc "Check server health. Maps to session health + adapter info for Claude."
  @spec server_health(pid()) ::
          {:ok,
           %{
             :adapter => :claude,
             :health => :active_query | :connecting | :error | :initializing | :ready
           }}
  def server_health(session), do: :claude_agent_sdk.server_health(session)

  @doc """
  Supervisor child specification for embedding a session.

  ## Examples

      children = [
        {ClaudeEx, cli_path: "claude", work_dir: "/my/project"}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec([session_opt()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :claude)
    |> BeamAgent.child_spec()
  end

  # ── Content Block Generalization (adapter-agnostic utilities) ────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters produce individual typed messages (text, tool_use, etc.).
  This function flattens both into a uniform stream where each message has a
  single, specific type — never nested content_blocks.

  Context fields (uuid, session_id, model, timestamp) from assistant messages
  are propagated to flattened children.

  ## Examples

      # Works identically regardless of which adapter produced messages:
      ClaudeEx.normalize_messages(messages)
      |> Enum.filter(& &1.type == :text)
      |> Enum.map(& &1.content)
      |> Enum.join("")
  """
  @spec normalize_messages([map()]) :: [map()]
  def normalize_messages(messages) do
    :beam_agent_content_core.normalize_messages(messages)
  end

  @doc """
  Flatten an assistant message (with content_blocks) into individual messages.

  Non-assistant messages pass through as a single-element list.
  Context fields from the parent are propagated to children.
  """
  @spec flatten_assistant(map()) :: [map()]
  def flatten_assistant(message) do
    :beam_agent_content_core.flatten_assistant(message)
  end

  @doc """
  Convert a list of flat messages into content_block() format.

  Supported types (text, thinking, tool_use, tool_result) map to their
  block equivalents. Other types are wrapped in raw blocks.
  """
  @spec messages_to_blocks([map()]) :: [content_block()]
  def messages_to_blocks(messages) do
    :beam_agent_content_core.messages_to_blocks(messages)
  end

  @doc """
  Convert a single content_block into a flat message.
  """
  @spec block_to_message(content_block()) :: %{
          :type => :raw | :text | :thinking | :tool_result | :tool_use,
          :content => term(),
          :raw => term(),
          :tool_input => term(),
          :tool_name => term(),
          :tool_use_id => term()
        }
  def block_to_message(block) do
    :beam_agent_content_core.block_to_message(block)
  end

  @doc """
  Convert a single flat message into a content_block.
  """
  @spec message_to_block(map()) :: content_block()
  def message_to_block(message) do
    :beam_agent_content_core.message_to_block(message)
  end

  # ── Additional Session Control ───────────────────────────────────

  @doc """
  Interrupt the current active query.

  Sends an interrupt signal to the CLI subprocess. The current query
  will terminate and the session returns to idle state.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    BeamAgent.Runtime.interrupt(session)
  end

  @doc """
  Send a raw control message to the session.

  Low-level interface for sending arbitrary control protocol messages.
  Most users should prefer the higher-level convenience functions.

  ## Examples

      ClaudeEx.send_control(session, "setModel", %{"model" => "claude-sonnet-4-6"})

  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :gen_statem.call(session, {:send_control, method, params}, 30_000)
  end

  # ── System Init Convenience Accessors ────────────────────────────

  @doc "List available tools from the system init data."
  @spec list_tools(pid()) :: {:ok, list()} | {:error, term()}
  def list_tools(session), do: extract_system_field(session, :tools, [])

  @doc "List available skills from the system init data."
  @spec list_skills(pid()) :: {:ok, list()} | {:error, term()}
  def list_skills(session), do: extract_system_field(session, :skills, [])

  @doc "List available plugins from the system init data."
  @spec list_plugins(pid()) :: {:ok, list()} | {:error, term()}
  def list_plugins(session), do: extract_system_field(session, :plugins, [])

  @doc "List configured MCP servers from the system init data."
  @spec list_mcp_servers(pid()) :: {:ok, list()} | {:error, term()}
  def list_mcp_servers(session), do: extract_system_field(session, :mcp_servers, [])

  @doc "List available agents from the system init data."
  @spec list_agents(pid()) :: {:ok, list()} | {:error, term()}
  def list_agents(session), do: extract_system_field(session, :agents, [])

  @doc "Get the CLI version from the system init data."
  @spec cli_version(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def cli_version(session), do: extract_system_field(session, :claude_code_version, nil)

  @doc "Get the working directory from the system init data."
  @spec working_directory(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def working_directory(session), do: extract_system_field(session, :cwd, nil)

  @doc "Get the output style from the system init data."
  @spec output_style(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def output_style(session), do: extract_system_field(session, :output_style, nil)

  @doc "Get the API key source from the system init data."
  @spec api_key_source(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def api_key_source(session), do: extract_system_field(session, :api_key_source, nil)

  @doc "List active beta features from the system init data."
  @spec active_betas(pid()) :: {:ok, list()} | {:error, term()}
  def active_betas(session), do: extract_system_field(session, :betas, [])

  @doc """
  Get the current model from session info.

  Extracts from the session's model field or system init data.
  """
  @spec current_model(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def current_model(session) do
    case session_info(session) do
      {:ok, %{model: model}} -> {:ok, model}
      {:ok, %{system_info: %{model: model}}} -> {:ok, model}
      {:ok, _} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc """
  Get the current permission mode from session info.
  """
  @spec current_permission_mode(pid()) :: {:ok, atom() | binary() | nil} | {:error, term()}
  def current_permission_mode(session) do
    extract_system_field(session, :permission_mode, nil)
  end

  # ── Todo Extraction ──────────────────────────────────────────────

  @doc """
  Extract all TodoWrite items from a list of messages.

  Scans assistant messages for `TodoWrite` tool use blocks and returns
  a flat list of todo items with `:content`, `:status`, and optional
  `:active_form` fields.
  """
  @spec extract_todos([message()]) :: [BeamAgent.Todo.todo_item()]
  defdelegate extract_todos(messages), to: BeamAgent.Todo

  @doc """
  Filter todo items by status.

  Valid statuses: `:pending`, `:in_progress`, `:completed`.
  """
  @spec filter_todos([BeamAgent.Todo.todo_item()], BeamAgent.Todo.todo_status()) ::
          [BeamAgent.Todo.todo_item()]
  defdelegate filter_todos(todos, status), to: BeamAgent.Todo, as: :filter_by_status

  @doc """
  Get a summary of todo counts by status.

  Returns a map like `%{pending: 2, in_progress: 1, completed: 3, total: 6}`.
  """
  @spec todo_summary([BeamAgent.Todo.todo_item()]) :: %{
          :total => non_neg_integer(),
          atom() => non_neg_integer()
        }
  defdelegate todo_summary(todos), to: BeamAgent.Todo

  # ── Internal ─────────────────────────────────────────────────────

  defp opts_to_map(opts) when is_list(opts) do
    Map.new(opts)
  end

  defp opts_to_map(opts) when is_map(opts), do: opts

  defp extract_system_field(session, field, default) do
    case session_info(session) do
      {:ok, %{system_info: info}} when is_map(info) ->
        {:ok, Map.get(info, field, default)}

      {:ok, _} ->
        {:ok, default}

      {:error, _} = err ->
        err
    end
  end
end
