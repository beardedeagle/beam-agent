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

tool_execution_complete_error_test() ->
    %% In v3, tool errors are reported via tool.execution_complete with isError=true.
    %% The old tool.errored event type falls through to the raw catch-all.
    Event = #{<<"type">> => <<"tool.execution_complete">>,
              <<"data">> => #{<<"toolName">> => <<"shell">>,
                              <<"output">> => <<"permission denied">>,
                              <<"isError">> => true}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"permission denied">>, maps:get(content, Msg)),
    ?assertEqual(tool_error, maps:get(error_type, Msg)),
    ?assertEqual(<<"shell">>, maps:get(tool_name, Msg)).

tool_errored_legacy_falls_to_raw_test() ->
    %% The old tool.errored event no longer has a dedicated handler
    Event = #{<<"type">> => <<"tool.errored">>,
              <<"data">> => #{<<"toolName">> => <<"shell">>,
                              <<"error">> => <<"denied">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(raw, maps:get(type, Msg)).

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
    ?assertEqual(permission_completed, maps:get(subtype, Msg)).

%% --- Compaction ---

compaction_started_test() ->
    Event = #{<<"type">> => <<"compaction.started">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(compaction_start, maps:get(subtype, Msg)).

compaction_completed_test() ->
    Event = #{<<"type">> => <<"compaction.completed">>,
              <<"data">> => #{<<"tokensUsed">> => 500}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(compaction_complete, maps:get(subtype, Msg)).

%% --- Plan ---

plan_update_test() ->
    Event = #{<<"type">> => <<"plan.update">>,
              <<"data">> => #{<<"plan">> => <<"step 1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(plan_changed, maps:get(subtype, Msg)).

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
    %% COP-1: envValueMode is always included
    ?assertEqual(#{<<"envValueMode">> => <<"direct">>}, Params).

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
    ?assert(lists:member("--acp", Args)),
    ?assertNot(lists:member("server", Args)),
    ?assertNot(lists:member("--stdio", Args)),
    ?assertNot(lists:member("--sdk-protocol-version", Args)).

build_cli_args_with_log_level_test() ->
    Args = copilot_protocol:build_cli_args(#{log_level => <<"debug">>}),
    ?assert(lists:member("--log-level", Args)),
    ?assert(lists:member("debug", Args)).

build_cli_args_appends_user_args_after_required_transport_args_test() ->
    Args = copilot_protocol:build_cli_args(#{cli_args => ["--foo", "bar"]}),
    ?assertEqual(["--acp", "--foo", "bar"], Args).

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

%%====================================================================
%% V3 Broadcast Event Normalization Tests
%%====================================================================

external_tool_requested_test() ->
    Event = #{<<"type">> => <<"external_tool.requested">>,
              <<"data">> => #{<<"toolName">> => <<"bash">>,
                              <<"input">> => #{<<"cmd">> => <<"ls">>},
                              <<"requestId">> => <<"req-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"cmd">> => <<"ls">>}, maps:get(tool_input, Msg)),
    ?assertEqual(<<"req-1">>, maps:get(request_id, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

external_tool_requested_snake_case_test() ->
    Event = #{<<"type">> => <<"external_tool.requested">>,
              <<"data">> => #{<<"tool_name">> => <<"read">>,
                              <<"request_id">> => <<"req-2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"read">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"req-2">>, maps:get(request_id, Msg)).

external_tool_requested_minimal_test() ->
    Event = #{<<"type">> => <<"external_tool.requested">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(tool_name, Msg)),
    ?assertEqual(#{}, maps:get(tool_input, Msg)),
    ?assertEqual(undefined, maps:get(request_id, Msg)).

external_tool_completed_test() ->
    Event = #{<<"type">> => <<"external_tool.completed">>,
              <<"data">> => #{<<"toolName">> => <<"bash">>,
                              <<"output">> => <<"done">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"done">>, maps:get(content, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

external_tool_completed_minimal_test() ->
    Event = #{<<"type">> => <<"external_tool.completed">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(tool_name, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

permission_requested_v3_test() ->
    Event = #{<<"type">> => <<"permission.requested">>,
              <<"data">> => #{<<"requestId">> => <<"perm-1">>,
                              <<"request">> => #{<<"kind">> => <<"shell">>}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(<<"permission">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"perm-1">>, maps:get(request_id, Msg)),
    ?assertEqual(#{<<"kind">> => <<"shell">>}, maps:get(request, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

permission_requested_v3_snake_case_test() ->
    Event = #{<<"type">> => <<"permission.requested">>,
              <<"data">> => #{<<"request_id">> => <<"perm-2">>,
                              <<"request">> => #{}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(<<"perm-2">>, maps:get(request_id, Msg)).

permission_completed_v3_test() ->
    Event = #{<<"type">> => <<"permission.completed">>,
              <<"data">> => #{<<"result">> => <<"approved">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"permission_completed">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"approved">>, maps:get(content, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

permission_completed_v3_no_result_test() ->
    Event = #{<<"type">> => <<"permission.completed">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

%%====================================================================
%% Permission Result Kind Tests
%%====================================================================

build_permission_result_deny_by_rules_test() ->
    Result = copilot_protocol:build_permission_result({deny, <<"rule X">>, by_rules}),
    ?assertEqual(#{<<"kind">> => <<"denied-by-rules">>},
                 maps:get(<<"result">>, Result)).

build_permission_result_deny_by_content_exclusion_test() ->
    Result = copilot_protocol:build_permission_result(
                 {deny, <<"excluded">>, by_content_exclusion}),
    ?assertEqual(#{<<"kind">> => <<"denied-by-content-exclusion-policy">>},
                 maps:get(<<"result">>, Result)).

%%====================================================================
%% systemMessage.transform Response Format Tests
%%====================================================================

system_message_transform_response_format_test() ->
    Sections = [#{<<"type">> => <<"instructions">>,
                  <<"content">> => <<"Be helpful">>}],
    Resp = copilot_protocol:encode_response(<<"42">>,
               #{<<"sections">> => Sections}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Resp)),
    ?assertEqual(<<"42">>, maps:get(<<"id">>, Resp)),
    ResultMap = maps:get(<<"result">>, Resp),
    ?assertEqual(Sections, maps:get(<<"sections">>, ResultMap)).

system_message_transform_empty_sections_test() ->
    Resp = copilot_protocol:encode_response(<<"7">>,
               #{<<"sections">> => []}),
    ResultMap = maps:get(<<"result">>, Resp),
    ?assertEqual([], maps:get(<<"sections">>, ResultMap)).

%%====================================================================
%% COP-9: New normalize_event clause tests
%%====================================================================

%% --- Session Lifecycle ---

session_start_test() ->
    Event = #{<<"type">> => <<"session.start">>,
              <<"data">> => #{<<"sessionId">> => <<"s-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(session_start, maps:get(subtype, Msg)),
    ?assertEqual(#{<<"sessionId">> => <<"s-1">>}, maps:get(content, Msg)).

session_title_changed_test() ->
    Event = #{<<"type">> => <<"session.title_changed">>,
              <<"data">> => #{<<"title">> => <<"My Session">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(title_changed, maps:get(subtype, Msg)),
    ?assertEqual(<<"My Session">>, maps:get(content, Msg)).

session_title_changed_no_title_test() ->
    Event = #{<<"type">> => <<"session.title_changed">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

session_model_change_test() ->
    Event = #{<<"type">> => <<"session.model_change">>,
              <<"data">> => #{<<"model">> => <<"gpt-4o">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(model_changed, maps:get(subtype, Msg)),
    ?assertEqual(<<"gpt-4o">>, maps:get(model, Msg)).

session_model_change_model_id_fallback_test() ->
    Event = #{<<"type">> => <<"session.model_change">>,
              <<"data">> => #{<<"modelId">> => <<"gpt-4o-mini">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"gpt-4o-mini">>, maps:get(model, Msg)).

session_model_change_no_model_test() ->
    Event = #{<<"type">> => <<"session.model_change">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(<<>>, maps:get(model, Msg)).

session_mode_changed_test() ->
    Event = #{<<"type">> => <<"session.mode_changed">>,
              <<"data">> => #{<<"mode">> => <<"agent">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(mode_changed, maps:get(subtype, Msg)).

session_shutdown_test() ->
    Event = #{<<"type">> => <<"session.shutdown">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(shutdown, maps:get(subtype, Msg)).

session_usage_info_test() ->
    Event = #{<<"type">> => <<"session.usage_info">>,
              <<"data">> => #{<<"tokens">> => 500}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(usage_info, maps:get(subtype, Msg)).

session_tools_updated_test() ->
    Event = #{<<"type">> => <<"session.tools_updated">>,
              <<"data">> => #{<<"tools">> => []}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(tools_updated, maps:get(subtype, Msg)).

session_skills_loaded_test() ->
    Event = #{<<"type">> => <<"session.skills_loaded">>,
              <<"data">> => #{<<"skills">> => []}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(skills_loaded, maps:get(subtype, Msg)).

session_mcp_servers_loaded_test() ->
    Event = #{<<"type">> => <<"session.mcp_servers_loaded">>,
              <<"data">> => #{<<"servers">> => []}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(mcp_servers_loaded, maps:get(subtype, Msg)).

%% --- Turn Lifecycle ---

assistant_turn_start_test() ->
    Event = #{<<"type">> => <<"assistant.turn_start">>,
              <<"data">> => #{<<"turnId">> => <<"t-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(turn_start, maps:get(subtype, Msg)).

assistant_turn_end_test() ->
    Event = #{<<"type">> => <<"assistant.turn_end">>,
              <<"data">> => #{<<"turnId">> => <<"t-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(turn_end, maps:get(subtype, Msg)).

assistant_turn_end_with_usage_test() ->
    Event = #{<<"type">> => <<"assistant.turn_end">>,
              <<"data">> => #{<<"usage">> => #{<<"total">> => 200}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(turn_end, maps:get(subtype, Msg)),
    ?assertEqual(#{<<"total">> => 200}, maps:get(usage, Msg)).

assistant_usage_test() ->
    Event = #{<<"type">> => <<"assistant.usage">>,
              <<"data">> => #{<<"usage">> => #{<<"input">> => 100,
                                               <<"output">> => 50}}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(usage, maps:get(subtype, Msg)).

assistant_intent_test() ->
    Event = #{<<"type">> => <<"assistant.intent">>,
              <<"data">> => #{<<"intent">> => <<"code_edit">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(intent, maps:get(subtype, Msg)),
    ?assertEqual(<<"code_edit">>, maps:get(content, Msg)).

assistant_intent_no_intent_test() ->
    Event = #{<<"type">> => <<"assistant.intent">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(<<>>, maps:get(content, Msg)).

assistant_streaming_delta_test() ->
    Event = #{<<"type">> => <<"assistant.streaming_delta">>,
              <<"data">> => #{<<"delta">> => <<"chunk">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(text_delta, maps:get(type, Msg)),
    ?assertEqual(<<"chunk">>, maps:get(content, Msg)).

assistant_streaming_delta_content_fallback_test() ->
    Event = #{<<"type">> => <<"assistant.streaming_delta">>,
              <<"data">> => #{<<"content">> => <<"fallback_chunk">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(text_delta, maps:get(type, Msg)),
    ?assertEqual(<<"fallback_chunk">>, maps:get(content, Msg)).

assistant_streaming_delta_empty_test() ->
    Event = #{<<"type">> => <<"assistant.streaming_delta">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(text_delta, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

%% --- Subagent Events ---

subagent_started_test() ->
    Event = #{<<"type">> => <<"subagent.started">>,
              <<"data">> => #{<<"agentId">> => <<"a-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"subagent_started">>, maps:get(subtype, Msg)).

subagent_completed_test() ->
    Event = #{<<"type">> => <<"subagent.completed">>,
              <<"data">> => #{<<"agentId">> => <<"a-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"subagent_completed">>, maps:get(subtype, Msg)).

subagent_failed_test() ->
    Event = #{<<"type">> => <<"subagent.failed">>,
              <<"data">> => #{<<"error">> => <<"timeout">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"timeout">>, maps:get(content, Msg)),
    ?assertEqual(subagent_failed, maps:get(error_type, Msg)).

subagent_failed_no_error_test() ->
    Event = #{<<"type">> => <<"subagent.failed">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)).

subagent_selected_test() ->
    Event = #{<<"type">> => <<"subagent.selected">>,
              <<"data">> => #{<<"agentId">> => <<"a-2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(subagent_selected, maps:get(subtype, Msg)).

subagent_deselected_test() ->
    Event = #{<<"type">> => <<"subagent.deselected">>,
              <<"data">> => #{<<"agentId">> => <<"a-2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(subagent_deselected, maps:get(subtype, Msg)).

%% --- Hook Events ---

hook_start_test() ->
    Event = #{<<"type">> => <<"hook.start">>,
              <<"data">> => #{<<"hookId">> => <<"h-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(hook_start, maps:get(subtype, Msg)).

hook_end_test() ->
    Event = #{<<"type">> => <<"hook.end">>,
              <<"data">> => #{<<"hookId">> => <<"h-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(hook_end, maps:get(subtype, Msg)).

%% --- Skill Events ---

skill_invoked_test() ->
    Event = #{<<"type">> => <<"skill.invoked">>,
              <<"data">> => #{<<"skillId">> => <<"sk-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(skill_invoked, maps:get(subtype, Msg)).

%% --- Elicitation Events ---

elicitation_requested_test() ->
    Event = #{<<"type">> => <<"elicitation.requested">>,
              <<"data">> => #{<<"requestId">> => <<"req-1">>,
                              <<"question">> => <<"Which option?">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(<<"elicitation">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"req-1">>, maps:get(request_id, Msg)),
    ?assertEqual(#{<<"requestId">> => <<"req-1">>,
                   <<"question">> => <<"Which option?">>},
                 maps:get(request, Msg)).

elicitation_requested_snake_case_test() ->
    Event = #{<<"type">> => <<"elicitation.requested">>,
              <<"data">> => #{<<"request_id">> => <<"req-2">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(<<"req-2">>, maps:get(request_id, Msg)).

elicitation_requested_no_id_test() ->
    Event = #{<<"type">> => <<"elicitation.requested">>,
              <<"data">> => #{}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(undefined, maps:get(request_id, Msg)).

elicitation_completed_test() ->
    Event = #{<<"type">> => <<"elicitation.completed">>,
              <<"data">> => #{<<"answer">> => <<"yes">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(control_response, maps:get(type, Msg)),
    ?assertEqual(elicitation_completed, maps:get(subtype, Msg)).

%% --- Command Events ---

command_queued_test() ->
    Event = #{<<"type">> => <<"command.queued">>,
              <<"data">> => #{<<"commandId">> => <<"cmd-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(command_queued, maps:get(subtype, Msg)).

command_execute_test() ->
    Event = #{<<"type">> => <<"command.execute">>,
              <<"data">> => #{<<"commandId">> => <<"cmd-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(command_execute, maps:get(subtype, Msg)).

command_completed_test() ->
    Event = #{<<"type">> => <<"command.completed">>,
              <<"data">> => #{<<"commandId">> => <<"cmd-1">>}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(command_completed, maps:get(subtype, Msg)).

commands_changed_test() ->
    Event = #{<<"type">> => <<"commands.changed">>,
              <<"data">> => #{<<"commands">> => []}},
    Msg = copilot_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(commands_changed, maps:get(subtype, Msg)).
