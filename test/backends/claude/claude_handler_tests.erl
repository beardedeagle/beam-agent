%%%-------------------------------------------------------------------
%%% @doc EUnit tests for claude_session_handler pure-function coverage.
%%%
%%% Tests handle_set_model/2, handle_set_permission_mode/2, and
%%% control_cancel_request normalization. No mocks, no processes.
%%% @end
%%%-------------------------------------------------------------------
-module(claude_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% handle_set_model/2
%%====================================================================

set_model_returns_ok_tuple_test() ->
    HState = minimal_hstate(),
    Model = <<"claude-sonnet-4-20250514">>,
    Result = claude_session_handler:handle_set_model(Model, HState),
    ?assertMatch({ok, Model, [{send, _}], _}, Result).

set_model_send_action_contains_encoded_jsonl_test() ->
    HState = minimal_hstate(),
    Model = <<"claude-opus-4-20250514">>,
    {ok, Model, [{send, Encoded}], _} =
        claude_session_handler:handle_set_model(Model, HState),
    %% Encoded is iodata — flatten and decode
    Bin = iolist_to_binary(Encoded),
    %% JSONL line ends with newline; trim before decode
    Trimmed = string:trim(Bin, trailing, "\n"),
    Decoded = json:decode(Trimmed),
    ?assertEqual(<<"control_request">>, maps:get(<<"type">>, Decoded)),
    ?assert(is_binary(maps:get(<<"request_id">>, Decoded))),
    Request = maps:get(<<"request">>, Decoded),
    ?assertEqual(<<"setModel">>, maps:get(<<"subtype">>, Request)),
    ?assertEqual(Model, maps:get(<<"model">>, Request)).

set_model_does_not_modify_hstate_test() ->
    HState = minimal_hstate(),
    {ok, _, _, ReturnedHState} =
        claude_session_handler:handle_set_model(<<"m">>, HState),
    ?assertEqual(HState, ReturnedHState).

%%====================================================================
%% handle_set_permission_mode/2
%%====================================================================

set_permission_mode_returns_ok_tuple_test() ->
    HState = minimal_hstate(),
    Mode = <<"plan">>,
    Result = claude_session_handler:handle_set_permission_mode(Mode, HState),
    ?assertMatch({ok, Mode, [{send, _}], _}, Result).

set_permission_mode_send_action_contains_control_request_test() ->
    HState = minimal_hstate(),
    Mode = <<"bypassPermissions">>,
    {ok, Mode, [{send, Encoded}], _} =
        claude_session_handler:handle_set_permission_mode(Mode, HState),
    Bin = iolist_to_binary(Encoded),
    Trimmed = string:trim(Bin, trailing, "\n"),
    Decoded = json:decode(Trimmed),
    ?assertEqual(<<"control_request">>, maps:get(<<"type">>, Decoded)),
    ?assert(is_binary(maps:get(<<"request_id">>, Decoded))),
    Request = maps:get(<<"request">>, Decoded),
    ?assertEqual(<<"set_permission_mode">>, maps:get(<<"subtype">>, Request)),
    ?assertEqual(Mode, maps:get(<<"permission_mode">>, Request)).

%%====================================================================
%% control_cancel_request normalization (beam_agent_core)
%%====================================================================

normalize_control_cancel_request_test() ->
    Raw = #{<<"type">> => <<"control_cancel_request">>,
            <<"request_id">> => <<"req_cancel_42">>},
    Normalized = beam_agent_core:normalize_message(Raw),
    ?assertEqual(control_cancel_request, maps:get(type, Normalized)),
    ?assertEqual(<<"req_cancel_42">>, maps:get(request_id, Normalized)).

normalize_control_cancel_request_missing_id_test() ->
    Raw = #{<<"type">> => <<"control_cancel_request">>},
    Normalized = beam_agent_core:normalize_message(Raw),
    ?assertEqual(control_cancel_request, maps:get(type, Normalized)),
    %% request_id should not be present when absent from raw
    ?assertEqual(error, maps:find(request_id, Normalized)).

%%====================================================================
%% Helpers
%%====================================================================

%% Build a minimal #hstate{} via init_handler to avoid coupling to
%% the record definition. We extract the handler_state from the init
%% result and use it directly.
%%
%% Alternative: since tests must not spawn processes, we construct the
%% record by calling init_handler with a dummy CLI path. init_handler
%% is a pure function that returns {ok, #{handler_state := HState}}.
%% The transport is never started in these tests.
minimal_hstate() ->
    {ok, #{handler_state := HState}} =
        claude_session_handler:init_handler(#{
            cli_path => "/nonexistent/claude",
            session_id => <<"test-session">>
        }),
    HState.
