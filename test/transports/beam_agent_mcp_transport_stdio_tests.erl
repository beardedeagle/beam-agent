%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_transport_stdio PATH resolution.
%%%
%%% Verifies that start/1 resolves bare executable names via
%%% beam_agent_command_core:resolve_executable/1 before calling
%%% open_port({spawn_executable, ...}).
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_transport_stdio_tests).

-include_lib("eunit/include/eunit.hrl").

%% A clearly nonexistent program name that will never be in PATH.
-define(BOGUS_EXE, "beam_agent_nonexistent_exe_72f9a1").

not_found_returns_error_test() ->
    Result = beam_agent_mcp_transport_stdio:start(#{executable => ?BOGUS_EXE}),
    ?assertMatch({error, {executable_not_found, _}}, Result).

missing_option_returns_error_test() ->
    ?assertEqual({error, {missing_option, executable}},
                 beam_agent_mcp_transport_stdio:start(#{})).
