defmodule BeamAgentTest do
  use ExUnit.Case, async: true

  setup_all do
    assert Code.ensure_loaded?(BeamAgent)
    :ok
  end

  test "delegates backend registry to canonical erlang module" do
    assert BeamAgent.list_backends() == [:claude, :codex, :gemini, :opencode, :copilot]
  end

  test "exposes richer capability metadata" do
    {:ok, caps} = BeamAgent.capabilities(:codex)
    session_history = Enum.find(caps, &(&1.id == :session_history))
    assert session_history.support_level == :full

    assert session_history.implementation in [
             :direct_backend,
             :universal,
             :direct_backend_and_universal
           ]

    assert session_history.fidelity in [:exact, :validated_equivalent]
  end

  test "session store remains available on canonical root" do
    :beam_agent_session_store_core.clear()
    assert {:ok, []} = BeamAgent.list_sessions()
  end

  test "exports codex fuzzy file search session lifecycle on the canonical root" do
    assert function_exported?(BeamAgent, :fuzzy_file_search_session_start, 3)
    assert function_exported?(BeamAgent, :fuzzy_file_search_session_update, 3)
    assert function_exported?(BeamAgent, :fuzzy_file_search_session_stop, 2)
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

  test "exports Claude native control coverage on the canonical root" do
    assert function_exported?(BeamAgent, :rewind_files, 2)
    assert function_exported?(BeamAgent, :stop_task, 2)
    assert function_exported?(BeamAgent, :set_max_thinking_tokens, 2)
    assert function_exported?(BeamAgent, :mcp_server_status, 1)
    assert function_exported?(BeamAgent, :set_mcp_servers, 2)
    assert function_exported?(BeamAgent, :reconnect_mcp_server, 2)
    assert function_exported?(BeamAgent, :toggle_mcp_server, 3)
    assert function_exported?(BeamAgent, :list_native_sessions, 0)
    assert function_exported?(BeamAgent, :list_native_sessions, 1)
    assert function_exported?(BeamAgent, :get_native_session_messages, 1)
    assert function_exported?(BeamAgent, :get_native_session_messages, 2)
  end

  test "exports Codex native control, realtime, and admin surfaces on the canonical root" do
    assert function_exported?(BeamAgent, :thread_unsubscribe, 2)
    assert function_exported?(BeamAgent, :thread_name_set, 3)
    assert function_exported?(BeamAgent, :thread_metadata_update, 3)
    assert function_exported?(BeamAgent, :turn_steer, 4)
    assert function_exported?(BeamAgent, :turn_steer, 5)
    assert function_exported?(BeamAgent, :turn_interrupt, 3)
    assert function_exported?(BeamAgent, :thread_realtime_start, 2)
    assert function_exported?(BeamAgent, :thread_realtime_append_audio, 3)
    assert function_exported?(BeamAgent, :thread_realtime_append_text, 3)
    assert function_exported?(BeamAgent, :thread_realtime_stop, 2)
    assert function_exported?(BeamAgent, :review_start, 2)
    assert function_exported?(BeamAgent, :collaboration_mode_list, 1)
    assert function_exported?(BeamAgent, :experimental_feature_list, 1)
    assert function_exported?(BeamAgent, :skills_remote_list, 1)
    assert function_exported?(BeamAgent, :skills_remote_export, 2)
    assert function_exported?(BeamAgent, :apps_list, 1)
    assert function_exported?(BeamAgent, :config_requirements_read, 1)
    assert function_exported?(BeamAgent, :external_agent_config_detect, 1)
    assert function_exported?(BeamAgent, :external_agent_config_import, 2)
    assert function_exported?(BeamAgent, :mcp_server_oauth_login, 2)
    assert function_exported?(BeamAgent, :command_write_stdin, 3)
    assert function_exported?(BeamAgent, :command_write_stdin, 4)
    assert function_exported?(BeamAgent, :submit_feedback, 2)
    assert function_exported?(BeamAgent, :turn_respond, 3)
  end

  test "exports OpenCode and Copilot native operations on the canonical root" do
    assert function_exported?(BeamAgent, :app_info, 1)
    assert function_exported?(BeamAgent, :app_init, 1)
    assert function_exported?(BeamAgent, :app_log, 2)
    assert function_exported?(BeamAgent, :app_modes, 1)
    assert function_exported?(BeamAgent, :find_text, 2)
    assert function_exported?(BeamAgent, :find_files, 2)
    assert function_exported?(BeamAgent, :find_symbols, 2)
    assert function_exported?(BeamAgent, :file_list, 2)
    assert function_exported?(BeamAgent, :file_read, 2)
    assert function_exported?(BeamAgent, :file_status, 1)
    assert function_exported?(BeamAgent, :session_init, 2)
    assert function_exported?(BeamAgent, :session_messages, 1)
    assert function_exported?(BeamAgent, :session_messages, 2)
    assert function_exported?(BeamAgent, :prompt_async, 2)
    assert function_exported?(BeamAgent, :prompt_async, 3)
    assert function_exported?(BeamAgent, :shell_command, 2)
    assert function_exported?(BeamAgent, :shell_command, 3)
    assert function_exported?(BeamAgent, :tui_append_prompt, 2)
    assert function_exported?(BeamAgent, :tui_open_help, 1)
    assert function_exported?(BeamAgent, :get_status, 1)
    assert function_exported?(BeamAgent, :get_auth_status, 1)
    assert function_exported?(BeamAgent, :model_list, 1)
    assert function_exported?(BeamAgent, :get_last_session_id, 1)
    assert function_exported?(BeamAgent, :list_server_sessions, 1)
    assert function_exported?(BeamAgent, :get_server_session, 2)
    assert function_exported?(BeamAgent, :delete_server_session, 2)
    assert function_exported?(BeamAgent, :session_destroy, 1)
    assert function_exported?(BeamAgent, :session_destroy, 2)
  end
end
