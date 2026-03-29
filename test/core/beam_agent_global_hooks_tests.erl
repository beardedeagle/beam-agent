%%%-------------------------------------------------------------------
%%% @doc EUnit tests for global hook functionality.
%%%
%%% Covers:
%%%   - Global table creation (ensure_global_table, idempotent)
%%%   - Registration (register_global, unregister_global)
%%%   - Global registry snapshot (global_registry)
%%%   - fire/3 merging global hooks before session hooks
%%%   - Global hooks fire even with undefined session registry
%%%   - Reload bus notification on register/unregister
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_global_hooks_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_hooks_core:ensure_global_table(),
    ok = beam_agent_reload_bus:ensure_tables().

cleanup_tables() ->
    catch ets:delete(beam_agent_global_hooks),
    catch ets:delete(beam_agent_reload),
    ok.

noop_cb() -> fun(Ctx) -> {ok, Ctx} end.

%%====================================================================
%% Table Creation Tests
%%====================================================================

ensure_global_table_creates_ets_test() ->
    setup(),
    ?assertNotEqual(undefined, ets:whereis(beam_agent_global_hooks)),
    cleanup_tables().

ensure_global_table_is_idempotent_test() ->
    setup(),
    ok = beam_agent_hooks_core:ensure_global_table(),
    ?assertNotEqual(undefined, ets:whereis(beam_agent_global_hooks)),
    cleanup_tables().

%%====================================================================
%% Registration Tests
%%====================================================================

register_global_inserts_hook_test() ->
    setup(),
    Hook = beam_agent_hooks_core:hook(pre_tool_use, noop_cb()),
    ok = beam_agent_hooks_core:register_global(Hook),
    Registry = beam_agent_hooks_core:global_registry(),
    ?assertEqual(1, length(maps:get(pre_tool_use, Registry))),
    cleanup_tables().

register_global_creates_table_on_first_use_test() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    %% Table doesn't exist yet
    ?assertEqual(undefined, ets:whereis(beam_agent_global_hooks)),
    Hook = beam_agent_hooks_core:hook(stop, noop_cb()),
    ok = beam_agent_hooks_core:register_global(Hook),
    %% Table should now exist
    ?assertNotEqual(undefined, ets:whereis(beam_agent_global_hooks)),
    cleanup_tables().

register_global_multiple_hooks_same_event_test() ->
    setup(),
    H1 = beam_agent_hooks_core:hook(pre_tool_use, noop_cb()),
    H2 = beam_agent_hooks_core:hook(pre_tool_use, noop_cb()),
    ok = beam_agent_hooks_core:register_global(H1),
    ok = beam_agent_hooks_core:register_global(H2),
    Registry = beam_agent_hooks_core:global_registry(),
    ?assertEqual(2, length(maps:get(pre_tool_use, Registry))),
    cleanup_tables().

register_global_multiple_events_test() ->
    setup(),
    H1 = beam_agent_hooks_core:hook(pre_tool_use, noop_cb()),
    H2 = beam_agent_hooks_core:hook(session_start, noop_cb()),
    ok = beam_agent_hooks_core:register_global(H1),
    ok = beam_agent_hooks_core:register_global(H2),
    Registry = beam_agent_hooks_core:global_registry(),
    ?assertEqual(1, length(maps:get(pre_tool_use, Registry))),
    ?assertEqual(1, length(maps:get(session_start, Registry))),
    cleanup_tables().

unregister_global_removes_hook_test() ->
    setup(),
    Hook = beam_agent_hooks_core:hook(pre_tool_use, noop_cb()),
    ok = beam_agent_hooks_core:register_global(Hook),
    ok = beam_agent_hooks_core:unregister_global(Hook),
    Registry = beam_agent_hooks_core:global_registry(),
    ?assertEqual([], maps:get(pre_tool_use, Registry, [])),
    cleanup_tables().

unregister_global_only_removes_exact_match_test() ->
    setup(),
    Cb1 = fun(Ctx) -> {ok, Ctx} end,
    Cb2 = fun(Ctx) -> {ok, Ctx#{extra => true}} end,
    H1 = beam_agent_hooks_core:hook(pre_tool_use, Cb1),
    H2 = beam_agent_hooks_core:hook(pre_tool_use, Cb2),
    ok = beam_agent_hooks_core:register_global(H1),
    ok = beam_agent_hooks_core:register_global(H2),
    ok = beam_agent_hooks_core:unregister_global(H1),
    Registry = beam_agent_hooks_core:global_registry(),
    ?assertEqual(1, length(maps:get(pre_tool_use, Registry))),
    cleanup_tables().

unregister_global_idempotent_test() ->
    setup(),
    Hook = beam_agent_hooks_core:hook(stop, noop_cb()),
    %% Unregistering a hook that was never registered should not crash.
    ok = beam_agent_hooks_core:unregister_global(Hook),
    cleanup_tables().

unregister_global_no_table_safe_test() ->
    cleanup_tables(),
    Hook = beam_agent_hooks_core:hook(stop, noop_cb()),
    ok = beam_agent_hooks_core:unregister_global(Hook).

%%====================================================================
%% Global Registry Snapshot Tests
%%====================================================================

global_registry_empty_when_no_hooks_test() ->
    setup(),
    ?assertEqual(#{}, beam_agent_hooks_core:global_registry()),
    cleanup_tables().

global_registry_empty_when_no_table_test() ->
    cleanup_tables(),
    ?assertEqual(#{}, beam_agent_hooks_core:global_registry()).

%%====================================================================
%% fire/3 Global + Session Merge Tests
%%====================================================================

fire_merges_global_before_session_test() ->
    setup(),
    %% Global hook appends "global" to a list in context
    GlobalHook = beam_agent_hooks_core:hook(post_tool_use, fun(Ctx) ->
        Trail = maps:get(trail, Ctx, []),
        {ok, Ctx#{trail => Trail ++ [global]}}
    end),
    ok = beam_agent_hooks_core:register_global(GlobalHook),
    %% Session hook appends "session" to the same list
    SessionHook = beam_agent_hooks_core:hook(post_tool_use, fun(Ctx) ->
        Trail = maps:get(trail, Ctx, []),
        {ok, Ctx#{trail => Trail ++ [session]}}
    end),
    SessionReg = beam_agent_hooks_core:register_hook(
        SessionHook, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => post_tool_use, trail => []},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(post_tool_use, Ctx, SessionReg),
    %% Global fires first, then session
    ?assertEqual([global, session], maps:get(trail, FinalCtx)),
    cleanup_tables().

fire_global_hooks_with_undefined_session_registry_test() ->
    setup(),
    GlobalHook = beam_agent_hooks_core:hook(session_start, fun(Ctx) ->
        {ok, Ctx#{global_fired => true}}
    end),
    ok = beam_agent_hooks_core:register_global(GlobalHook),
    Ctx = #{event => session_start},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(session_start, Ctx, undefined),
    ?assertEqual(true, maps:get(global_fired, FinalCtx)),
    cleanup_tables().

fire_global_hooks_with_empty_session_registry_test() ->
    setup(),
    GlobalHook = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) ->
        {ok, Ctx#{global_ran => true}}
    end),
    ok = beam_agent_hooks_core:register_global(GlobalHook),
    Ctx = #{event => pre_tool_use, tool_name => <<"Read">>},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, #{}),
    ?assertEqual(true, maps:get(global_ran, FinalCtx)),
    cleanup_tables().

fire_no_hooks_returns_context_unchanged_test() ->
    setup(),
    Ctx = #{event => pre_tool_use},
    {ok, FinalCtx} = beam_agent_hooks_core:fire(pre_tool_use, Ctx, #{}),
    ?assertEqual(Ctx, FinalCtx),
    cleanup_tables().

fire_global_blocking_deny_stops_chain_test() ->
    setup(),
    DenyHook = beam_agent_hooks_core:hook(pre_tool_use, fun(_Ctx) ->
        {deny, <<"Blocked by global hook">>}
    end),
    ok = beam_agent_hooks_core:register_global(DenyHook),
    %% Session hook should never fire
    SessionHook = beam_agent_hooks_core:hook(pre_tool_use, fun(Ctx) ->
        {ok, Ctx#{session_fired => true}}
    end),
    SessionReg = beam_agent_hooks_core:register_hook(
        SessionHook, beam_agent_hooks_core:new_registry()),
    Ctx = #{event => pre_tool_use, tool_name => <<"Bash">>},
    Result = beam_agent_hooks_core:fire(pre_tool_use, Ctx, SessionReg),
    ?assertEqual({deny, <<"Blocked by global hook">>}, Result),
    cleanup_tables().

fire_global_blocking_ask_stops_chain_test() ->
    setup(),
    AskHook = beam_agent_hooks_core:hook(pre_tool_use, fun(_Ctx) ->
        {ask, <<"Need permission">>}
    end),
    ok = beam_agent_hooks_core:register_global(AskHook),
    Ctx = #{event => pre_tool_use, tool_name => <<"Write">>},
    Result = beam_agent_hooks_core:fire(pre_tool_use, Ctx, #{}),
    ?assertEqual({ask, <<"Need permission">>}, Result),
    cleanup_tables().

%%====================================================================
%% Reload Bus Integration Tests
%%====================================================================

register_global_notifies_reload_bus_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    Hook = beam_agent_hooks_core:hook(stop, noop_cb()),
    ok = beam_agent_hooks_core:register_global(Hook),
    receive
        {beam_agent_reload, hooks, _Version} -> ok
    after 1000 ->
        ?assert(false)
    end,
    cleanup_tables().

unregister_global_notifies_reload_bus_test() ->
    setup(),
    Hook = beam_agent_hooks_core:hook(stop, noop_cb()),
    ok = beam_agent_hooks_core:register_global(Hook),
    %% Subscribe after register so we only see the unregister notification
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_hooks_core:unregister_global(Hook),
    receive
        {beam_agent_reload, hooks, _Version} -> ok
    after 1000 ->
        ?assert(false)
    end,
    cleanup_tables().
