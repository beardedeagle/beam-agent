%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_registry.
%%%
%%% Covers:
%%%   - register/unregister/get/list/clear CRUD for each kind
%%%   - Kind isolation (clearing one kind does not affect others)
%%%   - All mutations emit {beam_agent_reload, Atom, _} for their kind
%%%   - Version counter increments across mutations
%%%   - Idempotent unregister of non-existent entries
%%%   - get returns {error, not_found} for missing entries
%%%   - register overwrites existing entries
%%%   - Kind-specific optional fields (role, version, handler)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_registry:ensure_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload),
    catch ets:delete(beam_agent_registry),
    ok.

expect_reload(Atom) ->
    receive
        {beam_agent_reload, Atom, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

drain_reloads() ->
    receive
        {beam_agent_reload, _, _} -> drain_reloads()
    after 0 ->
        ok
    end.

agent_opts() ->
    #{name => <<"Code Reviewer">>,
      description => <<"Reviews code for quality">>,
      role => reviewer,
      enabled => true,
      config => #{}}.

plugin_opts() ->
    #{name => <<"My Plugin">>,
      description => <<"A test plugin">>,
      version => <<"1.0.0">>,
      enabled => true,
      config => #{}}.

slash_opts() ->
    #{name => <<"review">>,
      description => <<"Run a code review">>,
      handler => fun(_) -> {ok, #{}} end,
      enabled => true,
      config => #{}}.

%%====================================================================
%% Agent Kind Tests
%%====================================================================

agent_register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    V = expect_reload(agents),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_registry:get(agent, <<"a1">>),
    ?assertEqual(<<"a1">>, maps:get(id, Entry)),
    ?assertEqual(agent, maps:get(kind, Entry)),
    ?assertEqual(<<"Code Reviewer">>, maps:get(name, Entry)),
    ?assertEqual(reviewer, maps:get(role, Entry)),
    cleanup_tables().

agent_get_not_found_test() ->
    setup(),
    ?assertEqual({error, not_found}, beam_agent_registry:get(agent, <<"nope">>)),
    cleanup_tables().

agent_list_returns_all_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:register(agent, <<"a2">>,
        (agent_opts())#{name => <<"Architect">>}),
    _ = expect_reload(agents),
    Entries = beam_agent_registry:list(agent),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

agent_unregister_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:unregister(agent, <<"a1">>),
    V2 = expect_reload(agents),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found}, beam_agent_registry:get(agent, <<"a1">>)),
    cleanup_tables().

agent_unregister_nonexistent_is_idempotent_test() ->
    setup(),
    ok = beam_agent_registry:unregister(agent, <<"nonexistent">>),
    V = expect_reload(agents),
    ?assert(V >= 1),
    cleanup_tables().

agent_clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:register(agent, <<"a2">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:clear(agent),
    V3 = expect_reload(agents),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_registry:list(agent)),
    cleanup_tables().

agent_version_increments_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    V1 = expect_reload(agents),
    ok = beam_agent_registry:unregister(agent, <<"a1">>),
    V2 = expect_reload(agents),
    ok = beam_agent_registry:clear(agent),
    V3 = expect_reload(agents),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().

agent_register_overwrites_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:register(agent, <<"a1">>,
        (agent_opts())#{name => <<"Updated">>}),
    _ = expect_reload(agents),
    {ok, Entry} = beam_agent_registry:get(agent, <<"a1">>),
    ?assertEqual(<<"Updated">>, maps:get(name, Entry)),
    cleanup_tables().

%%====================================================================
%% Plugin Kind Tests
%%====================================================================

plugin_register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_registry:register(plugin, <<"p1">>, plugin_opts()),
    V = expect_reload(plugins),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_registry:get(plugin, <<"p1">>),
    ?assertEqual(<<"p1">>, maps:get(id, Entry)),
    ?assertEqual(plugin, maps:get(kind, Entry)),
    ?assertEqual(<<"1.0.0">>, maps:get(version, Entry)),
    cleanup_tables().

plugin_list_returns_all_test() ->
    setup(),
    ok = beam_agent_registry:register(plugin, <<"p1">>, plugin_opts()),
    _ = expect_reload(plugins),
    ok = beam_agent_registry:register(plugin, <<"p2">>,
        (plugin_opts())#{name => <<"Other Plugin">>}),
    _ = expect_reload(plugins),
    Entries = beam_agent_registry:list(plugin),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

plugin_clear_removes_all_test() ->
    setup(),
    ok = beam_agent_registry:register(plugin, <<"p1">>, plugin_opts()),
    _ = expect_reload(plugins),
    ok = beam_agent_registry:clear(plugin),
    _ = expect_reload(plugins),
    ?assertEqual([], beam_agent_registry:list(plugin)),
    cleanup_tables().

%%====================================================================
%% Slash Kind Tests
%%====================================================================

slash_register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_registry:register(slash, <<"review">>, slash_opts()),
    V = expect_reload(commands),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_registry:get(slash, <<"review">>),
    ?assertEqual(<<"review">>, maps:get(id, Entry)),
    ?assertEqual(slash, maps:get(kind, Entry)),
    ?assert(is_function(maps:get(handler, Entry), 1)),
    cleanup_tables().

slash_list_returns_all_test() ->
    setup(),
    ok = beam_agent_registry:register(slash, <<"review">>, slash_opts()),
    _ = expect_reload(commands),
    ok = beam_agent_registry:register(slash, <<"commit">>,
        (slash_opts())#{name => <<"commit">>}),
    _ = expect_reload(commands),
    Entries = beam_agent_registry:list(slash),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

slash_clear_removes_all_test() ->
    setup(),
    ok = beam_agent_registry:register(slash, <<"review">>, slash_opts()),
    _ = expect_reload(commands),
    ok = beam_agent_registry:clear(slash),
    _ = expect_reload(commands),
    ?assertEqual([], beam_agent_registry:list(slash)),
    cleanup_tables().

%%====================================================================
%% Kind Isolation Tests
%%====================================================================

kinds_are_isolated_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"x">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:register(plugin, <<"x">>, plugin_opts()),
    _ = expect_reload(plugins),
    ok = beam_agent_registry:register(slash, <<"x">>, slash_opts()),
    _ = expect_reload(commands),
    %% Same id, different kinds — all coexist
    ?assertEqual(3, length(beam_agent_registry:list(agent))
        + length(beam_agent_registry:list(plugin))
        + length(beam_agent_registry:list(slash))),
    %% Clear one kind, others untouched
    ok = beam_agent_registry:clear(agent),
    drain_reloads(),
    ?assertEqual([], beam_agent_registry:list(agent)),
    ?assertEqual(1, length(beam_agent_registry:list(plugin))),
    ?assertEqual(1, length(beam_agent_registry:list(slash))),
    cleanup_tables().

clear_all_removes_everything_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"a1">>, agent_opts()),
    _ = expect_reload(agents),
    ok = beam_agent_registry:register(plugin, <<"p1">>, plugin_opts()),
    _ = expect_reload(plugins),
    ok = beam_agent_registry:register(slash, <<"s1">>, slash_opts()),
    _ = expect_reload(commands),
    ok = beam_agent_registry:clear(),
    drain_reloads(),
    ?assertEqual([], beam_agent_registry:list(agent)),
    ?assertEqual([], beam_agent_registry:list(plugin)),
    ?assertEqual([], beam_agent_registry:list(slash)),
    cleanup_tables().

%%====================================================================
%% Default Value Tests
%%====================================================================

name_defaults_to_id_test() ->
    setup(),
    ok = beam_agent_registry:register(agent, <<"my-agent">>, #{enabled => true}),
    _ = expect_reload(agents),
    {ok, Entry} = beam_agent_registry:get(agent, <<"my-agent">>),
    ?assertEqual(<<"my-agent">>, maps:get(name, Entry)),
    cleanup_tables().

enabled_defaults_to_true_test() ->
    setup(),
    ok = beam_agent_registry:register(plugin, <<"p1">>, #{name => <<"P">>}),
    _ = expect_reload(plugins),
    {ok, Entry} = beam_agent_registry:get(plugin, <<"p1">>),
    ?assertEqual(true, maps:get(enabled, Entry)),
    cleanup_tables().
