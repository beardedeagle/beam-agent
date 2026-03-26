%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_agent_registry.
%%%
%%% Covers:
%%%   - register/unregister/get/list/clear CRUD operations
%%%   - All mutations emit {beam_agent_reload, agents, _}
%%%   - Version counter increments across mutations
%%%   - Idempotent unregister of non-existent agent
%%%   - get returns {error, not_found} for missing agent
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_agent_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_agent_registry:ensure_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_global_agents),
    ok.

expect_agents_reload() ->
    receive
        {beam_agent_reload, agents, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

test_opts() ->
    #{name => <<"Code Reviewer">>,
      description => <<"Reviews code for quality">>,
      role => <<"reviewer">>,
      enabled => true,
      config => #{}}.

%%====================================================================
%% Tests
%%====================================================================

register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    V = expect_agents_reload(),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_agent_registry:get(<<"a1">>),
    ?assertEqual(<<"a1">>, maps:get(id, Entry)),
    ?assertEqual(<<"Code Reviewer">>, maps:get(name, Entry)),
    cleanup_tables().

get_returns_not_found_for_missing_test() ->
    setup(),
    ?assertEqual({error, not_found}, beam_agent_agent_registry:get(<<"nope">>)),
    cleanup_tables().

list_returns_all_entries_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    _ = expect_agents_reload(),
    ok = beam_agent_agent_registry:register(<<"a2">>,
        (test_opts())#{name => <<"Architect">>}),
    _ = expect_agents_reload(),
    Entries = beam_agent_agent_registry:list(),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

unregister_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    _ = expect_agents_reload(),
    ok = beam_agent_agent_registry:unregister(<<"a1">>),
    V2 = expect_agents_reload(),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found}, beam_agent_agent_registry:get(<<"a1">>)),
    cleanup_tables().

unregister_nonexistent_is_idempotent_test() ->
    setup(),
    ok = beam_agent_agent_registry:unregister(<<"nonexistent">>),
    V = expect_agents_reload(),
    ?assert(V >= 1),
    cleanup_tables().

clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    _ = expect_agents_reload(),
    ok = beam_agent_agent_registry:register(<<"a2">>, test_opts()),
    _ = expect_agents_reload(),
    ok = beam_agent_agent_registry:clear(),
    V3 = expect_agents_reload(),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_agent_registry:list()),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    V1 = expect_agents_reload(),
    ok = beam_agent_agent_registry:unregister(<<"a1">>),
    V2 = expect_agents_reload(),
    ok = beam_agent_agent_registry:clear(),
    V3 = expect_agents_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().

register_overwrites_existing_test() ->
    setup(),
    ok = beam_agent_agent_registry:register(<<"a1">>, test_opts()),
    _ = expect_agents_reload(),
    ok = beam_agent_agent_registry:register(<<"a1">>,
        (test_opts())#{name => <<"Updated">>}),
    _ = expect_agents_reload(),
    {ok, Entry} = beam_agent_agent_registry:get(<<"a1">>),
    ?assertEqual(<<"Updated">>, maps:get(name, Entry)),
    cleanup_tables().
