%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_audit (Layer 5).
%%%
%%% Tests cover:
%%%   - Sequential trace: start/stop audit trail
%%%   - System monitor: start/stop, idempotent stop
%%%   - Resource alarm telemetry emission
%%%
%%% These tests use real seq_trace and system_monitor — no mocks.
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
%% System Monitor — lifecycle
%%====================================================================

start_monitor_sets_system_monitor_test() ->
    beam_agent_command_audit:start_monitor(),
    try
        MonSetting = erlang:system_monitor(),
        ?assertMatch({_Pid, _Opts}, MonSetting),
        {Pid, _} = MonSetting,
        ?assert(is_pid(Pid)),
        ?assert(is_process_alive(Pid))
    after
        beam_agent_command_audit:stop_monitor()
    end.

stop_monitor_clears_system_monitor_test() ->
    beam_agent_command_audit:start_monitor(),
    beam_agent_command_audit:stop_monitor(),
    ?assertEqual(undefined, erlang:system_monitor()).

stop_monitor_idempotent_test() ->
    %% Calling stop when not started should not crash
    ?assertEqual(ok, beam_agent_command_audit:stop_monitor()),
    ?assertEqual(ok, beam_agent_command_audit:stop_monitor()).

start_monitor_replaces_previous_test() ->
    beam_agent_command_audit:start_monitor(),
    {Pid1, _} = erlang:system_monitor(),
    beam_agent_command_audit:start_monitor(),
    try
        {Pid2, _} = erlang:system_monitor(),
        ?assertNotEqual(Pid1, Pid2),
        %% Old monitor process should be dead
        ?assertNot(is_process_alive(Pid1)),
        ?assert(is_process_alive(Pid2))
    after
        beam_agent_command_audit:stop_monitor()
    end.

start_monitor_custom_thresholds_test() ->
    beam_agent_command_audit:start_monitor(#{
        long_gc => 100,
        long_schedule => 200,
        large_heap => 5_000_000,
        busy_port => false
    }),
    try
        {_Pid, Opts} = erlang:system_monitor(),
        ?assert(lists:member({long_gc, 100}, Opts)),
        ?assert(lists:member({long_schedule, 200}, Opts)),
        ?assert(lists:member({large_heap, 5_000_000}, Opts)),
        ?assertNot(lists:member(busy_port, Opts))
    after
        beam_agent_command_audit:stop_monitor()
    end.

%%====================================================================
%% Resource alarm telemetry
%%====================================================================

resource_alarm_large_heap_telemetry_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_resource_alarm_large_heap">>,
    telemetry:attach(HandlerId,
        [beam_agent, security, resource_alarm],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {resource_alarm, Metadata}
        end,
        []),
    beam_agent_command_audit:start_monitor(),
    try
        MonPid = persistent_term:get(beam_agent_audit_monitor_pid),
        %% Send a simulated system_monitor message directly
        MonPid ! {monitor, self(), large_heap, 999999},
        receive
            {resource_alarm, Meta} ->
                ?assertEqual(large_heap, maps:get(alarm_type, Meta)),
                ?assertEqual(999999, maps:get(heap_size, Meta)),
                ?assertEqual(self(), maps:get(pid, Meta))
        after 1000 ->
            ?assert(false)
        end
    after
        beam_agent_command_audit:stop_monitor(),
        telemetry:detach(HandlerId)
    end.

resource_alarm_long_gc_telemetry_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_resource_alarm_long_gc">>,
    telemetry:attach(HandlerId,
        [beam_agent, security, resource_alarm],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {resource_alarm, Metadata}
        end,
        []),
    beam_agent_command_audit:start_monitor(),
    try
        MonPid = persistent_term:get(beam_agent_audit_monitor_pid),
        FakeInfo = [{timeout, 100}],
        MonPid ! {monitor, self(), long_gc, FakeInfo},
        receive
            {resource_alarm, Meta} ->
                ?assertEqual(long_gc, maps:get(alarm_type, Meta)),
                ?assertEqual(FakeInfo, maps:get(info, Meta))
        after 1000 ->
            ?assert(false)
        end
    after
        beam_agent_command_audit:stop_monitor(),
        telemetry:detach(HandlerId)
    end.

resource_alarm_busy_port_telemetry_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_resource_alarm_busy_port">>,
    telemetry:attach(HandlerId,
        [beam_agent, security, resource_alarm],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {resource_alarm, Metadata}
        end,
        []),
    beam_agent_command_audit:start_monitor(),
    try
        MonPid = persistent_term:get(beam_agent_audit_monitor_pid),
        %% Use a fake port-like value for testing
        MonPid ! {monitor, self(), busy_port, fake_port},
        receive
            {resource_alarm, Meta} ->
                ?assertEqual(busy_port, maps:get(alarm_type, Meta)),
                ?assertEqual(fake_port, maps:get(port, Meta))
        after 1000 ->
            ?assert(false)
        end
    after
        beam_agent_command_audit:stop_monitor(),
        telemetry:detach(HandlerId)
    end.
