%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for copilot_frame.
%%%
%%% Fuzz-tests the Content-Length frame parser with random inputs to
%%% verify robustness. Uses PropEr generators for JSON maps, binary
%%% buffers, and Content-Length framed payloads.
%%%
%%% Properties (200 test cases each):
%%%   1. encode → extract roundtrips for any encodable map
%%%   2. extract_message never crashes on arbitrary binary
%%%   3. encode_message always produces valid iodata with correct CL
%%%   4. extract_messages never crashes on arbitrary binary
%%%   5. Batch extract recovers all messages from concatenated frames
%%%   6. Partial frames always return incomplete
%%%   7. Content-Length value matches actual body size
%%% @end
%%%-------------------------------------------------------------------
-module(prop_copilot_frame).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration — run PropEr properties via eunit
%%====================================================================

encode_extract_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_encode_extract_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

extract_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_extract_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

encode_produces_valid_iodata_test() ->
    ?assert(proper:quickcheck(prop_encode_produces_valid_iodata(),
        [{numtests, 200}, {to_file, user}])).

extract_messages_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_extract_messages_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

batch_extract_recovers_all_test() ->
    ?assert(proper:quickcheck(prop_batch_extract_recovers_all(),
        [{numtests, 200}, {to_file, user}])).

partial_frame_returns_incomplete_test() ->
    ?assert(proper:quickcheck(prop_partial_frame_returns_incomplete(),
        [{numtests, 200}, {to_file, user}])).

content_length_matches_body_test() ->
    ?assert(proper:quickcheck(prop_content_length_matches_body(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: encode then extract is identity for any JSON-encodable map
prop_encode_extract_roundtrip() ->
    ?FORALL(Msg, gen_json_map(),
        begin
            Encoded = iolist_to_binary(copilot_frame:encode_message(Msg)),
            case copilot_frame:extract_message(Encoded) of
                {ok, Decoded, Rest} ->
                    %% Decoded should match original, rest should be empty
                    Decoded =:= Msg andalso Rest =:= <<>>;
                _Other ->
                    false
            end
        end).

%% Property 2: extract_message never crashes on any binary input
prop_extract_never_crashes() ->
    ?FORALL(Bin, binary(),
        begin
            Result = copilot_frame:extract_message(Bin),
            case Result of
                {ok, M, _Rest} when is_map(M) -> true;
                incomplete -> true;
                {error, _Reason} -> true;
                _ -> false
            end
        end).

%% Property 3: encode_message always produces valid iodata
prop_encode_produces_valid_iodata() ->
    ?FORALL(Msg, gen_json_map(),
        begin
            Encoded = copilot_frame:encode_message(Msg),
            %% Must be convertible to binary (valid iodata)
            Bin = iolist_to_binary(Encoded),
            is_binary(Bin) andalso byte_size(Bin) > 0
        end).

%% Property 4: extract_messages never crashes on any binary input
prop_extract_messages_never_crashes() ->
    ?FORALL(Bin, binary(),
        begin
            {Msgs, Rest} = copilot_frame:extract_messages(Bin),
            is_list(Msgs) andalso is_binary(Rest)
        end).

%% Property 5: Concatenated encoded messages can all be batch-extracted
prop_batch_extract_recovers_all() ->
    ?FORALL(MsgList, non_empty(list(gen_json_map())),
        begin
            Encoded = iolist_to_binary(
                [copilot_frame:encode_message(M) || M <- MsgList]),
            {Decoded, Rest} = copilot_frame:extract_messages(Encoded),
            length(Decoded) =:= length(MsgList) andalso
            Rest =:= <<>> andalso
            Decoded =:= MsgList
        end).

%% Property 6: Truncated frame always returns incomplete
prop_partial_frame_returns_incomplete() ->
    ?FORALL(Msg, gen_json_map(),
        begin
            Full = iolist_to_binary(copilot_frame:encode_message(Msg)),
            %% Remove at least 1 byte from the end
            case byte_size(Full) of
                N when N > 1 ->
                    CutAt = max(1, N - 1),
                    Partial = binary:part(Full, 0, CutAt),
                    Result = copilot_frame:extract_message(Partial),
                    Result =:= incomplete orelse element(1, Result) =:= error;
                _ ->
                    true  %% Degenerate case
            end
        end).

%% Property 7: Content-Length in encoded output matches actual body size
prop_content_length_matches_body() ->
    ?FORALL(Msg, gen_json_map(),
        begin
            Encoded = iolist_to_binary(copilot_frame:encode_message(Msg)),
            %% Parse out the Content-Length value
            case binary:match(Encoded, <<"\r\n\r\n">>) of
                {Pos, 4} ->
                    Header = binary:part(Encoded, 0, Pos),
                    Body = binary:part(Encoded, Pos + 4,
                                       byte_size(Encoded) - Pos - 4),
                    %% Extract CL value
                    <<"Content-Length: ", CLBin/binary>> = Header,
                    CL = binary_to_integer(string:trim(CLBin)),
                    CL =:= byte_size(Body);
                nomatch ->
                    false
            end
        end).

%%====================================================================
%% Generators
%%====================================================================

%% Generate a simple JSON-encodable map (binary keys, safe values).
%% Uses ASCII-only strings to guarantee valid UTF-8 for json:encode/1.
gen_json_map() ->
    ?LET(Pairs, list({gen_json_key(), gen_json_value()}),
        maps:from_list([{<<"type">>, <<"test">>} | Pairs])).

gen_json_key() ->
    ?LET(S, non_empty(list(range($a, $z))),
        list_to_binary(S)).

gen_json_value() ->
    oneof([
        gen_json_string(),
        integer(),
        boolean(),
        null
    ]).

%% Generate a valid UTF-8 binary (ASCII subset) safe for json:encode.
gen_json_string() ->
    ?LET(S, list(range($\s, $~)),
        list_to_binary(S)).
