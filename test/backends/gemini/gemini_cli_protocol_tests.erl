%%%-------------------------------------------------------------------
%%% @doc EUnit tests for gemini_cli_protocol normalization.
%%%
%%% Tests cover every event type mapping from the Gemini CLI wire
%%% protocol to beam_agent_core:message(). Pure function calls — no
%%% processes, no setup/teardown needed.
%%% @end
%%%-------------------------------------------------------------------
-module(gemini_cli_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% normalize_event/1 — init
%%====================================================================

normalize_init_test() ->
    Raw = #{<<"type">> => <<"init">>,
            <<"session_id">> => <<"sess-001">>,
            <<"model">> => <<"gemini-2.0-flash">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"init">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"sess-001">>, maps:get(session_id, Msg)),
    ?assertEqual(<<"gemini-2.0-flash">>, maps:get(model, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

normalize_init_missing_fields_test() ->
    %% Defensive: missing session_id and model fall back to <<>>
    Raw = #{<<"type">> => <<"init">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"init">>, maps:get(subtype, Msg)),
    ?assertEqual(<<>>, maps:get(session_id, Msg)),
    ?assertEqual(<<>>, maps:get(model, Msg)).

%%====================================================================
%% normalize_event/1 — message/user
%%====================================================================

normalize_user_message_test() ->
    Raw = #{<<"type">> => <<"message">>,
            <<"role">> => <<"user">>,
            <<"content">> => <<"hello world">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(user, maps:get(type, Msg)),
    ?assertEqual(<<"hello world">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_event/1 — message/assistant (delta)
%%====================================================================

normalize_assistant_delta_test() ->
    Raw = #{<<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => <<"Hello">>,
            <<"delta">> => true},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"Hello">>, maps:get(content, Msg)),
    ?assertEqual(true, maps:get(delta, Msg)).

normalize_assistant_full_test() ->
    Raw = #{<<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => <<"Full response">>,
            <<"delta">> => false},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"Full response">>, maps:get(content, Msg)),
    ?assertEqual(false, maps:get(delta, Msg)).

normalize_assistant_no_delta_field_test() ->
    %% delta absent defaults to false
    Raw = #{<<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => <<"Some text">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(false, maps:get(delta, Msg)).

%%====================================================================
%% normalize_event/1 — tool_use
%%====================================================================

normalize_tool_use_test() ->
    Raw = #{<<"type">> => <<"tool_use">>,
            <<"tool_name">> => <<"Read">>,
            <<"parameters">> => #{<<"path">> => <<"/tmp/test">>},
            <<"tool_id">> => <<"tool-001">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"Read">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"path">> => <<"/tmp/test">>}, maps:get(tool_input, Msg)),
    ?assertEqual(<<"tool-001">>, maps:get(tool_use_id, Msg)).

normalize_tool_use_missing_fields_test() ->
    %% Defensive: missing fields fall back to defaults
    Raw = #{<<"type">> => <<"tool_use">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(tool_name, Msg)),
    ?assertEqual(#{}, maps:get(tool_input, Msg)),
    ?assertEqual(<<>>, maps:get(tool_use_id, Msg)).

%%====================================================================
%% normalize_event/1 — tool_result/success
%%====================================================================

normalize_tool_result_success_test() ->
    Raw = #{<<"type">> => <<"tool_result">>,
            <<"status">> => <<"success">>,
            <<"output">> => <<"file contents">>,
            <<"tool_id">> => <<"tool-001">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"file contents">>, maps:get(content, Msg)),
    ?assertEqual(<<"tool-001">>, maps:get(tool_use_id, Msg)).

%%====================================================================
%% normalize_event/1 — tool_result/error
%%====================================================================

normalize_tool_result_error_test() ->
    Raw = #{<<"type">> => <<"tool_result">>,
            <<"status">> => <<"error">>,
            <<"output">> => <<"permission denied">>,
            <<"tool_id">> => <<"tool-002">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"permission denied">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_event/1 — error/warning
%%====================================================================

normalize_error_warning_test() ->
    Raw = #{<<"type">> => <<"error">>,
            <<"severity">> => <<"warning">>,
            <<"message">> => <<"rate limit approaching">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"warning">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"rate limit approaching">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_event/1 — error/error
%%====================================================================

normalize_error_error_test() ->
    Raw = #{<<"type">> => <<"error">>,
            <<"severity">> => <<"error">>,
            <<"message">> => <<"something went wrong">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"something went wrong">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_event/1 — result/success
%%====================================================================

normalize_result_success_test() ->
    Stats = #{<<"tokens_in">> => 10, <<"tokens_out">> => 20,
              <<"duration_ms">> => 500, <<"tool_calls">> => 1},
    Raw = #{<<"type">> => <<"result">>,
            <<"status">> => <<"success">>,
            <<"stats">> => Stats},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(result, maps:get(type, Msg)),
    ParsedStats = maps:get(stats, Msg),
    ?assertEqual(10, maps:get(tokens_in, ParsedStats)),
    ?assertEqual(20, maps:get(tokens_out, ParsedStats)),
    ?assertEqual(500, maps:get(duration_ms, ParsedStats)),
    ?assertEqual(1, maps:get(tool_calls, ParsedStats)).

%%====================================================================
%% normalize_event/1 — result/error
%%====================================================================

normalize_result_error_test() ->
    Raw = #{<<"type">> => <<"result">>,
            <<"status">> => <<"error">>,
            <<"message">> => <<"model error">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"model error">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_event/1 — unknown type (raw)
%%====================================================================

normalize_unknown_type_test() ->
    Raw = #{<<"type">> => <<"some_future_event">>,
            <<"data">> => <<"whatever">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_missing_type_test() ->
    Raw = #{<<"data">> => <<"no type field">>},
    Msg = gemini_cli_protocol:normalize_event(Raw),
    ?assertEqual(raw, maps:get(type, Msg)).

%%====================================================================
%% parse_stats/1
%%====================================================================

parse_stats_full_test() ->
    Stats = #{<<"tokens_in">> => 5, <<"tokens_out">> => 15,
              <<"duration_ms">> => 200, <<"tool_calls">> => 3},
    Parsed = gemini_cli_protocol:parse_stats(Stats),
    ?assertEqual(5, maps:get(tokens_in, Parsed)),
    ?assertEqual(15, maps:get(tokens_out, Parsed)),
    ?assertEqual(200, maps:get(duration_ms, Parsed)),
    ?assertEqual(3, maps:get(tool_calls, Parsed)).

parse_stats_empty_test() ->
    Parsed = gemini_cli_protocol:parse_stats(#{}),
    ?assertEqual(0, maps:get(tokens_in, Parsed)),
    ?assertEqual(0, maps:get(tokens_out, Parsed)),
    ?assertEqual(0, maps:get(duration_ms, Parsed)),
    ?assertEqual(0, maps:get(tool_calls, Parsed)).

parse_stats_non_map_test() ->
    Parsed = gemini_cli_protocol:parse_stats(undefined),
    ?assertEqual(0, maps:get(tokens_in, Parsed)).

%%====================================================================
%% exit_code_to_error/1
%%====================================================================

exit_code_to_error_test() ->
    ?assertEqual(<<"success">>, gemini_cli_protocol:exit_code_to_error(0)),
    ?assertEqual(<<"auth_error">>, gemini_cli_protocol:exit_code_to_error(41)),
    ?assertEqual(<<"input_error">>, gemini_cli_protocol:exit_code_to_error(42)),
    ?assertEqual(<<"config_error">>, gemini_cli_protocol:exit_code_to_error(52)),
    ?assertEqual(<<"cancelled">>, gemini_cli_protocol:exit_code_to_error(130)),
    UnknownErr = gemini_cli_protocol:exit_code_to_error(99),
    ?assert(binary:match(UnknownErr, <<"unknown_error">>) =/= nomatch).

protocol_version_test() ->
    ?assertEqual(1, gemini_cli_protocol:protocol_version()).

initialize_params_test() ->
    Params = gemini_cli_protocol:initialize_params(#{}),
    ?assertEqual(1, maps:get(<<"protocolVersion">>, Params)),
    ClientCaps = maps:get(<<"clientCapabilities">>, Params),
    Fs = maps:get(<<"fs">>, ClientCaps),
    ?assertEqual(false, maps:get(<<"readTextFile">>, Fs)),
    ?assertEqual(false, maps:get(<<"writeTextFile">>, Fs)).

authenticate_params_with_api_key_test() ->
    Params =
        gemini_cli_protocol:authenticate_params(
            #{api_key => <<"secret">>},
            [#{<<"id">> => <<"gemini-api-key">>}]),
    ?assertEqual(<<"gemini-api-key">>, maps:get(<<"methodId">>, Params)),
    Meta = maps:get(<<"_meta">>, Params),
    ?assertEqual(<<"secret">>, maps:get(<<"api-key">>, Meta)).

start_session_method_and_params_test() ->
    ?assertEqual(<<"session/new">>,
                 gemini_cli_protocol:start_session_method(#{})),
    ?assertEqual(<<"session/load">>,
                 gemini_cli_protocol:start_session_method(
                     #{session_id => <<"sess-123">>})),
    LoadParams =
        gemini_cli_protocol:start_session_params(
            #{session_id => <<"sess-123">>,
              work_dir => <<"/tmp/project">>}),
    ?assertEqual(<<"sess-123">>, maps:get(<<"sessionId">>, LoadParams)),
    ?assertEqual(<<"/tmp/project">>, maps:get(<<"cwd">>, LoadParams)).

prompt_request_test() ->
    Params = gemini_cli_protocol:prompt_request(<<"sess-1">>, <<"hello">>),
    ?assertEqual(<<"sess-1">>, maps:get(<<"sessionId">>, Params)),
    [Block] = maps:get(<<"prompt">>, Params),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Block)).

approval_response_test() ->
    Options = [
        #{<<"optionId">> => <<"allow-once">>, <<"kind">> => <<"allow_once">>},
        #{<<"optionId">> => <<"reject-once">>, <<"kind">> => <<"reject_once">>}
    ],
    Allow = gemini_cli_protocol:approval_response(Options, accept),
    ?assertEqual(<<"selected">>,
                 maps:get(<<"outcome">>, maps:get(<<"outcome">>, Allow))),
    ?assertEqual(<<"allow-once">>,
                 maps:get(<<"optionId">>, maps:get(<<"outcome">>, Allow))),
    Cancel = gemini_cli_protocol:approval_response(Options, cancel),
    ?assertEqual(<<"cancelled">>,
                 maps:get(<<"outcome">>, maps:get(<<"outcome">>, Cancel))).
