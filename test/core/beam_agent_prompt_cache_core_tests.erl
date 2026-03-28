%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_prompt_cache_core.
%%%
%%% Pure tests — no mocks, no side effects beyond ETS.
%%% Each test ensures tables exist and clears state for isolation.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_prompt_cache_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_prompt_cache_core:ensure_tables(),
    beam_agent_prompt_cache_core:clear(),
    ok.

make_key(Backend, Model, Prompt) ->
    beam_agent_prompt_cache_core:cache_key(Backend, Model, Prompt).

%%====================================================================
%% cache_key/3
%%====================================================================

cache_key_deterministic_test() ->
    setup(),
    K1 = make_key(claude, <<"model-1">>, <<"hello">>),
    K2 = make_key(claude, <<"model-1">>, <<"hello">>),
    ?assertEqual(K1, K2).

cache_key_is_32_bytes_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"p">>),
    ?assertEqual(32, byte_size(K)).

cache_key_different_backends_differ_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"p">>),
    K2 = make_key(codex, <<"m">>, <<"p">>),
    ?assertNotEqual(K1, K2).

cache_key_different_models_differ_test() ->
    setup(),
    K1 = make_key(claude, <<"model-a">>, <<"p">>),
    K2 = make_key(claude, <<"model-b">>, <<"p">>),
    ?assertNotEqual(K1, K2).

cache_key_different_prompts_differ_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"hello">>),
    K2 = make_key(claude, <<"m">>, <<"world">>),
    ?assertNotEqual(K1, K2).

cache_key_atom_and_binary_backend_equivalent_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"p">>),
    K2 = make_key(<<"claude">>, <<"m">>, <<"p">>),
    ?assertEqual(K1, K2).

cache_key_empty_prompt_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<>>),
    ?assertEqual(32, byte_size(K)).

%%====================================================================
%% put/3 + get/1 round-trip
%%====================================================================

put_get_roundtrip_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"hello">>),
    Result = [#{type => text, content => <<"world">>}],
    ok = beam_agent_prompt_cache_core:put(K, Result, #{}),
    ?assertMatch({hit, Result, _}, beam_agent_prompt_cache_core:get(K)).

get_miss_on_empty_cache_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"hello">>),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K)).

get_miss_after_invalidate_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"hello">>),
    ok = beam_agent_prompt_cache_core:put(K, [#{type => text}], #{}),
    ok = beam_agent_prompt_cache_core:invalidate(K),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K)).

get_hit_metadata_contains_expected_keys_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"hello">>),
    ok = beam_agent_prompt_cache_core:put(K, [data], #{}),
    {hit, _, Meta} = beam_agent_prompt_cache_core:get(K),
    ?assert(maps:is_key(inserted_at, Meta)),
    ?assert(maps:is_key(expires_at, Meta)),
    ?assert(maps:is_key(byte_estimate, Meta)),
    ?assert(maps:is_key(age_ms, Meta)).

put_overwrites_existing_entry_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"hello">>),
    ok = beam_agent_prompt_cache_core:put(K, [first], #{}),
    ok = beam_agent_prompt_cache_core:put(K, [second], #{}),
    ?assertMatch({hit, [second], _}, beam_agent_prompt_cache_core:get(K)).

%%====================================================================
%% TTL expiry
%%====================================================================

get_miss_after_ttl_expires_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"ttl-test">>),
    %% TTL of 1ms — entry expires almost immediately
    ok = beam_agent_prompt_cache_core:put(K, [expired], #{ttl => 1}),
    timer:sleep(5),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K)).

get_hit_within_ttl_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"ttl-test">>),
    ok = beam_agent_prompt_cache_core:put(K, [alive], #{ttl => 60_000}),
    ?assertMatch({hit, [alive], _}, beam_agent_prompt_cache_core:get(K)).

%%====================================================================
%% evict_expired/0
%%====================================================================

evict_expired_removes_stale_entries_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"stale">>),
    K2 = make_key(claude, <<"m">>, <<"fresh">>),
    ok = beam_agent_prompt_cache_core:put(K1, [old], #{ttl => 1}),
    ok = beam_agent_prompt_cache_core:put(K2, [new], #{ttl => 60_000}),
    timer:sleep(5),
    Evicted = beam_agent_prompt_cache_core:evict_expired(),
    ?assertEqual(1, Evicted),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K1)),
    ?assertMatch({hit, [new], _}, beam_agent_prompt_cache_core:get(K2)).

evict_expired_returns_zero_when_nothing_expired_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"fresh">>),
    ok = beam_agent_prompt_cache_core:put(K, [alive], #{ttl => 60_000}),
    ?assertEqual(0, beam_agent_prompt_cache_core:evict_expired()).

%%====================================================================
%% clear/0
%%====================================================================

clear_wipes_all_entries_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"a">>),
    K2 = make_key(claude, <<"m">>, <<"b">>),
    ok = beam_agent_prompt_cache_core:put(K1, [a], #{}),
    ok = beam_agent_prompt_cache_core:put(K2, [b], #{}),
    ok = beam_agent_prompt_cache_core:clear(),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K1)),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K2)).

clear_resets_stats_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"stats-clear">>),
    _ = beam_agent_prompt_cache_core:get(K),
    ok = beam_agent_prompt_cache_core:clear(),
    Stats = beam_agent_prompt_cache_core:stats(),
    ?assertEqual(0, maps:get(hits, Stats)),
    ?assertEqual(0, maps:get(misses, Stats)).

%%====================================================================
%% stats/0
%%====================================================================

stats_initial_state_test() ->
    setup(),
    Stats = beam_agent_prompt_cache_core:stats(),
    ?assertEqual(0, maps:get(hits, Stats)),
    ?assertEqual(0, maps:get(misses, Stats)),
    ?assertEqual(0, maps:get(entries, Stats)),
    ?assertEqual(0, maps:get(bytes_estimate, Stats)).

stats_counts_hits_and_misses_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"stats-test">>),
    %% Miss
    _ = beam_agent_prompt_cache_core:get(K),
    %% Put + Hit
    ok = beam_agent_prompt_cache_core:put(K, [result], #{}),
    _ = beam_agent_prompt_cache_core:get(K),
    Stats = beam_agent_prompt_cache_core:stats(),
    ?assertEqual(1, maps:get(hits, Stats)),
    ?assertEqual(1, maps:get(misses, Stats)),
    ?assertEqual(1, maps:get(entries, Stats)),
    ?assert(maps:get(bytes_estimate, Stats) > 0).

stats_entries_count_matches_stored_test() ->
    setup(),
    lists:foreach(fun(I) ->
        K = make_key(claude, <<"m">>, integer_to_binary(I)),
        beam_agent_prompt_cache_core:put(K, [I], #{})
    end, lists:seq(1, 5)),
    Stats = beam_agent_prompt_cache_core:stats(),
    ?assertEqual(5, maps:get(entries, Stats)).

%%====================================================================
%% Max entries eviction
%%====================================================================

max_entries_triggers_eviction_test() ->
    setup(),
    MaxEntries = 10,
    %% Fill beyond max
    lists:foreach(fun(I) ->
        K = make_key(claude, <<"m">>, integer_to_binary(I)),
        beam_agent_prompt_cache_core:put(K, [I], #{max_entries => MaxEntries})
    end, lists:seq(1, 15)),
    Stats = beam_agent_prompt_cache_core:stats(),
    %% Should have evicted down to at most MaxEntries
    ?assert(maps:get(entries, Stats) =< MaxEntries + 1).

%%====================================================================
%% invalidate/1
%%====================================================================

invalidate_nonexistent_key_is_noop_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"ghost">>),
    ?assertEqual(ok, beam_agent_prompt_cache_core:invalidate(K)).

%%====================================================================
%% Edge cases
%%====================================================================

large_result_stored_correctly_test() ->
    setup(),
    K = make_key(claude, <<"m">>, <<"large">>),
    LargeResult = [#{content => binary:copy(<<"x">>, 100_000)}],
    ok = beam_agent_prompt_cache_core:put(K, LargeResult, #{}),
    {hit, Retrieved, Meta} = beam_agent_prompt_cache_core:get(K),
    ?assertEqual(LargeResult, Retrieved),
    ?assert(maps:get(byte_estimate, Meta) > 100_000).

multiple_backends_isolated_test() ->
    setup(),
    K1 = make_key(claude, <<"m">>, <<"shared prompt">>),
    K2 = make_key(codex, <<"m">>, <<"shared prompt">>),
    ok = beam_agent_prompt_cache_core:put(K1, [claude_result], #{}),
    ok = beam_agent_prompt_cache_core:put(K2, [codex_result], #{}),
    ?assertMatch({hit, [claude_result], _},
        beam_agent_prompt_cache_core:get(K1)),
    ?assertMatch({hit, [codex_result], _},
        beam_agent_prompt_cache_core:get(K2)).

ensure_tables_is_idempotent_test() ->
    setup(),
    %% Calling ensure_tables multiple times should not crash
    ok = beam_agent_prompt_cache_core:ensure_tables(),
    ok = beam_agent_prompt_cache_core:ensure_tables(),
    ok = beam_agent_prompt_cache_core:ensure_tables().

%%====================================================================
%% normalize_prompt/1
%%====================================================================

normalize_prompt_trims_whitespace_test() ->
    ?assertEqual(<<"hello">>,
        beam_agent_prompt_cache_core:normalize_prompt(<<"  hello  ">>)).

normalize_prompt_trims_newlines_test() ->
    ?assertEqual(<<"hello">>,
        beam_agent_prompt_cache_core:normalize_prompt(<<"\n hello \n">>)).

normalize_prompt_empty_binary_test() ->
    ?assertEqual(<<>>,
        beam_agent_prompt_cache_core:normalize_prompt(<<>>)).

normalize_prompt_whitespace_only_test() ->
    ?assertEqual(<<>>,
        beam_agent_prompt_cache_core:normalize_prompt(<<"   ">>)).

normalize_prompt_preserves_internal_whitespace_test() ->
    ?assertEqual(<<"hello world">>,
        beam_agent_prompt_cache_core:normalize_prompt(<<"hello world">>)).

normalize_prompt_nfc_normalization_test() ->
    %% U+00E9 (e-acute precomposed) vs U+0065 U+0301 (e + combining acute)
    Precomposed = <<16#C3, 16#A9>>,      %% "é" NFC
    Decomposed = <<16#65, 16#CC, 16#81>>, %% "é" NFD (e + combining accent)
    ?assertEqual(
        beam_agent_prompt_cache_core:normalize_prompt(Precomposed),
        beam_agent_prompt_cache_core:normalize_prompt(Decomposed)).

%%====================================================================
%% cache_key/4 (context-aware)
%%====================================================================

cache_key_4_with_context_differs_from_no_context_test() ->
    setup(),
    K1 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>, <<>>),
    K2 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>, <<"/tmp/project">>),
    ?assertNotEqual(K1, K2).

cache_key_4_same_context_produces_same_key_test() ->
    setup(),
    K1 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>, <<"/home">>),
    K2 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>, <<"/home">>),
    ?assertEqual(K1, K2).

cache_key_3_equivalent_to_key_4_empty_context_test() ->
    setup(),
    K3 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>),
    K4 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>, <<>>),
    ?assertEqual(K3, K4).

cache_key_normalizes_prompt_whitespace_test() ->
    setup(),
    K1 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"hello">>),
    K2 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"  hello  ">>),
    ?assertEqual(K1, K2).

cache_key_normalizes_prompt_nfc_test() ->
    setup(),
    Precomposed = <<16#C3, 16#A9>>,
    Decomposed = <<16#65, 16#CC, 16#81>>,
    K1 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, Precomposed),
    K2 = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, Decomposed),
    ?assertEqual(K1, K2).
