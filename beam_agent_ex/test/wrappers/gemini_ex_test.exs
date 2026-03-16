defmodule GeminiExTest do
  use ExUnit.Case, async: true

  setup_all do
    {:module, _} = Code.ensure_loaded(GeminiEx)
    :ok
  end

  describe "opts_to_map (via child_spec)" do
    test "keyword list converts to map" do
      spec = GeminiEx.child_spec(cli_path: "/usr/bin/gemini")
      assert %{id: :gemini_cli_session} = spec
      assert %{start: {:gemini_cli_session, :start_link, [opts]}} = spec
      assert is_map(opts)
      assert opts.cli_path == "/usr/bin/gemini"
    end

    test "session_id is used in child_spec id" do
      spec = GeminiEx.child_spec(cli_path: "gemini", session_id: "s1")
      assert %{id: {:gemini_cli_session, "s1"}} = spec
    end
  end

  describe "child_spec" do
    test "has correct structure" do
      spec = GeminiEx.child_spec(cli_path: "gemini")
      assert %{restart: :transient, shutdown: 10_000, type: :worker} = spec
      assert %{modules: [:gemini_cli_session]} = spec
    end
  end

  describe "sdk_hook" do
    test "creates a hook without matcher" do
      hook = GeminiEx.sdk_hook(:post_tool_use, fn _ctx -> :ok end)
      assert is_map(hook)
      assert hook.event == :post_tool_use
    end

    test "creates a hook with matcher" do
      hook =
        GeminiEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end, %{tool_name: "Read"})

      assert is_map(hook)
      assert hook.event == :pre_tool_use
      assert is_map(hook.matcher)
    end
  end

  describe "stream functions" do
    test "stream!/3 is exported" do
      assert function_exported?(GeminiEx, :stream!, 3)
    end

    test "stream/3 is exported" do
      assert function_exported?(GeminiEx, :stream, 3)
    end
  end

  describe "lifecycle functions" do
    test "start_session/1 is exported" do
      assert function_exported?(GeminiEx, :start_session, 1)
    end

    test "stop/1 is exported" do
      assert function_exported?(GeminiEx, :stop, 1)
    end

    test "health/1 is exported" do
      assert function_exported?(GeminiEx, :health, 1)
    end

    test "session_info/1 is exported" do
      assert function_exported?(GeminiEx, :session_info, 1)
    end

    test "set_model/2 is exported" do
      assert function_exported?(GeminiEx, :set_model, 2)
    end

    test "interrupt/1 is exported" do
      assert function_exported?(GeminiEx, :interrupt, 1)
    end
  end

  describe "MCP constructors" do
    test "mcp_tool/4 creates a tool definition" do
      tool = GeminiEx.mcp_tool("test", "A test", %{}, fn _ -> {:ok, []} end)
      assert tool.name == "test"
    end

    test "mcp_server/2 creates a server definition" do
      tool = GeminiEx.mcp_tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = GeminiEx.mcp_server("my-server", [tool])
      assert server.name == "my-server"
    end
  end
end
