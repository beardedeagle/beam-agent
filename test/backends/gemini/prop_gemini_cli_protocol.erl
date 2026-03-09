%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for gemini_cli_protocol.
%%%
%%% Fuzz-tests the Gemini CLI wire protocol normalization with random
%%% inputs to verify robustness. Uses PropEr generators for event maps,
%%% stats maps, and exit codes.
%%%
%%% Properties (200 test cases each):
%%%   1. normalize_event/1 never crashes on any map input
%%%   2. Output always has required type key
%%%   3. parse_stats/1 always returns map with all 4 stat keys
%%%   4. exit_code_to_error/1 always returns binary for any integer
%%%   5. Known event types produce expected beam_agent_core types
%%%   6. Tool events preserve tool_name and tool_use_id
%%%   7. Result events always include stats map
%%% @end
%%%-------------------------------------------------------------------
-module(prop_gemini_cli_protocol).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

normalize_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_normalize_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

output_always_has_type_test() ->
    ?assert(proper:quickcheck(prop_output_always_has_type(),
        [{numtests, 200}, {to_file, user}])).

parse_stats_always_complete_test() ->
    ?assert(proper:quickcheck(prop_parse_stats_always_complete(),
        [{numtests, 200}, {to_file, user}])).

exit_code_always_binary_test() ->
    ?assert(proper:quickcheck(prop_exit_code_always_binary(),
        [{numtests, 200}, {to_file, user}])).

known_types_produce_expected_test() ->
    ?assert(proper:quickcheck(prop_known_types_produce_expected(),
        [{numtests, 200}, {to_file, user}])).

tool_events_preserve_ids_test() ->
    ?assert(proper:quickcheck(prop_tool_events_preserve_ids(),
        [{numtests, 200}, {to_file, user}])).

result_events_include_stats_test() ->
    ?assert(proper:quickcheck(prop_result_events_include_stats(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: normalize_event/1 never crashes on any map
prop_normalize_never_crashes() ->
    ?FORALL(RawEvent, gen_raw_event(),
        begin
            Result = gemini_cli_protocol:normalize_event(RawEvent),
            is_map(Result)
        end).

%% Property 2: Output always contains a type key
prop_output_always_has_type() ->
    ?FORALL(RawEvent, gen_raw_event(),
        begin
            Msg = gemini_cli_protocol:normalize_event(RawEvent),
            maps:is_key(type, Msg)
        end).

%% Property 3: parse_stats/1 always returns map with all 4 stat keys
prop_parse_stats_always_complete() ->
    RequiredKeys = [tokens_in, tokens_out, duration_ms, tool_calls],
    ?FORALL(Input, gen_stats_input(),
        begin
            Stats = gemini_cli_protocol:parse_stats(Input),
            is_map(Stats) andalso
            lists:all(fun(K) -> maps:is_key(K, Stats) end, RequiredKeys)
        end).

%% Property 4: exit_code_to_error/1 always returns binary for any integer
prop_exit_code_always_binary() ->
    ?FORALL(Code, integer(),
        is_binary(gemini_cli_protocol:exit_code_to_error(Code))).

%% Property 5: Known event types produce expected beam_agent_core types
prop_known_types_produce_expected() ->
    ?FORALL({EventType, ExpectedType}, gen_type_pair(),
        begin
            Event = gen_event_for_type(EventType),
            Msg = gemini_cli_protocol:normalize_event(Event),
            maps:get(type, Msg) =:= ExpectedType
        end).

%% Property 6: Tool events preserve tool_name and tool_use_id
prop_tool_events_preserve_ids() ->
    ?FORALL({ToolName, ToolId}, {binary(), binary()},
        begin
            Event = #{<<"type">> => <<"tool_use">>,
                      <<"tool_name">> => ToolName,
                      <<"tool_id">> => ToolId,
                      <<"parameters">> => #{}},
            Msg = gemini_cli_protocol:normalize_event(Event),
            maps:get(tool_name, Msg) =:= ToolName andalso
            maps:get(tool_use_id, Msg) =:= ToolId
        end).

%% Property 7: Result events always include stats map
prop_result_events_include_stats() ->
    ?FORALL(StatsMap, gen_stats_input(),
        begin
            Event = #{<<"type">> => <<"result">>,
                      <<"status">> => <<"success">>,
                      <<"stats">> => StatsMap},
            Msg = gemini_cli_protocol:normalize_event(Event),
            maps:get(type, Msg) =:= result andalso
            is_map(maps:get(stats, Msg))
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_raw_event() ->
    ?LET(Type, oneof([
        <<"init">>, <<"message">>, <<"tool_use">>, <<"tool_result">>,
        <<"error">>, <<"result">>, binary()
    ]),
    ?LET(Extra, map(binary(), binary()),
        Extra#{<<"type">> => Type})).

gen_stats_input() ->
    oneof([
        #{<<"tokens_in">> => non_neg_integer(),
          <<"tokens_out">> => non_neg_integer(),
          <<"duration_ms">> => non_neg_integer(),
          <<"tool_calls">> => non_neg_integer()},
        #{},  %% empty map
        map(binary(), non_neg_integer()),  %% random keys
        not_a_map  %% non-map triggers default
    ]).

gen_type_pair() ->
    oneof([
        {<<"init">>, system},
        {<<"error_warning">>, system},   %% via error + severity=warning
        {<<"error_error">>, error},
        {<<"result_success">>, result},
        {<<"result_error">>, error},
        {<<"tool_use">>, tool_use},
        {<<"tool_result_success">>, tool_result},
        {<<"tool_result_error">>, error},
        {<<"message_user">>, user},
        {<<"message_assistant">>, text}
    ]).

gen_event_for_type(<<"init">>) ->
    #{<<"type">> => <<"init">>, <<"session_id">> => <<"s1">>, <<"model">> => <<"m1">>};
gen_event_for_type(<<"error_warning">>) ->
    #{<<"type">> => <<"error">>, <<"severity">> => <<"warning">>, <<"message">> => <<"w">>};
gen_event_for_type(<<"error_error">>) ->
    #{<<"type">> => <<"error">>, <<"severity">> => <<"error">>, <<"message">> => <<"e">>};
gen_event_for_type(<<"result_success">>) ->
    #{<<"type">> => <<"result">>, <<"status">> => <<"success">>, <<"stats">> => #{}};
gen_event_for_type(<<"result_error">>) ->
    #{<<"type">> => <<"result">>, <<"status">> => <<"error">>, <<"message">> => <<"e">>};
gen_event_for_type(<<"tool_use">>) ->
    #{<<"type">> => <<"tool_use">>, <<"tool_name">> => <<"t">>, <<"tool_id">> => <<"id">>};
gen_event_for_type(<<"tool_result_success">>) ->
    #{<<"type">> => <<"tool_result">>, <<"status">> => <<"success">>, <<"output">> => <<"o">>};
gen_event_for_type(<<"tool_result_error">>) ->
    #{<<"type">> => <<"tool_result">>, <<"status">> => <<"error">>, <<"output">> => <<"e">>};
gen_event_for_type(<<"message_user">>) ->
    #{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => <<"hi">>};
gen_event_for_type(<<"message_assistant">>) ->
    #{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>, <<"content">> => <<"hello">>}.
