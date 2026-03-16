%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_audit (Layer 5).
%%%
%%% Tests cover:
%%%   - Sequential trace: start/stop audit trail
%%%   - Token verification: label, send, receive, timestamp
%%%   - System monitor: install/uninstall on self()
%%%   - handle_monitor_message/1 pure function routing
%%%
%%% These tests use real seq_trace and system_monitor — no test doubles.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_audit_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Sequential Trace
%%====================================================================

start_audit_trail_sets_tokens_test() ->
    Label = make_ref(),
    beam_agent_command_audit:start_audit_trail(Label),
    Token = seq_trace:get_token(),
    ?assertNotEqual([], Token),
    beam_agent_command_audit:stop_audit_trail().

stop_audit_trail_clears_tokens_test() ->
    beam_agent_command_audit:start_audit_trail(make_ref()),
    beam_agent_command_audit:stop_audit_trail(),
    Token = seq_trace:get_token(),
    ?assertEqual([], Token).

start_audit_trail_preserves_label_test() ->
    Label = make_ref(),
    beam_agent_command_audit:start_audit_trail(Label),
    {label, Got} = seq_trace:get_token(label),
    ?assertEqual(Label, Got),
    beam_agent_command_audit:stop_audit_trail().

start_audit_trail_enables_send_test() ->
    beam_agent_command_audit:start_audit_trail(make_ref()),
    {send, Val} = seq_trace:get_token(send),
    ?assert(Val),
    beam_agent_command_audit:stop_audit_trail().

start_audit_trail_enables_receive_test() ->
    beam_agent_command_audit:start_audit_trail(make_ref()),
    {'receive', Val} = seq_trace:get_token('receive'),
    ?assert(Val),
    beam_agent_command_audit:stop_audit_trail().

start_audit_trail_enables_timestamp_test() ->
    beam_agent_command_audit:start_audit_trail(make_ref()),
    {timestamp, Val} = seq_trace:get_token(timestamp),
    ?assert(Val),
    beam_agent_command_audit:stop_audit_trail().

%%====================================================================
%% Idempotency
%%====================================================================

stop_audit_trail_idempotent_test() ->
    %% Stopping when never started should not crash
    ?assertEqual(ok, beam_agent_command_audit:stop_audit_trail()),
    ?assertEqual(ok, beam_agent_command_audit:stop_audit_trail()).

start_stop_cycle_test() ->
    %% Multiple start/stop cycles should work cleanly
    beam_agent_command_audit:start_audit_trail(ref1),
    beam_agent_command_audit:stop_audit_trail(),
    beam_agent_command_audit:start_audit_trail(ref2),
    {label, Got} = seq_trace:get_token(label),
    ?assertEqual(ref2, Got),
    beam_agent_command_audit:stop_audit_trail(),
    ?assertEqual([], seq_trace:get_token()).

%%====================================================================
%% System Monitor — install/uninstall on self()
%%====================================================================

install_system_monitor_sets_self_test() ->
    %% install_system_monitor/0 sets self() as the VM system monitor.
    beam_agent_command_audit:install_system_monitor(),
    {Pid, _Opts} = erlang:system_monitor(),
    ?assertEqual(self(), Pid),
    beam_agent_command_audit:uninstall_system_monitor().

uninstall_system_monitor_clears_test() ->
    beam_agent_command_audit:install_system_monitor(),
    beam_agent_command_audit:uninstall_system_monitor(),
    Result = erlang:system_monitor(),
    ?assertEqual(undefined, Result).

uninstall_system_monitor_idempotent_test() ->
    %% Uninstalling when never installed should not crash
    ?assertEqual(ok, beam_agent_command_audit:uninstall_system_monitor()).

install_system_monitor_with_custom_opts_test() ->
    beam_agent_command_audit:install_system_monitor(#{
        long_gc => 100,
        long_schedule => 200,
        large_heap => 5_000_000,
        busy_port => false
    }),
    {Pid, Opts} = erlang:system_monitor(),
    ?assertEqual(self(), Pid),
    ?assert(lists:member({long_gc, 100}, Opts)),
    ?assert(lists:member({long_schedule, 200}, Opts)),
    ?assert(lists:member({large_heap, 5000000}, Opts)),
    ?assertNot(lists:member(busy_port, Opts)),
    beam_agent_command_audit:uninstall_system_monitor().

install_system_monitor_defaults_include_busy_port_test() ->
    beam_agent_command_audit:install_system_monitor(),
    {_Pid, Opts} = erlang:system_monitor(),
    ?assert(lists:member(busy_port, Opts)),
    beam_agent_command_audit:uninstall_system_monitor().

%%====================================================================
%% handle_monitor_message/1 — pure function tests
%%====================================================================

handle_monitor_message_long_gc_test() ->
    Msg = {monitor, self(), long_gc, [{timeout, 55}]},
    Result = beam_agent_command_audit:handle_monitor_message(Msg),
    ?assertMatch({alarm, long_gc, #{pid := _, info := _}}, Result).

handle_monitor_message_long_schedule_test() ->
    Msg = {monitor, self(), long_schedule, [{timeout, 60}]},
    Result = beam_agent_command_audit:handle_monitor_message(Msg),
    ?assertMatch({alarm, long_schedule, #{pid := _, info := _}}, Result).

handle_monitor_message_large_heap_test() ->
    Msg = {monitor, self(), large_heap, 15_000_000},
    Result = beam_agent_command_audit:handle_monitor_message(Msg),
    ?assertMatch({alarm, large_heap, #{pid := _, heap_size := 15000000}}, Result).

handle_monitor_message_busy_port_test() ->
    PortKey = busy_port_key,
    Msg = {monitor, self(), busy_port, PortKey},
    Result = beam_agent_command_audit:handle_monitor_message(Msg),
    ?assertMatch({alarm, busy_port, #{pid := _, port := _}}, Result).

handle_monitor_message_unknown_ignored_test() ->
    ?assertEqual(ignore,
        beam_agent_command_audit:handle_monitor_message({unexpected, data})).

handle_monitor_message_preserves_details_test() ->
    Msg = {monitor, self(), long_gc, [{timeout, 42}]},
    {alarm, long_gc, Details} =
        beam_agent_command_audit:handle_monitor_message(Msg),
    ?assertEqual(self(), maps:get(pid, Details)),
    ?assertEqual([{timeout, 42}], maps:get(info, Details)).
