defmodule GeminiExTest do
  use ExUnit.Case, async: true

  # Ensure module is loaded before function_exported? checks
  setup_all do
    {:module, _} = Code.ensure_loaded(GeminiEx)
    :ok
  end

  # ── Option conversion ─────────────────────────────────────────────

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

  # ── Child spec structure ──────────────────────────────────────────

  describe "child_spec" do
    test "has correct structure" do
      spec = GeminiEx.child_spec(cli_path: "gemini")
      assert %{restart: :transient, shutdown: 10_000, type: :worker} = spec
      assert %{modules: [:gemini_cli_session]} = spec
    end
  end

  # ── SDK hook constructors ─────────────────────────────────────────

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

  # ── send_control delegates supported native controls ──────────────

  describe "send_control" do
    test "unsupported control still returns an error" do
      assert {:error, :not_supported} =
               :gemini_cli_session.send_control(self(), "method", %{})
    end
  end

  # ── Stream functions are exported ────────────────────────────────

  describe "stream functions" do
    test "stream!/3 is exported" do
      assert function_exported?(GeminiEx, :stream!, 3)
    end

    test "stream/3 is exported" do
      assert function_exported?(GeminiEx, :stream, 3)
    end
  end

  # ── Start and lifecycle functions are exported ────────────────────

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

  # ── Integration tests with mock script ───────────────────────────

  describe "query with mock CLI" do
    setup do
      script_path =
        "/tmp/mock_gemini_ex_#{:erlang.unique_integer([:positive])}"

      script = """
      #!/usr/bin/env python3
      import json, sys

      session_id = "gemini-sess-ex"
      current_model = "gemini-2.0-flash"
      current_mode = "default"

      def send(obj):
          sys.stdout.write(json.dumps(obj) + "\\n")
          sys.stdout.flush()

      def modes_payload():
          return {
              "currentModeId": current_mode,
              "availableModes": [
                  {"id": "default", "name": "Default", "description": "Prompt for approval"},
                  {"id": "autoEdit", "name": "Auto Edit", "description": "Auto approve edits"},
                  {"id": "yolo", "name": "YOLO", "description": "Allow all"}
              ]
          }

      def models_payload():
          return {
              "currentModelId": current_model,
              "availableModels": [
                  {"id": "gemini-2.0-flash", "name": "Flash"},
                  {"id": "gemini-1.5-pro", "name": "Pro"}
              ]
          }

      for line in sys.stdin:
          msg = json.loads(line)
          method = msg.get("method")
          if method == "initialize":
              send({
                  "id": msg["id"],
                  "result": {
                      "protocolVersion": 1,
                      "authMethods": [],
                      "agentCapabilities": {
                          "loadSession": True,
                          "promptCapabilities": {
                              "image": False,
                              "audio": False,
                              "embeddedContext": True
                          },
                          "mcpCapabilities": {"http": False, "sse": False},
                          "sessionCapabilities": {}
                      }
                  }
              })
          elif method == "session/new":
              send({
                  "id": msg["id"],
                  "result": {
                      "sessionId": session_id,
                      "modes": modes_payload(),
                      "models": models_payload(),
                      "configOptions": []
                  }
              })
          elif method == "session/set_model":
              current_model = msg["params"]["modelId"]
              send({"id": msg["id"], "result": {}})
          elif method == "session/set_mode":
              current_mode = msg["params"]["modeId"]
              send({"id": msg["id"], "result": {}})
          elif method == "session/prompt":
              prompt_text = msg["params"]["prompt"][0].get("text", "")
              send({
                  "method": "session/update",
                  "params": {
                      "sessionId": session_id,
                      "update": {
                          "sessionUpdate": "user_message_chunk",
                          "content": {"type": "text", "text": prompt_text}
                      }
                  }
              })
              send({
                  "method": "session/update",
                  "params": {
                      "sessionId": session_id,
                      "update": {
                          "sessionUpdate": "agent_message_chunk",
                          "content": {"type": "text", "text": "Hello from GeminiEx!"}
                      }
                  }
              })
              send({"id": msg["id"], "result": {"stopReason": "end_turn"}})
      """

      File.write!(script_path, script)
      System.cmd("chmod", ["+x", script_path])

      on_exit(fn -> File.rm(script_path) end)
      {:ok, script_path: script_path}
    end

    test "query/2 collects all messages", %{script_path: script_path} do
      :application.ensure_all_started(:telemetry)
      {:ok, session} = GeminiEx.start_session(cli_path: script_path)
      assert :ok == wait_until_ready(session)
      {:ok, messages} = GeminiEx.query(session, "Hello!")
      assert is_list(messages)
      assert length(messages) >= 1
      types = Enum.map(messages, & &1.type)
      assert :text in types or :result in types
      GeminiEx.stop(session)
    end

    test "stream!/3 yields messages", %{script_path: script_path} do
      :application.ensure_all_started(:telemetry)
      {:ok, session} = GeminiEx.start_session(cli_path: script_path)
      assert :ok == wait_until_ready(session)

      messages =
        session
        |> GeminiEx.stream!("Hello!")
        |> Enum.to_list()

      assert is_list(messages)
      assert length(messages) >= 1
      GeminiEx.stop(session)
    end

    test "health returns ready before query", %{script_path: script_path} do
      :application.ensure_all_started(:telemetry)
      {:ok, session} = GeminiEx.start_session(cli_path: script_path)
      assert :ok == wait_until_ready(session)
      assert GeminiEx.health(session) == :ready
      GeminiEx.stop(session)
    end

    test "session_info returns gemini_cli transport", %{script_path: script_path} do
      :application.ensure_all_started(:telemetry)
      {:ok, session} = GeminiEx.start_session(cli_path: script_path)
      assert :ok == wait_until_ready(session)
      {:ok, info} = GeminiEx.session_info(session)
      assert info.transport == :gemini_cli
      GeminiEx.stop(session)
    end

    test "set_model updates model", %{script_path: script_path} do
      :application.ensure_all_started(:telemetry)
      {:ok, session} = GeminiEx.start_session(cli_path: script_path)
      assert :ok == wait_until_ready(session)
      {:ok, model} = GeminiEx.set_model(session, "gemini-1.5-pro")
      assert model == "gemini-1.5-pro"
      GeminiEx.stop(session)
    end
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant messages inline" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{type: :thinking, thinking: "hmm"},
            %{type: :text, text: "answer"}
          ]
        },
        %{type: :result}
      ]

      flat = GeminiEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:thinking, :text, :result]
    end

    test "passes through Gemini-style flat messages unchanged" do
      messages = [
        %{type: :system, subtype: "init", content: ""},
        %{type: :text, content: "hi"},
        %{type: :result, content: ""}
      ]

      assert GeminiEx.normalize_messages(messages) == messages
    end
  end

  describe "content block conversion" do
    test "round-trip thinking block" do
      block = %{type: :thinking, thinking: "reason"}
      assert block == GeminiEx.message_to_block(GeminiEx.block_to_message(block))
    end

    test "messages_to_blocks converts flat messages" do
      blocks = GeminiEx.messages_to_blocks([%{type: :thinking, content: "hmm"}])
      assert length(blocks) == 1
      assert hd(blocks).type == :thinking
      assert hd(blocks).thinking == "hmm"
    end
  end

  # ── System Init Convenience Accessors ──────────────────────────────

  describe "system init accessors" do
    test "list_tools/1 is exported" do
      assert function_exported?(GeminiEx, :list_tools, 1)
    end

    test "list_skills/1 is exported" do
      assert function_exported?(GeminiEx, :list_skills, 1)
    end

    test "list_plugins/1 is exported" do
      assert function_exported?(GeminiEx, :list_plugins, 1)
    end

    test "list_mcp_servers/1 is exported" do
      assert function_exported?(GeminiEx, :list_mcp_servers, 1)
    end

    test "list_agents/1 is exported" do
      assert function_exported?(GeminiEx, :list_agents, 1)
    end

    test "cli_version/1 is exported" do
      assert function_exported?(GeminiEx, :cli_version, 1)
    end

    test "working_directory/1 is exported" do
      assert function_exported?(GeminiEx, :working_directory, 1)
    end

    test "output_style/1 is exported" do
      assert function_exported?(GeminiEx, :output_style, 1)
    end

    test "api_key_source/1 is exported" do
      assert function_exported?(GeminiEx, :api_key_source, 1)
    end

    test "active_betas/1 is exported" do
      assert function_exported?(GeminiEx, :active_betas, 1)
    end

    test "current_model/1 is exported" do
      assert function_exported?(GeminiEx, :current_model, 1)
    end

    test "current_permission_mode/1 is exported" do
      assert function_exported?(GeminiEx, :current_permission_mode, 1)
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

      todos = GeminiEx.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Task 1"
      assert hd(todos).status == :pending
    end

    test "filter_todos/2 filters by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed}
      ]

      result = GeminiEx.filter_todos(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "todo_summary/1 counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed},
        %{content: "C", status: :completed}
      ]

      summary = GeminiEx.todo_summary(todos)
      assert summary.pending == 1
      assert summary.completed == 2
      assert summary.total == 3
    end
  end

  describe "additional session control" do
    test "set_permission_mode/2 is exported" do
      assert function_exported?(GeminiEx, :set_permission_mode, 2)
    end

    test "send_control/3 is exported" do
      assert function_exported?(GeminiEx, :send_control, 3)
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

  defp wait_until_ready(session, attempts \\ 20)
  defp wait_until_ready(_session, 0), do: :timeout

  defp wait_until_ready(session, attempts) do
    case GeminiEx.health(session) do
      :ready ->
        :ok

      _ ->
        Process.sleep(50)
        wait_until_ready(session, attempts - 1)
    end
  end
end
