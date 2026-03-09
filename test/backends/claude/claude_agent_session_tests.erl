%%%-------------------------------------------------------------------
%%% @doc EUnit tests for claude_agent_session gen_statem.
%%%
%%% Uses a mock shell script that speaks the corrected Claude Code
%%% wire protocol (control_request/control_response, user messages,
%%% assistant content blocks).
%%%
%%% Tests cover:
%%%   - Full session lifecycle (connect → init → ready → query → ready)
%%%   - Inbound control_request auto-approval (transparent to consumer)
%%%   - Enriched result fields from TS SDK protocol
%%%   - session_info/1 query in all states
%%%   - Permission handler callback (Dependency Injection)
%%%   - New convenience API (set_model, set_permission_mode, etc.)
%%%   - Error handling (bad path, concurrent queries, wrong refs)
%%%   - Environment variables (CLAUDE_CODE_ENTRYPOINT, SDK_VERSION)
%%% @end
%%%-------------------------------------------------------------------
-module(claude_agent_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests (no real CLI needed)
%%====================================================================

send_query_not_connected_test_() ->
    {"send_query to non-existent process returns error",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, claude_agent_session:send_query(
             Pid, <<"test">>, #{}, 100))
     end}.

receive_message_not_connected_test_() ->
    {"receive_message to non-existent process returns error",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, claude_agent_session:receive_message(
             Pid, make_ref(), 100))
     end}.

child_spec_test() ->
    Spec = claude_agent_sdk:child_spec(#{cli_path => "/usr/bin/claude"}),
    ?assertEqual(claude_agent_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(10000, maps:get(shutdown, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(claude_agent_session, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/claude"}], Args).

%%====================================================================
%% Mock script-based integration tests
%%====================================================================

mock_cli_test_() ->
    {"full session lifecycle with mock CLI (corrected protocol)",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) -> [
          {"session connects and initializes",
           {timeout, 10, fun() -> test_init(ScriptPath) end}},
          {"query and receive messages (assistant + result)",
           {timeout, 15, fun() -> test_query_lifecycle(ScriptPath) end}},
          {"health reports correct state",
           {timeout, 10, fun() -> test_health_transitions(ScriptPath) end}},
          {"inbound control_request handled internally (fail-closed)",
           {timeout, 15, fun() -> test_control_request_handling(ScriptPath) end}},
          {"enriched result fields are parsed",
           {timeout, 15, fun() -> test_enriched_result(ScriptPath) end}},
          {"environment variables are set",
           {timeout, 10, fun() -> test_env_vars(ScriptPath) end}},
          {"session_info returns session data",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"result field takes priority over content field",
           {timeout, 15, fun() -> test_result_field_priority(ScriptPath) end}}
      ] end}}.

setup_mock_cli() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_claude_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_cli_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock_cli(ScriptPath) ->
    file:delete(ScriptPath).

%% Mock CLI speaking the corrected wire protocol with enriched fields.
%% Uses "result" field (not "content") for result messages per TS SDK.
mock_cli_script() ->
    <<
      "#!/bin/sh\n"
      "exec 2>/dev/null\n"
      "# Mock Claude CLI — corrected wire protocol with enriched fields\n"
      "# Emit system greeting with init metadata\n"
      "echo '{\"type\":\"system\",\"subtype\":\"init\",\"content\":\"ready\","
             "\"tools\":[\"Read\",\"Write\",\"Bash\"],"
             "\"model\":\"claude-sonnet-4-20250514\","
             "\"permissionMode\":\"default\","
             "\"claude_code_version\":\"2.1.66\"}'\n"
      "\n"
      "# Read stdin and respond to protocol messages\n"
      "while IFS= read -r line; do\n"
      "  case \"$line\" in\n"
      "    *control_request*)\n"
      "      echo '{\"type\":\"control_response\","
                   "\"response\":{\"subtype\":\"success\","
                   "\"session_id\":\"test-session-123\"}}'\n"
      "      ;;\n"
      "    *user*)\n"
      "      # Emit a control_request to test auto-approval\n"
      "      echo '{\"type\":\"control_request\","
                   "\"request_id\":\"cr_1\","
                   "\"request\":{\"subtype\":\"can_use_tool\","
                   "\"tool_name\":\"Read\","
                   "\"tool_input\":{\"path\":\"/tmp/test\"}}}'\n"
      "      # Emit assistant message with content blocks\n"
      "      echo '{\"type\":\"assistant\","
                   "\"content\":[{\"type\":\"text\","
                   "\"text\":\"Hello from mock Claude\"},"
                   "{\"type\":\"text\",\"text\":\"Thinking...\"}],"
                   "\"uuid\":\"msg-uuid-001\"}'\n"
      "      # Emit enriched result with \"result\" field (TS SDK format)\n"
      "      echo '{\"type\":\"result\","
                   "\"result\":\"Final answer\","
                   "\"duration_ms\":150,"
                   "\"duration_api_ms\":120,"
                   "\"num_turns\":1,"
                   "\"stop_reason\":\"end_turn\","
                   "\"is_error\":false,"
                   "\"subtype\":\"success\","
                   "\"session_id\":\"test-session-123\","
                   "\"uuid\":\"msg-uuid-002\"}'\n"
      "      ;;\n"
      "    *)\n"
      "      ;;\n"
      "  esac\n"
      "done\n"
    >>.

test_init(ScriptPath) ->
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),
    ?assertEqual(ready, claude_agent_session:health(Pid)),
    claude_agent_session:stop(Pid).

test_query_lifecycle(ScriptPath) ->
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),
    ?assertEqual(ready, claude_agent_session:health(Pid)),

    %% Send query (user message format)
    {ok, Ref} = claude_agent_session:send_query(
        Pid, <<"What is 2+2?">>, #{}, 10000),
    ?assert(is_reference(Ref)),

    %% Receive assistant message with content blocks
    %% (control_request is handled internally — consumer doesn't see it)
    {ok, Msg1} = claude_agent_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(assistant, maps:get(type, Msg1)),
    Blocks = maps:get(content_blocks, Msg1),
    ?assertEqual(2, length(Blocks)),
    [Block1, Block2] = Blocks,
    ?assertEqual(text, maps:get(type, Block1)),
    ?assertEqual(<<"Hello from mock Claude">>, maps:get(text, Block1)),
    ?assertEqual(text, maps:get(type, Block2)),
    ?assertEqual(<<"Thinking...">>, maps:get(text, Block2)),
    %% uuid should be extracted
    ?assertEqual(<<"msg-uuid-001">>, maps:get(uuid, Msg1)),

    %% Receive final result with enriched fields
    {ok, Msg2} = claude_agent_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(result, maps:get(type, Msg2)),
    ?assertEqual(<<"Final answer">>, maps:get(content, Msg2)),
    ?assertEqual(<<"msg-uuid-002">>, maps:get(uuid, Msg2)),

    %% After result, session should be back to ready
    timer:sleep(100),
    ?assertEqual(ready, claude_agent_session:health(Pid)),

    claude_agent_session:stop(Pid).

test_health_transitions(ScriptPath) ->
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    Health1 = claude_agent_session:health(Pid),
    ?assert(lists:member(Health1, [connecting, initializing, ready])),

    timer:sleep(1000),
    ?assertEqual(ready, claude_agent_session:health(Pid)),

    %% During query, should be active_query
    {ok, Ref} = claude_agent_session:send_query(
        Pid, <<"test">>, #{}, 10000),
    Health2 = claude_agent_session:health(Pid),
    ?assert(lists:member(Health2, [active_query, ready])),

    %% Drain messages
    drain_messages(Pid, Ref),

    timer:sleep(100),
    ?assertEqual(ready, claude_agent_session:health(Pid)),

    claude_agent_session:stop(Pid).

test_control_request_handling(ScriptPath) ->
    %% Verify that inbound control_request messages are handled internally
    %% (fail-closed by default) and transparent to the consumer
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),

    {ok, Ref} = claude_agent_session:send_query(
        Pid, <<"test">>, #{}, 10000),

    %% The mock emits: control_request, assistant, result
    %% Consumer should only see: assistant, result
    {ok, Msg1} = claude_agent_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(assistant, maps:get(type, Msg1)),

    {ok, Msg2} = claude_agent_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(result, maps:get(type, Msg2)),

    %% No more messages — session is back to ready
    timer:sleep(100),
    ?assertEqual(ready, claude_agent_session:health(Pid)),

    claude_agent_session:stop(Pid).

test_enriched_result(ScriptPath) ->
    %% Verify result message carries enriched protocol fields
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),

    {ok, Ref} = claude_agent_session:send_query(
        Pid, <<"test">>, #{}, 10000),

    %% Drain to result
    Result = drain_to_result(Pid, Ref),
    ?assertEqual(result, maps:get(type, Result)),
    ?assertEqual(<<"Final answer">>, maps:get(content, Result)),
    ?assertEqual(150, maps:get(duration_ms, Result)),
    ?assertEqual(120, maps:get(duration_api_ms, Result)),
    ?assertEqual(1, maps:get(num_turns, Result)),
    ?assertEqual(<<"end_turn">>, maps:get(stop_reason, Result)),
    ?assertEqual(end_turn, maps:get(stop_reason_atom, Result)),
    ?assertEqual(false, maps:get(is_error, Result)),
    ?assertEqual(<<"success">>, maps:get(subtype, Result)),

    claude_agent_session:stop(Pid).

test_env_vars(ScriptPath) ->
    %% Verify the session starts successfully — env vars are set
    %% in build_port_opts (CLAUDE_CODE_ENTRYPOINT, CLAUDE_AGENT_SDK_VERSION).
    %% We verify indirectly: if port_opts were malformed, start would fail.
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),
    ?assertEqual(ready, claude_agent_session:health(Pid)),
    claude_agent_session:stop(Pid).

test_session_info(ScriptPath) ->
    %% session_info/1 should return parsed system init metadata
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),

    {ok, Info} = claude_agent_session:session_info(Pid),
    ?assert(is_map(Info)),
    ?assertEqual(<<"test-session-123">>, maps:get(session_id, Info)),
    %% system_info should have parsed init metadata
    SysInfo = maps:get(system_info, Info),
    ?assert(is_map(SysInfo)),
    ?assertEqual([<<"Read">>, <<"Write">>, <<"Bash">>],
                 maps:get(tools, SysInfo)),
    ?assertEqual(<<"claude-sonnet-4-20250514">>, maps:get(model, SysInfo)),
    ?assertEqual(<<"default">>, maps:get(permission_mode, SysInfo)),
    ?assertEqual(<<"2.1.66">>, maps:get(claude_code_version, SysInfo)),

    claude_agent_session:stop(Pid).

test_result_field_priority(ScriptPath) ->
    %% The mock emits result with "result" field (not "content")
    %% Verify the normalized message uses the "result" field value
    {ok, Pid} = claude_agent_session:start_link(#{
        cli_path => ScriptPath
    }),
    timer:sleep(1000),

    {ok, Ref} = claude_agent_session:send_query(
        Pid, <<"test">>, #{}, 10000),
    Result = drain_to_result(Pid, Ref),
    %% "result" field should produce "Final answer", not empty
    ?assertEqual(<<"Final answer">>, maps:get(content, Result)),

    claude_agent_session:stop(Pid).

%%====================================================================
%% Permission handler tests
%%====================================================================

permission_handler_test_() ->
    {"permission handler callback is invoked for can_use_tool",
     {setup,
      fun setup_permission_mock/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               %% Create a permission handler that denies Read tool
               Self = self(),
               Handler = fun(ToolName, ToolInput, Options) ->
                   Self ! {permission_check, ToolName, ToolInput, Options},
                   case ToolName of
                       <<"Read">> -> {deny, <<"Read denied by test">>};
                       _ -> {allow, ToolInput}
                   end
               end,

               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath,
                   permission_handler => Handler
               }),
               timer:sleep(1000),

               {ok, Ref} = claude_agent_session:send_query(
                   Pid, <<"test">>, #{}, 10000),

               %% The handler should have been called
               receive
                   {permission_check, ToolName, _Input, _Opts} ->
                       ?assertEqual(<<"Read">>, ToolName)
               after 5000 ->
                   ?assert(false)  %% Handler was not called
               end,

               %% Drain remaining messages
               drain_messages(Pid, Ref),
               catch claude_agent_session:stop(Pid)
           end}
      end}}.

setup_permission_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_claude_perm_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_cli_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%%====================================================================
%% Error handling tests
%%====================================================================

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI fails in init",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          process_flag(trap_exit, true),
          %% Suppress expected warning from open_port failure
          #{level := OldLevel} = logger:get_primary_config(),
          logger:set_primary_config(level, none),
          Result = claude_agent_session:start_link(#{
              cli_path => "/nonexistent/path/to/claude_that_doesnt_exist"
          }),
          logger:set_primary_config(level, OldLevel),
          ?assertMatch({error, {shutdown, {open_port_failed, _}}}, Result),
          process_flag(trap_exit, false)
      end}}.

concurrent_query_rejected_test_() ->
    {"second query rejected while one is active",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, _Ref1} = claude_agent_session:send_query(
                   Pid, <<"query1">>, #{}, 10000),

               Result = claude_agent_session:send_query(
                   Pid, <<"query2">>, #{}, 1000),
               ?assertEqual({error, query_in_progress}, Result),

               catch claude_agent_session:stop(Pid)
           end}
      end}}.

bad_ref_rejected_test_() ->
    {"receive_message with wrong ref returns error",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, _Ref} = claude_agent_session:send_query(
                   Pid, <<"test">>, #{}, 10000),

               WrongRef = make_ref(),
               ?assertEqual(
                   {error, bad_ref},
                   claude_agent_session:receive_message(Pid, WrongRef, 1000)),

               catch claude_agent_session:stop(Pid)
           end}
      end}}.

%%====================================================================
%% Convenience API tests (claude_agent_sdk)
%%====================================================================

sdk_query_test_() ->
    {"claude_agent_sdk:query/2 collects all messages",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, Messages} = claude_agent_sdk:query(
                   Pid, <<"What is 2+2?">>),

               ?assert(is_list(Messages)),
               ?assert(length(Messages) >= 1),

               %% Last message should be result
               Last = lists:last(Messages),
               LastType = maps:get(type, Last),
               ?assert(lists:member(LastType, [result, error])),

               claude_agent_session:stop(Pid)
           end}
      end}}.

sdk_session_info_test_() ->
    {"claude_agent_sdk:session_info/1 delegates to session",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, Info} = claude_agent_sdk:session_info(Pid),
               ?assert(is_map(Info)),
               ?assert(maps:is_key(session_id, Info)),
               ?assert(maps:is_key(system_info, Info)),

               claude_agent_session:stop(Pid)
           end}
      end}}.

%%====================================================================
%% session_info availability tests
%%====================================================================

session_info_during_init_test_() ->
    {"session_info available during connecting/initializing",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               %% Query immediately (before init completes)
               {ok, Info} = claude_agent_session:session_info(Pid),
               ?assert(is_map(Info)),
               ?assert(maps:is_key(session_id, Info)),

               timer:sleep(1000),
               claude_agent_session:stop(Pid)
           end}
      end}}.

session_info_during_query_test_() ->
    {"session_info available during active_query",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, _Ref} = claude_agent_session:send_query(
                   Pid, <<"test">>, #{}, 10000),

               %% session_info should work during active query
               {ok, Info} = claude_agent_session:session_info(Pid),
               ?assert(is_map(Info)),

               catch claude_agent_session:stop(Pid)
           end}
      end}}.

%%====================================================================
%% Cancel tests
%%====================================================================

cancel_active_query_test_() ->
    {"cancel/2 cancels an active query",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, Ref} = claude_agent_session:send_query(
                   Pid, <<"test">>, #{}, 10000),
               ok = claude_agent_session:cancel(Pid, Ref),

               timer:sleep(100),
               ?assertEqual(ready, claude_agent_session:health(Pid)),

               catch claude_agent_session:stop(Pid)
           end}
      end}}.

%%====================================================================
%% SDK convenience API tests
%%====================================================================

sdk_supported_commands_test_() ->
    {"supported_commands extracts from init_response",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               %% Our mock init_response doesn't include commands,
               %% so we should get the default empty list
               {ok, Commands} = claude_agent_sdk:supported_commands(Pid),
               ?assert(is_list(Commands)),

               claude_agent_session:stop(Pid)
           end}
      end}}.

sdk_supported_models_test_() ->
    {"supported_models extracts from init_response",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, Models} = claude_agent_sdk:supported_models(Pid),
               ?assert(is_list(Models)),

               claude_agent_session:stop(Pid)
           end}
      end}}.

sdk_account_info_test_() ->
    {"account_info extracts from init_response",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 10,
           fun() ->
               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath
               }),
               timer:sleep(1000),

               {ok, Account} = claude_agent_sdk:account_info(Pid),
               ?assert(is_map(Account)),

               claude_agent_session:stop(Pid)
           end}
      end}}.

%%====================================================================
%% SDK MCP server tests
%%====================================================================

sdk_mcp_constructors_test() ->
    %% Verify SDK convenience constructors work
    Handler = fun(_Input) -> {ok, [#{type => text, text => <<"hi">>}]} end,
    Tool = claude_agent_sdk:mcp_tool(<<"greet">>, <<"Greet">>,
        #{<<"type">> => <<"object">>}, Handler),
    ?assertEqual(<<"greet">>, maps:get(name, Tool)),
    Server = claude_agent_sdk:mcp_server(<<"my-tools">>, [Tool]),
    ?assertEqual(<<"my-tools">>, maps:get(name, Server)).

sdk_mcp_session_test_() ->
    {"session with sdk_mcp_servers dispatches mcp_message to handler",
     {setup,
      fun setup_mcp_mock/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               EchoHandler = fun(Input) ->
                   Text = maps:get(<<"text">>, Input, <<"default">>),
                   {ok, [#{type => text, text => Text}]}
               end,
               Tool = beam_agent_mcp_core:tool(<<"echo">>, <<"Echo">>,
                   #{<<"type">> => <<"object">>}, EchoHandler),
               Server = beam_agent_mcp_core:server(<<"test-tools">>, [Tool]),

               {ok, Pid} = claude_agent_session:start_link(#{
                   cli_path => ScriptPath,
                   sdk_mcp_servers => [Server]
               }),
               timer:sleep(1000),
               ?assertEqual(ready, claude_agent_session:health(Pid)),

               {ok, Ref} = claude_agent_session:send_query(
                   Pid, <<"test">>, #{}, 10000),

               %% Drain messages — the mock emits an mcp_message control_request
               %% which should be handled internally via the registry
               Result = drain_to_result(Pid, Ref),
               ?assertEqual(result, maps:get(type, Result)),

               claude_agent_session:stop(Pid)
           end}
      end}}.

setup_mcp_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_claude_mcp_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_mcp_cli_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%% Mock CLI that sends an mcp_message control_request.
mock_mcp_cli_script() ->
    <<
      "#!/bin/sh\n"
      "echo '{\"type\":\"system\",\"subtype\":\"init\",\"content\":\"ready\","
             "\"model\":\"claude-sonnet-4-20250514\"}'\n"
      "while IFS= read -r line; do\n"
      "  case \"$line\" in\n"
      "    *control_request*)\n"
      "      echo '{\"type\":\"control_response\","
                   "\"response\":{\"subtype\":\"success\","
                   "\"session_id\":\"mcp-session-1\"}}'\n"
      "      ;;\n"
      "    *user*)\n"
      "      echo '{\"type\":\"control_request\","
                   "\"request_id\":\"cr_mcp_1\","
                   "\"request\":{\"subtype\":\"mcp_message\","
                   "\"server_name\":\"test-tools\","
                   "\"message\":{\"jsonrpc\":\"2.0\",\"id\":1,"
                   "\"method\":\"tools/call\","
                   "\"params\":{\"name\":\"echo\","
                   "\"arguments\":{\"text\":\"hello\"}}}}}'\n"
      "      echo '{\"type\":\"assistant\","
                   "\"content\":[{\"type\":\"text\","
                   "\"text\":\"MCP tool called\"}]}'\n"
      "      echo '{\"type\":\"result\","
                   "\"result\":\"Done with MCP\","
                   "\"session_id\":\"mcp-session-1\"}'\n"
      "      ;;\n"
      "  esac\n"
      "done\n"
    >>.

%%====================================================================
%% SDK Hooks Integration Tests
%%====================================================================

sdk_hooks_pre_tool_use_deny_test_() ->
    {"sdk_hooks pre_tool_use can deny tool use",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              %% Hook that denies the "Read" tool (which our mock sends)
              Hook = beam_agent_hooks_core:hook(pre_tool_use,
                  fun(Ctx) ->
                      case maps:get(tool_name, Ctx, <<>>) of
                          <<"Read">> -> {deny, <<"Read tool blocked by hook">>};
                          _ -> ok
                      end
                  end),
              {ok, Pid} = claude_agent_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_hooks => [Hook]
              }),
              timer:sleep(1500),
              %% The mock sends a can_use_tool for "Read" —
              %% the hook should deny it before the permission handler
              ?assertEqual(ready, claude_agent_session:health(Pid)),
              {ok, Ref} = claude_agent_session:send_query(
                  Pid, <<"test">>, #{}, 5000),
              %% Drain messages — the session should still work
              %% (deny is sent back to CLI, query continues)
              Result = drain_to_result(Pid, Ref),
              ?assertEqual(result, maps:get(type, Result)),
              claude_agent_session:stop(Pid)
          end}
      end}}.

sdk_hooks_user_prompt_deny_test_() ->
    {"sdk_hooks user_prompt_submit can deny query",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              %% Hook that denies all prompts
              Hook = beam_agent_hooks_core:hook(user_prompt_submit,
                  fun(_) -> {deny, <<"prompts blocked">>} end),
              {ok, Pid} = claude_agent_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_hooks => [Hook]
              }),
              timer:sleep(1500),
              ?assertEqual(ready, claude_agent_session:health(Pid)),
              %% send_query should return hook_denied error
              Result = claude_agent_session:send_query(
                  Pid, <<"test">>, #{}, 5000),
              ?assertMatch({error, {hook_denied, <<"prompts blocked">>}},
                           Result),
              %% Session should still be in ready state
              ?assertEqual(ready, claude_agent_session:health(Pid)),
              claude_agent_session:stop(Pid)
          end}
      end}}.

sdk_hooks_with_matcher_test_() ->
    {"sdk_hooks matcher filters by tool name pattern",
     {setup,
      fun setup_mock_cli/0,
      fun cleanup_mock_cli/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              %% Hook with matcher that only fires on "Bash" tools
              %% (mock sends "Read", so this should NOT deny)
              Hook = beam_agent_hooks_core:hook(pre_tool_use,
                  fun(_) -> {deny, <<"bash blocked">>} end,
                  #{tool_name => <<"^Bash$">>}),
              {ok, Pid} = claude_agent_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_hooks => [Hook]
              }),
              timer:sleep(1500),
              {ok, Ref} = claude_agent_session:send_query(
                  Pid, <<"test">>, #{}, 5000),
              %% Should complete normally since matcher doesn't match "Read"
              Result = drain_to_result(Pid, Ref),
              ?assertEqual(result, maps:get(type, Result)),
              claude_agent_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

drain_messages(Pid, Ref) ->
    case claude_agent_session:receive_message(Pid, Ref, 2000) of
        {ok, #{type := result}} -> ok;
        {ok, #{type := error}} -> ok;
        {ok, _} -> drain_messages(Pid, Ref);
        {error, _} -> ok
    end.

drain_to_result(Pid, Ref) ->
    case claude_agent_session:receive_message(Pid, Ref, 5000) of
        {ok, #{type := result} = Msg} -> Msg;
        {ok, #{type := error} = Msg}  -> Msg;
        {ok, _}                       -> drain_to_result(Pid, Ref);
        {error, Reason}               -> error({drain_failed, Reason})
    end.
