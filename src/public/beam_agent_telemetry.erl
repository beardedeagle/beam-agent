-module(beam_agent_telemetry).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for telemetry helpers inside `beam_agent`.".

-export([span_start/3, span_stop/3, span_exception/3, state_change/3, buffer_overflow/2]).

span_start(Agent, EventSuffix, Metadata) ->
    beam_agent_telemetry_core:span_start(Agent, EventSuffix, Metadata).
span_stop(Agent, EventSuffix, StartTime) ->
    beam_agent_telemetry_core:span_stop(Agent, EventSuffix, StartTime).
span_exception(Agent, EventSuffix, Reason) ->
    beam_agent_telemetry_core:span_exception(Agent, EventSuffix, Reason).
state_change(Agent, FromState, ToState) ->
    beam_agent_telemetry_core:state_change(Agent, FromState, ToState).
buffer_overflow(BufferSize, Max) ->
    beam_agent_telemetry_core:buffer_overflow(BufferSize, Max).
