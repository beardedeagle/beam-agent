%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_plan_cache_core.
%%%
%%% Tests the agentic plan caching engine including quality tracking
%%% and quality-based eviction.  No mocks — real ETS tables.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_plan_cache_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_plan_cache_core:ensure_tables(),
    beam_agent_plan_cache_core:clear(),
    ok.

make_key(Task) ->
    beam_agent_plan_cache_core:plan_key(claude, <<"opus-4">>, Task).

make_plan(Steps) ->
    #{steps => Steps,
      task_signature => <<"test task">>,
      step_count => length(Steps)}.

make_step(Tool, Order) ->
    #{tool => Tool, description => <<"step">>, order => Order}.

simple_plan() ->
    make_plan([
        make_step(<<"run_tests">>, 1),
        make_step(<<"report">>, 2)
    ]).

%%====================================================================
%% plan_key/3,4
%%====================================================================

plan_key_deterministic_test() ->
    setup(),
    K1 = make_key(<<"build project">>),
    K2 = make_key(<<"build project">>),
    ?assertEqual(K1, K2).

plan_key_is_32_bytes_test() ->
    setup(),
    K = make_key(<<"task">>),
    ?assertEqual(32, byte_size(K)).

plan_key_different_tasks_differ_test() ->
    setup(),
    K1 = make_key(<<"run tests">>),
    K2 = make_key(<<"deploy app">>),
    ?assertNotEqual(K1, K2).

plan_key_different_backends_differ_test() ->
    setup(),
    K1 = beam_agent_plan_cache_core:plan_key(claude, <<"m">>, <<"t">>),
    K2 = beam_agent_plan_cache_core:plan_key(codex, <<"m">>, <<"t">>),
    ?assertNotEqual(K1, K2).

plan_key_different_models_differ_test() ->
    setup(),
    K1 = beam_agent_plan_cache_core:plan_key(claude, <<"opus">>, <<"t">>),
    K2 = beam_agent_plan_cache_core:plan_key(claude, <<"sonnet">>, <<"t">>),
    ?assertNotEqual(K1, K2).

plan_key_normalizes_whitespace_test() ->
    setup(),
    K1 = make_key(<<"run tests">>),
    K2 = make_key(<<"  run tests  ">>),
    ?assertEqual(K1, K2).

plan_key_4_context_differentiates_test() ->
    setup(),
    K1 = beam_agent_plan_cache_core:plan_key(
        claude, <<"m">>, <<"t">>, <<>>),
    K2 = beam_agent_plan_cache_core:plan_key(
        claude, <<"m">>, <<"t">>, <<"/project-a">>),
    ?assertNotEqual(K1, K2).

plan_key_3_equals_key_4_empty_context_test() ->
    setup(),
    K3 = beam_agent_plan_cache_core:plan_key(claude, <<"m">>, <<"t">>),
    K4 = beam_agent_plan_cache_core:plan_key(
        claude, <<"m">>, <<"t">>, <<>>),
    ?assertEqual(K3, K4).

%%====================================================================
%% put/3 + get/1 round-trip
%%====================================================================

put_get_roundtrip_test() ->
    setup(),
    K = make_key(<<"roundtrip">>),
    Plan = simple_plan(),
    ok = beam_agent_plan_cache_core:put(K, Plan, #{}),
    ?assertMatch({hit, Plan, _}, beam_agent_plan_cache_core:get(K)).

get_miss_on_empty_cache_test() ->
    setup(),
    K = make_key(<<"ghost">>),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(K)).

get_miss_after_invalidate_test() ->
    setup(),
    K = make_key(<<"invalidate">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    ok = beam_agent_plan_cache_core:invalidate(K),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(K)).

get_hit_metadata_has_expected_keys_test() ->
    setup(),
    K = make_key(<<"meta">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    {hit, _, Meta} = beam_agent_plan_cache_core:get(K),
    ?assert(maps:is_key(inserted_at, Meta)),
    ?assert(maps:is_key(expires_at, Meta)),
    ?assert(maps:is_key(byte_estimate, Meta)),
    ?assert(maps:is_key(age_ms, Meta)),
    ?assert(maps:is_key(success_count, Meta)),
    ?assert(maps:is_key(failure_count, Meta)),
    ?assert(maps:is_key(success_rate, Meta)).

put_overwrites_existing_test() ->
    setup(),
    K = make_key(<<"overwrite">>),
    P1 = make_plan([make_step(<<"old">>, 1)]),
    P2 = make_plan([make_step(<<"new">>, 1)]),
    ok = beam_agent_plan_cache_core:put(K, P1, #{}),
    ok = beam_agent_plan_cache_core:put(K, P2, #{}),
    {hit, Retrieved, _} = beam_agent_plan_cache_core:get(K),
    ?assertEqual(P2, Retrieved).

%%====================================================================
%% TTL expiry
%%====================================================================

get_miss_after_ttl_expires_test() ->
    setup(),
    K = make_key(<<"ttl-expire">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{ttl => 1}),
    timer:sleep(5),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(K)).

get_hit_within_ttl_test() ->
    setup(),
    K = make_key(<<"ttl-alive">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(),
        #{ttl => 60_000}),
    ?assertMatch({hit, _, _}, beam_agent_plan_cache_core:get(K)).

%%====================================================================
%% Quality tracking
%%====================================================================

record_success_increments_counter_test() ->
    setup(),
    K = make_key(<<"quality-s">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    ok = beam_agent_plan_cache_core:record_success(K),
    ok = beam_agent_plan_cache_core:record_success(K),
    ok = beam_agent_plan_cache_core:record_success(K),
    {hit, _, Meta} = beam_agent_plan_cache_core:get(K),
    ?assertEqual(3, maps:get(success_count, Meta)),
    ?assertEqual(0, maps:get(failure_count, Meta)).

record_failure_increments_counter_test() ->
    setup(),
    K = make_key(<<"quality-f">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    ok = beam_agent_plan_cache_core:record_failure(K),
    ok = beam_agent_plan_cache_core:record_failure(K),
    {hit, _, Meta} = beam_agent_plan_cache_core:get(K),
    ?assertEqual(0, maps:get(success_count, Meta)),
    ?assertEqual(2, maps:get(failure_count, Meta)).

success_rate_computed_correctly_test() ->
    setup(),
    K = make_key(<<"rate">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    ok = beam_agent_plan_cache_core:record_success(K),
    ok = beam_agent_plan_cache_core:record_success(K),
    ok = beam_agent_plan_cache_core:record_success(K),
    ok = beam_agent_plan_cache_core:record_failure(K),
    {hit, _, Meta} = beam_agent_plan_cache_core:get(K),
    %% 3 successes, 1 failure = 75% success rate
    ?assertEqual(0.75, maps:get(success_rate, Meta)).

success_rate_defaults_to_one_when_no_executions_test() ->
    setup(),
    K = make_key(<<"no-exec">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    {hit, _, Meta} = beam_agent_plan_cache_core:get(K),
    ?assertEqual(1.0, maps:get(success_rate, Meta)).

record_success_on_missing_key_is_noop_test() ->
    setup(),
    K = make_key(<<"missing">>),
    ?assertEqual(ok, beam_agent_plan_cache_core:record_success(K)).

record_failure_on_missing_key_is_noop_test() ->
    setup(),
    K = make_key(<<"missing">>),
    ?assertEqual(ok, beam_agent_plan_cache_core:record_failure(K)).

%%====================================================================
%% evict_low_quality/1
%%====================================================================

evict_low_quality_removes_bad_plans_test() ->
    setup(),
    Good = make_key(<<"good-plan">>),
    Bad = make_key(<<"bad-plan">>),
    ok = beam_agent_plan_cache_core:put(Good, simple_plan(), #{}),
    ok = beam_agent_plan_cache_core:put(Bad, simple_plan(), #{}),
    %% Good plan: 3/4 = 75% success
    lists:foreach(fun(_) ->
        beam_agent_plan_cache_core:record_success(Good)
    end, lists:seq(1, 3)),
    beam_agent_plan_cache_core:record_failure(Good),
    %% Bad plan: 1/4 = 25% success
    beam_agent_plan_cache_core:record_success(Bad),
    lists:foreach(fun(_) ->
        beam_agent_plan_cache_core:record_failure(Bad)
    end, lists:seq(1, 3)),
    %% Evict plans with < 50% success
    Evicted = beam_agent_plan_cache_core:evict_low_quality(0.5),
    ?assertEqual(1, Evicted),
    ?assertMatch({hit, _, _}, beam_agent_plan_cache_core:get(Good)),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(Bad)).

evict_low_quality_skips_unexecuted_plans_test() ->
    setup(),
    K = make_key(<<"never-run">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    Evicted = beam_agent_plan_cache_core:evict_low_quality(0.5),
    ?assertEqual(0, Evicted),
    ?assertMatch({hit, _, _}, beam_agent_plan_cache_core:get(K)).

%%====================================================================
%% evict_expired/0
%%====================================================================

evict_expired_removes_stale_entries_test() ->
    setup(),
    K1 = make_key(<<"stale">>),
    K2 = make_key(<<"fresh">>),
    ok = beam_agent_plan_cache_core:put(K1, simple_plan(), #{ttl => 1}),
    ok = beam_agent_plan_cache_core:put(K2, simple_plan(),
        #{ttl => 60_000}),
    timer:sleep(5),
    Evicted = beam_agent_plan_cache_core:evict_expired(),
    ?assertEqual(1, Evicted),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(K1)),
    ?assertMatch({hit, _, _}, beam_agent_plan_cache_core:get(K2)).

%%====================================================================
%% Stats
%%====================================================================

stats_initial_state_test() ->
    setup(),
    Stats = beam_agent_plan_cache_core:stats(),
    ?assertEqual(0, maps:get(hits, Stats)),
    ?assertEqual(0, maps:get(misses, Stats)),
    ?assertEqual(0, maps:get(entries, Stats)),
    ?assertEqual(0, maps:get(bytes_estimate, Stats)).

stats_counts_hits_and_misses_test() ->
    setup(),
    K = make_key(<<"stats">>),
    _ = beam_agent_plan_cache_core:get(K),          %% miss
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    _ = beam_agent_plan_cache_core:get(K),          %% hit
    Stats = beam_agent_plan_cache_core:stats(),
    ?assertEqual(1, maps:get(hits, Stats)),
    ?assertEqual(1, maps:get(misses, Stats)),
    ?assertEqual(1, maps:get(entries, Stats)),
    ?assert(maps:get(bytes_estimate, Stats) > 0).

%%====================================================================
%% Max entries eviction
%%====================================================================

max_entries_triggers_eviction_test() ->
    setup(),
    Max = 10,
    lists:foreach(fun(I) ->
        K = make_key(integer_to_binary(I)),
        beam_agent_plan_cache_core:put(K, simple_plan(),
            #{max_entries => Max})
    end, lists:seq(1, 15)),
    Stats = beam_agent_plan_cache_core:stats(),
    ?assert(maps:get(entries, Stats) =< Max + 1).

%%====================================================================
%% Table lifecycle
%%====================================================================

ensure_tables_is_idempotent_test() ->
    ok = beam_agent_plan_cache_core:ensure_tables(),
    ok = beam_agent_plan_cache_core:ensure_tables(),
    ok = beam_agent_plan_cache_core:ensure_tables().

clear_resets_everything_test() ->
    setup(),
    K = make_key(<<"clear">>),
    ok = beam_agent_plan_cache_core:put(K, simple_plan(), #{}),
    _ = beam_agent_plan_cache_core:get(K),
    ok = beam_agent_plan_cache_core:clear(),
    ?assertEqual(miss, beam_agent_plan_cache_core:get(K)),
    Stats = beam_agent_plan_cache_core:stats(),
    %% Stats reset — only the miss from the get above
    ?assertEqual(0, maps:get(hits, Stats)).

%%====================================================================
%% invalidate/1
%%====================================================================

invalidate_nonexistent_key_is_noop_test() ->
    setup(),
    K = make_key(<<"ghost">>),
    ?assertEqual(ok, beam_agent_plan_cache_core:invalidate(K)).
