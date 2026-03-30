-module(beam_agent_telemetry).
-moduledoc """
OpenTelemetry-style span and event emission for the BeamAgent SDK.

All five backend session handlers emit telemetry events via this module so that
consuming applications can attach handlers once and observe every backend
uniformly. No OTLP export or collector is built in — this module follows the
Erlang/OTP `telemetry` convention: the library emits events, applications handle
them.

== Optional dependency

The `telemetry` library is an *optional* dependency. When present, events are
emitted via `telemetry:execute/3`. When absent, all emission is a silent no-op
with zero overhead. To enable telemetry, add `{telemetry, \"~> 1.3\"}` to your
application's `deps` in `rebar.config` and include `telemetry` in your
application's `applications` list.

== Event namespace

All events are published under the `[beam_agent, ...]` prefix. The Agent
parameter (an atom such as `claude` or `codex`) becomes the second element of
the event name list:

```
[beam_agent, claude, query, start]
[beam_agent, claude, query, stop]
[beam_agent, claude, query, exception]
[beam_agent, command, run, start]       %% shell command execution
[beam_agent, command, run, stop]        %% includes exit_code in metadata
[beam_agent, command, run, exception]   %% timeout or port failure
[beam_agent, session, state_change]     %% backend session lifecycle
[beam_agent, run, state_change]         %% canonical run lifecycle
[beam_agent, buffer, overflow]          %% always at this fixed path
```

== Span lifecycle

A span covers a single unit of work. Start it with `span_start/3`, which
returns a monotonic start time. Pass that time to `span_stop/3` when the work
completes normally, or to `span_exception/3` if it raises.

```erlang
StartTime = beam_agent_telemetry:span_start(claude, query, #{prompt_length => 42}),
%% ... do work ...
beam_agent_telemetry:span_stop(claude, query, StartTime).
```

== Attaching handlers

Use the standard `telemetry:attach/4` or `telemetry:attach_many/4` call in your
application startup:

```erlang
telemetry:attach_many(
    my_handler,
    [
        [beam_agent, claude, query, start],
        [beam_agent, claude, query, stop]
    ],
    fun my_telemetry_handler:handle/4,
    []
).
```
""".

-export([
    span_start/3,
    span_stop/3,
    span_stop/4,
    span_exception/3,
    span_exception/4,
    state_change/3,
    state_change/4,
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

-doc "Emit a state change event for a non-session BeamAgent domain.".
-spec state_change(atom(), atom(), atom(), map()) -> ok.
state_change(Domain, FromState, ToState, Metadata) when is_map(Metadata) ->
    maybe_execute(
        [beam_agent, Domain, state_change],
        #{system_time => erlang:system_time()},
        Metadata#{
            agent => Domain,
            from_state => FromState,
            to_state => ToState
        }
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
