%%%-------------------------------------------------------------------
%%% @doc Unit tests for copilot_protocol — event normalization and
%%%      wire format builders.
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Event Normalization Tests
%%====================================================================

%% --- Assistant Messages ---

assistant_message_test() ->
    Event = #{<<"type">> => <<"assistant.message">>,
              <<"data">> => #{<<"content">> => <<"Hello there">>,
                              <<"messageId">> => <<"msg-1">>,
                              <<"model">> => <<"gpt-4">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(assistant, maps:get(type, Msg)),
    ?assertEqual(<<"Hello there">>, maps:get(content, Msg)),
    ?assertEqual(<<"msg-1">>, maps:get(message_id, Msg)),
    ?assertEqual(<<"gpt-4">>, maps:get(model, Msg)).

assistant_message_minimal_test() ->
    Event = #{<<"type">> => <<"assistant.message">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(assistant, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

assistant_message_delta_test() ->
    Event = #{<<"type">> => <<"assistant.message_delta">>,
              <<"data">> => #{<<"deltaContent">> => <<"chunk">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"chunk">>, maps:get(content, Msg)).

assistant_message_delta_snake_case_test() ->
    %% Test snake_case variant of delta field
    Event = #{<<"type">> => <<"assistant.message_delta">>,
              <<"data">> => #{<<"delta_content">> => <<"chunk2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"chunk2">>, maps:get(content, Msg)).

%% --- Reasoning ---

assistant_reasoning_test() ->
    Event = #{<<"type">> => <<"assistant.reasoning">>,
              <<"data">> => #{<<"content">> => <<"Let me think...">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"Let me think...">>, maps:get(content, Msg)).

assistant_reasoning_delta_test() ->
    Event = #{<<"type">> => <<"assistant.reasoning_delta">>,
              <<"data">> => #{<<"deltaContent">> => <<"step 1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"step 1">>, maps:get(content, Msg)).

%% --- Tool Events ---

tool_executing_test() ->
    Event = #{<<"type">> => <<"tool.executing">>,
              <<"data">> => #{<<"toolName">> => <<"read_file">>,
                              <<"arguments">> => #{<<"path">> => <<"/tmp/x">>},
                              <<"toolCallId">> => <<"tc-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"path">> => <<"/tmp/x">>}, maps:get(tool_input, Msg)),
    ?assertEqual(<<"tc-1">>, maps:get(tool_use_id, Msg)).

tool_executing_snake_case_test() ->
    Event = #{<<"type">> => <<"tool.executing">>,
              <<"data">> => #{<<"tool_name">> => <<"write">>,
                              <<"toolInput">> => #{},
                              <<"tool_call_id">> => <<"tc-2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"write">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"tc-2">>, maps:get(tool_use_id, Msg)).

tool_completed_test() ->
    Event = #{<<"type">> => <<"tool.completed">>,
              <<"data">> => #{<<"toolName">> => <<"read_file">>,
                              <<"output">> => <<"file contents">>,
                              <<"toolCallId">> => <<"tc-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"file contents">>, maps:get(content, Msg)),
    ?assertEqual(<<"tc-1">>, maps:get(tool_use_id, Msg)).

tool_errored_test() ->
    Event = #{<<"type">> => <<"tool.errored">>,
              <<"data">> => #{<<"toolName">> => <<"shell">>,
                              <<"error">> => <<"permission denied">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"permission denied">>, maps:get(content, Msg)),
    ?assertEqual(tool_error, maps:get(error_type, Msg)),
    ?assertEqual(<<"shell">>, maps:get(tool_name, Msg)).

agent_tool_call_test() ->
    Event = #{<<"type">> => <<"agent.toolCall">>,
              <<"data">> => #{<<"toolName">> => <<"agent_tool">>,
                              <<"arguments">> => #{<<"q">> => <<"test">>}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"agent_tool">>, maps:get(tool_name, Msg)).

%% --- Session Lifecycle ---

session_idle_test() ->
    Event = #{<<"type">> => <<"session.idle">>,
              <<"data">> => #{<<"usage">> => #{<<"total">> => 100}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(#{<<"total">> => 100}, maps:get(usage, Msg)).

session_idle_no_data_test() ->
    Event = #{<<"type">> => <<"session.idle">>},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(result, maps:get(type, Msg)).

session_error_test() ->
    Event = #{<<"type">> => <<"session.error">>,
              <<"data">> => #{<<"message">> => <<"rate limited">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"rate limited">>, maps:get(content, Msg)),
    ?assertEqual(session_error, maps:get(error_type, Msg)).

session_resume_test() ->
    Event = #{<<"type">> => <<"session.resume">>,
              <<"data">> => #{<<"sessionId">> => <<"s-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(resume, maps:get(subtype, Msg)).

%% --- Permission Events ---

permission_request_event_test() ->
    Event = #{<<"type">> => <<"permission.request">>,
              <<"data">> => #{<<"kind">> => <<"shell">>,
                              <<"toolCallId">> => <<"tc-5">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(permission_request, maps:get(subtype, Msg)),
    ?assertEqual(<<"shell">>, maps:get(permission_kind, Msg)).

permission_resolved_event_test() ->
    Event = #{<<"type">> => <<"permission.resolved">>,
              <<"data">> => #{<<"kind">> => <<"approved">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_response, maps:get(type, Msg)),
    ?assertEqual(permission_resolved, maps:get(subtype, Msg)).

%% --- Compaction ---

compaction_started_test() ->
    Event = #{<<"type">> => <<"compaction.started">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(compaction_started, maps:get(subtype, Msg)).

compaction_completed_test() ->
    Event = #{<<"type">> => <<"compaction.completed">>,
              <<"data">> => #{<<"tokensUsed">> => 500}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(compaction_completed, maps:get(subtype, Msg)).

%% --- Plan ---

plan_update_test() ->
    Event = #{<<"type">> => <<"plan.update">>,
              <<"data">> => #{<<"plan">> => <<"step 1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(plan_update, maps:get(subtype, Msg)).

%% --- User Message ---

user_message_test() ->
    Event = #{<<"type">> => <<"user.message">>,
              <<"data">> => #{<<"content">> => <<"hi">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(user, maps:get(type, Msg)),
    ?assertEqual(<<"hi">>, maps:get(content, Msg)).

%% --- Unknown Events ---

unknown_event_type_test() ->
    Event = #{<<"type">> => <<"future.event">>,
              <<"data">> => #{<<"x">> => 1}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(<<"future.event">>, maps:get(subtype, Msg)).

completely_unknown_structure_test() ->
    Event = #{<<"foo">> => <<"bar">>},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(raw, maps:get(type, Msg)).

%%====================================================================
%% Wire Format Builder Tests
%%====================================================================

build_session_create_params_minimal_test() ->
    Params = copilot_protocol:build_session_create_params(#{}),
    ?assertEqual(#{}, Params).

build_session_create_params_full_test() ->
    Opts = #{
        session_id => <<"s-1">>,
        model => <<"gpt-4">>,
        reasoning_effort => <<"high">>,
        work_dir => <<"/tmp">>,
        streaming => true,
        client_name => <<"my-app">>
    },
    Params = copilot_protocol:build_session_create_params(Opts),
    ?assertEqual(<<"s-1">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual(<<"gpt-4">>, maps:get(<<"model">>, Params)),
    ?assertEqual(<<"high">>, maps:get(<<"reasoningEffort">>, Params)),
    ?assertEqual(<<"/tmp">>, maps:get(<<"workingDirectory">>, Params)),
    ?assertEqual(true, maps:get(<<"streaming">>, Params)),
    ?assertEqual(<<"my-app">>, maps:get(<<"clientName">>, Params)).

build_session_send_params_test() ->
    Params = copilot_protocol:build_session_send_params(
        <<"s-1">>, <<"hello">>, #{}),
    ?assertEqual(<<"s-1">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual(<<"hello">>, maps:get(<<"prompt">>, Params)),
    ?assertNot(maps:is_key(<<"attachments">>, Params)).

build_session_send_params_with_attachments_test() ->
    Attachment = #{<<"type">> => <<"file">>, <<"path">> => <<"/x">>},
    Params = copilot_protocol:build_session_send_params(
        <<"s-1">>, <<"look">>, #{attachments => [Attachment]}),
    ?assertEqual([Attachment], maps:get(<<"attachments">>, Params)).

build_session_resume_params_test() ->
    Params = copilot_protocol:build_session_resume_params(
        <<"s-old">>, #{model => <<"gpt-4">>}),
    ?assertEqual(<<"s-old">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual(<<"gpt-4">>, maps:get(<<"model">>, Params)).

%%====================================================================
%% Response Builder Tests
%%====================================================================

build_tool_result_test() ->
    Result = copilot_protocol:build_tool_result(
        #{text_result => <<"output">>, result_type => <<"success">>}, #{}),
    ?assertEqual(<<"output">>, maps:get(<<"textResultForLlm">>, Result)),
    ?assertEqual(<<"success">>, maps:get(<<"resultType">>, Result)).

build_permission_result_allow_test() ->
    Result = copilot_protocol:build_permission_result({allow, #{}}),
    ?assertEqual(#{<<"kind">> => <<"approved">>},
                 maps:get(<<"result">>, Result)).

build_permission_result_deny_test() ->
    Result = copilot_protocol:build_permission_result({deny, <<"no">>}),
    ?assertEqual(#{<<"kind">> => <<"denied-interactively-by-user">>},
                 maps:get(<<"result">>, Result)).

build_permission_result_no_handler_test() ->
    Result = copilot_protocol:build_permission_result(undefined),
    Kind = maps:get(<<"kind">>, maps:get(<<"result">>, Result)),
    ?assertEqual(<<"denied-no-approval-rule-and-could-not-request-from-user">>,
                 Kind).

build_hook_result_nil_test() ->
    ?assertEqual(#{}, copilot_protocol:build_hook_result(undefined)).

build_hook_result_map_test() ->
    R = #{<<"modified">> => true},
    ?assertEqual(R, copilot_protocol:build_hook_result(R)).

build_user_input_result_test() ->
    Result = copilot_protocol:build_user_input_result(
        #{answer => <<"yes">>, was_freeform => false}),
    ?assertEqual(<<"yes">>, maps:get(<<"answer">>, Result)),
    ?assertEqual(false, maps:get(<<"wasFreeform">>, Result)).

%%====================================================================
%% JSON-RPC 2.0 Encoding Tests
%%====================================================================

encode_request_test() ->
    Req = copilot_protocol:encode_request(<<"1">>, <<"ping">>, #{<<"msg">> => <<"hi">>}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Req)),
    ?assertEqual(<<"1">>, maps:get(<<"id">>, Req)),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Req)),
    ?assertEqual(#{<<"msg">> => <<"hi">>}, maps:get(<<"params">>, Req)).

encode_request_no_params_test() ->
    Req = copilot_protocol:encode_request(<<"2">>, <<"status.get">>, undefined),
    ?assertEqual(#{}, maps:get(<<"params">>, Req)).

encode_response_test() ->
    Resp = copilot_protocol:encode_response(<<"1">>, #{<<"ok">> => true}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Resp)),
    ?assertEqual(<<"1">>, maps:get(<<"id">>, Resp)),
    ?assertEqual(#{<<"ok">> => true}, maps:get(<<"result">>, Resp)).

encode_error_response_test() ->
    Resp = copilot_protocol:encode_error_response(<<"1">>, -32601, <<"not found">>),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Resp)),
    ErrObj = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, ErrObj)),
    ?assertEqual(<<"not found">>, maps:get(<<"message">>, ErrObj)).

encode_error_response_with_data_test() ->
    Resp = copilot_protocol:encode_error_response(
        <<"1">>, -32603, <<"internal">>, #{<<"detail">> => <<"x">>}),
    ErrObj = maps:get(<<"error">>, Resp),
    ?assertEqual(#{<<"detail">> => <<"x">>}, maps:get(<<"data">>, ErrObj)).

%%====================================================================
%% CLI Building Tests
%%====================================================================

build_cli_args_default_test() ->
    Args = copilot_protocol:build_cli_args(#{}),
    ?assert(lists:member("server", Args)),
    ?assert(lists:member("--stdio", Args)),
    ?assert(lists:member("--sdk-protocol-version", Args)).

build_cli_args_with_log_level_test() ->
    Args = copilot_protocol:build_cli_args(#{log_level => <<"debug">>}),
    ?assert(lists:member("--log-level", Args)),
    ?assert(lists:member("debug", Args)).

build_env_default_test() ->
    Env = copilot_protocol:build_env(#{}),
    ?assert(lists:keymember("NO_COLOR", 1, Env)),
    ?assert(lists:keymember("COPILOT_SDK_VERSION", 1, Env)).

build_env_with_token_test() ->
    Env = copilot_protocol:build_env(#{github_token => <<"gh_abc123">>}),
    ?assert(lists:keymember("GITHUB_TOKEN", 1, Env)),
    {"GITHUB_TOKEN", Token} = lists:keyfind("GITHUB_TOKEN", 1, Env),
    ?assertEqual("gh_abc123", Token).

sdk_protocol_version_test() ->
    V = copilot_protocol:sdk_protocol_version(),
    ?assert(is_integer(V)),
    ?assert(V > 0).
