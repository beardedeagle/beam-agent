defmodule BeamAgent.StoreTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Store)
    :ok
  end

  test "exports the canonical store surface" do
    assert function_exported?(BeamAgent.Store, :configure_domain, 2)
    assert function_exported?(BeamAgent.Store, :domain_config, 1)
    assert function_exported?(BeamAgent.Store, :adapter_module, 1)
    assert function_exported?(BeamAgent.Store, :reset_domain, 1)
    assert function_exported?(BeamAgent.Store, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Store, :clear, 0)
    assert function_exported?(BeamAgent.Store, :close_table, 1)
    assert function_exported?(BeamAgent.Store, :sync_table, 1)
    assert function_exported?(BeamAgent.Store, :flush_counters, 1)
    assert function_exported?(BeamAgent.Store, :data_dir, 1)
  end

  test "ensure_tables then close_table smoke test" do
    :ok = BeamAgent.Store.ensure_tables()
    :ok = BeamAgent.Store.close_table(:beam_agent_store_smoke_test)
  end
end
