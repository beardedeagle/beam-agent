%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_prompt_cache (public API).
%%%
%%% Tests cover the public API surface:
%%%   - Delegation to core (clear, stats, evict_expired)
%%%   - Cache interaction via store/lookup/invalidate with dead pids
%%%     (resolve_backend gracefully falls back to <<"unknown">>)
%%%   - Cache opts extraction and stripping
%%%
%%% No mocks.  Tests use real ETS tables and dead process pids to
%%% exercise the public wiring without requiring a live backend session.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_prompt_cache_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_prompt_cache_core:ensure_tables(),
    beam_agent_prompt_cache_core:clear(),
    ok.

%% Return a dead pid that resolve_backend will handle gracefully.
dead_pid() ->
    Pid = spawn(fun() -> ok end),
    timer:sleep(1),
    Pid.

%% Compute the expected key for a dead pid (backend = <<"unknown">>).
expected_key(Prompt) ->
    beam_agent_prompt_cache_core:cache_key(
        <<"unknown">>, <<"default">>, Prompt).

expected_key(Prompt, Model) ->
    beam_agent_prompt_cache_core:cache_key(
        <<"unknown">>, Model, Prompt).

%%====================================================================
%% clear/0
%%====================================================================

clear_delegates_to_core_test() ->
    setup(),
    K = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>),
    beam_agent_prompt_cache_core:put(K, [data], #{}),
    ok = beam_agent_prompt_cache:clear(),
    ?assertEqual(miss, beam_agent_prompt_cache_core:get(K)).

%%====================================================================
%% stats/0
%%====================================================================

stats_delegates_to_core_test() ->
    setup(),
    Stats = beam_agent_prompt_cache:stats(),
    ?assert(is_map(Stats)),
    ?assertEqual(0, maps:get(hits, Stats)),
    ?assertEqual(0, maps:get(misses, Stats)),
    ?assertEqual(0, maps:get(entries, Stats)),
    ?assertEqual(0, maps:get(bytes_estimate, Stats)).

stats_reflects_core_operations_test() ->
    setup(),
    K = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"p">>),
    beam_agent_prompt_cache_core:put(K, [data], #{}),
    _ = beam_agent_prompt_cache_core:get(K),
    Stats = beam_agent_prompt_cache:stats(),
    ?assertEqual(1, maps:get(hits, Stats)),
    ?assertEqual(1, maps:get(entries, Stats)).

%%====================================================================
%% evict_expired/0
%%====================================================================

evict_expired_delegates_to_core_test() ->
    setup(),
    K = beam_agent_prompt_cache_core:cache_key(claude, <<"m">>, <<"stale">>),
    beam_agent_prompt_cache_core:put(K, [old], #{ttl => 1}),
    timer:sleep(5),
    Count = beam_agent_prompt_cache:evict_expired(),
    ?assertEqual(1, Count).

%%====================================================================
%% store/4 + lookup/2
%%====================================================================

store_and_lookup_roundtrip_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"What is OTP?">>,
    Messages = [#{type => text, content => <<"OTP is...">>}],
    ok = beam_agent_prompt_cache:store(Pid, Prompt, Messages, #{}),
    ?assertMatch({hit, Messages, _},
        beam_agent_prompt_cache:lookup(Pid, Prompt)).

store_with_cache_ttl_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"ttl test">>,
    ok = beam_agent_prompt_cache:store(
        Pid, Prompt, [data], #{cache_ttl => 1}),
    timer:sleep(5),
    ?assertEqual(miss, beam_agent_prompt_cache:lookup(Pid, Prompt)).

lookup_miss_on_empty_cache_test() ->
    setup(),
    Pid = dead_pid(),
    ?assertEqual(miss, beam_agent_prompt_cache:lookup(Pid, <<"absent">>)).

%%====================================================================
%% lookup/3 — model scoping
%%====================================================================

different_models_produce_different_keys_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"shared prompt">>,
    ok = beam_agent_prompt_cache:store(
        Pid, Prompt, [model_a_result], #{model => <<"model-a">>}),
    ok = beam_agent_prompt_cache:store(
        Pid, Prompt, [model_b_result], #{model => <<"model-b">>}),
    ?assertMatch({hit, [model_a_result], _},
        beam_agent_prompt_cache:lookup(Pid, Prompt, #{model => <<"model-a">>})),
    ?assertMatch({hit, [model_b_result], _},
        beam_agent_prompt_cache:lookup(Pid, Prompt, #{model => <<"model-b">>})).

%%====================================================================
%% invalidate/2
%%====================================================================

invalidate_removes_cached_entry_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"to invalidate">>,
    ok = beam_agent_prompt_cache:store(Pid, Prompt, [data], #{}),
    ok = beam_agent_prompt_cache:invalidate(Pid, Prompt),
    ?assertEqual(miss, beam_agent_prompt_cache:lookup(Pid, Prompt)).

invalidate_nonexistent_is_noop_test() ->
    setup(),
    Pid = dead_pid(),
    ?assertEqual(ok, beam_agent_prompt_cache:invalidate(Pid, <<"ghost">>)).

%%====================================================================
%% Cache key override
%%====================================================================

cache_key_override_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"override test">>,
    CustomKey = beam_agent_prompt_cache_core:cache_key(
        gemini, <<"custom-model">>, <<"custom-prompt">>),
    ok = beam_agent_prompt_cache:store(
        Pid, Prompt, [custom], #{cache_key => CustomKey}),
    %% Lookup with same override finds it
    ?assertMatch({hit, [custom], _},
        beam_agent_prompt_cache:lookup(Pid, Prompt, #{cache_key => CustomKey})),
    %% Lookup without override misses (different key)
    ?assertEqual(miss,
        beam_agent_prompt_cache:lookup(Pid, Prompt)).

%%====================================================================
%% Edge cases
%%====================================================================

dead_pid_resolves_backend_gracefully_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"dead pid test">>,
    %% Store using the public API (will resolve backend to <<"unknown">>)
    ok = beam_agent_prompt_cache:store(Pid, Prompt, [result], #{}),
    %% Verify via core using the expected key
    ExpectedKey = expected_key(Prompt),
    ?assertMatch({hit, [result], _},
        beam_agent_prompt_cache_core:get(ExpectedKey)).

model_from_opts_used_in_key_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"model opts test">>,
    ok = beam_agent_prompt_cache:store(
        Pid, Prompt, [result], #{model => <<"claude-4">>}),
    ExpectedKey = expected_key(Prompt, <<"claude-4">>),
    ?assertMatch({hit, [result], _},
        beam_agent_prompt_cache_core:get(ExpectedKey)).

default_model_when_not_specified_test() ->
    setup(),
    Pid = dead_pid(),
    Prompt = <<"default model test">>,
    ok = beam_agent_prompt_cache:store(Pid, Prompt, [result], #{}),
    ExpectedKey = expected_key(Prompt),
    ?assertMatch({hit, [result], _},
        beam_agent_prompt_cache_core:get(ExpectedKey)).
