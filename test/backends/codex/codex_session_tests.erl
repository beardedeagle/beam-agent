%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_session public contracts.
%%%-------------------------------------------------------------------
-module(codex_session_tests).

-include_lib("eunit/include/eunit.hrl").

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

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI fails",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          process_flag(trap_exit, true),
          #{level := OldLevel} = logger:get_primary_config(),
          logger:set_primary_config(level, none),
          Result = codex_session:start_link(#{
              cli_path => "/nonexistent/path/to/codex_that_doesnt_exist"
          }),
          logger:set_primary_config(level, OldLevel),
          ?assertMatch({error, {transport_start_failed, _}}, Result),
          process_flag(trap_exit, false)
      end}}.
