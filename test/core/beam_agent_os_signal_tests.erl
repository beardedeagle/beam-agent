%%%-------------------------------------------------------------------
%%% @doc Tests for beam_agent_os_signal — OS signal delivery via ports.
%%%
%%% All tests use real OS processes. Zero mocks.
%%%
%%% Covers:
%%%   - Signal delivery: SIGINT, SIGTERM, SIGKILL, SIGHUP
%%%   - Error paths: nonexistent PID, invalid PID values
%%%   - Input validation: zero PID, negative PID, non-integer PID, bad signal atom
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_os_signal_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Signal Delivery (real processes)
%%====================================================================

sigint_terminates_sleep_process_test() ->
    {Port, OsPid} = spawn_sleep(),
    ok = beam_agent_os_signal:send_signal(sigint, OsPid),
    assert_process_exits(Port).

sigterm_terminates_sleep_process_test() ->
    {Port, OsPid} = spawn_sleep(),
    ok = beam_agent_os_signal:send_signal(sigterm, OsPid),
    assert_process_exits(Port).

sigkill_terminates_sleep_process_test() ->
    {Port, OsPid} = spawn_sleep(),
    ok = beam_agent_os_signal:send_signal(sigkill, OsPid),
    assert_process_exits(Port).

sighup_terminates_sleep_process_test() ->
    {Port, OsPid} = spawn_sleep(),
    ok = beam_agent_os_signal:send_signal(sighup, OsPid),
    assert_process_exits(Port).

%%====================================================================
%% Error Paths
%%====================================================================

nonexistent_pid_returns_error_test() ->
    %% PID 99999999 almost certainly does not exist on any system.
    {error, {exit_status, _}} =
        beam_agent_os_signal:send_signal(sigint, 99999999).

%%====================================================================
%% Input Validation
%%====================================================================

invalid_pid_zero_test() ->
    ?assertEqual({error, {invalid_pid, 0}},
                 beam_agent_os_signal:send_signal(sigint, 0)).

invalid_pid_negative_test() ->
    ?assertEqual({error, {invalid_pid, -1}},
                 beam_agent_os_signal:send_signal(sigint, -1)).

invalid_pid_atom_test() ->
    ?assertEqual({error, {invalid_pid, foo}},
                 beam_agent_os_signal:send_signal(sigint, foo)).

invalid_pid_binary_test() ->
    ?assertEqual({error, {invalid_pid, <<"123">>}},
                 beam_agent_os_signal:send_signal(sigint, <<"123">>)).

invalid_signal_crashes_test() ->
    ?assertError(function_clause,
                 beam_agent_os_signal:send_signal(bogus, 12345)).

%%====================================================================
%% Helpers
%%====================================================================

%% Spawn a real `sleep 60` process and return its port + OS PID.
-spec spawn_sleep() -> {port(), pos_integer()}.
spawn_sleep() ->
    Port = open_port({spawn, "sleep 60"}, [exit_status]),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    {Port, OsPid}.

%% Assert the port's underlying OS process exits within 5 seconds.
-spec assert_process_exits(port()) -> ok.
assert_process_exits(Port) ->
    receive
        {Port, {exit_status, _}} -> ok
    after 5000 ->
        catch port_close(Port),
        error(process_did_not_terminate)
    end.
