defmodule BeamAgent.CheckpointTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Checkpoint)
    :ok
  end

  test "exports the canonical checkpoint surface" do
    assert function_exported?(BeamAgent.Checkpoint, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Checkpoint, :clear, 0)
    assert function_exported?(BeamAgent.Checkpoint, :snapshot, 3)
    assert function_exported?(BeamAgent.Checkpoint, :rewind, 2)
    assert function_exported?(BeamAgent.Checkpoint, :list_checkpoints, 1)
    assert function_exported?(BeamAgent.Checkpoint, :get_checkpoint, 2)
    assert function_exported?(BeamAgent.Checkpoint, :delete_checkpoint, 2)
    assert function_exported?(BeamAgent.Checkpoint, :extract_file_paths, 2)
    assert function_exported?(BeamAgent.Checkpoint, :rewind_files, 2)
  end

  test "snapshot, list, and nil normalization smoke test" do
    :ok = BeamAgent.Checkpoint.ensure_tables()
    :ok = BeamAgent.Checkpoint.clear()

    session = "checkpoint-smoke-#{System.unique_integer([:positive, :monotonic])}"
    tmp_dir = System.tmp_dir!()
    tmp_file = Path.join(tmp_dir, "beam_agent_checkpoint_test_#{session}.txt")

    on_exit(fn ->
      File.rm(tmp_file)
      BeamAgent.Checkpoint.clear()
    end)

    File.write!(tmp_file, "checkpoint content")

    {:ok, cp} = BeamAgent.Checkpoint.snapshot(session, "uuid-1", [tmp_file])
    assert cp.session_id == session
    assert cp.uuid == "uuid-1"
    assert length(cp.files) == 1

    [file_snap] = cp.files
    assert file_snap.path == tmp_file
    assert file_snap.existed == true
    assert file_snap.content == "checkpoint content"

    {:ok, checkpoints} = BeamAgent.Checkpoint.list_checkpoints(session)
    assert length(checkpoints) == 1
    assert hd(checkpoints).uuid == "uuid-1"

    # Verify nil normalization for non-existent files
    nonexistent = Path.join(tmp_dir, "beam_agent_checkpoint_test_nonexistent_#{session}.txt")
    {:ok, cp2} = BeamAgent.Checkpoint.snapshot(session, "uuid-2", [nonexistent])
    [snap2] = cp2.files
    assert snap2.existed == false
    assert snap2.content == nil
    assert snap2.permissions == nil
  end
end
