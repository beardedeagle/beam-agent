%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_reload_bus.
%%%
%%% Covers:
%%%   - Table creation (ensure_tables, idempotent)
%%%   - Subscription (subscribe, unsubscribe, idempotent)
%%%   - Notification (notify sends to subscribers, prunes dead)
%%%   - Version counter (monotonic, incremented on notify)
%%%   - Graceful degradation (operations before table creation)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_reload_bus_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

%% Each test needs a fresh ETS state. We delete the tables if they
%% exist, then call ensure_tables/0 to recreate them.
setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    ok.

%%====================================================================
%% Table Creation Tests
%%====================================================================

ensure_tables_creates_both_tables_test() ->
    setup(),
    ?assertNotEqual(undefined, ets:whereis(beam_agent_reload_subscribers)),
    ?assertNotEqual(undefined, ets:whereis(beam_agent_reload_version)),
    cleanup_tables().

ensure_tables_is_idempotent_test() ->
    setup(),
    %% Calling again should not crash or reset the version.
    ok = beam_agent_reload_bus:ensure_tables(),
    ?assertNotEqual(undefined, ets:whereis(beam_agent_reload_subscribers)),
    cleanup_tables().

ensure_tables_seeds_version_at_zero_test() ->
    setup(),
    ?assertEqual(0, beam_agent_reload_bus:version()),
    cleanup_tables().

%%====================================================================
%% Subscription Tests
%%====================================================================

subscribe_adds_calling_process_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    Subs = ets:tab2list(beam_agent_reload_subscribers),
    ?assert(lists:member({self()}, Subs)),
    cleanup_tables().

subscribe_explicit_pid_test() ->
    setup(),
    Pid = spawn(fun() -> receive stop -> ok end end),
    ok = beam_agent_reload_bus:subscribe(Pid),
    Subs = ets:tab2list(beam_agent_reload_subscribers),
    ?assert(lists:member({Pid}, Subs)),
    Pid ! stop,
    cleanup_tables().

subscribe_is_idempotent_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:subscribe(),
    %% set table — duplicate inserts are no-ops
    Subs = ets:tab2list(beam_agent_reload_subscribers),
    Count = length([S || S = {P} <- Subs, P =:= self()]),
    ?assertEqual(1, Count),
    cleanup_tables().

unsubscribe_removes_calling_process_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:unsubscribe(),
    Subs = ets:tab2list(beam_agent_reload_subscribers),
    ?assertNot(lists:member({self()}, Subs)),
    cleanup_tables().

unsubscribe_is_idempotent_test() ->
    setup(),
    %% Unsubscribing when not subscribed should not crash.
    ok = beam_agent_reload_bus:unsubscribe(),
    cleanup_tables().

%%====================================================================
%% Notification Tests
%%====================================================================

notify_sends_message_to_subscribers_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:notify(hooks),
    receive
        {beam_agent_reload, hooks, Version} ->
            ?assertEqual(1, Version)
    after 1000 ->
        ?assert(false)
    end,
    cleanup_tables().

notify_increments_version_monotonically_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:notify(hooks),
    ok = beam_agent_reload_bus:notify(skills),
    ok = beam_agent_reload_bus:notify(hooks),
    %% Drain all three messages
    Versions = collect_reload_versions(3),
    ?assertEqual([1, 2, 3], Versions),
    cleanup_tables().

notify_prunes_dead_subscribers_test() ->
    setup(),
    %% Spawn a process that exits immediately
    Pid = spawn(fun() -> ok end),
    timer:sleep(50),  %% Ensure it's dead
    ok = beam_agent_reload_bus:subscribe(Pid),
    ?assert(lists:member({Pid}, ets:tab2list(beam_agent_reload_subscribers))),
    %% Notify should prune the dead subscriber
    ok = beam_agent_reload_bus:notify(hooks),
    timer:sleep(50),
    ?assertNot(lists:member({Pid}, ets:tab2list(beam_agent_reload_subscribers))),
    cleanup_tables().

notify_sends_correct_type_test() ->
    setup(),
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:notify(skills),
    receive
        {beam_agent_reload, Type, _} ->
            ?assertEqual(skills, Type)
    after 1000 ->
        ?assert(false)
    end,
    cleanup_tables().

%%====================================================================
%% Version Tests
%%====================================================================

version_returns_zero_before_tables_created_test() ->
    cleanup_tables(),
    ?assertEqual(0, beam_agent_reload_bus:version()).

version_reflects_notify_count_test() ->
    setup(),
    ?assertEqual(0, beam_agent_reload_bus:version()),
    ok = beam_agent_reload_bus:notify(hooks),
    ?assertEqual(1, beam_agent_reload_bus:version()),
    ok = beam_agent_reload_bus:notify(tools),
    ?assertEqual(2, beam_agent_reload_bus:version()),
    cleanup_tables().

%%====================================================================
%% Graceful Degradation Tests
%%====================================================================

operations_before_tables_safe_test() ->
    cleanup_tables(),
    %% All operations should return ok even without tables
    ok = beam_agent_reload_bus:subscribe(),
    ok = beam_agent_reload_bus:unsubscribe(),
    ok = beam_agent_reload_bus:notify(hooks),
    ?assertEqual(0, beam_agent_reload_bus:version()).

%%====================================================================
%% Internal Helpers
%%====================================================================

collect_reload_versions(0) -> [];
collect_reload_versions(N) ->
    receive
        {beam_agent_reload, _Type, V} ->
            [V | collect_reload_versions(N - 1)]
    after 1000 ->
        []
    end.
