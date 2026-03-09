defmodule BeamAgent.Content do
  @moduledoc "Content-block conversion helpers for the canonical `BeamAgent` package."

  defdelegate parse_blocks(blocks), to: :beam_agent_content
  defdelegate block_to_message(block), to: :beam_agent_content
  defdelegate message_to_block(message), to: :beam_agent_content
  defdelegate flatten_assistant(message), to: :beam_agent_content
  defdelegate messages_to_blocks(messages), to: :beam_agent_content
  defdelegate normalize_messages(messages), to: :beam_agent_content
end
