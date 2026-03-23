-module(beam_agent_json).
-moduledoc false.

-export([safe_decode_object/1, safe_decode/1, max_decode_size/0]).

%% 50 MB — defense-in-depth limit for inputs without an upstream buffer bound.
-define(MAX_JSON_DECODE_SIZE, 52_428_800).

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Safely decode a JSON binary, validating the result is a map.

Returns `{ok, Map}` if the input decodes to a JSON object,
`{error, {not_object, Value}}` if it decodes to a non-object type,
`{error, {json_too_large, Size}}` if the input exceeds 50 MB,
or `{error, {decode_failed, Reason}}` if decoding fails.

The 50 MB limit is defense-in-depth for call sites that do not have an
upstream buffer bound (e.g. SSE buffer limit or WS frame limit).
""".
-spec safe_decode_object(binary()) -> {ok, map()} | {error, term()}.
safe_decode_object(Bin) when is_binary(Bin), byte_size(Bin) > ?MAX_JSON_DECODE_SIZE ->
    {error, {json_too_large, byte_size(Bin)}};
safe_decode_object(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {not_object, Other}}
    catch
        error:Reason -> {error, {decode_failed, Reason}}
    end;
safe_decode_object(_) ->
    {error, {decode_failed, not_binary}}.

-doc """
Safely decode a JSON binary, accepting any JSON value type.

Returns `{ok, Term}` on success,
`{error, {json_too_large, Size}}` if the input exceeds `max_decode_size/0`,
or `{error, {decode_failed, Reason}}` if decoding fails.

Use `safe_decode_object/1` when the caller requires a JSON object (map).
""".
-spec safe_decode(binary()) -> {ok, term()} | {error, term()}.
safe_decode(Bin) when is_binary(Bin), byte_size(Bin) > ?MAX_JSON_DECODE_SIZE ->
    {error, {json_too_large, byte_size(Bin)}};
safe_decode(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Result -> {ok, Result}
    catch
        error:Reason -> {error, {decode_failed, Reason}}
    end;
safe_decode(_) ->
    {error, {decode_failed, not_binary}}.

-doc "Defense-in-depth byte-size limit for JSON decoding (50 MB).".
-spec max_decode_size() -> 52_428_800.
max_decode_size() -> ?MAX_JSON_DECODE_SIZE.
