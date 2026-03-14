%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_telemetry_core (telemetry event helpers).
%%%
%%% Tests cover:
%%%   - span_start/3: emits [beam_agent, Agent, EventSuffix, start] event,
%%%     returns integer monotonic start time
%%%   - span_stop/3: emits [beam_agent, Agent, EventSuffix, stop] event
%%%     with duration measurement
%%%   - span_exception/3: emits [beam_agent, Agent, EventSuffix, exception]
%%%     event with reason in metadata
%%%   - state_change/3: emits [beam_agent, session, state_change] event
%%%     with from_state/to_state in metadata
%%%   - buffer_overflow/2: emits [beam_agent, buffer, overflow] event with
%%%     buffer_size measurement and max metadata
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_telemetry_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% span_start/3 tests
%%====================================================================

span_start_returns_integer_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_span_start_returns_integer">>,
    telemetry:attach(HandlerId,
        [beam_agent, claude, query, start],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(claude, query,
        #{session => <<"s1">>}),
    ?assert(is_integer(StartTime)),
    telemetry:detach(HandlerId).

span_start_emits_start_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_start_emits_event">>,
    telemetry:attach(HandlerId,
        [beam_agent, claude, query, start],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    _StartTime = beam_agent_telemetry_core:span_start(claude, query,
        #{session => <<"s2">>}),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_map(Measurements)),
            ?assert(is_integer(maps:get(system_time, Measurements))),
            ?assertEqual(claude, maps:get(agent, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_start_includes_caller_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_start_caller_metadata">>,
    telemetry:attach(HandlerId,
        [beam_agent, gemini, query, start],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    _StartTime = beam_agent_telemetry_core:span_start(gemini, query,
        #{custom_key => <<"custom_val">>}),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual(<<"custom_val">>, maps:get(custom_key, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_start_agent_injected_into_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_start_agent_injected">>,
    telemetry:attach(HandlerId,
        [beam_agent, codex, exec, start],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    _StartTime = beam_agent_telemetry_core:span_start(codex, exec, #{}),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual(codex, maps:get(agent, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

%%====================================================================
%% span_stop/3 tests
%%====================================================================

span_stop_emits_stop_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_stop_emits_event">>,
    telemetry:attach(HandlerId,
        [beam_agent, claude, query, stop],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(claude, query, #{}),
    ok = beam_agent_telemetry_core:span_stop(claude, query, StartTime),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_map(Measurements)),
            Duration = maps:get(duration, Measurements),
            ?assert(is_integer(Duration)),
            ?assert(Duration >= 0),
            ?assertEqual(claude, maps:get(agent, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_stop_duration_is_non_negative_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_stop_duration_non_negative">>,
    telemetry:attach(HandlerId,
        [beam_agent, gemini, stream, stop],
        fun(_EventName, Measurements, _Metadata, _Config) ->
            Self ! {telemetry_event, Measurements}
        end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(gemini, stream, #{}),
    timer:sleep(5),
    ok = beam_agent_telemetry_core:span_stop(gemini, stream, StartTime),
    receive
        {telemetry_event, Measurements} ->
            Duration = maps:get(duration, Measurements),
            ?assert(Duration > 0)
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_stop_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_span_stop_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, codex, exec, stop],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(codex, exec, #{}),
    Result = beam_agent_telemetry_core:span_stop(codex, exec, StartTime),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

%%====================================================================
%% span_exception/3 tests
%%====================================================================

span_exception_emits_exception_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_exception_emits_event">>,
    telemetry:attach(HandlerId,
        [beam_agent, claude, query, exception],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:span_exception(claude, query, timeout),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_map(Measurements)),
            ?assert(is_integer(maps:get(system_time, Measurements))),
            ?assertEqual(claude, maps:get(agent, Metadata)),
            ?assertEqual(timeout, maps:get(reason, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_exception_reason_in_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_exception_reason">>,
    telemetry:attach(HandlerId,
        [beam_agent, gemini, stream, exception],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:span_exception(gemini, stream,
        {error, connection_refused}),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual({error, connection_refused},
                maps:get(reason, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_exception_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_span_exception_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, codex, exec, exception],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    Result = beam_agent_telemetry_core:span_exception(codex, exec, some_reason),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

span_exception_agent_in_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_exception_agent_meta">>,
    telemetry:attach(HandlerId,
        [beam_agent, opencode, query, exception],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:span_exception(opencode, query, crash),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual(opencode, maps:get(agent, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

%%====================================================================
%% state_change/3 tests
%%====================================================================

state_change_emits_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_state_change_emits_event">>,
    telemetry:attach(HandlerId,
        [beam_agent, session, state_change],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:state_change(claude, idle, running),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_map(Measurements)),
            ?assert(is_integer(maps:get(system_time, Measurements))),
            ?assertEqual(claude, maps:get(agent, Metadata)),
            ?assertEqual(idle, maps:get(from_state, Metadata)),
            ?assertEqual(running, maps:get(to_state, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

state_change_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_state_change_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, session, state_change],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    Result = beam_agent_telemetry_core:state_change(gemini, connecting, connected),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

state_change_different_agents_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_state_change_agents">>,
    telemetry:attach(HandlerId,
        [beam_agent, session, state_change],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:state_change(copilot, starting, ready),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual(copilot, maps:get(agent, Metadata)),
            ?assertEqual(starting, maps:get(from_state, Metadata)),
            ?assertEqual(ready, maps:get(to_state, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

state_change_event_name_is_fixed_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    %% Regardless of the agent argument, the event name is always
    %% [beam_agent, session, state_change].
    Self = self(),
    HandlerId = <<"test_state_change_fixed_name">>,
    telemetry:attach(HandlerId,
        [beam_agent, session, state_change],
        fun(EventName, _Measurements, _Metadata, _Config) ->
            Self ! {telemetry_event, EventName}
        end,
        []),
    ok = beam_agent_telemetry_core:state_change(codex, idle, running),
    receive
        {telemetry_event, EventName} ->
            ?assertEqual([beam_agent, session, state_change], EventName)
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

%%====================================================================
%% buffer_overflow/2 tests
%%====================================================================

buffer_overflow_emits_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_buffer_overflow_emits_event">>,
    telemetry:attach(HandlerId,
        [beam_agent, buffer, overflow],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:buffer_overflow(1024, 512),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_map(Measurements)),
            ?assertEqual(1024, maps:get(buffer_size, Measurements)),
            ?assertEqual(512, maps:get(max, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

buffer_overflow_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_buffer_overflow_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, buffer, overflow],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    Result = beam_agent_telemetry_core:buffer_overflow(200, 100),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

buffer_overflow_measurements_contain_size_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_buffer_overflow_size_key">>,
    telemetry:attach(HandlerId,
        [beam_agent, buffer, overflow],
        fun(_EventName, Measurements, _Metadata, _Config) ->
            Self ! {telemetry_event, Measurements}
        end,
        []),
    ok = beam_agent_telemetry_core:buffer_overflow(9999, 100),
    receive
        {telemetry_event, Measurements} ->
            ?assertEqual(9999, maps:get(buffer_size, Measurements))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

buffer_overflow_metadata_contains_max_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_buffer_overflow_max_key">>,
    telemetry:attach(HandlerId,
        [beam_agent, buffer, overflow],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:buffer_overflow(500, 250),
    receive
        {telemetry_event, Metadata} ->
            ?assertEqual(250, maps:get(max, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

%%====================================================================
%% span_stop/4 tests (with metadata)
%%====================================================================

span_stop_4_emits_stop_with_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_stop_4_metadata">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, stop],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(command, run, #{}),
    ok = beam_agent_telemetry_core:span_stop(command, run, StartTime,
        #{exit_code => 0, cwd => <<"/tmp">>}),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_integer(maps:get(duration, Measurements))),
            ?assertEqual(command, maps:get(agent, Metadata)),
            ?assertEqual(0, maps:get(exit_code, Metadata)),
            ?assertEqual(<<"/tmp">>, maps:get(cwd, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_stop_4_duration_non_negative_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_stop_4_duration">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, stop],
        fun(_EventName, Measurements, _Metadata, _Config) ->
            Self ! {telemetry_event, Measurements}
        end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(command, run, #{}),
    timer:sleep(5),
    ok = beam_agent_telemetry_core:span_stop(command, run, StartTime,
        #{exit_code => 0}),
    receive
        {telemetry_event, Measurements} ->
            ?assert(maps:get(duration, Measurements) > 0)
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_stop_4_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_span_stop_4_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, stop],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    StartTime = beam_agent_telemetry_core:span_start(command, run, #{}),
    Result = beam_agent_telemetry_core:span_stop(command, run, StartTime, #{}),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

%%====================================================================
%% span_exception/4 tests (with metadata)
%%====================================================================

span_exception_4_emits_with_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_exception_4_metadata">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, exception],
        fun(_EventName, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Measurements, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:span_exception(command, run,
        {timeout, 5000}, #{command => <<"sleep 10">>, cwd => undefined}),
    receive
        {telemetry_event, Measurements, Metadata} ->
            ?assert(is_integer(maps:get(system_time, Measurements))),
            ?assertEqual(command, maps:get(agent, Metadata)),
            ?assertEqual({timeout, 5000}, maps:get(reason, Metadata)),
            ?assertEqual(<<"sleep 10">>, maps:get(command, Metadata)),
            ?assertEqual(undefined, maps:get(cwd, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).

span_exception_4_returns_ok_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = <<"test_span_exception_4_returns_ok">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, exception],
        fun(_EventName, _Measurements, _Metadata, _Config) -> ok end,
        []),
    Result = beam_agent_telemetry_core:span_exception(command, run,
        some_error, #{key => val}),
    ?assertEqual(ok, Result),
    telemetry:detach(HandlerId).

span_exception_4_merges_agent_and_reason_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = <<"test_span_exception_4_merge">>,
    telemetry:attach(HandlerId,
        [beam_agent, command, run, exception],
        fun(_EventName, _Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Metadata}
        end,
        []),
    ok = beam_agent_telemetry_core:span_exception(command, run,
        badarg, #{custom => data}),
    receive
        {telemetry_event, Metadata} ->
            %% Agent and reason are injected alongside caller metadata.
            ?assertEqual(command, maps:get(agent, Metadata)),
            ?assertEqual(badarg, maps:get(reason, Metadata)),
            ?assertEqual(data, maps:get(custom, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(HandlerId).
