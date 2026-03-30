defmodule BeamAgent.ConfigTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Config)
    :ok
  end

  test "exports the session config surface" do
    assert function_exported?(BeamAgent.Config, :read, 1)
    assert function_exported?(BeamAgent.Config, :read, 2)
    assert function_exported?(BeamAgent.Config, :update, 2)
    assert function_exported?(BeamAgent.Config, :providers, 1)
    assert function_exported?(BeamAgent.Config, :value_write, 3)
    assert function_exported?(BeamAgent.Config, :value_write, 4)
    assert function_exported?(BeamAgent.Config, :batch_write, 2)
    assert function_exported?(BeamAgent.Config, :batch_write, 3)
    assert function_exported?(BeamAgent.Config, :requirements_read, 1)
    assert function_exported?(BeamAgent.Config, :external_agent_detect, 1)
    assert function_exported?(BeamAgent.Config, :external_agent_detect, 2)
    assert function_exported?(BeamAgent.Config, :external_agent_import, 2)
  end

  test "exports the global SDK config surface" do
    assert function_exported?(BeamAgent.Config, :ensure_table, 0)
    assert function_exported?(BeamAgent.Config, :global_set, 2)
    assert function_exported?(BeamAgent.Config, :global_get, 1)
    assert function_exported?(BeamAgent.Config, :global_get, 2)
    assert function_exported?(BeamAgent.Config, :global_delete, 1)
    assert function_exported?(BeamAgent.Config, :global_list, 0)
    assert function_exported?(BeamAgent.Config, :global_clear, 0)
  end

  test "exports the universal fallback config surface" do
    assert function_exported?(BeamAgent.Config, :config_read, 1)
    assert function_exported?(BeamAgent.Config, :config_update, 2)
    assert function_exported?(BeamAgent.Config, :config_value_write, 4)
    assert function_exported?(BeamAgent.Config, :config_batch_write, 3)
    assert function_exported?(BeamAgent.Config, :config_requirements_read, 1)
    assert function_exported?(BeamAgent.Config, :external_agent_config_detect, 2)
    assert function_exported?(BeamAgent.Config, :external_agent_config_import, 2)
    assert function_exported?(BeamAgent.Config, :provider_auth_methods, 1)
    assert function_exported?(BeamAgent.Config, :provider_oauth_authorize, 3)
    assert function_exported?(BeamAgent.Config, :provider_oauth_callback, 3)
  end
end
