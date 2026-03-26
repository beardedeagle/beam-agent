%%%-------------------------------------------------------------------
%%% @doc EUnit tests for reload bus integration in beam_agent_tool_registry.
%%%
%%% Covers:
%%%   - register_session_registry emits {beam_agent_reload, tools, _}
%%%   - update_session_registry emits {beam_agent_reload, tools, _}
%%%   - unregister_session_registry emits {beam_agent_reload, tools, _}
%%%   - Version counter increments across mutations
%%%   - register_session_registry with undefined skips notification
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_tool_registry_reload_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_tool_registry:ensure_registry_table(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_tool_registries),
    ok.

%% Drain one reload message, assert type is tools.
expect_tools_reload() ->
    receive
        {beam_agent_reload, tools, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

%% Build a minimal MCP registry for testing.
test_registry() ->
    Tool = beam_agent_tool_registry:tool(
        <<"test_tool">>, <<"A test tool">>,
        #{<<"type">> => <<"object">>},
        fun(_Input) -> {ok, [#{type => text, text => <<"ok">>}]} end),
    Server = beam_agent_tool_registry:server(<<"test_server">>, [Tool]),
    beam_agent_tool_registry:build_registry([Server]).

%%====================================================================
%% Tests
%%====================================================================

register_session_registry_notifies_reload_bus_test() ->
    setup(),
    Registry = test_registry(),
    ok = beam_agent_tool_registry:register_session_registry(self(), Registry),
    V = expect_tools_reload(),
    ?assert(V >= 1),
    cleanup_tables().

register_session_registry_undefined_skips_notification_test() ->
    setup(),
    ok = beam_agent_tool_registry:register_session_registry(self(), undefined),
    %% No message should arrive — undefined registries are no-ops.
    receive
        {beam_agent_reload, tools, _} -> ?assert(false)
    after 100 ->
        ok
    end,
    cleanup_tables().

update_session_registry_notifies_reload_bus_test() ->
    setup(),
    Registry = test_registry(),
    ok = beam_agent_tool_registry:register_session_registry(self(), Registry),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:update_session_registry(
        self(), fun(R) -> R end),
    V2 = expect_tools_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

update_session_registry_not_found_skips_notification_test() ->
    setup(),
    FakePid = spawn(fun() -> receive stop -> ok end end),
    %% No registry registered for FakePid — should return error, no notification.
    {error, not_found} = beam_agent_tool_registry:update_session_registry(
        FakePid, fun(R) -> R end),
    receive
        {beam_agent_reload, tools, _} -> ?assert(false)
    after 100 ->
        ok
    end,
    FakePid ! stop,
    cleanup_tables().

unregister_session_registry_notifies_reload_bus_test() ->
    setup(),
    Registry = test_registry(),
    ok = beam_agent_tool_registry:register_session_registry(self(), Registry),
    _ = expect_tools_reload(),
    ok = beam_agent_tool_registry:unregister_session_registry(self()),
    V2 = expect_tools_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    Registry = test_registry(),
    ok = beam_agent_tool_registry:register_session_registry(self(), Registry),
    V1 = expect_tools_reload(),
    ok = beam_agent_tool_registry:update_session_registry(
        self(), fun(R) -> R end),
    V2 = expect_tools_reload(),
    ok = beam_agent_tool_registry:unregister_session_registry(self()),
    V3 = expect_tools_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().
