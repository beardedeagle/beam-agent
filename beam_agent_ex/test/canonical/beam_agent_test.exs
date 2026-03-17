defmodule BeamAgentTest do
  use ExUnit.Case, async: true

  @domain_modules [
    BeamAgent,
    BeamAgent.Capabilities,
    BeamAgent.Context,
    BeamAgent.Runtime,
    BeamAgent.Catalog,
    BeamAgent.Control,
    BeamAgent.Command,
    BeamAgent.MCP,
    BeamAgent.Skills,
    BeamAgent.Apps,
    BeamAgent.Config,
    BeamAgent.File,
    BeamAgent.Journal,
    BeamAgent.Memory,
    BeamAgent.Provider,
    BeamAgent.Routines,
    BeamAgent.Routing,
    BeamAgent.Account,
    BeamAgent.Artifacts,
    BeamAgent.Search,
    BeamAgent.Runs,
    BeamAgent.Checkpoint,
    BeamAgent.SessionStore,
    BeamAgent.Threads
  ]

  setup_all do
    Enum.each(@domain_modules, &Code.ensure_loaded!/1)
    :ok
  end

  # ---------------------------------------------------------------------------
  # BeamAgent lifecycle core (functions that remain on the root module)
  # ---------------------------------------------------------------------------

  test "delegates backend registry to canonical erlang module" do
    assert BeamAgent.list_backends() == [:claude, :codex, :gemini, :opencode, :copilot]
  end

  test "command wrapper executes a minimal shell command" do
    assert {:ok, %{exit_code: 0, output: output}} =
             BeamAgent.Command.run(portable_echo_segments("beam-agent-smoke"))

    assert trim_output(output) == "beam-agent-smoke"
  end

  test "runtime wrapper round-trips provider state" do
    session = "runtime-smoke-#{System.unique_integer([:positive])}"

    assert {:error, :not_set} = BeamAgent.Runtime.current_provider(session)
    assert :ok = BeamAgent.Runtime.set_provider(session, "openai")
    assert {:ok, "openai"} = BeamAgent.Runtime.current_provider(session)
    assert :ok = BeamAgent.Runtime.clear_provider(session)
    assert {:error, :not_set} = BeamAgent.Runtime.current_provider(session)
  end

  test "context wrapper exports budget estimation" do
    assert function_exported?(BeamAgent.Context, :context_status, 1)
    assert function_exported?(BeamAgent.Context, :budget_estimate, 1)
    assert function_exported?(BeamAgent.Context, :compact_now, 2)
    assert function_exported?(BeamAgent.Context, :maybe_compact, 2)
  end

  test "routines wrapper exports durable scheduled execution" do
    assert function_exported?(BeamAgent.Routines, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Routines, :clear, 0)
    assert function_exported?(BeamAgent.Routines, :create, 1)
    assert function_exported?(BeamAgent.Routines, :update, 2)
    assert function_exported?(BeamAgent.Routines, :cancel, 1)
    assert function_exported?(BeamAgent.Routines, :get, 1)
    assert function_exported?(BeamAgent.Routines, :list, 0)
    assert function_exported?(BeamAgent.Routines, :list, 1)
    assert function_exported?(BeamAgent.Routines, :due, 0)
    assert function_exported?(BeamAgent.Routines, :due, 1)
    assert function_exported?(BeamAgent.Routines, :next_due_at, 0)
    assert function_exported?(BeamAgent.Routines, :run_now, 1)
    assert function_exported?(BeamAgent.Routines, :run_due, 0)
    assert function_exported?(BeamAgent.Routines, :run_due, 1)
  end

  test "routing wrapper chooses the preferred backend" do
    assert {:ok, decision} =
             BeamAgent.Routing.select_backend(%{
               policy: :preferred_then_fallback,
               preferred_backends: [:gemini, :codex]
             })

    assert decision.backend == :gemini
  end

  test "provider wrapper accepts session identity binaries for universal flows" do
    session = "provider-wrapper-#{System.unique_integer([:positive])}"

    assert {:error, :not_set} = BeamAgent.Provider.current(session)
    assert :ok = BeamAgent.Provider.set(session, "openai")
    assert {:ok, "openai"} = BeamAgent.Provider.current(session)

    assert {:ok, pending_result} =
             BeamAgent.Provider.oauth_authorize(session, "openai", %{
               authorize_url: "https://example.test/oauth"
             })

    request_id = pending_result[:request_id] || pending_result["request_id"]

    assert {:ok, callback_result} =
             BeamAgent.Provider.oauth_callback(session, "openai", %{
               request_id: request_id,
               code: "authorized"
             })

    assert (callback_result[:status] || callback_result["status"]) == :configured
    assert {:ok, provider_config} = BeamAgent.Runtime.get_provider_config(session)

    oauth_callback =
      Map.get(provider_config, :oauth_callback) || Map.get(provider_config, "oauth_callback")

    assert is_map(oauth_callback)
    assert (oauth_callback[:code] || oauth_callback["code"]) == :redacted
    assert {:ok, providers} = BeamAgent.Provider.list(session)
    assert Enum.any?(providers, &((Map.get(&1, :id) || Map.get(&1, "id")) == "openai"))
  end

  test "provider wrapper round-trips provider state with binary session ids" do
    session = "provider-smoke-#{System.unique_integer([:positive])}"

    assert {:error, :not_set} = BeamAgent.Provider.current(session)
    assert :ok = BeamAgent.Provider.set(session, "openai")
    assert {:ok, "openai"} = BeamAgent.Provider.current(session)
    assert {:ok, providers} = BeamAgent.Provider.list(session)
    assert Enum.any?(providers, &(&1[:id] == "openai" or &1["id"] == "openai"))
    assert :ok = BeamAgent.Provider.clear(session)
    assert {:error, :not_set} = BeamAgent.Provider.current(session)
  end

  test "session store remains available on canonical root" do
    assert {:ok, sessions} = BeamAgent.list_sessions()
    assert is_list(sessions)
  end

  test "exports session lifecycle functions on the canonical root" do
    assert function_exported?(BeamAgent, :init, 0)
    assert function_exported?(BeamAgent, :init, 1)
    assert function_exported?(BeamAgent, :start_session, 1)
    assert function_exported?(BeamAgent, :child_spec, 1)
    assert function_exported?(BeamAgent, :stop, 1)
    assert function_exported?(BeamAgent, :query, 2)
    assert function_exported?(BeamAgent, :query, 3)
    assert function_exported?(BeamAgent, :session_info, 1)
    assert function_exported?(BeamAgent, :health, 1)
    assert function_exported?(BeamAgent, :backend, 1)
    assert function_exported?(BeamAgent, :list_backends, 0)
  end

  test "exports event subscription and event streaming on the canonical root" do
    assert function_exported?(BeamAgent, :event_subscribe, 1)
    assert function_exported?(BeamAgent, :receive_event, 2)
    assert function_exported?(BeamAgent, :receive_event, 3)
    assert function_exported?(BeamAgent, :event_unsubscribe, 2)
    assert function_exported?(BeamAgent, :event_stream!, 1)
    assert function_exported?(BeamAgent, :event_stream!, 2)
    assert function_exported?(BeamAgent, :event_stream, 1)
    assert function_exported?(BeamAgent, :event_stream, 2)
  end

  test "exports streaming convenience functions on the canonical root" do
    assert function_exported?(BeamAgent, :stream!, 2)
    assert function_exported?(BeamAgent, :stream!, 3)
    assert function_exported?(BeamAgent, :stream, 2)
    assert function_exported?(BeamAgent, :stream, 3)
  end

  test "exports utility functions on the canonical root" do
    assert function_exported?(BeamAgent, :normalize_message, 1)
    assert function_exported?(BeamAgent, :make_request_id, 0)
    assert function_exported?(BeamAgent, :parse_stop_reason, 1)
    assert function_exported?(BeamAgent, :parse_permission_mode, 1)
    assert function_exported?(BeamAgent, :collect_messages, 4)
    assert function_exported?(BeamAgent, :collect_messages, 5)
  end

  test "exports session store operations on the canonical root" do
    assert function_exported?(BeamAgent, :list_sessions, 0)
    assert function_exported?(BeamAgent, :list_sessions, 1)
    assert function_exported?(BeamAgent, :get_session_messages, 1)
    assert function_exported?(BeamAgent, :get_session_messages, 2)
    assert function_exported?(BeamAgent, :get_session, 1)
    assert function_exported?(BeamAgent, :delete_session, 1)
    assert function_exported?(BeamAgent, :fork_session, 2)
    assert function_exported?(BeamAgent, :revert_session, 2)
    assert function_exported?(BeamAgent, :unrevert_session, 1)
    assert function_exported?(BeamAgent, :share_session, 1)
    assert function_exported?(BeamAgent, :share_session, 2)
    assert function_exported?(BeamAgent, :unshare_session, 1)
    assert function_exported?(BeamAgent, :summarize_session, 1)
    assert function_exported?(BeamAgent, :summarize_session, 2)
    assert function_exported?(BeamAgent, :list_native_sessions, 0)
    assert function_exported?(BeamAgent, :list_native_sessions, 1)
    assert function_exported?(BeamAgent, :get_native_session_messages, 1)
    assert function_exported?(BeamAgent, :get_native_session_messages, 2)
  end

  test "exports thread operations on the canonical root" do
    assert function_exported?(BeamAgent, :thread_start, 2)
    assert function_exported?(BeamAgent, :thread_resume, 2)
    assert function_exported?(BeamAgent, :thread_resume, 3)
    assert function_exported?(BeamAgent, :thread_list, 1)
    assert function_exported?(BeamAgent, :thread_list, 2)
    assert function_exported?(BeamAgent, :thread_fork, 2)
    assert function_exported?(BeamAgent, :thread_fork, 3)
    assert function_exported?(BeamAgent, :thread_read, 2)
    assert function_exported?(BeamAgent, :thread_read, 3)
    assert function_exported?(BeamAgent, :thread_archive, 2)
    assert function_exported?(BeamAgent, :thread_unarchive, 2)
    assert function_exported?(BeamAgent, :thread_rollback, 3)
    assert function_exported?(BeamAgent, :thread_unsubscribe, 2)
    assert function_exported?(BeamAgent, :thread_name_set, 3)
    assert function_exported?(BeamAgent, :thread_metadata_update, 3)
    assert function_exported?(BeamAgent, :thread_loaded_list, 1)
    assert function_exported?(BeamAgent, :thread_loaded_list, 2)
    assert function_exported?(BeamAgent, :thread_compact, 2)
  end

  # ---------------------------------------------------------------------------
  # Domain module export tests (functions moved to focused submodules)
  # ---------------------------------------------------------------------------

  test "Capabilities module exposes capability metadata and queries" do
    {:ok, caps} = BeamAgent.Capabilities.capabilities(:codex)
    session_history = Enum.find(caps, &(&1.id == :session_history))
    assert session_history.support_level == :full

    assert session_history.implementation in [
             :direct_backend,
             :universal,
             :direct_backend_and_universal
           ]

    assert session_history.fidelity in [:exact, :validated_equivalent]

    assert function_exported?(BeamAgent.Capabilities, :capabilities, 0)
    assert function_exported?(BeamAgent.Capabilities, :capabilities, 1)
    assert function_exported?(BeamAgent.Capabilities, :supports, 2)
  end

  test "Runtime module exports session control functions" do
    assert function_exported?(BeamAgent.Runtime, :get_state, 1)
    assert function_exported?(BeamAgent.Runtime, :current_provider, 1)
    assert function_exported?(BeamAgent.Runtime, :set_provider, 2)
    assert function_exported?(BeamAgent.Runtime, :clear_provider, 1)
    assert function_exported?(BeamAgent.Runtime, :set_model, 2)
    assert function_exported?(BeamAgent.Runtime, :set_permission_mode, 2)
    assert function_exported?(BeamAgent.Runtime, :interrupt, 1)
    assert function_exported?(BeamAgent.Runtime, :abort, 1)
    assert function_exported?(BeamAgent.Runtime, :send_control, 3)
    assert function_exported?(BeamAgent.Runtime, :get_status, 1)
    assert function_exported?(BeamAgent.Runtime, :get_auth_status, 1)
    assert function_exported?(BeamAgent.Runtime, :get_last_session_id, 1)
    assert function_exported?(BeamAgent.Runtime, :set_max_thinking_tokens, 2)
    assert function_exported?(BeamAgent.Runtime, :stop_task, 2)
    assert function_exported?(BeamAgent.Runtime, :windows_sandbox_setup_start, 2)
  end

  test "Catalog module exports listing and lookup functions" do
    assert function_exported?(BeamAgent.Catalog, :list_tools, 1)
    assert function_exported?(BeamAgent.Catalog, :list_skills, 1)
    assert function_exported?(BeamAgent.Catalog, :list_plugins, 1)
    assert function_exported?(BeamAgent.Catalog, :list_mcp_servers, 1)
    assert function_exported?(BeamAgent.Catalog, :list_agents, 1)
    assert function_exported?(BeamAgent.Catalog, :get_tool, 2)
    assert function_exported?(BeamAgent.Catalog, :get_skill, 2)
    assert function_exported?(BeamAgent.Catalog, :get_plugin, 2)
    assert function_exported?(BeamAgent.Catalog, :get_agent, 2)
    assert function_exported?(BeamAgent.Catalog, :supported_commands, 1)
    assert function_exported?(BeamAgent.Catalog, :supported_models, 1)
    assert function_exported?(BeamAgent.Catalog, :supported_agents, 1)
    assert function_exported?(BeamAgent.Catalog, :model_list, 1)
    assert function_exported?(BeamAgent.Catalog, :model_list, 2)
    assert function_exported?(BeamAgent.Catalog, :list_commands, 1)
  end

  test "Runs module exposes run and step lifecycle functions" do
    assert function_exported?(BeamAgent.Runs, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Runs, :clear, 0)
    assert function_exported?(BeamAgent.Runs, :start_run, 2)
    assert function_exported?(BeamAgent.Runs, :get_run, 1)
    assert function_exported?(BeamAgent.Runs, :list_runs, 0)
    assert function_exported?(BeamAgent.Runs, :list_runs, 1)
    assert function_exported?(BeamAgent.Runs, :complete_run, 2)
    assert function_exported?(BeamAgent.Runs, :fail_run, 2)
    assert function_exported?(BeamAgent.Runs, :cancel_run, 2)
    assert function_exported?(BeamAgent.Runs, :start_step, 2)
    assert function_exported?(BeamAgent.Runs, :get_step, 2)
    assert function_exported?(BeamAgent.Runs, :list_steps, 1)
    assert function_exported?(BeamAgent.Runs, :complete_step, 3)
    assert function_exported?(BeamAgent.Runs, :fail_step, 3)
    assert function_exported?(BeamAgent.Runs, :cancel_step, 3)
  end

  test "Artifacts module exposes typed artifact storage functions" do
    assert function_exported?(BeamAgent.Artifacts, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Artifacts, :clear, 0)
    assert function_exported?(BeamAgent.Artifacts, :put, 1)
    assert function_exported?(BeamAgent.Artifacts, :put, 2)
    assert function_exported?(BeamAgent.Artifacts, :get, 1)
    assert function_exported?(BeamAgent.Artifacts, :list, 0)
    assert function_exported?(BeamAgent.Artifacts, :list, 1)
    assert function_exported?(BeamAgent.Artifacts, :search, 1)
    assert function_exported?(BeamAgent.Artifacts, :search, 2)
    assert function_exported?(BeamAgent.Artifacts, :attach, 3)
    assert function_exported?(BeamAgent.Artifacts, :delete, 1)
  end

  test "Journal module exposes durable journal functions" do
    assert function_exported?(BeamAgent.Journal, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Journal, :clear, 0)
    assert function_exported?(BeamAgent.Journal, :append, 2)
    assert function_exported?(BeamAgent.Journal, :list, 0)
    assert function_exported?(BeamAgent.Journal, :list, 1)
    assert function_exported?(BeamAgent.Journal, :stream_from, 1)
    assert function_exported?(BeamAgent.Journal, :stream_from, 2)
    assert function_exported?(BeamAgent.Journal, :get, 1)
    assert function_exported?(BeamAgent.Journal, :ack, 2)
  end

  test "Memory module exposes long-term memory functions" do
    assert function_exported?(BeamAgent.Memory, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Memory, :clear, 0)
    assert function_exported?(BeamAgent.Memory, :remember, 2)
    assert function_exported?(BeamAgent.Memory, :remember, 3)
    assert function_exported?(BeamAgent.Memory, :get, 1)
    assert function_exported?(BeamAgent.Memory, :list, 0)
    assert function_exported?(BeamAgent.Memory, :list, 1)
    assert function_exported?(BeamAgent.Memory, :recall, 2)
    assert function_exported?(BeamAgent.Memory, :search, 1)
    assert function_exported?(BeamAgent.Memory, :search, 2)
    assert function_exported?(BeamAgent.Memory, :forget, 1)
    assert function_exported?(BeamAgent.Memory, :pin, 1)
    assert function_exported?(BeamAgent.Memory, :unpin, 1)
    assert function_exported?(BeamAgent.Memory, :expire, 0)
    assert function_exported?(BeamAgent.Memory, :expire, 1)
  end

  test "Control module exports turn steering and collaboration functions" do
    assert function_exported?(BeamAgent.Control, :turn_steer, 4)
    assert function_exported?(BeamAgent.Control, :turn_steer, 5)
    assert function_exported?(BeamAgent.Control, :turn_interrupt, 3)
    assert function_exported?(BeamAgent.Control, :thread_realtime_start, 2)
    assert function_exported?(BeamAgent.Control, :thread_realtime_append_audio, 3)
    assert function_exported?(BeamAgent.Control, :thread_realtime_append_text, 3)
    assert function_exported?(BeamAgent.Control, :thread_realtime_stop, 2)
    assert function_exported?(BeamAgent.Control, :review_start, 2)
    assert function_exported?(BeamAgent.Control, :collaboration_mode_list, 1)
    assert function_exported?(BeamAgent.Control, :experimental_feature_list, 1)
    assert function_exported?(BeamAgent.Control, :experimental_feature_list, 2)
    assert function_exported?(BeamAgent.Control, :list_server_sessions, 1)
    assert function_exported?(BeamAgent.Control, :get_server_session, 2)
    assert function_exported?(BeamAgent.Control, :delete_server_session, 2)
    assert function_exported?(BeamAgent.Control, :list_server_agents, 1)
    assert function_exported?(BeamAgent.Control, :server_health, 1)
  end

  test "Command module exports command execution functions" do
    assert function_exported?(BeamAgent.Command, :run, 1)
    assert function_exported?(BeamAgent.Command, :run, 2)
    assert function_exported?(BeamAgent.Command, :session_init, 2)
    assert function_exported?(BeamAgent.Command, :session_messages, 1)
    assert function_exported?(BeamAgent.Command, :session_messages, 2)
    assert function_exported?(BeamAgent.Command, :prompt_async, 2)
    assert function_exported?(BeamAgent.Command, :prompt_async, 3)
    assert function_exported?(BeamAgent.Command, :shell_command, 2)
    assert function_exported?(BeamAgent.Command, :shell_command, 3)
    assert function_exported?(BeamAgent.Command, :tui_append_prompt, 2)
    assert function_exported?(BeamAgent.Command, :tui_open_help, 1)
    assert function_exported?(BeamAgent.Command, :session_destroy, 1)
    assert function_exported?(BeamAgent.Command, :session_destroy, 2)
    assert function_exported?(BeamAgent.Command, :command_run, 2)
    assert function_exported?(BeamAgent.Command, :command_run, 3)
    assert function_exported?(BeamAgent.Command, :command_write_stdin, 3)
    assert function_exported?(BeamAgent.Command, :command_write_stdin, 4)
    assert function_exported?(BeamAgent.Command, :submit_feedback, 2)
    assert function_exported?(BeamAgent.Command, :turn_respond, 3)
    assert function_exported?(BeamAgent.Command, :send_command, 3)
  end

  test "MCP module exports server management functions" do
    # Registry-scoped
    assert function_exported?(BeamAgent.MCP, :register_server, 2)
    assert function_exported?(BeamAgent.MCP, :unregister_server, 2)
    assert function_exported?(BeamAgent.MCP, :tool, 4)
    assert function_exported?(BeamAgent.MCP, :server_status, 1)
    assert function_exported?(BeamAgent.MCP, :set_servers, 2)
    assert function_exported?(BeamAgent.MCP, :reconnect_server, 2)
    assert function_exported?(BeamAgent.MCP, :toggle_server, 3)
    assert function_exported?(BeamAgent.MCP, :server_names, 1)
    assert function_exported?(BeamAgent.MCP, :server, 2)
    assert function_exported?(BeamAgent.MCP, :server, 3)
    # Session-scoped (non-conflicting names)
    assert function_exported?(BeamAgent.MCP, :status, 1)
    assert function_exported?(BeamAgent.MCP, :status_list, 1)
    assert function_exported?(BeamAgent.MCP, :add_server, 2)
    assert function_exported?(BeamAgent.MCP, :server_oauth_login, 2)
    assert function_exported?(BeamAgent.MCP, :server_reload, 1)
    # Session-scoped (prefixed to avoid arity conflicts)
    assert function_exported?(BeamAgent.MCP, :session_server_status, 1)
    assert function_exported?(BeamAgent.MCP, :session_set_servers, 2)
    assert function_exported?(BeamAgent.MCP, :session_reconnect_server, 2)
    assert function_exported?(BeamAgent.MCP, :session_toggle_server, 3)
  end

  test "Skills module exports skill management functions" do
    assert function_exported?(BeamAgent.Skills, :list, 1)
    assert function_exported?(BeamAgent.Skills, :list, 2)
    assert function_exported?(BeamAgent.Skills, :remote_list, 1)
    assert function_exported?(BeamAgent.Skills, :remote_list, 2)
    assert function_exported?(BeamAgent.Skills, :remote_export, 2)
    assert function_exported?(BeamAgent.Skills, :config_write, 3)
  end

  test "Apps module exports project management functions" do
    assert function_exported?(BeamAgent.Apps, :list, 1)
    assert function_exported?(BeamAgent.Apps, :list, 2)
    assert function_exported?(BeamAgent.Apps, :info, 1)
    assert function_exported?(BeamAgent.Apps, :init, 1)
    assert function_exported?(BeamAgent.Apps, :log, 2)
    assert function_exported?(BeamAgent.Apps, :modes, 1)
  end

  test "Config module exports configuration functions" do
    assert function_exported?(BeamAgent.Config, :read, 1)
    assert function_exported?(BeamAgent.Config, :read, 2)
    assert function_exported?(BeamAgent.Config, :update, 2)
    assert function_exported?(BeamAgent.Config, :providers, 1)
    assert function_exported?(BeamAgent.Config, :value_write, 3)
    assert function_exported?(BeamAgent.Config, :value_write, 4)
    assert function_exported?(BeamAgent.Config, :batch_write, 2)
    assert function_exported?(BeamAgent.Config, :batch_write, 3)
    assert function_exported?(BeamAgent.Config, :requirements_read, 1)
    assert function_exported?(BeamAgent.Config, :external_agent_detect, 1)
    assert function_exported?(BeamAgent.Config, :external_agent_detect, 2)
    assert function_exported?(BeamAgent.Config, :external_agent_import, 2)
  end

  test "File module exports file operation functions" do
    assert function_exported?(BeamAgent.File, :find_text, 2)
    assert function_exported?(BeamAgent.File, :find_files, 2)
    assert function_exported?(BeamAgent.File, :find_symbols, 2)
    assert function_exported?(BeamAgent.File, :list, 2)
    assert function_exported?(BeamAgent.File, :read, 2)
    assert function_exported?(BeamAgent.File, :status, 1)
  end

  test "Provider module exports provider management functions" do
    assert function_exported?(BeamAgent.Provider, :current, 1)
    assert function_exported?(BeamAgent.Provider, :set, 2)
    assert function_exported?(BeamAgent.Provider, :clear, 1)
    assert function_exported?(BeamAgent.Provider, :current_agent, 1)
    assert function_exported?(BeamAgent.Provider, :set_agent, 2)
    assert function_exported?(BeamAgent.Provider, :clear_agent, 1)
    assert function_exported?(BeamAgent.Provider, :list, 1)
    assert function_exported?(BeamAgent.Provider, :auth_methods, 1)
    assert function_exported?(BeamAgent.Provider, :oauth_authorize, 3)
    assert function_exported?(BeamAgent.Provider, :oauth_callback, 3)
  end

  test "Account module exports authentication functions" do
    assert function_exported?(BeamAgent.Account, :info, 1)
    assert function_exported?(BeamAgent.Account, :login, 2)
    assert function_exported?(BeamAgent.Account, :cancel, 2)
    assert function_exported?(BeamAgent.Account, :logout, 1)
    assert function_exported?(BeamAgent.Account, :rate_limits, 1)
  end

  test "Search module exports fuzzy file search functions" do
    assert function_exported?(BeamAgent.Search, :fuzzy, 2)
    assert function_exported?(BeamAgent.Search, :fuzzy, 3)
    assert function_exported?(BeamAgent.Search, :session_start, 3)
    assert function_exported?(BeamAgent.Search, :session_update, 3)
    assert function_exported?(BeamAgent.Search, :session_stop, 2)
  end

  test "Checkpoint module exports file rewind function" do
    assert function_exported?(BeamAgent.Checkpoint, :rewind_files, 2)
  end

  test "SessionStore module exports session persistence functions" do
    assert function_exported?(BeamAgent.SessionStore, :list_sessions, 0)
    assert function_exported?(BeamAgent.SessionStore, :list_sessions, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_session_messages, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_session_messages, 2)
    assert function_exported?(BeamAgent.SessionStore, :get_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :delete_session, 1)
    assert function_exported?(BeamAgent.SessionStore, :list_native_sessions, 0)
    assert function_exported?(BeamAgent.SessionStore, :list_native_sessions, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_native_session_messages, 1)
    assert function_exported?(BeamAgent.SessionStore, :get_native_session_messages, 2)
  end

  test "Threads module exports thread lifecycle functions" do
    assert function_exported?(BeamAgent.Threads, :thread_start, 2)
    assert function_exported?(BeamAgent.Threads, :thread_resume, 2)
    assert function_exported?(BeamAgent.Threads, :thread_resume, 3)
    assert function_exported?(BeamAgent.Threads, :thread_list, 1)
    assert function_exported?(BeamAgent.Threads, :thread_list, 2)
    assert function_exported?(BeamAgent.Threads, :thread_fork, 2)
    assert function_exported?(BeamAgent.Threads, :thread_fork, 3)
    assert function_exported?(BeamAgent.Threads, :thread_read, 2)
    assert function_exported?(BeamAgent.Threads, :thread_read, 3)
    assert function_exported?(BeamAgent.Threads, :thread_archive, 2)
    assert function_exported?(BeamAgent.Threads, :thread_unarchive, 2)
    assert function_exported?(BeamAgent.Threads, :thread_rollback, 3)
    assert function_exported?(BeamAgent.Threads, :thread_unsubscribe, 2)
    assert function_exported?(BeamAgent.Threads, :thread_name_set, 3)
    assert function_exported?(BeamAgent.Threads, :thread_metadata_update, 3)
    assert function_exported?(BeamAgent.Threads, :thread_loaded_list, 1)
    assert function_exported?(BeamAgent.Threads, :thread_loaded_list, 2)
    assert function_exported?(BeamAgent.Threads, :thread_compact, 2)
  end

  defp trim_output(output) when is_binary(output) do
    String.trim_trailing(output)
  end

  defp portable_echo_segments(text) when is_binary(text) do
    ["erl", "-noshell", "-eval", "io:put_chars(#{inspect(text)}), halt()."]
  end
end
