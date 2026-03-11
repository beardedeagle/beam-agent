defmodule CopilotEx do
  @moduledoc """
  Elixir wrapper for the Copilot CLI agent SDK.

  Provides idiomatic Elixir access to `copilot_session` (Erlang/OTP
  gen_statem) with lazy streaming via `Stream.resource/3`.

  ## Quick Start

      {:ok, session} = CopilotEx.start_session(cli_path: "copilot")
      {:ok, messages} = CopilotEx.query(session, "What is 2 + 2?")
      CopilotEx.stop(session)

  ## Streaming

      session
      |> CopilotEx.stream!("Explain OTP supervision trees")
      |> Enum.each(fn msg ->
        case msg.type do
          :text   -> IO.write(msg.content)
          :result -> IO.puts("\\nDone!")
          _       -> :ok
        end
      end)

  ## Session Options

  - `:cli_path` - Path to the Copilot CLI executable (default: `"copilot"`)
  - `:work_dir` - Working directory for the CLI subprocess
  - `:env` - Environment variables as `[{key, value}]` charlists
  - `:buffer_max` - Max raw binary buffer in bytes (default: 2MB)
  - `:session_id` - Resume a previous session (binary)
  - `:model` - Model to use (binary)
  - `:system_message` - System prompt sent to the Copilot session
  - `:permission_mode` - Permission mode (binary)
  - `:permission_handler` - `fn(request, invocation, opts) -> result` callback
  - `:available_tools` - Allowed tool list passed to Copilot
  - `:excluded_tools` - Disallowed tool list passed to Copilot
  - `:mcp_servers` - MCP server configurations (map)
  - `:output_format` - Structured output JSON schema (map)
  - `:reasoning_effort` - Reasoning effort level
  - `:sdk_mcp_servers` - In-process MCP servers (list of server maps).
    All adapters share this unified API via `beam_agent_tool_registry`.
  - `:sdk_hooks` - SDK lifecycle hooks (list of hook maps)
  - `:user_input_handler` - User input request handler function

  ## In-Process MCP Tools

  Register tools via the unified `beam_agent_tool_registry` API (same as all adapters):

      tool = :beam_agent_tool_registry.tool("weather", "Get weather",
        %{"type" => "object",
          "properties" => %{"city" => %{"type" => "string"}}},
        fn args ->
          city = Map.get(args, "city", "unknown")
          {:ok, [%{type: :text, text: "72F in \#{city}"}]}
        end)
      server = :beam_agent_tool_registry.server("my-tools", [tool])
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        sdk_mcp_servers: [server]
      )

  ## Permission Handling

  Register a handler for Copilot permission requests (fail-closed by default):

      handler = fn request, _invocation, _opts ->
        case request do
          %{"kind" => "file_write"} -> {:allow, %{}}
          _ -> {:deny, "Not allowed"}
        end
      end
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        permission_handler: handler
      )
  """

  # ── Session Lifecycle ────────────────────────────────────────────

  @doc """
  Start a new Copilot CLI session.

  Returns `{:ok, pid}` on success. The session process speaks
  full bidirectional JSON-RPC 2.0 over Content-Length framed stdio.

  ## Examples

      {:ok, session} = CopilotEx.start_session(cli_path: "copilot")
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        model: "gpt-4o",
        permission_mode: "acceptEdits"
      )
  """
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :copilot)
    |> BeamAgent.start_session()
  end

  @doc "Gracefully stop a session, closing the CLI subprocess."
  @spec stop(pid()) :: :ok
  def stop(session) do
    BeamAgent.stop(session)
  end

  # ── Blocking Query ───────────────────────────────────────────────

  @doc """
  Send a query and collect all response messages (blocking).

  Returns `{:ok, messages}` once the query completes (session.idle).
  Uses deadline-based timeout.

  ## Options

    * `:timeout` - total query timeout in ms (default: 120_000)

  ## Examples

      {:ok, messages} = CopilotEx.query(session, "Hello!")
      last = List.last(messages)
      IO.puts(last.content)
  """
  @spec query(pid(), binary(), map()) :: {:ok, [map()]} | {:error, term()}
  def query(session, prompt, params \\ %{}) do
    BeamAgent.query(session, prompt, params)
  end

  # ── Streaming ────────────────────────────────────────────────────

  @doc """
  Returns a `Stream` that yields messages as they arrive.

  Raises on errors. Uses `Stream.resource/3` under the hood with
  demand-driven backpressure — the gen_statem only delivers the
  next message when the stream consumer requests it.

  The query is dispatched to the CLI immediately when `stream!/3`
  is called (not lazily on first consumption). Message *consumption*
  is lazy/pull-based.

  The stream halts automatically when a `:result` or terminal `:error`
  message is received. Note: Copilot can emit non-terminal `:error`
  messages (warnings), so the halt condition checks `is_error: true`
  — unlike other adapters where all `:error` messages are terminal.

  ## Examples

      CopilotEx.stream!(session, "Explain GenServer")
      |> Stream.filter(& &1.type == :text)
      |> Enum.map(& &1.content)
      |> Enum.join("")

      # With options
      CopilotEx.stream!(session, "Hello", %{timeout: 60_000})
      |> Enum.to_list()
  """
  @spec stream!(pid(), binary(), map()) :: Enumerable.t()
  def stream!(session, prompt, params \\ %{}) do
    BeamAgent.stream!(session, prompt, params)
  end

  @doc """
  Returns a `Stream` that yields `{:ok, msg}` or `{:error, reason}` tuples.

  Non-raising variant of `stream!/3`.
  """
  @spec stream(pid(), binary(), map()) :: Enumerable.t()
  def stream(session, prompt, params \\ %{}) do
    BeamAgent.stream(session, prompt, params)
  end

  # ── Session Info & Runtime Control ───────────────────────────────

  @doc """
  Get the current health/state of a session.

  ## Examples

      :ready = CopilotEx.health(session)
  """
  @spec health(pid()) :: :connecting | :initializing | :ready | :active_query | :error
  def health(session) do
    BeamAgent.health(session)
  end

  @doc """
  Query session info (adapter, session_id, model, etc.).

  ## Examples

      {:ok, info} = CopilotEx.session_info(session)
      info.copilot_session_id
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    BeamAgent.session_info(session)
  end

  @doc """
  Change the model at runtime during a session.

  ## Examples

      {:ok, _} = CopilotEx.set_model(session, "gpt-4o")
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    BeamAgent.set_model(session, model)
  end

  @doc "Resume a native Copilot session by id."
  @spec resume_session(binary()) :: {:ok, pid()} | {:error, term()}
  def resume_session(session_id) do
    :copilot_client.resume_session(session_id)
  end

  @spec resume_session(binary(), keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def resume_session(session_id, opts) do
    :copilot_client.resume_session(session_id, opts_to_map(opts))
  end

  @doc """
  Interrupt/abort the current active query.

  ## Examples

      :ok = CopilotEx.interrupt(session)
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    BeamAgent.interrupt(session)
  end

  @doc "Abort the current active query. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session) do
    BeamAgent.abort(session)
  end

  # ── Arbitrary Control ────────────────────────────────────────────

  @doc """
  Send an arbitrary JSON-RPC command to the Copilot CLI.

  ## Examples

      {:ok, result} = CopilotEx.send_command(session, "config.get", %{})
  """
  @spec send_command(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_command(session, method, params \\ %{}) do
    :copilot_client.send_command(session, method, params)
  end

  @doc "Get native Copilot CLI status information."
  @spec get_status(pid()) :: {:ok, term()} | {:error, term()}
  def get_status(session), do: :copilot_client.get_status(session)

  @doc "Get native Copilot authentication status."
  @spec get_auth_status(pid()) :: {:ok, term()} | {:error, term()}
  def get_auth_status(session), do: :copilot_client.get_auth_status(session)

  @doc "List native Copilot models with metadata."
  @spec model_list(pid()) :: {:ok, term()} | {:error, term()}
  def model_list(session), do: :copilot_client.model_list(session)

  @doc "Get the last native Copilot session id."
  @spec get_last_session_id(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def get_last_session_id(session), do: :copilot_client.get_last_session_id(session)

  @doc "List native Copilot sessions."
  @spec list_server_sessions(pid()) :: {:ok, [map()]} | {:error, term()}
  def list_server_sessions(session), do: :copilot_client.list_server_sessions(session)

  @spec list_server_sessions(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_server_sessions(session, filter),
    do: :copilot_client.list_server_sessions(session, filter)

  @doc "Get native Copilot session metadata by id."
  @spec get_server_session(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def get_server_session(session, session_id),
    do: :copilot_client.get_server_session(session, session_id)

  @doc "Delete a native Copilot session by id."
  @spec delete_server_session(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def delete_server_session(session, session_id),
    do: :copilot_client.delete_server_session(session, session_id)

  @doc "Fetch native Copilot events/messages for the current session."
  @spec session_get_messages(pid()) :: {:ok, term()} | {:error, term()}
  def session_get_messages(session), do: :copilot_client.session_get_messages(session)

  @spec session_get_messages(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def session_get_messages(session, session_id),
    do: :copilot_client.session_get_messages(session, session_id)

  @doc "Destroy the current native Copilot session."
  @spec session_destroy(pid()) :: {:ok, term()} | {:error, term()}
  def session_destroy(session), do: :copilot_client.session_destroy(session)

  @spec session_destroy(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def session_destroy(session, session_id),
    do: :copilot_client.session_destroy(session, session_id)

  # ── SDK Hook Constructors ────────────────────────────────────────

  @doc """
  Create an SDK lifecycle hook.

  Hooks fire at the shared `BeamAgent.Hooks` lifecycle points, including
  blocking events like `:pre_tool_use`, `:user_prompt_submit`, and
  `:permission_request`, plus notification events such as `:post_tool_use`,
  `:post_tool_use_failure`, `:session_start`, `:session_end`,
  `:subagent_start`, `:subagent_stop`, `:pre_compact`, `:notification`,
  `:config_change`, `:task_completed`, and `:teammate_idle`.

  ## Examples

      hook = CopilotEx.sdk_hook(:pre_tool_use, fn ctx ->
        case ctx.tool_name do
          "Bash" -> {:deny, "No shell access"}
          _ -> :ok
        end
      end)
      {:ok, session} = CopilotEx.start_session(sdk_hooks: [hook])
  """
  @spec sdk_hook(atom(), function()) :: map()
  def sdk_hook(event, callback) do
    :beam_agent_hooks_core.hook(event, callback)
  end

  @doc """
  Create an SDK lifecycle hook with a matcher filter.

  ## Examples

      hook = CopilotEx.sdk_hook(:pre_tool_use,
        fn _ctx -> {:deny, "blocked"} end,
        %{tool_name: "Bash"})
  """
  @spec sdk_hook(atom(), function(), map()) :: map()
  def sdk_hook(event, callback, matcher) do
    :beam_agent_hooks_core.hook(event, callback, matcher)
  end

  # ── Supervisor Integration ───────────────────────────────────────

  @doc """
  Supervisor child specification for a copilot_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.

  ## Examples

      children = [
        {CopilotEx, cli_path: "copilot", work_dir: "/my/project"}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :copilot)
    |> BeamAgent.child_spec()
  end

  # ── Content Block Generalization ─────────────────────────────────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Copilot) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      CopilotEx.normalize_messages(messages)
      |> Enum.filter(& &1.type == :text)
      |> Enum.map(& &1.content)
      |> Enum.join("")
  """
  @spec normalize_messages([map()]) :: [map()]
  def normalize_messages(messages) do
    :beam_agent_content_core.normalize_messages(messages)
  end

  @doc "Flatten an assistant message (with content_blocks) into individual messages."
  @spec flatten_assistant(map()) :: [map()]
  def flatten_assistant(message), do: :beam_agent_content_core.flatten_assistant(message)

  @doc "Convert a list of flat messages into content_block format."
  @spec messages_to_blocks([map()]) :: [map()]
  def messages_to_blocks(messages), do: :beam_agent_content_core.messages_to_blocks(messages)

  @doc "Convert a single content_block into a flat message."
  @spec block_to_message(map()) :: map()
  def block_to_message(block), do: :beam_agent_content_core.block_to_message(block)

  @doc "Convert a single flat message into a content_block."
  @spec message_to_block(map()) :: map()
  def message_to_block(message), do: :beam_agent_content_core.message_to_block(message)

  # ── SDK MCP Server Constructors ──────────────────────────────────

  @doc "Create an in-process MCP tool definition."
  @spec mcp_tool(binary(), binary(), map(), (map() -> {:ok, list()} | {:error, binary()})) ::
          map()
  def mcp_tool(name, description, input_schema, handler) do
    :beam_agent_tool_registry.tool(name, description, input_schema, handler)
  end

  @doc "Create an in-process MCP server definition."
  @spec mcp_server(binary(), [map()]) :: map()
  def mcp_server(name, tools) do
    :beam_agent_tool_registry.server(name, tools)
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

  @doc "Get the current permission mode from session info."
  @spec current_permission_mode(pid()) :: {:ok, atom() | binary() | nil} | {:error, term()}
  def current_permission_mode(session) do
    extract_system_field(session, :permission_mode, nil)
  end

  # ── Universal: Session Store (beam_agent_core) ─────────────────────────

  @doc "List all tracked sessions."
  @spec list_sessions() :: {:ok, [map()]}
  def list_sessions, do: :copilot_client.list_sessions()

  @doc "List sessions with filters."
  @spec list_sessions(map()) :: {:ok, [map()]}
  def list_sessions(opts) when is_map(opts), do: :copilot_client.list_sessions(opts)

  @doc "Get messages for a session."
  @spec get_session_messages(binary()) :: {:ok, [map()]} | {:error, :not_found}
  def get_session_messages(session_id), do: :copilot_client.get_session_messages(session_id)

  @doc "Get messages with options."
  @spec get_session_messages(binary(), map()) :: {:ok, [map()]} | {:error, :not_found}
  def get_session_messages(session_id, opts),
    do: :copilot_client.get_session_messages(session_id, opts)

  @doc "Get session metadata by ID."
  @spec get_session(binary()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id), do: :copilot_client.get_session(session_id)

  @doc "Delete a session and its messages."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: :copilot_client.delete_session(session_id)

  @doc "Fork a tracked session into a new session ID."
  @spec fork_session(pid(), map()) :: {:ok, map()} | {:error, :not_found}
  def fork_session(session, opts), do: :copilot_client.fork_session(session, opts)

  @doc "Revert the visible session history to a prior boundary."
  @spec revert_session(pid(), map()) :: {:ok, map()} | {:error, term()}
  def revert_session(session, selector),
    do: :copilot_client.revert_session(session, selector)

  @doc "Clear any stored session revert state."
  @spec unrevert_session(pid()) :: {:ok, map()} | {:error, :not_found}
  def unrevert_session(session), do: :copilot_client.unrevert_session(session)

  @doc "Create or replace share state for the current session."
  @spec share_session(pid()) :: {:ok, map()} | {:error, :not_found}
  def share_session(session), do: :copilot_client.share_session(session)

  @spec share_session(pid(), map()) :: {:ok, map()} | {:error, :not_found}
  def share_session(session, opts), do: :copilot_client.share_session(session, opts)

  @doc "Revoke share state for the current session."
  @spec unshare_session(pid()) :: :ok | {:error, :not_found}
  def unshare_session(session), do: :copilot_client.unshare_session(session)

  @doc "Generate and store a summary for the current session."
  @spec summarize_session(pid()) :: {:ok, map()} | {:error, :not_found}
  def summarize_session(session), do: :copilot_client.summarize_session(session)

  @spec summarize_session(pid(), map()) :: {:ok, map()} | {:error, :not_found}
  def summarize_session(session, opts),
    do: :copilot_client.summarize_session(session, opts)

  # ── Universal: Thread Management (beam_agent_core) ────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), map()) :: {:ok, map()}
  def thread_start(session, opts \\ %{}),
    do: :copilot_client.thread_start(session, opts)

  @doc "Resume an existing thread."
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_resume(session, thread_id),
    do: :copilot_client.thread_resume(session, thread_id)

  @doc "List all threads for this session."
  @spec thread_list(pid()) :: {:ok, [map()]}
  def thread_list(session), do: :copilot_client.thread_list(session)

  @doc "Fork an existing thread."
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_fork(session, thread_id),
    do: :copilot_client.thread_fork(session, thread_id)

  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, :not_found}
  def thread_fork(session, thread_id, opts),
    do: :copilot_client.thread_fork(session, thread_id, opts)

  @doc "Read thread metadata, optionally including visible messages."
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_read(session, thread_id),
    do: :copilot_client.thread_read(session, thread_id)

  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, :not_found}
  def thread_read(session, thread_id, opts),
    do: :copilot_client.thread_read(session, thread_id, opts)

  @doc "Archive a thread."
  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_archive(session, thread_id),
    do: :copilot_client.thread_archive(session, thread_id)

  @doc "Unarchive a thread."
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_unarchive(session, thread_id),
    do: :copilot_client.thread_unarchive(session, thread_id)

  @doc "Rollback the visible thread history."
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_rollback(session, thread_id, selector),
    do: :copilot_client.thread_rollback(session, thread_id, selector)

  # ── Universal: MCP Management (beam_agent_core) ───────────────────────

  @doc "Get status of all MCP servers."
  @spec mcp_server_status(pid()) :: {:ok, map()}
  def mcp_server_status(session), do: :copilot_client.mcp_server_status(session)

  @doc "Replace MCP server configurations."
  @spec set_mcp_servers(pid(), [map()]) :: {:ok, term()} | {:error, term()}
  def set_mcp_servers(session, servers),
    do: :copilot_client.set_mcp_servers(session, servers)

  @doc "Reconnect a failed MCP server."
  @spec reconnect_mcp_server(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def reconnect_mcp_server(session, server_name),
    do: :copilot_client.reconnect_mcp_server(session, server_name)

  @doc "Enable or disable an MCP server."
  @spec toggle_mcp_server(pid(), binary(), boolean()) :: {:ok, term()} | {:error, term()}
  def toggle_mcp_server(session, server_name, enabled),
    do: :copilot_client.toggle_mcp_server(session, server_name, enabled)

  # ── Universal: Init Response Accessors ───────────────────────────

  @doc "List available slash commands."
  @spec supported_commands(pid()) :: {:ok, list()} | {:error, term()}
  def supported_commands(session), do: :copilot_client.supported_commands(session)

  @doc "List available models."
  @spec supported_models(pid()) :: {:ok, list()} | {:error, term()}
  def supported_models(session), do: :copilot_client.supported_models(session)

  @doc "List available agents."
  @spec supported_agents(pid()) :: {:ok, list()} | {:error, term()}
  def supported_agents(session), do: :copilot_client.supported_agents(session)

  @doc "Get account information."
  @spec account_info(pid()) :: {:ok, map()} | {:error, term()}
  def account_info(session), do: :copilot_client.account_info(session)

  # ── Universal: Session Control (beam_agent_core) ──────────────────────

  @doc "Change the permission mode at runtime via universal control."
  @spec set_permission_mode(pid(), binary()) :: {:ok, map()}
  def set_permission_mode(session, mode) do
    BeamAgent.set_permission_mode(session, mode)
  end

  @doc "Set maximum thinking tokens via universal control."
  @spec set_max_thinking_tokens(pid(), pos_integer()) :: {:ok, map()}
  def set_max_thinking_tokens(session, max_tokens) do
    :copilot_client.set_max_thinking_tokens(session, max_tokens)
  end

  @doc "Revert file changes to a checkpoint via universal checkpointing."
  @spec rewind_files(pid(), binary()) :: :ok | {:error, :not_found | term()}
  def rewind_files(session, checkpoint_uuid) do
    :copilot_client.rewind_files(session, checkpoint_uuid)
  end

  @doc "Stop a running agent task via universal task tracking."
  @spec stop_task(pid(), binary()) :: :ok | {:error, :not_found}
  def stop_task(session, task_id) do
    :copilot_client.stop_task(session, task_id)
  end

  @doc "Run a command via universal command execution."
  @spec command_run(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def command_run(session, command, opts \\ %{}) do
    :copilot_client.command_run(session, command, opts)
  end

  @doc "Submit feedback via universal feedback tracking."
  @spec submit_feedback(pid(), map()) :: :ok
  def submit_feedback(session, feedback) do
    :copilot_client.submit_feedback(session, feedback)
  end

  @doc "Respond to an agent request via universal turn response."
  @spec turn_respond(pid(), binary(), map()) :: :ok | {:error, :not_found | :already_resolved}
  def turn_respond(session, request_id, params) do
    :copilot_client.turn_respond(session, request_id, params)
  end

  @doc "Send a raw control message. Delegates to native Copilot implementation."
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params) do
    :copilot_client.send_control(session, method, params)
  end

  @doc "Check server health. Maps to session health for Copilot."
  @spec server_health(pid()) :: {:ok, map()}
  def server_health(session), do: :copilot_client.server_health(session)

  # ── Todo Extraction ──────────────────────────────────────────────

  @doc "Extract all TodoWrite items from a list of messages."
  @spec extract_todos([map()]) :: [BeamAgent.Todo.todo_item()]
  defdelegate extract_todos(messages), to: BeamAgent.Todo

  @doc "Filter todo items by status."
  @spec filter_todos([BeamAgent.Todo.todo_item()], BeamAgent.Todo.todo_status()) ::
          [BeamAgent.Todo.todo_item()]
  defdelegate filter_todos(todos, status), to: BeamAgent.Todo, as: :filter_by_status

  @doc "Get a summary of todo counts by status."
  @spec todo_summary([BeamAgent.Todo.todo_item()]) :: %{atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: BeamAgent.Todo

  # ── Internal ─────────────────────────────────────────────────────

  defp opts_to_map(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> opts_to_map()
  end

  defp opts_to_map(opts) when is_map(opts) do
    opts
  end

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
