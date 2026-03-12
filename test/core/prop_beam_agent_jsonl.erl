%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_jsonl.
%%%
%%% Fuzz-tests the JSONL (JSON Lines) codec with random inputs to verify
%%% round-trip properties and extraction invariants.
%%%
%%% Properties (200 test cases each):
%%%   1. encode_line → decode_line round-trips for maps
%%%   2. extract_lines preserves all complete lines
%%%   3. extract_lines remainder contains no newlines
%%%   4. extract_line returns none when no newline present
%%%   5. decode_line never crashes on arbitrary binary input
%%%   6. encode_line output ends with newline
%%%   7. Multiple encoded lines concatenated → extract_lines recovers all
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_jsonl).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

encode_decode_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_encode_decode_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

extract_lines_preserves_content_test() ->
    ?assert(proper:quickcheck(prop_extract_lines_preserves_content(),
        [{numtests, 200}, {to_file, user}])).

extract_lines_no_newlines_in_remainder_test() ->
    ?assert(proper:quickcheck(prop_extract_lines_no_newlines_in_remainder(),
        [{numtests, 200}, {to_file, user}])).

extract_line_none_without_newline_test() ->
    ?assert(proper:quickcheck(prop_extract_line_none_without_newline(),
        [{numtests, 200}, {to_file, user}])).

decode_line_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_decode_line_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

encode_line_newline_terminated_test() ->
    ?assert(proper:quickcheck(prop_encode_line_newline_terminated(),
        [{numtests, 200}, {to_file, user}])).

multi_encode_extract_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_multi_encode_extract_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: encode_line → decode_line round-trips for maps with binary keys/values
prop_encode_decode_roundtrip() ->
    ?FORALL(Map, gen_json_map(),
        begin
            Encoded = iolist_to_binary(beam_agent_jsonl:encode_line(Map)),
            Line = binary:part(Encoded, 0, byte_size(Encoded) - 1),
            {ok, Decoded} = beam_agent_jsonl:decode_line(Line),
            Decoded =:= Map
        end).

%% Property 2: extract_lines returns all complete lines from buffer
prop_extract_lines_preserves_content() ->
    ?FORALL({Lines, Partial}, {list(gen_non_newline_bin()), gen_non_newline_bin()},
        begin
            Buffer = iolist_to_binary(
                [[[L, $\n] || L <- Lines], Partial]),
            {Extracted, _Remaining} = beam_agent_jsonl:extract_lines(Buffer),
            NonEmpty = [L || L <- Lines, L =/= <<>>],
            Extracted =:= NonEmpty
        end).

%% Property 3: extract_lines remainder contains no newlines
prop_extract_lines_no_newlines_in_remainder() ->
    ?FORALL(Buffer, binary(),
        begin
            {_Lines, Remaining} = beam_agent_jsonl:extract_lines(Buffer),
            binary:match(Remaining, <<"\n">>) =:= nomatch
        end).

%% Property 4: extract_line returns none when buffer has no newline
prop_extract_line_none_without_newline() ->
    ?FORALL(Buffer, gen_non_newline_bin(),
        beam_agent_jsonl:extract_line(Buffer) =:= none).

%% Property 5: decode_line never crashes on arbitrary binary input
prop_decode_line_never_crashes() ->
    ?FORALL(Input, binary(),
        begin
            case beam_agent_jsonl:decode_line(Input) of
                {ok, M} -> is_map(M);
                {error, _} -> true
            end
        end).

%% Property 6: encode_line output always ends with newline
prop_encode_line_newline_terminated() ->
    ?FORALL(Map, gen_json_map(),
        begin
            Bin = iolist_to_binary(beam_agent_jsonl:encode_line(Map)),
            binary:last(Bin) =:= $\n
        end).

%% Property 7: Multiple encoded lines concatenated → extract_lines recovers all
prop_multi_encode_extract_roundtrip() ->
    ?FORALL(Maps, non_empty(list(gen_json_map())),
        begin
            Encoded = iolist_to_binary(
                [beam_agent_jsonl:encode_line(M) || M <- Maps]),
            {Lines, <<>>} = beam_agent_jsonl:extract_lines(Encoded),
            Decoded = [begin {ok, M} = beam_agent_jsonl:decode_line(L), M end
                       || L <- Lines],
            Decoded =:= Maps
        end).

%%====================================================================
%% Generators
%%====================================================================

%% Generate a JSON-safe map (UTF-8 binary keys and values for clean round-trips).
gen_json_map() ->
    ?LET(Pairs, list({gen_utf8_nonempty(), gen_utf8()}),
        maps:from_list(Pairs)).

%% Generate a valid UTF-8 binary (printable ASCII subset for JSON safety).
gen_utf8() ->
    ?LET(Chars, list(range(32, 126)), list_to_binary(Chars)).

gen_utf8_nonempty() ->
    ?LET(Chars, non_empty(list(range(32, 126))), list_to_binary(Chars)).

%% Generate a binary that contains no newline characters.
gen_non_newline_bin() ->
    ?LET(Bin, binary(),
        binary:replace(Bin, <<"\n">>, <<>>, [global])).
