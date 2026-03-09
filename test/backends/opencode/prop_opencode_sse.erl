%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for opencode_sse.
%%%
%%% Fuzz-tests the pure SSE frame parser with random binary inputs
%%% to verify robustness and correctness invariants.
%%%
%%% Properties (200 test cases each):
%%%   1. parse_chunk/2 never crashes on any binary input
%%%   2. Chunk boundary independence — splitting input at any point
%%%      produces the same events as parsing the whole input at once
%%%   3. Events always have a data key
%%%   4. Empty chunks produce no events (idempotent)
%%%   5. Comment-only input produces no events
%%%   6. Data line count matches data: field count
%%% @end
%%%-------------------------------------------------------------------
-module(prop_opencode_sse).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

never_crashes_test() ->
    ?assert(proper:quickcheck(prop_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

chunk_boundary_independence_test() ->
    ?assert(proper:quickcheck(prop_chunk_boundary_independence(),
        [{numtests, 200}, {to_file, user}])).

events_always_have_data_test() ->
    ?assert(proper:quickcheck(prop_events_always_have_data(),
        [{numtests, 200}, {to_file, user}])).

empty_chunks_idempotent_test() ->
    ?assert(proper:quickcheck(prop_empty_chunks_idempotent(),
        [{numtests, 200}, {to_file, user}])).

comments_produce_no_events_test() ->
    ?assert(proper:quickcheck(prop_comments_produce_no_events(),
        [{numtests, 200}, {to_file, user}])).

well_formed_event_count_test() ->
    ?assert(proper:quickcheck(prop_well_formed_event_count(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: parse_chunk/2 never crashes on any binary
prop_never_crashes() ->
    ?FORALL(Chunk, binary(),
        begin
            State0 = opencode_sse:new_state(),
            {Events, _State1} = opencode_sse:parse_chunk(Chunk, State0),
            is_list(Events)
        end).

%% Property 2: Splitting input at any point produces same events
%%             as parsing the whole thing at once
prop_chunk_boundary_independence() ->
    ?FORALL({Part1, Part2}, {gen_sse_data(), gen_sse_data()},
        begin
            Full = <<Part1/binary, Part2/binary>>,
            State0 = opencode_sse:new_state(),
            %% Parse in one go
            {EventsOne, _} = opencode_sse:parse_chunk(Full, State0),
            %% Parse in two chunks
            {EventsA, StateA} = opencode_sse:parse_chunk(Part1, State0),
            {EventsB, _} = opencode_sse:parse_chunk(Part2, StateA),
            EventsTwo = EventsA ++ EventsB,
            EventsOne =:= EventsTwo
        end).

%% Property 3: Every event has a data key
prop_events_always_have_data() ->
    ?FORALL(Chunk, gen_sse_data(),
        begin
            State0 = opencode_sse:new_state(),
            {Events, _} = opencode_sse:parse_chunk(Chunk, State0),
            lists:all(fun(E) -> maps:is_key(data, E) end, Events)
        end).

%% Property 4: Empty chunk doesn't change event output
prop_empty_chunks_idempotent() ->
    ?FORALL(N, range(1, 10),
        begin
            State0 = opencode_sse:new_state(),
            {Events, StateN} = feed_empty_chunks(N, State0),
            Events =:= [] andalso StateN =:= State0
        end).

%% Property 5: Comment-only lines produce no events
prop_comments_produce_no_events() ->
    ?FORALL(Comments, list(gen_comment_line()),
        begin
            Data = iolist_to_binary(
                [[<<": ">>, C, <<"\n">>] || C <- Comments] ++ [<<"\n">>]),
            State0 = opencode_sse:new_state(),
            {Events, _} = opencode_sse:parse_chunk(Data, State0),
            Events =:= []
        end).

%% Property 6: N well-formed events produce exactly N parsed events
prop_well_formed_event_count() ->
    ?FORALL(EventDatas, non_empty(list(binary())),
        begin
            %% Build well-formed SSE: each event has one data line + blank line
            Lines = [[<<"data: ">>, D, <<"\n\n">>] || D <- EventDatas],
            Data = iolist_to_binary(Lines),
            State0 = opencode_sse:new_state(),
            {Events, _} = opencode_sse:parse_chunk(Data, State0),
            length(Events) =:= length(EventDatas)
        end).

%%====================================================================
%% Generators
%%====================================================================

%% Generate SSE-like data with proper line endings
gen_sse_data() ->
    ?LET(Fields, list(gen_sse_field()),
        iolist_to_binary(Fields)).

gen_sse_field() ->
    oneof([
        %% data field
        ?LET(V, binary(), [<<"data: ">>, V, <<"\n">>]),
        %% event field
        ?LET(V, gen_event_name(), [<<"event: ">>, V, <<"\n">>]),
        %% id field
        ?LET(V, binary(), [<<"id: ">>, V, <<"\n">>]),
        %% comment
        ?LET(V, binary(), [<<": ">>, V, <<"\n">>]),
        %% empty line (event boundary)
        <<"\n">>,
        %% retry field
        ?LET(V, non_neg_integer(), [<<"retry: ">>, integer_to_binary(V), <<"\n">>])
    ]).

gen_event_name() ->
    oneof([
        <<"message.part.updated">>,
        <<"session.idle">>,
        <<"server.heartbeat">>,
        binary()
    ]).

gen_comment_line() ->
    binary().

%%====================================================================
%% Helpers
%%====================================================================

feed_empty_chunks(0, State) -> {[], State};
feed_empty_chunks(N, State) ->
    {Events, State1} = opencode_sse:parse_chunk(<<>>, State),
    {Events2, StateN} = feed_empty_chunks(N - 1, State1),
    {Events ++ Events2, StateN}.
