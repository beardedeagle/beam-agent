-module(beam_agent_transport_stdio_jsonl).
-compile([nowarn_missing_spec]).
-moduledoc "Reusable JSONL framing helpers for stdio line-oriented backends.".

-export([extract_lines/1, extract_line/1, decode_line/1, encode_line/1]).

extract_lines(Buffer) -> beam_agent_jsonl:extract_lines(Buffer).
extract_line(Buffer) -> beam_agent_jsonl:extract_line(Buffer).
decode_line(Line) -> beam_agent_jsonl:decode_line(Line).
encode_line(Map) -> beam_agent_jsonl:encode_line(Map).
