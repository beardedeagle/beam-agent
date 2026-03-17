%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_store.
%%%-------------------------------------------------------------------
-module(beam_agent_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONFIG_TABLE, beam_agent_store_config).
-define(TABLE, beam_agent_store_test_table).
-define(COUNTER_TABLE, beam_agent_store_test_counter).
-define(ORDERED_TABLE, beam_agent_store_test_ordered).

ensure_tables_idempotent_test() ->
    ok = beam_agent_store:ensure_tables(),
    ok = beam_agent_store:ensure_tables(),
    reset().

default_config_uses_ets_adapter_test() ->
    reset(),
    ?assertEqual(beam_agent_store_ets, beam_agent_store:adapter_module(runs)),
    ?assertEqual(#{
        adapter => beam_agent_store_ets,
        options => #{}
    }, beam_agent_store:domain_config(runs)),
    reset().

configure_domain_accepts_explicit_ets_adapter_test() ->
    reset(),
    ok = beam_agent_store:configure_domain(runs, #{
        adapter => beam_agent_store_ets,
        options => #{mode => test}
    }),
    ?assertEqual(#{
        adapter => beam_agent_store_ets,
        options => #{mode => test}
    }, beam_agent_store:domain_config(runs)),
    ok = beam_agent_store:reset_domain(runs),
    ?assertEqual(#{
        adapter => beam_agent_store_ets,
        options => #{}
    }, beam_agent_store:domain_config(runs)),
    reset().

configure_domain_rejects_invalid_adapter_test() ->
    reset(),
    ?assertEqual({error, {invalid_adapter, lists}},
        beam_agent_store:configure_domain(runs, #{adapter => lists})),
    reset().

configure_domain_rejects_invalid_options_test() ->
    reset(),
    ?assertEqual({error, invalid_options},
        beam_agent_store:configure_domain(runs, #{
            adapter => beam_agent_store_ets,
            options => invalid
        })),
    reset().

ets_adapter_roundtrip_test() ->
    reset(),
    ok = beam_agent_store:ensure_table(test_domain, ?TABLE, [set, named_table,
        {read_concurrency, true}]),
    true = beam_agent_store:insert(test_domain, ?TABLE, {<<"key">>, value}),
    ?assertEqual([{<<"key">>, value}],
        beam_agent_store:lookup(test_domain, ?TABLE, <<"key">>)),
    true = beam_agent_store:delete(test_domain, ?TABLE, <<"key">>),
    ?assertEqual([], beam_agent_store:lookup(test_domain, ?TABLE, <<"key">>)),
    reset().

ets_adapter_counter_and_ordered_iteration_test() ->
    reset(),
    ok = beam_agent_store:ensure_table(test_domain, ?COUNTER_TABLE,
        [set, named_table]),
    ?assertEqual(1,
        beam_agent_store:update_counter(test_domain, ?COUNTER_TABLE,
            counter, {2, 1}, {counter, 0})),
    ?assertEqual(2,
        beam_agent_store:update_counter(test_domain, ?COUNTER_TABLE,
            counter, {2, 1})),
    ok = beam_agent_store:ensure_table(test_domain, ?ORDERED_TABLE,
        [ordered_set, named_table, {read_concurrency, true}]),
    true = beam_agent_store:insert(test_domain, ?ORDERED_TABLE, {1, one}),
    true = beam_agent_store:insert(test_domain, ?ORDERED_TABLE, {3, three}),
    ?assertEqual(1, beam_agent_store:first(test_domain, ?ORDERED_TABLE)),
    ?assertEqual(3, beam_agent_store:next(test_domain, ?ORDERED_TABLE, 1)),
    ?assertEqual('$end_of_table',
        beam_agent_store:next(test_domain, ?ORDERED_TABLE, 3)),
    reset().

reset() ->
    ok = beam_agent_store:clear(),
    clear_table(?TABLE),
    clear_table(?COUNTER_TABLE),
    clear_table(?ORDERED_TABLE),
    clear_table(?CONFIG_TABLE),
    ok.

clear_table(Table) ->
    case ets:whereis(Table) of
        undefined ->
            ok;
        _ ->
            true = beam_agent_ets:delete_all_objects(Table),
            ok
    end.
