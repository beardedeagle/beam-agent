-module(beam_agent_telemetry_core).
-moduledoc false.

-export([
    span_start/3,
    span_stop/3,
    span_stop/4,
    span_exception/3,
    span_exception/4,
    state_change/3,
    buffer_overflow/2
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Emit a span start event. Returns monotonic start time for duration calculation in span_stop/3.".
-spec span_start(atom(), atom(), map()) -> integer().
span_start(Agent, EventSuffix, Metadata) ->
    StartTime = erlang:monotonic_time(),
    maybe_execute(
        [beam_agent, Agent, EventSuffix, start],
        #{system_time => erlang:system_time()},
        Metadata#{agent => Agent}
    ),
    StartTime.

-doc "Emit a span stop event with duration measurement.".
-spec span_stop(atom(), atom(), integer()) -> ok.
span_stop(Agent, EventSuffix, StartTime) ->
    Duration = erlang:monotonic_time() - StartTime,
    maybe_execute(
        [beam_agent, Agent, EventSuffix, stop],
        #{duration => Duration},
        #{agent => Agent}
    ).

-doc "Emit a span stop event with duration measurement and additional metadata.".
-spec span_stop(atom(), atom(), integer(), map()) -> ok.
span_stop(Agent, EventSuffix, StartTime, Metadata) when is_map(Metadata) ->
    Duration = erlang:monotonic_time() - StartTime,
    maybe_execute(
        [beam_agent, Agent, EventSuffix, stop],
        #{duration => Duration},
        Metadata#{agent => Agent}
    ).

-doc "Emit a span exception event.".
-spec span_exception(atom(), atom(), term()) -> ok.
span_exception(Agent, EventSuffix, Reason) ->
    maybe_execute(
        [beam_agent, Agent, EventSuffix, exception],
        #{system_time => erlang:system_time()},
        #{agent => Agent, reason => Reason}
    ).

-doc "Emit a span exception event with additional metadata.".
-spec span_exception(atom(), atom(), term(), map()) -> ok.
span_exception(Agent, EventSuffix, Reason, Metadata) when is_map(Metadata) ->
    maybe_execute(
        [beam_agent, Agent, EventSuffix, exception],
        #{system_time => erlang:system_time()},
        Metadata#{agent => Agent, reason => Reason}
    ).

-doc "Emit a state change event for gen_statem transitions.".
-spec state_change(atom(), atom(), atom()) -> ok.
state_change(Agent, FromState, ToState) ->
    maybe_execute(
        [beam_agent, session, state_change],
        #{system_time => erlang:system_time()},
        #{agent => Agent, from_state => FromState, to_state => ToState}
    ).

-doc "Emit a buffer overflow warning.".
-spec buffer_overflow(pos_integer(), pos_integer()) -> ok.
buffer_overflow(BufferSize, Max) ->
    maybe_execute(
        [beam_agent, buffer, overflow],
        #{buffer_size => BufferSize},
        #{max => Max}
    ).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec maybe_execute([atom()], map(), map()) -> ok.
maybe_execute(Event, Measurements, Metadata) ->
    case erlang:function_exported(telemetry, execute, 3) of
        true ->
            apply(telemetry, execute, [Event, Measurements, Metadata]);
        false ->
            ok
    end.
