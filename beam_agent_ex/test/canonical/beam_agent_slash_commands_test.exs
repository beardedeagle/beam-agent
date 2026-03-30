defmodule BeamAgent.SlashCommandsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.SlashCommands)
    :ok
  end

  test "exports the canonical slash commands surface" do
    assert function_exported?(BeamAgent.SlashCommands, :ensure_table, 0)
    assert function_exported?(BeamAgent.SlashCommands, :register, 2)
    assert function_exported?(BeamAgent.SlashCommands, :unregister, 1)
    assert function_exported?(BeamAgent.SlashCommands, :get, 1)
    assert function_exported?(BeamAgent.SlashCommands, :list, 0)
    assert function_exported?(BeamAgent.SlashCommands, :clear, 0)
  end
end
