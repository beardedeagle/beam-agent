defmodule OpencodeEx.Session do
  @moduledoc """
  Direct access to the underlying `opencode_session` gen_statem.

  Use this module when you need fine-grained control over the session
  lifecycle, such as sending control messages or managing the
  send_query/receive_message cycle manually.

  For most use cases, prefer the higher-level `OpencodeEx` module.
  """

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
           required(:content_blocks) => [map()],
           required(:duration_api_ms) => non_neg_integer(),
           required(:duration_ms) => non_neg_integer(),
           required(:error_info) => map(),
           required(:errors) => [binary()],
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

  @doc """
  Send a query and get a reference for manual message pulling.

  This is the low-level interface. For most use cases, prefer
  `OpencodeEx.query/3` or `OpencodeEx.stream!/3`.
  """
  @spec send_query(pid(), binary(), query_opts(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def send_query(session, prompt, params \\ %{}, timeout \\ 120_000) do
    :opencode_session.send_query(session, prompt, params, timeout)
  end

  @doc """
  Pull the next message from an active query (demand-driven).
  """
  @spec receive_message(pid(), reference(), timeout()) ::
          {:ok, message_map()} | {:error, term()}
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
