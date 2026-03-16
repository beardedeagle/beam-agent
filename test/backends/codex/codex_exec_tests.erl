%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_exec public contracts.
%%%-------------------------------------------------------------------
-module(codex_exec_tests).

-include_lib("eunit/include/eunit.hrl").

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

bad_cli_path_exec_test_() ->
    {"start_link with nonexistent CLI starts but query fails on port open",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          {ok, Pid} = codex_exec:start_link(#{
              cli_path => "/nonexistent/path/to/codex_that_doesnt_exist"
          }),
          ?assertEqual(ready, codex_exec:health(Pid)),
          Result = codex_exec:send_query(Pid, <<"test">>, #{}, 5000),
          ?assertMatch({error, {open_port_failed, _}}, Result),
          codex_exec:stop(Pid)
      end}}.
