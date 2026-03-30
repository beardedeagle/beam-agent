defmodule BeamAgent.ContentTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Content)
    :ok
  end

  test "exports the canonical content surface" do
    assert function_exported?(BeamAgent.Content, :parse_blocks, 1)
    assert function_exported?(BeamAgent.Content, :block_to_message, 1)
    assert function_exported?(BeamAgent.Content, :message_to_block, 1)
    assert function_exported?(BeamAgent.Content, :flatten_assistant, 1)
    assert function_exported?(BeamAgent.Content, :messages_to_blocks, 1)
    assert function_exported?(BeamAgent.Content, :normalize_messages, 1)
  end
end
