defmodule BeamAgent.Checkpoint do
  @moduledoc "Checkpoint and rewind helpers for the canonical `BeamAgent` package."

  defdelegate snapshot(session_id, uuid, file_paths), to: :beam_agent_checkpoint
  defdelegate rewind(session_id, uuid), to: :beam_agent_checkpoint
  defdelegate list_checkpoints(session_id), to: :beam_agent_checkpoint
  defdelegate get_checkpoint(session_id, uuid), to: :beam_agent_checkpoint
  defdelegate delete_checkpoint(session_id, uuid), to: :beam_agent_checkpoint
  defdelegate extract_file_paths(tool_name, tool_input), to: :beam_agent_checkpoint
end
