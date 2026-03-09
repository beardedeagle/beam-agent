%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the Gemini ACP-backed session adapter.
%%%-------------------------------------------------------------------
-module(gemini_cli_session_tests).

-include_lib("eunit/include/eunit.hrl").

child_spec_test() ->
    Spec = gemini_cli_client:child_spec(#{cli_path => "/usr/bin/gemini"}),
    ?assertEqual(gemini_cli_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(gemini_cli_session, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/gemini"}], Args).

send_control_not_supported_test() ->
    ?assertEqual({error, not_supported},
                 gemini_cli_session:send_control(self(), <<"noop">>, #{})).

mock_session_test_() ->
    {"gemini_cli_session lifecycle with mock ACP server",
     {setup,
      fun setup_mock_session/0,
      fun cleanup_mock/1,
      fun(ScriptPath) -> [
          {"health reports ready after ACP initialization",
           {timeout, 10, fun() -> test_health(ScriptPath) end}},
          {"permission_mode is normalized into ACP startup argv",
           {timeout, 10, fun() -> test_permission_mode_flag(ScriptPath) end}},
          {"sandbox flag is forwarded to Gemini CLI startup argv",
           {timeout, 10, fun() -> test_sandbox_flag(ScriptPath) end}},
          {"query streams normalized user, thought, tool, and result messages",
           {timeout, 10, fun() -> test_query(ScriptPath) end}},
          {"structured attachments are forwarded as ACP prompt blocks",
           {timeout, 10, fun() -> test_structured_prompt_blocks(ScriptPath) end}},
          {"sequential queries reuse the persistent ACP session",
           {timeout, 10, fun() -> test_sequential_queries(ScriptPath) end}},
          {"session info exposes native session metadata",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"set_model stores local runtime override",
           {timeout, 10, fun() -> test_set_model(ScriptPath) end}},
          {"set_permission_mode drives session/set_mode",
           {timeout, 10, fun() -> test_set_permission_mode(ScriptPath) end}},
          {"interrupt maps to session/cancel and yields cancelled stop reason",
           {timeout, 10, fun() -> test_interrupt(ScriptPath) end}},
          {"wrong ref is rejected",
           {timeout, 10, fun() -> test_wrong_ref(ScriptPath) end}},
          {"concurrent query is rejected while a prompt is active",
           {timeout, 10, fun() -> test_concurrent_query(ScriptPath) end}},
          {"reverse permission requests are bridged through shared control defaults",
           {timeout, 10, fun() -> test_permission_request_default_reject(ScriptPath) end}},
          {"gemini_cli_client:query/2 collects the full prompt lifecycle",
           {timeout, 10, fun() -> test_sdk_query(ScriptPath) end}}
      ] end}}.

setup_mock_session() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath =
        "/tmp/mock_gemini_acp_" ++
        integer_to_list(erlang:unique_integer([positive])),
    ok = file:write_file(ScriptPath, mock_acp_server_script()),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock(ScriptPath) ->
    file:delete(ScriptPath).

mock_acp_server_script() ->
    [
     "#!/usr/bin/env python3\n",
     "import json, select, sys, time\n",
     "argv = ' '.join(sys.argv[1:])\n",
     "session_id = 'gemini-acp-001'\n",
     "current_mode = 'default'\n",
     "current_model = 'gemini-2.0-flash'\n",
     "def send(obj):\n",
     "    sys.stdout.write(json.dumps(obj) + '\\n')\n",
     "    sys.stdout.flush()\n",
     "while True:\n",
     "    line = sys.stdin.readline()\n",
     "    if not line:\n",
     "        break\n",
     "    msg = json.loads(line)\n",
     "    method = msg.get('method')\n",
     "    params = msg.get('params', {}) or {}\n",
     "    mid = msg.get('id')\n",
     "    if method == 'initialize':\n",
     "        send({'id': mid, 'result': {\n",
     "            'protocolVersion': 1,\n",
     "            'agentInfo': {'name': 'gemini-cli', 'title': 'Gemini CLI', 'version': '0.32.1'},\n",
     "            'authMethods': [{'id': 'gemini-api-key', 'name': 'Gemini API key'}],\n",
     "            'agentCapabilities': {'loadSession': True, 'promptCapabilities': {'image': True, 'audio': True, 'embeddedContext': True}},\n",
     "            '_meta': {'argv': argv}\n",
     "        }})\n",
     "    elif method == 'authenticate':\n",
     "        send({'id': mid, 'result': {}})\n",
     "    elif method in ('session/new', 'session/load'):\n",
     "        session_id = params.get('sessionId') or session_id\n",
     "        send({'id': mid, 'result': {\n",
     "            'sessionId': session_id,\n",
     "            'modes': {'availableModes': [\n",
     "                {'id': 'default', 'name': 'Default'},\n",
     "                {'id': 'auto_edit', 'name': 'Auto Edit'},\n",
     "                {'id': 'yolo', 'name': 'YOLO'}],\n",
     "                'currentModeId': current_mode},\n",
     "            'models': {'availableModels': [\n",
     "                {'modelId': 'gemini-2.0-flash', 'name': 'Flash'},\n",
     "                {'modelId': 'gemini-1.5-pro', 'name': 'Pro'}],\n",
     "                'currentModelId': current_model}\n",
     "        }})\n",
     "    elif method == 'session/set_mode':\n",
     "        current_mode = params.get('modeId', current_mode)\n",
     "        send({'method': 'session/update', 'params': {\n",
     "            'sessionId': session_id,\n",
     "            'update': {'sessionUpdate': 'current_mode_update', 'currentModeId': current_mode}\n",
     "        }})\n",
     "        send({'id': mid, 'result': {}})\n",
     "    elif method == 'session/prompt':\n",
     "        prompt_blocks = params.get('prompt', [])\n",
     "        prompt_text = ' '.join([part.get('text', '') for part in prompt_blocks if isinstance(part, dict) and part.get('type') == 'text'])\n",
     "        send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "            'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': prompt_text}}}})\n",
     "        if prompt_text == 'inspect blocks':\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': json.dumps(prompt_blocks, sort_keys=True)}}}})\n",
     "            send({'id': mid, 'result': {'stopReason': 'end_turn'}})\n",
     "        elif prompt_text == 'permission':\n",
     "            req_id = 9001\n",
     "            send({'id': req_id, 'method': 'session/request_permission', 'params': {\n",
     "                'sessionId': session_id,\n",
     "                'toolCall': {'toolCallId': 'tool-001', 'title': 'Write file', 'kind': 'write'},\n",
     "                'options': [\n",
     "                    {'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},\n",
     "                    {'optionId': 'reject-once', 'name': 'Reject once', 'kind': 'reject_once'}]}})\n",
     "            response = json.loads(sys.stdin.readline())\n",
     "            outcome = response['result']['outcome']\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'tool_call', 'toolCallId': 'tool-001', 'title': 'Write file', 'status': 'pending'}}})\n",
     "            if outcome.get('outcome') == 'selected' and outcome.get('optionId') == 'allow-once':\n",
     "                send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                    'sessionUpdate': 'tool_call_update', 'toolCallId': 'tool-001', 'status': 'completed',\n",
     "                    'content': [{'type': 'content', 'content': {'type': 'text', 'text': 'write ok'}}]}}})\n",
     "            else:\n",
     "                send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                    'sessionUpdate': 'tool_call_update', 'toolCallId': 'tool-001', 'status': 'failed',\n",
     "                    'content': [{'type': 'content', 'content': {'type': 'text', 'text': 'permission denied'}}]}}})\n",
     "            send({'id': mid, 'result': {'stopReason': 'end_turn'}})\n",
     "        elif prompt_text == 'slow':\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'Working...'}}}})\n",
     "            cancelled = False\n",
     "            deadline = time.time() + 5.0\n",
     "            while time.time() < deadline:\n",
     "                ready, _, _ = select.select([sys.stdin], [], [], 0.05)\n",
     "                if ready:\n",
     "                    inner = json.loads(sys.stdin.readline())\n",
     "                    if inner.get('method') == 'session/cancel':\n",
     "                        cancelled = True\n",
     "                        break\n",
     "            send({'id': mid, 'result': {'stopReason': 'cancelled' if cancelled else 'end_turn'}})\n",
     "        else:\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'Thinking'}}}})\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Hello from Gemini ACP'}}}})\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'tool_call', 'toolCallId': 'tool-123', 'title': 'Read file', 'status': 'pending'}}})\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'tool_call_update', 'toolCallId': 'tool-123', 'status': 'completed',\n",
     "                'content': [{'type': 'content', 'content': {'type': 'text', 'text': 'file contents'}}]}}})\n",
     "            send({'method': 'session/update', 'params': {'sessionId': session_id, 'update': {\n",
     "                'sessionUpdate': 'session_info_update', 'title': 'Gemini mock session', 'updatedAt': '2026-03-08T00:00:00Z'}}})\n",
     "            send({'id': mid, 'result': {'stopReason': 'end_turn'}})\n",
     "    elif method == 'session/cancel':\n",
     "        pass\n"
    ].

test_health(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    ?assertEqual(ready, gemini_cli_session:health(Pid)),
    gemini_cli_session:stop(Pid).

test_permission_mode_flag(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{
        cli_path => ScriptPath,
        permission_mode => <<"bypassPermissions">>
    }),
    wait_ready(Pid),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    Argv = init_argv(Info),
    ?assertNotEqual(nomatch, binary:match(Argv, <<"--approval-mode yolo">>)),
    ?assertNotEqual(nomatch, binary:match(Argv, <<"--experimental-acp">>)),
    gemini_cli_session:stop(Pid).

test_sandbox_flag(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{
        cli_path => ScriptPath,
        sandbox => true
    }),
    wait_ready(Pid),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    Argv = init_argv(Info),
    ?assertNotEqual(nomatch, binary:match(Argv, <<"--sandbox">>)),
    gemini_cli_session:stop(Pid).

test_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"hello">>, #{}, 10000),
    Messages = collect_all(Pid, Ref, []),
    Types = [maps:get(type, M) || M <- Messages],
    ?assert(lists:member(user, Types)),
    ?assert(lists:member(thinking, Types)),
    ?assert(lists:member(text, Types)),
    ?assert(lists:member(tool_use, Types)),
    ?assert(lists:member(tool_result, Types)),
    ?assert(lists:member(result, Types)),
    gemini_cli_session:stop(Pid).

test_structured_prompt_blocks(ScriptPath) ->
    TextPath = temp_path(<<"gemini-attachment.txt">>),
    ImagePath = temp_path(<<"gemini-attachment.png">>),
    ok = file:write_file(binary_to_list(TextPath), <<"structured file">>),
    ok = file:write_file(binary_to_list(ImagePath), <<16#89, $P, $N, $G>>),
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Messages} = beam_agent:query(Pid, <<"inspect blocks">>, #{
        attachments => [
            #{type => file, path => TextPath},
            #{type => local_image, path => ImagePath}
        ]
    }),
    PromptBlocksMsg = find_first_type(text, Messages),
    Json = maps:get(content, PromptBlocksMsg),
    ?assertNotEqual(nomatch, binary:match(Json, <<"\"type\": \"resource\"">>)),
    ?assertNotEqual(nomatch, binary:match(Json, <<"\"type\": \"image\"">>)),
    ?assertNotEqual(nomatch, binary:match(Json, <<"file://">>)),
    ok = file:delete(binary_to_list(TextPath)),
    ok = file:delete(binary_to_list(ImagePath)),
    gemini_cli_session:stop(Pid).

test_sequential_queries(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Ref1} = gemini_cli_session:send_query(Pid, <<"first">>, #{}, 10000),
    _ = collect_all(Pid, Ref1, []),
    ?assertEqual(ready, wait_ready(Pid)),
    {ok, Ref2} = gemini_cli_session:send_query(Pid, <<"second">>, #{}, 10000),
    Messages2 = collect_all(Pid, Ref2, []),
    ?assert(length(Messages2) > 0),
    gemini_cli_session:stop(Pid).

test_session_info(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"info">>, #{}, 10000),
    _ = collect_all(Pid, Ref, []),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assertEqual(gemini_cli, maps:get(transport, Info)),
    ?assertEqual(<<"gemini-acp-001">>, maps:get(session_id, Info)),
    ?assertEqual(<<"Gemini mock session">>, maps:get(title, Info)),
    gemini_cli_session:stop(Pid).

test_set_model(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    ?assertEqual({ok, <<"gemini-1.5-pro">>},
                 gemini_cli_session:set_model(Pid, <<"gemini-1.5-pro">>)),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assertEqual(<<"gemini-1.5-pro">>, maps:get(model, Info)),
    gemini_cli_session:stop(Pid).

test_set_permission_mode(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    ?assertEqual({ok, <<"yolo">>},
                 gemini_cli_session:set_permission_mode(Pid, <<"yolo">>)),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assertEqual(<<"yolo">>, maps:get(permission_mode, Info)),
    gemini_cli_session:stop(Pid).

test_interrupt(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"slow">>, #{}, 10000),
    timer:sleep(100),
    ?assertEqual(ok, gemini_cli_session:interrupt(Pid)),
    Messages = collect_all(Pid, Ref, []),
    Result = find_last_type(result, Messages),
    ?assertEqual(<<"cancelled">>, maps:get(stop_reason, Result)),
    gemini_cli_session:stop(Pid).

test_wrong_ref(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, _Ref} = gemini_cli_session:send_query(Pid, <<"hello">>, #{}, 10000),
    ?assertEqual({error, bad_ref},
                 gemini_cli_session:receive_message(Pid, make_ref(), 1000)),
    catch gemini_cli_session:stop(Pid).

test_concurrent_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, _Ref1} = gemini_cli_session:send_query(Pid, <<"slow">>, #{}, 10000),
    ?assertEqual({error, query_in_progress},
                 gemini_cli_session:send_query(Pid, <<"second">>, #{}, 1000)),
    catch gemini_cli_session:stop(Pid).

test_permission_request_default_reject(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"permission">>, #{}, 10000),
    Messages = collect_all(Pid, Ref, []),
    Types = [maps:get(type, M) || M <- Messages],
    ?assert(lists:member(tool_use, Types)),
    ?assert(lists:member(error, Types)),
    ?assert(lists:member(result, Types)),
    ErrorMsg = find_first_type(error, Messages),
    ?assertNotEqual(nomatch,
                    binary:match(maps:get(content, ErrorMsg),
                                 <<"permission denied">>)),
    gemini_cli_session:stop(Pid).

test_sdk_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    wait_ready(Pid),
    {ok, Messages} = gemini_cli_client:query(Pid, <<"sdk">>),
    Types = [maps:get(type, M) || M <- Messages],
    ?assert(lists:member(result, Types)),
    gemini_cli_session:stop(Pid).

wait_ready(Pid) ->
    wait_ready(Pid, 40).

wait_ready(Pid, 0) ->
    gemini_cli_session:health(Pid);
wait_ready(Pid, Attempts) ->
    case gemini_cli_session:health(Pid) of
        ready ->
            ready;
        _ ->
            timer:sleep(50),
            wait_ready(Pid, Attempts - 1)
    end.

collect_all(Pid, Ref, Acc) ->
    case gemini_cli_session:receive_message(Pid, Ref, 3000) of
        {ok, Msg} ->
            collect_all(Pid, Ref, [Msg | Acc]);
        {error, complete} ->
            lists:reverse(Acc)
    end.

find_first_type(Type, [#{type := Type} = Msg | _]) ->
    Msg;
find_first_type(Type, [_ | Rest]) ->
    find_first_type(Type, Rest).

find_last_type(Type, Messages) ->
    lists:last([Msg || #{type := T} = Msg <- Messages, T =:= Type]).

init_argv(Info) ->
    Init = maps:get(init_response, Info, #{}),
    Meta = maps:get(<<"_meta">>, Init, #{}),
    maps:get(<<"argv">>, Meta, <<>>).

temp_path(Name) ->
    unicode:characters_to_binary(
        filename:join([os:getenv("TMPDIR", "/tmp"),
                       "beam_agent_gemini_" ++ integer_to_list(erlang:unique_integer([positive])) ++
                       "_" ++ binary_to_list(Name)])).
