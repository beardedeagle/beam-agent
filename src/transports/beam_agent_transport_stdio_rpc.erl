-module(beam_agent_transport_stdio_rpc).
-compile([nowarn_missing_spec]).
-moduledoc "Reusable request/response framing helpers for stdio RPC backends.".

-export([
    encode_request/3,
    encode_notification/2,
    encode_response/2,
    encode_error/3,
    encode_error/4,
    decode/1,
    next_id/0
]).

encode_request(Id, Method, Params) -> beam_agent_jsonrpc:encode_request(Id, Method, Params).
encode_notification(Method, Params) -> beam_agent_jsonrpc:encode_notification(Method, Params).
encode_response(Id, Result) -> beam_agent_jsonrpc:encode_response(Id, Result).
encode_error(Id, Code, Message) -> beam_agent_jsonrpc:encode_error(Id, Code, Message).
encode_error(Id, Code, Message, Data) ->
    beam_agent_jsonrpc:encode_error(Id, Code, Message, Data).
decode(Map) -> beam_agent_jsonrpc:decode(Map).
next_id() -> beam_agent_jsonrpc:next_id().
