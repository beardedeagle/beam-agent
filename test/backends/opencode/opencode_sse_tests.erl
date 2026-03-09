%%%-------------------------------------------------------------------
%%% @doc EUnit tests for opencode_sse SSE frame parser.
%%%
%%% Pure unit tests — no processes, no external dependencies.
%%% Tests cover the full SSE parsing specification:
%%%   - Complete and partial events
%%%   - Buffering across chunk boundaries
%%%   - All field types (data, event, id)
%%%   - Comment lines
%%%   - Multi-line data joining
%%%   - Mixed complete and partial events
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_sse_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Single complete event
%%====================================================================

single_event_test() ->
    Input = <<"data: hello\n\n">>,
    {Events, State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([#{data => <<"hello">>}], Events),
    ?assertEqual(opencode_sse:new_state(), State).

%%====================================================================
%% Multiple events in one chunk
%%====================================================================

multiple_events_test() ->
    Input = <<"data: first\n\ndata: second\n\n">>,
    {Events, State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual(2, length(Events)),
    [E1, E2] = Events,
    ?assertEqual(<<"first">>, maps:get(data, E1)),
    ?assertEqual(<<"second">>, maps:get(data, E2)),
    ?assertEqual(opencode_sse:new_state(), State).

%%====================================================================
%% Partial event across chunks (buffering)
%%====================================================================

partial_event_across_chunks_test() ->
    S0 = opencode_sse:new_state(),
    %% First chunk: partial line, no newline yet
    {Events1, S1} = opencode_sse:parse_chunk(<<"data: he">>, S0),
    ?assertEqual([], Events1),
    %% S1 has partial line in buffer — opaque, don't inspect

    %% Second chunk: completes the data line but no blank line yet
    {Events2, S2} = opencode_sse:parse_chunk(<<"llo\n">>, S1),
    ?assertEqual([], Events2),
    %% S2 has a processed data field in the event accumulator

    %% Third chunk: blank line flushes the event
    {Events3, S3} = opencode_sse:parse_chunk(<<"\n">>, S2),
    ?assertEqual([#{data => <<"hello">>}], Events3),
    ?assertEqual(opencode_sse:new_state(), S3).

%%====================================================================
%% Comment lines ignored (heartbeats)
%%====================================================================

comment_lines_ignored_test() ->
    Input = <<": this is a comment\ndata: real\n\n">>,
    {Events, State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([#{data => <<"real">>}], Events),
    ?assertEqual(opencode_sse:new_state(), State).

only_comments_produce_no_events_test() ->
    Input = <<": heartbeat\n: another comment\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([], Events).

%%====================================================================
%% Event type field captured
%%====================================================================

event_type_field_test() ->
    Input = <<"event: message.part.updated\ndata: {}\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual(1, length(Events)),
    [E] = Events,
    ?assertEqual(<<"message.part.updated">>, maps:get(event, E)),
    ?assertEqual(<<"{}">>, maps:get(data, E)).

%%====================================================================
%% ID field captured
%%====================================================================

id_field_test() ->
    Input = <<"id: 42\ndata: payload\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual(1, length(Events)),
    [E] = Events,
    ?assertEqual(<<"42">>, maps:get(id, E)),
    ?assertEqual(<<"payload">>, maps:get(data, E)).

%%====================================================================
%% Data-only event (no event or id fields)
%%====================================================================

data_only_event_test() ->
    Input = <<"data: just data\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    [E] = Events,
    ?assertNot(maps:is_key(event, E)),
    ?assertNot(maps:is_key(id, E)),
    ?assertEqual(<<"just data">>, maps:get(data, E)).

%%====================================================================
%% Multiple data lines joined with \n
%%====================================================================

multiple_data_lines_joined_test() ->
    Input = <<"data: line1\ndata: line2\ndata: line3\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    [E] = Events,
    ?assertEqual(<<"line1\nline2\nline3">>, maps:get(data, E)).

%%====================================================================
%% Mixed complete and partial events
%%====================================================================

mixed_complete_and_partial_test() ->
    %% One complete event followed by a partial line
    Input = <<"data: complete\n\ndata: parti">>,
    {Events, S1} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([#{data => <<"complete">>}], Events),
    %% S1 has partial data — finish it off
    {Events2, S2} = opencode_sse:parse_chunk(<<"al\n\n">>, S1),
    ?assertEqual([#{data => <<"partial">>}], Events2),
    ?assertEqual(opencode_sse:new_state(), S2).

%%====================================================================
%% Empty chunk
%%====================================================================

empty_chunk_test() ->
    {Events, State} = opencode_sse:parse_chunk(<<>>, opencode_sse:new_state()),
    ?assertEqual([], Events),
    ?assertEqual(opencode_sse:new_state(), State).

empty_chunk_with_buffer_test() ->
    %% Buffer carries through unchanged when chunk is empty
    S0 = opencode_sse:new_state(),
    {[], S1} = opencode_sse:parse_chunk(<<"data: partial">>, S0),
    {Events, S2} = opencode_sse:parse_chunk(<<>>, S1),
    ?assertEqual([], Events),
    ?assertEqual(S1, S2).

%%====================================================================
%% Large event spanning chunks
%%====================================================================

large_event_spanning_chunks_test() ->
    %% Build a large payload and split it across many chunks
    BigData = binary:copy(<<"x">>, 50000),
    Line = <<"data: ", BigData/binary, "\n">>,
    Terminator = <<"\n">>,
    %% Split into 100-byte chunks
    Chunks = split_into_chunks(<<Line/binary, Terminator/binary>>, 100),
    {Events, FinalState} = lists:foldl(
        fun(Chunk, {EvAcc, StateAcc}) ->
            {NewEvs, NewState} = opencode_sse:parse_chunk(Chunk, StateAcc),
            {EvAcc ++ NewEvs, NewState}
        end,
        {[], opencode_sse:new_state()},
        Chunks
    ),
    ?assertEqual(1, length(Events)),
    [E] = Events,
    ?assertEqual(BigData, maps:get(data, E)),
    ?assertEqual(opencode_sse:new_state(), FinalState).

%%====================================================================
%% CRLF line endings
%%====================================================================

crlf_line_endings_test() ->
    Input = <<"data: hello\r\n\r\n">>,
    {Events, State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([#{data => <<"hello">>}], Events),
    ?assertEqual(opencode_sse:new_state(), State).

%%====================================================================
%% Event with all three fields
%%====================================================================

all_fields_test() ->
    Input = <<"event: server.connected\nid: 1\ndata: {\"status\":\"ok\"}\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    [E] = Events,
    ?assertEqual(<<"server.connected">>, maps:get(event, E)),
    ?assertEqual(<<"1">>, maps:get(id, E)),
    ?assertEqual(<<"{\"status\":\"ok\"}">>, maps:get(data, E)).

%%====================================================================
%% Event with empty data line produces no event
%%====================================================================

no_data_no_event_test() ->
    %% A blank line with no preceding data lines produces no event
    Input = <<"event: heartbeat\n\n">>,
    {Events, _State} = opencode_sse:parse_chunk(Input, opencode_sse:new_state()),
    ?assertEqual([], Events).

%%====================================================================
%% Helpers
%%====================================================================

split_into_chunks(Binary, Size) ->
    split_into_chunks(Binary, Size, []).

split_into_chunks(<<>>, _Size, Acc) ->
    lists:reverse(Acc);
split_into_chunks(Binary, Size, Acc) when byte_size(Binary) =< Size ->
    lists:reverse([Binary | Acc]);
split_into_chunks(Binary, Size, Acc) ->
    <<Chunk:Size/binary, Rest/binary>> = Binary,
    split_into_chunks(Rest, Size, [Chunk | Acc]).
