-module(beam_agent_jsonrpc).
-moduledoc """
Shared JSON-RPC encoding/decoding for Codex wire protocol.

Pure functions for the JSON-RPC envelope used by Codex CLI.
CRITICAL: Codex does NOT include `"jsonrpc": "2.0"` on the wire.
Our encoder matches this behaviour exactly.

Uses OTP 27+ `json` module -- no external JSON dependency.
""".

-export([
    %% Encoding (returns iodata, newline-terminated)
    encode_request/3,
    encode_notification/2,
    encode_response/2,
    encode_error/3,
    encode_error/4,
    %% Decoding (takes already-decoded JSON map)
    decode/1,
    %% ID generation (monotonic integer counter via process dict)
    next_id/0
]).

-export_type([
    request_id/0,
    jsonrpc_msg/0
]).

%% encode functions intentionally return iolist() matching iodata() supertype.
-dialyzer({nowarn_function, [
    encode_request/3,
    encode_notification/2,
    encode_response/2,
    encode_error/3,
    encode_error/4
]}).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type request_id() :: binary() | integer().

-type jsonrpc_msg() ::
    {request, request_id(), binary(), map() | undefined}
  | {notification, binary(), map() | undefined}
  | {response, request_id(), term()}
  | {error_response, request_id(), integer(), binary(), term() | undefined}
  | {unknown, map()}.

%%====================================================================
%% Encoding API
%%====================================================================

-doc "Encode a JSON-RPC request (has method + id). No \"jsonrpc\" field -- Codex omits it on the wire.".
-spec encode_request(request_id(), binary(), map() | undefined) -> iodata().
encode_request(Id, Method, undefined) ->
    [json:encode(#{<<"id">> => Id, <<"method">> => Method}), $\n];
encode_request(Id, Method, Params) when is_map(Params) ->
    [json:encode(#{<<"id">> => Id, <<"method">> => Method,
                   <<"params">> => Params}), $\n].

-doc "Encode a JSON-RPC notification (has method, no id).".
-spec encode_notification(binary(), map() | undefined) -> iodata().
encode_notification(Method, undefined) ->
    [json:encode(#{<<"method">> => Method}), $\n];
encode_notification(Method, Params) when is_map(Params) ->
    [json:encode(#{<<"method">> => Method, <<"params">> => Params}), $\n].

-doc "Encode a successful JSON-RPC response.".
-spec encode_response(request_id(), term()) -> iodata().
encode_response(Id, Result) ->
    [json:encode(#{<<"id">> => Id, <<"result">> => Result}), $\n].

-doc "Encode a JSON-RPC error response (without data).".
-spec encode_error(request_id(), integer(), binary()) -> iodata().
encode_error(Id, Code, Message) ->
    [json:encode(#{<<"id">> => Id,
                   <<"error">> => #{<<"code">> => Code,
                                    <<"message">> => Message}}), $\n].

-doc "Encode a JSON-RPC error response (with data).".
-spec encode_error(request_id(), integer(), binary(), term()) -> iodata().
encode_error(Id, Code, Message, Data) ->
    [json:encode(#{<<"id">> => Id,
                   <<"error">> => #{<<"code">> => Code,
                                    <<"message">> => Message,
                                    <<"data">> => Data}}), $\n].

%%====================================================================
%% Decoding API
%%====================================================================

-doc "Decode a JSON map into a typed JSON-RPC message. Handles requests, notifications, responses, and errors.".
-spec decode(map()) -> jsonrpc_msg().
decode(#{<<"method">> := Method, <<"id">> := Id} = Raw) ->
    %% Request (has both method and id)
    {request, Id, Method, maps:get(<<"params">>, Raw, undefined)};
decode(#{<<"method">> := Method} = Raw) ->
    %% Notification (method, no id)
    {notification, Method, maps:get(<<"params">>, Raw, undefined)};
decode(#{<<"id">> := Id, <<"error">> := #{<<"code">> := Code,
                                           <<"message">> := Msg} = Err}) ->
    %% Error response (check before success — error field is definitive)
    {error_response, Id, Code, Msg, maps:get(<<"data">>, Err, undefined)};
decode(#{<<"id">> := Id, <<"result">> := Result}) ->
    %% Successful response
    {response, Id, Result};
decode(Other) when is_map(Other) ->
    {unknown, Other}.

%%====================================================================
%% ID Generation
%%====================================================================

-doc """
Generate the next monotonically-increasing integer request ID.

Uses process dictionary for per-process state (appropriate for
gen_statem processes where each session has its own counter).
""".
-spec next_id() -> integer().
next_id() ->
    Id = case get({?MODULE, next_id}) of
        undefined -> 1;
        N -> N
    end,
    put({?MODULE, next_id}, Id + 1),
    Id.
