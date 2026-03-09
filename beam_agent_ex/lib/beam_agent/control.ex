defmodule BeamAgent.Control do
  @moduledoc "Control and callback state helpers for the canonical `BeamAgent` package."

  defdelegate dispatch(session_id, method, params), to: :beam_agent_control
  defdelegate get_config(session_id, key), to: :beam_agent_control
  defdelegate set_config(session_id, key, value), to: :beam_agent_control
  defdelegate get_all_config(session_id), to: :beam_agent_control
  defdelegate clear_config(session_id), to: :beam_agent_control
  defdelegate set_permission_mode(session_id, mode), to: :beam_agent_control
  defdelegate get_permission_mode(session_id), to: :beam_agent_control
  defdelegate set_max_thinking_tokens(session_id, tokens), to: :beam_agent_control
  defdelegate get_max_thinking_tokens(session_id), to: :beam_agent_control
  defdelegate register_task(session_id, task_id, pid), to: :beam_agent_control
  defdelegate unregister_task(session_id, task_id), to: :beam_agent_control
  defdelegate stop_task(session_id, task_id), to: :beam_agent_control
  defdelegate list_tasks(session_id), to: :beam_agent_control
  defdelegate submit_feedback(session_id, feedback), to: :beam_agent_control
  defdelegate get_feedback(session_id), to: :beam_agent_control
  defdelegate clear_feedback(session_id), to: :beam_agent_control
  defdelegate store_pending_request(session_id, request_id, request), to: :beam_agent_control
  defdelegate resolve_pending_request(session_id, request_id, response), to: :beam_agent_control
  defdelegate get_pending_response(session_id, request_id), to: :beam_agent_control
  defdelegate list_pending_requests(session_id), to: :beam_agent_control
end
