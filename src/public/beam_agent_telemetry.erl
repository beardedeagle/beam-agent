-module(beam_agent_telemetry).
-moduledoc """
Public wrapper for OpenTelemetry-style span and event emission inside `beam_agent`.

All five backend session handlers emit telemetry events via this module so that
consuming applications can attach handlers once and observe every backend
uniformly. No OTLP export or collector is built in — this module follows the
Erlang/OTP `telemetry` convention: the library emits events, applications handle
them.

## Optional dependency

The `telemetry` library is an **optional** dependency. When present, events are
emitted via `telemetry:execute/3`. When absent, all emission is a silent no-op
with zero overhead. To enable telemetry, add `{telemetry, "~> 1.3"}` to your
application's `deps` in `rebar.config` and include `telemetry` in your
application's `applications` list.

## Event namespace

All events are published under the `[:beam_agent, ...]` prefix. The Agent
parameter (an atom such as `claude` or `codex`) becomes the second element of
the event name list:

```
[:beam_agent, claude, query, start]
[:beam_agent, claude, query, stop]
[:beam_agent, claude, query, exception]
[:beam_agent, session, state_change]     %% always at this fixed path
[:beam_agent, buffer, overflow]          %% always at this fixed path
```

## Span lifecycle

A span covers a single unit of work. Start it with `span_start/3`, which
returns a monotonic start time. Pass that time to `span_stop/3` when the work
completes normally, or to `span_exception/3` if it raises.

```erlang
StartTime = beam_agent_telemetry:span_start(claude, query, #{prompt_length => 42}),
%% ... do work ...
beam_agent_telemetry:span_stop(claude, query, StartTime).
```

## Attaching handlers

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

See the `telemetry` library documentation for handler function signature details.

## Core concepts

Telemetry is event-based instrumentation. The SDK emits events at key
points (session start, query start, query complete, errors) and your
application can subscribe to those events for logging, metrics, or
monitoring dashboards.

You do not call this module to subscribe. Instead, use the standard
telemetry:attach/4 or telemetry:attach_many/4 in your application
startup to register handler functions. This module is what the SDK
uses internally to emit the events.

A span covers a unit of work: span_start/3 begins it (returning a
timestamp), and span_stop/3 or span_exception/3 ends it. The SDK
computes the duration automatically from the start timestamp.

## Architecture deep dive

Events follow the Erlang telemetry library convention: event names are
lists of atoms under the [beam_agent, ...] prefix. The Agent atom
(claude, codex, etc.) is the second element, making it easy to filter
by backend.

Measurements include duration in native time units (computed from
erlang:monotonic_time/0 deltas). Metadata maps carry backend, session_id,
and operation-specific fields. state_change/3 and buffer_overflow/2 are
standalone events outside the span pattern.

Zero overhead when no handlers are attached -- the telemetry library
short-circuits when the handler list is empty. When the telemetry
library is not present, all emission is a silent no-op. This module
delegates to beam_agent_telemetry_core for all emission logic.
""".

-export([span_start/3, span_stop/3, span_exception/3, state_change/3, buffer_overflow/2]).

-doc """
Emit a span start event and return a monotonic start time.

The returned integer must be passed unchanged to `span_stop/3` or
`span_exception/3` so the duration can be computed.

Parameters:
- `Agent` — backend atom, e.g. `claude`, `codex`, `gemini`, `opencode`, `copilot`
- `EventSuffix` — atom labelling the operation, e.g. `query`, `connect`
- `Metadata` — arbitrary map attached to the telemetry event

Returns a monotonic integer (result of `erlang:monotonic_time/0`).

```erlang
T = beam_agent_telemetry:span_start(claude, query, #{session_id => Id}),
%% work...
beam_agent_telemetry:span_stop(claude, query, T).
```
""".
-spec span_start(atom(), atom(), map()) -> integer().
span_start(Agent, EventSuffix, Metadata) ->
    beam_agent_telemetry_core:span_start(Agent, EventSuffix, Metadata).

-doc """
Emit a span stop event, computing duration from the start time returned by `span_start/3`.

The event is published at `[:beam_agent, Agent, EventSuffix, stop]` with a
`duration` measurement in native time units.

Parameters:
- `Agent` — same atom passed to `span_start/3`
- `EventSuffix` — same atom passed to `span_start/3`
- `StartTime` — the integer returned by `span_start/3`
""".
-spec span_stop(atom(), atom(), integer()) -> ok.
span_stop(Agent, EventSuffix, StartTime) ->
    beam_agent_telemetry_core:span_stop(Agent, EventSuffix, StartTime).

-doc """
Emit a span exception event when a unit of work fails.

The event is published at `[:beam_agent, Agent, EventSuffix, exception]`.
Call this instead of `span_stop/3` when the work raised an error or exception.

Parameters:
- `Agent` — backend atom
- `EventSuffix` — operation atom, must match the `span_start/3` call
- `Reason` — the error reason or exception term
""".
-spec span_exception(atom(), atom(), term()) -> ok.
span_exception(Agent, EventSuffix, Reason) ->
    beam_agent_telemetry_core:span_exception(Agent, EventSuffix, Reason).

-doc """
Emit a state change event for a gen_statem transition.

The event is published at the fixed path `[:beam_agent, session, state_change]`.
Backend session handlers call this on every state machine transition so that
consumers can observe the full session lifecycle.

Parameters:
- `Agent` — backend atom identifying which session handler fired
- `FromState` — the state the session is leaving (e.g. `connecting`, `ready`)
- `ToState` — the state the session is entering

Valid state atoms: `connecting`, `initializing`, `ready`, `active_query`, `error`.
""".
-spec state_change(atom(), atom(), atom()) -> ok.
state_change(Agent, FromState, ToState) ->
    beam_agent_telemetry_core:state_change(Agent, FromState, ToState).

-doc """
Emit a buffer overflow warning when accumulated transport data exceeds the limit.

The event is published at the fixed path `[:beam_agent, buffer, overflow]`.
This event fires when the session engine's inbound buffer grows beyond the
configured maximum, which typically signals a misbehaving backend or extremely
large responses.

Parameters:
- `BufferSize` — current size of the buffer in bytes
- `Max` — the configured maximum in bytes
""".
-spec buffer_overflow(pos_integer(), pos_integer()) -> ok.
buffer_overflow(BufferSize, Max) ->
    beam_agent_telemetry_core:buffer_overflow(BufferSize, Max).
