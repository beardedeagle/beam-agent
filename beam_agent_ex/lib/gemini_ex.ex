defmodule GeminiEx do
  @moduledoc """
  Elixir wrapper for the Gemini CLI agent SDK.

  Provides idiomatic Elixir access to the Gemini CLI ACP transport.
  Sessions are persistent, multi-turn, and stream JSON-RPC notifications
  over the official Gemini CLI's ACP mode.

  ## Quick Start

      {:ok, session} = GeminiEx.start_session(cli_path: "gemini")
      {:ok, messages} = GeminiEx.query(session, "What is 2+2?")
      GeminiEx.stop(session)

  ## Streaming

      session
      |> GeminiEx.stream!("Explain quantum computing")
      |> Enum.each(&IO.inspect/1)

  ## Hooks

      hook = GeminiEx.sdk_hook(:post_tool_use, fn ctx ->
        IO.inspect(ctx, label: "tool used")
        :ok
      end)
      {:ok, session} = GeminiEx.start_session(cli_path: "gemini", sdk_hooks: [hook])
  """

  # Dialyzer infers impractically narrow binary sizes for small status maps.
  @dialyzer {:nowarn_function, reconnect_mcp_server: 2}
  @dialyzer {:nowarn_function, toggle_mcp_server: 3}

  # ── Shared Types ────────────────────────────────────────────────────

  @typep stop_reason ::
           :end_turn
           | :max_tokens
           | :stop_sequence
           | :refusal
           | :tool_use_stop
           | :unknown_stop

  @typep message_map :: %{
           required(:type) => atom(),
           required(:content) => binary(),
           required(:content_blocks) => [any()],
           required(:duration_api_ms) => non_neg_integer(),
           required(:duration_ms) => non_neg_integer(),
           required(:error_info) => map(),
           required(:errors) => [any()],
           required(:event_type) => binary(),
           required(:fast_mode_state) => map(),
           required(:is_error) => boolean(),
           required(:is_replay) => boolean(),
           required(:is_using_overage) => boolean(),
           required(:message_id) => binary(),
           required(:model) => binary(),
           required(:model_usage) => map(),
           required(:num_turns) => non_neg_integer(),
           required(:overage_disabled_reason) => binary(),
           required(:overage_resets_at) => number(),
           required(:overage_status) => binary(),
           required(:parent_tool_use_id) => :null | binary(),
           required(:permission_denials) => [any()],
           required(:rate_limit_status) => binary(),
           required(:rate_limit_type) => binary(),
           required(:raw) => map(),
           required(:request) => map(),
           required(:request_id) => binary(),
           required(:resets_at) => number(),
           required(:response) => map(),
           required(:session_id) => binary(),
           required(:stop_reason) => binary(),
           required(:stop_reason_atom) => stop_reason(),
           required(:structured_output) => term(),
           required(:subtype) => binary(),
           required(:surpassed_threshold) => number(),
           required(:system_info) => map(),
           required(:thread_id) => binary(),
           required(:timestamp) => integer(),
           required(:tool_input) => map(),
           required(:tool_name) => binary(),
           required(:tool_use_id) => binary(),
           required(:total_cost_usd) => number(),
           required(:usage) => map(),
           required(:utilization) => number(),
           required(:uuid) => binary()
         }

  @typep query_opts :: %{
           optional(:agent) => binary(),
           optional(:allowed_tools) => [binary()],
           optional(:approval_policy) => binary(),
           optional(:attachments) => [map()],
           optional(:cwd) => binary(),
           optional(:disallowed_tools) => [binary()],
           optional(:effort) => binary(),
           optional(:max_budget_usd) => number(),
           optional(:max_tokens) => pos_integer(),
           optional(:max_turns) => pos_integer(),
           optional(:mode) => binary(),
           optional(:model) => binary(),
           optional(:model_id) => binary(),
           optional(:output_format) => :json_schema | :text | binary() | map(),
           optional(:permission_mode) =>
             :accept_edits | :bypass_permissions | :default | :dont_ask | :plan | binary(),
           optional(:provider) => map(),
           optional(:provider_id) => binary(),
           optional(:sandbox_mode) => binary(),
           optional(:summary) => binary(),
           optional(:system) => binary() | map(),
           optional(:system_prompt) =>
             binary() | %{:preset => binary(), :type => :preset, :append => binary()},
           optional(:thinking) => map(),
           optional(:timeout) => timeout(),
           optional(:tools) => [any()] | map()
         }

  @typep session_info_map :: %{
           required(:session_id) => binary(),
           required(:adapter) => atom(),
           required(:created_at) => integer(),
           required(:cwd) => binary(),
           required(:extra) => map(),
           required(:message_count) => non_neg_integer(),
           required(:model) => binary(),
           required(:updated_at) => integer()
         }

  @typep content_block :: %{
           required(:type) => :raw | :text | :thinking | :tool_result | :tool_use,
           required(:content) => binary(),
           required(:id) => binary(),
           required(:input) => map(),
           required(:name) => binary(),
           required(:raw) => map(),
           required(:text) => binary(),
           required(:thinking) => binary(),
           required(:tool_use_id) => binary()
         }

  @typep hook_context :: %{
           required(:event) => atom(),
           required(:agent_id) => binary(),
           required(:agent_transcript_path) => binary(),
           required(:agent_type) => binary(),
           required(:content) => binary(),
           required(:duration_ms) => non_neg_integer(),
           required(:interrupt) => boolean(),
           required(:params) => map(),
           required(:permission_prompt_tool_name) => binary(),
           required(:permission_suggestions) => [any()],
           required(:prompt) => binary(),
           required(:reason) => term(),
           required(:session_id) => binary(),
           required(:stop_hook_active) => boolean(),
           required(:stop_reason) => atom() | binary(),
           required(:system_info) => map(),
           required(:tool_input) => map(),
           required(:tool_name) => binary(),
           required(:tool_use_id) => binary(),
           required(:updated_permissions) => map()
         }

  @typep hook_callback :: (hook_context() -> :ok | {:deny, binary()})

  @typep thread_info :: %{
           required(:created_at) => integer(),
           required(:message_count) => non_neg_integer(),
           required(:session_id) => binary(),
           required(:status) => :active | :archived | :completed | :paused,
           required(:thread_id) => binary(),
           required(:updated_at) => integer(),
           required(:visible_message_count) => non_neg_integer(),
           required(:archived) => boolean(),
           required(:archived_at) => integer(),
           required(:metadata) => map(),
           required(:name) => binary(),
           required(:parent_thread_id) => binary(),
           required(:summary) => map()
         }

  @typep thread_opts :: %{
           optional(:metadata) => map(),
           optional(:name) => binary(),
           optional(:parent_thread_id) => binary(),
           optional(:thread_id) => binary()
         }

  @typep share_info :: %{
           required(:created_at) => integer(),
           required(:session_id) => binary(),
           required(:share_id) => binary(),
           required(:status) => :active
         }

  @typep summary_info :: %{
           required(:content) => binary(),
           required(:generated_at) => integer(),
           required(:generated_by) => binary(),
           required(:message_count) => non_neg_integer(),
           required(:session_id) => binary()
         }

  @typep mcp_tool_def :: %{
           required(:description) => binary(),
           required(:handler) => (map() -> {:error, binary()} | {:ok, [any()]}),
           required(:input_schema) => map(),
           required(:name) => binary()
         }

  @typep mcp_server_def :: %{
           required(:name) => binary(),
           required(:tools) => [
             %{
               :description => binary(),
               :handler => (term() -> any()),
               :input_schema => map(),
               :name => binary()
             }
           ],
           required(:version) => binary()
         }

  @typep session_filter_opts :: %{
           optional(:adapter) => atom(),
           optional(:cwd) => binary(),
           optional(:limit) => pos_integer(),
           optional(:model) => binary(),
           optional(:since) => integer()
         }

  @typep message_filter_opts :: %{
           optional(:include_hidden) => boolean(),
           optional(:limit) => pos_integer(),
           optional(:offset) => non_neg_integer(),
           optional(:types) => [atom()]
         }

  @typep todo_item :: %{
           required(:content) => binary(),
           required(:status) => :completed | :in_progress | :pending,
           required(:active_form) => binary()
         }

  # ── Session Lifecycle ──────────────────────────────────────────────

  @doc "Start a persistent Gemini CLI ACP session."
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :gemini)
    |> BeamAgent.start_session()
  end

  @doc "Stop a session."
  @spec stop(pid()) :: :ok
  def stop(session) do
    BeamAgent.stop(session)
  end

  # ── Blocking Query ─────────────────────────────────────────────────

  @doc """
  Send a query and collect all response messages (blocking).

  Returns `{:ok, messages}` where messages is a list of `beam_agent_core`
  message maps. Uses deadline-based timeout.

  ## Options

    * `:timeout` - total query timeout in ms (default: 120_000)
  """
  @spec query(pid(), binary(), query_opts()) :: {:ok, [message_map()]} | {:error, term()}
  def query(session, prompt, params \\ %{}) do
    BeamAgent.query(session, prompt, params)
  end

  # ── Streaming ──────────────────────────────────────────────────────

  @doc """
  Returns a `Stream` that yields messages as they arrive.

  Raises on errors. Uses `Stream.resource/3` under the hood.

  The query is dispatched to the CLI immediately when `stream!/3`
  is called. Message *consumption* is lazy/pull-based.

  ## Example

      session
      |> GeminiEx.stream!("Explain OTP")
      |> Enum.each(fn msg -> IO.puts(msg.content) end)
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

  # ── Session Info & Runtime Control ─────────────────────────────────

  @doc "Query session health."
  @spec health(pid()) :: atom()
  def health(session) do
    BeamAgent.health(session)
  end

  @doc "Query session info."
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    BeamAgent.session_info(session)
  end

  @doc "Change the model at runtime."
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    BeamAgent.Runtime.set_model(session, model)
  end

  @doc "Interrupt the current query."
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    BeamAgent.Runtime.interrupt(session)
  end

  # ── SDK Hook Constructors ──────────────────────────────────────────

  @doc "Create an SDK lifecycle hook."
  @spec sdk_hook(atom(), hook_callback()) :: %{
          :event => atom(),
          :callback => hook_callback()
        }
  def sdk_hook(event, callback) do
    :beam_agent_hooks_core.hook(event, callback)
  end

  @doc "Create an SDK lifecycle hook with a matcher."
  @spec sdk_hook(atom(), hook_callback(), %{:tool_name => binary()}) :: %{
          :event => atom(),
          :callback => hook_callback(),
          :matcher => %{:tool_name => binary()},
          :compiled_re => {:re_pattern, term(), term(), term(), term()}
        }
  def sdk_hook(event, callback, matcher) do
    :beam_agent_hooks_core.hook(event, callback, matcher)
  end

  # ── Supervisor Integration ─────────────────────────────────────────

  @doc """
  Supervisor child specification for a gemini_cli_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :gemini)
    |> BeamAgent.child_spec()
  end

  # ── Content Block Generalization ──────────────────────────────────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Gemini) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      GeminiEx.normalize_messages(messages)
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
  @spec messages_to_blocks([map()]) :: [content_block()]
  def messages_to_blocks(messages), do: :beam_agent_content_core.messages_to_blocks(messages)

  @doc "Convert a single content_block into a flat message."
  @spec block_to_message(content_block()) :: %{
          :type => :raw | :text | :thinking | :tool_result | :tool_use,
          :content => term(),
          :raw => term(),
          :tool_input => term(),
          :tool_name => term(),
          :tool_use_id => term()
        }
  def block_to_message(block), do: :beam_agent_content_core.block_to_message(block)

  @doc "Convert a single flat message into a content_block."
  @spec message_to_block(map()) :: content_block()
  def message_to_block(message), do: :beam_agent_content_core.message_to_block(message)

  # ── Additional Session Control ──────────────────────────────────────

  @doc "Change the permission mode at runtime via universal control."
  @spec set_permission_mode(pid(), binary()) :: {:ok, map()}
  def set_permission_mode(session, mode) do
    BeamAgent.Runtime.set_permission_mode(session, mode)
  end

  @doc "Send a raw control message via universal control dispatch."
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :gemini_cli_client.send_control(session, method, params)
  end

  # ── SDK MCP Server Constructors ─────────────────────────────────────

  @doc "Create an in-process MCP tool definition."
  @spec mcp_tool(binary(), binary(), map(), (map() -> {:error, binary()} | {:ok, [map()]})) ::
          mcp_tool_def()
  def mcp_tool(name, description, input_schema, handler) do
    :beam_agent_tool_registry.tool(name, description, input_schema, handler)
  end

  @doc "Create an in-process MCP server definition."
  @spec mcp_server(binary(), [
          %{
            :description => binary(),
            :handler => (map() -> {term(), term()}),
            :input_schema => map(),
            :name => binary()
          }
        ]) :: mcp_server_def()
  def mcp_server(name, tools) do
    :beam_agent_tool_registry.server(name, tools)
  end

  # ── System Init Convenience Accessors ───────────────────────────────

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

  @doc "Abort the current query. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session), do: interrupt(session)

  # ── Universal: Session Store (beam_agent_core) ──────────────────────────

  @doc "List all tracked sessions."
  @spec list_sessions() :: {:ok, [session_info_map()]}
  def list_sessions, do: :gemini_cli_client.list_sessions()

  @doc "List sessions with filters."
  @spec list_sessions(session_filter_opts()) :: {:ok, [session_info_map()]}
  def list_sessions(opts) when is_map(opts), do: :gemini_cli_client.list_sessions(opts)

  @doc "Get messages for a session."
  @spec get_session_messages(binary()) :: {:ok, [message_map()]} | {:error, :not_found}
  def get_session_messages(session_id), do: :gemini_cli_client.get_session_messages(session_id)

  @doc "Get messages with options."
  @spec get_session_messages(binary(), message_filter_opts()) ::
          {:ok, [message_map()]} | {:error, :not_found}
  def get_session_messages(session_id, opts),
    do: :gemini_cli_client.get_session_messages(session_id, opts)

  @doc "Get session metadata by ID."
  @spec get_session(binary()) :: {:ok, session_info_map()} | {:error, :not_found}
  def get_session(session_id), do: :gemini_cli_client.get_session(session_id)

  @doc "Delete a session and its messages."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: :gemini_cli_client.delete_session(session_id)

  @doc "Fork a tracked session into a new session ID."
  @spec fork_session(pid(), map()) :: {:ok, session_info_map()} | {:error, :not_found}
  def fork_session(session, opts), do: :gemini_cli_client.fork_session(session, opts)

  @doc "Revert the visible session history to a prior boundary."
  @spec revert_session(pid(), map()) ::
          {:ok, session_info_map()} | {:error, :invalid_selector | :not_found}
  def revert_session(session, selector),
    do: :gemini_cli_client.revert_session(session, selector)

  @doc "Clear any stored session revert state."
  @spec unrevert_session(pid()) :: {:ok, session_info_map()} | {:error, :not_found}
  def unrevert_session(session), do: :gemini_cli_client.unrevert_session(session)

  @doc "Create or replace share state for the current session."
  @spec share_session(pid()) :: {:ok, share_info()} | {:error, :not_found}
  def share_session(session), do: :gemini_cli_client.share_session(session)

  @spec share_session(pid(), map()) :: {:ok, share_info()} | {:error, :not_found}
  def share_session(session, opts), do: :gemini_cli_client.share_session(session, opts)

  @doc "Revoke share state for the current session."
  @spec unshare_session(pid()) :: :ok | {:error, :not_found}
  def unshare_session(session), do: :gemini_cli_client.unshare_session(session)

  @doc "Generate and store a summary for the current session."
  @spec summarize_session(pid()) :: {:ok, summary_info()} | {:error, :not_found}
  def summarize_session(session), do: :gemini_cli_client.summarize_session(session)

  @spec summarize_session(pid(), map()) :: {:ok, summary_info()} | {:error, :not_found}
  def summarize_session(session, opts),
    do: :gemini_cli_client.summarize_session(session, opts)

  # ── Universal: Thread Management (beam_agent_core) ──────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), thread_opts()) ::
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
    do: :gemini_cli_client.thread_start(session, opts)

  @doc "Resume an existing thread."
  @spec thread_resume(pid(), binary()) :: {:ok, thread_info()} | {:error, :not_found}
  def thread_resume(session, thread_id),
    do: :gemini_cli_client.thread_resume(session, thread_id)

  @doc "List all threads for this session."
  @spec thread_list(pid()) :: {:ok, [thread_info()]}
  def thread_list(session), do: :gemini_cli_client.thread_list(session)

  @doc "Fork an existing thread."
  @spec thread_fork(pid(), binary()) :: {:ok, thread_info()} | {:error, :not_found}
  def thread_fork(session, thread_id),
    do: :gemini_cli_client.thread_fork(session, thread_id)

  @spec thread_fork(pid(), binary(), thread_opts()) ::
          {:ok, thread_info()} | {:error, :not_found}
  def thread_fork(session, thread_id, opts),
    do: :gemini_cli_client.thread_fork(session, thread_id, opts)

  @doc "Read thread metadata, optionally including visible messages."
  @spec thread_read(pid(), binary()) ::
          {:ok, %{:thread => thread_info(), :messages => [map()]}} | {:error, :not_found}
  def thread_read(session, thread_id),
    do: :gemini_cli_client.thread_read(session, thread_id)

  @spec thread_read(pid(), binary(), map()) ::
          {:ok, %{:thread => thread_info(), :messages => [map()]}} | {:error, :not_found}
  def thread_read(session, thread_id, opts),
    do: :gemini_cli_client.thread_read(session, thread_id, opts)

  @doc "Archive a thread."
  @spec thread_archive(pid(), binary()) :: {:ok, thread_info()} | {:error, :not_found}
  def thread_archive(session, thread_id),
    do: :gemini_cli_client.thread_archive(session, thread_id)

  @doc "Unarchive a thread."
  @spec thread_unarchive(pid(), binary()) :: {:ok, thread_info()} | {:error, :not_found}
  def thread_unarchive(session, thread_id),
    do: :gemini_cli_client.thread_unarchive(session, thread_id)

  @doc "Rollback the visible thread history."
  @spec thread_rollback(pid(), binary(), map()) ::
          {:ok, thread_info()} | {:error, :invalid_selector | :not_found}
  def thread_rollback(session, thread_id, selector),
    do: :gemini_cli_client.thread_rollback(session, thread_id, selector)

  # ── Universal: MCP Management (beam_agent_core) ─────────────────────────

  @doc "Get status of all MCP servers."
  @spec mcp_server_status(pid()) :: {:ok, %{binary() => map()}}
  def mcp_server_status(session),
    do: :gemini_cli_client.mcp_server_status(session)

  @doc "Replace MCP server configurations."
  @spec set_mcp_servers(pid(), [%{:name => binary(), :tools => [map()], :version => binary()}]) ::
          {:error, :not_found} | {:ok, %{binary() => binary()}}
  def set_mcp_servers(session, servers),
    do: :gemini_cli_client.set_mcp_servers(session, servers)

  @doc "Reconnect a failed MCP server."
  @spec reconnect_mcp_server(pid(), binary()) ::
          {:error, :not_found} | {:ok, %{binary() => binary()}}
  def reconnect_mcp_server(session, server_name),
    do: :gemini_cli_client.reconnect_mcp_server(session, server_name)

  @doc "Enable or disable an MCP server."
  @spec toggle_mcp_server(pid(), binary(), boolean()) ::
          {:error, :not_found} | {:ok, %{binary() => binary()}}
  def toggle_mcp_server(session, server_name, enabled),
    do: :gemini_cli_client.toggle_mcp_server(session, server_name, enabled)

  # ── Universal: Init Response Accessors ─────────────────────────────

  @doc "List available slash commands."
  @spec supported_commands(pid()) :: {:ok, list()} | {:error, term()}
  def supported_commands(session), do: :gemini_cli_client.supported_commands(session)

  @doc "List available models."
  @spec supported_models(pid()) :: {:ok, list()} | {:error, term()}
  def supported_models(session), do: :gemini_cli_client.supported_models(session)

  @doc "List available agents."
  @spec supported_agents(pid()) :: {:ok, list()} | {:error, term()}
  def supported_agents(session), do: :gemini_cli_client.supported_agents(session)

  @doc "Get account information."
  @spec account_info(pid()) :: {:ok, map()} | {:error, term()}
  def account_info(session), do: :gemini_cli_client.account_info(session)

  # ── Universal: Session Control (beam_agent_core) ───────────────────────

  @doc "Set maximum thinking tokens via universal control."
  @spec set_max_thinking_tokens(pid(), pos_integer()) ::
          {:ok, %{:max_thinking_tokens => pos_integer()}}
  def set_max_thinking_tokens(session, max_tokens) do
    :gemini_cli_client.set_max_thinking_tokens(session, max_tokens)
  end

  @doc "Revert file changes to a checkpoint via universal checkpointing."
  @spec rewind_files(pid(), binary()) ::
          :ok | {:error, :not_found | {:restore_failed, binary(), atom()}}
  def rewind_files(session, checkpoint_uuid) do
    :gemini_cli_client.rewind_files(session, checkpoint_uuid)
  end

  @doc "Stop a running agent task via universal task tracking."
  @spec stop_task(pid(), binary()) :: :ok | {:error, :not_found}
  def stop_task(session, task_id) do
    :gemini_cli_client.stop_task(session, task_id)
  end

  @doc "Run a command via universal command execution."
  @spec command_run(pid(), binary(), map()) ::
          {:ok, %{:exit_code => integer(), :output => binary()}}
          | {:error, {:port_exit, term()} | {:port_failed, term()} | {:timeout, timeout()}}
  def command_run(session, command, opts \\ %{}) do
    :gemini_cli_client.command_run(session, command, opts)
  end

  @doc "Submit feedback via universal feedback tracking."
  @spec submit_feedback(pid(), map()) :: :ok
  def submit_feedback(session, feedback) do
    :gemini_cli_client.submit_feedback(session, feedback)
  end

  @doc "Respond to an agent request via universal turn response."
  @spec turn_respond(pid(), binary(), map()) :: :ok | {:error, :not_found | :already_resolved}
  def turn_respond(session, request_id, params) do
    :gemini_cli_client.turn_respond(session, request_id, params)
  end

  @doc "Check server health. Maps to session health for Gemini."
  @spec server_health(pid()) ::
          {:ok,
           %{
             :adapter => :gemini_cli,
             :health => :active_query | :connecting | :error | :initializing | :ready
           }}
  def server_health(session), do: :gemini_cli_client.server_health(session)

  # ── Todo Extraction ─────────────────────────────────────────────────

  @doc "Extract all TodoWrite items from a list of messages."
  @spec extract_todos([message_map()]) :: [todo_item()]
  defdelegate extract_todos(messages), to: BeamAgent.Todo

  @doc "Filter todo items by status."
  @spec filter_todos([BeamAgent.Todo.todo_item()], BeamAgent.Todo.todo_status()) ::
          [BeamAgent.Todo.todo_item()]
  defdelegate filter_todos(todos, status), to: BeamAgent.Todo, as: :filter_by_status

  @doc "Get a summary of todo counts by status."
  @spec todo_summary([todo_item()]) :: %{:total => non_neg_integer(), atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: BeamAgent.Todo

  # ── Internal ───────────────────────────────────────────────────────

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
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
