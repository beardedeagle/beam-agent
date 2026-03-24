%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_store_dets.
%%%
%%% Tests cover all 12 beam_agent_store callbacks against real DETS
%%% files using ram_file mode for speed. No mocks, no test doubles.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_store_dets_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TABLE, beam_agent_dets_test_table).
-define(COUNTER_TABLE, beam_agent_dets_test_counter).
-define(BAG_TABLE, beam_agent_dets_test_bag).
-define(ORDERED_TABLE, beam_agent_dets_test_ordered).

-define(OPTS, #{data_dir => test_data_dir(), ram_file => true}).

%%====================================================================
%% Helpers
%%====================================================================

test_data_dir() ->
    filename:join(["/tmp", "beam_agent_dets_test_" ++
        integer_to_list(erlang:unique_integer([positive]))]).

cleanup_table(Table) ->
    beam_agent_store_dets:close_table(Table).

cleanup_all() ->
    lists:foreach(fun cleanup_table/1,
        [?TABLE, ?COUNTER_TABLE, ?BAG_TABLE, ?ORDERED_TABLE]).

%%====================================================================
%% ensure_table/3
%%====================================================================

ensure_table_creates_dets_file_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ?assertNotEqual(undefined, dets:info(?TABLE, type)),
    cleanup_all().

ensure_table_idempotent_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    cleanup_all().

ensure_table_bag_type_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?BAG_TABLE, [bag], ?OPTS),
    ?assertEqual(bag, dets:info(?BAG_TABLE, type)),
    cleanup_all().

ensure_table_ordered_set_downgrades_to_set_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?ORDERED_TABLE,
        [ordered_set], ?OPTS),
    ?assertEqual(set, dets:info(?ORDERED_TABLE, type)),
    cleanup_all().

%%====================================================================
%% insert/3, lookup/3, delete/3
%%====================================================================

insert_and_lookup_roundtrip_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {<<"k1">>, v1}, #{}),
    ?assertEqual([{<<"k1">>, v1}],
        beam_agent_store_dets:lookup(?TABLE, <<"k1">>, #{})),
    cleanup_all().

insert_overwrites_existing_key_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {key, old}, #{}),
    true = beam_agent_store_dets:insert(?TABLE, {key, new}, #{}),
    ?assertEqual([{key, new}],
        beam_agent_store_dets:lookup(?TABLE, key, #{})),
    cleanup_all().

delete_removes_key_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {<<"k1">>, v1}, #{}),
    true = beam_agent_store_dets:delete(?TABLE, <<"k1">>, #{}),
    ?assertEqual([],
        beam_agent_store_dets:lookup(?TABLE, <<"k1">>, #{})),
    cleanup_all().

lookup_missing_key_returns_empty_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ?assertEqual([],
        beam_agent_store_dets:lookup(?TABLE, nonexistent, #{})),
    cleanup_all().

%%====================================================================
%% insert_new/3
%%====================================================================

insert_new_succeeds_on_new_key_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ?assert(beam_agent_store_dets:insert_new(?TABLE, {key, val}, #{})),
    cleanup_all().

insert_new_fails_on_existing_key_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {key, val}, #{}),
    ?assertNot(beam_agent_store_dets:insert_new(?TABLE, {key, other}, #{})),
    cleanup_all().

%%====================================================================
%% delete_object/3
%%====================================================================

delete_object_removes_specific_record_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?BAG_TABLE, [bag], ?OPTS),
    true = beam_agent_store_dets:insert(?BAG_TABLE, {key, a}, #{}),
    true = beam_agent_store_dets:insert(?BAG_TABLE, {key, b}, #{}),
    true = beam_agent_store_dets:delete_object(?BAG_TABLE, {key, a}, #{}),
    ?assertEqual([{key, b}],
        beam_agent_store_dets:lookup(?BAG_TABLE, key, #{})),
    cleanup_all().

%%====================================================================
%% delete_all_objects/2
%%====================================================================

delete_all_objects_empties_table_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {a, 1}, #{}),
    true = beam_agent_store_dets:insert(?TABLE, {b, 2}, #{}),
    true = beam_agent_store_dets:delete_all_objects(?TABLE, #{}),
    ?assertEqual([], beam_agent_store_dets:lookup(?TABLE, a, #{})),
    ?assertEqual([], beam_agent_store_dets:lookup(?TABLE, b, #{})),
    cleanup_all().

%%====================================================================
%% update_counter/4,5
%%====================================================================

update_counter_with_default_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?COUNTER_TABLE, [set], ?OPTS),
    Result = beam_agent_store_dets:update_counter(
        ?COUNTER_TABLE, counter, {2, 1}, {counter, 0}, #{}),
    ?assertEqual(1, Result),
    cleanup_all().

update_counter_increments_existing_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?COUNTER_TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?COUNTER_TABLE, {counter, 10}, #{}),
    Result = beam_agent_store_dets:update_counter(
        ?COUNTER_TABLE, counter, {2, 5}, #{}),
    ?assertEqual(15, Result),
    cleanup_all().

update_counter_simple_increment_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?COUNTER_TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?COUNTER_TABLE, {counter, 0}, #{}),
    Result = beam_agent_store_dets:update_counter(
        ?COUNTER_TABLE, counter, 3, #{}),
    ?assertEqual(3, Result),
    cleanup_all().

%%====================================================================
%% foldl/4
%%====================================================================

foldl_accumulates_all_records_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {a, 1}, #{}),
    true = beam_agent_store_dets:insert(?TABLE, {b, 2}, #{}),
    true = beam_agent_store_dets:insert(?TABLE, {c, 3}, #{}),
    Sum = beam_agent_store_dets:foldl(
        fun({_K, V}, Acc) -> Acc + V end, 0, ?TABLE, #{}),
    ?assertEqual(6, Sum),
    cleanup_all().

%%====================================================================
%% first/2, next/3
%%====================================================================

first_and_next_iterate_all_keys_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {a, 1}, #{}),
    true = beam_agent_store_dets:insert(?TABLE, {b, 2}, #{}),
    K1 = beam_agent_store_dets:first(?TABLE, #{}),
    ?assertNotEqual('$end_of_table', K1),
    K2 = beam_agent_store_dets:next(?TABLE, K1, #{}),
    ?assertNotEqual('$end_of_table', K2),
    K3 = beam_agent_store_dets:next(?TABLE, K2, #{}),
    ?assertEqual('$end_of_table', K3),
    Keys = lists:sort([K1, K2]),
    ?assertEqual([a, b], Keys),
    cleanup_all().

first_on_empty_table_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ?assertEqual('$end_of_table',
        beam_agent_store_dets:first(?TABLE, #{})),
    cleanup_all().

%%====================================================================
%% close_table/1, sync_table/1
%%====================================================================

close_table_makes_info_undefined_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    ok = beam_agent_store_dets:close_table(?TABLE),
    ?assertEqual(undefined, dets:info(?TABLE, type)).

close_table_idempotent_test() ->
    ok = beam_agent_store_dets:close_table(nonexistent_table_xyz).

sync_table_flushes_without_error_test() ->
    cleanup_all(),
    ok = beam_agent_store_dets:ensure_table(?TABLE, [set], ?OPTS),
    true = beam_agent_store_dets:insert(?TABLE, {key, val}, #{}),
    ok = beam_agent_store_dets:sync_table(?TABLE),
    cleanup_all().

%%====================================================================
%% Store boundary integration — configure_domain + roundtrip
%%====================================================================

store_boundary_dets_roundtrip_test() ->
    cleanup_all(),
    ok = beam_agent_store:ensure_tables(),
    ok = beam_agent_store:configure_domain(dets_test_domain, #{
        adapter => beam_agent_store_dets,
        options => ?OPTS
    }),
    TestTable = beam_agent_dets_integration_test,
    ok = beam_agent_store:ensure_table(dets_test_domain, TestTable, [set]),
    true = beam_agent_store:insert(dets_test_domain, TestTable, {<<"key">>, value}),
    ?assertEqual([{<<"key">>, value}],
        beam_agent_store:lookup(dets_test_domain, TestTable, <<"key">>)),
    true = beam_agent_store:delete(dets_test_domain, TestTable, <<"key">>),
    ?assertEqual([],
        beam_agent_store:lookup(dets_test_domain, TestTable, <<"key">>)),
    beam_agent_store_dets:close_table(TestTable),
    beam_agent_store:reset_domain(dets_test_domain),
    beam_agent_store:clear(),
    cleanup_all().

data_dir_defaults_test() ->
    ?assertEqual("beam_agent_data",
        beam_agent_store_dets:data_dir(#{})).

data_dir_binary_test() ->
    ?assertEqual("/tmp/custom",
        beam_agent_store_dets:data_dir(#{data_dir => <<"/tmp/custom">>})).

data_dir_string_test() ->
    ?assertEqual("/tmp/custom",
        beam_agent_store_dets:data_dir(#{data_dir => "/tmp/custom"})).
