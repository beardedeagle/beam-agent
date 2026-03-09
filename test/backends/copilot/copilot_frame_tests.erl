%%%-------------------------------------------------------------------
%%% @doc Unit tests for copilot_frame — Content-Length frame parser.
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_frame_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% extract_message tests
%%====================================================================

empty_buffer_test() ->
    ?assertEqual(incomplete, copilot_frame:extract_message(<<>>)).

incomplete_header_test() ->
    ?assertEqual(incomplete, copilot_frame:extract_message(<<"Content-Le">>)).

incomplete_body_test() ->
    %% Header complete but body not fully received
    Frame = <<"Content-Length: 20\r\n\r\n{\"partial\":">>,
    ?assertEqual(incomplete, copilot_frame:extract_message(Frame)).

single_complete_message_test() ->
    Body = <<"{\"method\":\"ping\"}">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(Len),
        <<"\r\n\r\n">>, Body
    ]),
    {ok, Decoded, Rest} = copilot_frame:extract_message(Frame),
    ?assertEqual(#{<<"method">> => <<"ping">>}, Decoded),
    ?assertEqual(<<>>, Rest).

message_with_remaining_data_test() ->
    Body1 = <<"{\"id\":1}">>,
    Len1 = byte_size(Body1),
    Trailer = <<"Content-Length: 5\r\n\r\n">>,
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(Len1),
        <<"\r\n\r\n">>, Body1, Trailer
    ]),
    {ok, Decoded, Rest} = copilot_frame:extract_message(Frame),
    ?assertEqual(#{<<"id">> => 1}, Decoded),
    ?assertEqual(Trailer, Rest).

unicode_body_test() ->
    %% JSON with unicode characters — Content-Length counts bytes, not chars
    Body = <<"{\"text\":\"hello \\u00e9\"}">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(Len),
        <<"\r\n\r\n">>, Body
    ]),
    {ok, Decoded, <<>>} = copilot_frame:extract_message(Frame),
    ?assertEqual(<<"hello é"/utf8>>, maps:get(<<"text">>, Decoded)).

case_insensitive_header_test() ->
    Body = <<"{\"ok\":true}">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"content-length: ">>, integer_to_binary(Len),
        <<"\r\n\r\n">>, Body
    ]),
    {ok, Decoded, <<>>} = copilot_frame:extract_message(Frame),
    ?assertEqual(#{<<"ok">> => true}, Decoded).

missing_content_length_header_test() ->
    Frame = <<"X-Custom: foo\r\n\r\n{\"a\":1}">>,
    ?assertMatch({error, missing_content_length},
                 copilot_frame:extract_message(Frame)).

invalid_content_length_value_test() ->
    Frame = <<"Content-Length: abc\r\n\r\n{}">>,
    ?assertMatch({error, {invalid_content_length, _}},
                 copilot_frame:extract_message(Frame)).

negative_content_length_test() ->
    Frame = <<"Content-Length: -5\r\n\r\n{}">>,
    ?assertMatch({error, {invalid_content_length, _}},
                 copilot_frame:extract_message(Frame)).

invalid_json_body_test() ->
    Body = <<"not json at all!">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(Len),
        <<"\r\n\r\n">>, Body
    ]),
    ?assertMatch({error, {json_decode, _}},
                 copilot_frame:extract_message(Frame)).

non_object_json_test() ->
    Body = <<"[1,2,3]">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(Len),
        <<"\r\n\r\n">>, Body
    ]),
    ?assertMatch({error, {invalid_json, not_object}},
                 copilot_frame:extract_message(Frame)).

zero_length_body_test() ->
    Frame = <<"Content-Length: 2\r\n\r\n{}">>,
    {ok, Decoded, <<>>} = copilot_frame:extract_message(Frame),
    ?assertEqual(#{}, Decoded).

multiple_header_lines_test() ->
    %% Extra headers before Content-Length (like HTTP)
    Body = <<"{\"v\":1}">>,
    Len = byte_size(Body),
    Frame = iolist_to_binary([
        <<"X-Extra: ignore\r\nContent-Length: ">>,
        integer_to_binary(Len), <<"\r\n\r\n">>, Body
    ]),
    {ok, Decoded, <<>>} = copilot_frame:extract_message(Frame),
    ?assertEqual(#{<<"v">> => 1}, Decoded).

header_too_large_test() ->
    %% > 4KB of data without \r\n\r\n triggers error
    BigHeader = binary:copy(<<"X">>, 5000),
    ?assertMatch({error, {header_too_large, _}},
                 copilot_frame:extract_message(BigHeader)).

%%====================================================================
%% extract_messages (batch) tests
%%====================================================================

extract_messages_empty_test() ->
    {Msgs, Rest} = copilot_frame:extract_messages(<<>>),
    ?assertEqual([], Msgs),
    ?assertEqual(<<>>, Rest).

extract_messages_two_complete_test() ->
    Body1 = <<"{\"n\":1}">>,
    Body2 = <<"{\"n\":2}">>,
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body1)),
        <<"\r\n\r\n">>, Body1,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body2)),
        <<"\r\n\r\n">>, Body2
    ]),
    {Msgs, Rest} = copilot_frame:extract_messages(Frame),
    ?assertEqual(2, length(Msgs)),
    ?assertEqual(#{<<"n">> => 1}, hd(Msgs)),
    ?assertEqual(#{<<"n">> => 2}, lists:nth(2, Msgs)),
    ?assertEqual(<<>>, Rest).

extract_messages_with_partial_test() ->
    Body1 = <<"{\"n\":1}">>,
    Partial = <<"Content-Length: 100\r\n\r\n{\"partial">>,
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body1)),
        <<"\r\n\r\n">>, Body1, Partial
    ]),
    {Msgs, Rest} = copilot_frame:extract_messages(Frame),
    ?assertEqual(1, length(Msgs)),
    ?assertEqual(#{<<"n">> => 1}, hd(Msgs)),
    ?assertEqual(Partial, Rest).

%%====================================================================
%% encode_message tests
%%====================================================================

encode_simple_message_test() ->
    Msg = #{<<"method">> => <<"ping">>},
    Encoded = iolist_to_binary(copilot_frame:encode_message(Msg)),
    %% Should start with Content-Length header
    ?assertMatch(<<"Content-Length: ", _/binary>>, Encoded),
    %% Should contain \r\n\r\n separator
    {Pos, _} = binary:match(Encoded, <<"\r\n\r\n">>),
    ?assert(Pos > 0),
    %% Body should be valid JSON
    Body = binary:part(Encoded, Pos + 4, byte_size(Encoded) - Pos - 4),
    Decoded = json:decode(Body),
    ?assertEqual(#{<<"method">> => <<"ping">>}, Decoded).

encode_decode_roundtrip_test() ->
    Original = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => <<"abc">>,
                 <<"method">> => <<"test">>, <<"params">> => #{<<"x">> => 42}},
    Encoded = iolist_to_binary(copilot_frame:encode_message(Original)),
    {ok, Decoded, <<>>} = copilot_frame:extract_message(Encoded),
    ?assertEqual(Original, Decoded).

encode_content_length_accuracy_test() ->
    %% Verify Content-Length matches actual body byte count
    Msg = #{<<"data">> => <<"hello world">>},
    Encoded = iolist_to_binary(copilot_frame:encode_message(Msg)),
    [HeaderPart, BodyPart] = binary:split(Encoded, <<"\r\n\r\n">>),
    <<"Content-Length: ", LenBin/binary>> = HeaderPart,
    ClaimedLength = binary_to_integer(LenBin),
    ActualLength = byte_size(BodyPart),
    ?assertEqual(ClaimedLength, ActualLength).
