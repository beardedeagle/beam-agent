%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_account_core (account/auth lifecycle).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - auth_status: default unknown state for unresolvable sessions
%%%   - account_login: sets login_pending when backend unresolvable
%%%   - account_login_cancel: sets login_cancelled
%%%   - account_logout: sets logged_out with CLI source
%%%   - rate_limits: always empty universal
%%%   - account_info: combined auth + rate_limits
%%%   - Login flow: login -> verify -> logout -> verify
%%%   - clear_session: removes per-session auth state
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_account_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = beam_agent_account_core:ensure_tables(),
    ok = beam_agent_account_core:ensure_tables(),
    ok = beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear().

clear_removes_data_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_clear">>,
    %% Login stores state (login_pending — no backend resolvable in test)
    {ok, _} = beam_agent_account_core:account_login(S, #{}),
    {ok, Auth1} = beam_agent_account_core:auth_status(S),
    ?assertEqual(login_pending, maps:get(status, Auth1)),
    ok = beam_agent_account_core:clear(),
    %% After clear, falls back to unknown/unavailable default
    {ok, Auth2} = beam_agent_account_core:auth_status(S),
    ?assertEqual(unknown, maps:get(status, Auth2)),
    ?assertEqual(unavailable, maps:get(source, Auth2)).

%%====================================================================
%% auth_status tests
%%====================================================================

auth_status_default_unknown_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    {ok, State} = beam_agent_account_core:auth_status(<<"acct_unknown">>),
    ?assertEqual(unknown, maps:get(status, State)),
    ?assertEqual(unavailable, maps:get(source, State)),
    ?assertEqual(<<"acct_unknown">>, maps:get(session, State)).

%%====================================================================
%% account_login tests
%%====================================================================

account_login_basic_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    %% No backend resolvable in test — returns login_pending
    {ok, Result} = beam_agent_account_core:account_login(<<"acct_login">>, #{}),
    ?assertEqual(login_pending, maps:get(status, Result)),
    %% No provider_id when none given
    ?assertEqual(error, maps:find(provider_id, Result)).

account_login_with_provider_id_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    Params = #{provider_id => <<"github_123">>},
    {ok, Result} = beam_agent_account_core:account_login(<<"acct_login_pid">>, Params),
    ?assertEqual(login_pending, maps:get(status, Result)),
    ?assertEqual(<<"github_123">>, maps:get(provider_id, Result)).

account_login_stores_state_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_login_state">>,
    Params = #{provider_id => <<"prov_1">>},
    {ok, _} = beam_agent_account_core:account_login(S, Params),
    {ok, Auth} = beam_agent_account_core:auth_status(S),
    ?assertEqual(login_pending, maps:get(status, Auth)),
    ?assertEqual(<<"prov_1">>, maps:get(provider_id, Auth)),
    ?assertEqual(Params, maps:get(login_params, Auth)).

%%====================================================================
%% account_login_cancel tests
%%====================================================================

account_login_cancel_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_cancel">>,
    {ok, Result} = beam_agent_account_core:account_login_cancel(S, #{}),
    ?assertEqual(login_cancelled, maps:get(status, Result)).

account_login_cancel_after_login_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_cancel2">>,
    {ok, _} = beam_agent_account_core:account_login(S, #{provider_id => <<"p1">>}),
    {ok, _} = beam_agent_account_core:account_login_cancel(S, #{}),
    {ok, Auth} = beam_agent_account_core:auth_status(S),
    ?assertEqual(login_cancelled, maps:get(status, Auth)),
    %% provider_id from previous login is preserved
    ?assertEqual(<<"p1">>, maps:get(provider_id, Auth)).

%%====================================================================
%% account_logout tests
%%====================================================================

account_logout_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_logout">>,
    {ok, _} = beam_agent_account_core:account_login(S, #{}),
    {ok, Result} = beam_agent_account_core:account_logout(S),
    ?assertEqual(logged_out, maps:get(status, Result)).

account_logout_stores_state_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_logout_state">>,
    {ok, _} = beam_agent_account_core:account_login(S, #{}),
    {ok, _} = beam_agent_account_core:account_logout(S),
    {ok, Auth} = beam_agent_account_core:auth_status(S),
    ?assertEqual(logged_out, maps:get(status, Auth)),
    ?assertEqual(cli, maps:get(source, Auth)),
    ?assert(is_integer(maps:get(logged_out_at, Auth))),
    %% logged_in_at should be removed
    ?assertEqual(error, maps:find(logged_in_at, Auth)).

%%====================================================================
%% rate_limits tests
%%====================================================================

rate_limits_always_empty_universal_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    {ok, RL} = beam_agent_account_core:rate_limits(<<"acct_rl">>),
    ?assertEqual([], maps:get(limits, RL)),
    ?assertEqual(universal, maps:get(source, RL)).

%%====================================================================
%% account_info tests
%%====================================================================

account_info_combines_auth_and_rate_limits_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_info">>,
    {ok, _} = beam_agent_account_core:account_login(S, #{provider_id => <<"pi">>}),
    {ok, Info} = beam_agent_account_core:account_info(S),
    %% Auth portion — login_pending since no backend resolvable
    Auth = maps:get(auth, Info),
    ?assertEqual(login_pending, maps:get(status, Auth)),
    ?assertEqual(<<"pi">>, maps:get(provider_id, Auth)),
    %% Rate limits portion
    RL = maps:get(rate_limits, Info),
    ?assertEqual([], maps:get(limits, RL)),
    ?assertEqual(universal, maps:get(source, RL)).

account_info_default_session_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    {ok, Info} = beam_agent_account_core:account_info(<<"acct_info_default">>),
    Auth = maps:get(auth, Info),
    ?assertEqual(unknown, maps:get(status, Auth)),
    ?assertEqual(unavailable, maps:get(source, Auth)).

%%====================================================================
%% Login flow integration tests
%%====================================================================

login_then_logout_flow_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_flow">>,
    %% Before login: unknown (no backend resolvable)
    {ok, Auth0} = beam_agent_account_core:auth_status(S),
    ?assertEqual(unknown, maps:get(status, Auth0)),
    ?assertEqual(unavailable, maps:get(source, Auth0)),
    %% Login — pending since no backend
    {ok, _} = beam_agent_account_core:account_login(S, #{provider_id => <<"gh">>}),
    {ok, Auth1} = beam_agent_account_core:auth_status(S),
    ?assertEqual(login_pending, maps:get(status, Auth1)),
    %% Logout
    {ok, _} = beam_agent_account_core:account_logout(S),
    {ok, Auth2} = beam_agent_account_core:auth_status(S),
    ?assertEqual(logged_out, maps:get(status, Auth2)).

%%====================================================================
%% clear_session/1
%%====================================================================

clear_session_removes_entry_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    S = <<"acct_clear_session">>,
    {ok, _} = beam_agent_account_core:account_login(S, #{provider_id => <<"gh">>}),
    {ok, Auth1} = beam_agent_account_core:auth_status(S),
    ?assertEqual(login_pending, maps:get(status, Auth1)),
    ok = beam_agent_account_core:clear_session(S),
    %% After clear_session the entry is gone; auth_status returns unknown default
    {ok, Auth2} = beam_agent_account_core:auth_status(S),
    ?assertEqual(unavailable, maps:get(source, Auth2)),
    beam_agent_account_core:clear().

clear_session_nonexistent_is_ok_test() ->
    beam_agent_account_core:ensure_tables(),
    ?assertEqual(ok, beam_agent_account_core:clear_session(<<"no-such-session">>)),
    beam_agent_account_core:clear().

clear_session_pid_removes_entry_test() ->
    beam_agent_account_core:ensure_tables(),
    beam_agent_account_core:clear(),
    Pid = self(),
    {ok, _} = beam_agent_account_core:account_login(Pid, #{}),
    {ok, Auth1} = beam_agent_account_core:auth_status(Pid),
    ?assertEqual(login_pending, maps:get(status, Auth1)),
    ok = beam_agent_account_core:clear_session(Pid),
    {ok, Auth2} = beam_agent_account_core:auth_status(Pid),
    ?assertEqual(unavailable, maps:get(source, Auth2)),
    beam_agent_account_core:clear().
