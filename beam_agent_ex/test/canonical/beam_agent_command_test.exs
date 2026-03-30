defmodule BeamAgent.CommandTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Command)
    :ok
  end

  test "exports the standalone command surface" do
    assert function_exported?(BeamAgent.Command, :run, 1)
    assert function_exported?(BeamAgent.Command, :run, 2)
  end

  test "exports the session-scoped command surface" do
    assert function_exported?(BeamAgent.Command, :session_init, 2)
    assert function_exported?(BeamAgent.Command, :session_messages, 1)
    assert function_exported?(BeamAgent.Command, :session_messages, 2)
    assert function_exported?(BeamAgent.Command, :prompt_async, 2)
    assert function_exported?(BeamAgent.Command, :prompt_async, 3)
    assert function_exported?(BeamAgent.Command, :shell_command, 2)
    assert function_exported?(BeamAgent.Command, :shell_command, 3)
    assert function_exported?(BeamAgent.Command, :tui_append_prompt, 2)
    assert function_exported?(BeamAgent.Command, :tui_open_help, 1)
    assert function_exported?(BeamAgent.Command, :session_destroy, 1)
    assert function_exported?(BeamAgent.Command, :session_destroy, 2)
    assert function_exported?(BeamAgent.Command, :command_run, 2)
    assert function_exported?(BeamAgent.Command, :command_run, 3)
    assert function_exported?(BeamAgent.Command, :command_write_stdin, 3)
    assert function_exported?(BeamAgent.Command, :command_write_stdin, 4)
    assert function_exported?(BeamAgent.Command, :submit_feedback, 2)
    assert function_exported?(BeamAgent.Command, :turn_respond, 3)
    assert function_exported?(BeamAgent.Command, :send_command, 3)
  end
end
