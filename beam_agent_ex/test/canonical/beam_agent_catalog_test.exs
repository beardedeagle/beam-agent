defmodule BeamAgent.CatalogTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.Catalog)
    :ok
  end

  test "exports the session catalog surface" do
    assert function_exported?(BeamAgent.Catalog, :list_tools, 1)
    assert function_exported?(BeamAgent.Catalog, :list_skills, 1)
    assert function_exported?(BeamAgent.Catalog, :list_plugins, 1)
    assert function_exported?(BeamAgent.Catalog, :list_mcp_servers, 1)
    assert function_exported?(BeamAgent.Catalog, :list_agents, 1)
    assert function_exported?(BeamAgent.Catalog, :get_tool, 2)
    assert function_exported?(BeamAgent.Catalog, :get_skill, 2)
    assert function_exported?(BeamAgent.Catalog, :get_plugin, 2)
    assert function_exported?(BeamAgent.Catalog, :get_agent, 2)
    assert function_exported?(BeamAgent.Catalog, :current_agent, 1)
    assert function_exported?(BeamAgent.Catalog, :set_default_agent, 2)
    assert function_exported?(BeamAgent.Catalog, :clear_default_agent, 1)
  end

  test "exports the global registry surface" do
    assert function_exported?(BeamAgent.Catalog, :ensure_registry, 0)
    assert function_exported?(BeamAgent.Catalog, :register_agent, 2)
    assert function_exported?(BeamAgent.Catalog, :unregister_agent, 1)
    assert function_exported?(BeamAgent.Catalog, :get_registered_agent, 1)
    assert function_exported?(BeamAgent.Catalog, :registered_agents, 0)
    assert function_exported?(BeamAgent.Catalog, :clear_registered_agents, 0)
    assert function_exported?(BeamAgent.Catalog, :register_plugin, 2)
    assert function_exported?(BeamAgent.Catalog, :unregister_plugin, 1)
    assert function_exported?(BeamAgent.Catalog, :get_registered_plugin, 1)
    assert function_exported?(BeamAgent.Catalog, :registered_plugins, 0)
    assert function_exported?(BeamAgent.Catalog, :clear_registered_plugins, 0)
    assert function_exported?(BeamAgent.Catalog, :register_command, 2)
    assert function_exported?(BeamAgent.Catalog, :unregister_command, 1)
    assert function_exported?(BeamAgent.Catalog, :get_registered_command, 1)
    assert function_exported?(BeamAgent.Catalog, :registered_commands, 0)
    assert function_exported?(BeamAgent.Catalog, :clear_registered_commands, 0)
  end

  test "exports the file operations surface" do
    assert function_exported?(BeamAgent.Catalog, :find_text, 2)
    assert function_exported?(BeamAgent.Catalog, :find_files, 2)
    assert function_exported?(BeamAgent.Catalog, :find_symbols, 2)
    assert function_exported?(BeamAgent.Catalog, :file_list, 2)
    assert function_exported?(BeamAgent.Catalog, :file_read, 2)
    assert function_exported?(BeamAgent.Catalog, :file_status, 1)
  end

  test "exports the fuzzy search surface" do
    assert function_exported?(BeamAgent.Catalog, :fuzzy_search, 2)
    assert function_exported?(BeamAgent.Catalog, :fuzzy_search, 3)
    assert function_exported?(BeamAgent.Catalog, :search_session_start, 3)
    assert function_exported?(BeamAgent.Catalog, :search_session_update, 3)
    assert function_exported?(BeamAgent.Catalog, :search_session_stop, 2)
  end

  test "exports the static listings surface" do
    assert function_exported?(BeamAgent.Catalog, :supported_commands, 1)
    assert function_exported?(BeamAgent.Catalog, :supported_models, 1)
    assert function_exported?(BeamAgent.Catalog, :supported_agents, 1)
    assert function_exported?(BeamAgent.Catalog, :model_list, 1)
    assert function_exported?(BeamAgent.Catalog, :model_list, 2)
    assert function_exported?(BeamAgent.Catalog, :list_commands, 1)
  end
end
