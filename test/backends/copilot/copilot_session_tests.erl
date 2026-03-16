%%%-------------------------------------------------------------------
%%% @doc EUnit tests for copilot_session public contracts.
%%%-------------------------------------------------------------------
-module(copilot_session_tests).

-include_lib("eunit/include/eunit.hrl").

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
    {"send_query to non-existent process exits",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, copilot_session:send_query(Pid, <<"test">>, #{}, 100))
     end}.

receive_message_not_connected_test_() ->
    {"receive_message to non-existent process exits",
     fun() ->
         Pid = spawn(fun() -> ok end),
         timer:sleep(10),
         ?assertExit(_, copilot_session:receive_message(Pid, make_ref(), 100))
     end}.

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
