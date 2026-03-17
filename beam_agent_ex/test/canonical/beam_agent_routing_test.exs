defmodule BeamAgent.RoutingTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Routing)
    :ok
  end

  test "exports the canonical routing surface" do
    assert function_exported?(BeamAgent.Routing, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Routing, :clear, 0)
    assert function_exported?(BeamAgent.Routing, :select_backend, 1)
    assert function_exported?(BeamAgent.Routing, :select_backend, 2)
  end

  test "selects backends and reuses sticky affinity through the Elixir wrapper" do
    assert :ok = BeamAgent.Routing.clear()

    assert {:ok, first} =
             BeamAgent.Routing.select_backend(%{
               policy: :sticky,
               affinity_key: "beam-agent-routing-wrapper",
               preferred_backends: [:claude, :codex]
             })

    assert {:ok, second} =
             BeamAgent.Routing.select_backend(%{
               policy: :sticky,
               affinity_key: "beam-agent-routing-wrapper",
               preferred_backends: [:codex, :claude]
             })

    assert first.backend == second.backend
    assert second.affinity_key == "beam-agent-routing-wrapper"
  end
end
