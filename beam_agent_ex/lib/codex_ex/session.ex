defmodule CodexEx.Session do
  @moduledoc """
  Direct access to the underlying Codex gen_statem modules.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or managing the
  receive_message/send_query cycle manually.

  For most use cases, prefer the higher-level `CodexEx` module.
  """

  @doc """
  Send a control protocol message (app-server only).

  ## Examples

      {:ok, response} = CodexEx.Session.send_control(session, "thread/list", %{})
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :codex_session.send_control(session, method, params)
  end

  @doc """
  Interrupt a running turn.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :codex_session.interrupt(session)
  end

  @doc """
  Send a query and get a reference for manual message pulling.
  """
  @spec send_query(pid(), binary(), map(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :codex_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def receive_message(session, ref, timeout \\ 120_000) do
    :codex_session.receive_message(session, ref, timeout)
  end

  @doc """
  Query session info.
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :codex_session.session_info(session)
  end

  @doc """
  Change the model at runtime.
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :codex_session.set_model(session, model)
  end

  @doc """
  Change the approval policy at runtime.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    :codex_session.set_permission_mode(session, mode)
  end
end
