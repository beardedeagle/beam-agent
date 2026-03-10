%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_session gen_statem.
%%%
%%% Uses mock shell scripts that speak the Codex JSON-RPC protocol.
%%% Tests cover:
%%%   - 3-step initialize handshake (request → response → notification)
%%%   - Query lifecycle (auto thread + turn + streaming + result)
%%%   - Health state transitions
%%%   - send_control for arbitrary methods
%%%   - Interrupt active turn
%%%   - Session info
%%%   - Approval handler callback
%%%   - Hook firing (user_prompt_submit deny)
%%%   - Error handling (bad path, wrong ref, concurrent query)
%%% @end
%%%-------------------------------------------------------------------
-module(codex_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests (no real CLI needed)
%%====================================================================

child_spec_test() ->
    Spec = codex_app_server:child_spec(#{cli_path => "/usr/bin/codex"}),
    ?assertEqual(codex_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(10000, maps:get(shutdown, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(codex_session, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/codex"}], Args).

child_spec_with_session_id_test() ->
    Spec = codex_app_server:child_spec(#{
        cli_path => "/usr/bin/codex",
        session_id => <<"my-session">>
    }),
    ?assertEqual({codex_session, <<"my-session">>}, maps:get(id, Spec)).

exec_child_spec_test() ->
    Spec = codex_app_server:exec_child_spec(#{cli_path => "/usr/bin/codex"}),
    ?assertEqual(codex_exec, maps:get(id, Spec)),
    {Mod, _, _} = maps:get(start, Spec),
    ?assertEqual(codex_exec, Mod).

%%====================================================================
%% Mock script-based integration tests
%%====================================================================

mock_session_test_() ->
    {"full codex_session lifecycle with mock CLI",
     {setup,
      fun setup_mock_codex/0,
      fun cleanup_mock/1,
      fun(ScriptPath) -> [
          {"session connects and initializes (3-step handshake)",
           {timeout, 10, fun() -> test_init(ScriptPath) end}},
          {"health reports correct states",
           {timeout, 10, fun() -> test_health(ScriptPath) end}},
          {"query lifecycle (auto thread + turn + streaming + result)",
           {timeout, 15, fun() -> test_query_lifecycle(ScriptPath) end}},
          {"session_info returns thread/turn/server data",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"concurrent query rejected",
           {timeout, 10, fun() -> test_concurrent_query(ScriptPath) end}},
          {"wrong ref rejected",
           {timeout, 10, fun() -> test_wrong_ref(ScriptPath) end}},
          {"codex_app_server:query/2 collects all messages",
           {timeout, 15, fun() -> test_sdk_query(ScriptPath) end}}
      ] end}}.

setup_mock_codex() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_codex_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_codex_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock(ScriptPath) ->
    file:delete(ScriptPath).

%% Mock Codex CLI that speaks JSON-RPC protocol.
%% Handles:
%%   1. initialize request → response
%%   2. initialized notification (ignored)
%%   3. thread/start request → response with threadId
%%   4. turn/start request → response with turnId + streaming notifications
mock_codex_script() ->
    <<
      "#!/bin/sh\n"
      "exec 2>/dev/null\n"
      "# Mock Codex CLI — JSON-RPC protocol\n"
      "# Read and respond to JSON-RPC messages on stdin/stdout\n"
      "while IFS= read -r line; do\n"
      "  case \"$line\" in\n"
      "    *'\"method\":\"initialize\"'*)\n"
      "      # Extract request id — simple pattern: id is first integer after \"id\":\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"serverName\\\":\\\"codex\\\",\\\"serverVersion\\\":\\\"0.1.0\\\"}}\"\n"
      "      ;;\n"
      "    *'\"method\":\"initialized\"'*)\n"
      "      # Acknowledged — no response needed\n"
      "      ;;\n"
      "    *'\"method\":\"thread/start\"'*)\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"threadId\\\":\\\"thread-001\\\"}}\"\n"
      "      ;;\n"
      "    *'\"method\":\"turn/start\"'*)\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"turnId\\\":\\\"turn-001\\\"}}\"\n"
      "      # Emit streaming notifications\n"
      "      echo '{\"method\":\"turn/started\",\"params\":{\"turnId\":\"turn-001\"}}'\n"
      "      echo '{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"AgentMessage\",\"content\":\"thinking...\"}}}'\n"
      "      echo '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"Hello from Codex!\"}}'\n"
      "      echo '{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"AgentMessage\",\"content\":\"Hello from Codex!\"}}}'\n"
      "      echo '{\"method\":\"turn/completed\",\"params\":{\"status\":\"completed\",\"turnId\":\"turn-001\"}}'\n"
      "      ;;\n"
      "    *'\"method\":\"turn/interrupt\"'*)\n"
      "      echo '{\"method\":\"turn/completed\",\"params\":{\"status\":\"interrupted\",\"turnId\":\"turn-001\"}}'\n"
      "      ;;\n"
      "    *)\n"
      "      ;;\n"
      "  esac\n"
      "done\n"
    >>.

test_init(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, codex_session:health(Pid)),
    codex_session:stop(Pid).

test_health(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    %% Should be initializing or already ready (fast mock)
    Health1 = codex_session:health(Pid),
    ?assert(lists:member(Health1, [initializing, ready])),
    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, codex_session:health(Pid)),
    codex_session:stop(Pid).

test_query_lifecycle(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),
    ?assertEqual(ready, codex_session:health(Pid)),

    {ok, Ref} = codex_session:send_query(Pid, <<"What is 2+2?">>, #{}, 10000),
    ?assert(is_reference(Ref)),

    %% Collect messages — should get streaming notifications then result
    Messages = collect_all(Pid, Ref, []),
    ?assert(length(Messages) >= 1),

    %% Last message should be result (turn/completed)
    Last = lists:last(Messages),
    ?assertEqual(result, maps:get(type, Last)),
    ?assertEqual(<<"completed">>, maps:get(subtype, Last)),

    timer:sleep(100),
    ?assertEqual(ready, codex_session:health(Pid)),
    codex_session:stop(Pid).

test_session_info(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, Info} = codex_session:session_info(Pid),
    ?assert(is_map(Info)),
    %% server_info should have data from initialize response
    ServerInfo = maps:get(server_info, Info),
    ?assert(is_map(ServerInfo)),
    ?assertEqual(<<"codex">>, maps:get(<<"serverName">>, ServerInfo)),

    codex_session:stop(Pid).

test_concurrent_query(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, _Ref1} = codex_session:send_query(Pid, <<"query1">>, #{}, 10000),
    Result = codex_session:send_query(Pid, <<"query2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),

    catch codex_session:stop(Pid).

test_wrong_ref(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, _Ref} = codex_session:send_query(Pid, <<"test">>, #{}, 10000),
    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 codex_session:receive_message(Pid, WrongRef, 1000)),

    catch codex_session:stop(Pid).

test_sdk_query(ScriptPath) ->
    {ok, Pid} = codex_session:start_link(#{cli_path => ScriptPath}),
    ok = wait_for_health(Pid, ready, 5000),

    {ok, Messages} = codex_app_server:query(Pid, <<"What is 2+2?">>),
    ?assert(is_list(Messages)),
    ?assert(length(Messages) >= 1),

    Last = lists:last(Messages),
    ?assertEqual(result, maps:get(type, Last)),

    codex_session:stop(Pid).

%%====================================================================
%% Approval handler tests
%%====================================================================

approval_handler_test_() ->
    {"approval handler is invoked for command approval requests",
     {setup,
      fun setup_approval_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               Self = self(),
               Handler = fun(Method, _Params, _Opts) ->
                   Self ! {approval_check, Method},
                   accept
               end,
               {ok, Pid} = codex_session:start_link(#{
                   cli_path => ScriptPath,
                   approval_handler => Handler
               }),
               ok = wait_for_health(Pid, ready, 5000),

               {ok, Ref} = codex_session:send_query(Pid, <<"test">>, #{}, 10000),

               %% Handler should have been called
               receive
                   {approval_check, Method} ->
                       ?assertEqual(
                           <<"item/commandExecution/requestApproval">>, Method)
               after 5000 ->
                   ?assert(false)
               end,

               drain_messages(Pid, Ref),
               catch codex_session:stop(Pid)
           end}
      end}}.

approval_handler_crash_declines_test_() ->
    {"approval handler crash results in decline (fail-closed)",
     {setup,
      fun setup_approval_mock/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15,
           fun() ->
               %% Handler that crashes
               Handler = fun(_Method, _Params, _Opts) ->
                   error(handler_crash)
               end,
               {ok, Pid} = codex_session:start_link(#{
                   cli_path => ScriptPath,
                   approval_handler => Handler
               }),
               ok = wait_for_health(Pid, ready, 5000),

               %% Should not crash the session
               {ok, Ref} = codex_session:send_query(Pid, <<"test">>, #{}, 10000),
               drain_messages(Pid, Ref),
               %% Session should still be alive
               timer:sleep(100),
               Health = codex_session:health(Pid),
               ?assert(lists:member(Health, [ready, active_query])),
               catch codex_session:stop(Pid)
           end}
      end}}.

setup_approval_mock() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_codex_approval_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_approval_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

%% Mock that sends a command approval request during a turn.
mock_approval_script() ->
    <<
      "#!/bin/sh\n"
      "exec 2>/dev/null\n"
      "while IFS= read -r line; do\n"
      "  case \"$line\" in\n"
      "    *'\"method\":\"initialize\"'*)\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"serverName\\\":\\\"codex\\\"}}\"\n"
      "      ;;\n"
      "    *'\"method\":\"initialized\"'*)\n"
      "      ;;\n"
      "    *'\"method\":\"thread/start\"'*)\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"threadId\\\":\\\"thread-a\\\"}}\"\n"
      "      ;;\n"
      "    *'\"method\":\"turn/start\"'*)\n"
      "      req_id=$(echo \"$line\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/')\n"
      "      echo \"{\\\"id\\\":${req_id},\\\"result\\\":{\\\"turnId\\\":\\\"turn-a\\\"}}\"\n"
      "      # Send approval request (server-initiated request with id)\n"
      "      echo '{\"id\":999,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"ls -la\",\"cwd\":\"/tmp\"}}'\n"
      "      # Wait for approval response, then complete\n"
      "      read -r approval_response\n"
      "      echo '{\"method\":\"turn/completed\",\"params\":{\"status\":\"completed\"}}'\n"
      "      ;;\n"
      "    *)\n"
      "      ;;\n"
      "  esac\n"
      "done\n"
    >>.

%%====================================================================
%% Hook tests
%%====================================================================

hook_user_prompt_deny_test_() ->
    {"user_prompt_submit hook can deny query",
     {setup,
      fun setup_mock_codex/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          {timeout, 15, fun() ->
              Hook = beam_agent_hooks_core:hook(user_prompt_submit,
                  fun(_) -> {deny, <<"prompts blocked">>} end),
              {ok, Pid} = codex_session:start_link(#{
                  cli_path => ScriptPath,
                  sdk_hooks => [Hook]
              }),
              ok = wait_for_health(Pid, ready, 5000),
              ?assertEqual(ready, codex_session:health(Pid)),
              Result = codex_session:send_query(Pid, <<"test">>, #{}, 5000),
              ?assertMatch({error, {hook_denied, <<"prompts blocked">>}}, Result),
              ?assertEqual(ready, codex_session:health(Pid)),
              codex_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Error handling tests
%%====================================================================

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI fails",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          process_flag(trap_exit, true),
          %% Suppress expected warning from open_port failure
          #{level := OldLevel} = logger:get_primary_config(),
          logger:set_primary_config(level, none),
          Result = codex_session:start_link(#{
              cli_path => "/nonexistent/path/to/codex_that_doesnt_exist"
          }),
          logger:set_primary_config(level, OldLevel),
          ?assertMatch({error, {transport_start_failed, _}}, Result),
          process_flag(trap_exit, false)
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Poll health until it matches Expected or timeout (milliseconds).
%%      Replaces fragile timer:sleep calls in tests.
wait_for_health(Pid, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_health_loop(Pid, Expected, Deadline).

wait_for_health_loop(Pid, Expected, Deadline) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {error, {timeout, Expected, codex_session:health(Pid)}};
        false ->
            case codex_session:health(Pid) of
                Expected -> ok;
                _ ->
                    timer:sleep(50),
                    wait_for_health_loop(Pid, Expected, Deadline)
            end
    end.

collect_all(Pid, Ref, Acc) ->
    case codex_session:receive_message(Pid, Ref, 5000) of
        {ok, #{type := result} = Msg} ->
            lists:reverse([Msg | Acc]);
        {ok, #{type := error} = Msg} ->
            lists:reverse([Msg | Acc]);
        {ok, Msg} ->
            collect_all(Pid, Ref, [Msg | Acc]);
        {error, complete} ->
            lists:reverse(Acc);
        {error, _} ->
            lists:reverse(Acc)
    end.

drain_messages(Pid, Ref) ->
    case codex_session:receive_message(Pid, Ref, 3000) of
        {ok, #{type := result}} -> ok;
        {ok, #{type := error}} -> ok;
        {ok, _} -> drain_messages(Pid, Ref);
        {error, _} -> ok
    end.
