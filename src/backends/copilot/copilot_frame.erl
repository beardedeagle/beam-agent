-module(copilot_frame).
-moduledoc false.
-type json_scalar() :: binary() | number() | boolean() | null.
-type json_value() :: json_scalar() | [json_value()] | json_map().
-type json_map() :: #{binary() => json_value()}.
-type encodable_map() :: #{atom() | binary() | integer() => term()}.
-type content_length_error() ::
          missing_content_length
          | {invalid_content_length, integer() | iodata()}
          | {malformed_header, binary()}.
-export([extract_message/1,extract_messages/1,encode_message/1]).
-export_type([extract_result/0]).
-type extract_result() ::
          {ok, json_map(), Remaining :: binary()} |
          incomplete |
          {error, term()}.
-spec extract_message(binary()) -> extract_result().
extract_message(Buffer) when byte_size(Buffer) =:= 0 ->
    incomplete;
extract_message(Buffer) ->
    case find_header_boundary(Buffer) of
        nomatch ->
            case byte_size(Buffer) > 4096 of
                true ->
                    {error, {header_too_large, byte_size(Buffer)}};
                false ->
                    incomplete
            end;
        {HeaderEnd, BodyStart} ->
            Header = binary:part(Buffer, 0, HeaderEnd),
            case parse_content_length(Header) of
                {ok, ContentLength} ->
                    Available = byte_size(Buffer) - BodyStart,
                    case Available >= ContentLength of
                        true ->
                            Body =
                                binary:part(Buffer, BodyStart,
                                            ContentLength),
                            RestStart = BodyStart + ContentLength,
                            Rest =
                                binary:part(Buffer, RestStart,
                                            byte_size(Buffer)
                                            -
                                            RestStart),
                            decode_body(Body, Rest);
                        false ->
                            incomplete
                    end;
                {error, _} = Err ->
                    Err
            end
    end.
-spec extract_messages(binary()) -> {[json_map()], binary()}.
extract_messages(Buffer) ->
    extract_messages_acc(Buffer, []).
-spec encode_message(encodable_map()) -> [binary(), ...].
encode_message(Msg) when is_map(Msg) ->
    BodyBytes = iolist_to_binary(json:encode(Msg)),
    Length = byte_size(BodyBytes),
    [<<"Content-Length: ">>,
     integer_to_binary(Length),
     <<"\r\n\r\n">>,
     BodyBytes].
-spec find_header_boundary(binary()) ->
                              nomatch | {non_neg_integer(), pos_integer()}.
find_header_boundary(Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        nomatch ->
            nomatch;
        {Pos, 4} ->
            {Pos, Pos + 4}
    end.
-spec parse_content_length(binary()) ->
                              {ok, non_neg_integer()} |
                              {error, content_length_error()}.
parse_content_length(Header) ->
    Lines = binary:split(Header, <<"\r\n">>, [global]),
    parse_cl_lines(Lines).
-spec parse_cl_lines([binary()]) ->
                        {ok, non_neg_integer()} |
                        {error, content_length_error()}.
parse_cl_lines([]) ->
    {error, missing_content_length};
parse_cl_lines([Line | Rest]) ->
    Lower = string:lowercase(Line),
    case Lower of
        <<"content-length:",_/binary>> ->
            case binary:split(Line, <<":">>) of
                [_, ValueBin] ->
                    Trimmed = string:trim(ValueBin),
                    try binary_to_integer(Trimmed) of
                        N when N >= 0 ->
                            {ok, N};
                        N ->
                            {error, {invalid_content_length, N}}
                    catch
                        error:badarg ->
                            {error, {invalid_content_length, Trimmed}}
                    end;
                _ ->
                    {error, {malformed_header, Line}}
            end;
        _ ->
            parse_cl_lines(Rest)
    end.
-spec decode_body(binary(), binary()) ->
                     {ok, json_map(), binary()} |
                     {error, {invalid_json, not_object} |
                             {json_decode, term()}}.
decode_body(Body, Rest) ->
    try json:decode(Body) of
        Decoded when is_map(Decoded) ->
            {ok, Decoded, Rest};
        _Other ->
            {error, {invalid_json, not_object}}
    catch
        error:Reason ->
            {error, {json_decode, Reason}}
    end.
-spec extract_messages_acc(binary(), [json_map()]) ->
                             {[json_map()], binary()}.
extract_messages_acc(Buffer, Acc) ->
    case extract_message(Buffer) of
        {ok, Msg, Rest} ->
            extract_messages_acc(Rest, [Msg | Acc]);
        incomplete ->
            {lists:reverse(Acc), Buffer};
        {error, _Reason} ->
            {lists:reverse(Acc), Buffer}
    end.
