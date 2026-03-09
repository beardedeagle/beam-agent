defmodule GeminiEx.Session do
  @moduledoc """
  Direct access to the underlying `gemini_cli_session` gen_statem.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or managing the
  send_query/receive_message cycle manually.

  For most use cases, prefer the higher-level `GeminiEx` module.
  """

  @doc """
  Send a query and get a reference for manual message pulling.

  This is the low-level interface. For most use cases, prefer
  `GeminiEx.query/3` or `GeminiEx.stream!/3`.
  """
  @spec send_query(pid(), binary(), map(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :gemini_cli_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def receive_message(session, ref, timeout \\ 120_000) do
    :gemini_cli_session.receive_message(session, ref, timeout)
  end

  @doc """
  Send a low-level control protocol message directly to `gemini_cli_session`.

  The persistent Gemini ACP implementation exposes the supported runtime
  controls through `GeminiEx.set_model/2`, `GeminiEx.set_permission_mode/2`,
  and `GeminiEx.send_control/3` on the higher-level client wrapper. The
  underlying session callback remains a narrow escape hatch and returns
  `{:error, :not_supported}` for generic control methods.
  """
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :gemini_cli_session.send_control(session, method, params)
  end

  @doc """
  Interrupt a running query.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :gemini_cli_session.interrupt(session)
  end

  @doc """
  Query session info.
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :gemini_cli_session.session_info(session)
  end

  @doc """
  Change the model at runtime.
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :gemini_cli_session.set_model(session, model)
  end

  @doc """
  Change the permission mode at runtime.
  """
  @spec set_permission_mode(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) do
    :gemini_cli_session.set_permission_mode(session, mode)
  end
end
