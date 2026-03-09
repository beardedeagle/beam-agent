defmodule BeamAgent.Threads do
  @moduledoc "Unified thread lifecycle helpers for the canonical `BeamAgent` package."

  defdelegate thread_start(session, opts), to: :beam_agent
  defdelegate thread_resume(session, thread_id), to: :beam_agent
  defdelegate thread_list(session), to: :beam_agent
  defdelegate thread_fork(session, thread_id), to: :beam_agent
  defdelegate thread_fork(session, thread_id, opts), to: :beam_agent
  defdelegate thread_read(session, thread_id), to: :beam_agent
  defdelegate thread_read(session, thread_id, opts), to: :beam_agent
  defdelegate thread_archive(session, thread_id), to: :beam_agent
  defdelegate thread_unarchive(session, thread_id), to: :beam_agent
  defdelegate thread_rollback(session, thread_id, selector), to: :beam_agent
end
