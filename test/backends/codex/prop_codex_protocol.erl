%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for codex_protocol.
%%%
%%% Fuzz-tests the Codex wire protocol normalization with random inputs
%%% to verify robustness. Uses PropEr generators for notification params,
%%% item types, approval decisions, and enum encodings.
%%%
%%% Properties (200 test cases each):
%%%   1. normalize_notification/2 never crashes on any method + params
%%%   2. Output always has required type key
%%%   3. parse_approval_decision/1 always returns valid atom
%%%   4. encode/decode approval decision roundtrip
%%%   5. Known methods produce expected types
%%%   6. Item started/completed with unknown types produce raw
%%%   7. turn_start_params always includes threadId and input
%%% @end
%%%-------------------------------------------------------------------
-module(prop_codex_protocol).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration — run PropEr properties via eunit
%%====================================================================

normalize_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_normalize_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

output_always_has_type_test() ->
    ?assert(proper:quickcheck(prop_output_always_has_type(),
        [{numtests, 200}, {to_file, user}])).

parse_approval_valid_test() ->
    ?assert(proper:quickcheck(prop_parse_approval_valid(),
        [{numtests, 200}, {to_file, user}])).

approval_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_approval_roundtrip(),
        [{numtests, 200}, {to_file, user}])).

known_methods_produce_expected_types_test() ->
    ?assert(proper:quickcheck(prop_known_methods_produce_expected_types(),
        [{numtests, 200}, {to_file, user}])).

unknown_item_types_produce_raw_test() ->
    ?assert(proper:quickcheck(prop_unknown_item_types_produce_raw(),
        [{numtests, 200}, {to_file, user}])).

turn_start_params_shape_test() ->
    ?assert(proper:quickcheck(prop_turn_start_params_shape(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: normalize_notification/2 never crashes on any input
prop_normalize_never_crashes() ->
    ?FORALL({Method, Params}, {gen_method(), gen_params()},
        begin
            Result = codex_protocol:normalize_notification(Method, Params),
            is_map(Result)
        end).

%% Property 2: Output always contains a type key
prop_output_always_has_type() ->
    ?FORALL({Method, Params}, {gen_method(), gen_params()},
        begin
            Msg = codex_protocol:normalize_notification(Method, Params),
            maps:is_key(type, Msg)
        end).

%% Property 3: parse_approval_decision/1 always returns a valid atom
prop_parse_approval_valid() ->
    ValidAtoms = [accept, accept_for_session, decline, cancel],
    ?FORALL(Input, gen_approval_input(),
        lists:member(codex_protocol:parse_approval_decision(Input), ValidAtoms)).

%% Property 4: encode then parse is identity for known decisions
prop_approval_roundtrip() ->
    ?FORALL(Decision, oneof([accept, accept_for_session, decline, cancel]),
        begin
            Encoded = codex_protocol:encode_approval_decision(Decision),
            Decoded = codex_protocol:parse_approval_decision(Encoded),
            Decoded =:= Decision
        end).

%% Property 5: Known methods always produce their expected type
prop_known_methods_produce_expected_types() ->
    ?FORALL({Method, ExpectedType}, gen_method_type_pair(),
        begin
            Params = gen_params_for_method(Method),
            Msg = codex_protocol:normalize_notification(Method, Params),
            maps:get(type, Msg) =:= ExpectedType
        end).

%% Property 6: Item started/completed with unknown types produce raw
prop_unknown_item_types_produce_raw() ->
    ?FORALL({Notif, UnknownType}, {oneof([<<"item/started">>, <<"item/completed">>]),
                                    gen_unknown_item_type()},
        begin
            Params = #{<<"item">> => #{<<"type">> => UnknownType}},
            Msg = codex_protocol:normalize_notification(Notif, Params),
            maps:get(type, Msg) =:= raw
        end).

%% Property 7: turn_start_params always includes threadId and input
prop_turn_start_params_shape() ->
    ?FORALL({ThreadId, Prompt}, {binary(), binary()},
        begin
            Result = codex_protocol:turn_start_params(ThreadId, Prompt),
            maps:is_key(<<"threadId">>, Result) andalso
            maps:is_key(<<"input">>, Result) andalso
            maps:get(<<"threadId">>, Result) =:= ThreadId
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_method() ->
    oneof([
        <<"item/agentMessage/delta">>,
        <<"item/started">>,
        <<"item/completed">>,
        <<"turn/completed">>,
        <<"turn/started">>,
        <<"item/commandExecution/outputDelta">>,
        <<"item/fileChange/outputDelta">>,
        <<"item/reasoning/textDelta">>,
        <<"error">>,
        <<"thread/status/changed">>,
        binary()  %% random unknown method
    ]).

gen_params() ->
    ?LET(Extra, map(binary(), binary()),
        ?LET(Item, gen_item(),
            Extra#{<<"item">> => Item,
                   <<"delta">> => <<"some delta">>,
                   <<"status">> => <<"completed">>})).

gen_item() ->
    ?LET(Type, oneof([<<"AgentMessage">>, <<"CommandExecution">>,
                       <<"FileChange">>, binary()]),
        #{<<"type">> => Type,
          <<"content">> => <<"test content">>,
          <<"command">> => <<"ls">>,
          <<"output">> => <<"output">>,
          <<"filePath">> => <<"/tmp/test">>,
          <<"action">> => <<"write">>}).

gen_approval_input() ->
    oneof([
        <<"accept">>, <<"acceptForSession">>, <<"decline">>, <<"cancel">>,
        binary()  %% random -> decline
    ]).

gen_method_type_pair() ->
    oneof([
        {<<"item/agentMessage/delta">>, text},
        {<<"turn/completed">>, result},
        {<<"turn/started">>, system},
        {<<"item/commandExecution/outputDelta">>, stream_event},
        {<<"item/fileChange/outputDelta">>, stream_event},
        {<<"item/reasoning/textDelta">>, thinking},
        {<<"error">>, error},
        {<<"thread/status/changed">>, system}
    ]).

gen_params_for_method(<<"item/started">>) ->
    #{<<"item">> => #{<<"type">> => <<"AgentMessage">>,
                      <<"content">> => <<"hello">>}};
gen_params_for_method(<<"item/completed">>) ->
    #{<<"item">> => #{<<"type">> => <<"CommandExecution">>,
                      <<"command">> => <<"ls">>,
                      <<"output">> => <<"files">>}};
gen_params_for_method(_) ->
    #{<<"delta">> => <<"d">>, <<"status">> => <<"ok">>,
      <<"message">> => <<"msg">>}.

gen_unknown_item_type() ->
    ?SUCHTHAT(T, binary(),
        T =/= <<"AgentMessage">> andalso
        T =/= <<"CommandExecution">> andalso
        T =/= <<"FileChange">>).
