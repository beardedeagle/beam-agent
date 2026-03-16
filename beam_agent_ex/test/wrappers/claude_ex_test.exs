defmodule ClaudeExTest do
  use ExUnit.Case, async: true

  @moduletag :claude_ex

  setup_all do
    {:module, _} = Code.ensure_loaded(ClaudeEx)
    :ok
  end

  describe "start_session/1" do
    @tag capture_log: true
    test "fails with bad CLI path" do
      Process.flag(:trap_exit, true)

      assert {:error, {:transport_start_failed, _}} =
               ClaudeEx.start_session(cli_path: "/nonexistent/path/to/claude")

      Process.flag(:trap_exit, false)
    end
  end

  describe "child_spec/1" do
    test "returns valid supervisor child spec" do
      spec = ClaudeEx.child_spec(cli_path: "claude")
      assert %{id: :claude_agent_session} = spec
      assert spec.restart == :transient
      assert spec.type == :worker
      assert spec.shutdown == 10_000
      assert {:claude_agent_session, :start_link, [opts]} = spec.start
      assert opts.cli_path == "claude"
    end

    test "uses session_id as child id when provided" do
      spec = ClaudeEx.child_spec(cli_path: "claude", session_id: "sess_123")
      assert %{id: {:claude_agent_session, "sess_123"}} = spec
    end
  end

  describe "health/1" do
    test "returns error for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert catch_exit(ClaudeEx.health(pid))
    end
  end

  describe "MCP constructors" do
    test "mcp_tool/4 creates tool definition" do
      handler = fn input -> {:ok, [%{type: :text, text: input["msg"]}]} end
      tool = ClaudeEx.mcp_tool("echo", "Echo input", %{"type" => "object"}, handler)

      assert tool.name == "echo"
      assert tool.description == "Echo input"
      assert is_function(tool.handler, 1)
    end

    test "mcp_server/2 creates server with tools" do
      tool =
        ClaudeEx.mcp_tool("t1", "Test", %{"type" => "object"}, fn _ ->
          {:ok, [%{type: :text, text: "ok"}]}
        end)

      server = ClaudeEx.mcp_server("my-server", [tool])
      assert server.name == "my-server"
      assert length(server.tools) == 1
      assert server.version == "1.0.0"
    end
  end

  describe "SDK hook constructors" do
    test "sdk_hook/2 creates hook definition" do
      hook = ClaudeEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end)
      assert hook.event == :pre_tool_use
      assert is_function(hook.callback, 1)
      refute Map.has_key?(hook, :matcher)
    end

    test "sdk_hook/3 creates hook with matcher" do
      hook = ClaudeEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end, %{tool_name: "Bash"})
      assert hook.event == :pre_tool_use
      assert is_function(hook.callback, 1)
      assert hook.matcher == %{tool_name: "Bash"}
    end

    test "all six event types work" do
      events = [
        :pre_tool_use,
        :post_tool_use,
        :stop,
        :session_start,
        :session_end,
        :user_prompt_submit
      ]

      for event <- events do
        hook = ClaudeEx.sdk_hook(event, fn _ctx -> :ok end)
        assert hook.event == event
      end
    end

    test "hook callback can return deny tuple" do
      hook =
        ClaudeEx.sdk_hook(
          :pre_tool_use,
          fn _ctx -> {:deny, "blocked"} end
        )

      assert hook.callback.(%{event: :pre_tool_use}) == {:deny, "blocked"}
    end
  end
end
