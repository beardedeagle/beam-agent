%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_app_core (app registry over ETS).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables idempotent, clear removes data)
%%%   - register_app: creates entry with required keys, merges opts
%%%   - apps_list: empty when none, returns registered, status filter
%%%   - app_info: {error, no_app} when empty, returns entry after register
%%%   - app_init: creates default app, idempotent on existing
%%%   - app_log: appends entry, {error, no_app} when no app
%%%   - app_modes: default modes, custom modes after register
%%%   - unregister_app: removes app, idempotent on missing
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_app_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    ok = beam_agent_app_core:ensure_tables(),
    ok = beam_agent_app_core:ensure_tables(),
    ok = beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear().

clear_removes_all_data_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-clear">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"app1">>, #{}),
    {ok, [_]} = beam_agent_app_core:apps_list(Sess),
    ok = beam_agent_app_core:clear(),
    {ok, []} = beam_agent_app_core:apps_list(Sess),
    beam_agent_app_core:clear().

%%====================================================================
%% register_app tests
%%====================================================================

register_app_creates_entry_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-reg-1">>,
    {ok, Entry} = beam_agent_app_core:register_app(Sess, <<"myapp">>, #{}),
    ?assertEqual(<<"myapp">>, maps:get(id, Entry)),
    ?assertEqual(<<"myapp">>, maps:get(name, Entry)),
    ?assertEqual(Sess, maps:get(session, Entry)),
    ?assertEqual(active, maps:get(status, Entry)),
    ?assert(is_list(maps:get(modes, Entry))),
    ?assertEqual([], maps:get(log, Entry)),
    ?assert(is_map(maps:get(metadata, Entry))),
    ?assert(is_integer(maps:get(registered_at, maps:get(metadata, Entry)))),
    beam_agent_app_core:clear().

register_app_with_custom_name_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    {ok, Entry} = beam_agent_app_core:register_app(
        <<"sess-reg-2">>, <<"app2">>, #{name => <<"My Custom App">>}),
    ?assertEqual(<<"My Custom App">>, maps:get(name, Entry)),
    beam_agent_app_core:clear().

register_app_with_custom_modes_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Modes = [<<"fast">>, <<"slow">>],
    {ok, Entry} = beam_agent_app_core:register_app(
        <<"sess-reg-3">>, <<"app3">>, #{modes => Modes}),
    ?assertEqual(Modes, maps:get(modes, Entry)),
    beam_agent_app_core:clear().

register_app_with_metadata_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Meta = #{env => <<"prod">>},
    {ok, Entry} = beam_agent_app_core:register_app(
        <<"sess-reg-4">>, <<"app4">>, #{metadata => Meta}),
    Merged = maps:get(metadata, Entry),
    ?assertEqual(<<"prod">>, maps:get(env, Merged)),
    %% registered_at is also present from the base entry
    ?assert(maps:is_key(registered_at, Merged)),
    beam_agent_app_core:clear().

register_app_update_existing_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-reg-upd">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"app5">>, #{name => <<"v1">>}),
    {ok, Updated} = beam_agent_app_core:register_app(Sess, <<"app5">>, #{name => <<"v2">>}),
    ?assertEqual(<<"v2">>, maps:get(name, Updated)),
    %% Only one app should exist
    {ok, List} = beam_agent_app_core:apps_list(Sess),
    ?assertEqual(1, length(List)),
    beam_agent_app_core:clear().

register_app_inactive_status_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    {ok, Entry} = beam_agent_app_core:register_app(
        <<"sess-reg-inact">>, <<"app6">>, #{status => inactive}),
    ?assertEqual(inactive, maps:get(status, Entry)),
    beam_agent_app_core:clear().

%%====================================================================
%% apps_list tests
%%====================================================================

apps_list_empty_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    {ok, List} = beam_agent_app_core:apps_list(<<"sess-empty">>),
    ?assertEqual([], List).

apps_list_returns_registered_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-list-1">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"a1">>, #{}),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"a2">>, #{}),
    {ok, List} = beam_agent_app_core:apps_list(Sess),
    ?assertEqual(2, length(List)),
    Ids = lists:sort([maps:get(id, E) || E <- List]),
    ?assertEqual([<<"a1">>, <<"a2">>], Ids),
    beam_agent_app_core:clear().

apps_list_session_isolation_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    {ok, _} = beam_agent_app_core:register_app(<<"sessA">>, <<"a1">>, #{}),
    {ok, _} = beam_agent_app_core:register_app(<<"sessB">>, <<"b1">>, #{}),
    {ok, ListA} = beam_agent_app_core:apps_list(<<"sessA">>),
    {ok, ListB} = beam_agent_app_core:apps_list(<<"sessB">>),
    ?assertEqual(1, length(ListA)),
    ?assertEqual(1, length(ListB)),
    ?assertEqual(<<"a1">>, maps:get(id, hd(ListA))),
    ?assertEqual(<<"b1">>, maps:get(id, hd(ListB))),
    beam_agent_app_core:clear().

apps_list_status_filter_active_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-filter">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"act">>, #{status => active}),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"inact">>, #{status => inactive}),
    {ok, Active} = beam_agent_app_core:apps_list(Sess, #{status => active}),
    ?assertEqual(1, length(Active)),
    ?assertEqual(<<"act">>, maps:get(id, hd(Active))),
    beam_agent_app_core:clear().

apps_list_status_filter_inactive_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-filter-2">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"act">>, #{status => active}),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"inact">>, #{status => inactive}),
    {ok, Inactive} = beam_agent_app_core:apps_list(Sess, #{status => inactive}),
    ?assertEqual(1, length(Inactive)),
    ?assertEqual(<<"inact">>, maps:get(id, hd(Inactive))),
    beam_agent_app_core:clear().

apps_list_no_filter_returns_all_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-filter-3">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"act">>, #{status => active}),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"inact">>, #{status => inactive}),
    {ok, All} = beam_agent_app_core:apps_list(Sess, #{}),
    ?assertEqual(2, length(All)),
    beam_agent_app_core:clear().

%%====================================================================
%% app_info tests
%%====================================================================

app_info_no_app_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    ?assertEqual({error, no_app}, beam_agent_app_core:app_info(<<"sess-noapp">>)).

app_info_returns_entry_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-info-1">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"infoapp">>, #{}),
    {ok, Entry} = beam_agent_app_core:app_info(Sess),
    ?assertEqual(<<"infoapp">>, maps:get(id, Entry)),
    beam_agent_app_core:clear().

app_info_returns_latest_when_multiple_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-info-multi">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"first">>, #{}),
    timer:sleep(5),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"second">>, #{}),
    {ok, Entry} = beam_agent_app_core:app_info(Sess),
    ?assertEqual(<<"second">>, maps:get(id, Entry)),
    beam_agent_app_core:clear().

%%====================================================================
%% app_init tests
%%====================================================================

app_init_creates_default_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-init-1">>,
    {ok, Entry} = beam_agent_app_core:app_init(Sess),
    ?assertEqual(<<"default">>, maps:get(id, Entry)),
    ?assertEqual(<<"app-sess-init-1">>, maps:get(name, Entry)),
    beam_agent_app_core:clear().

app_init_idempotent_returns_existing_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-init-2">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"existing">>, #{name => <<"MyApp">>}),
    {ok, Entry} = beam_agent_app_core:app_init(Sess),
    %% Returns the existing app, does not create a new default
    ?assertEqual(<<"existing">>, maps:get(id, Entry)),
    ?assertEqual(<<"MyApp">>, maps:get(name, Entry)),
    beam_agent_app_core:clear().

app_init_twice_same_result_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-init-3">>,
    {ok, First} = beam_agent_app_core:app_init(Sess),
    {ok, Second} = beam_agent_app_core:app_init(Sess),
    ?assertEqual(maps:get(id, First), maps:get(id, Second)),
    %% Still only one app
    {ok, List} = beam_agent_app_core:apps_list(Sess),
    ?assertEqual(1, length(List)),
    beam_agent_app_core:clear().

%%====================================================================
%% app_log tests
%%====================================================================

app_log_appends_entry_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-log-1">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"logapp">>, #{}),
    ok = beam_agent_app_core:app_log(Sess, <<"first log">>),
    ok = beam_agent_app_core:app_log(Sess, <<"second log">>),
    {ok, Entry} = beam_agent_app_core:app_info(Sess),
    Log = maps:get(log, Entry),
    ?assertEqual(2, length(Log)),
    %% Chronological order (oldest first) in the public API
    [First, Second] = Log,
    ?assertEqual(<<"first log">>, maps:get(body, First)),
    ?assertEqual(<<"second log">>, maps:get(body, Second)),
    ?assert(is_integer(maps:get(timestamp, First))),
    ?assert(maps:get(timestamp, First) =< maps:get(timestamp, Second)),
    beam_agent_app_core:clear().

app_log_no_app_returns_error_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    ?assertEqual({error, no_app}, beam_agent_app_core:app_log(<<"sess-nolog">>, <<"msg">>)).

app_log_arbitrary_term_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-log-term">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"termapp">>, #{}),
    ok = beam_agent_app_core:app_log(Sess, #{level => error, msg => <<"boom">>}),
    {ok, Entry} = beam_agent_app_core:app_info(Sess),
    [LogEntry] = maps:get(log, Entry),
    ?assertEqual(#{level => error, msg => <<"boom">>}, maps:get(body, LogEntry)),
    beam_agent_app_core:clear().

%%====================================================================
%% app_modes tests
%%====================================================================

app_modes_default_when_no_app_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    {ok, Modes} = beam_agent_app_core:app_modes(<<"sess-nomodes">>),
    ?assertEqual([<<"default">>, <<"debug">>, <<"verbose">>], Modes).

app_modes_default_after_register_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-modes-1">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"modeapp">>, #{}),
    {ok, Modes} = beam_agent_app_core:app_modes(Sess),
    ?assertEqual([<<"default">>, <<"debug">>, <<"verbose">>], Modes),
    beam_agent_app_core:clear().

app_modes_custom_after_register_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-modes-2">>,
    Custom = [<<"turbo">>, <<"stealth">>],
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"modeapp2">>, #{modes => Custom}),
    {ok, Modes} = beam_agent_app_core:app_modes(Sess),
    ?assertEqual(Custom, Modes),
    beam_agent_app_core:clear().

%%====================================================================
%% unregister_app tests
%%====================================================================

unregister_app_removes_entry_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-unreg-1">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"gone">>, #{}),
    {ok, [_]} = beam_agent_app_core:apps_list(Sess),
    ok = beam_agent_app_core:unregister_app(Sess, <<"gone">>),
    {ok, []} = beam_agent_app_core:apps_list(Sess),
    beam_agent_app_core:clear().

unregister_app_idempotent_on_missing_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    ok = beam_agent_app_core:unregister_app(<<"sess-unreg-2">>, <<"nosuch">>),
    beam_agent_app_core:clear().

unregister_app_only_target_test() ->
    beam_agent_app_core:ensure_tables(),
    beam_agent_app_core:clear(),
    Sess = <<"sess-unreg-3">>,
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"keep">>, #{}),
    {ok, _} = beam_agent_app_core:register_app(Sess, <<"remove">>, #{}),
    ok = beam_agent_app_core:unregister_app(Sess, <<"remove">>),
    {ok, Remaining} = beam_agent_app_core:apps_list(Sess),
    ?assertEqual(1, length(Remaining)),
    ?assertEqual(<<"keep">>, maps:get(id, hd(Remaining))),
    beam_agent_app_core:clear().
