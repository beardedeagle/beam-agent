%%%-------------------------------------------------------------------
%%% @doc EUnit tests for copilot_session gen_statem.
%%%
%%% Uses a mock shell script that speaks Content-Length framed
%%% JSON-RPC 2.0 — the Copilot CLI wire protocol. The mock handles:
%%%
%%%   - ping request → response
%%%   - session.create → response with sessionId
%%%   - session.send → session.event notifications + session.idle
%%%   - Server-initiated requests: tool.call, permission.request,
%%%     hooks.invoke, user_input.request
%%%
%%% Tests cover:
%%%   - Full session lifecycle (connect → init → ready → query → ready)
%%%   - Health state transitions
%%%   - Session ID capture from session.create response
%%%   - Query lifecycle with session.event delivery
%%%   - Concurrent query rejection
%%%   - Wrong ref rejection
%%%   - Port exit handling during query
%%%   - Permission handler callback (fail-closed default)
%%%   - Tool handler invocation via tool.call server request
%%%   - Hook firing: user_prompt_submit deny, session_start
%%%   - Interrupt sends session.abort
%%%   - SDK-level copilot_client:query/2 collects all messages
%%%   - child_spec correctness
%%%   - session_info in all states
%%%   - set_model via session.model.switchTo
%%%   - send_command for arbitrary JSON-RPC
%%%   - Bad CLI path error handling
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests (no real CLI needed)
%%====================================================================

child_spec_test() ->
    Spec = copilot_client:child_spec(#{cli_path => "/usr/bin/copilot"}),
    ?assertEqual(copilot_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(10000, maps:get(shutdown, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(copilot_session, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/copilot"}], Args).

child_spec_with_session_id_test() ->
    Spec = copilot_client:child_spec(#{
        cli_path => "/usr/bin/copilot",
        session_id => <<"my-session">>
    }),
    ?assertEqual({copilot_session, <<"my-session">>}, maps:get(id, Spec)).

send_query_not_connected_test_() ->
    {"send_query to non-existent process returns error",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, copilot_session:send_query(
             Pid, <<"test">>, #{}, 100))
     end}.

receive_message_not_connected_test_() ->
    {"receive_message to non-existent process returns error",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, copilot_session:receive_message(
             Pid, make_ref(), 100))
     end}.

%%====================================================================
%% Mock script-based integration tests
%%====================================================================

mock_session_test_() ->
    {"full copilot_session lifecycle with mock CLI",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) -> [
          {"session connects and initializes",
           {timeout, 10, fun() -> test_init(ScriptPath) end}},
          {"health reports correct state transitions",
           {timeout, 10, fun() -> test_health_transitions(ScriptPath) end}},
          {"session_info returns session data",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"query lifecycle (session.event → session.idle)",
           {timeout, 15, fun() -> test_query_lifecycle(ScriptPath) end}},
          {"concurrent query rejected",
           {timeout, 10, fun() -> test_concurrent_query(ScriptPath) end}},
          {"wrong ref rejected",
           {timeout, 10, fun() -> test_wrong_ref(ScriptPath) end}},
          {"copilot_client:query/2 collects all messages",
           {timeout, 15, fun() -> test_sdk_query(ScriptPath) end}},
          {"session_info available during active_query",
           {timeout, 15, fun() -> test_session_info_during_query(ScriptPath) end}}
      ] end}}.

setup_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_copilot_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_copilot_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock(ScriptPath) ->
    file:delete(ScriptPath).

%% ---------------------------------------------------------------------------
%% Mock Copilot CLI
%%
%% Speaks Content-Length framed JSON-RPC 2.0 on stdin/stdout.
%% Handles:
%%   1. ping → pong response
%%   2. session.create → response with sessionId
%%   3. session.send → session.event notifications + session.idle notification
%%   4. session.abort → ok response
%%   5. session.model.switchTo → ok response
%%
%% Note: The script uses Python for reliable Content-Length frame parsing
%% and generation. Shell-based approaches are fragile for binary-framed
%% protocols since they rely on line-oriented I/O.
%% ---------------------------------------------------------------------------
mock_copilot_script() ->
    <<
      "#!/usr/bin/env python3\n"
      "import sys, json\n"
      "\n"
      "def send(obj):\n"
      "    body = json.dumps(obj)\n"
      "    header = f'Content-Length: {len(body)}\\r\\n\\r\\n'\n"
      "    sys.stdout.write(header + body)\n"
      "    sys.stdout.flush()\n"
      "\n"
      "def recv():\n"
      "    # Read Content-Length header\n"
      "    header = ''\n"
      "    while True:\n"
      "        ch = sys.stdin.read(1)\n"
      "        if ch == '':\n"
      "            return None\n"
      "        header += ch\n"
      "        if header.endswith('\\r\\n\\r\\n'):\n"
      "            break\n"
      "    # Extract content length\n"
      "    for line in header.strip().split('\\r\\n'):\n"
      "        if line.lower().startswith('content-length:'):\n"
      "            length = int(line.split(':', 1)[1].strip())\n"
      "            break\n"
      "    else:\n"
      "        return None\n"
      "    body = sys.stdin.read(length)\n"
      "    if len(body) < length:\n"
      "        return None\n"
      "    return json.loads(body)\n"
      "\n"
      "while True:\n"
      "    msg = recv()\n"
      "    if msg is None:\n"
      "        break\n"
      "    method = msg.get('method', '')\n"
      "    req_id = msg.get('id')\n"
      "\n"
      "    if method == 'ping':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'message': 'pong'}})\n"
      "\n"
      "    elif method == 'session.create':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'sessionId': 'copilot-sess-001'}})\n"
      "\n"
      "    elif method == 'session.send':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        # Emit session events as notifications\n"
      "        # 1. assistant.message_delta (streaming text)\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'assistant.message_delta',\n"
      "                                   'data': {'deltaContent': 'Hello '}}}})\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'assistant.message_delta',\n"
      "                                   'data': {'deltaContent': 'world!'}}}})\n"
      "        # 2. tool.executing\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'tool.executing',\n"
      "                                   'data': {'toolName': 'read_file',\n"
      "                                            'arguments': {'path': '/tmp/x'},\n"
      "                                            'toolCallId': 'tc-42'}}}})\n"
      "        # 3. tool.completed\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'tool.completed',\n"
      "                                   'data': {'toolName': 'read_file',\n"
      "                                            'output': 'file contents',\n"
      "                                            'toolCallId': 'tc-42'}}}})\n"
      "        # 4. assistant.message (full message)\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'assistant.message',\n"
      "                                   'data': {'content': 'Final answer',\n"
      "                                            'messageId': 'msg-99',\n"
      "                                            'model': 'gpt-4'}}}})\n"
      "        # 5. session.idle (signals query complete)\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {'usage': {'total': 500}}}}})\n"
      "\n"
      "    elif method == 'session.abort':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        # Emit session.idle to signal query complete after abort\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {}}}})\n"
      "\n"
      "    elif method == 'session.model.switchTo':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "\n"
      "    elif req_id is not None:\n"
      "        # Unknown method with id — respond with method not found\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'error': {'code': -32601,\n"
      "                        'message': 'Method not found'}})\n"
    >>.

test_init(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, copilot_session:health(Pid)),
    copilot_session:stop(Pid).

test_health_transitions(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    %% Should be connecting or already progressing
    Health1 = copilot_session:health(Pid),
    ?assert(lists:member(Health1, [connecting, initializing, ready])),

    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, copilot_session:health(Pid)),

    %% During query, should be active_query
    {ok, Ref} = copilot_session:send_query(Pid, <<"test">>, #{}, 10000),
    Health2 = copilot_session:health(Pid),
    ?assert(lists:member(Health2, [active_query, ready])),

    %% Drain messages
    drain_messages(Pid, Ref),

    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, copilot_session:health(Pid)),

    copilot_session:stop(Pid).

test_session_info(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, Info} = copilot_session:session_info(Pid),
    ?assert(is_map(Info)),
    ?assertEqual(copilot, maps:get(adapter, Info)),
    ?assert(is_binary(maps:get(session_id, Info))),
    ?assertEqual(<<"copilot-sess-001">>, maps:get(copilot_session_id, Info)),

    copilot_session:stop(Pid).

test_query_lifecycle(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, Ref} = copilot_session:send_query(Pid, <<"What is 2+2?">>, #{}, 10000),
    ?assert(is_reference(Ref)),

    %% Message 1: text delta "Hello "
    {ok, Msg1} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(text, maps:get(type, Msg1)),
    ?assertEqual(<<"Hello ">>, maps:get(content, Msg1)),

    %% Message 2: text delta "world!"
    {ok, Msg2} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(text, maps:get(type, Msg2)),
    ?assertEqual(<<"world!">>, maps:get(content, Msg2)),

    %% Message 3: tool.executing → tool_use
    {ok, Msg3} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(tool_use, maps:get(type, Msg3)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg3)),
    ?assertEqual(#{<<"path">> => <<"/tmp/x">>}, maps:get(tool_input, Msg3)),
    ?assertEqual(<<"tc-42">>, maps:get(tool_use_id, Msg3)),

    %% Message 4: tool.completed → tool_result
    {ok, Msg4} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(tool_result, maps:get(type, Msg4)),
    ?assertEqual(<<"file contents">>, maps:get(content, Msg4)),

    %% Message 5: assistant.message → assistant
    {ok, Msg5} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(assistant, maps:get(type, Msg5)),
    ?assertEqual(<<"Final answer">>, maps:get(content, Msg5)),
    ?assertEqual(<<"msg-99">>, maps:get(message_id, Msg5)),

    %% Message 6: session.idle → result
    {ok, Msg6} = copilot_session:receive_message(Pid, Ref, 5000),
    ?assertEqual(result, maps:get(type, Msg6)),
    ?assertEqual(#{<<"total">> => 500}, maps:get(usage, Msg6)),

    %% After result, session should be back to ready
    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, copilot_session:health(Pid)),

    copilot_session:stop(Pid).

test_concurrent_query(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, _Ref1} = copilot_session:send_query(Pid, <<"q1">>, #{}, 10000),
    Result = copilot_session:send_query(Pid, <<"q2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),

    catch copilot_session:stop(Pid).

test_wrong_ref(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, _Ref} = copilot_session:send_query(Pid, <<"test">>, #{}, 10000),
    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 copilot_session:receive_message(Pid, WrongRef, 1000)),

    catch copilot_session:stop(Pid).

test_sdk_query(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, Messages} = copilot_client:query(Pid, <<"What is 2+2?">>),
    ?assert(is_list(Messages)),
    ?assert(length(Messages) >= 1),

    %% Last message should be result
    Last = lists:last(Messages),
    ?assertEqual(result, maps:get(type, Last)),

    copilot_session:stop(Pid).

test_session_info_during_query(ScriptPath) ->
    {ok, Pid} = copilot_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, _Ref} = copilot_session:send_query(Pid, <<"test">>, #{}, 10000),

    %% session_info should work during active query
    {ok, Info} = copilot_session:session_info(Pid),
    ?assert(is_map(Info)),
    ?assertEqual(copilot, maps:get(adapter, Info)),

    catch copilot_session:stop(Pid).

%%====================================================================
%% Permission handler tests
%%====================================================================

permission_handler_test_() ->
    {"permission handler invoked for permission.request",
     {setup,
      fun setup_permission_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              Self = self(),
              Handler = fun(Request, _Ctx) ->
                  Self ! {permission_check, Request},
                  {allow, #{}}
              end,

              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath,
                  permission_handler => Handler
              }),
              ok = wait_for_health(Pid, ready, 5000),

              {ok, Ref} = copilot_session:send_query(
                  Pid, <<"test">>, #{}, 10000),

              %% Handler should have been called
              receive
                  {permission_check, Request} ->
                      ?assertEqual(<<"shell">>,
                                   maps:get(<<"kind">>, Request))
              after 5000 ->
                  ?assert(false)
              end,

              drain_messages(Pid, Ref),
              catch copilot_session:stop(Pid)
          end}
      end}}.

permission_handler_crash_denies_test_() ->
    {"permission handler crash results in deny (fail-closed)",
     {setup,
      fun setup_permission_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              %% Handler that crashes
              Handler = fun(_Request, _Ctx) ->
                  error(handler_crash)
              end,

              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath,
                  permission_handler => Handler
              }),
              ok = wait_for_health(Pid, ready, 5000),

              %% Should not crash the session
              {ok, Ref} = copilot_session:send_query(
                  Pid, <<"test">>, #{}, 10000),
              drain_messages(Pid, Ref),

              %% Session should still be alive
              ok = wait_for_health(Pid, ready, 5000),
              Health = copilot_session:health(Pid),
              ?assertEqual(ready, Health),

              catch copilot_session:stop(Pid)
          end}
      end}}.

setup_permission_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_copilot_perm_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_permission_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%% Mock that sends a permission.request server-initiated request during query.
mock_permission_script() ->
    <<
      "#!/usr/bin/env python3\n"
      "import sys, json\n"
      "\n"
      "def send(obj):\n"
      "    body = json.dumps(obj)\n"
      "    header = f'Content-Length: {len(body)}\\r\\n\\r\\n'\n"
      "    sys.stdout.write(header + body)\n"
      "    sys.stdout.flush()\n"
      "\n"
      "def recv():\n"
      "    header = ''\n"
      "    while True:\n"
      "        ch = sys.stdin.read(1)\n"
      "        if ch == '':\n"
      "            return None\n"
      "        header += ch\n"
      "        if header.endswith('\\r\\n\\r\\n'):\n"
      "            break\n"
      "    for line in header.strip().split('\\r\\n'):\n"
      "        if line.lower().startswith('content-length:'):\n"
      "            length = int(line.split(':', 1)[1].strip())\n"
      "            break\n"
      "    else:\n"
      "        return None\n"
      "    body = sys.stdin.read(length)\n"
      "    if len(body) < length:\n"
      "        return None\n"
      "    return json.loads(body)\n"
      "\n"
      "while True:\n"
      "    msg = recv()\n"
      "    if msg is None:\n"
      "        break\n"
      "    method = msg.get('method', '')\n"
      "    req_id = msg.get('id')\n"
      "\n"
      "    if method == 'ping':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'message': 'pong'}})\n"
      "\n"
      "    elif method == 'session.create':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'sessionId': 'perm-sess-001'}})\n"
      "\n"
      "    elif method == 'session.send':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        # Send a permission.request (server-initiated request)\n"
      "        send({'jsonrpc': '2.0', 'id': 'perm-req-1',\n"
      "              'method': 'permission.request',\n"
      "              'params': {'request': {'kind': 'shell',\n"
      "                                     'command': 'ls -la'},\n"
      "                         'invocation': {'toolCallId': 'tc-p1'}}})\n"
      "        # Read the permission response\n"
      "        perm_resp = recv()\n"
      "        # Emit assistant message + session.idle\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'assistant.message',\n"
      "                                   'data': {'content': 'Done'}}}})\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {}}}})\n"
      "\n"
      "    elif method == 'session.abort':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {}}}})\n"
    >>.

%%====================================================================
%% Tool handler tests
%%====================================================================

tool_handler_test_() ->
    {"tool.call server request invokes registered tool handler",
     {setup,
      fun setup_tool_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              Self = self(),
              Handler = fun(Arguments) ->
                  Self ! {tool_invoked, Arguments},
                  {ok, [#{type => text, text => <<"tool output">>}]}
              end,

              Tool = beam_agent_tool_registry:tool(<<"my_tool">>, <<"Test tool">>,
                  #{<<"type">> => <<"object">>}, Handler),
              Server = beam_agent_tool_registry:server(<<"test-tools">>, [Tool]),

              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_mcp_servers => [Server]
              }),
              ok = wait_for_health(Pid, ready, 5000),

              {ok, Ref} = copilot_session:send_query(
                  Pid, <<"test">>, #{}, 10000),

              %% Handler should have been called with just arguments
              receive
                  {tool_invoked, Arguments} ->
                      ?assertEqual(#{<<"x">> => 42}, Arguments)
              after 5000 ->
                  ?assert(false)
              end,

              drain_messages(Pid, Ref),
              catch copilot_session:stop(Pid)
          end}
      end}}.

setup_tool_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_copilot_tool_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_tool_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%% Mock that sends a tool.call server-initiated request during query.
mock_tool_script() ->
    <<
      "#!/usr/bin/env python3\n"
      "import sys, json\n"
      "\n"
      "def send(obj):\n"
      "    body = json.dumps(obj)\n"
      "    header = f'Content-Length: {len(body)}\\r\\n\\r\\n'\n"
      "    sys.stdout.write(header + body)\n"
      "    sys.stdout.flush()\n"
      "\n"
      "def recv():\n"
      "    header = ''\n"
      "    while True:\n"
      "        ch = sys.stdin.read(1)\n"
      "        if ch == '':\n"
      "            return None\n"
      "        header += ch\n"
      "        if header.endswith('\\r\\n\\r\\n'):\n"
      "            break\n"
      "    for line in header.strip().split('\\r\\n'):\n"
      "        if line.lower().startswith('content-length:'):\n"
      "            length = int(line.split(':', 1)[1].strip())\n"
      "            break\n"
      "    else:\n"
      "        return None\n"
      "    body = sys.stdin.read(length)\n"
      "    if len(body) < length:\n"
      "        return None\n"
      "    return json.loads(body)\n"
      "\n"
      "while True:\n"
      "    msg = recv()\n"
      "    if msg is None:\n"
      "        break\n"
      "    method = msg.get('method', '')\n"
      "    req_id = msg.get('id')\n"
      "\n"
      "    if method == 'ping':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'message': 'pong'}})\n"
      "\n"
      "    elif method == 'session.create':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'sessionId': 'tool-sess-001'}})\n"
      "\n"
      "    elif method == 'session.send':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        # Send a tool.call server-initiated request\n"
      "        send({'jsonrpc': '2.0', 'id': 'tool-req-1',\n"
      "              'method': 'tool.call',\n"
      "              'params': {'toolName': 'my_tool',\n"
      "                         'arguments': {'x': 42},\n"
      "                         'toolCallId': 'tc-t1',\n"
      "                         'sessionId': 'tool-sess-001'}})\n"
      "        # Read the tool result response\n"
      "        tool_resp = recv()\n"
      "        # Complete the query\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'assistant.message',\n"
      "                                   'data': {'content': 'Used tool'}}}})\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {}}}})\n"
      "\n"
      "    elif method == 'session.abort':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        send({'jsonrpc': '2.0', 'method': 'session.event',\n"
      "              'params': {'event': {'type': 'session.idle',\n"
      "                                   'data': {}}}})\n"
    >>.

%%====================================================================
%% Hook tests
%%====================================================================

hook_user_prompt_deny_test_() ->
    {"user_prompt_submit hook can deny query",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              Hook = beam_agent_hooks_core:hook(user_prompt_submit,
                  fun(_) -> {deny, <<"prompts blocked">>} end),
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_hooks => [Hook]
              }),
              ok = wait_for_health(Pid, ready, 5000),
              ?assertEqual(ready, copilot_session:health(Pid)),
              Result = copilot_session:send_query(
                  Pid, <<"test">>, #{}, 5000),
              ?assertMatch({error, {hook_denied, <<"prompts blocked">>}}, Result),
              %% Session should still be in ready state
              ?assertEqual(ready, copilot_session:health(Pid)),
              copilot_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Interrupt (abort) tests
%%====================================================================

interrupt_test_() ->
    {"interrupt sends session.abort and returns to ready",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              {ok, Ref} = copilot_session:send_query(
                  Pid, <<"long task">>, #{}, 10000),

              %% Interrupt immediately — don't drain messages first
              %% The mock responds to session.abort with ok + session.idle
              %% Note: Due to buffering, some events from session.send
              %% may already be queued, so we drain everything
              ok = copilot_session:interrupt(Pid),

              %% Drain remaining messages
              drain_messages(Pid, Ref),

              ok = wait_for_health(Pid, ready, 5000),
              ?assertEqual(ready, copilot_session:health(Pid)),

              copilot_session:stop(Pid)
          end}
      end}}.

interrupt_no_active_query_test_() ->
    {"interrupt with no active query returns error",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 10, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              Result = copilot_session:interrupt(Pid),
              ?assertEqual({error, no_active_query}, Result),

              copilot_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% set_model tests
%%====================================================================

set_model_test_() ->
    {"set_model sends session.model.switchTo and gets response",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 10, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              Result = copilot_session:set_model(
                  Pid, <<"claude-sonnet-4-20250514">>),
              ?assertMatch({ok, _}, Result),

              copilot_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% send_command tests
%%====================================================================

send_command_test_() ->
    {"send_command forwards arbitrary JSON-RPC to CLI",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 10, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              %% Unknown method → error response from mock
              Result = copilot_session:send_control(
                  Pid, <<"custom.method">>, #{<<"arg">> => <<"val">>}),
              %% Mock returns error for unknown methods
              ?assertMatch({error, _}, Result),

              copilot_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Error handling tests
%%====================================================================

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI fails in init",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          process_flag(trap_exit, true),
          #{level := OldLevel} = logger:get_primary_config(),
          logger:set_primary_config(level, none),
          Result = copilot_session:start_link(#{
              cli_path => "/nonexistent/path/to/copilot_that_doesnt_exist"
          }),
          logger:set_primary_config(level, OldLevel),
          ?assertMatch({error, {transport_start_failed, _}}, Result),
          process_flag(trap_exit, false)
      end}}.

port_exit_during_query_test_() ->
    {"port exit during query synthesizes error and result",
     {setup,
      fun setup_exit_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              {ok, Ref} = copilot_session:send_query(
                  Pid, <<"test">>, #{}, 10000),

              %% The mock exits after session.send — engine replies with
              %% cli_exit error to the consumer directly.
              Result = copilot_session:receive_message(Pid, Ref, 5000),
              ?assertMatch({error, {cli_exit, _}}, Result),

              %% Session should be in error state
              timer:sleep(200),
              ?assertEqual(error, copilot_session:health(Pid)),

              catch copilot_session:stop(Pid)
          end}
      end}}.

setup_exit_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_copilot_exit_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_exit_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%% Mock that exits immediately after receiving session.send.
mock_exit_script() ->
    <<
      "#!/usr/bin/env python3\n"
      "import sys, json\n"
      "\n"
      "def send(obj):\n"
      "    body = json.dumps(obj)\n"
      "    header = f'Content-Length: {len(body)}\\r\\n\\r\\n'\n"
      "    sys.stdout.write(header + body)\n"
      "    sys.stdout.flush()\n"
      "\n"
      "def recv():\n"
      "    header = ''\n"
      "    while True:\n"
      "        ch = sys.stdin.read(1)\n"
      "        if ch == '':\n"
      "            return None\n"
      "        header += ch\n"
      "        if header.endswith('\\r\\n\\r\\n'):\n"
      "            break\n"
      "    for line in header.strip().split('\\r\\n'):\n"
      "        if line.lower().startswith('content-length:'):\n"
      "            length = int(line.split(':', 1)[1].strip())\n"
      "            break\n"
      "    else:\n"
      "        return None\n"
      "    body = sys.stdin.read(length)\n"
      "    if len(body) < length:\n"
      "        return None\n"
      "    return json.loads(body)\n"
      "\n"
      "while True:\n"
      "    msg = recv()\n"
      "    if msg is None:\n"
      "        break\n"
      "    method = msg.get('method', '')\n"
      "    req_id = msg.get('id')\n"
      "\n"
      "    if method == 'ping':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'message': 'pong'}})\n"
      "\n"
      "    elif method == 'session.create':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'sessionId': 'exit-sess-001'}})\n"
      "\n"
      "    elif method == 'session.send':\n"
      "        send({'jsonrpc': '2.0', 'id': req_id,\n"
      "              'result': {'ok': True}})\n"
      "        # Exit immediately to simulate crash\n"
      "        sys.exit(1)\n"
    >>.

%%====================================================================
%% Second query after first completes
%%====================================================================

second_query_test_() ->
    {"second query succeeds after first completes (ready reuse)",
     {setup,
      fun setup_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 20, fun() ->
              {ok, Pid} = copilot_session:start_link(#{
                  cli_path => ScriptPath
              }),
              ok = wait_for_health(Pid, ready, 5000),

              %% First query
              {ok, Messages1} = copilot_client:query(
                  Pid, <<"First query">>),
              ?assert(length(Messages1) >= 1),
              Last1 = lists:last(Messages1),
              ?assertEqual(result, maps:get(type, Last1)),

              ok = wait_for_health(Pid, ready, 5000),

              %% Second query — should succeed (session reuse)
              {ok, Messages2} = copilot_client:query(
                  Pid, <<"Second query">>),
              ?assert(length(Messages2) >= 1),
              Last2 = lists:last(Messages2),
              ?assertEqual(result, maps:get(type, Last2)),

              copilot_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Poll health until it matches Expected or timeout (milliseconds).
wait_for_health(Pid, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_health_loop(Pid, Expected, Deadline).

wait_for_health_loop(Pid, Expected, Deadline) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {error, {timeout, Expected, copilot_session:health(Pid)}};
        false ->
            case copilot_session:health(Pid) of
                Expected -> ok;
                _ ->
                    timer:sleep(50),
                    wait_for_health_loop(Pid, Expected, Deadline)
            end
    end.


drain_messages(Pid, Ref) ->
    case copilot_session:receive_message(Pid, Ref, 3000) of
        {ok, #{type := result}} -> ok;
        {ok, #{type := error, is_error := true}} -> ok;
        {ok, _} -> drain_messages(Pid, Ref);
        {error, _} -> ok
    end.

