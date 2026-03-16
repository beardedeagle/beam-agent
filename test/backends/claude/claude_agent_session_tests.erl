%%%-------------------------------------------------------------------
%%% @doc EUnit tests for claude_agent_session public contracts.
%%%
%%% The protocol-level behavior is covered by adapter/contract tests and
%%% public wrapper coverage. This suite intentionally avoids synthetic CLI
%%% processes and keeps only direct surface guarantees.
%%%-------------------------------------------------------------------
-module(claude_agent_session_tests).

-include_lib("eunit/include/eunit.hrl").

send_query_not_connected_test_() ->
    {"send_query to non-existent process exits",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, claude_agent_session:send_query(Pid, <<"test">>, #{}, 100))
     end}.

receive_message_not_connected_test_() ->
    {"receive_message to non-existent process exits",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, claude_agent_session:receive_message(Pid, make_ref(), 100))
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

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI fails in init",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          process_flag(trap_exit, true),
          #{level := OldLevel} = logger:get_primary_config(),
          logger:set_primary_config(level, none),
          Result = claude_agent_session:start_link(#{
              cli_path => "/nonexistent/path/to/claude_that_doesnt_exist"
          }),
          logger:set_primary_config(level, OldLevel),
          ?assertMatch({error, {transport_start_failed, _}}, Result),
          process_flag(trap_exit, false)
      end}}.
