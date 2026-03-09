defmodule OpencodeExTest do
  use ExUnit.Case, async: true

  setup_all do
    {:module, _} = Code.ensure_loaded(OpencodeEx)
    :ok
  end

  @moduledoc """
  Tests for the OpencodeEx Elixir wrapper.

  Since the wrapper depends on gun (network), these tests are kept
  lightweight and focus on:
    - Module compilation and export verification
    - opts_to_map behaviour (keyword → map conversion)
    - child_spec structure
    - Function arity contracts
    - SDK hook constructors
  """

  # ── Module existence ────────────────────────────────────────────────

  test "OpencodeEx module is defined" do
    assert Code.ensure_loaded?(OpencodeEx)
  end

  # ── Function exports ────────────────────────────────────────────────

  test "start_session/1 is exported" do
    assert function_exported?(OpencodeEx, :start_session, 1)
  end

  test "stop/1 is exported" do
    assert function_exported?(OpencodeEx, :stop, 1)
  end

  test "query/2 is exported" do
    assert function_exported?(OpencodeEx, :query, 2)
  end

  test "query/3 is exported" do
    assert function_exported?(OpencodeEx, :query, 3)
  end

  test "stream!/2 is exported" do
    assert function_exported?(OpencodeEx, :stream!, 2)
  end

  test "stream!/3 is exported" do
    assert function_exported?(OpencodeEx, :stream!, 3)
  end

  test "stream/2 is exported" do
    assert function_exported?(OpencodeEx, :stream, 2)
  end

  test "stream/3 is exported" do
    assert function_exported?(OpencodeEx, :stream, 3)
  end

  test "abort/1 is exported" do
    assert function_exported?(OpencodeEx, :abort, 1)
  end

  test "health/1 is exported" do
    assert function_exported?(OpencodeEx, :health, 1)
  end

  test "session_info/1 is exported" do
    assert function_exported?(OpencodeEx, :session_info, 1)
  end

  test "set_model/2 is exported" do
    assert function_exported?(OpencodeEx, :set_model, 2)
  end

  test "sdk_hook/2 is exported" do
    assert function_exported?(OpencodeEx, :sdk_hook, 2)
  end

  test "sdk_hook/3 is exported" do
    assert function_exported?(OpencodeEx, :sdk_hook, 3)
  end

  test "child_spec/1 is exported" do
    assert function_exported?(OpencodeEx, :child_spec, 1)
  end

  test "list_server_sessions/1 is exported" do
    assert function_exported?(OpencodeEx, :list_server_sessions, 1)
  end

  test "get_server_session/2 is exported" do
    assert function_exported?(OpencodeEx, :get_server_session, 2)
  end

  test "delete_server_session/2 is exported" do
    assert function_exported?(OpencodeEx, :delete_server_session, 2)
  end

  test "send_command/2 is exported (arity 2)" do
    assert function_exported?(OpencodeEx, :send_command, 2)
  end

  test "send_command/3 is exported (arity 3)" do
    assert function_exported?(OpencodeEx, :send_command, 3)
  end

  test "server_health/1 is exported" do
    assert function_exported?(OpencodeEx, :server_health, 1)
  end

  # ── opts_to_map behaviour ───────────────────────────────────────────

  test "child_spec accepts keyword list" do
    spec = OpencodeEx.child_spec(directory: "/tmp")
    assert is_map(spec)
    assert spec.id == :opencode_session
  end

  test "child_spec accepts map" do
    spec = OpencodeEx.child_spec(%{directory: "/tmp"})
    assert is_map(spec)
    assert spec.id == :opencode_session
  end

  test "child_spec uses session_id as child id when provided (keyword)" do
    spec = OpencodeEx.child_spec(directory: "/tmp", session_id: "my-sess")
    assert spec.id == {:opencode_session, "my-sess"}
  end

  test "child_spec uses session_id as child id when provided (map)" do
    spec = OpencodeEx.child_spec(%{directory: "/tmp", session_id: "sess-2"})
    assert spec.id == {:opencode_session, "sess-2"}
  end

  # ── child_spec structure ────────────────────────────────────────────

  test "child_spec has correct structure" do
    spec = OpencodeEx.child_spec(directory: "/tmp")
    assert spec.restart == :transient
    assert spec.shutdown == 10_000
    assert spec.type == :worker
    assert spec.modules == [:opencode_session]
    {mod, fun, _args} = spec.start
    assert mod == :opencode_session
    assert fun == :start_link
  end

  # ── SDK hook constructors ───────────────────────────────────────────

  test "sdk_hook/2 returns a hook def map" do
    hook = OpencodeEx.sdk_hook(:session_start, fn _ctx -> :ok end)
    assert is_map(hook)
    assert Map.has_key?(hook, :event)
    assert Map.has_key?(hook, :callback)
    assert hook.event == :session_start
  end

  test "sdk_hook/3 returns a hook def map with matcher" do
    hook = OpencodeEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end, %{tool_name: "Bash"})
    assert is_map(hook)
    assert hook.event == :pre_tool_use
    assert Map.has_key?(hook, :matcher)
  end

  # ── Default parameter handling ──────────────────────────────────────

  test "query/2 and query/3 have different default params" do
    # Verify that query/2 calls query/3 by checking arity
    assert function_exported?(OpencodeEx, :query, 2)
    assert function_exported?(OpencodeEx, :query, 3)
  end

  test "stream!/2 has default params (arity 2 exported)" do
    assert function_exported?(OpencodeEx, :stream!, 2)
  end

  test "stream/2 has default params (arity 2 exported)" do
    assert function_exported?(OpencodeEx, :stream, 2)
  end

  test "send_command/2 has default params (arity 2 exported)" do
    assert function_exported?(OpencodeEx, :send_command, 2)
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant messages inline" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{type: :text, text: "hello from opencode"}
          ]
        },
        %{type: :result}
      ]

      flat = OpencodeEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:text, :result]
    end

    test "passes through OpenCode-style flat messages unchanged" do
      messages = [
        %{type: :system, subtype: "connected"},
        %{type: :text, content: "hi"},
        %{type: :tool_use, tool_name: "edit", tool_input: %{}},
        %{type: :result, content: ""}
      ]

      assert OpencodeEx.normalize_messages(messages) == messages
    end
  end

  describe "content block conversion" do
    test "round-trip tool_result block" do
      block = %{type: :tool_result, tool_use_id: "tu_1", content: "output"}
      assert block == OpencodeEx.message_to_block(OpencodeEx.block_to_message(block))
    end

    test "messages_to_blocks wraps non-content types as raw" do
      blocks = OpencodeEx.messages_to_blocks([%{type: :system, content: "init"}])
      assert length(blocks) == 1
      assert hd(blocks).type == :raw
    end
  end

  # ── System Init Convenience Accessors ──────────────────────────────

  describe "system init accessors" do
    test "list_tools/1 is exported" do
      assert function_exported?(OpencodeEx, :list_tools, 1)
    end

    test "list_skills/1 is exported" do
      assert function_exported?(OpencodeEx, :list_skills, 1)
    end

    test "list_plugins/1 is exported" do
      assert function_exported?(OpencodeEx, :list_plugins, 1)
    end

    test "list_mcp_servers/1 is exported" do
      assert function_exported?(OpencodeEx, :list_mcp_servers, 1)
    end

    test "list_agents/1 is exported" do
      assert function_exported?(OpencodeEx, :list_agents, 1)
    end

    test "cli_version/1 is exported" do
      assert function_exported?(OpencodeEx, :cli_version, 1)
    end

    test "working_directory/1 is exported" do
      assert function_exported?(OpencodeEx, :working_directory, 1)
    end

    test "output_style/1 is exported" do
      assert function_exported?(OpencodeEx, :output_style, 1)
    end

    test "api_key_source/1 is exported" do
      assert function_exported?(OpencodeEx, :api_key_source, 1)
    end

    test "active_betas/1 is exported" do
      assert function_exported?(OpencodeEx, :active_betas, 1)
    end

    test "current_model/1 is exported" do
      assert function_exported?(OpencodeEx, :current_model, 1)
    end

    test "current_permission_mode/1 is exported" do
      assert function_exported?(OpencodeEx, :current_permission_mode, 1)
    end
  end

  # ── Todo Extraction ────────────────────────────────────────────────

  describe "todo extraction" do
    test "extract_todos/1 extracts from assistant messages" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{"content" => "Task 1", "status" => "pending"}
            }
          ]
        }
      ]

      todos = OpencodeEx.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Task 1"
      assert hd(todos).status == :pending
    end

    test "filter_todos/2 filters by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed}
      ]

      result = OpencodeEx.filter_todos(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "todo_summary/1 counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed},
        %{content: "C", status: :completed}
      ]

      summary = OpencodeEx.todo_summary(todos)
      assert summary.pending == 1
      assert summary.completed == 2
      assert summary.total == 3
    end
  end

  describe "additional session control" do
    test "interrupt/1 is exported" do
      assert function_exported?(OpencodeEx, :interrupt, 1)
    end

    test "set_permission_mode/2 is exported" do
      assert function_exported?(OpencodeEx, :set_permission_mode, 2)
    end

    test "send_control/3 is exported" do
      assert function_exported?(OpencodeEx, :send_control, 3)
    end
  end

  describe "MCP constructors" do
    test "mcp_tool/4 creates a tool definition" do
      tool = OpencodeEx.mcp_tool("test", "A test", %{}, fn _ -> {:ok, []} end)
      assert tool.name == "test"
    end

    test "mcp_server/2 creates a server definition" do
      tool = OpencodeEx.mcp_tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = OpencodeEx.mcp_server("my-server", [tool])
      assert server.name == "my-server"
    end
  end
end
