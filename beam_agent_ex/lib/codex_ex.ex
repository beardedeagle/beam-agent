defmodule CodexEx do
  @moduledoc """
  Elixir wrapper for the Codex CLI agent SDK.

  Provides idiomatic Elixir access to the Codex app-server, direct realtime
  voice, and exec transports. For most use cases, use `start_session/1` for
  full bidirectional JSON-RPC, `start_realtime/1` for direct realtime voice,
  or `start_exec/1` for simpler one-shot queries.

  ## Quick Start

      {:ok, session} = CodexEx.start_session(cli_path: "codex")
      {:ok, messages} = CodexEx.query(session, "What is 2+2?")
      CodexEx.stop(session)

  ## Streaming

      session
      |> CodexEx.stream!("Explain quantum computing")
      |> Enum.each(&IO.inspect/1)

  ## Thread Management (app-server only)

      {:ok, %{"threadId" => tid}} = CodexEx.thread_start(session, %{})
      {:ok, messages} = CodexEx.query(session, "Follow-up question")
  """

  # Dialyzer infers impractically narrow binary sizes for small status maps
  # and expands type aliases more aggressively than the spec references.
  @dialyzer {:nowarn_function, reconnect_mcp_server: 2}
  @dialyzer {:nowarn_function, toggle_mcp_server: 3}
  @dialyzer {:nowarn_function, sdk_hook: 2}
  @dialyzer {:nowarn_function, get_session_messages: 2}
  @dialyzer {:nowarn_function, extract_todos: 1}

  # ── Shared Types ────────────────────────────────────────────────────

  @typedoc "Stop reason atoms returned by the backend."
  @type stop_reason ::
          :end_turn
          | :max_tokens
          | :refusal
          | :stop_sequence
          | :tool_use_stop
          | :unknown_stop

  @typedoc "A message map as returned by `beam_agent_core`."
  @type message :: %{
          required(:type) => atom(),
          optional(:content) => binary(),
          optional(:content_blocks) => [any()],
          optional(:duration_api_ms) => non_neg_integer(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:error_info) => map(),
          optional(:errors) => [any()],
          optional(:event_type) => binary(),
          optional(:fast_mode_state) => map(),
          optional(:is_error) => boolean(),
          optional(:is_replay) => boolean(),
          optional(:is_using_overage) => boolean(),
          optional(:message_id) => binary(),
          optional(:model) => binary(),
          optional(:model_usage) => map(),
          optional(:num_turns) => non_neg_integer(),
          optional(:overage_disabled_reason) => binary(),
          optional(:overage_resets_at) => number(),
          optional(:overage_status) => binary(),
          optional(:parent_tool_use_id) => :null | binary(),
          optional(:permission_denials) => [any()],
          optional(:rate_limit_status) => binary(),
          optional(:rate_limit_type) => binary(),
          optional(:raw) => map(),
          optional(:request) => map(),
          optional(:request_id) => binary(),
          optional(:resets_at) => number(),
          optional(:response) => map(),
          optional(:session_id) => binary(),
          optional(:stop_reason) => binary(),
          optional(:stop_reason_atom) => stop_reason(),
          optional(:structured_output) => term(),
          optional(:subtype) => binary(),
          optional(:surpassed_threshold) => number(),
          optional(:system_info) => map(),
          optional(:thread_id) => binary(),
          optional(:timestamp) => integer(),
          optional(:tool_input) => map(),
          optional(:tool_name) => binary(),
          optional(:tool_use_id) => binary(),
          optional(:total_cost_usd) => number(),
          optional(:usage) => map(),
          optional(:utilization) => number(),
          optional(:uuid) => binary()
        }

  @typedoc "Query parameter map accepted by `query/3` and `send_query/4`."
  @type query_params :: %{
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

  @typedoc "A content block used in message-to-block conversions."
  @type content_block :: %{
          required(:type) => :raw | :text | :thinking | :tool_result | :tool_use,
          optional(:content) => binary(),
          optional(:id) => binary(),
          optional(:input) => map(),
          optional(:name) => binary(),
          optional(:raw) => map(),
          optional(:text) => binary(),
          optional(:thinking) => binary(),
          optional(:tool_use_id) => binary()
        }

  @typedoc "A flat message produced from a content block."
  @type flat_message :: %{
          required(:type) => :raw | :text | :thinking | :tool_result | :tool_use,
          optional(:content) => term(),
          optional(:raw) => term(),
          optional(:tool_input) => term(),
          optional(:tool_name) => term(),
          optional(:tool_use_id) => term()
        }

  @typedoc "Session store entry map."
  @type session_store_entry :: %{
          :session_id => binary(),
          :adapter => atom(),
          :created_at => integer(),
          :cwd => binary(),
          :extra => map(),
          :message_count => non_neg_integer(),
          :model => binary(),
          :updated_at => integer()
        }

  @typedoc "Session filter options for `list_sessions/1`."
  @type session_filter_opts :: %{
          optional(:adapter) => atom(),
          optional(:cwd) => binary(),
          optional(:limit) => pos_integer(),
          optional(:model) => binary(),
          optional(:since) => integer()
        }

  @typedoc "Share state information."
  @type share_info :: %{
          :created_at => integer(),
          :session_id => binary(),
          :share_id => binary(),
          :status => :active
        }

  @typedoc "Session summary information."
  @type summary_info :: %{
          :content => binary(),
          :generated_at => integer(),
          :generated_by => binary(),
          :message_count => non_neg_integer(),
          :session_id => binary()
        }

  @typedoc "Hook context map passed to SDK lifecycle hook callbacks."
  @type hook_context :: %{
          optional(:event) => atom(),
          optional(:agent_id) => binary(),
          optional(:agent_transcript_path) => binary(),
          optional(:agent_type) => binary(),
          optional(:content) => binary(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:interrupt) => boolean(),
          optional(:params) => map(),
          optional(:permission_prompt_tool_name) => binary(),
          optional(:permission_suggestions) => [any()],
          optional(:prompt) => binary(),
          optional(:reason) => term(),
          optional(:session_id) => binary(),
          optional(:stop_hook_active) => boolean(),
          optional(:stop_reason) => atom() | binary(),
          optional(:system_info) => map(),
          optional(:tool_input) => map(),
          optional(:tool_name) => binary(),
          optional(:tool_use_id) => binary(),
          optional(:updated_permissions) => map()
        }

  @typedoc "Hook callback function type."
  @type hook_callback :: (hook_context() -> :ok | {:deny, binary()})

  @typedoc "SDK hook definition returned by `sdk_hook/2,3`."
  @type hook_def :: %{
          :callback => hook_callback(),
          :event => atom(),
          optional(:matcher) => %{:tool_name => binary()},
          optional(:compiled_re) => {:re_pattern, term(), term(), term(), term()}
        }

  @typedoc "MCP tool definition map."
  @type mcp_tool_def :: %{
          :description => binary(),
          :handler => (map() -> {:error, binary()} | {:ok, [any()]}),
          :input_schema => map(),
          :name => binary()
        }

  @typedoc "MCP server definition map."
  @type mcp_server_def :: %{
          :name => binary(),
          :tools => [mcp_tool_def()],
          :version => binary()
        }

  @typedoc "Server health status map."
  @type server_health_info :: %{
          :adapter => :codex,
          :health =>
            :active_query | :active_turn | :connecting | :error | :initializing | :ready
        }

  @typedoc "Todo item extracted from messages."
  @type todo_item :: %{
          required(:content) => binary(),
          required(:status) => :completed | :in_progress | :pending,
          optional(:active_form) => binary()
        }

  # ── Session Lifecycle ──────────────────────────────────────────────

  @doc "Start a Codex app-server session (full bidirectional JSON-RPC)."
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :codex)
    |> Map.put_new(:transport, :app_server)
    |> BeamAgent.start_session()
  end

  @doc "Start a Codex exec session (one-shot JSONL queries)."
  @spec start_exec(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_exec(opts) do
    :codex_exec.start_link(opts_to_map(opts))
  end

  @doc "Start a Codex direct realtime session (native realtime websocket voice/text)."
  @spec start_realtime(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_realtime(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :codex)
    |> Map.put(:transport, :realtime)
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
  @spec query(pid(), binary(), query_params()) :: {:ok, [message()]} | {:error, term()}
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
      |> CodexEx.stream!("Explain OTP")
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

  # ── Thread Management (app-server only) ────────────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_start(session, opts \\ %{}) do
    :codex_app_server.thread_start(session, opts)
  end

  @doc "Resume an existing thread by ID."
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id) do
    :codex_app_server.thread_resume(session, thread_id)
  end

  @spec thread_resume(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id, opts) do
    :codex_app_server.thread_resume(session, thread_id, opts)
  end

  @doc "List all threads."
  @spec thread_list(pid()) :: {:ok, map()} | {:error, term()}
  def thread_list(session) do
    :codex_app_server.thread_list(session)
  end

  @spec thread_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_list(session, opts) do
    :codex_app_server.thread_list(session, opts)
  end

  @doc "List all currently loaded threads."
  @spec thread_loaded_list(pid()) :: {:ok, map()} | {:error, term()}
  def thread_loaded_list(session) do
    :codex_app_server.thread_loaded_list(session)
  end

  @spec thread_loaded_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_loaded_list(session, opts) do
    :codex_app_server.thread_loaded_list(session, opts)
  end

  @doc "Fork an existing thread."
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id) do
    :codex_app_server.thread_fork(session, thread_id)
  end

  @doc "Read a stored thread."
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id) do
    :codex_app_server.thread_read(session, thread_id)
  end

  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id, opts) do
    :codex_app_server.thread_read(session, thread_id, opts)
  end

  @doc "Archive a thread."
  @spec thread_archive(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def thread_archive(session, thread_id) do
    :codex_app_server.thread_archive(session, thread_id)
  end

  @doc "Unsubscribe the current connection from a thread."
  @spec thread_unsubscribe(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_unsubscribe(session, thread_id) do
    :codex_app_server.thread_unsubscribe(session, thread_id)
  end

  @doc "Set a thread display name."
  @spec thread_name_set(pid(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_name_set(session, thread_id, name) do
    :codex_app_server.thread_name_set(session, thread_id, name)
  end

  @doc "Patch stored thread metadata."
  @spec thread_metadata_update(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_metadata_update(session, thread_id, metadata_patch) do
    :codex_app_server.thread_metadata_update(session, thread_id, metadata_patch)
  end

  @doc "Unarchive a thread."
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_unarchive(session, thread_id) do
    :codex_app_server.thread_unarchive(session, thread_id)
  end

  @doc "Rollback a thread."
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_rollback(session, thread_id, opts) do
    :codex_app_server.thread_rollback(session, thread_id, opts)
  end

  @doc "Steer an in-flight turn with additional input."
  @spec turn_steer(pid(), binary(), binary(), binary() | [%{binary() => term()}]) ::
          {:ok, map()} | {:error, term()}
  def turn_steer(session, thread_id, turn_id, input) do
    :codex_app_server.turn_steer(session, thread_id, turn_id, input)
  end

  @spec turn_steer(pid(), binary(), binary(), binary() | [%{binary() => term()}], map()) ::
          {:ok, map()} | {:error, term()}
  def turn_steer(session, thread_id, turn_id, input, opts) do
    :codex_app_server.turn_steer(session, thread_id, turn_id, input, opts)
  end

  @doc "Interrupt an in-flight turn explicitly by thread and turn id."
  @spec turn_interrupt(pid(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def turn_interrupt(session, thread_id, turn_id) do
    :codex_app_server.turn_interrupt(session, thread_id, turn_id)
  end

  @doc "Start a native realtime session for a thread."
  @spec thread_realtime_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_realtime_start(session, opts) do
    :codex_app_server.thread_realtime_start(session, opts)
  end

  @doc "Append an audio chunk to a native realtime thread session."
  @spec thread_realtime_append_audio(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_realtime_append_audio(session, thread_id, opts) do
    :codex_app_server.thread_realtime_append_audio(session, thread_id, opts)
  end

  @doc "Append text to a native realtime thread session."
  @spec thread_realtime_append_text(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_realtime_append_text(session, thread_id, opts) do
    :codex_app_server.thread_realtime_append_text(session, thread_id, opts)
  end

  @doc "Stop a native realtime thread session."
  @spec thread_realtime_stop(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_realtime_stop(session, thread_id) do
    :codex_app_server.thread_realtime_stop(session, thread_id)
  end

  @doc "Start a native review request."
  @spec review_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def review_start(session, opts) do
    :codex_app_server.review_start(session, opts)
  end

  @doc "List native collaboration mode presets."
  @spec collaboration_mode_list(pid()) :: {:ok, map()} | {:error, term()}
  def collaboration_mode_list(session) do
    :codex_app_server.collaboration_mode_list(session)
  end

  @doc "List native experimental feature flags."
  @spec experimental_feature_list(pid()) :: {:ok, map()} | {:error, term()}
  def experimental_feature_list(session) do
    :codex_app_server.experimental_feature_list(session)
  end

  @spec experimental_feature_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def experimental_feature_list(session, opts) do
    :codex_app_server.experimental_feature_list(session, opts)
  end

  @doc "List native skills."
  @spec skills_list(pid()) :: {:ok, map()} | {:error, term()}
  def skills_list(session) do
    :codex_app_server.skills_list(session)
  end

  @spec skills_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def skills_list(session, opts) do
    :codex_app_server.skills_list(session, opts)
  end

  @doc "List native remote skills."
  @spec skills_remote_list(pid()) :: {:ok, map()} | {:error, term()}
  def skills_remote_list(session) do
    :codex_app_server.skills_remote_list(session)
  end

  @spec skills_remote_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def skills_remote_list(session, opts) do
    :codex_app_server.skills_remote_list(session, opts)
  end

  @doc "Export a native remote skill."
  @spec skills_remote_export(pid(), map()) :: {:ok, map()} | {:error, term()}
  def skills_remote_export(session, opts) do
    :codex_app_server.skills_remote_export(session, opts)
  end

  @doc "Enable or disable a native skill by path."
  @spec skills_config_write(pid(), binary(), boolean()) :: {:ok, map()} | {:error, term()}
  def skills_config_write(session, path, enabled) do
    :codex_app_server.skills_config_write(session, path, enabled)
  end

  @doc "List native apps/connectors."
  @spec apps_list(pid()) :: {:ok, map()} | {:error, term()}
  def apps_list(session) do
    :codex_app_server.apps_list(session)
  end

  @spec apps_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def apps_list(session, opts) do
    :codex_app_server.apps_list(session, opts)
  end

  @doc "List native models."
  @spec model_list(pid()) :: {:ok, map()} | {:error, term()}
  def model_list(session) do
    :codex_app_server.model_list(session)
  end

  @spec model_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  def model_list(session, opts) do
    :codex_app_server.model_list(session, opts)
  end

  @doc "Read the effective native config."
  @spec config_read(pid()) :: {:ok, map()} | {:error, term()}
  def config_read(session) do
    :codex_app_server.config_read(session)
  end

  @spec config_read(pid(), map()) :: {:ok, map()} | {:error, term()}
  def config_read(session, opts) do
    :codex_app_server.config_read(session, opts)
  end

  @doc "Write a single native config value."
  @spec config_value_write(pid(), binary(), term()) :: {:ok, map()} | {:error, term()}
  def config_value_write(session, key_path, value) do
    :codex_app_server.config_value_write(session, key_path, value)
  end

  @spec config_value_write(pid(), binary(), term(), map()) :: {:ok, map()} | {:error, term()}
  def config_value_write(session, key_path, value, opts) do
    :codex_app_server.config_value_write(session, key_path, value, opts)
  end

  @doc "Apply a batch of native config edits."
  @spec config_batch_write(pid(), [map()]) :: {:ok, map()} | {:error, term()}
  def config_batch_write(session, edits) do
    :codex_app_server.config_batch_write(session, edits)
  end

  @spec config_batch_write(pid(), [map()], map()) :: {:ok, map()} | {:error, term()}
  def config_batch_write(session, edits, opts) do
    :codex_app_server.config_batch_write(session, edits, opts)
  end

  @doc "Read native config requirements."
  @spec config_requirements_read(pid()) :: {:ok, map()} | {:error, term()}
  def config_requirements_read(session) do
    :codex_app_server.config_requirements_read(session)
  end

  @doc "Detect migratable external agent config artifacts."
  @spec external_agent_config_detect(pid()) :: {:ok, map()} | {:error, term()}
  def external_agent_config_detect(session) do
    :codex_app_server.external_agent_config_detect(session)
  end

  @spec external_agent_config_detect(pid(), map()) :: {:ok, map()} | {:error, term()}
  def external_agent_config_detect(session, opts) do
    :codex_app_server.external_agent_config_detect(session, opts)
  end

  @doc "Import selected external agent config artifacts."
  @spec external_agent_config_import(pid(), map()) :: {:ok, map()} | {:error, term()}
  def external_agent_config_import(session, opts) do
    :codex_app_server.external_agent_config_import(session, opts)
  end

  @doc "Start an MCP server OAuth login flow."
  @spec mcp_server_oauth_login(pid(), map()) :: {:ok, map()} | {:error, term()}
  def mcp_server_oauth_login(session, opts) do
    :codex_app_server.mcp_server_oauth_login(session, opts)
  end

  @doc "Reload native MCP server config from disk."
  @spec mcp_server_reload(pid()) :: {:ok, map()} | {:error, term()}
  def mcp_server_reload(session) do
    :codex_app_server.mcp_server_reload(session)
  end

  @doc "List native MCP server status entries."
  @spec mcp_server_status_list(pid()) :: {:ok, map()} | {:error, term()}
  def mcp_server_status_list(session) do
    :codex_app_server.mcp_server_status_list(session)
  end

  @doc "Start a native account login flow."
  @spec account_login(pid(), map()) :: {:ok, map()} | {:error, term()}
  def account_login(session, opts) do
    :codex_app_server.account_login(session, opts)
  end

  @doc "Cancel a native account login flow."
  @spec account_login_cancel(pid(), map()) :: {:ok, map()} | {:error, term()}
  def account_login_cancel(session, opts) do
    :codex_app_server.account_login_cancel(session, opts)
  end

  @doc "Log out of the native account session."
  @spec account_logout(pid()) :: {:ok, map()} | {:error, term()}
  def account_logout(session) do
    :codex_app_server.account_logout(session)
  end

  @doc "Read native account rate limits."
  @spec account_rate_limits(pid()) :: {:ok, map()} | {:error, term()}
  def account_rate_limits(session) do
    :codex_app_server.account_rate_limits(session)
  end

  @doc "Run a fuzzy file search."
  @spec fuzzy_file_search(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def fuzzy_file_search(session, query) do
    :codex_app_server.fuzzy_file_search(session, query)
  end

  @spec fuzzy_file_search(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def fuzzy_file_search(session, query, opts) do
    :codex_app_server.fuzzy_file_search(session, query, opts)
  end

  @doc "Start a native fuzzy file search session."
  @spec fuzzy_file_search_session_start(pid(), binary(), [term()]) ::
          {:ok, map()} | {:error, term()}
  def fuzzy_file_search_session_start(session, search_session_id, roots) do
    :codex_app_server.fuzzy_file_search_session_start(session, search_session_id, roots)
  end

  @doc "Update a native fuzzy file search session query."
  @spec fuzzy_file_search_session_update(pid(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  def fuzzy_file_search_session_update(session, search_session_id, query) do
    :codex_app_server.fuzzy_file_search_session_update(session, search_session_id, query)
  end

  @doc "Stop a native fuzzy file search session."
  @spec fuzzy_file_search_session_stop(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def fuzzy_file_search_session_stop(session, search_session_id) do
    :codex_app_server.fuzzy_file_search_session_stop(session, search_session_id)
  end

  @doc "Start Windows sandbox setup."
  @spec windows_sandbox_setup_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def windows_sandbox_setup_start(session, opts) do
    :codex_app_server.windows_sandbox_setup_start(session, opts)
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
    BeamAgent.set_model(session, model)
  end

  @doc "Interrupt the current turn."
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    BeamAgent.interrupt(session)
  end

  # ── SDK Hook Constructors ──────────────────────────────────────────

  @doc "Create an SDK lifecycle hook."
  @spec sdk_hook(atom(), hook_callback()) :: hook_def()
  def sdk_hook(event, callback) do
    :beam_agent_hooks_core.hook(event, callback)
  end

  @doc "Create an SDK lifecycle hook with a matcher."
  @spec sdk_hook(atom(), hook_callback(), %{:tool_name => binary()}) :: hook_def()
  def sdk_hook(event, callback, matcher) do
    :beam_agent_hooks_core.hook(event, callback, matcher)
  end

  # ── Supervisor Integration ─────────────────────────────────────────

  @doc """
  Supervisor child specification for a codex_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> opts_to_map()
    |> Map.put(:backend, :codex)
    |> Map.put_new(:transport, :app_server)
    |> BeamAgent.child_spec()
  end

  # ── Content Block Generalization ──────────────────────────────────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Codex) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      CodexEx.normalize_messages(messages)
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
  @spec block_to_message(content_block()) :: flat_message()
  def block_to_message(block), do: :beam_agent_content_core.block_to_message(block)

  @doc "Convert a single flat message into a content_block."
  @spec message_to_block(map()) :: content_block()
  def message_to_block(message), do: :beam_agent_content_core.message_to_block(message)

  # ── Additional Session Control ──────────────────────────────────────

  @doc "Change the permission mode at runtime."
  @spec set_permission_mode(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    BeamAgent.set_permission_mode(session, mode)
  end

  @doc """
  Send a raw control message to the session.

  Low-level interface for sending arbitrary JSON-RPC control messages.
  App-server sessions dispatch normally; exec sessions return
  `{:error, :not_supported}`.
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :gen_statem.call(session, {:send_control, method, params}, 30_000)
  end

  # ── Codex-Specific Operations ───────────────────────────────────────

  @doc """
  Run a command in the Codex sandbox.

  Returns `{:error, :not_supported}` for exec sessions.
  """
  @spec command_run(pid(), binary() | [binary()], map()) :: {:ok, term()} | {:error, term()}
  def command_run(session, command, opts \\ %{}) do
    :codex_app_server.command_run(session, command, opts)
  end

  @doc "Write stdin to a running command execution."
  @spec command_write_stdin(pid(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def command_write_stdin(session, process_id, stdin) do
    :codex_app_server.command_write_stdin(session, process_id, stdin)
  end

  @spec command_write_stdin(pid(), binary(), binary(), map()) ::
          {:ok, map()} | {:error, term()}
  def command_write_stdin(session, process_id, stdin, opts) do
    :codex_app_server.command_write_stdin(session, process_id, stdin, opts)
  end

  @doc """
  Submit a feedback report to the Codex server.
  """
  @spec submit_feedback(pid(), map()) :: {:ok, term()} | {:error, term()}
  def submit_feedback(session, feedback) when is_map(feedback) do
    :codex_app_server.submit_feedback(session, feedback)
  end

  @doc """
  Respond to an agent request (approval, user input, etc.).
  """
  @spec turn_respond(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def turn_respond(session, request_id, params) do
    :codex_app_server.turn_respond(session, request_id, params)
  end

  # ── SDK MCP Server Constructors ─────────────────────────────────────

  @doc "Create an in-process MCP tool definition."
  @spec mcp_tool(binary(), binary(), map(), (map() -> {:ok, [map()]} | {:error, binary()})) ::
          mcp_tool_def()
  def mcp_tool(name, description, input_schema, handler) do
    :beam_agent_tool_registry.tool(name, description, input_schema, handler)
  end

  @doc "Create an in-process MCP server definition."
  @spec mcp_server(binary(), [mcp_tool_def()]) :: mcp_server_def()
  def mcp_server(name, tools) do
    :beam_agent_tool_registry.server(name, tools)
  end

  # ── Supervisor Integration (exec) ───────────────────────────────────

  @doc """
  Supervisor child specification for a codex_exec process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.
  """
  @spec exec_child_spec(keyword() | map()) :: Supervisor.child_spec()
  def exec_child_spec(opts) do
    :codex_app_server.exec_child_spec(opts_to_map(opts))
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

  @doc "Abort the current turn. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session), do: interrupt(session)

  # ── Universal: Session Store (beam_agent_core) ──────────────────────────

  @doc "List all tracked sessions."
  @spec list_sessions() :: {:ok, [session_store_entry()]}
  def list_sessions, do: :codex_app_server.list_sessions()

  @doc "List sessions with filters."
  @spec list_sessions(session_filter_opts()) :: {:ok, [session_store_entry()]}
  def list_sessions(opts) when is_map(opts), do: :codex_app_server.list_sessions(opts)

  @doc "Get messages for a session."
  @spec get_session_messages(binary()) :: {:ok, [message()]} | {:error, :not_found}
  def get_session_messages(session_id), do: :codex_app_server.get_session_messages(session_id)

  @doc "Get messages with options."
  @spec get_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, :not_found}
  def get_session_messages(session_id, opts),
    do: :codex_app_server.get_session_messages(session_id, opts)

  @doc "Get session metadata by ID."
  @spec get_session(binary()) :: {:ok, session_store_entry()} | {:error, :not_found}
  def get_session(session_id), do: :codex_app_server.get_session(session_id)

  @doc "Delete a session and its messages."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: :codex_app_server.delete_session(session_id)

  @doc "Fork a tracked session into a new session ID."
  @spec fork_session(pid(), map()) :: {:ok, session_store_entry()} | {:error, :not_found}
  def fork_session(session, opts), do: :codex_app_server.fork_session(session, opts)

  @doc "Revert the visible session history to a prior boundary."
  @spec revert_session(pid(), map()) ::
          {:ok, session_store_entry()} | {:error, :invalid_selector | :not_found}
  def revert_session(session, selector),
    do: :codex_app_server.revert_session(session, selector)

  @doc "Clear any stored session revert state."
  @spec unrevert_session(pid()) :: {:ok, session_store_entry()} | {:error, :not_found}
  def unrevert_session(session), do: :codex_app_server.unrevert_session(session)

  @doc "Create or replace share state for the current session."
  @spec share_session(pid()) :: {:ok, share_info()} | {:error, :not_found}
  def share_session(session), do: :codex_app_server.share_session(session)

  @spec share_session(pid(), map()) :: {:ok, share_info()} | {:error, :not_found}
  def share_session(session, opts), do: :codex_app_server.share_session(session, opts)

  @doc "Revoke share state for the current session."
  @spec unshare_session(pid()) :: :ok | {:error, :not_found}
  def unshare_session(session), do: :codex_app_server.unshare_session(session)

  @doc "Generate and store a summary for the current session."
  @spec summarize_session(pid()) :: {:ok, summary_info()} | {:error, :not_found}
  def summarize_session(session), do: :codex_app_server.summarize_session(session)

  @spec summarize_session(pid(), map()) :: {:ok, summary_info()} | {:error, :not_found}
  def summarize_session(session, opts),
    do: :codex_app_server.summarize_session(session, opts)

  # ── Universal: MCP Management (beam_agent_core) ─────────────────────────

  @doc "Get status of all MCP servers."
  @spec mcp_server_status(pid()) :: {:ok, %{binary() => map()}}
  def mcp_server_status(session), do: :codex_app_server.mcp_server_status(session)

  @doc "Replace MCP server configurations."
  @spec set_mcp_servers(pid(), [mcp_server_def()]) :: {:ok, map()} | {:error, :not_found}
  def set_mcp_servers(session, servers),
    do: :codex_app_server.set_mcp_servers(session, servers)

  @doc "Reconnect a failed MCP server."
  @spec reconnect_mcp_server(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def reconnect_mcp_server(session, server_name),
    do: :codex_app_server.reconnect_mcp_server(session, server_name)

  @doc "Enable or disable an MCP server."
  @spec toggle_mcp_server(pid(), binary(), boolean()) :: {:ok, map()} | {:error, :not_found}
  def toggle_mcp_server(session, server_name, enabled),
    do: :codex_app_server.toggle_mcp_server(session, server_name, enabled)

  # ── Universal: Init Response Accessors ─────────────────────────────

  @doc "List available slash commands."
  @spec supported_commands(pid()) :: {:ok, list()} | {:error, term()}
  def supported_commands(session), do: :codex_app_server.supported_commands(session)

  @doc "List available models."
  @spec supported_models(pid()) :: {:ok, list()} | {:error, term()}
  def supported_models(session), do: :codex_app_server.supported_models(session)

  @doc "List available agents."
  @spec supported_agents(pid()) :: {:ok, list()} | {:error, term()}
  def supported_agents(session), do: :codex_app_server.supported_agents(session)

  @doc "Get account information."
  @spec account_info(pid()) :: {:ok, map()} | {:error, term()}
  def account_info(session), do: :codex_app_server.account_info(session)

  # ── Universal: Session Control (beam_agent_core) ───────────────────────

  @doc "Set maximum thinking tokens via universal control."
  @spec set_max_thinking_tokens(pid(), pos_integer()) ::
          {:ok, %{:max_thinking_tokens => pos_integer()}}
  def set_max_thinking_tokens(session, max_tokens) do
    :codex_app_server.set_max_thinking_tokens(session, max_tokens)
  end

  @doc "Revert file changes to a checkpoint via universal checkpointing."
  @spec rewind_files(pid(), binary()) ::
          :ok | {:error, :not_found | {:restore_failed, binary(), atom()}}
  def rewind_files(session, checkpoint_uuid) do
    :codex_app_server.rewind_files(session, checkpoint_uuid)
  end

  @doc "Stop a running agent task via universal task tracking."
  @spec stop_task(pid(), binary()) :: :ok | {:error, :not_found}
  def stop_task(session, task_id) do
    :codex_app_server.stop_task(session, task_id)
  end

  @doc "Check server health. Maps to session health for Codex."
  @spec server_health(pid()) :: {:ok, server_health_info()}
  def server_health(session), do: :codex_app_server.server_health(session)

  # ── Todo Extraction ─────────────────────────────────────────────────

  @doc "Extract all TodoWrite items from a list of messages."
  @spec extract_todos([message()]) :: [todo_item()]
  defdelegate extract_todos(messages), to: BeamAgent.Todo

  @doc "Filter todo items by status."
  @spec filter_todos([BeamAgent.Todo.todo_item()], BeamAgent.Todo.todo_status()) ::
          [BeamAgent.Todo.todo_item()]
  defdelegate filter_todos(todos, status), to: BeamAgent.Todo, as: :filter_by_status

  @doc "Get a summary of todo counts by status."
  @spec todo_summary([todo_item()]) :: %{required(:total) => non_neg_integer(), atom() => non_neg_integer()}
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
