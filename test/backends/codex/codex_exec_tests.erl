%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_exec gen_statem.
%%%
%%% Uses mock shell scripts that emit JSONL output and exit.
%%% Tests cover:
%%%   - Health state transitions
%%%   - Query lifecycle (JSONL output + exit_status 0)
%%%   - Sequential queries (new port each)
%%%   - Session info
%%%   - Set model at runtime
%%%   - Interrupt
%%%   - send_control → not_supported
%%%   - Error handling (bad path, wrong ref, concurrent query)
%%% @end
%%%-------------------------------------------------------------------
-module(codex_exec_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests
%%====================================================================

exec_child_spec_test() ->
    Spec = codex_app_server:exec_child_spec(#{cli_path => "/usr/bin/codex"}),
    ?assertEqual(codex_exec, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(codex_exec, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/codex"}], Args).

send_control_not_supported_test() ->
    ?assertEqual({error, not_supported},
                 codex_exec:send_control(self(), <<"foo">>, #{})).

%%====================================================================
%% Mock script-based integration tests
%%====================================================================

mock_exec_test_() ->
    {"codex_exec lifecycle with mock CLI",
     {setup,
      fun setup_mock_exec/0,
      fun cleanup_mock/1,
      fun(ScriptPath) -> [
          {"health reports ready in idle state",
           {timeout, 10, fun() -> test_health(ScriptPath) end}},
          {"query collects JSONL output",
           {timeout, 10, fun() -> test_query(ScriptPath) end}},
          {"sequential queries work (new port each)",
           {timeout, 15, fun() -> test_sequential_queries(ScriptPath) end}},
          {"session_info returns transport info",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"set_model stores model",
           {timeout, 10, fun() -> test_set_model(ScriptPath) end}},
          {"interrupt closes port",
           {timeout, 10, fun() -> test_interrupt(ScriptPath) end}},
          {"wrong ref rejected",
           {timeout, 10, fun() -> test_wrong_ref(ScriptPath) end}},
          {"concurrent query rejected",
           {timeout, 10, fun() -> test_concurrent_query(ScriptPath) end}},
          {"codex_app_server:query/2 collects all messages (exec)",
           {timeout, 15, fun() -> test_sdk_query_exec(ScriptPath) end}}
      ] end}}.

setup_mock_exec() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_codex_exec_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_exec_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock(ScriptPath) ->
    file:delete(ScriptPath).

%% Mock script that emits JSONL output and exits.
%% The "exec" args format: script exec --output-format jsonl [--model M] PROMPT
%% We just emit some JSONL regardless of args, then exit 0.
mock_exec_script() ->
    <<
      "#!/bin/sh\n"
      "exec 2>/dev/null\n"
      "# Mock codex exec — emit JSONL and exit\n"
      "# Ignore all args, emit fixed output\n"
      "echo '{\"type\":\"text\",\"content\":\"Hello from exec!\"}'\n"
      "echo '{\"type\":\"result\",\"content\":\"done\",\"subtype\":\"completed\"}'\n"
      "exit 0\n"
    >>.

test_health(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    ?assertEqual(ready, codex_exec:health(Pid)),
    codex_exec:stop(Pid).

test_query(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, Ref} = codex_exec:send_query(Pid, <<"What is 2+2?">>, #{}, 10000),
    ?assert(is_reference(Ref)),

    Messages = collect_all(Pid, Ref, []),
    ?assert(length(Messages) >= 1),

    %% Should have text and/or result messages
    Types = [maps:get(type, M) || M <- Messages],
    ?assert(lists:member(text, Types) orelse lists:member(result, Types)),

    codex_exec:stop(Pid).

test_sequential_queries(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),

    %% First query
    {ok, Ref1} = codex_exec:send_query(Pid, <<"query1">>, #{}, 10000),
    _Msgs1 = collect_all(Pid, Ref1, []),

    %% Wait for idle state
    timer:sleep(200),
    ?assertEqual(ready, codex_exec:health(Pid)),

    %% Second query
    {ok, Ref2} = codex_exec:send_query(Pid, <<"query2">>, #{}, 10000),
    _Msgs2 = collect_all(Pid, Ref2, []),

    timer:sleep(200),
    ?assertEqual(ready, codex_exec:health(Pid)),
    codex_exec:stop(Pid).

test_session_info(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, Info} = codex_exec:session_info(Pid),
    ?assert(is_map(Info)),
    ?assertEqual(exec, maps:get(transport, Info)),
    codex_exec:stop(Pid).

test_set_model(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, <<"gpt-4">>} = codex_exec:set_model(Pid, <<"gpt-4">>),
    {ok, Info} = codex_exec:session_info(Pid),
    ?assertEqual(<<"gpt-4">>, maps:get(model, Info)),
    codex_exec:stop(Pid).

test_interrupt(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref} = codex_exec:send_query(Pid, <<"test">>, #{}, 10000),
    ?assertEqual(ok, codex_exec:interrupt(Pid)),
    timer:sleep(200),
    ?assertEqual(ready, codex_exec:health(Pid)),
    codex_exec:stop(Pid).

test_wrong_ref(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref} = codex_exec:send_query(Pid, <<"test">>, #{}, 10000),
    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 codex_exec:receive_message(Pid, WrongRef, 1000)),
    catch codex_exec:stop(Pid).

test_concurrent_query(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref1} = codex_exec:send_query(Pid, <<"query1">>, #{}, 10000),
    Result = codex_exec:send_query(Pid, <<"query2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),
    catch codex_exec:stop(Pid).

test_sdk_query_exec(ScriptPath) ->
    {ok, Pid} = codex_exec:start_link(#{cli_path => ScriptPath}),
    {ok, Messages} = codex_app_server:query(Pid, <<"What is 2+2?">>),
    ?assert(is_list(Messages)),
    ?assert(length(Messages) >= 1),
    codex_exec:stop(Pid).

%%====================================================================
%% Error handling tests
%%====================================================================

bad_cli_path_exec_test_() ->
    {"start_link with nonexistent CLI starts ok (fails on query)",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          %% codex_exec starts in idle, port opened per-query
          {ok, Pid} = codex_exec:start_link(#{
              cli_path => "/nonexistent/path/to/codex_that_doesnt_exist"
          }),
          ?assertEqual(ready, codex_exec:health(Pid)),
          %% Query should fail when trying to open port
          Result = codex_exec:send_query(Pid, <<"test">>, #{}, 5000),
          ?assertMatch({error, {open_port_failed, _}}, Result),
          codex_exec:stop(Pid)
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

collect_all(Pid, Ref, Acc) ->
    case codex_exec:receive_message(Pid, Ref, 5000) of
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
