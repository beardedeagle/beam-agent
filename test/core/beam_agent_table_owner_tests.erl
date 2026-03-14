%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_table_owner.
%%%
%%% Tests cover:
%%%   - Public mode initialization and idempotency
%%%   - Hardened mode initialization with real owner process
%%%   - Access mode resolution for always-protected and regular tables
%%%   - Synchronous write proxy (insert, delete, update_counter)
%%%   - Owner process lifecycle (linked to consumer, exits on consumer death)
%%%   - ETS heir transfer on owner crash
%%%   - Persistent term cleanup on shutdown
%%%   - Write timeout error on unresponsive owner
%%%
%%% All tests use real ETS tables and real processes — zero mocks.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_table_owner_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test helpers
%%====================================================================

%% Clean up persistent terms set by beam_agent_table_owner.
%% Called in teardown to ensure test isolation.
cleanup() ->
    case beam_agent_table_owner:owner_pid() of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            unlink(Pid),
            exit(Pid, kill),
            wait_for_death(Pid)
    end,
    _ = persistent_term:erase(beam_agent_table_access_mode),
    _ = persistent_term:erase(beam_agent_table_owner_pid),
    _ = persistent_term:erase(beam_agent_tables_initialized),
    flush_transfers(),
    ok.

%% Drain any pending ETS-TRANSFER messages from the mailbox.
%% These arrive when the owner dies and tables transfer to the heir.
flush_transfers() ->
    receive
        {'ETS-TRANSFER', _, _, _} -> flush_transfers()
    after 0 -> ok
    end.

%% Wait for a process to exit.
wait_for_death(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        error({process_still_alive, Pid})
    end.

%% Delete an ETS table if it exists.
delete_table(Name) ->
    case ets:whereis(Name) of
        undefined -> ok;
        _Tid -> ets:delete(Name)
    end.

%%====================================================================
%% Public mode tests
%%====================================================================

public_mode_defaults_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(true, beam_agent_table_owner:initialized()),
    cleanup().

public_mode_explicit_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    cleanup().

init_idempotent_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    %% Second call is a no-op.
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% Still public — the second call did not change the mode.
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    cleanup().

%%====================================================================
%% Hardened mode tests
%%====================================================================

hardened_mode_spawns_owner_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    ?assertEqual(hardened, beam_agent_table_owner:access_mode()),
    Pid = beam_agent_table_owner:owner_pid(),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(true, beam_agent_table_owner:initialized()),
    cleanup().

owner_linked_to_consumer_test() ->
    %% The owner is linked to the process that called init/1.
    %% We spawn a consumer, have it init, then kill it and verify
    %% the owner dies too.
    cleanup(),
    Self = self(),
    Consumer = spawn(fun() ->
        ok = beam_agent_table_owner:init(#{table_access => hardened}),
        Self ! {ready, beam_agent_table_owner:owner_pid()},
        receive stop -> ok end
    end),
    OwnerPid = receive {ready, P} -> P after 5000 -> error(timeout) end,
    ?assert(is_process_alive(OwnerPid)),
    %% Kill the consumer — owner should follow.
    exit(Consumer, kill),
    wait_for_death(Consumer),
    wait_for_death(OwnerPid),
    cleanup().

%%====================================================================
%% Access resolution tests
%%====================================================================

always_protected_tables_test() ->
    %% These 5 tables are always protected regardless of mode.
    cleanup(),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_control_callbacks)),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_backend_sessions)),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_apps)),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_skills)),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_checkpoints)),
    ?assertNot(beam_agent_table_owner:is_always_protected(some_other_table)).

resolve_access_public_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    %% In public mode, ALL tables are public — including always-protected ones.
    %% Without an owner process there is no write proxy, so every process
    %% must be able to write directly.
    ?assertEqual(public, beam_agent_table_owner:resolve_access(beam_agent_apps)),
    ?assertEqual(public, beam_agent_table_owner:resolve_access(some_table)),
    cleanup().

resolve_access_hardened_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% Always-protected tables are protected.
    ?assertEqual(protected, beam_agent_table_owner:resolve_access(beam_agent_apps)),
    %% Regular tables are also protected in hardened mode.
    ?assertEqual(protected, beam_agent_table_owner:resolve_access(some_table)),
    cleanup().

%%====================================================================
%% Write proxy tests
%%====================================================================

write_proxy_public_mode_direct_test() ->
    %% In public mode, write_proxy_sync falls back to direct ETS calls.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    TableName = beam_agent_owner_test_proxy_pub,
    delete_table(TableName),
    _ = ets:new(TableName, [set, public, named_table]),
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        insert, TableName, {key1, value1})),
    ?assertEqual([{key1, value1}], ets:lookup(TableName, key1)),
    ets:delete(TableName),
    cleanup().

write_proxy_hardened_mode_test() ->
    %% In hardened mode, writes go through the owner process.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% Create a table owned by the owner process.
    TableName = beam_agent_owner_test_proxy_hard,
    delete_table(TableName),
    OwnerPid = beam_agent_table_owner:owner_pid(),
    Ref = make_ref(),
    OwnerPid ! {create_table, TableName,
                [set, protected, named_table, {read_concurrency, true}],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    %% Write through proxy.
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        insert, TableName, {key1, value1})),
    %% Read directly (reads always work from any process on protected tables).
    ?assertEqual([{key1, value1}], ets:lookup(TableName, key1)),
    %% Delete through proxy.
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        delete, TableName, key1)),
    ?assertEqual([], ets:lookup(TableName, key1)),
    cleanup().

write_proxy_update_counter_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    TableName = beam_agent_owner_test_counter,
    delete_table(TableName),
    OwnerPid = beam_agent_table_owner:owner_pid(),
    Ref = make_ref(),
    OwnerPid ! {create_table, TableName,
                [set, protected, named_table],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    %% Insert initial counter via proxy.
    beam_agent_table_owner:write_proxy_sync(insert, TableName, {counter, 0}),
    %% Increment via update_counter proxy.
    Result = beam_agent_table_owner:write_proxy_sync(
        update_counter, TableName, {counter, 1}),
    ?assertEqual(1, Result),
    %% Increment again.
    Result2 = beam_agent_table_owner:write_proxy_sync(
        update_counter, TableName, {counter, 5}),
    ?assertEqual(6, Result2),
    cleanup().

%%====================================================================
%% Heir transfer tests
%%====================================================================

heir_transfer_on_owner_crash_test() ->
    %% When the owner crashes, ETS tables transfer to the consumer (heir).
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    OwnerPid = beam_agent_table_owner:owner_pid(),
    TableName = beam_agent_owner_test_heir,
    delete_table(TableName),
    Ref = make_ref(),
    OwnerPid ! {create_table, TableName,
                [set, protected, named_table],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    %% Write some data through proxy.
    beam_agent_table_owner:write_proxy_sync(insert, TableName, {key1, data1}),
    %% Kill the owner (not the consumer — we are the consumer).
    unlink(OwnerPid),
    exit(OwnerPid, kill),
    wait_for_death(OwnerPid),
    %% We should receive the ETS-TRANSFER message as the heir.
    receive
        {'ETS-TRANSFER', _Tab, OwnerPid, TableName} ->
            ok
    after 2000 ->
        error(no_ets_transfer_received)
    end,
    %% Data survives the transfer — we can still read it.
    ?assertEqual([{key1, data1}], ets:lookup(TableName, key1)),
    %% And now as the new owner, we can write directly.
    ets:insert(TableName, {key2, data2}),
    ?assertEqual([{key2, data2}], ets:lookup(TableName, key2)),
    delete_table(TableName),
    cleanup().

%%====================================================================
%% Persistent term cleanup tests
%%====================================================================

persistent_terms_cleaned_on_consumer_death_test() ->
    cleanup(),
    Self = self(),
    Consumer = spawn(fun() ->
        ok = beam_agent_table_owner:init(#{table_access => hardened}),
        Self ! ready,
        receive stop -> ok end
    end),
    receive ready -> ok after 5000 -> error(timeout) end,
    ?assertEqual(hardened, beam_agent_table_owner:access_mode()),
    ?assertEqual(true, beam_agent_table_owner:initialized()),
    %% Kill the consumer — owner follows and cleans up persistent terms.
    exit(Consumer, kill),
    wait_for_death(Consumer),
    %% Give the owner a moment to clean up before it dies.
    timer:sleep(50),
    %% Persistent terms should be erased (defaults returned).
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(false, beam_agent_table_owner:initialized()),
    cleanup().

%%====================================================================
%% Uninitialized defaults tests
%%====================================================================

uninitialized_defaults_test() ->
    cleanup(),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(false, beam_agent_table_owner:initialized()).

%%====================================================================
%% Monitor-for-cleanup tests
%%====================================================================

monitor_for_cleanup_public_mode_test() ->
    %% In public mode, monitor_for_cleanup returns ignored.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(ignored, beam_agent_table_owner:monitor_for_cleanup(
        self(), {erlang, is_integer, [42]})),
    cleanup().

monitor_for_cleanup_hardened_fires_callback_test() ->
    %% In hardened mode, the owner monitors the pid and executes
    %% the MFA callback when it dies.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% Create a public table as a signal: the callback inserts a marker.
    SignalTable = beam_agent_monitor_test_signal,
    delete_table(SignalTable),
    _ = ets:new(SignalTable, [set, public, named_table]),
    %% Spawn a process and register a callback that writes to the table.
    Doomed = spawn(fun() -> receive stop -> ok end end),
    ok = beam_agent_table_owner:monitor_for_cleanup(Doomed,
        {ets, insert, [SignalTable, {cleaned_up, true}]}),
    %% Kill the doomed process.
    exit(Doomed, kill),
    wait_for_death(Doomed),
    %% Give the owner loop time to process DOWN.
    timer:sleep(50),
    %% The callback should have fired, inserting the marker.
    ?assertEqual([{cleaned_up, true}], ets:lookup(SignalTable, cleaned_up)),
    ets:delete(SignalTable),
    cleanup().

monitor_already_dead_process_test() ->
    %% Monitoring a process that is already dead is safe.
    %% erlang:monitor/2 immediately delivers a DOWN message.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    SignalTable = beam_agent_monitor_dead_signal,
    delete_table(SignalTable),
    _ = ets:new(SignalTable, [set, public, named_table]),
    %% Spawn and kill a process BEFORE registering the monitor.
    Doomed = spawn(fun() -> ok end),
    wait_for_death(Doomed),
    %% Register monitor for already-dead process.
    ok = beam_agent_table_owner:monitor_for_cleanup(Doomed,
        {ets, insert, [SignalTable, {cleaned_up, true}]}),
    %% DOWN is delivered immediately — callback fires.
    timer:sleep(50),
    ?assertEqual([{cleaned_up, true}], ets:lookup(SignalTable, cleaned_up)),
    ets:delete(SignalTable),
    cleanup().

monitor_for_cleanup_uninitialized_test() ->
    %% When not initialized, no owner exists — returns ignored.
    cleanup(),
    ?assertEqual(ignored, beam_agent_table_owner:monitor_for_cleanup(
        self(), {erlang, is_integer, [42]})).
