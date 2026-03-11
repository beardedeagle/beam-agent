-module(beam_agent_jsonl).
-moduledoc false.

-export([
    extract_lines/1,
    extract_line/1,
    decode_line/1,
    encode_line/1
]).

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Split buffer on newlines. Returns all complete lines and the
remaining partial line. Caller stores the remaining buffer.

Example:

```erlang
extract_lines(<<"{\"a\":1}\n{\"b\":2}\npartial">>)
%% => {[<<"{\"a\":1}">>, <<"{\"b\":2}">>], <<"partial">>}
```
""".
-spec extract_lines(binary()) -> {[binary()], binary()}.
extract_lines(Buffer) ->
    case binary:split(Buffer, <<"\n">>, [global]) of
        [Single] ->
            %% No newline found — entire buffer is a partial line
            {[], Single};
        Parts ->
            {Lines, [Remaining]} = lists:split(length(Parts) - 1, Parts),
            {[L || L <- Lines, L =/= <<>>], Remaining}
    end.

-doc """
Extract a single complete JSONL line from the buffer.

Returns `{ok, Line, Rest}` if a complete line exists, or
`none` if the buffer has no complete line yet.

This is the demand-driven primitive: the gen_statem calls this
only when a consumer has requested a message, implementing
pull-based backpressure.
""".
-spec extract_line(binary()) -> {ok, binary(), binary()} | none.
extract_line(Buffer) ->
    case binary:split(Buffer, <<"\n">>) of
        [_Single] ->
            %% No newline — no complete line yet
            none;
        [<<>>, Rest] ->
            %% Empty line (consecutive newlines) — skip and retry
            extract_line(Rest);
        [Line, Rest] ->
            {ok, Line, Rest}
    end.

-doc "Decode a single JSONL line into an Erlang map. Uses OTP 27+ json module (no external deps).".
-spec decode_line(binary()) -> {ok, map()} | {error, term()}.
decode_line(<<>>) ->
    {error, empty_line};
decode_line(Line) ->
    try json:decode(Line) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {not_object, Other}}
    catch
        error:Reason -> {error, {json_decode, Reason}}
    end.

-doc "Encode an Erlang map as a JSONL line (with trailing newline).".
-dialyzer({nowarn_function, encode_line/1}).
-spec encode_line(map()) -> iolist().
encode_line(Map) when is_map(Map) ->
    [json:encode(Map), $\n].
