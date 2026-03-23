-module(beam_agent_json).
-moduledoc false.

-export([safe_decode_object/1]).

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Safely decode a JSON binary, validating the result is a map.

Returns `{ok, Map}` if the input decodes to a JSON object,
`{error, {not_object, Value}}` if it decodes to a non-object type,
or `{error, {decode_failed, Reason}}` if decoding fails.
""".
-spec safe_decode_object(binary()) -> {ok, map()} | {error, term()}.
safe_decode_object(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {not_object, Other}}
    catch
        error:Reason -> {error, {decode_failed, Reason}}
    end;
safe_decode_object(_) ->
    {error, {decode_failed, not_binary}}.
