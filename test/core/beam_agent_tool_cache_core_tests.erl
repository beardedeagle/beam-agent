%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_tool_cache_core.
%%%
%%% Tests the deterministic tool result cache including per-tool
%%% invalidation.  No mocks — real ETS tables.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_tool_cache_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_tool_cache_core:ensure_tables(),
    beam_agent_tool_cache_core:clear(),
    ok.

make_key(ToolName, Args) ->
    beam_agent_tool_cache_core:cache_key(ToolName, Args).

%%====================================================================
%% cache_key/2
%%====================================================================

cache_key_deterministic_test() ->
    setup(),
    K1 = make_key(<<"read_file">>, #{<<"path">> => <<"/tmp/a">>}),
    K2 = make_key(<<"read_file">>, #{<<"path">> => <<"/tmp/a">>}),
    ?assertEqual(K1, K2).

cache_key_is_32_bytes_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ?assertEqual(32, byte_size(K)).

cache_key_different_tools_differ_test() ->
    setup(),
    K1 = make_key(<<"read_file">>, #{<<"path">> => <<"/a">>}),
    K2 = make_key(<<"list_dir">>, #{<<"path">> => <<"/a">>}),
    ?assertNotEqual(K1, K2).

cache_key_different_args_differ_test() ->
    setup(),
    K1 = make_key(<<"read_file">>, #{<<"path">> => <<"/a">>}),
    K2 = make_key(<<"read_file">>, #{<<"path">> => <<"/b">>}),
    ?assertNotEqual(K1, K2).

cache_key_arg_order_independent_test() ->
    setup(),
    %% Maps with same keys/values but different insertion order
    %% should produce the same key (sorted before hashing)
    K1 = make_key(<<"tool">>, #{<<"a">> => 1, <<"b">> => 2}),
    K2 = make_key(<<"tool">>, #{<<"b">> => 2, <<"a">> => 1}),
    ?assertEqual(K1, K2).

cache_key_empty_args_test() ->
    setup(),
    K = make_key(<<"tool">>, #{}),
    ?assertEqual(32, byte_size(K)).

%%====================================================================
%% put/4 + get/1 round-trip
%%====================================================================

put_get_roundtrip_test() ->
    setup(),
    K = make_key(<<"read_file">>, #{<<"path">> => <<"/tmp">>}),
    Result = {ok, [#{type => text, text => <<"content">>}]},
    ok = beam_agent_tool_cache_core:put(
        K, <<"read_file">>, Result, #{}),
    ?assertMatch({hit, Result, _},
        beam_agent_tool_cache_core:get(K)).

get_miss_on_empty_cache_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K)).

get_miss_after_invalidate_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(K, <<"tool">>, result, #{}),
    ok = beam_agent_tool_cache_core:invalidate(K),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K)).

get_hit_metadata_has_expected_keys_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(K, <<"tool">>, data, #{}),
    {hit, _, Meta} = beam_agent_tool_cache_core:get(K),
    ?assert(maps:is_key(tool_name, Meta)),
    ?assert(maps:is_key(inserted_at, Meta)),
    ?assert(maps:is_key(expires_at, Meta)),
    ?assert(maps:is_key(byte_estimate, Meta)),
    ?assert(maps:is_key(age_ms, Meta)),
    ?assertEqual(<<"tool">>, maps:get(tool_name, Meta)).

put_overwrites_existing_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(K, <<"tool">>, first, #{}),
    ok = beam_agent_tool_cache_core:put(K, <<"tool">>, second, #{}),
    ?assertMatch({hit, second, _},
        beam_agent_tool_cache_core:get(K)).

%%====================================================================
%% TTL expiry
%%====================================================================

get_miss_after_ttl_expires_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, expired, #{ttl => 1}),
    timer:sleep(5),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K)).

get_hit_within_ttl_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, alive, #{ttl => 60_000}),
    ?assertMatch({hit, alive, _},
        beam_agent_tool_cache_core:get(K)).

%%====================================================================
%% Per-tool invalidation
%%====================================================================

invalidate_tool_removes_all_entries_for_tool_test() ->
    setup(),
    K1 = make_key(<<"read_file">>, #{<<"path">> => <<"/a">>}),
    K2 = make_key(<<"read_file">>, #{<<"path">> => <<"/b">>}),
    K3 = make_key(<<"list_dir">>, #{<<"path">> => <<"/a">>}),
    ok = beam_agent_tool_cache_core:put(
        K1, <<"read_file">>, content_a, #{}),
    ok = beam_agent_tool_cache_core:put(
        K2, <<"read_file">>, content_b, #{}),
    ok = beam_agent_tool_cache_core:put(
        K3, <<"list_dir">>, listing, #{}),
    %% Invalidate all read_file entries
    ok = beam_agent_tool_cache_core:invalidate_tool(<<"read_file">>),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K1)),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K2)),
    %% list_dir entries are unaffected
    ?assertMatch({hit, listing, _},
        beam_agent_tool_cache_core:get(K3)).

invalidate_tool_nonexistent_is_noop_test() ->
    setup(),
    ?assertEqual(ok,
        beam_agent_tool_cache_core:invalidate_tool(<<"no_such_tool">>)).

%%====================================================================
%% evict_expired/0
%%====================================================================

evict_expired_removes_stale_entries_test() ->
    setup(),
    K1 = make_key(<<"tool">>, #{<<"x">> => <<"stale">>}),
    K2 = make_key(<<"tool">>, #{<<"x">> => <<"fresh">>}),
    ok = beam_agent_tool_cache_core:put(
        K1, <<"tool">>, old, #{ttl => 1}),
    ok = beam_agent_tool_cache_core:put(
        K2, <<"tool">>, new, #{ttl => 60_000}),
    timer:sleep(5),
    Evicted = beam_agent_tool_cache_core:evict_expired(),
    ?assertEqual(1, Evicted),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K1)),
    ?assertMatch({hit, new, _},
        beam_agent_tool_cache_core:get(K2)).

evict_expired_returns_zero_when_nothing_expired_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, alive, #{ttl => 60_000}),
    ?assertEqual(0, beam_agent_tool_cache_core:evict_expired()).

%%====================================================================
%% Stats
%%====================================================================

stats_initial_state_test() ->
    setup(),
    Stats = beam_agent_tool_cache_core:stats(),
    ?assertEqual(0, maps:get(hits, Stats)),
    ?assertEqual(0, maps:get(misses, Stats)),
    ?assertEqual(0, maps:get(entries, Stats)),
    ?assertEqual(0, maps:get(bytes_estimate, Stats)).

stats_counts_hits_and_misses_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    _ = beam_agent_tool_cache_core:get(K),         %% miss
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, result, #{}),
    _ = beam_agent_tool_cache_core:get(K),         %% hit
    Stats = beam_agent_tool_cache_core:stats(),
    ?assertEqual(1, maps:get(hits, Stats)),
    ?assertEqual(1, maps:get(misses, Stats)),
    ?assertEqual(1, maps:get(entries, Stats)),
    ?assert(maps:get(bytes_estimate, Stats) > 0).

stats_entries_count_matches_test() ->
    setup(),
    lists:foreach(fun(I) ->
        K = make_key(<<"tool">>, #{<<"i">> => I}),
        beam_agent_tool_cache_core:put(
            K, <<"tool">>, I, #{})
    end, lists:seq(1, 5)),
    Stats = beam_agent_tool_cache_core:stats(),
    ?assertEqual(5, maps:get(entries, Stats)).

%%====================================================================
%% Max entries eviction
%%====================================================================

max_entries_triggers_eviction_test() ->
    setup(),
    Max = 10,
    lists:foreach(fun(I) ->
        K = make_key(<<"tool">>, #{<<"i">> => I}),
        beam_agent_tool_cache_core:put(
            K, <<"tool">>, I, #{max_entries => Max})
    end, lists:seq(1, 15)),
    Stats = beam_agent_tool_cache_core:stats(),
    ?assert(maps:get(entries, Stats) =< Max + 1).

%%====================================================================
%% Table lifecycle
%%====================================================================

ensure_tables_is_idempotent_test() ->
    ok = beam_agent_tool_cache_core:ensure_tables(),
    ok = beam_agent_tool_cache_core:ensure_tables(),
    ok = beam_agent_tool_cache_core:ensure_tables().

clear_resets_everything_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, data, #{}),
    _ = beam_agent_tool_cache_core:get(K),
    ok = beam_agent_tool_cache_core:clear(),
    ?assertEqual(miss, beam_agent_tool_cache_core:get(K)),
    Stats = beam_agent_tool_cache_core:stats(),
    ?assertEqual(0, maps:get(hits, Stats)).

%%====================================================================
%% invalidate/1
%%====================================================================

invalidate_nonexistent_key_is_noop_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    ?assertEqual(ok, beam_agent_tool_cache_core:invalidate(K)).

%%====================================================================
%% Complex result types
%%====================================================================

caches_complex_results_test() ->
    setup(),
    K = make_key(<<"tool">>, #{<<"x">> => 1}),
    Result = {ok, [#{type => text, text => <<"hello">>},
                   #{type => image, data => <<"png">>,
                     mime_type => <<"image/png">>}]},
    ok = beam_agent_tool_cache_core:put(
        K, <<"tool">>, Result, #{}),
    ?assertMatch({hit, Result, _},
        beam_agent_tool_cache_core:get(K)).
