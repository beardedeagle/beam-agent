%%%-------------------------------------------------------------------
%%% @doc EUnit + PropEr tests for beam_agent_jsonl.
%%%
%%% The critical property: splitting a JSONL payload into arbitrary
%%% binary chunks and reassembling via extract_lines/1 must produce
%%% identical decoded lines regardless of chunk boundaries.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_jsonl_tests).

-include_lib("eunit/include/eunit.hrl").
%% EUnit defines a LET macro; PropEr redefines it. Undefine EUnit's
%% to avoid warnings_as_errors failure. We use PropEr's ?LET, not EUnit's.
-undef(LET).
-include_lib("proper/include/proper.hrl").

%%====================================================================
%% EUnit: extract_lines/1
%%====================================================================

extract_lines_empty_test() ->
    ?assertEqual({[], <<>>}, beam_agent_jsonl:extract_lines(<<>>)).

extract_lines_no_newline_test() ->
    ?assertEqual({[], <<"partial">>}, beam_agent_jsonl:extract_lines(<<"partial">>)).

extract_lines_single_complete_test() ->
    {Lines, Rest} = beam_agent_jsonl:extract_lines(<<"{\"a\":1}\n">>),
    ?assertEqual([<<"{\"a\":1}">>], Lines),
    ?assertEqual(<<>>, Rest).

extract_lines_multiple_complete_test() ->
    Input = <<"{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n">>,
    {Lines, Rest} = beam_agent_jsonl:extract_lines(Input),
    ?assertEqual([<<"{\"a\":1}">>, <<"{\"b\":2}">>, <<"{\"c\":3}">>], Lines),
    ?assertEqual(<<>>, Rest).

extract_lines_trailing_partial_test() ->
    Input = <<"{\"a\":1}\n{\"b\":2}\npartial">>,
    {Lines, Rest} = beam_agent_jsonl:extract_lines(Input),
    ?assertEqual([<<"{\"a\":1}">>, <<"{\"b\":2}">>], Lines),
    ?assertEqual(<<"partial">>, Rest).

extract_lines_consecutive_newlines_test() ->
    %% Empty lines between valid lines should be filtered out
    Input = <<"{\"a\":1}\n\n{\"b\":2}\n">>,
    {Lines, Rest} = beam_agent_jsonl:extract_lines(Input),
    ?assertEqual([<<"{\"a\":1}">>, <<"{\"b\":2}">>], Lines),
    ?assertEqual(<<>>, Rest).

extract_lines_only_newlines_test() ->
    {Lines, Rest} = beam_agent_jsonl:extract_lines(<<"\n\n\n">>),
    ?assertEqual([], Lines),
    ?assertEqual(<<>>, Rest).

%%====================================================================
%% EUnit: extract_line/1
%%====================================================================

extract_line_empty_test() ->
    ?assertEqual(none, beam_agent_jsonl:extract_line(<<>>)).

extract_line_no_newline_test() ->
    ?assertEqual(none, beam_agent_jsonl:extract_line(<<"partial">>)).

extract_line_single_test() ->
    ?assertEqual(
        {ok, <<"{\"a\":1}">>, <<>>},
        beam_agent_jsonl:extract_line(<<"{\"a\":1}\n">>)
    ).

extract_line_with_remainder_test() ->
    ?assertEqual(
        {ok, <<"{\"a\":1}">>, <<"rest">>},
        beam_agent_jsonl:extract_line(<<"{\"a\":1}\nrest">>)
    ).

extract_line_skips_empty_lines_test() ->
    %% Leading empty lines should be skipped
    ?assertEqual(
        {ok, <<"{\"a\":1}">>, <<>>},
        beam_agent_jsonl:extract_line(<<"\n\n{\"a\":1}\n">>)
    ).

extract_line_all_empty_test() ->
    ?assertEqual(none, beam_agent_jsonl:extract_line(<<"\n\n\n">>)).

%%====================================================================
%% EUnit: decode_line/1
%%====================================================================

decode_line_empty_test() ->
    ?assertEqual({error, empty_line}, beam_agent_jsonl:decode_line(<<>>)).

decode_line_valid_object_test() ->
    {ok, Map} = beam_agent_jsonl:decode_line(<<"{\"type\":\"text\"}">>),
    ?assertEqual(#{<<"type">> => <<"text">>}, Map).

decode_line_nested_object_test() ->
    Input = <<"{\"type\":\"tool_use\",\"input\":{\"key\":\"val\"}}">>,
    {ok, Map} = beam_agent_jsonl:decode_line(Input),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, Map)),
    ?assertEqual(#{<<"key">> => <<"val">>}, maps:get(<<"input">>, Map)).

decode_line_not_object_test() ->
    %% JSON array is valid JSON but not an object
    {error, {not_object, _}} = beam_agent_jsonl:decode_line(<<"[1,2,3]">>).

decode_line_invalid_json_test() ->
    {error, {json_decode, _}} = beam_agent_jsonl:decode_line(<<"{broken">>).

decode_line_number_test() ->
    {error, {not_object, _}} = beam_agent_jsonl:decode_line(<<"42">>).

%%====================================================================
%% EUnit: encode_line/1
%%====================================================================

encode_line_simple_test() ->
    Result = iolist_to_binary(beam_agent_jsonl:encode_line(#{<<"a">> => 1})),
    %% Must end with newline
    ?assertEqual($\n, binary:last(Result)),
    %% Must be valid JSON before the newline
    JsonPart = binary:part(Result, 0, byte_size(Result) - 1),
    {ok, Decoded} = beam_agent_jsonl:decode_line(JsonPart),
    ?assertEqual(1, maps:get(<<"a">>, Decoded)).

encode_line_empty_map_test() ->
    Result = iolist_to_binary(beam_agent_jsonl:encode_line(#{})),
    ?assertEqual($\n, binary:last(Result)),
    JsonPart = binary:part(Result, 0, byte_size(Result) - 1),
    ?assertEqual({ok, #{}}, beam_agent_jsonl:decode_line(JsonPart)).

%%====================================================================
%% EUnit: roundtrip encode → decode
%%====================================================================

roundtrip_test() ->
    Original = #{<<"type">> => <<"text">>, <<"content">> => <<"hello">>},
    Encoded = iolist_to_binary(beam_agent_jsonl:encode_line(Original)),
    %% Strip trailing newline for decode
    JsonLine = binary:part(Encoded, 0, byte_size(Encoded) - 1),
    {ok, Decoded} = beam_agent_jsonl:decode_line(JsonLine),
    ?assertEqual(Original, Decoded).

%%====================================================================
%% PropEr: JSONL buffer reassembly — chunk boundary independence
%%====================================================================

%% Generator: list of JSON-encodable maps
json_maps() ->
    non_empty(list(json_map())).

json_map() ->
    ?LET(KVs, non_empty(list({json_key(), json_value()})),
         maps:from_list(KVs)).

json_key() ->
    ?LET(S, non_empty(list(range($a, $z))),
         list_to_binary(S)).

json_value() ->
    oneof([
        json_key(),                        %% binary string
        integer(),
        boolean(),
        float(),
        null
    ]).

%% Generator: list of positive chunk sizes.
%% split_into_chunks/2 handles the case where sizes don't cover the
%% full binary — the remainder becomes the final chunk.
chunk_sizes(_Len) ->
    non_empty(list(range(1, 100))).

%% Split a binary into chunks of given sizes
split_into_chunks(<<>>, _Sizes) ->
    [];
split_into_chunks(Bin, []) ->
    [Bin];
split_into_chunks(Bin, [Size | Rest]) ->
    ActualSize = min(Size, byte_size(Bin)),
    <<Chunk:ActualSize/binary, Remaining/binary>> = Bin,
    [Chunk | split_into_chunks(Remaining, Rest)].

%% The core property: chunk boundaries don't affect the result.
%%
%% Given a list of JSON maps:
%%   1. Encode them as JSONL (one JSON object per line)
%%   2. Split the binary into random chunks
%%   3. Feed chunks into extract_lines one at a time (simulating Port data)
%%   4. The reassembled complete lines must decode to the original maps
prop_chunk_boundary_independence() ->
    ?FORALL(Maps, json_maps(),
    begin
        %% Encode as JSONL
        Payload = iolist_to_binary(
            [beam_agent_jsonl:encode_line(M) || M <- Maps]),

        %% Split into random chunks
        ?FORALL(Sizes, chunk_sizes(byte_size(Payload)),
        begin
            Chunks = split_into_chunks(Payload, Sizes),

            %% Feed chunks through extract_lines, accumulating results
            {AllLines, FinalRest} = lists:foldl(
                fun(Chunk, {AccLines, Buffer}) ->
                    Combined = <<Buffer/binary, Chunk/binary>>,
                    {NewLines, Remaining} = beam_agent_jsonl:extract_lines(Combined),
                    {AccLines ++ NewLines, Remaining}
                end,
                {[], <<>>},
                Chunks
            ),

            %% Final rest should be empty (all lines are complete)
            ?assertEqual(<<>>, FinalRest),

            %% Decode all lines
            Decoded = [begin
                {ok, M} = beam_agent_jsonl:decode_line(L),
                M
            end || L <- AllLines],

            %% Must match original maps
            ?assertEqual(Maps, Decoded),
            true
        end)
    end).

%% The single-line extraction property: extract_line/1 demand-pull
%% produces the same lines as extract_lines/1 batch.
prop_extract_line_matches_extract_lines() ->
    ?FORALL(Maps, json_maps(),
    begin
        Payload = iolist_to_binary(
            [beam_agent_jsonl:encode_line(M) || M <- Maps]),

        %% Batch extraction
        {BatchLines, BatchRest} = beam_agent_jsonl:extract_lines(Payload),

        %% Demand-driven extraction (one at a time)
        DemandLines = extract_all_lines(Payload),

        ?assertEqual(BatchLines, DemandLines),
        ?assertEqual(<<>>, BatchRest),
        true
    end).

%% Helper: extract all lines one at a time using extract_line/1
extract_all_lines(Buffer) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none -> [];
        {ok, Line, Rest} -> [Line | extract_all_lines(Rest)]
    end.

%%====================================================================
%% PropEr: encode/decode roundtrip
%%====================================================================

prop_encode_decode_roundtrip() ->
    ?FORALL(M, json_map(),
    begin
        Encoded = iolist_to_binary(beam_agent_jsonl:encode_line(M)),
        JsonLine = binary:part(Encoded, 0, byte_size(Encoded) - 1),
        {ok, Decoded} = beam_agent_jsonl:decode_line(JsonLine),
        ?assertEqual(M, Decoded),
        true
    end).

%%====================================================================
%% PropEr runner (EUnit integration)
%%====================================================================

proper_test_() ->
    Opts = [{numtests, 200}, {to_file, user}],
    [
        {"chunk boundary independence",
         {timeout, 60,
          fun() -> ?assert(proper:quickcheck(prop_chunk_boundary_independence(), Opts)) end}},
        {"extract_line matches extract_lines",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_extract_line_matches_extract_lines(), Opts)) end}},
        {"encode/decode roundtrip",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_encode_decode_roundtrip(), Opts)) end}}
    ].
