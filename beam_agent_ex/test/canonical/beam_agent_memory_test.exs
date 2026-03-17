defmodule BeamAgent.MemoryTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Memory)
    :ok
  end

  test "exports the canonical memory surface" do
    assert function_exported?(BeamAgent.Memory, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Memory, :clear, 0)
    assert function_exported?(BeamAgent.Memory, :remember, 2)
    assert function_exported?(BeamAgent.Memory, :remember, 3)
    assert function_exported?(BeamAgent.Memory, :get, 1)
    assert function_exported?(BeamAgent.Memory, :list, 0)
    assert function_exported?(BeamAgent.Memory, :list, 1)
    assert function_exported?(BeamAgent.Memory, :recall, 2)
    assert function_exported?(BeamAgent.Memory, :search, 1)
    assert function_exported?(BeamAgent.Memory, :search, 2)
    assert function_exported?(BeamAgent.Memory, :forget, 1)
    assert function_exported?(BeamAgent.Memory, :pin, 1)
    assert function_exported?(BeamAgent.Memory, :unpin, 1)
    assert function_exported?(BeamAgent.Memory, :expire, 0)
    assert function_exported?(BeamAgent.Memory, :expire, 1)
  end

  test "stores, recalls, and expires memories through the Elixir wrapper" do
    session = "beam-agent-memory-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, memory} =
             BeamAgent.Memory.remember(session, %{
               kind: :note,
               content: "remember the safer deploy path",
               attributes: %{topic: "release"},
               ttl: 0,
               salience: 10
             })

    assert {:ok, []} = BeamAgent.Memory.list(%{session_id: session})
    assert {:ok, [expired]} = BeamAgent.Memory.list(%{session_id: session, include_expired: true})
    assert expired.memory_id == memory.memory_id

    assert :ok = BeamAgent.Memory.pin(memory.memory_id)
    assert {:ok, [match]} = BeamAgent.Memory.recall(session, "safer deploy")
    assert match.memory_id == memory.memory_id

    assert :ok = BeamAgent.Memory.unpin(memory.memory_id)
    assert {:ok, 1} = BeamAgent.Memory.expire(%{session_id: session})
    assert {:error, :not_found} = BeamAgent.Memory.get(memory.memory_id)
  end
end
