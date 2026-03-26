%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_plugin_registry.
%%%
%%% Covers:
%%%   - register/unregister/get/list/clear CRUD operations
%%%   - All mutations emit {beam_agent_reload, plugins, _}
%%%   - Version counter increments across mutations
%%%   - Idempotent unregister of non-existent plugin
%%%   - get returns {error, not_found} for missing plugin
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_plugin_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_plugin_registry:ensure_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_global_plugins),
    ok.

expect_plugins_reload() ->
    receive
        {beam_agent_reload, plugins, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

test_opts() ->
    #{name => <<"Test Plugin">>,
      description => <<"A test plugin">>,
      version => <<"1.0.0">>,
      enabled => true,
      config => #{}}.

%%====================================================================
%% Tests
%%====================================================================

register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    V = expect_plugins_reload(),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_plugin_registry:get(<<"p1">>),
    ?assertEqual(<<"p1">>, maps:get(id, Entry)),
    ?assertEqual(<<"Test Plugin">>, maps:get(name, Entry)),
    cleanup_tables().

get_returns_not_found_for_missing_test() ->
    setup(),
    ?assertEqual({error, not_found}, beam_agent_plugin_registry:get(<<"nope">>)),
    cleanup_tables().

list_returns_all_entries_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    _ = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:register(<<"p2">>,
        (test_opts())#{name => <<"Plugin 2">>}),
    _ = expect_plugins_reload(),
    Entries = beam_agent_plugin_registry:list(),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

unregister_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    _ = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:unregister(<<"p1">>),
    V2 = expect_plugins_reload(),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found}, beam_agent_plugin_registry:get(<<"p1">>)),
    cleanup_tables().

unregister_nonexistent_is_idempotent_test() ->
    setup(),
    ok = beam_agent_plugin_registry:unregister(<<"nonexistent">>),
    %% Should still get a reload notification (fire-and-forget pattern).
    V = expect_plugins_reload(),
    ?assert(V >= 1),
    cleanup_tables().

clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    _ = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:register(<<"p2">>, test_opts()),
    _ = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:clear(),
    V3 = expect_plugins_reload(),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_plugin_registry:list()),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    V1 = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:unregister(<<"p1">>),
    V2 = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:clear(),
    V3 = expect_plugins_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().

register_overwrites_existing_test() ->
    setup(),
    ok = beam_agent_plugin_registry:register(<<"p1">>, test_opts()),
    _ = expect_plugins_reload(),
    ok = beam_agent_plugin_registry:register(<<"p1">>,
        (test_opts())#{name => <<"Updated">>}),
    _ = expect_plugins_reload(),
    {ok, Entry} = beam_agent_plugin_registry:get(<<"p1">>),
    ?assertEqual(<<"Updated">>, maps:get(name, Entry)),
    cleanup_tables().
