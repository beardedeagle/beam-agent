%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_realtime_protocol URL construction.
%%%
%%% Verifies that build_ws_path/1 percent-encodes special characters
%%% in model names so the resulting WebSocket path is always a valid URL.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_realtime_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% build_ws_path/1
%%====================================================================

build_ws_path_plain_model_test() ->
    ?assertEqual(<<"/v1/realtime?model=gpt-4o-realtime-preview">>,
                 codex_realtime_protocol:build_ws_path(
                     <<"gpt-4o-realtime-preview">>)).

build_ws_path_encodes_space_test() ->
    %% uri_string:compose_query uses '+' for spaces per W3C form encoding.
    %% Both '+' and '%20' are valid in query strings; compose_query chooses '+'.
    ?assertEqual(<<"/v1/realtime?model=gpt-4o+realtime">>,
                 codex_realtime_protocol:build_ws_path(
                     <<"gpt-4o realtime">>)).

build_ws_path_encodes_ampersand_test() ->
    %% An ampersand in a query value must be encoded (%26) to avoid
    %% being interpreted as a query parameter separator
    Result = codex_realtime_protocol:build_ws_path(<<"a&b">>),
    ?assertMatch(<<"/v1/realtime?model=", _/binary>>, Result),
    %% The raw & must not appear literally in the result
    ?assertEqual(nomatch, binary:match(Result, <<"model=a&b">>)),
    ?assertNotEqual(nomatch, binary:match(Result, <<"%26">>)).

build_ws_path_encodes_question_mark_test() ->
    %% A question mark in the model name must be encoded (%3F) to
    %% prevent it from being treated as a second query string delimiter
    Result = codex_realtime_protocol:build_ws_path(<<"model?v2">>),
    ?assertNotEqual(nomatch, binary:match(Result, <<"%3F">>)).

build_ws_path_encodes_hash_test() ->
    %% A hash in the model name must be encoded (%23) to prevent it
    %% from being interpreted as a fragment separator
    Result = codex_realtime_protocol:build_ws_path(<<"model#v2">>),
    ?assertNotEqual(nomatch, binary:match(Result, <<"%23">>)).

build_ws_path_encodes_plus_test() ->
    %% A plus sign must be encoded; uri_string uses %2B
    Result = codex_realtime_protocol:build_ws_path(<<"gpt+4">>),
    ?assertNotEqual(nomatch, binary:match(Result, <<"%2B">>)).

build_ws_path_prefix_test() ->
    %% The path always starts with /v1/realtime?model=
    Result = codex_realtime_protocol:build_ws_path(<<"any-model">>),
    ?assertMatch(<<"/v1/realtime?model=", _/binary>>, Result).
