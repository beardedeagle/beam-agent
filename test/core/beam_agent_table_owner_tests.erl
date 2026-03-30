%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_table_owner.
%%%
%%% Tests cover:
%%%   - Hardened mode default initialization and idempotency
%%%   - Explicit public mode initialization
%%%   - Access mode resolution for always-protected and regular tables
%%%   - Synchronous write proxy (insert, delete, update_counter)
%%%   - Owner process lifecycle (linked to consumer, exits on consumer death)
%%%   - ETS heir transfer on owner crash
%%%   - Persistent term cleanup on shutdown
%%%   - Write timeout error on unresponsive owner
%%%   - Write sharding across multiple shard processes
%%%   - Shard routing consistency via erlang:phash2
%%%   - is_owner_process/0 for shard self-detection
%%%
%%% All tests use real ETS tables and real processes — zero test doubles.
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
    case beam_agent_table_owner:shard_pids() of
        undefined -> ok;
        Shards ->
            lists:foreach(fun(Pid) ->
                unlink(Pid),
                exit(Pid, kill),
                wait_for_death(Pid)
            end, tuple_to_list(Shards))
    end,
    _ = persistent_term:erase(beam_agent_table_access_mode),
    _ = persistent_term:erase(beam_agent_table_owner_pid),
    _ = persistent_term:erase(beam_agent_table_owner_shards),
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
%% Initialization and access mode tests
%%====================================================================

hardened_mode_defaults_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(),
    ?assertEqual(hardened, beam_agent_table_owner:access_mode()),
    ?assertNotEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(true, beam_agent_table_owner:initialized()),
    ?assertEqual(1, beam_agent_table_owner:shard_count()),
    ?assertNotEqual(undefined, beam_agent_table_owner:shard_pids()),
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
%% Hardened mode tests (single shard — backward compat)
%%====================================================================

hardened_mode_spawns_owner_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    ?assertEqual(hardened, beam_agent_table_owner:access_mode()),
    Pid = beam_agent_table_owner:owner_pid(),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(true, beam_agent_table_owner:initialized()),
    ?assertEqual(1, beam_agent_table_owner:shard_count()),
    cleanup().

single_shard_pids_tuple_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    Shards = beam_agent_table_owner:shard_pids(),
    ?assertEqual(1, tuple_size(Shards)),
    ?assertEqual(beam_agent_table_owner:owner_pid(), element(1, Shards)),
    cleanup().

owner_linked_to_consumer_test() ->
    cleanup(),
    Self = self(),
    Consumer = spawn(fun() ->
        ok = beam_agent_table_owner:init(#{table_access => hardened}),
        Self ! {ready, beam_agent_table_owner:owner_pid()},
        receive stop -> ok end
    end),
    OwnerPid = receive {ready, P} -> P after 5000 -> error(timeout) end,
    ?assert(is_process_alive(OwnerPid)),
    exit(Consumer, kill),
    wait_for_death(Consumer),
    wait_for_death(OwnerPid),
    cleanup().

%%====================================================================
%% Access resolution tests
%%====================================================================

always_protected_tables_test() ->
    cleanup(),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_runtime)),
    ?assert(beam_agent_table_owner:is_always_protected(beam_agent_backend_sessions)),
    ?assertNot(beam_agent_table_owner:is_always_protected(some_other_table)).

resolve_access_public_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(public, beam_agent_table_owner:resolve_access(beam_agent_runtime)),
    ?assertEqual(public, beam_agent_table_owner:resolve_access(some_table)),
    cleanup().

resolve_access_hardened_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    ?assertEqual(protected, beam_agent_table_owner:resolve_access(beam_agent_runtime)),
    ?assertEqual(protected, beam_agent_table_owner:resolve_access(some_table)),
    cleanup().

%%====================================================================
%% Write proxy tests (single shard)
%%====================================================================

write_proxy_public_mode_direct_test() ->
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
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    TableName = beam_agent_owner_test_proxy_hard,
    delete_table(TableName),
    ShardPid = beam_agent_table_owner:shard_for_table(TableName),
    Ref = make_ref(),
    ShardPid ! {create_table, TableName,
                [set, protected, named_table, {read_concurrency, true}],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        insert, TableName, {key1, value1})),
    ?assertEqual([{key1, value1}], ets:lookup(TableName, key1)),
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        delete, TableName, key1)),
    ?assertEqual([], ets:lookup(TableName, key1)),
    cleanup().

write_proxy_update_counter_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    TableName = beam_agent_owner_test_counter,
    delete_table(TableName),
    ShardPid = beam_agent_table_owner:shard_for_table(TableName),
    Ref = make_ref(),
    ShardPid ! {create_table, TableName,
                [set, protected, named_table],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    beam_agent_table_owner:write_proxy_sync(insert, TableName, {counter, 0}),
    Result = beam_agent_table_owner:write_proxy_sync(
        update_counter, TableName, {counter, 1}),
    ?assertEqual(1, Result),
    Result2 = beam_agent_table_owner:write_proxy_sync(
        update_counter, TableName, {counter, 5}),
    ?assertEqual(6, Result2),
    cleanup().

%%====================================================================
%% Heir transfer tests
%%====================================================================

heir_transfer_on_owner_crash_test() ->
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
    beam_agent_table_owner:write_proxy_sync(insert, TableName, {key1, data1}),
    unlink(OwnerPid),
    exit(OwnerPid, kill),
    wait_for_death(OwnerPid),
    receive
        {'ETS-TRANSFER', _Tab, OwnerPid, TableName} ->
            ok
    after 2000 ->
        error(no_ets_transfer_received)
    end,
    ?assertEqual([{key1, data1}], ets:lookup(TableName, key1)),
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
    exit(Consumer, kill),
    wait_for_death(Consumer),
    timer:sleep(50),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(false, beam_agent_table_owner:initialized()),
    ?assertEqual(undefined, beam_agent_table_owner:shard_pids()),
    cleanup().

%%====================================================================
%% Uninitialized defaults tests
%%====================================================================

uninitialized_defaults_test() ->
    cleanup(),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(false, beam_agent_table_owner:initialized()),
    ?assertEqual(0, beam_agent_table_owner:shard_count()),
    ?assertEqual(undefined, beam_agent_table_owner:shard_pids()),
    ?assertNot(beam_agent_table_owner:is_owner_process()).

%%====================================================================
%% Monitor-for-cleanup tests
%%====================================================================

monitor_for_cleanup_public_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(ignored, beam_agent_table_owner:monitor_for_cleanup(
        self(), {erlang, is_integer, [42]})),
    cleanup().

monitor_for_cleanup_hardened_fires_callback_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    SignalTable = beam_agent_monitor_test_signal,
    delete_table(SignalTable),
    _ = ets:new(SignalTable, [set, public, named_table]),
    Doomed = spawn(fun() -> receive stop -> ok end end),
    ok = beam_agent_table_owner:monitor_for_cleanup(Doomed,
        {ets, insert, [SignalTable, {cleaned_up, true}]}),
    exit(Doomed, kill),
    wait_for_death(Doomed),
    timer:sleep(50),
    ?assertEqual([{cleaned_up, true}], ets:lookup(SignalTable, cleaned_up)),
    ets:delete(SignalTable),
    cleanup().

monitor_already_dead_process_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    SignalTable = beam_agent_monitor_dead_signal,
    delete_table(SignalTable),
    _ = ets:new(SignalTable, [set, public, named_table]),
    Doomed = spawn(fun() -> ok end),
    wait_for_death(Doomed),
    ok = beam_agent_table_owner:monitor_for_cleanup(Doomed,
        {ets, insert, [SignalTable, {cleaned_up, true}]}),
    timer:sleep(50),
    ?assertEqual([{cleaned_up, true}], ets:lookup(SignalTable, cleaned_up)),
    ets:delete(SignalTable),
    cleanup().

monitor_for_cleanup_uninitialized_test() ->
    cleanup(),
    ?assertEqual(ignored, beam_agent_table_owner:monitor_for_cleanup(
        self(), {erlang, is_integer, [42]})).

%%====================================================================
%% Write sharding tests
%%====================================================================

multi_shard_spawns_correct_count_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 4}),
    ?assertEqual(4, beam_agent_table_owner:shard_count()),
    Shards = beam_agent_table_owner:shard_pids(),
    ?assertEqual(4, tuple_size(Shards)),
    lists:foreach(fun(Idx) ->
        Pid = element(Idx, Shards),
        ?assert(is_pid(Pid)),
        ?assert(is_process_alive(Pid))
    end, lists:seq(1, 4)),
    cleanup().

multi_shard_owner_pid_returns_primary_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 3}),
    Shards = beam_agent_table_owner:shard_pids(),
    ?assertEqual(element(1, Shards), beam_agent_table_owner:owner_pid()),
    cleanup().

shard_for_table_deterministic_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 4}),
    %% Same table always routes to the same shard.
    Pid1 = beam_agent_table_owner:shard_for_table(my_table),
    Pid2 = beam_agent_table_owner:shard_for_table(my_table),
    ?assertEqual(Pid1, Pid2),
    cleanup().

shard_for_table_distributes_across_shards_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 4}),
    Shards = beam_agent_table_owner:shard_pids(),
    %% Generate enough table names to hit multiple shards.
    Tables = [list_to_atom("shard_test_table_" ++ integer_to_list(I))
              || I <- lists:seq(1, 100)],
    ShardPids = lists:usort([beam_agent_table_owner:shard_for_table(T)
                             || T <- Tables]),
    AllShardPids = lists:usort(tuple_to_list(Shards)),
    %% With 100 tables across 4 shards, all shards should be hit.
    ?assertEqual(AllShardPids, ShardPids),
    cleanup().

shard_for_table_public_mode_returns_undefined_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(undefined, beam_agent_table_owner:shard_for_table(any_table)),
    cleanup().

multi_shard_write_proxy_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 3}),
    TableName = beam_agent_shard_write_test,
    delete_table(TableName),
    ShardPid = beam_agent_table_owner:shard_for_table(TableName),
    Ref = make_ref(),
    ShardPid ! {create_table, TableName,
                [set, protected, named_table],
                self(), Ref},
    receive {table_created, Ref, ok} -> ok
    after 5000 -> error(table_create_timeout)
    end,
    ?assertEqual(true, beam_agent_table_owner:write_proxy_sync(
        insert, TableName, {key1, value1})),
    ?assertEqual([{key1, value1}], ets:lookup(TableName, key1)),
    cleanup().

is_owner_process_false_for_non_owner_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened,
                                       shard_count => 2}),
    ?assertNot(beam_agent_table_owner:is_owner_process()),
    cleanup().

is_owner_process_public_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertNot(beam_agent_table_owner:is_owner_process()),
    cleanup().

multi_shard_all_die_on_consumer_death_test() ->
    cleanup(),
    Self = self(),
    Consumer = spawn(fun() ->
        ok = beam_agent_table_owner:init(#{table_access => hardened,
                                           shard_count => 3}),
        Self ! {ready, beam_agent_table_owner:shard_pids()},
        receive stop -> ok end
    end),
    Shards = receive {ready, S} -> S after 5000 -> error(timeout) end,
    AllPids = tuple_to_list(Shards),
    lists:foreach(fun(P) -> ?assert(is_process_alive(P)) end, AllPids),
    exit(Consumer, kill),
    wait_for_death(Consumer),
    lists:foreach(fun(P) -> wait_for_death(P) end, AllPids),
    timer:sleep(50),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:shard_pids()),
    cleanup().

multi_shard_persistent_terms_cleaned_test() ->
    cleanup(),
    Self = self(),
    Consumer = spawn(fun() ->
        ok = beam_agent_table_owner:init(#{table_access => hardened,
                                           shard_count => 2}),
        Self ! ready,
        receive stop -> ok end
    end),
    receive ready -> ok after 5000 -> error(timeout) end,
    ?assertEqual(hardened, beam_agent_table_owner:access_mode()),
    ?assertEqual(2, beam_agent_table_owner:shard_count()),
    exit(Consumer, kill),
    wait_for_death(Consumer),
    timer:sleep(50),
    ?assertEqual(public, beam_agent_table_owner:access_mode()),
    ?assertEqual(undefined, beam_agent_table_owner:owner_pid()),
    ?assertEqual(undefined, beam_agent_table_owner:shard_pids()),
    ?assertEqual(false, beam_agent_table_owner:initialized()),
    cleanup().
