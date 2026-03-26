%%%-------------------------------------------------------------------
%%% @doc EUnit tests for global MCP server registration in
%%% beam_agent_tool_registry.
%%%
%%% Covers:
%%%   - register_global_server/unregister/get/list/clear CRUD
%%%   - All mutations emit {beam_agent_reload, tools, _}
%%%   - Version counter increments across mutations
%%%   - Idempotent unregister of non-existent server
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_tool_registry_global_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_tool_registry:ensure_global_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_global_mcp_servers),
    ok.

expect_tools_reload() ->
    receive
        {beam_agent_reload, tools, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

test_server() ->
    Tool = beam_agent_tool_registry:tool(
        <<"test_tool">>, <<"A test tool">>,
        #{<<"type">> => <<"object">>},
        fun(_Input) -> {ok, [#{type => text, text => <<"ok">>}]} end),
    beam_agent_tool_registry:server(<<"global_server">>, [Tool]).

%%====================================================================
%% Tests
%%====================================================================

register_stores_and_notifies_test() ->
    setup(),
    Server = test_server(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"global_server">>, Server),
    V = expect_tools_reload(),
    ?assert(V >= 1),
    {ok, Retrieved} = beam_agent_tool_registry:get_global_server(
        <<"global_server">>),
    ?assertEqual(<<"global_server">>, maps:get(name, Retrieved)),
    cleanup_tables().

get_returns_not_found_for_missing_test() ->
    setup(),
    ?assertEqual({error, not_found},
        beam_agent_tool_registry:get_global_server(<<"nope">>)),
    cleanup_tables().

list_returns_all_entries_test() ->
    setup(),
    S1 = test_server(),
    S2 = beam_agent_tool_registry:server(<<"server2">>, []),
    ok = beam_agent_tool_registry:register_global_server(<<"s1">>, S1),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:register_global_server(<<"s2">>, S2),
    _ = expect_tools_reload(),
    Entries = beam_agent_tool_registry:list_global_servers(),
    ?assertEqual(2, length(Entries)),
    cleanup_tables().

unregister_removes_and_notifies_test() ->
    setup(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"s1">>, test_server()),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:unregister_global_server(<<"s1">>),
    V2 = expect_tools_reload(),
    ?assert(V2 >= 2),
    ?assertEqual({error, not_found},
        beam_agent_tool_registry:get_global_server(<<"s1">>)),
    cleanup_tables().

unregister_nonexistent_is_idempotent_test() ->
    setup(),
    ok = beam_agent_tool_registry:unregister_global_server(<<"nonexistent">>),
    V = expect_tools_reload(),
    ?assert(V >= 1),
    cleanup_tables().

clear_removes_all_and_notifies_test() ->
    setup(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"s1">>, test_server()),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"s2">>, beam_agent_tool_registry:server(<<"s2">>, [])),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:clear_global_servers(),
    V3 = expect_tools_reload(),
    ?assert(V3 >= 3),
    ?assertEqual([], beam_agent_tool_registry:list_global_servers()),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"s1">>, test_server()),
    V1 = expect_tools_reload(),
    ok = beam_agent_tool_registry:unregister_global_server(<<"s1">>),
    V2 = expect_tools_reload(),
    ok = beam_agent_tool_registry:clear_global_servers(),
    V3 = expect_tools_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().

register_overwrites_existing_test() ->
    setup(),
    ok = beam_agent_tool_registry:register_global_server(
        <<"s1">>, test_server()),
    _ = expect_tools_reload(),
    NewServer = beam_agent_tool_registry:server(<<"updated">>, []),
    ok = beam_agent_tool_registry:register_global_server(<<"s1">>, NewServer),
    _ = expect_tools_reload(),
    {ok, Entry} = beam_agent_tool_registry:get_global_server(<<"s1">>),
    ?assertEqual(<<"updated">>, maps:get(name, Entry)),
    cleanup_tables().
