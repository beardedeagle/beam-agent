defmodule BeamAgent.ThreadsTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Threads)
    :ok
  end

  test "exports the canonical threads surface" do
    # Storage layer
    assert function_exported?(BeamAgent.Threads, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Threads, :clear, 0)
    assert function_exported?(BeamAgent.Threads, :start_thread, 2)
    assert function_exported?(BeamAgent.Threads, :fork_thread, 3)
    assert function_exported?(BeamAgent.Threads, :resume_thread, 2)
    assert function_exported?(BeamAgent.Threads, :list_threads, 1)
    assert function_exported?(BeamAgent.Threads, :get_thread, 2)
    assert function_exported?(BeamAgent.Threads, :read_thread, 2)
    assert function_exported?(BeamAgent.Threads, :read_thread, 3)
    assert function_exported?(BeamAgent.Threads, :delete_thread, 2)
    assert function_exported?(BeamAgent.Threads, :archive_thread, 2)
    assert function_exported?(BeamAgent.Threads, :unarchive_thread, 2)
    assert function_exported?(BeamAgent.Threads, :rollback_thread, 3)
    assert function_exported?(BeamAgent.Threads, :record_thread_message, 3)
    assert function_exported?(BeamAgent.Threads, :get_thread_messages, 2)
    assert function_exported?(BeamAgent.Threads, :thread_count, 1)
    assert function_exported?(BeamAgent.Threads, :active_thread, 1)
    assert function_exported?(BeamAgent.Threads, :set_active_thread, 2)
    assert function_exported?(BeamAgent.Threads, :clear_active_thread, 1)

    # Session layer
    assert function_exported?(BeamAgent.Threads, :thread_start, 2)
    assert function_exported?(BeamAgent.Threads, :thread_resume, 2)
    assert function_exported?(BeamAgent.Threads, :thread_resume, 3)
    assert function_exported?(BeamAgent.Threads, :thread_list, 1)
    assert function_exported?(BeamAgent.Threads, :thread_list, 2)
    assert function_exported?(BeamAgent.Threads, :thread_fork, 2)
    assert function_exported?(BeamAgent.Threads, :thread_fork, 3)
    assert function_exported?(BeamAgent.Threads, :thread_read, 2)
    assert function_exported?(BeamAgent.Threads, :thread_read, 3)
    assert function_exported?(BeamAgent.Threads, :thread_archive, 2)
    assert function_exported?(BeamAgent.Threads, :thread_unarchive, 2)
    assert function_exported?(BeamAgent.Threads, :thread_rollback, 3)
    assert function_exported?(BeamAgent.Threads, :thread_unsubscribe, 2)
    assert function_exported?(BeamAgent.Threads, :thread_name_set, 3)
    assert function_exported?(BeamAgent.Threads, :thread_metadata_update, 3)
    assert function_exported?(BeamAgent.Threads, :thread_loaded_list, 1)
    assert function_exported?(BeamAgent.Threads, :thread_loaded_list, 2)
    assert function_exported?(BeamAgent.Threads, :thread_compact, 2)
  end
end
