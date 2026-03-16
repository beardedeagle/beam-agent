%%%-------------------------------------------------------------------
%%% @doc EUnit tests for gemini_cli_session public contracts.
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
