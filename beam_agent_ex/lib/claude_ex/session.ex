defmodule ClaudeEx.Session do
  @moduledoc """
  Direct access to the underlying `claude_agent_session` gen_statem.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or interrupting queries.
  For most use cases, prefer the higher-level `ClaudeEx` module.

  ## Control Protocol

  The Claude Code CLI uses a `control_request`/`control_response` protocol
  for session management and tool approval. Inbound control requests from
  the CLI (e.g., `can_use_tool`) are auto-approved by the session unless
  a custom `permission_handler` is provided via session opts.
  Use `send_control/3` to send custom control requests to the CLI.
  """

  @doc """
  Send a control protocol message (e.g., for session management).

  Uses the `control_request`/`control_response` protocol.
  Works in both `:ready` and `:active_query` states.

  ## Examples

      {:ok, response} = ClaudeEx.Session.send_control(session, "ping", %{})
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :claude_agent_session.send_control(session, method, params)
  end

  @doc """
  Interrupt a running query. The consumer will receive
  `{:error, :interrupted}` on the next `receive_message` call.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :claude_agent_session.interrupt(session)
  end

  @doc """
  Cancel an active query, discarding any buffered messages.
  """
  @spec cancel(pid(), reference()) :: :ok
  def cancel(session, ref) do
    :claude_agent_session.cancel(session, ref)
  end

  @doc """
  Send a query and get a reference for manual message pulling.

  This is the low-level interface. For most use cases, prefer
  `ClaudeEx.query/3` or `ClaudeEx.stream!/3`.
  """
  @spec send_query(pid(), binary(), map(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :claude_agent_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, ClaudeEx.message()} | {:error, term()}
  def receive_message(session, ref, timeout \\ 120_000) do
    :claude_agent_session.receive_message(session, ref, timeout)
  end

  @doc """
  Query session capabilities and initialization data.

  Delegates to `ClaudeEx.session_info/1`. Available in all states.
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :claude_agent_session.session_info(session)
  end

  @doc """
  Change the model at runtime during a session.
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :claude_agent_session.set_model(session, model)
  end

  @doc """
  Change the permission mode at runtime.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    :claude_agent_session.set_permission_mode(session, mode)
  end

  @doc """
  Revert file changes to a checkpoint.
  """
  @spec rewind_files(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def rewind_files(session, checkpoint_uuid) do
    :claude_agent_session.rewind_files(session, checkpoint_uuid)
  end

  @doc """
  Stop a running agent task by task ID.
  """
  @spec stop_task(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def stop_task(session, task_id) do
    :claude_agent_session.stop_task(session, task_id)
  end

  @doc """
  Set the maximum thinking tokens at runtime.
  """
  @spec set_max_thinking_tokens(pid(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def set_max_thinking_tokens(session, max_tokens)
      when is_integer(max_tokens) and max_tokens > 0 do
    :claude_agent_session.set_max_thinking_tokens(session, max_tokens)
  end

  @doc """
  Query MCP server health and status.
  """
  @spec mcp_server_status(pid()) :: {:ok, term()} | {:error, term()}
  def mcp_server_status(session) do
    :claude_agent_session.mcp_server_status(session)
  end

  @doc """
  Dynamically add or replace MCP server configurations.
  """
  @spec set_mcp_servers(pid(), map()) :: {:ok, term()} | {:error, term()}
  def set_mcp_servers(session, servers) do
    :claude_agent_session.set_mcp_servers(session, servers)
  end

  @doc """
  Reconnect a failed MCP server by name.
  """
  @spec reconnect_mcp_server(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def reconnect_mcp_server(session, server_name) do
    :claude_agent_session.reconnect_mcp_server(session, server_name)
  end

  @doc """
  Enable or disable an MCP server at runtime.
  """
  @spec toggle_mcp_server(pid(), binary(), boolean()) :: {:ok, term()} | {:error, term()}
  def toggle_mcp_server(session, server_name, enabled) do
    :claude_agent_session.toggle_mcp_server(session, server_name, enabled)
  end
end
