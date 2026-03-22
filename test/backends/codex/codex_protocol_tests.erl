%%%-------------------------------------------------------------------
%%% @doc Unit tests for codex_protocol.
%%%
%%% Tests the Codex wire protocol encoders, decoders, and
%%% normalization functions.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Notification normalization
%%====================================================================

agent_message_delta_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"item/agentMessage/delta">>,
              #{<<"delta">> => <<"hello">>}),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"hello">>, maps:get(content, Msg)).

item_started_agent_message_test() ->
    Item = #{<<"type">> => <<"AgentMessage">>,
             <<"content">> => <<"hi">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/started">>, #{<<"item">> => Item}),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"hi">>, maps:get(content, Msg)).

item_started_command_execution_test() ->
    Item = #{<<"type">> => <<"CommandExecution">>,
             <<"command">> => <<"ls">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/started">>, #{<<"item">> => Item}),
    ?assertEqual(tool_use, maps:get(type, Msg)).

item_started_file_change_test() ->
    Item = #{<<"type">> => <<"FileChange">>,
             <<"filePath">> => <<"/tmp/x">>,
             <<"action">> => <<"write">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/started">>, #{<<"item">> => Item}),
    ?assertEqual(tool_use, maps:get(type, Msg)).

item_completed_command_execution_test() ->
    Item = #{<<"type">> => <<"CommandExecution">>,
             <<"command">> => <<"ls">>,
             <<"output">> => <<"files">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/completed">>, #{<<"item">> => Item}),
    ?assertEqual(tool_result, maps:get(type, Msg)).

item_completed_file_change_test() ->
    Item = #{<<"type">> => <<"FileChange">>,
             <<"filePath">> => <<"/tmp/x">>,
             <<"action">> => <<"write">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/completed">>, #{<<"item">> => Item}),
    ?assertEqual(tool_result, maps:get(type, Msg)).

item_started_unknown_type_test() ->
    Item = #{<<"type">> => <<"SomethingNew">>},
    Msg = codex_protocol:normalize_notification(
              <<"item/started">>, #{<<"item">> => Item}),
    ?assertEqual(raw, maps:get(type, Msg)).

turn_completed_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"turn/completed">>,
              #{<<"status">> => <<"completed">>}),
    ?assertEqual(result, maps:get(type, Msg)).

turn_completed_error_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"turn/completed">>,
              #{<<"status">> => <<"error">>,
                <<"error">> => <<"oops">>}),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"error">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"oops">>, maps:get(content, Msg)).

command_output_delta_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"item/commandExecution/outputDelta">>,
              #{<<"delta">> => <<"line1">>}),
    ?assertEqual(stream_event, maps:get(type, Msg)).

reasoning_delta_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"item/reasoning/textDelta">>,
              #{<<"delta">> => <<"thinking...">>}),
    ?assertEqual(thinking, maps:get(type, Msg)).

error_notification_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"error">>,
              #{<<"message">> => <<"fail">>}),
    ?assertEqual(error, maps:get(type, Msg)).

unknown_method_produces_raw_test() ->
    Msg = codex_protocol:normalize_notification(
              <<"completely/unknown">>, #{<<"x">> => 1}),
    ?assertEqual(raw, maps:get(type, Msg)).

%%====================================================================
%% Thread and turn params
%%====================================================================

thread_start_params_test() ->
    Params = codex_protocol:thread_start_params(#{}),
    ?assert(is_map(Params)).

turn_start_params_binary_test() ->
    Params = codex_protocol:turn_start_params(<<"t1">>, <<"hello">>),
    ?assertEqual(<<"t1">>, maps:get(<<"threadId">>, Params)),
    Inputs = maps:get(<<"input">>, Params),
    ?assert(is_list(Inputs)),
    ?assert(length(Inputs) > 0).

turn_start_params_with_opts_test() ->
    Opts = #{model => <<"gpt-4">>, effort => <<"high">>},
    Params = codex_protocol:turn_start_params(<<"t1">>, <<"hi">>, Opts),
    ?assertEqual(<<"gpt-4">>, maps:get(<<"model">>, Params)),
    ?assertEqual(<<"high">>, maps:get(<<"effort">>, Params)).

%%====================================================================
%% Initialize params
%%====================================================================

initialize_params_with_model_test() ->
    Params = codex_protocol:initialize_params(#{model => <<"gpt-4">>}),
    ?assertEqual(<<"gpt-4">>, maps:get(<<"model">>, Params)).

initialize_params_minimal_test() ->
    Params = codex_protocol:initialize_params(#{}),
    ?assert(maps:is_key(<<"clientInfo">>, Params)),
    ?assertNot(maps:is_key(<<"model">>, Params)).

%%====================================================================
%% Approval response builders (V2 ReviewDecision wire values)
%%====================================================================

command_approval_approved_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"approved">>},
                 codex_protocol:command_approval_response(approved)).

command_approval_approved_for_session_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"approved_for_session">>},
                 codex_protocol:command_approval_response(approved_for_session)).

command_approval_denied_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"denied">>},
                 codex_protocol:command_approval_response(denied)).

command_approval_abort_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"abort">>},
                 codex_protocol:command_approval_response(abort)).

file_approval_approved_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"approved">>},
                 codex_protocol:file_approval_response(approved)).

file_approval_denied_test() ->
    ?assertEqual(#{<<"review_decision">> => <<"denied">>},
                 codex_protocol:file_approval_response(denied)).

%%====================================================================
%% Enum round-trip tests
%%====================================================================

approval_decision_roundtrip_test() ->
    Decisions = [approved, approved_for_session, denied, abort],
    lists:foreach(fun(D) ->
        Encoded = codex_protocol:encode_approval_decision(D),
        ?assertEqual(D, codex_protocol:parse_approval_decision(Encoded))
    end, Decisions).

parse_unknown_approval_defaults_to_denied_test() ->
    ?assertEqual(denied, codex_protocol:parse_approval_decision(<<"garbage">>)).

encode_ask_for_approval_all_variants_test() ->
    ?assertEqual(<<"untrusted">>,  codex_protocol:encode_ask_for_approval(untrusted)),
    ?assertEqual(<<"on-failure">>, codex_protocol:encode_ask_for_approval(on_failure)),
    ?assertEqual(<<"on-request">>, codex_protocol:encode_ask_for_approval(on_request)),
    ?assertEqual(<<"never">>,      codex_protocol:encode_ask_for_approval(never)).

encode_ask_for_approval_granular_test() ->
    Config = #{<<"bash">> => on_failure, <<"write">> => never},
    Result = codex_protocol:encode_ask_for_approval({granular, Config}),
    ?assertEqual(<<"granular">>, maps:get(<<"type">>, Result)),
    ConfigResult = maps:get(<<"config">>, Result),
    ?assertEqual(<<"on-failure">>, maps:get(<<"bash">>, ConfigResult)),
    ?assertEqual(<<"never">>, maps:get(<<"write">>, ConfigResult)).

%%====================================================================
%% Sandbox policy encoding (V2 tagged objects)
%%====================================================================

encode_sandbox_mode_read_only_test() ->
    Result = codex_protocol:encode_sandbox_mode(read_only),
    ?assertEqual(#{<<"type">> => <<"readOnly">>}, Result).

encode_sandbox_mode_workspace_write_test() ->
    Result = codex_protocol:encode_sandbox_mode(workspace_write),
    ?assertEqual(#{<<"type">> => <<"workspaceWrite">>}, Result).

encode_sandbox_mode_full_access_test() ->
    Result = codex_protocol:encode_sandbox_mode(danger_full_access),
    ?assertEqual(#{<<"type">> => <<"fullAccess">>}, Result).

encode_sandbox_policy_structured_test() ->
    Policy = #{type => workspace_write,
               writable_roots => [<<"/tmp">>, <<"/home">>],
               network_access => none},
    Result = codex_protocol:encode_sandbox_mode(Policy),
    ?assertEqual(<<"workspaceWrite">>, maps:get(<<"type">>, Result)),
    ?assertEqual([<<"/tmp">>, <<"/home">>], maps:get(<<"writableRoots">>, Result)),
    ?assertEqual(<<"none">>, maps:get(<<"networkAccess">>, Result)).

%%====================================================================
%% Text input
%%====================================================================

text_input_test() ->
    Input = codex_protocol:text_input(<<"hello">>),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Input)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Input)).

%%====================================================================
%% User input response
%%====================================================================

user_input_response_answers_test() ->
    R = codex_protocol:request_user_input_response(#{answers => #{<<"q1">> => <<"a1">>}}),
    ?assert(maps:is_key(<<"answers">>, R)).

user_input_response_default_test() ->
    R = codex_protocol:request_user_input_response(undefined),
    ?assertEqual(#{<<"answers">> => #{}}, R).
