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
