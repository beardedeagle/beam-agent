%%%-------------------------------------------------------------------
%%% @doc EUnit tests for codex_session_handler — handle_set_model/2
%%%      and handle_set_permission_mode/2 per-turn override storage.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_session_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% handle_set_model/2 tests
%%====================================================================

set_model_stores_model_in_hstate_test() ->
    HState = minimal_hstate(),
    Model = <<"gpt-4o">>,
    {ok, Model, [], _HState1} =
        codex_session_handler:handle_set_model(Model, HState).

set_model_returns_no_send_actions_test() ->
    HState = minimal_hstate(),
    {ok, _, Actions, _} =
        codex_session_handler:handle_set_model(<<"o3-mini">>, HState),
    ?assertEqual([], Actions).

%%====================================================================
%% handle_set_permission_mode/2 tests
%%====================================================================

set_permission_mode_stores_sandbox_mode_test() ->
    HState = minimal_hstate(),
    Mode = <<"full-auto">>,
    {ok, Mode, [], _HState1} =
        codex_session_handler:handle_set_permission_mode(Mode, HState).

set_permission_mode_returns_no_send_actions_test() ->
    HState = minimal_hstate(),
    {ok, _, Actions, _} =
        codex_session_handler:handle_set_permission_mode(
            <<"suggest">>, HState),
    ?assertEqual([], Actions).

%%====================================================================
%% Helpers
%%====================================================================

%% Build a minimal handler state suitable for pure function testing.
%% Uses init_handler/1 to construct a real #hstate{} record without
%% exposing internal record details.
-spec minimal_hstate() -> term().
minimal_hstate() ->
    {ok, #{handler_state := HState}} =
        codex_session_handler:init_handler(#{
            cli_path => "/nonexistent/codex"
        }),
    HState.
