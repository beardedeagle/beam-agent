defmodule BeamAgent do
  @moduledoc """
  Canonical Elixir wrapper for the consolidated `beam_agent` SDK.

  `BeamAgent` is the intended package-level entrypoint. All user-visible
  features — threads, turns, skills, apps, files, MCP, accounts, fuzzy search,
  and more — are available here with universal fallbacks across all five
  backends (Claude, Codex, Gemini, OpenCode, Copilot).

  Backend-specific wrappers (`ClaudeEx`, `CodexEx`, `GeminiEx`, `OpencodeEx`,
  `CopilotEx`) remain available for backend-native flows. `BeamAgent.Raw`
  exposes only low-level transport/debug escape hatches.
  """

  @type backend :: :beam_agent.backend()
  @type message_type :: :beam_agent.message_type()
  @type stop_reason :: :beam_agent.stop_reason()
  @type permission_mode :: :beam_agent.permission_mode()
  @type message :: :beam_agent.message()
  @type permission_result :: :beam_agent.permission_result()
  @type receive_fun :: :beam_agent.receive_fun()
  @type terminal_pred :: :beam_agent.terminal_pred()

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
          :status => :active | :revoked,
          :revoked_at => integer()
        }

  @type summary_info_map :: %{
          :content => binary(),
          :generated_at => integer(),
          :generated_by => binary(),
          :message_count => non_neg_integer(),
          :session_id => binary()
        }

  defdelegate start_session(opts), to: :beam_agent
  defdelegate child_spec(opts), to: :beam_agent
  defdelegate stop(session), to: :beam_agent
  defdelegate query(session, prompt), to: :beam_agent
  defdelegate query(session, prompt, params), to: :beam_agent
  defdelegate event_subscribe(session), to: :beam_agent
  defdelegate receive_event(session, ref), to: :beam_agent
  defdelegate receive_event(session, ref, timeout), to: :beam_agent
  defdelegate event_unsubscribe(session, ref), to: :beam_agent
  defdelegate session_info(session), to: :beam_agent
  defdelegate health(session), to: :beam_agent
  defdelegate backend(session), to: :beam_agent
  defdelegate list_backends(), to: :beam_agent
  defdelegate set_model(session, model), to: :beam_agent
  defdelegate set_permission_mode(session, mode), to: :beam_agent
  defdelegate interrupt(session), to: :beam_agent
  defdelegate abort(session), to: :beam_agent
  defdelegate send_control(session, method, params), to: :beam_agent
  defdelegate supported_commands(session), to: :beam_agent
  defdelegate supported_models(session), to: :beam_agent
  defdelegate supported_agents(session), to: :beam_agent
  defdelegate account_info(session), to: :beam_agent
  defdelegate list_tools(session), to: :beam_agent
  defdelegate list_skills(session), to: :beam_agent
  defdelegate list_plugins(session), to: :beam_agent
  defdelegate list_mcp_servers(session), to: :beam_agent
  defdelegate list_agents(session), to: :beam_agent
  defdelegate get_tool(session, tool_id), to: :beam_agent
  defdelegate get_skill(session, skill_id), to: :beam_agent
  defdelegate get_plugin(session, plugin_id), to: :beam_agent
  defdelegate get_agent(session, agent_id), to: :beam_agent
  defdelegate current_provider(session), to: :beam_agent
  defdelegate set_provider(session, provider_id), to: :beam_agent
  defdelegate clear_provider(session), to: :beam_agent
  defdelegate current_agent(session), to: :beam_agent
  defdelegate set_agent(session, agent_id), to: :beam_agent
  defdelegate clear_agent(session), to: :beam_agent
  defdelegate capabilities(), to: :beam_agent
  defdelegate capabilities(value), to: :beam_agent
  defdelegate supports(capability, value), to: :beam_agent
  defdelegate normalize_message(raw), to: :beam_agent
  defdelegate make_request_id(), to: :beam_agent
  defdelegate parse_stop_reason(reason), to: :beam_agent
  defdelegate parse_permission_mode(mode), to: :beam_agent
  defdelegate collect_messages(session, ref, deadline, receive_fun), to: :beam_agent

  defdelegate collect_messages(session, ref, deadline, receive_fun, terminal_pred),
    to: :beam_agent

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

  @spec list_sessions() :: {:ok, [session_info_map()]}
  def list_sessions, do: BeamAgent.SessionStore.list_sessions()

  @spec list_sessions(map()) :: {:ok, [session_info_map()]}
  def list_sessions(opts) when is_map(opts), do: BeamAgent.SessionStore.list_sessions(opts)

  defdelegate list_native_sessions(), to: :beam_agent
  defdelegate list_native_sessions(opts), to: :beam_agent

  @spec get_session_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id),
    do: BeamAgent.SessionStore.get_session_messages(session_id)

  @spec get_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id, opts) when is_map(opts) do
    BeamAgent.SessionStore.get_session_messages(session_id, opts)
  end

  defdelegate get_native_session_messages(session_id), to: :beam_agent
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent

  @spec get_session(binary()) :: {:ok, session_info_map()} | {:error, :not_found}
  def get_session(session_id), do: BeamAgent.SessionStore.get_session(session_id)

  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: BeamAgent.SessionStore.delete_session(session_id)

  @spec fork_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def fork_session(session_or_id, opts),
    do: BeamAgent.SessionStore.fork_session(session_or_id, opts)

  @spec revert_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def revert_session(session_or_id, selector),
    do: BeamAgent.SessionStore.revert_session(session_or_id, selector)

  @spec unrevert_session(pid()) :: {:ok, session_info_map()} | {:error, term()}
  def unrevert_session(session_or_id), do: BeamAgent.SessionStore.unrevert_session(session_or_id)

  @spec share_session(pid()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id), do: BeamAgent.SessionStore.share_session(session_or_id)

  @spec share_session(pid(), map()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id, opts),
    do: BeamAgent.SessionStore.share_session(session_or_id, opts)

  @spec unshare_session(pid()) :: :ok | {:error, term()}
  def unshare_session(session_or_id), do: BeamAgent.SessionStore.unshare_session(session_or_id)

  @spec summarize_session(pid()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id),
    do: BeamAgent.SessionStore.summarize_session(session_or_id)

  @spec summarize_session(pid(), map()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id, opts),
    do: BeamAgent.SessionStore.summarize_session(session_or_id, opts)

  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_start(session, opts), do: BeamAgent.Threads.thread_start(session, opts)

  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id), do: BeamAgent.Threads.thread_resume(session, thread_id)

  defdelegate thread_resume(session, thread_id, opts), to: :beam_agent

  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, term()}
  def thread_list(session), do: BeamAgent.Threads.thread_list(session)

  defdelegate thread_list(session, opts), to: :beam_agent

  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id), do: BeamAgent.Threads.thread_fork(session, thread_id)

  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id, opts),
    do: BeamAgent.Threads.thread_fork(session, thread_id, opts)

  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id), do: BeamAgent.Threads.thread_read(session, thread_id)

  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id, opts),
    do: BeamAgent.Threads.thread_read(session, thread_id, opts)

  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_archive(session, thread_id), do: BeamAgent.Threads.thread_archive(session, thread_id)

  defdelegate thread_unsubscribe(session, thread_id), to: :beam_agent
  defdelegate thread_name_set(session, thread_id, name), to: :beam_agent
  defdelegate thread_metadata_update(session, thread_id, metadata_patch), to: :beam_agent

  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_unarchive(session, thread_id),
    do: BeamAgent.Threads.thread_unarchive(session, thread_id)

  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_rollback(session, thread_id, selector),
    do: BeamAgent.Threads.thread_rollback(session, thread_id, selector)

  defdelegate thread_loaded_list(session), to: :beam_agent
  defdelegate thread_loaded_list(session, opts), to: :beam_agent
  defdelegate thread_compact(session, opts), to: :beam_agent
  defdelegate turn_steer(session, thread_id, turn_id, input), to: :beam_agent
  defdelegate turn_steer(session, thread_id, turn_id, input, opts), to: :beam_agent
  defdelegate turn_interrupt(session, thread_id, turn_id), to: :beam_agent
  defdelegate thread_realtime_start(session, opts), to: :beam_agent
  defdelegate thread_realtime_append_audio(session, thread_id, opts), to: :beam_agent
  defdelegate thread_realtime_append_text(session, thread_id, opts), to: :beam_agent
  defdelegate thread_realtime_stop(session, thread_id), to: :beam_agent
  defdelegate review_start(session, opts), to: :beam_agent
  defdelegate collaboration_mode_list(session), to: :beam_agent
  defdelegate experimental_feature_list(session), to: :beam_agent
  defdelegate experimental_feature_list(session, opts), to: :beam_agent
  defdelegate skills_list(session), to: :beam_agent
  defdelegate skills_list(session, opts), to: :beam_agent
  defdelegate skills_remote_list(session), to: :beam_agent
  defdelegate skills_remote_list(session, opts), to: :beam_agent
  defdelegate skills_remote_export(session, opts), to: :beam_agent
  defdelegate skills_config_write(session, path, enabled), to: :beam_agent
  defdelegate apps_list(session), to: :beam_agent
  defdelegate apps_list(session, opts), to: :beam_agent
  defdelegate app_info(session), to: :beam_agent
  defdelegate app_init(session), to: :beam_agent
  defdelegate app_log(session, body), to: :beam_agent
  defdelegate app_modes(session), to: :beam_agent
  defdelegate model_list(session), to: :beam_agent
  defdelegate model_list(session, opts), to: :beam_agent
  defdelegate get_status(session), to: :beam_agent
  defdelegate get_auth_status(session), to: :beam_agent
  defdelegate get_last_session_id(session), to: :beam_agent
  defdelegate list_server_sessions(session), to: :beam_agent
  defdelegate get_server_session(session, session_id), to: :beam_agent
  defdelegate delete_server_session(session, session_id), to: :beam_agent
  defdelegate list_server_agents(session), to: :beam_agent
  defdelegate list_commands(session), to: :beam_agent
  defdelegate config_read(session), to: :beam_agent
  defdelegate config_read(session, opts), to: :beam_agent
  defdelegate config_update(session, body), to: :beam_agent
  defdelegate config_providers(session), to: :beam_agent
  defdelegate find_text(session, pattern), to: :beam_agent
  defdelegate find_files(session, opts), to: :beam_agent
  defdelegate find_symbols(session, query), to: :beam_agent
  defdelegate file_list(session, path), to: :beam_agent
  defdelegate file_read(session, path), to: :beam_agent
  defdelegate file_status(session), to: :beam_agent
  defdelegate config_value_write(session, key_path, value), to: :beam_agent
  defdelegate config_value_write(session, key_path, value, opts), to: :beam_agent
  defdelegate config_batch_write(session, edits), to: :beam_agent
  defdelegate config_batch_write(session, edits, opts), to: :beam_agent
  defdelegate config_requirements_read(session), to: :beam_agent
  defdelegate external_agent_config_detect(session), to: :beam_agent
  defdelegate external_agent_config_detect(session, opts), to: :beam_agent
  defdelegate external_agent_config_import(session, opts), to: :beam_agent
  defdelegate provider_list(session), to: :beam_agent
  defdelegate provider_auth_methods(session), to: :beam_agent
  defdelegate provider_oauth_authorize(session, provider_id, body), to: :beam_agent
  defdelegate provider_oauth_callback(session, provider_id, body), to: :beam_agent
  defdelegate mcp_status(session), to: :beam_agent
  defdelegate add_mcp_server(session, body), to: :beam_agent
  defdelegate mcp_server_status(session), to: :beam_agent
  defdelegate set_mcp_servers(session, servers), to: :beam_agent
  defdelegate reconnect_mcp_server(session, server_name), to: :beam_agent
  defdelegate toggle_mcp_server(session, server_name, enabled), to: :beam_agent
  defdelegate mcp_server_oauth_login(session, opts), to: :beam_agent
  defdelegate mcp_server_reload(session), to: :beam_agent
  defdelegate mcp_server_status_list(session), to: :beam_agent
  defdelegate account_login(session, opts), to: :beam_agent
  defdelegate account_login_cancel(session, opts), to: :beam_agent
  defdelegate account_logout(session), to: :beam_agent
  defdelegate account_rate_limits(session), to: :beam_agent
  defdelegate fuzzy_file_search(session, query), to: :beam_agent
  defdelegate fuzzy_file_search(session, query, opts), to: :beam_agent
  defdelegate fuzzy_file_search_session_start(session, search_session_id, roots), to: :beam_agent
  defdelegate fuzzy_file_search_session_update(session, search_session_id, query), to: :beam_agent
  defdelegate fuzzy_file_search_session_stop(session, search_session_id), to: :beam_agent
  defdelegate windows_sandbox_setup_start(session, opts), to: :beam_agent
  defdelegate set_max_thinking_tokens(session, max_tokens), to: :beam_agent
  defdelegate rewind_files(session, checkpoint_uuid), to: :beam_agent
  defdelegate stop_task(session, task_id), to: :beam_agent
  defdelegate session_init(session, opts), to: :beam_agent
  defdelegate session_messages(session), to: :beam_agent
  defdelegate session_messages(session, opts), to: :beam_agent
  defdelegate prompt_async(session, prompt), to: :beam_agent
  defdelegate prompt_async(session, prompt, opts), to: :beam_agent
  defdelegate shell_command(session, command), to: :beam_agent
  defdelegate shell_command(session, command, opts), to: :beam_agent
  defdelegate tui_append_prompt(session, text), to: :beam_agent
  defdelegate tui_open_help(session), to: :beam_agent
  defdelegate session_destroy(session), to: :beam_agent
  defdelegate session_destroy(session, session_id), to: :beam_agent
  defdelegate command_run(session, command), to: :beam_agent
  defdelegate command_run(session, command, opts), to: :beam_agent
  defdelegate command_write_stdin(session, process_id, stdin), to: :beam_agent
  defdelegate command_write_stdin(session, process_id, stdin, opts), to: :beam_agent
  defdelegate submit_feedback(session, feedback), to: :beam_agent
  defdelegate turn_respond(session, request_id, params), to: :beam_agent
  defdelegate send_command(session, command, params), to: :beam_agent
  defdelegate server_health(session), to: :beam_agent

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

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts
end
