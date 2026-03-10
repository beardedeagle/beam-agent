defmodule ClaudeExTest do
  use ExUnit.Case, async: true

  @moduletag :claude_ex

  # Ensure module is loaded before function_exported? checks
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

  describe "with mock CLI" do
    setup do
      script_path = create_mock_cli()
      {:ok, session} = ClaudeEx.start_session(cli_path: script_path, session_id: "test-elixir-123")
      # Wait for initialization (system greeting + control_response handshake)
      Process.sleep(1500)

      on_exit(fn ->
        try do
          ClaudeEx.stop(session)
        catch
          _, _ -> :ok
        end

        File.rm(script_path)
      end)

      %{session: session, script_path: script_path}
    end

    test "query/3 returns all messages", %{session: session} do
      {:ok, messages} = ClaudeEx.query(session, "Hello")
      assert is_list(messages)
      assert length(messages) >= 1
      last = List.last(messages)
      assert last.type in [:result, :error]
    end

    test "stream!/3 returns lazy enumerable", %{session: session} do
      messages =
        ClaudeEx.stream!(session, "Hello")
        |> Enum.to_list()

      assert length(messages) >= 1

      # All messages should have a type
      for msg <- messages do
        assert Map.has_key?(msg, :type)
      end

      # Last message should be result
      last = List.last(messages)
      assert last.type in [:result, :error]
    end

    test "stream!/3 still works when the backend registry entry is missing", %{session: session} do
      :ok = :beam_agent_backend.unregister_session(session)

      messages =
        ClaudeEx.stream!(session, "Hello")
        |> Enum.to_list()

      assert length(messages) >= 1
      assert List.last(messages).type in [:result, :error]
    end

    test "stream/3 wraps in ok/error tuples", %{session: session} do
      results =
        ClaudeEx.stream(session, "Hello")
        |> Enum.to_list()

      assert length(results) >= 1

      for result <- results do
        assert match?({:ok, _}, result)
      end

      {:ok, last_msg} = List.last(results)
      assert last_msg.type in [:result, :error]
    end

    test "stream/3 still works when the backend registry entry is missing", %{session: session} do
      :ok = :beam_agent_backend.unregister_session(session)

      results =
        ClaudeEx.stream(session, "Hello")
        |> Enum.to_list()

      assert length(results) >= 1
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert match?({:ok, %{type: type}} when type in [:result, :error], List.last(results))
    end

    test "health returns :ready after init", %{session: session} do
      assert ClaudeEx.health(session) == :ready
    end

    test "stream!/3 with assistant content blocks", %{session: session} do
      # Extract text content from assistant message content_blocks
      blocks =
        ClaudeEx.stream!(session, "Hello")
        |> Stream.filter(&(&1.type == :assistant))
        |> Enum.flat_map(& &1.content_blocks)
        |> Enum.filter(&(&1.type == :text))

      assert length(blocks) >= 1
      assert Enum.all?(blocks, &is_binary(&1.text))
    end

    test "result message has enriched fields", %{session: session} do
      result =
        ClaudeEx.stream!(session, "Hello")
        |> Enum.filter(&(&1.type == :result))
        |> List.first()

      assert result != nil
      assert result.content == "Done!"
      assert result.duration_ms == 100
      assert result.num_turns == 1
      assert result.stop_reason == "end_turn"
      assert result.stop_reason_atom == :end_turn
    end

    test "result uses 'result' field when present", %{session: session} do
      result =
        ClaudeEx.stream!(session, "Hello")
        |> Enum.filter(&(&1.type == :result))
        |> List.first()

      # The mock CLI emits "result" field, not "content"
      assert result.content == "Done!"
    end

    test "session_info returns session data", %{session: session} do
      {:ok, info} = ClaudeEx.session_info(session)
      assert is_map(info)
      assert info.session_id == "test-elixir-123"
      assert is_map(info.system_info)
      assert info.system_info.model == "claude-sonnet-4-20250514"
      assert info.system_info.tools == ["Read", "Write", "Bash"]
    end

    test "supported_commands returns list", %{session: session} do
      {:ok, commands} = ClaudeEx.supported_commands(session)
      assert is_list(commands)
    end

    test "supported_models returns list", %{session: session} do
      {:ok, models} = ClaudeEx.supported_models(session)
      assert is_list(models)
    end

    test "supported_agents returns list", %{session: session} do
      {:ok, agents} = ClaudeEx.supported_agents(session)
      assert is_list(agents)
    end

    test "account_info returns map", %{session: session} do
      {:ok, account} = ClaudeEx.account_info(session)
      assert is_map(account)
    end

    test "uuid extracted from messages", %{session: session} do
      messages =
        ClaudeEx.stream!(session, "Hello")
        |> Enum.to_list()

      # At least one message should have a uuid
      has_uuid = Enum.any?(messages, &Map.has_key?(&1, :uuid))
      assert has_uuid
    end
  end

  describe "ClaudeEx.Session" do
    setup do
      script_path = create_mock_cli()
      {:ok, session} = ClaudeEx.start_session(cli_path: script_path, session_id: "test-elixir-123")
      Process.sleep(1500)

      on_exit(fn ->
        try do
          ClaudeEx.stop(session)
        catch
          _, _ -> :ok
        end

        File.rm(script_path)
      end)

      %{session: session}
    end

    test "send_query and receive_message low-level API", %{session: session} do
      {:ok, ref} = ClaudeEx.Session.send_query(session, "test")
      assert is_reference(ref)

      # Pull messages until result
      messages = pull_all(session, ref)
      assert length(messages) >= 1
      last = List.last(messages)
      assert last.type in [:result, :error]
    end

    test "session_info delegates correctly", %{session: session} do
      {:ok, info} = ClaudeEx.Session.session_info(session)
      assert is_map(info)
      assert Map.has_key?(info, :session_id)
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

      result = hook.callback.(%{event: :pre_tool_use})
      assert result == {:deny, "blocked"}
    end
  end

  describe "session store" do
    setup do
      tmp = "/tmp/claude_ex_store_test_#{:erlang.unique_integer([:positive])}"
      File.mkdir_p!(tmp <> "/projects/test-proj")

      # Write a mock session file (json:encode returns iodata, convert to binary)
      lines = [
        IO.iodata_to_binary(
          :json.encode(%{
            "type" => "system",
            "subtype" => "init",
            "content" => "ready",
            "model" => "claude-sonnet-4-20250514"
          })
        ),
        IO.iodata_to_binary(:json.encode(%{"type" => "user", "content" => "hello"}))
      ]

      File.write!(
        tmp <> "/projects/test-proj/sess-abc.jsonl",
        Enum.join(lines, "\n") <> "\n"
      )

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "list_native_sessions/1 finds session files", %{tmp: tmp} do
      {:ok, sessions} = ClaudeEx.list_native_sessions(config_dir: tmp)
      assert length(sessions) >= 1
      ids = Enum.map(sessions, & &1.session_id)
      assert "sess-abc" in ids
    end

    test "get_native_session_messages/2 parses transcript", %{tmp: tmp} do
      {:ok, messages} =
        ClaudeEx.get_native_session_messages("sess-abc",
          config_dir: tmp
        )

      assert length(messages) == 2
      [first | _] = messages
      assert first["type"] == "system"
    end

    test "get_native_session_messages/2 returns error for missing", %{tmp: tmp} do
      assert {:error, :not_found} =
               ClaudeEx.get_native_session_messages("nonexistent", config_dir: tmp)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp create_mock_cli do
    path = "/tmp/mock_claude_ex_#{:erlang.unique_integer([:positive])}"

    script = """
    #!/bin/sh
    # Emit system greeting with init metadata
    echo '{"type":"system","subtype":"init","content":"ready","tools":["Read","Write","Bash"],"model":"claude-sonnet-4-20250514","permissionMode":"default","claude_code_version":"2.1.66"}'
    # Read and respond to protocol messages
    while IFS= read -r line; do
      case "$line" in
        *control_request*)
          echo '{"type":"control_response","response":{"subtype":"success","session_id":"test-elixir-123"}}'
          ;;
        *user*)
          echo '{"type":"assistant","content":[{"type":"text","text":"Hello from Claude"},{"type":"text","text":"Working on it..."}],"uuid":"msg-uuid-ex-001"}'
          echo '{"type":"result","result":"Done!","duration_ms":100,"num_turns":1,"stop_reason":"end_turn","is_error":false,"subtype":"success","uuid":"msg-uuid-ex-002"}'
          ;;
        *)
          ;;
      esac
    done
    """

    File.write!(path, script)
    System.cmd("chmod", ["+x", path])
    path
  end

  defp pull_all(session, ref) do
    case ClaudeEx.Session.receive_message(session, ref, 5_000) do
      {:ok, %{type: type} = msg} when type in [:result, :error] -> [msg]
      {:ok, msg} -> [msg | pull_all(session, ref)]
      {:error, :complete} -> []
      {:error, reason} -> raise "Unexpected error: #{inspect(reason)}"
    end
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant message with content_blocks inline" do
      messages = [
        %{type: :system, content: "init"},
        %{
          type: :assistant,
          session_id: "s1",
          content_blocks: [
            %{type: :thinking, thinking: "hmm"},
            %{type: :text, text: "hello"}
          ]
        },
        %{type: :result, content: ""}
      ]

      flat = ClaudeEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:system, :thinking, :text, :result]
      # Context propagated
      assert Enum.at(flat, 1).session_id == "s1"
    end

    test "passes through already-flat messages unchanged" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :result, content: ""}
      ]

      assert ClaudeEx.normalize_messages(messages) == messages
    end

    test "returns empty list for empty input" do
      assert ClaudeEx.normalize_messages([]) == []
    end
  end

  describe "flatten_assistant/1" do
    test "expands content_blocks into individual messages" do
      msg = %{
        type: :assistant,
        content_blocks: [
          %{type: :text, text: "hi"},
          %{type: :tool_use, id: "tu_1", name: "bash", input: %{}}
        ]
      }

      flat = ClaudeEx.flatten_assistant(msg)
      assert length(flat) == 2
      assert Enum.at(flat, 0).type == :text
      assert Enum.at(flat, 1).type == :tool_use
    end

    test "non-assistant passes through" do
      msg = %{type: :text, content: "hello"}
      assert ClaudeEx.flatten_assistant(msg) == [msg]
    end
  end

  describe "messages_to_blocks/1" do
    test "converts flat messages to content_blocks" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :thinking, content: "hmm"}
      ]

      blocks = ClaudeEx.messages_to_blocks(messages)
      assert length(blocks) == 2
      assert Enum.at(blocks, 0).type == :text
      assert Enum.at(blocks, 0).text == "hello"
      assert Enum.at(blocks, 1).type == :thinking
    end
  end

  describe "block_to_message/1 and message_to_block/1" do
    test "round-trip text" do
      block = %{type: :text, text: "hello"}
      assert block == ClaudeEx.message_to_block(ClaudeEx.block_to_message(block))
    end

    test "round-trip tool_use" do
      block = %{type: :tool_use, id: "tu_1", name: "bash", input: %{}}
      assert block == ClaudeEx.message_to_block(ClaudeEx.block_to_message(block))
    end
  end

  # ── System Init Convenience Accessors ──────────────────────────────

  describe "system init accessors" do
    test "list_tools/1 is exported" do
      assert function_exported?(ClaudeEx, :list_tools, 1)
    end

    test "list_skills/1 is exported" do
      assert function_exported?(ClaudeEx, :list_skills, 1)
    end

    test "list_plugins/1 is exported" do
      assert function_exported?(ClaudeEx, :list_plugins, 1)
    end

    test "list_mcp_servers/1 is exported" do
      assert function_exported?(ClaudeEx, :list_mcp_servers, 1)
    end

    test "list_agents/1 is exported" do
      assert function_exported?(ClaudeEx, :list_agents, 1)
    end

    test "cli_version/1 is exported" do
      assert function_exported?(ClaudeEx, :cli_version, 1)
    end

    test "working_directory/1 is exported" do
      assert function_exported?(ClaudeEx, :working_directory, 1)
    end

    test "output_style/1 is exported" do
      assert function_exported?(ClaudeEx, :output_style, 1)
    end

    test "api_key_source/1 is exported" do
      assert function_exported?(ClaudeEx, :api_key_source, 1)
    end

    test "active_betas/1 is exported" do
      assert function_exported?(ClaudeEx, :active_betas, 1)
    end

    test "current_model/1 is exported" do
      assert function_exported?(ClaudeEx, :current_model, 1)
    end

    test "current_permission_mode/1 is exported" do
      assert function_exported?(ClaudeEx, :current_permission_mode, 1)
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

      todos = ClaudeEx.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Task 1"
      assert hd(todos).status == :pending
    end

    test "filter_todos/2 filters by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed}
      ]

      result = ClaudeEx.filter_todos(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "todo_summary/1 counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :completed},
        %{content: "C", status: :completed}
      ]

      summary = ClaudeEx.todo_summary(todos)
      assert summary.pending == 1
      assert summary.completed == 2
      assert summary.total == 3
    end
  end

  # ── Additional Session Control ─────────────────────────────────────

  describe "additional session control" do
    test "interrupt/1 is exported" do
      assert function_exported?(ClaudeEx, :interrupt, 1)
    end

    test "send_control/3 is exported" do
      assert function_exported?(ClaudeEx, :send_control, 3)
    end
  end
end
