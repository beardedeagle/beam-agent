%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_jsonrpc — JSON-RPC encoding/decoding.
%%%
%%% Verifies:
%%%   - No "jsonrpc" field in encoded output (Codex wire format)
%%%   - Round-trip encoding/decoding
%%%   - All message type variants
%%%   - next_id monotonic counter
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_jsonrpc_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Encoding tests
%%====================================================================

encode_request_integer_id_test() ->
    Iodata = beam_agent_jsonrpc:encode_request(1, <<"test/method">>, #{<<"key">> => <<"val">>}),
    Bin = iolist_to_binary(Iodata),
    %% Must end with newline
    ?assert(binary:last(Bin) =:= $\n),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(1, maps:get(<<"id">>, Map)),
    ?assertEqual(<<"test/method">>, maps:get(<<"method">>, Map)),
    ?assertEqual(#{<<"key">> => <<"val">>}, maps:get(<<"params">>, Map)),
    %% CRITICAL: No jsonrpc field
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_request_binary_id_test() ->
    Iodata = beam_agent_jsonrpc:encode_request(<<"req-abc">>, <<"turn/start">>, #{<<"threadId">> => <<"t1">>}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"req-abc">>, maps:get(<<"id">>, Map)),
    ?assertEqual(<<"turn/start">>, maps:get(<<"method">>, Map)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_notification_with_params_test() ->
    Iodata = beam_agent_jsonrpc:encode_notification(<<"initialized">>, #{<<"version">> => <<"1.0">>}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"initialized">>, maps:get(<<"method">>, Map)),
    ?assertEqual(#{<<"version">> => <<"1.0">>}, maps:get(<<"params">>, Map)),
    ?assertNot(maps:is_key(<<"id">>, Map)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_notification_without_params_test() ->
    Iodata = beam_agent_jsonrpc:encode_notification(<<"initialized">>, undefined),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"initialized">>, maps:get(<<"method">>, Map)),
    ?assertNot(maps:is_key(<<"params">>, Map)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_response_test() ->
    Iodata = beam_agent_jsonrpc:encode_response(42, #{<<"status">> => <<"ok">>}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(42, maps:get(<<"id">>, Map)),
    ?assertEqual(#{<<"status">> => <<"ok">>}, maps:get(<<"result">>, Map)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_error_with_data_test() ->
    Iodata = beam_agent_jsonrpc:encode_error(5, -32600, <<"Invalid Request">>, #{<<"detail">> => <<"bad">>}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(5, maps:get(<<"id">>, Map)),
    Err = maps:get(<<"error">>, Map),
    ?assertEqual(-32600, maps:get(<<"code">>, Err)),
    ?assertEqual(<<"Invalid Request">>, maps:get(<<"message">>, Err)),
    ?assertEqual(#{<<"detail">> => <<"bad">>}, maps:get(<<"data">>, Err)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

encode_error_without_data_test() ->
    Iodata = beam_agent_jsonrpc:encode_error(6, -32601, <<"Method not found">>),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(6, maps:get(<<"id">>, Map)),
    Err = maps:get(<<"error">>, Map),
    ?assertEqual(-32601, maps:get(<<"code">>, Err)),
    ?assertEqual(<<"Method not found">>, maps:get(<<"message">>, Err)),
    ?assertNot(maps:is_key(<<"data">>, Err)),
    ?assertNot(maps:is_key(<<"jsonrpc">>, Map)).

%%====================================================================
%% Decoding tests
%%====================================================================

decode_request_test() ->
    Map = #{<<"id">> => 1, <<"method">> => <<"turn/start">>,
            <<"params">> => #{<<"threadId">> => <<"t1">>}},
    ?assertEqual(
        {request, 1, <<"turn/start">>, #{<<"threadId">> => <<"t1">>}},
        beam_agent_jsonrpc:decode(Map)).

decode_notification_test() ->
    Map = #{<<"method">> => <<"item/agentMessage/delta">>,
            <<"params">> => #{<<"delta">> => <<"hello">>}},
    ?assertEqual(
        {notification, <<"item/agentMessage/delta">>, #{<<"delta">> => <<"hello">>}},
        beam_agent_jsonrpc:decode(Map)).

decode_notification_no_params_test() ->
    Map = #{<<"method">> => <<"initialized">>},
    ?assertEqual(
        {notification, <<"initialized">>, undefined},
        beam_agent_jsonrpc:decode(Map)).

decode_success_response_test() ->
    Map = #{<<"id">> => 42, <<"result">> => #{<<"threadId">> => <<"t1">>}},
    ?assertEqual(
        {response, 42, #{<<"threadId">> => <<"t1">>}},
        beam_agent_jsonrpc:decode(Map)).

decode_error_response_test() ->
    Map = #{<<"id">> => 3,
            <<"error">> => #{<<"code">> => -32600,
                             <<"message">> => <<"Invalid Request">>,
                             <<"data">> => <<"extra">>}},
    ?assertEqual(
        {error_response, 3, -32600, <<"Invalid Request">>, <<"extra">>},
        beam_agent_jsonrpc:decode(Map)).

decode_error_response_no_data_test() ->
    Map = #{<<"id">> => 4,
            <<"error">> => #{<<"code">> => -32601,
                             <<"message">> => <<"Not found">>}},
    ?assertEqual(
        {error_response, 4, -32601, <<"Not found">>, undefined},
        beam_agent_jsonrpc:decode(Map)).

decode_unknown_test() ->
    Map = #{<<"something">> => <<"else">>},
    ?assertMatch({unknown, _}, beam_agent_jsonrpc:decode(Map)).

%%====================================================================
%% Round-trip test
%%====================================================================

roundtrip_request_test() ->
    Iodata = beam_agent_jsonrpc:encode_request(7, <<"thread/start">>, #{<<"name">> => <<"test">>}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertMatch(
        {request, 7, <<"thread/start">>, #{<<"name">> := <<"test">>}},
        beam_agent_jsonrpc:decode(Map)).

roundtrip_response_test() ->
    Iodata = beam_agent_jsonrpc:encode_response(99, #{<<"ok">> => true}),
    Bin = iolist_to_binary(Iodata),
    {ok, Map} = beam_agent_jsonl:decode_line(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertMatch(
        {response, 99, #{<<"ok">> := true}},
        beam_agent_jsonrpc:decode(Map)).

%%====================================================================
%% next_id tests
%%====================================================================

next_id_monotonic_test() ->
    %% Reset counter for this test
    erase({beam_agent_jsonrpc, next_id}),
    Id1 = beam_agent_jsonrpc:next_id(),
    Id2 = beam_agent_jsonrpc:next_id(),
    Id3 = beam_agent_jsonrpc:next_id(),
    ?assert(Id1 < Id2),
    ?assert(Id2 < Id3),
    ?assertEqual(1, Id1),
    ?assertEqual(2, Id2),
    ?assertEqual(3, Id3).

%%====================================================================
%% No jsonrpc field in all encoded output
%%====================================================================

no_jsonrpc_field_in_any_output_test() ->
    Outputs = [
        beam_agent_jsonrpc:encode_request(1, <<"m">>, #{}),
        beam_agent_jsonrpc:encode_notification(<<"n">>, #{}),
        beam_agent_jsonrpc:encode_response(1, #{}),
        beam_agent_jsonrpc:encode_error(1, -1, <<"e">>),
        beam_agent_jsonrpc:encode_error(1, -1, <<"e">>, #{})
    ],
    lists:foreach(fun(Iodata) ->
        Bin = iolist_to_binary(Iodata),
        Line = binary:part(Bin, 0, byte_size(Bin) - 1),
        {ok, Map} = beam_agent_jsonl:decode_line(Line),
        ?assertNot(maps:is_key(<<"jsonrpc">>, Map))
    end, Outputs).
