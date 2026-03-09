defmodule CopilotExTest do
  use ExUnit.Case, async: true

  setup_all do
    {:module, _} = Code.ensure_loaded(CopilotEx)
    :ok
  end

  @moduledoc """
  Tests for the CopilotEx Elixir wrapper.

  Since the wrapper depends on a real Copilot CLI binary, these tests
  focus on:
    - Module compilation and export verification
    - opts_to_map behaviour (keyword -> map conversion)
    - child_spec structure
    - Function arity contracts
    - SDK hook constructors
  """

  # -- Module existence ----------------------------------------------------

  test "CopilotEx module is defined" do
    assert Code.ensure_loaded?(CopilotEx)
  end

  # -- Function exports ----------------------------------------------------

  test "start_session/0 is exported" do
    assert function_exported?(CopilotEx, :start_session, 0)
  end

  test "start_session/1 is exported" do
    assert function_exported?(CopilotEx, :start_session, 1)
  end

  test "stop/1 is exported" do
    assert function_exported?(CopilotEx, :stop, 1)
  end

  test "query/2 is exported" do
    assert function_exported?(CopilotEx, :query, 2)
  end

  test "query/3 is exported" do
    assert function_exported?(CopilotEx, :query, 3)
  end

  test "stream!/2 is exported" do
    assert function_exported?(CopilotEx, :stream!, 2)
  end

  test "stream!/3 is exported" do
    assert function_exported?(CopilotEx, :stream!, 3)
  end

  test "stream/2 is exported" do
    assert function_exported?(CopilotEx, :stream, 2)
  end

  test "stream/3 is exported" do
    assert function_exported?(CopilotEx, :stream, 3)
  end

  test "health/1 is exported" do
    assert function_exported?(CopilotEx, :health, 1)
  end

  test "session_info/1 is exported" do
    assert function_exported?(CopilotEx, :session_info, 1)
  end

  test "set_model/2 is exported" do
    assert function_exported?(CopilotEx, :set_model, 2)
  end

  test "interrupt/1 is exported" do
    assert function_exported?(CopilotEx, :interrupt, 1)
  end

  test "abort/1 is exported" do
    assert function_exported?(CopilotEx, :abort, 1)
  end

  test "send_command/2 is exported (arity 2)" do
    assert function_exported?(CopilotEx, :send_command, 2)
  end

  test "send_command/3 is exported (arity 3)" do
    assert function_exported?(CopilotEx, :send_command, 3)
  end

  test "sdk_hook/2 is exported" do
    assert function_exported?(CopilotEx, :sdk_hook, 2)
  end

  test "sdk_hook/3 is exported" do
    assert function_exported?(CopilotEx, :sdk_hook, 3)
  end

  test "child_spec/1 is exported" do
    assert function_exported?(CopilotEx, :child_spec, 1)
  end

  # -- opts_to_map behaviour -----------------------------------------------

  test "child_spec accepts keyword list" do
    spec = CopilotEx.child_spec(cli_path: "copilot")
    assert is_map(spec)
    assert spec.id == :copilot_session
  end

  test "child_spec accepts map" do
    spec = CopilotEx.child_spec(%{cli_path: "copilot"})
    assert is_map(spec)
    assert spec.id == :copilot_session
  end

  test "child_spec uses session_id as child id when provided (keyword)" do
    spec = CopilotEx.child_spec(cli_path: "copilot", session_id: "my-sess")
    assert spec.id == {:copilot_session, "my-sess"}
  end

  test "child_spec uses session_id as child id when provided (map)" do
    spec = CopilotEx.child_spec(%{cli_path: "copilot", session_id: "sess-2"})
    assert spec.id == {:copilot_session, "sess-2"}
  end

  # -- child_spec structure ------------------------------------------------

  test "child_spec has correct structure" do
    spec = CopilotEx.child_spec(cli_path: "copilot")
    assert spec.restart == :transient
    assert spec.shutdown == 10_000
    assert spec.type == :worker
    assert spec.modules == [:copilot_session]
    {mod, fun, _args} = spec.start
    assert mod == :copilot_session
    assert fun == :start_link
  end

  test "child_spec start args contain map opts" do
    spec = CopilotEx.child_spec(cli_path: "copilot", model: "gpt-4o")
    {_mod, _fun, [opts]} = spec.start
    assert is_map(opts)
    assert opts.cli_path == "copilot"
    assert opts.model == "gpt-4o"
  end

  test "child_spec preserves canonical option keys" do
    spec =
      CopilotEx.child_spec(
        cli_path: "copilot",
        system_message: "Be brief",
        available_tools: ["read_file"],
        excluded_tools: ["bash"],
        reasoning_effort: "high"
      )

    {_mod, _fun, [opts]} = spec.start

    assert opts.system_message == "Be brief"
    assert opts.available_tools == ["read_file"]
    assert opts.excluded_tools == ["bash"]
    assert opts.reasoning_effort == "high"
  end

  # -- SDK hook constructors -----------------------------------------------

  test "sdk_hook/2 returns a hook def map" do
    hook = CopilotEx.sdk_hook(:session_start, fn _ctx -> :ok end)
    assert is_map(hook)
    assert Map.has_key?(hook, :event)
    assert Map.has_key?(hook, :callback)
    assert hook.event == :session_start
  end

  test "sdk_hook/3 returns a hook def map with matcher" do
    hook =
      CopilotEx.sdk_hook(
        :pre_tool_use,
        fn _ctx -> :ok end,
        %{tool_name: "Bash"}
      )

    assert is_map(hook)
    assert hook.event == :pre_tool_use
    assert Map.has_key?(hook, :matcher)
  end

  test "sdk_hook/2 with :stop event" do
    hook = CopilotEx.sdk_hook(:stop, fn _ctx -> :ok end)
    assert hook.event == :stop
  end

  test "sdk_hook/2 with :user_prompt_submit event" do
    hook = CopilotEx.sdk_hook(:user_prompt_submit, fn _ctx -> :ok end)
    assert hook.event == :user_prompt_submit
  end

  # -- Default parameter handling ------------------------------------------

  test "query/2 and query/3 have different default params" do
    assert function_exported?(CopilotEx, :query, 2)
    assert function_exported?(CopilotEx, :query, 3)
  end

  test "stream!/2 has default params (arity 2 exported)" do
    assert function_exported?(CopilotEx, :stream!, 2)
  end

  test "stream/2 has default params (arity 2 exported)" do
    assert function_exported?(CopilotEx, :stream, 2)
  end

  test "send_command/2 has default params (arity 2 exported)" do
    assert function_exported?(CopilotEx, :send_command, 2)
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant messages inline" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{type: :text, text: "from copilot"},
            %{type: :tool_use, id: "tu_1", name: "read", input: %{}}
          ]
        },
        %{type: :result}
      ]

      flat = CopilotEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:text, :tool_use, :result]
    end

    test "passes through Copilot-style flat messages unchanged" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :tool_use, tool_name: "read", tool_input: %{}},
        %{type: :tool_result, tool_name: "read", content: "data"},
        %{type: :result}
      ]

      assert CopilotEx.normalize_messages(messages) == messages
    end
  end

  describe "content block conversion" do
    test "flatten_assistant passes through non-assistant" do
      msg = %{type: :text, content: "hello"}
      assert CopilotEx.flatten_assistant(msg) == [msg]
    end

    test "round-trip text block" do
      block = %{type: :text, text: "hello"}
      assert block == CopilotEx.message_to_block(CopilotEx.block_to_message(block))
    end
  end

  # ── System Init Convenience Accessors ──────────────────────────────

  describe "system init accessors" do
    test "list_tools/1 is exported" do
      assert function_exported?(CopilotEx, :list_tools, 1)
    end

    test "list_skills/1 is exported" do
      assert function_exported?(CopilotEx, :list_skills, 1)
    end

    test "list_plugins/1 is exported" do
      assert function_exported?(CopilotEx, :list_plugins, 1)
    end

    test "list_mcp_servers/1 is exported" do
      assert function_exported?(CopilotEx, :list_mcp_servers, 1)
    end

    test "list_agents/1 is exported" do
      assert function_exported?(CopilotEx, :list_agents, 1)
    end

    test "cli_version/1 is exported" do
      assert function_exported?(CopilotEx, :cli_version, 1)
    end

    test "working_directory/1 is exported" do
      assert function_exported?(CopilotEx, :working_directory, 1)
    end

    test "output_style/1 is exported" do
      assert function_exported?(CopilotEx, :output_style, 1)
    end

    test "api_key_source/1 is exported" do
      assert function_exported?(CopilotEx, :api_key_source, 1)
    end

    test "active_betas/1 is exported" do
      assert function_exported?(CopilotEx, :active_betas, 1)
    end

    test "current_model/1 is exported" do
      assert function_exported?(CopilotEx, :current_model, 1)
    end

    test "current_permission_mode/1 is exported" do
      assert function_exported?(CopilotEx, :current_permission_mode, 1)
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

      todos = CopilotEx.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Task 1"
      assert hd(todos).status == :pending
    end

    test "filter_todos/2 filters by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed}
      ]

      result = CopilotEx.filter_todos(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "todo_summary/1 counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed},
        %{content: "C", status: :completed}
      ]

      summary = CopilotEx.todo_summary(todos)
      assert summary.pending == 1
      assert summary.completed == 2
      assert summary.total == 3
    end
  end

  describe "MCP constructors" do
    test "mcp_tool/4 creates a tool definition" do
      tool = CopilotEx.mcp_tool("test", "A test", %{}, fn _ -> {:ok, []} end)
      assert tool.name == "test"
    end

    test "mcp_server/2 creates a server definition" do
      tool = CopilotEx.mcp_tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = CopilotEx.mcp_server("my-server", [tool])
      assert server.name == "my-server"
    end
  end
end
