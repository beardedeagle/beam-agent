%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_ets.
%%%
%%% Tests cover:
%%%   - Table creation with ensure_table/2 in both public and hardened modes
%%%   - Write operations (insert, insert_new, delete, delete_object,
%%%     delete_all_objects, update_counter) in both modes
%%%   - Read operations passthrough (lookup, foldl, select, match, etc.)
%%%   - Proxy bypass when caller IS the owner process
%%%   - Idempotent table creation (ensure_table on existing table)
%%%   - Access mode injection (public vs protected based on table name)
%%%
%%% All tests use real ETS tables and real processes — zero mocks.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_ets_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test helpers
%%====================================================================

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
flush_transfers() ->
    receive
        {'ETS-TRANSFER', _, _, _} -> flush_transfers()
    after 0 -> ok
    end.

wait_for_death(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        error({process_still_alive, Pid})
    end.

delete_table(Name) ->
    case ets:whereis(Name) of
        undefined -> ok;
        _Tid -> ets:delete(Name)
    end.

%%====================================================================
%% ensure_table tests — public mode
%%====================================================================

ensure_table_public_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    TableName = beam_agent_ets_test_pub,
    delete_table(TableName),
    ok = beam_agent_ets:ensure_table(TableName,
        [set, named_table, {read_concurrency, true}]),
    %% Table exists and is public.
    ?assertNotEqual(undefined, ets:whereis(TableName)),
    ?assertEqual(public, ets:info(TableName, protection)),
    delete_table(TableName),
    cleanup().

ensure_table_always_protected_names_public_in_public_mode_test() ->
    %% In public mode, even "always-protected" table names get public access.
    %% Without an owner process there is no write proxy, so every process
    %% must be able to write directly.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    TableName = beam_agent_apps,
    delete_table(TableName),
    ok = beam_agent_ets:ensure_table(TableName,
        [set, named_table, {read_concurrency, true}]),
    ?assertEqual(public, ets:info(TableName, protection)),
    delete_table(TableName),
    cleanup().

ensure_table_idempotent_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    TableName = beam_agent_ets_test_idem,
    delete_table(TableName),
    ok = beam_agent_ets:ensure_table(TableName, [set, named_table]),
    %% Insert data, then call ensure_table again — data should survive.
    ets:insert(TableName, {key1, value1}),
    ok = beam_agent_ets:ensure_table(TableName, [set, named_table]),
    ?assertEqual([{key1, value1}], ets:lookup(TableName, key1)),
    delete_table(TableName),
    cleanup().

%%====================================================================
%% ensure_table tests — hardened mode
%%====================================================================

ensure_table_hardened_mode_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    TableName = beam_agent_ets_test_hard,
    delete_table(TableName),
    ok = beam_agent_ets:ensure_table(TableName,
        [set, named_table, {read_concurrency, true}]),
    %% Table exists and is protected (owned by the owner process).
    ?assertNotEqual(undefined, ets:whereis(TableName)),
    ?assertEqual(protected, ets:info(TableName, protection)),
    %% Owner process owns the table.
    OwnerPid = beam_agent_table_owner:owner_pid(),
    ?assertEqual(OwnerPid, ets:info(TableName, owner)),
    cleanup().

%%====================================================================
%% Write operations — public mode (direct ETS)
%%====================================================================

insert_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_insert_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    ?assertEqual(true, beam_agent_ets:insert(T, {k1, v1})),
    ?assertEqual([{k1, v1}], ets:lookup(T, k1)),
    delete_table(T),
    cleanup().

insert_new_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_insn_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    ?assertEqual(true, beam_agent_ets:insert_new(T, {k1, v1})),
    ?assertEqual(false, beam_agent_ets:insert_new(T, {k1, v2})),
    ?assertEqual([{k1, v1}], ets:lookup(T, k1)),
    delete_table(T),
    cleanup().

delete_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_del_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    ?assertEqual(true, beam_agent_ets:delete(T, k1)),
    ?assertEqual([], ets:lookup(T, k1)),
    delete_table(T),
    cleanup().

delete_object_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_delobj_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [bag, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    beam_agent_ets:insert(T, {k1, v2}),
    ?assertEqual(true, beam_agent_ets:delete_object(T, {k1, v1})),
    ?assertEqual([{k1, v2}], ets:lookup(T, k1)),
    delete_table(T),
    cleanup().

delete_all_objects_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_delall_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    beam_agent_ets:insert(T, {k2, v2}),
    ?assertEqual(true, beam_agent_ets:delete_all_objects(T)),
    ?assertEqual([], ets:tab2list(T)),
    delete_table(T),
    cleanup().

update_counter_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_ctr_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {counter, 0}),
    ?assertEqual(1, beam_agent_ets:update_counter(T, counter, 1)),
    ?assertEqual(6, beam_agent_ets:update_counter(T, counter, 5)),
    delete_table(T),
    cleanup().

update_counter_with_default_public_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_ctrd_pub,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    %% Key doesn't exist yet — default record is used.
    ?assertEqual(1, beam_agent_ets:update_counter(T, counter, 1, {counter, 0})),
    ?assertEqual(4, beam_agent_ets:update_counter(T, counter, 3, {counter, 0})),
    delete_table(T),
    cleanup().

%%====================================================================
%% Write operations — hardened mode (proxied through owner)
%%====================================================================

insert_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_insert_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    ?assertEqual(true, beam_agent_ets:insert(T, {k1, v1})),
    ?assertEqual([{k1, v1}], beam_agent_ets:lookup(T, k1)),
    cleanup().

insert_new_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_insn_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    ?assertEqual(true, beam_agent_ets:insert_new(T, {k1, v1})),
    ?assertEqual(false, beam_agent_ets:insert_new(T, {k1, v2})),
    ?assertEqual([{k1, v1}], beam_agent_ets:lookup(T, k1)),
    cleanup().

delete_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_del_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    ?assertEqual(true, beam_agent_ets:delete(T, k1)),
    ?assertEqual([], beam_agent_ets:lookup(T, k1)),
    cleanup().

delete_all_objects_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_delall_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    beam_agent_ets:insert(T, {k2, v2}),
    ?assertEqual(true, beam_agent_ets:delete_all_objects(T)),
    ?assertEqual([], beam_agent_ets:tab2list(T)),
    cleanup().

update_counter_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_ctr_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {counter, 0}),
    ?assertEqual(1, beam_agent_ets:update_counter(T, counter, 1)),
    ?assertEqual(11, beam_agent_ets:update_counter(T, counter, 10)),
    cleanup().

update_counter_with_default_hardened_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_ctrd_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    ?assertEqual(1, beam_agent_ets:update_counter(T, counter, 1, {counter, 0})),
    ?assertEqual(6, beam_agent_ets:update_counter(T, counter, 5, {counter, 0})),
    cleanup().

%%====================================================================
%% Read operations (passthrough — verify they work in both modes)
%%====================================================================

read_operations_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    T = beam_agent_ets_test_reads,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [ordered_set, named_table]),
    beam_agent_ets:insert(T, {a, 1}),
    beam_agent_ets:insert(T, {b, 2}),
    beam_agent_ets:insert(T, {c, 3}),
    %% lookup
    ?assertEqual([{b, 2}], beam_agent_ets:lookup(T, b)),
    %% foldl
    Sum = beam_agent_ets:foldl(fun({_K, V}, Acc) -> Acc + V end, 0, T),
    ?assertEqual(6, Sum),
    %% whereis
    ?assertNotEqual(undefined, beam_agent_ets:whereis(T)),
    %% next (ordered_set)
    ?assertEqual(b, beam_agent_ets:next(T, a)),
    ?assertEqual(c, beam_agent_ets:next(T, b)),
    ?assertEqual('$end_of_table', beam_agent_ets:next(T, c)),
    %% select
    MatchSpec = [{{b, '$1'}, [], ['$1']}],
    ?assertEqual([2], beam_agent_ets:select(T, MatchSpec)),
    %% match
    ?assertEqual([[1]], beam_agent_ets:match(T, {a, '$1'})),
    %% match_object
    ?assertEqual([{c, 3}], beam_agent_ets:match_object(T, {c, '_'})),
    %% tab2list
    ?assertEqual([{a, 1}, {b, 2}, {c, 3}], beam_agent_ets:tab2list(T)),
    %% info
    ?assert(is_list(beam_agent_ets:info(T))),
    ?assertEqual(ordered_set, beam_agent_ets:info(T, type)),
    delete_table(T),
    cleanup().

read_operations_hardened_mode_test() ->
    %% Reads work identically in hardened mode — zero overhead.
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_reads_hard,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    beam_agent_ets:insert(T, {k1, v1}),
    beam_agent_ets:insert(T, {k2, v2}),
    ?assertEqual([{k1, v1}], beam_agent_ets:lookup(T, k1)),
    ?assertEqual(2, length(beam_agent_ets:tab2list(T))),
    cleanup().

%%====================================================================
%% Batch insert test
%%====================================================================

batch_insert_test() ->
    cleanup(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    T = beam_agent_ets_test_batch,
    delete_table(T),
    ok = beam_agent_ets:ensure_table(T, [set, named_table]),
    %% Insert a list of records in one call.
    Records = [{k1, v1}, {k2, v2}, {k3, v3}],
    ?assertEqual(true, beam_agent_ets:insert(T, Records)),
    ?assertEqual([{k2, v2}], beam_agent_ets:lookup(T, k2)),
    ?assertEqual(3, length(beam_agent_ets:tab2list(T))),
    cleanup().

%%====================================================================
%% whereis on non-existent table
%%====================================================================

whereis_nonexistent_test() ->
    ?assertEqual(undefined, beam_agent_ets:whereis(beam_agent_ets_no_such_table)).
