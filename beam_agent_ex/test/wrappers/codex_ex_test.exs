defmodule CodexExTest do
  use ExUnit.Case, async: true

  # Ensure module is loaded before function_exported? checks
  setup_all do
    {:module, _} = Code.ensure_loaded(CodexEx)
    :ok
  end

  # ── Option conversion ────────────────────────────────────────────

  describe "opts_to_map (via child_spec)" do
    test "keyword list converts to map" do
      spec = CodexEx.child_spec(cli_path: "/usr/bin/codex")
      assert %{id: :codex_session} = spec
      assert %{start: {:codex_session, :start_link, [opts]}} = spec
      assert is_map(opts)
      assert opts.cli_path == "/usr/bin/codex"
    end

    test "session_id is used in child_spec id" do
      spec = CodexEx.child_spec(cli_path: "codex", session_id: "s1")
      assert %{id: {:codex_session, "s1"}} = spec
    end
  end

  # ── Child spec structure ─────────────────────────────────────────

  describe "child_spec" do
    test "has correct structure" do
      spec = CodexEx.child_spec(cli_path: "codex")
      assert %{restart: :transient, shutdown: 10_000, type: :worker} = spec
      assert %{modules: [:codex_session]} = spec
    end
  end

  # ── SDK hook constructors ────────────────────────────────────────

  describe "sdk_hook" do
    test "creates a hook without matcher" do
      hook = CodexEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end)
      assert is_map(hook)
      assert hook.event == :pre_tool_use
    end

    test "creates a hook with matcher" do
      hook =
        CodexEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end, %{tool_name: "Read"})

      assert is_map(hook)
      assert hook.event == :pre_tool_use
      assert is_map(hook.matcher)
    end
  end

  # ── Session module ───────────────────────────────────────────────

  describe "CodexEx.Session" do
    test "send_control delegates to codex_session" do
      # codex_exec returns {:error, :not_supported} — tests function exists
      assert {:error, :not_supported} =
               :codex_exec.send_control(self(), "method", %{})
    end
  end

  # ── Thread management functions exist ────────────────────────────

  describe "thread management" do
    test "thread_start/2 is exported" do
      assert function_exported?(CodexEx, :thread_start, 2)
    end

    test "thread_resume/2 is exported" do
      assert function_exported?(CodexEx, :thread_resume, 2)
    end

    test "thread_list/1 is exported" do
      assert function_exported?(CodexEx, :thread_list, 1)
    end
  end

  # ── Stream functions are exported ────────────────────────────────

  describe "stream functions" do
    test "stream!/3 is exported" do
      assert function_exported?(CodexEx, :stream!, 3)
    end

    test "stream/3 is exported" do
      assert function_exported?(CodexEx, :stream, 3)
    end
  end

  # ── Start functions are exported ─────────────────────────────────

  describe "start functions" do
    test "start_session/1 is exported" do
      assert function_exported?(CodexEx, :start_session, 1)
    end

    test "start_exec/1 is exported" do
      assert function_exported?(CodexEx, :start_exec, 1)
    end

    test "start_realtime/1 is exported" do
      assert function_exported?(CodexEx, :start_realtime, 1)
    end
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant messages inline" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{type: :text, text: "hello"}
          ]
        },
        %{type: :result}
      ]

      flat = CodexEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:text, :result]
    end

    test "passes through Codex-style flat messages unchanged" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :tool_use, tool_name: "bash", tool_input: %{}},
        %{type: :result, content: ""}
      ]

      assert CodexEx.normalize_messages(messages) == messages
    end
  end

  describe "content block conversion" do
    test "round-trip text block" do
      block = %{type: :text, text: "hello"}
      assert block == CodexEx.message_to_block(CodexEx.block_to_message(block))
    end

    test "messages_to_blocks converts flat messages" do
      blocks = CodexEx.messages_to_blocks([%{type: :text, content: "hi"}])
      assert length(blocks) == 1
      assert hd(blocks).type == :text
      assert hd(blocks).text == "hi"
    end
  end

  # ── System Init Convenience Accessors ──────────────────────────────

  describe "system init accessors" do
    test "list_tools/1 is exported" do
      assert function_exported?(CodexEx, :list_tools, 1)
    end

    test "list_skills/1 is exported" do
      assert function_exported?(CodexEx, :list_skills, 1)
    end

    test "list_plugins/1 is exported" do
      assert function_exported?(CodexEx, :list_plugins, 1)
    end

    test "list_mcp_servers/1 is exported" do
      assert function_exported?(CodexEx, :list_mcp_servers, 1)
    end

    test "list_agents/1 is exported" do
      assert function_exported?(CodexEx, :list_agents, 1)
    end

    test "cli_version/1 is exported" do
      assert function_exported?(CodexEx, :cli_version, 1)
    end

    test "working_directory/1 is exported" do
      assert function_exported?(CodexEx, :working_directory, 1)
    end

    test "output_style/1 is exported" do
      assert function_exported?(CodexEx, :output_style, 1)
    end

    test "api_key_source/1 is exported" do
      assert function_exported?(CodexEx, :api_key_source, 1)
    end

    test "active_betas/1 is exported" do
      assert function_exported?(CodexEx, :active_betas, 1)
    end

    test "current_model/1 is exported" do
      assert function_exported?(CodexEx, :current_model, 1)
    end

    test "current_permission_mode/1 is exported" do
      assert function_exported?(CodexEx, :current_permission_mode, 1)
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

      todos = CodexEx.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Task 1"
      assert hd(todos).status == :pending
    end

    test "filter_todos/2 filters by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed}
      ]

      result = CodexEx.filter_todos(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "todo_summary/1 counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed},
        %{content: "C", status: :completed}
      ]

      summary = CodexEx.todo_summary(todos)
      assert summary.pending == 1
      assert summary.completed == 2
      assert summary.total == 3
    end
  end

  # ── Additional Session Control ─────────────────────────────────────

  describe "additional session control" do
    test "set_permission_mode/2 is exported" do
      assert function_exported?(CodexEx, :set_permission_mode, 2)
    end

    test "send_control/3 is exported" do
      assert function_exported?(CodexEx, :send_control, 3)
    end
  end

  # ── Codex-Specific Operations ──────────────────────────────────────

  describe "codex-specific operations" do
    test "command_run/3 is exported" do
      assert function_exported?(CodexEx, :command_run, 3)
    end

    test "submit_feedback/2 is exported" do
      assert function_exported?(CodexEx, :submit_feedback, 2)
    end

    test "turn_respond/3 is exported" do
      assert function_exported?(CodexEx, :turn_respond, 3)
    end
  end

  # ── SDK MCP Server Constructors ────────────────────────────────────

  describe "MCP constructors" do
    test "mcp_tool/4 creates a tool definition" do
      tool = CodexEx.mcp_tool("test", "A test", %{}, fn _ -> {:ok, []} end)
      assert tool.name == "test"
      assert tool.description == "A test"
    end

    test "mcp_server/2 creates a server definition" do
      tool = CodexEx.mcp_tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = CodexEx.mcp_server("my-server", [tool])
      assert server.name == "my-server"
      assert length(server.tools) == 1
    end
  end

  # ── Exec child spec ────────────────────────────────────────────────

  describe "exec_child_spec" do
    test "creates spec for codex_exec" do
      spec = CodexEx.exec_child_spec(cli_path: "codex")
      assert %{id: :codex_exec} = spec
      assert %{start: {:codex_exec, :start_link, [_opts]}} = spec
      assert %{modules: [:codex_exec]} = spec
    end

    test "uses session_id in exec child spec id" do
      spec = CodexEx.exec_child_spec(cli_path: "codex", session_id: "e1")
      assert %{id: {:codex_exec, "e1"}} = spec
    end
  end
end
