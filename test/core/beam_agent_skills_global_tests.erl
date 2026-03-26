%%%-------------------------------------------------------------------
%%% @doc EUnit tests for global skill registration in beam_agent_skills_core.
%%%
%%% Covers:
%%%   - register_global_skill/unregister_global_skill/get/list/clear CRUD
%%%   - All mutations emit {beam_agent_reload, skills, _}
%%%   - list_global_skills/1 filtering (enabled, category)
%%%   - Version counter increments across mutations
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_skills_global_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_skills_core:ensure_global_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_global_skills),
    ok.

expect_skills_reload() ->
    receive
        {beam_agent_reload, skills, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

test_opts() ->
    #{name => <<"Test Skill">>,
      description => <<"A test skill">>,
      source => <<"local">>,
      enabled => true,
      config => #{}}.

%%====================================================================
%% Tests
%%====================================================================

register_stores_and_notifies_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    V = expect_skills_reload(),
    ?assert(V >= 1),
    {ok, Entry} = beam_agent_skills_core:get_global_skill(<<"s1">>),
    ?assertEqual(<<"s1">>, maps:get(id, Entry)),
    ?assertEqual(<<"Test Skill">>, maps:get(name, Entry)),
    cleanup_tables().

get_returns_not_found_for_missing_test() ->
    setup(),
    ?assertEqual({error, not_found},
        beam_agent_skills_core:get_global_skill(<<"nope">>)),
    cleanup_tables().

list_returns_all_entries_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:register_global_skill(<<"s2">>,
        (test_opts())#{name => <<"Skill 2">>}),
    _ = expect_skills_reload(),
    Entries = beam_agent_skills_core:list_global_skills(),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

list_with_enabled_filter_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>,
        (test_opts())#{enabled => true}),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:register_global_skill(<<"s2">>,
        (test_opts())#{enabled => false}),
    _ = expect_skills_reload(),
    Enabled = beam_agent_skills_core:list_global_skills(#{enabled => true}),
    ?assertEqual(1, length(Enabled)),
    Disabled = beam_agent_skills_core:list_global_skills(#{enabled => false}),
    ?assertEqual(1, length(Disabled)),
    cleanup_tables().

unregister_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:unregister_global_skill(<<"s1">>),
    V2 = expect_skills_reload(),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found},
        beam_agent_skills_core:get_global_skill(<<"s1">>)),
    cleanup_tables().

clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:register_global_skill(<<"s2">>, test_opts()),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:clear_global_skills(),
    V3 = expect_skills_reload(),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_skills_core:list_global_skills()),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    V1 = expect_skills_reload(),
    ok = beam_agent_skills_core:unregister_global_skill(<<"s1">>),
    V2 = expect_skills_reload(),
    ok = beam_agent_skills_core:clear_global_skills(),
    V3 = expect_skills_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().

register_overwrites_existing_test() ->
    setup(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>, test_opts()),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:register_global_skill(<<"s1">>,
        (test_opts())#{name => <<"Updated">>}),
    _ = expect_skills_reload(),
    {ok, Entry} = beam_agent_skills_core:get_global_skill(<<"s1">>),
    ?assertEqual(<<"Updated">>, maps:get(name, Entry)),
    cleanup_tables().
