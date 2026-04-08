%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport_port PATH resolution.
%%%
%%% Verifies that start/1 resolves bare executable names via
%%% beam_agent_command_core:resolve_executable/1 before calling
%%% open_port({spawn_executable, ...}).
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_transport_port_tests).

-include_lib("eunit/include/eunit.hrl").

%% A clearly nonexistent program name that will never be in PATH.
-define(BOGUS_EXE, "beam_agent_nonexistent_exe_72f9a1").

not_found_returns_error_test() ->
    Result = beam_agent_transport_port:start(#{executable => ?BOGUS_EXE}),
    ?assertMatch({error, {executable_not_found, _}}, Result).

missing_option_returns_error_test() ->
    ?assertEqual({error, {missing_option, executable}},
                 beam_agent_transport_port:start(#{})).

%% Positive path — a bare name in $PATH resolves and starts a port.
bare_name_resolves_via_path_test() ->
    {ok, Port} = beam_agent_transport_port:start(
        #{executable => "sh", args => ["-c", "exit 0"]}
    ),
    %% Drain the exit_status message to keep the mailbox clean.
    receive
        {Port, {exit_status, _}} -> ok
    after
        5000 -> ok
    end,
    catch port_close(Port),
    ok.
