%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for copilot_protocol.
%%%
%%% Fuzz-tests the Copilot wire protocol normalization with random
%%% inputs to verify robustness. Uses PropEr generators for event
%%% maps, JSON-RPC encoding, and CLI arg building.
%%%
%%% Properties (200 test cases each):
%%%   1. normalize_event/1 never crashes on any map with type+data
%%%   2. Output always has required type key
%%%   3. encode_request always produces valid JSON-RPC 2.0 map
%%%   4. encode_response always has jsonrpc, id, result keys
%%%   5. Known event types produce expected beam_agent_core types
%%%   6. Tool events preserve tool_name
%%%   7. sdk_protocol_version returns positive integer
%%% @end
%%%-------------------------------------------------------------------
-module(prop_copilot_protocol).

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

encode_request_valid_jsonrpc_test() ->
    ?assert(proper:quickcheck(prop_encode_request_valid_jsonrpc(),
        [{numtests, 200}, {to_file, user}])).

encode_response_has_required_keys_test() ->
    ?assert(proper:quickcheck(prop_encode_response_has_required_keys(),
        [{numtests, 200}, {to_file, user}])).

known_types_produce_expected_test() ->
    ?assert(proper:quickcheck(prop_known_types_produce_expected(),
        [{numtests, 200}, {to_file, user}])).

tool_events_preserve_name_test() ->
    ?assert(proper:quickcheck(prop_tool_events_preserve_name(),
        [{numtests, 200}, {to_file, user}])).

sdk_protocol_version_positive_test() ->
    V = copilot_protocol:sdk_protocol_version(),
    ?assert(is_integer(V) andalso V > 0).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: normalize_event/1 never crashes on any map with type+data
prop_normalize_never_crashes() ->
    ?FORALL(RawEvent, gen_raw_event(),
        begin
            Result = copilot_protocol:normalize_event(RawEvent),
            is_map(Result)
        end).

%% Property 2: Output always contains a type key
prop_output_always_has_type() ->
    ?FORALL(RawEvent, gen_raw_event(),
        begin
            Msg = copilot_protocol:normalize_event(RawEvent),
            maps:is_key(type, Msg)
        end).

%% Property 3: encode_request always produces valid JSON-RPC 2.0 map
prop_encode_request_valid_jsonrpc() ->
    ?FORALL({Id, Method, Params}, {gen_id(), gen_method_name(), gen_params()},
        begin
            Result = copilot_protocol:encode_request(Id, Method, Params),
            is_map(Result) andalso
            maps:get(<<"jsonrpc">>, Result) =:= <<"2.0">> andalso
            maps:get(<<"id">>, Result) =:= Id andalso
            maps:get(<<"method">>, Result) =:= Method andalso
            maps:is_key(<<"params">>, Result)
        end).

%% Property 4: encode_response always has jsonrpc, id, result keys
prop_encode_response_has_required_keys() ->
    ?FORALL({Id, ResultVal}, {gen_id(), gen_result_value()},
        begin
            Resp = copilot_protocol:encode_response(Id, ResultVal),
            maps:get(<<"jsonrpc">>, Resp) =:= <<"2.0">> andalso
            maps:get(<<"id">>, Resp) =:= Id andalso
            maps:is_key(<<"result">>, Resp)
        end).

%% Property 5: Known event types produce expected beam_agent_core types
prop_known_types_produce_expected() ->
    ?FORALL({EventType, ExpectedType}, gen_type_pair(),
        begin
            Event = gen_event_for_type(EventType),
            Msg = copilot_protocol:normalize_event(Event),
            maps:get(type, Msg) =:= ExpectedType
        end).

%% Property 6: Tool events preserve tool_name
prop_tool_events_preserve_name() ->
    ?FORALL(ToolName, non_empty(binary()),
        begin
            Event = #{<<"type">> => <<"tool.executing">>,
                      <<"data">> => #{<<"toolName">> => ToolName,
                                      <<"input">> => #{}}},
            Msg = copilot_protocol:normalize_event(Event),
            maps:get(tool_name, Msg) =:= ToolName
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_raw_event() ->
    ?LET(Type, oneof([
        <<"assistant.message">>, <<"assistant.message_delta">>,
        <<"assistant.reasoning">>, <<"assistant.reasoning_delta">>,
        <<"tool.executing">>, <<"tool.completed">>, <<"tool.errored">>,
        <<"agent.toolCall">>,
        <<"session.idle">>, <<"session.error">>, <<"session.resume">>,
        <<"permission.request">>, <<"permission.resolved">>,
        <<"compaction.started">>, <<"compaction.completed">>,
        <<"plan.update">>, <<"user.message">>,
        binary()  %% random unknown type
    ]),
    ?LET(DataExtra, map(binary(), binary()),
        #{<<"type">> => Type,
          <<"data">> => DataExtra#{
              <<"content">> => <<"test">>,
              <<"toolName">> => <<"Bash">>,
              <<"message">> => <<"msg">>
          }})).

gen_id() ->
    oneof([binary(), integer(1, 999999)]).

gen_method_name() ->
    oneof([
        <<"session.create">>,
        <<"session.send">>,
        <<"session.resume">>,
        <<"config.get">>,
        binary()
    ]).

gen_params() ->
    oneof([
        #{},
        #{<<"key">> => <<"value">>},
        undefined
    ]).

gen_result_value() ->
    oneof([
        #{<<"ok">> => true},
        <<"success">>,
        null,
        true
    ]).

gen_type_pair() ->
    oneof([
        {<<"assistant.message">>, assistant},
        {<<"assistant.message_delta">>, text},
        {<<"assistant.reasoning">>, thinking},
        {<<"assistant.reasoning_delta">>, thinking},
        {<<"tool.executing">>, tool_use},
        {<<"tool.completed">>, tool_result},
        {<<"tool.errored">>, error},
        {<<"agent.toolCall">>, tool_use},
        {<<"session.idle">>, result},
        {<<"session.error">>, error},
        {<<"session.resume">>, system},
        {<<"permission.request">>, control_request},
        {<<"permission.resolved">>, control_response},
        {<<"compaction.started">>, system},
        {<<"compaction.completed">>, system},
        {<<"plan.update">>, system},
        {<<"user.message">>, user}
    ]).

gen_event_for_type(<<"assistant.message">>) ->
    #{<<"type">> => <<"assistant.message">>,
      <<"data">> => #{<<"content">> => <<"hello">>}};
gen_event_for_type(<<"assistant.message_delta">>) ->
    #{<<"type">> => <<"assistant.message_delta">>,
      <<"data">> => #{<<"deltaContent">> => <<"d">>}};
gen_event_for_type(<<"assistant.reasoning">>) ->
    #{<<"type">> => <<"assistant.reasoning">>,
      <<"data">> => #{<<"content">> => <<"think">>}};
gen_event_for_type(<<"assistant.reasoning_delta">>) ->
    #{<<"type">> => <<"assistant.reasoning_delta">>,
      <<"data">> => #{<<"deltaContent">> => <<"d">>}};
gen_event_for_type(<<"tool.executing">>) ->
    #{<<"type">> => <<"tool.executing">>,
      <<"data">> => #{<<"toolName">> => <<"Bash">>, <<"input">> => #{}}};
gen_event_for_type(<<"tool.completed">>) ->
    #{<<"type">> => <<"tool.completed">>,
      <<"data">> => #{<<"toolName">> => <<"Read">>, <<"output">> => <<"ok">>}};
gen_event_for_type(<<"tool.errored">>) ->
    #{<<"type">> => <<"tool.errored">>,
      <<"data">> => #{<<"toolName">> => <<"Bash">>, <<"error">> => <<"fail">>}};
gen_event_for_type(<<"agent.toolCall">>) ->
    #{<<"type">> => <<"agent.toolCall">>,
      <<"data">> => #{<<"toolName">> => <<"Write">>, <<"input">> => #{}}};
gen_event_for_type(<<"session.idle">>) ->
    #{<<"type">> => <<"session.idle">>, <<"data">> => #{}};
gen_event_for_type(<<"session.error">>) ->
    #{<<"type">> => <<"session.error">>,
      <<"data">> => #{<<"message">> => <<"err">>}};
gen_event_for_type(<<"session.resume">>) ->
    #{<<"type">> => <<"session.resume">>,
      <<"data">> => #{<<"session_id">> => <<"s1">>}};
gen_event_for_type(<<"permission.request">>) ->
    #{<<"type">> => <<"permission.request">>,
      <<"data">> => #{<<"kind">> => <<"file_write">>}};
gen_event_for_type(<<"permission.resolved">>) ->
    #{<<"type">> => <<"permission.resolved">>,
      <<"data">> => #{<<"allowed">> => true}};
gen_event_for_type(<<"compaction.started">>) ->
    #{<<"type">> => <<"compaction.started">>, <<"data">> => #{}};
gen_event_for_type(<<"compaction.completed">>) ->
    #{<<"type">> => <<"compaction.completed">>, <<"data">> => #{}};
gen_event_for_type(<<"plan.update">>) ->
    #{<<"type">> => <<"plan.update">>,
      <<"data">> => #{<<"plan">> => <<"step 1">>}};
gen_event_for_type(<<"user.message">>) ->
    #{<<"type">> => <<"user.message">>,
      <<"data">> => #{<<"content">> => <<"hi">>}}.
