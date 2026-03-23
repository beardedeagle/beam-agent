%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_capabilities public API.
%%%
%%% Tests cover:
%%%   - H9: safe nested map access in status/2 and for_backend/1
%%%   - L12: assert_capability/2 convenience function
%%%
%%% All tests are pure — no processes, no ETS, no test doubles.
%%% The capabilities module is compiled-in static data only.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_capabilities_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% H9: status/2 — safe nested map access
%%====================================================================

status_returns_support_info_for_valid_pair_test() ->
    {ok, Info} = beam_agent_capabilities:status(checkpointing, codex),
    ?assertEqual(full, maps:get(support_level, Info)),
    ?assert(maps:is_key(implementation, Info)),
    ?assert(maps:is_key(fidelity, Info)).

status_returns_error_for_unknown_capability_test() ->
    ?assertMatch({error, {unknown_capability, totally_bogus}},
        beam_agent_capabilities:status(totally_bogus, claude)).

status_returns_error_for_unknown_backend_test() ->
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:status(checkpointing, no_such_backend)).

status_returns_error_for_both_unknown_test() ->
    %% capability lookup fails first — that error is returned
    ?assertMatch({error, {unknown_capability, _}},
        beam_agent_capabilities:status(bad_cap, bad_backend)).

status_binary_backend_works_test() ->
    {ok, Info} = beam_agent_capabilities:status(hooks, <<"gemini">>),
    ?assertEqual(full, maps:get(support_level, Info)).

status_all_capabilities_all_backends_test() ->
    Caps = beam_agent_capabilities:capability_ids(),
    Backends = beam_agent_capabilities:backends(),
    lists:foreach(fun(Cap) ->
        lists:foreach(fun(Backend) ->
            ?assertMatch({ok, _}, beam_agent_capabilities:status(Cap, Backend))
        end, Backends)
    end, Caps).

%%====================================================================
%% H9: for_backend/1 — safe nested map access via project_capability
%%====================================================================

for_backend_returns_projected_list_test() ->
    {ok, Caps} = beam_agent_capabilities:for_backend(claude),
    ?assertEqual(length(beam_agent_capabilities:capability_ids()), length(Caps)),
    [First | _] = Caps,
    ?assert(maps:is_key(id, First)),
    ?assert(maps:is_key(support_level, First)),
    ?assert(maps:is_key(implementation, First)),
    ?assert(maps:is_key(fidelity, First)).

for_backend_returns_error_for_unknown_backend_test() ->
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:for_backend(not_a_real_backend)).

for_backend_binary_backend_works_test() ->
    {ok, Caps} = beam_agent_capabilities:for_backend(<<"opencode">>),
    ?assertEqual(length(beam_agent_capabilities:capability_ids()), length(Caps)).

%%====================================================================
%% H9: supports/2 — relies on status/2, tests error propagation
%%====================================================================

supports_returns_ok_true_for_valid_pair_test() ->
    ?assertEqual({ok, true},
        beam_agent_capabilities:supports(event_streaming, copilot)).

supports_returns_error_for_unknown_capability_test() ->
    ?assertMatch({error, {unknown_capability, ghost_feature}},
        beam_agent_capabilities:supports(ghost_feature, claude)).

supports_returns_error_for_unknown_backend_test() ->
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:supports(hooks, phantom_backend)).

%%====================================================================
%% L12: assert_capability/2
%%====================================================================

assert_capability_returns_ok_for_valid_pair_test() ->
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(session_lifecycle, claude)).

assert_capability_returns_ok_for_all_valid_combinations_test() ->
    Caps = beam_agent_capabilities:capability_ids(),
    Backends = beam_agent_capabilities:backends(),
    lists:foreach(fun(Cap) ->
        lists:foreach(fun(Backend) ->
            ?assertEqual(ok, beam_agent_capabilities:assert_capability(Cap, Backend))
        end, Backends)
    end, Caps).

assert_capability_returns_error_for_unknown_capability_test() ->
    ?assertMatch({error, {unknown_capability, nonexistent_cap}},
        beam_agent_capabilities:assert_capability(nonexistent_cap, claude)).

assert_capability_returns_error_for_unknown_backend_test() ->
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(checkpointing, unknown_backend_xyz)).

assert_capability_binary_backend_works_test() ->
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(thinking_budget, <<"claude">>)).

assert_capability_unknown_cap_and_backend_returns_error_test() ->
    %% Backend normalisation runs first; unknown backend is reported
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(bad_cap, bad_backend)).

%% The {unsupported_capability, Cap, Backend} path is triggered when
%% status/2 returns {ok, #{support_level := missing}}. All 22 capabilities
%% are currently at `full` support level across all 5 backends, so this
%% branch is unreachable with static data and cannot be exercised without
%% a mock. The path is verified structurally: assert_capability/2 now
%% delegates to status/2 (not supports/2), so valid pairs still return ok.
assert_capability_uses_status_not_supports_test() ->
    %% Regression: implementation was changed from supports/2 to status/2.
    %% Valid pairs must still return ok; errors must still propagate.
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(checkpointing, codex)),
    ?assertMatch({error, {unknown_capability, _}},
        beam_agent_capabilities:assert_capability(ghost_cap, claude)),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(hooks, phantom)).
