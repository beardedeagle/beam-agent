defmodule OpencodeEx.Session do
  @moduledoc """
  Direct access to the underlying `opencode_session` gen_statem.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or managing the
  send_query/receive_message cycle manually.

  For most use cases, prefer the higher-level `OpencodeEx` module.
  """

  @doc """
  Send a query and get a reference for manual message pulling.

  This is the low-level interface. For most use cases, prefer
  `OpencodeEx.query/3` or `OpencodeEx.stream!/3`.
  """
  @spec send_query(pid(), binary(), map(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :opencode_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def receive_message(session, ref, timeout \\ 120_000) do
    :opencode_session.receive_message(session, ref, timeout)
  end

  @doc """
  Send a control protocol message.

  ## Examples

      {:ok, response} = OpencodeEx.Session.send_control(session, "ping", %{})
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :opencode_session.send_control(session, method, params)
  end

  @doc """
  Interrupt a running query.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :opencode_session.interrupt(session)
  end

  @doc """
  Query session info.
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :opencode_session.session_info(session)
  end

  @doc """
  Change the model at runtime.
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :opencode_session.set_model(session, model)
  end

  @doc """
  Change the permission mode at runtime.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    :opencode_session.set_permission_mode(session, mode)
  end
end
