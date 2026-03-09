%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_protocol — Codex message normalization
%%%      and wire format builders.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Notification normalization tests
%%====================================================================

normalize_agent_message_delta_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/agentMessage/delta">>,
        #{<<"delta">> => <<"hello world">>}),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"hello world">>, maps:get(content, Msg)).

normalize_item_started_agent_message_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/started">>,
        #{<<"item">> => #{<<"type">> => <<"AgentMessage">>,
                          <<"content">> => <<"thinking...">>}}),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"thinking...">>, maps:get(content, Msg)).

normalize_item_started_command_execution_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/started">>,
        #{<<"item">> => #{<<"type">> => <<"CommandExecution">>,
                          <<"command">> => <<"ls -la">>,
                          <<"args">> => #{<<"cwd">> => <<"/tmp">>}}}),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"ls -la">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"cwd">> => <<"/tmp">>}, maps:get(tool_input, Msg)).

normalize_item_started_file_change_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/started">>,
        #{<<"item">> => #{<<"type">> => <<"FileChange">>,
                          <<"filePath">> => <<"/src/main.rs">>,
                          <<"action">> => <<"modify">>}}),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"/src/main.rs">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"action">> => <<"modify">>}, maps:get(tool_input, Msg)).

normalize_item_completed_command_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/completed">>,
        #{<<"item">> => #{<<"type">> => <<"CommandExecution">>,
                          <<"command">> => <<"echo hi">>,
                          <<"output">> => <<"hi\n">>}}),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"echo hi">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"hi\n">>, maps:get(content, Msg)).

normalize_item_completed_file_change_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/completed">>,
        #{<<"item">> => #{<<"type">> => <<"FileChange">>,
                          <<"filePath">> => <<"/src/lib.rs">>,
                          <<"output">> => <<"modified 3 lines">>}}),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"/src/lib.rs">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"modified 3 lines">>, maps:get(content, Msg)).

normalize_turn_completed_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"turn/completed">>,
        #{<<"status">> => <<"completed">>,
          <<"turnId">> => <<"turn-1">>}),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"completed">>, maps:get(subtype, Msg)).

normalize_turn_completed_with_error_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"turn/completed">>,
        #{<<"status">> => <<"error">>,
          <<"error">> => <<"model overloaded">>}),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"model overloaded">>, maps:get(content, Msg)).

normalize_turn_started_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"turn/started">>,
        #{<<"turnId">> => <<"turn-1">>}),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"turn_started">>, maps:get(subtype, Msg)).

normalize_command_output_delta_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/commandExecution/outputDelta">>,
        #{<<"delta">> => <<"output chunk">>}),
    ?assertEqual(stream_event, maps:get(type, Msg)),
    ?assertEqual(<<"output chunk">>, maps:get(content, Msg)),
    ?assertEqual(<<"command_output">>, maps:get(subtype, Msg)).

normalize_file_output_delta_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/fileChange/outputDelta">>,
        #{<<"delta">> => <<"diff chunk">>}),
    ?assertEqual(stream_event, maps:get(type, Msg)),
    ?assertEqual(<<"diff chunk">>, maps:get(content, Msg)),
    ?assertEqual(<<"file_output">>, maps:get(subtype, Msg)).

normalize_reasoning_text_delta_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"item/reasoning/textDelta">>,
        #{<<"delta">> => <<"thinking about this...">>}),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"thinking about this...">>, maps:get(content, Msg)).

normalize_error_with_will_retry_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"error">>,
        #{<<"message">> => <<"rate limited">>,
          <<"willRetry">> => true}),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"rate limited">>, maps:get(content, Msg)),
    ?assertEqual(<<"will_retry">>, maps:get(subtype, Msg)).

normalize_error_without_retry_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"error">>,
        #{<<"message">> => <<"fatal error">>}),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"fatal error">>, maps:get(content, Msg)),
    ?assertNot(maps:is_key(subtype, Msg)).

normalize_thread_status_changed_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"thread/status/changed">>,
        #{<<"status">> => <<"active">>}),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"thread_status_changed">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"thread status: active">>, maps:get(content, Msg)).

normalize_unknown_test() ->
    Msg = codex_protocol:normalize_notification(
        <<"something/unknown">>,
        #{<<"data">> => <<"whatever">>}),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assert(maps:is_key(raw, Msg)).

%%====================================================================
%% Text input helper
%%====================================================================

text_input_test() ->
    Input = codex_protocol:text_input(<<"Hello, Codex!">>),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Input)),
    ?assertEqual(<<"Hello, Codex!">>, maps:get(<<"text">>, Input)).

%%====================================================================
%% Wire param builders
%%====================================================================

thread_start_params_all_opts_test() ->
    Params = codex_protocol:thread_start_params(#{
        ephemeral => true,
        base_instructions => <<"be helpful">>,
        developer_instructions => <<"use rust">>
    }),
    ?assertEqual(true, maps:get(<<"ephemeral">>, Params)),
    ?assertEqual(<<"be helpful">>, maps:get(<<"baseInstructions">>, Params)),
    ?assertEqual(<<"use rust">>, maps:get(<<"developerInstructions">>, Params)).

thread_start_params_empty_test() ->
    Params = codex_protocol:thread_start_params(#{}),
    ?assertEqual(false, maps:get(<<"experimentalRawEvents">>, Params)),
    ?assertEqual(false, maps:get(<<"persistExtendedHistory">>, Params)).

fuzzy_file_search_session_start_params_test() ->
    Params =
        codex_protocol:fuzzy_file_search_session_start_params(
            <<"search-1">>,
            [<<"/tmp/a">>, "/tmp/b"]),
    ?assertEqual(<<"search-1">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual([<<"/tmp/a">>, <<"/tmp/b">>], maps:get(<<"roots">>, Params)).

fuzzy_file_search_session_update_params_test() ->
    Params =
        codex_protocol:fuzzy_file_search_session_update_params(
            <<"search-1">>,
            <<"beam">>),
    ?assertEqual(<<"search-1">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual(<<"beam">>, maps:get(<<"query">>, Params)).

fuzzy_file_search_session_stop_params_test() ->
    Params =
        codex_protocol:fuzzy_file_search_session_stop_params(<<"search-1">>),
    ?assertEqual(<<"search-1">>, maps:get(<<"sessionId">>, Params)).

turn_start_params_string_prompt_test() ->
    Params = codex_protocol:turn_start_params(<<"t1">>, <<"What is 2+2?">>),
    ?assertEqual(<<"t1">>, maps:get(<<"threadId">>, Params)),
    [Input] = maps:get(<<"input">>, Params),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Input)),
    ?assertEqual(<<"What is 2+2?">>, maps:get(<<"text">>, Input)).

turn_start_params_explicit_inputs_test() ->
    Inputs = [codex_protocol:text_input(<<"hello">>)],
    Params = codex_protocol:turn_start_params(<<"t2">>, Inputs),
    ?assertEqual(<<"t2">>, maps:get(<<"threadId">>, Params)),
    ?assertEqual(Inputs, maps:get(<<"input">>, Params)).

turn_start_params_with_opts_test() ->
    Params = codex_protocol:turn_start_params(
        <<"t3">>, <<"test">>,
        #{model => <<"o4-mini">>,
          approval_policy => <<"on-request">>,
          sandbox_mode => <<"read-only">>}),
    ?assertEqual(<<"t3">>, maps:get(<<"threadId">>, Params)),
    ?assertEqual(<<"o4-mini">>, maps:get(<<"model">>, Params)),
    ?assertEqual(<<"on-request">>, maps:get(<<"approvalPolicy">>, Params)),
    ?assertEqual(<<"read-only">>, maps:get(<<"sandboxPolicy">>, Params)).

initialize_params_test() ->
    Params = codex_protocol:initialize_params(#{
        model => <<"o4-mini">>,
        approval_policy => <<"never">>
    }),
    ClientInfo = maps:get(<<"clientInfo">>, Params),
    ?assertEqual(<<"beam_agent_sdk">>, maps:get(<<"name">>, ClientInfo)),
    ?assertEqual(<<"0.1.0">>, maps:get(<<"version">>, ClientInfo)),
    ?assertEqual(<<"o4-mini">>, maps:get(<<"model">>, Params)),
    ?assertEqual(<<"never">>, maps:get(<<"askForApproval">>, Params)).

initialize_params_minimal_test() ->
    Params = codex_protocol:initialize_params(#{}),
    ?assert(maps:is_key(<<"clientInfo">>, Params)),
    ?assertNot(maps:is_key(<<"model">>, Params)).

%%====================================================================
%% Approval response builders
%%====================================================================

command_approval_accept_test() ->
    ?assertEqual(#{<<"decision">> => <<"accept">>},
                 codex_protocol:command_approval_response(accept)).

command_approval_accept_for_session_test() ->
    ?assertEqual(#{<<"decision">> => <<"acceptForSession">>},
                 codex_protocol:command_approval_response(accept_for_session)).

command_approval_decline_test() ->
    ?assertEqual(#{<<"decision">> => <<"decline">>},
                 codex_protocol:command_approval_response(decline)).

command_approval_cancel_test() ->
    ?assertEqual(#{<<"decision">> => <<"cancel">>},
                 codex_protocol:command_approval_response(cancel)).

file_approval_accept_test() ->
    ?assertEqual(#{<<"decision">> => <<"accept">>},
                 codex_protocol:file_approval_response(accept)).

file_approval_decline_test() ->
    ?assertEqual(#{<<"decision">> => <<"decline">>},
                 codex_protocol:file_approval_response(decline)).

%%====================================================================
%% Enum round-trip tests
%%====================================================================

approval_decision_roundtrip_test() ->
    Decisions = [accept, accept_for_session, decline, cancel],
    lists:foreach(fun(D) ->
        Encoded = codex_protocol:encode_approval_decision(D),
        ?assertEqual(D, codex_protocol:parse_approval_decision(Encoded))
    end, Decisions).

parse_unknown_approval_defaults_to_decline_test() ->
    ?assertEqual(decline, codex_protocol:parse_approval_decision(<<"garbage">>)).

encode_ask_for_approval_all_variants_test() ->
    ?assertEqual(<<"untrusted">>,  codex_protocol:encode_ask_for_approval(untrusted)),
    ?assertEqual(<<"on-failure">>, codex_protocol:encode_ask_for_approval(on_failure)),
    ?assertEqual(<<"on-request">>, codex_protocol:encode_ask_for_approval(on_request)),
    ?assertEqual(<<"reject">>,     codex_protocol:encode_ask_for_approval(reject)),
    ?assertEqual(<<"never">>,      codex_protocol:encode_ask_for_approval(never)).

encode_sandbox_mode_all_variants_test() ->
    ?assertEqual(<<"read-only">>,         codex_protocol:encode_sandbox_mode(read_only)),
    ?assertEqual(<<"workspace-write">>,   codex_protocol:encode_sandbox_mode(workspace_write)),
    ?assertEqual(<<"danger-full-access">>, codex_protocol:encode_sandbox_mode(danger_full_access)).
