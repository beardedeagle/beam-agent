defmodule BeamAgent.SessionStore do
  @moduledoc "Unified session history store helpers for the canonical `BeamAgent` package."

  defdelegate list_sessions(), to: :beam_agent_session_store
  defdelegate list_sessions(opts), to: :beam_agent_session_store
  defdelegate get_session(session_id), to: :beam_agent_session_store
  defdelegate delete_session(session_id), to: :beam_agent_session_store
  defdelegate fork_session(session_or_id, opts), to: :beam_agent
  defdelegate revert_session(session_or_id, selector), to: :beam_agent
  defdelegate unrevert_session(session_or_id), to: :beam_agent
  defdelegate share_session(session_or_id), to: :beam_agent
  defdelegate share_session(session_or_id, opts), to: :beam_agent
  defdelegate unshare_session(session_or_id), to: :beam_agent
  defdelegate summarize_session(session_or_id), to: :beam_agent
  defdelegate summarize_session(session_or_id, opts), to: :beam_agent
  defdelegate get_session_messages(session_id), to: :beam_agent_session_store
  defdelegate get_session_messages(session_id, opts), to: :beam_agent_session_store
end
