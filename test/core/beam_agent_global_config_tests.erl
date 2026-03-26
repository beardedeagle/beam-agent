%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_global_config.
%%%
%%% Covers:
%%%   - set/get/get-with-default/delete/list/clear CRUD operations
%%%   - All mutations emit {beam_agent_reload, config, _}
%%%   - Version counter increments across mutations
%%%   - get returns {error, not_found} for missing key
%%%   - get/2 returns default for missing key
%%%   - Idempotent delete of non-existent key
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_global_config_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_global_config:ensure_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_global_config),
    ok.

expect_config_reload() ->
    receive
        {beam_agent_reload, config, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

%%====================================================================
%% Tests
%%====================================================================

set_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"max_retries">>, 3),
    V = expect_config_reload(),
    ?assert(V >= 1),
    ?assertEqual({ok, 3}, beam_agent_global_config:get(<<"max_retries">>)),
    cleanup_tables().

get_returns_not_found_for_missing_test() ->
    setup(),
    ?assertEqual({error, not_found}, beam_agent_global_config:get(<<"nope">>)),
    cleanup_tables().

get_with_default_returns_value_when_present_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"timeout">>, 5000),
    _ = expect_config_reload(),
    ?assertEqual(5000, beam_agent_global_config:get(<<"timeout">>, 1000)),
    cleanup_tables().

get_with_default_returns_default_when_missing_test() ->
    setup(),
    ?assertEqual(1000, beam_agent_global_config:get(<<"timeout">>, 1000)),
    cleanup_tables().

list_returns_all_entries_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"k1">>, v1),
    _ = expect_config_reload(),
    ok = beam_agent_global_config:set(<<"k2">>, v2),
    _ = expect_config_reload(),
    Entries = beam_agent_global_config:list(),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

delete_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"k1">>, v1),
    _ = expect_config_reload(),
    ok = beam_agent_global_config:delete(<<"k1">>),
    V2 = expect_config_reload(),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found}, beam_agent_global_config:get(<<"k1">>)),
    cleanup_tables().

delete_nonexistent_is_idempotent_test() ->
    setup(),
    ok = beam_agent_global_config:delete(<<"nonexistent">>),
    V = expect_config_reload(),
    ?assert(V >= 1),
    cleanup_tables().

clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"k1">>, v1),
    _ = expect_config_reload(),
    ok = beam_agent_global_config:set(<<"k2">>, v2),
    _ = expect_config_reload(),
    ok = beam_agent_global_config:clear(),
    V3 = expect_config_reload(),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_global_config:list()),
    cleanup_tables().

set_overwrites_existing_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"k1">>, original),
    _ = expect_config_reload(),
    ok = beam_agent_global_config:set(<<"k1">>, updated),
    _ = expect_config_reload(),
    ?assertEqual({ok, updated}, beam_agent_global_config:get(<<"k1">>)),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_global_config:set(<<"k1">>, v1),
    V1 = expect_config_reload(),
    ok = beam_agent_global_config:delete(<<"k1">>),
    V2 = expect_config_reload(),
    ok = beam_agent_global_config:clear(),
    V3 = expect_config_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().
