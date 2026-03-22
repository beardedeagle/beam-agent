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
        %% v2 tool event names
        <<"tool.executing">>, <<"tool.completed">>,
        %% v3 tool event names
        <<"tool.execution_start">>, <<"tool.execution_complete">>,
        <<"agent.toolCall">>,
        <<"session.idle">>, <<"session.error">>, <<"session.resume">>,
        %% v2 permission/compaction/plan names
        <<"permission.request">>, <<"permission.resolved">>,
        <<"compaction.started">>, <<"compaction.completed">>,
        <<"plan.update">>,
        %% v3 permission/compaction/plan names
        <<"permission.requested">>, <<"permission.completed">>,
        <<"session.compaction_start">>, <<"session.compaction_complete">>,
        <<"session.plan_changed">>,
        <<"user.message">>,
        %% COP-9: new session lifecycle events
        <<"session.start">>, <<"session.title_changed">>,
        <<"session.model_change">>, <<"session.mode_changed">>,
        <<"session.shutdown">>, <<"session.usage_info">>,
        <<"session.tools_updated">>, <<"session.skills_loaded">>,
        <<"session.mcp_servers_loaded">>,
        %% COP-9: new turn lifecycle events
        <<"assistant.turn_start">>, <<"assistant.turn_end">>,
        <<"assistant.usage">>, <<"assistant.intent">>,
        <<"assistant.streaming_delta">>,
        %% COP-9: subagent events
        <<"subagent.started">>, <<"subagent.completed">>,
        <<"subagent.failed">>, <<"subagent.selected">>,
        <<"subagent.deselected">>,
        %% COP-9: hook events
        <<"hook.start">>, <<"hook.end">>,
        %% COP-9: skill events
        <<"skill.invoked">>,
        %% COP-9: elicitation events
        <<"elicitation.requested">>, <<"elicitation.completed">>,
        %% COP-9: command events
        <<"command.queued">>, <<"command.execute">>,
        <<"command.completed">>, <<"commands.changed">>,
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
        %% v2 names (still accepted via guard clauses)
        {<<"tool.executing">>, tool_use},
        {<<"tool.completed">>, tool_result},
        %% v3 names
        {<<"tool.execution_start">>, tool_use},
        {<<"tool.execution_complete">>, tool_result},
        {<<"agent.toolCall">>, tool_use},
        {<<"session.idle">>, result},
        {<<"session.error">>, error},
        {<<"session.resume">>, system},
        %% v2 permission names
        {<<"permission.request">>, control_request},
        {<<"permission.resolved">>, control_response},
        %% v3 permission names
        {<<"permission.requested">>, control_request},
        %% v2 compaction/plan names (still accepted via guard clauses)
        {<<"compaction.started">>, system},
        {<<"compaction.completed">>, system},
        {<<"plan.update">>, system},
        %% v3 compaction/plan names
        {<<"session.compaction_start">>, system},
        {<<"session.compaction_complete">>, system},
        {<<"session.plan_changed">>, system},
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
gen_event_for_type(<<"tool.execution_start">>) ->
    #{<<"type">> => <<"tool.execution_start">>,
      <<"data">> => #{<<"toolName">> => <<"Bash">>, <<"arguments">> => #{}}};
gen_event_for_type(<<"tool.execution_complete">>) ->
    #{<<"type">> => <<"tool.execution_complete">>,
      <<"data">> => #{<<"toolName">> => <<"Read">>, <<"output">> => <<"ok">>}};
gen_event_for_type(<<"permission.requested">>) ->
    #{<<"type">> => <<"permission.requested">>,
      <<"data">> => #{<<"requestId">> => <<"req1">>, <<"request">> => #{}}};
gen_event_for_type(<<"permission.completed">>) ->
    #{<<"type">> => <<"permission.completed">>,
      <<"data">> => #{<<"result">> => <<"ok">>}};
gen_event_for_type(<<"session.compaction_start">>) ->
    #{<<"type">> => <<"session.compaction_start">>, <<"data">> => #{}};
gen_event_for_type(<<"session.compaction_complete">>) ->
    #{<<"type">> => <<"session.compaction_complete">>, <<"data">> => #{}};
gen_event_for_type(<<"session.plan_changed">>) ->
    #{<<"type">> => <<"session.plan_changed">>,
      <<"data">> => #{<<"plan">> => <<"step 1">>}};
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
