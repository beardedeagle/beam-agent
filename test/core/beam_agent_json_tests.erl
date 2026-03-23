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
