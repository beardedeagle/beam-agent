-module(beam_agent_transport_http_sse).
-compile([nowarn_missing_spec]).
-moduledoc "Reusable SSE parsing helpers for HTTP streaming backends.".

-export([new_state/0, parse_chunk/2, buffer_size/1]).
-export_type([sse_event/0, parse_state/0]).

-type sse_event() :: opencode_sse:sse_event().
-type parse_state() :: opencode_sse:parse_state().

new_state() -> opencode_sse:new_state().
parse_chunk(Chunk, State) -> opencode_sse:parse_chunk(Chunk, State).
buffer_size(State) -> opencode_sse:buffer_size(State).
