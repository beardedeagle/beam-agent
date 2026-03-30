defmodule BeamAgent.FileTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.File)
    :ok
  end

  test "exports the canonical file surface" do
    assert function_exported?(BeamAgent.File, :find_text, 2)
    assert function_exported?(BeamAgent.File, :find_files, 2)
    assert function_exported?(BeamAgent.File, :find_symbols, 2)
    assert function_exported?(BeamAgent.File, :list, 2)
    assert function_exported?(BeamAgent.File, :read, 2)
    assert function_exported?(BeamAgent.File, :status, 1)
  end
end
