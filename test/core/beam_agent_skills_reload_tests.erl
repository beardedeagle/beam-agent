%%%-------------------------------------------------------------------
%%% @doc EUnit tests for reload bus integration in beam_agent_skills_core.
%%%
%%% Covers:
%%%   - register_skill emits {beam_agent_reload, skills, _}
%%%   - unregister_skill emits {beam_agent_reload, skills, _}
%%%   - skills_config_write emits {beam_agent_reload, skills, _}
%%%   - clear emits {beam_agent_reload, skills, _}
%%%   - clear_session emits {beam_agent_reload, skills, _}
%%%   - Version counter increments across mutations
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_skills_reload_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_skills_core:ensure_tables(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_skills),
    ok.

%% Drain one reload message, assert type is skills.
expect_skills_reload() ->
    receive
        {beam_agent_reload, skills, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

%%====================================================================
%% Tests
%%====================================================================

register_skill_notifies_reload_bus_test() ->
    setup(),
    {ok, _} = beam_agent_skills_core:register_skill(
        <<"sess1">>, <<"my_skill">>, #{name => <<"My Skill">>}),
    V = expect_skills_reload(),
    ?assert(V >= 1),
    cleanup_tables().

unregister_skill_notifies_reload_bus_test() ->
    setup(),
    {ok, _} = beam_agent_skills_core:register_skill(
        <<"sess1">>, <<"sk1">>, #{}),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:unregister_skill(<<"sess1">>, <<"sk1">>),
    V2 = expect_skills_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

skills_config_write_notifies_reload_bus_test() ->
    setup(),
    ok = beam_agent_skills_core:skills_config_write(
        <<"sess1">>, <<"/path/to/skill">>, true),
    V = expect_skills_reload(),
    ?assert(V >= 1),
    cleanup_tables().

clear_notifies_reload_bus_test() ->
    setup(),
    {ok, _} = beam_agent_skills_core:register_skill(
        <<"sess1">>, <<"sk1">>, #{}),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:clear(),
    V2 = expect_skills_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

clear_session_notifies_reload_bus_test() ->
    setup(),
    {ok, _} = beam_agent_skills_core:register_skill(
        <<"sess1">>, <<"sk1">>, #{}),
    _ = expect_skills_reload(),
    ok = beam_agent_skills_core:clear_session(<<"sess1">>),
    V2 = expect_skills_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    {ok, _} = beam_agent_skills_core:register_skill(
        <<"sess1">>, <<"sk1">>, #{}),
    V1 = expect_skills_reload(),
    ok = beam_agent_skills_core:skills_config_write(
        <<"sess1">>, <<"/cfg">>, false),
    V2 = expect_skills_reload(),
    ok = beam_agent_skills_core:unregister_skill(<<"sess1">>, <<"sk1">>),
    V3 = expect_skills_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().
