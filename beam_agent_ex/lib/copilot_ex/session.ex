defmodule CopilotEx.Session do
  @moduledoc """
  Direct access to the underlying `copilot_session` gen_statem.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or managing the
  send_query/receive_message cycle manually.

  For most use cases, prefer the higher-level `CopilotEx` module.
  """

  @doc """
  Send a query and get a reference for manual message pulling.

  This is the low-level interface. For most use cases, prefer
  `CopilotEx.query/3` or `CopilotEx.stream!/3`.
  """
  @spec send_query(pid(), binary(), map(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :copilot_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def receive_message(session, ref, timeout \\ 120_000) do
    :copilot_session.receive_message(session, ref, timeout)
  end

  @doc """
  Send a control protocol message.

  Uses Copilot's JSON-RPC 2.0 protocol to send arbitrary methods
  to the CLI subprocess.

  ## Examples

      {:ok, response} = CopilotEx.Session.send_control(session, "config.get", %{})
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :copilot_session.send_control(session, method, params)
  end

  @doc """
  Interrupt a running query.

  The CLI subprocess receives a cancellation notification and the
  consumer will receive `{:error, :interrupted}` on the next
  `receive_message` call.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :copilot_session.interrupt(session)
  end

  @doc """
  Query session info (adapter, session_id, model, etc.).
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :copilot_session.session_info(session)
  end

  @doc """
  Change the model at runtime during a session.
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :copilot_session.set_model(session, model)
  end
end
