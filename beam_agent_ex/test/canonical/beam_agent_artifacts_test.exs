defmodule BeamAgent.ArtifactsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Artifacts)
    :ok
  end

  test "exports the canonical artifacts surface" do
    assert function_exported?(BeamAgent.Artifacts, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Artifacts, :clear, 0)
    assert function_exported?(BeamAgent.Artifacts, :put, 1)
    assert function_exported?(BeamAgent.Artifacts, :put, 2)
    assert function_exported?(BeamAgent.Artifacts, :get, 1)
    assert function_exported?(BeamAgent.Artifacts, :list, 0)
    assert function_exported?(BeamAgent.Artifacts, :list, 1)
    assert function_exported?(BeamAgent.Artifacts, :search, 1)
    assert function_exported?(BeamAgent.Artifacts, :search, 2)
    assert function_exported?(BeamAgent.Artifacts, :attach, 3)
    assert function_exported?(BeamAgent.Artifacts, :delete, 1)
  end

  test "stores, links, and searches artifacts through the Elixir wrapper" do
    session = "beam-agent-artifacts-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, run} = BeamAgent.Runs.start_run(session, %{kind: :workflow})

    assert {:ok, artifact} =
             BeamAgent.Artifacts.put(%{
               run_id: run.run_id,
               kind: :plan,
               title: "Artifact Plan",
               body: "implement the artifact store",
               format: :markdown
             })

    assert :ok = BeamAgent.Artifacts.attach(artifact.artifact_id, :message, "msg-1")
    assert {:ok, [match]} = BeamAgent.Artifacts.search("artifact implement")
    assert match.artifact_id == artifact.artifact_id

    assert {:ok, stored} = BeamAgent.Artifacts.get(artifact.artifact_id)
    assert stored.run_id == run.run_id
    assert stored.session_id == session
  end
end
