-module(beam_agent_json_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit: safe_decode_object/1
%%====================================================================

safe_decode_object_valid_object_test() ->
    {ok, Map} = beam_agent_json:safe_decode_object(<<"{\"key\":\"value\"}">>),
    ?assertEqual(#{<<"key">> => <<"value">>}, Map).

safe_decode_object_empty_object_test() ->
    ?assertEqual({ok, #{}}, beam_agent_json:safe_decode_object(<<"{}">>)).

safe_decode_object_nested_object_test() ->
    Input = <<"{\"outer\":{\"inner\":42}}">>,
    {ok, Map} = beam_agent_json:safe_decode_object(Input),
    ?assertEqual(#{<<"inner">> => 42}, maps:get(<<"outer">>, Map)).

safe_decode_object_array_test() ->
    {error, {not_object, List}} = beam_agent_json:safe_decode_object(<<"[1,2,3]">>),
    ?assertEqual([1, 2, 3], List).

safe_decode_object_string_test() ->
    {error, {not_object, Str}} = beam_agent_json:safe_decode_object(<<"\"hello\"">>),
    ?assertEqual(<<"hello">>, Str).

safe_decode_object_number_test() ->
    {error, {not_object, _}} = beam_agent_json:safe_decode_object(<<"42">>).

safe_decode_object_null_test() ->
    {error, {not_object, null}} = beam_agent_json:safe_decode_object(<<"null">>).

safe_decode_object_boolean_test() ->
    {error, {not_object, true}} = beam_agent_json:safe_decode_object(<<"true">>).

safe_decode_object_invalid_json_test() ->
    {error, {decode_failed, _}} = beam_agent_json:safe_decode_object(<<"{broken">>).

safe_decode_object_empty_binary_test() ->
    {error, {decode_failed, _}} = beam_agent_json:safe_decode_object(<<>>).

safe_decode_object_not_binary_test() ->
    ?assertEqual({error, {decode_failed, not_binary}},
                 beam_agent_json:safe_decode_object("not a binary")).

safe_decode_object_not_binary_atom_test() ->
    ?assertEqual({error, {decode_failed, not_binary}},
                 beam_agent_json:safe_decode_object(hello)).

safe_decode_object_too_large_test() ->
    %% 50 MB limit = 52_428_800 bytes; exceed by 1 byte
    OverSize = 52_428_800 + 1,
    Bin = binary:copy(<<0>>, OverSize),
    ?assertEqual({error, {json_too_large, OverSize}},
                 beam_agent_json:safe_decode_object(Bin)).

safe_decode_object_at_limit_test() ->
    %% Exactly at the 50 MB boundary — should attempt decode, not reject
    AtLimit = 52_428_800,
    Bin = iolist_to_binary([<<"{\"k\":\"">>, binary:copy(<<"a">>, AtLimit - 8), <<"\"}">>]),
    %% Will either succeed or fail JSON parse, but must NOT return json_too_large
    Result = beam_agent_json:safe_decode_object(Bin),
    case Result of
        {ok, _} -> ok;
        {error, {decode_failed, _}} -> ok;
        {error, {json_too_large, _}} -> ?assert(false)
    end.

%%====================================================================
%% EUnit: max_decode_size/0
%%====================================================================

max_decode_size_returns_expected_value_test() ->
    ?assertEqual(52_428_800, beam_agent_json:max_decode_size()).

max_decode_size_is_positive_integer_test() ->
    Max = beam_agent_json:max_decode_size(),
    ?assert(is_integer(Max)),
    ?assert(Max > 0).

%%====================================================================
%% EUnit: safe_decode/1
%%====================================================================

safe_decode_valid_object_test() ->
    ?assertEqual({ok, #{<<"key">> => <<"val">>}},
        beam_agent_json:safe_decode(<<"{\"key\":\"val\"}">>)).

safe_decode_valid_array_test() ->
    ?assertEqual({ok, [1, 2, 3]},
        beam_agent_json:safe_decode(<<"[1,2,3]">>)).

safe_decode_valid_string_test() ->
    ?assertEqual({ok, <<"hello">>},
        beam_agent_json:safe_decode(<<"\"hello\"">>)).

safe_decode_valid_number_test() ->
    ?assertEqual({ok, 42},
        beam_agent_json:safe_decode(<<"42">>)).

safe_decode_valid_boolean_test() ->
    ?assertEqual({ok, true},
        beam_agent_json:safe_decode(<<"true">>)).

safe_decode_valid_null_test() ->
    ?assertEqual({ok, null},
        beam_agent_json:safe_decode(<<"null">>)).

safe_decode_invalid_json_test() ->
    ?assertMatch({error, {decode_failed, _}},
        beam_agent_json:safe_decode(<<"not json">>)).

safe_decode_empty_binary_test() ->
    ?assertMatch({error, {decode_failed, _}},
        beam_agent_json:safe_decode(<<>>)).

safe_decode_non_binary_test() ->
    ?assertEqual({error, {decode_failed, not_binary}},
        beam_agent_json:safe_decode(not_a_binary)).

safe_decode_rejects_oversized_input_test() ->
    Max = beam_agent_json:max_decode_size(),
    Big = binary:copy(<<0>>, Max + 1),
    ?assertEqual({error, {json_too_large, Max + 1}},
        beam_agent_json:safe_decode(Big)).

safe_decode_at_limit_attempts_decode_test() ->
    %% Exactly at the 50 MB boundary — must NOT return json_too_large
    Max = beam_agent_json:max_decode_size(),
    Bin = binary:copy(<<"x">>, Max),
    Result = beam_agent_json:safe_decode(Bin),
    case Result of
        {ok, _} -> ok;
        {error, {decode_failed, _}} -> ok;
        {error, {json_too_large, _}} -> ?assert(false)
    end.
