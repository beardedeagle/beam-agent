%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for opencode_protocol.
%%%
%%% Fuzz-tests the OpenCode SSE event normalization with random inputs
%%% to verify robustness. Uses PropEr generators for SSE event maps,
%%% part types, tool statuses, and prompt inputs.
%%%
%%% Properties (200 test cases each):
%%%   1. normalize_event/1 never crashes on any SSE event map
%%%   2. Output is always beam_agent_core:message() or skip
%%%   3. Known event types produce expected beam_agent_core types
%%%   4. build_prompt_input/2 always includes parts list
%%%   5. build_permission_reply/2 always includes id and decision
%%%   6. Tool part status dispatch produces correct types
%%%   7. Heartbeat events always produce skip
%%% @end
%%%-------------------------------------------------------------------
-module(prop_opencode_protocol).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

normalize_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_normalize_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

output_valid_shape_test() ->
    ?assert(proper:quickcheck(prop_output_valid_shape(),
        [{numtests, 200}, {to_file, user}])).

known_events_produce_expected_types_test() ->
    ?assert(proper:quickcheck(prop_known_events_produce_expected_types(),
        [{numtests, 200}, {to_file, user}])).

prompt_input_always_has_parts_test() ->
    ?assert(proper:quickcheck(prop_prompt_input_always_has_parts(),
        [{numtests, 200}, {to_file, user}])).

permission_reply_shape_test() ->
    ?assert(proper:quickcheck(prop_permission_reply_shape(),
        [{numtests, 200}, {to_file, user}])).

tool_part_status_dispatch_test() ->
    ?assert(proper:quickcheck(prop_tool_part_status_dispatch(),
        [{numtests, 200}, {to_file, user}])).

heartbeat_always_skip_test() ->
    ?assert(proper:quickcheck(prop_heartbeat_always_skip(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: normalize_event/1 never crashes on any input
prop_normalize_never_crashes() ->
    ?FORALL(SseEvent, gen_sse_event(),
        begin
            Result = opencode_protocol:normalize_event(SseEvent),
            Result =:= skip orelse is_map(Result)
        end).

%% Property 2: Non-skip output always has type key
prop_output_valid_shape() ->
    ?FORALL(SseEvent, gen_sse_event(),
        begin
            Result = opencode_protocol:normalize_event(SseEvent),
            case Result of
                skip -> true;
                Msg -> maps:is_key(type, Msg)
            end
        end).

%% Property 3: Known event types produce expected beam_agent_core types
prop_known_events_produce_expected_types() ->
    ?FORALL({EventType, ExpectedType}, gen_event_type_pair(),
        begin
            SseEvent = gen_sse_event_for_type(EventType),
            Result = opencode_protocol:normalize_event(SseEvent),
            case ExpectedType of
                skip -> Result =:= skip;
                Type -> is_map(Result) andalso maps:get(type, Result) =:= Type
            end
        end).

%% Property 4: build_prompt_input/2 always includes parts
prop_prompt_input_always_has_parts() ->
    ?FORALL({Prompt, Opts}, {binary(), gen_prompt_opts()},
        begin
            Result = opencode_protocol:build_prompt_input(Prompt, Opts),
            is_map(Result) andalso
            maps:is_key(<<"parts">>, Result) andalso
            is_list(maps:get(<<"parts">>, Result))
        end).

%% Property 5: build_permission_reply/2 always has id and decision
prop_permission_reply_shape() ->
    ?FORALL({PermId, Decision}, {binary(), oneof([<<"allow">>, <<"deny">>])},
        begin
            Result = opencode_protocol:build_permission_reply(PermId, Decision),
            maps:get(<<"id">>, Result) =:= PermId andalso
            maps:get(<<"decision">>, Result) =:= Decision
        end).

%% Property 6: Tool part status dispatch produces correct types
prop_tool_part_status_dispatch() ->
    ?FORALL({Status, ExpectedType}, gen_tool_status_pair(),
        begin
            Part = #{<<"type">> => <<"tool">>,
                     <<"status">> => Status,
                     <<"state">> => #{<<"status">> => Status,
                                      <<"tool">> => <<"test_tool">>,
                                      <<"input">> => #{},
                                      <<"output">> => <<"out">>,
                                      <<"error">> => <<"err">>}},
            SseEvent = #{event => <<"message.part.updated">>,
                         data => #{<<"part">> => Part}},
            Result = opencode_protocol:normalize_event(SseEvent),
            is_map(Result) andalso maps:get(type, Result) =:= ExpectedType
        end).

%% Property 7: Heartbeat events always produce skip
prop_heartbeat_always_skip() ->
    ?FORALL(Payload, map(binary(), binary()),
        begin
            SseEvent = #{event => <<"server.heartbeat">>, data => Payload},
            opencode_protocol:normalize_event(SseEvent) =:= skip
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_sse_event() ->
    ?LET(EventType, oneof([
        <<"message.part.updated">>, <<"message.updated">>,
        <<"session.idle">>, <<"session.error">>,
        <<"permission.updated">>, <<"server.heartbeat">>,
        <<"server.connected">>, binary()
    ]),
    ?LET(Payload, map(binary(), binary()),
        #{event => EventType, data => Payload})).

gen_event_type_pair() ->
    oneof([
        {<<"session.idle">>, result},
        {<<"session.error">>, error},
        {<<"server.heartbeat">>, skip},
        {<<"server.connected">>, system},
        {<<"permission.updated">>, control_request}
    ]).

gen_sse_event_for_type(<<"session.idle">>) ->
    #{event => <<"session.idle">>, data => #{}};
gen_sse_event_for_type(<<"session.error">>) ->
    #{event => <<"session.error">>, data => #{<<"message">> => <<"err">>}};
gen_sse_event_for_type(<<"server.heartbeat">>) ->
    #{event => <<"server.heartbeat">>, data => #{}};
gen_sse_event_for_type(<<"server.connected">>) ->
    #{event => <<"server.connected">>, data => #{}};
gen_sse_event_for_type(<<"permission.updated">>) ->
    #{event => <<"permission.updated">>,
      data => #{<<"id">> => <<"perm1">>, <<"request">> => #{}}}.

gen_prompt_opts() ->
    oneof([
        #{},
        #{model => <<"claude-3">>},
        #{model => #{<<"providerID">> => <<"anthropic">>,
                     <<"modelID">> => <<"claude-3">>}}
    ]).

gen_tool_status_pair() ->
    oneof([
        {<<"pending">>, tool_use},
        {<<"running">>, tool_use},
        {<<"completed">>, tool_result},
        {<<"error">>, error}
    ]).
