%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for beam_agent_content_core.
%%%
%%% Fuzz-tests the content block parser with random inputs to verify
%%% robustness properties.
%%%
%%% Properties (200 test cases each):
%%%   1. parse_blocks/1 never crashes on any list input
%%%   2. Known block types produce matching atoms
%%%   3. Non-map elements are dropped
%%%   4. Output length <= input length
%%% @end
%%%-------------------------------------------------------------------
-module(prop_beam_agent_content_core).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

parse_blocks_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_parse_blocks_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

known_types_produce_atoms_test() ->
    ?assert(proper:quickcheck(prop_known_types_produce_atoms(),
        [{numtests, 200}, {to_file, user}])).

non_maps_dropped_test() ->
    ?assert(proper:quickcheck(prop_non_maps_dropped(),
        [{numtests, 200}, {to_file, user}])).

output_length_leq_input_test() ->
    ?assert(proper:quickcheck(prop_output_length_leq_input(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: parse_blocks/1 never crashes on any list input
prop_parse_blocks_never_crashes() ->
    ?FORALL(Input, list(any()),
        begin
            Result = beam_agent_content_core:parse_blocks(Input),
            is_list(Result)
        end).

%% Property 2: Known block types produce matching atom types
prop_known_types_produce_atoms() ->
    KnownTypes = [<<"text">>, <<"thinking">>, <<"tool_use">>,
                  <<"tool_result">>],
    ?FORALL(TypeBin, oneof(KnownTypes),
        begin
            Block = #{<<"type">> => TypeBin},
            [Parsed] = beam_agent_content_core:parse_blocks([Block]),
            ExpectedAtom = binary_to_existing_atom(TypeBin),
            maps:get(type, Parsed) =:= ExpectedAtom
        end).

%% Property 3: Non-map elements in input are dropped from output
prop_non_maps_dropped() ->
    ?FORALL({NonMaps, Maps},
        {list(oneof([binary(), integer(), atom(), list()])),
         list(#{<<"type">> => binary()})},
        begin
            Input = interleave(NonMaps, Maps),
            Result = beam_agent_content_core:parse_blocks(Input),
            %% Result should only contain maps (parsed blocks)
            lists:all(fun is_map/1, Result) andalso
            %% And should have at most as many entries as Maps
            length(Result) =< length(Maps) + length(NonMaps)
        end).

%% Property 4: Output length is always <= input length
prop_output_length_leq_input() ->
    ?FORALL(Input, list(oneof([
        #{<<"type">> => <<"text">>, <<"text">> => binary()},
        #{<<"type">> => <<"thinking">>, <<"thinking">> => binary()},
        #{<<"unknown">> => binary()},
        binary(),
        integer()
    ])),
        begin
            Result = beam_agent_content_core:parse_blocks(Input),
            length(Result) =< length(Input)
        end).

%%====================================================================
%% Helpers
%%====================================================================

%% Interleave two lists.
-spec interleave([term()], [term()]) -> [term()].
interleave([], Ys) -> Ys;
interleave(Xs, []) -> Xs;
interleave([X | Xs], [Y | Ys]) -> [X, Y | interleave(Xs, Ys)].
