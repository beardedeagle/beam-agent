%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_capabilities public API.
%%%
%%% Tests cover:
%%%   - H9: safe nested map access in status/2 and for_backend/1
%%%   - L12: assert_capability/2 convenience function
%%%   - Pluggable registration: register_backend, register_capability,
%%%     unregister_backend
%%%   - ETS-backed runtime matrix with seed/reset
%%%
%%% All tests use real ETS tables — zero test doubles.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_capabilities_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

reset() ->
    beam_agent_capabilities:reset().

%%====================================================================
%% H9: status/2 — safe nested map access
%%====================================================================

status_returns_support_info_for_valid_pair_test() ->
    reset(),
    {ok, Info} = beam_agent_capabilities:status(checkpointing, codex),
    ?assertEqual(full, maps:get(support_level, Info)),
    ?assert(maps:is_key(implementation, Info)),
    ?assert(maps:is_key(fidelity, Info)).

status_returns_error_for_unknown_capability_test() ->
    reset(),
    ?assertMatch({error, {unknown_capability, totally_bogus}},
        beam_agent_capabilities:status(totally_bogus, claude)).

status_returns_error_for_unknown_backend_test() ->
    reset(),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:status(checkpointing, no_such_backend)).

status_returns_error_for_both_unknown_test() ->
    reset(),
    ?assertMatch({error, {unknown_capability, _}},
        beam_agent_capabilities:status(bad_cap, bad_backend)).

status_binary_backend_works_test() ->
    reset(),
    {ok, Info} = beam_agent_capabilities:status(hooks, <<"gemini">>),
    ?assertEqual(full, maps:get(support_level, Info)).

status_all_capabilities_all_backends_test() ->
    reset(),
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
    reset(),
    {ok, Caps} = beam_agent_capabilities:for_backend(claude),
    ?assertEqual(length(beam_agent_capabilities:capability_ids()), length(Caps)),
    [First | _] = Caps,
    ?assert(maps:is_key(id, First)),
    ?assert(maps:is_key(support_level, First)),
    ?assert(maps:is_key(implementation, First)),
    ?assert(maps:is_key(fidelity, First)).

for_backend_returns_error_for_unknown_backend_test() ->
    reset(),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:for_backend(not_a_real_backend)).

for_backend_binary_backend_works_test() ->
    reset(),
    {ok, Caps} = beam_agent_capabilities:for_backend(<<"opencode">>),
    ?assertEqual(length(beam_agent_capabilities:capability_ids()), length(Caps)).

%%====================================================================
%% H9: supports/2 — relies on status/2, tests error propagation
%%====================================================================

supports_returns_ok_true_for_valid_pair_test() ->
    reset(),
    ?assertEqual({ok, true},
        beam_agent_capabilities:supports(event_streaming, copilot)).

supports_returns_error_for_unknown_capability_test() ->
    reset(),
    ?assertMatch({error, {unknown_capability, ghost_feature}},
        beam_agent_capabilities:supports(ghost_feature, claude)).

supports_returns_error_for_unknown_backend_test() ->
    reset(),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:supports(hooks, phantom_backend)).

%%====================================================================
%% L12: assert_capability/2
%%====================================================================

assert_capability_returns_ok_for_valid_pair_test() ->
    reset(),
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(session_lifecycle, claude)).

assert_capability_returns_ok_for_all_valid_combinations_test() ->
    reset(),
    Caps = beam_agent_capabilities:capability_ids(),
    Backends = beam_agent_capabilities:backends(),
    lists:foreach(fun(Cap) ->
        lists:foreach(fun(Backend) ->
            ?assertEqual(ok, beam_agent_capabilities:assert_capability(Cap, Backend))
        end, Backends)
    end, Caps).

assert_capability_returns_error_for_unknown_capability_test() ->
    reset(),
    ?assertMatch({error, {unknown_capability, nonexistent_cap}},
        beam_agent_capabilities:assert_capability(nonexistent_cap, claude)).

assert_capability_returns_error_for_unknown_backend_test() ->
    reset(),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(checkpointing, unknown_backend_xyz)).

assert_capability_binary_backend_works_test() ->
    reset(),
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(thinking_budget, <<"claude">>)).

assert_capability_unknown_cap_and_backend_returns_error_test() ->
    reset(),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(bad_cap, bad_backend)).

assert_capability_uses_status_not_supports_test() ->
    reset(),
    ?assertEqual(ok,
        beam_agent_capabilities:assert_capability(checkpointing, codex)),
    ?assertMatch({error, {unknown_capability, _}},
        beam_agent_capabilities:assert_capability(ghost_cap, claude)),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:assert_capability(hooks, phantom)).

%%====================================================================
%% H9: capability_ids/0 — pattern-matching extraction
%%====================================================================

capability_ids_returns_atom_list_test() ->
    reset(),
    Ids = beam_agent_capabilities:capability_ids(),
    ?assert(is_list(Ids)),
    ?assert(length(Ids) > 0),
    lists:foreach(fun(Id) -> ?assert(is_atom(Id)) end, Ids).

capability_ids_matches_all_count_test() ->
    reset(),
    Ids = beam_agent_capabilities:capability_ids(),
    All = beam_agent_capabilities:all(),
    ?assertEqual(length(All), length(Ids)).

capability_ids_no_duplicates_test() ->
    reset(),
    Ids = beam_agent_capabilities:capability_ids(),
    ?assertEqual(length(Ids), length(lists:usort(Ids))).

%%====================================================================
%% Pluggable registration: register_backend/2
%%====================================================================

register_backend_adds_new_backend_test() ->
    reset(),
    Caps = full_capability_set(full, direct_backend, exact),
    ok = beam_agent_capabilities:register_backend(my_custom_backend, Caps),
    ?assert(lists:member(my_custom_backend, beam_agent_capabilities:backends())),
    {ok, true} = beam_agent_capabilities:supports(session_lifecycle, my_custom_backend),
    reset().

register_backend_for_backend_returns_full_list_test() ->
    reset(),
    Caps = full_capability_set(full, universal, validated_equivalent),
    ok = beam_agent_capabilities:register_backend(test_backend, Caps),
    {ok, Projected} = beam_agent_capabilities:for_backend(test_backend),
    ?assertEqual(23, length(Projected)),
    [First | _] = Projected,
    ?assertEqual(full, maps:get(support_level, First)),
    reset().

register_backend_status_returns_correct_info_test() ->
    reset(),
    Caps = full_capability_set(full, universal, validated_equivalent),
    ok = beam_agent_capabilities:register_backend(test_backend_2, Caps),
    {ok, Info} = beam_agent_capabilities:status(hooks, test_backend_2),
    ?assertEqual(full, maps:get(support_level, Info)),
    ?assertEqual(universal, maps:get(implementation, Info)),
    ?assertEqual(validated_equivalent, maps:get(fidelity, Info)),
    reset().

register_backend_does_not_affect_builtin_test() ->
    reset(),
    Caps = full_capability_set(full, direct_backend, exact),
    ok = beam_agent_capabilities:register_backend(extra, Caps),
    {ok, ClaudeInfo} = beam_agent_capabilities:status(session_lifecycle, claude),
    ?assertEqual(full, maps:get(support_level, ClaudeInfo)),
    reset().

%%====================================================================
%% Pluggable registration: register_capability/3
%%====================================================================

register_capability_overrides_single_entry_test() ->
    reset(),
    ok = beam_agent_capabilities:register_capability(claude, hooks, #{
        support_level => partial,
        implementation => universal,
        fidelity => validated_equivalent
    }),
    {ok, Info} = beam_agent_capabilities:status(hooks, claude),
    ?assertEqual(partial, maps:get(support_level, Info)),
    ?assertEqual(universal, maps:get(implementation, Info)),
    reset().

register_capability_for_new_backend_test() ->
    reset(),
    ok = beam_agent_capabilities:register_capability(new_b, session_lifecycle, #{
        support_level => full,
        implementation => direct_backend,
        fidelity => exact
    }),
    ?assert(lists:member(new_b, beam_agent_capabilities:backends())),
    {ok, Info} = beam_agent_capabilities:status(session_lifecycle, new_b),
    ?assertEqual(full, maps:get(support_level, Info)),
    reset().

%%====================================================================
%% Pluggable registration: unregister_backend/1
%%====================================================================

unregister_backend_removes_all_entries_test() ->
    reset(),
    Caps = full_capability_set(full, direct_backend, exact),
    ok = beam_agent_capabilities:register_backend(removable, Caps),
    ?assert(lists:member(removable, beam_agent_capabilities:backends())),
    ok = beam_agent_capabilities:unregister_backend(removable),
    ?assertNot(lists:member(removable, beam_agent_capabilities:backends())),
    ?assertMatch({error, {unknown_backend, _}},
        beam_agent_capabilities:status(hooks, removable)),
    reset().

unregister_nonexistent_backend_is_safe_test() ->
    reset(),
    ok = beam_agent_capabilities:unregister_backend(does_not_exist),
    reset().

%%====================================================================
%% reset/0 restores defaults
%%====================================================================

reset_restores_defaults_after_modification_test() ->
    reset(),
    ok = beam_agent_capabilities:register_capability(claude, hooks, #{
        support_level => missing,
        implementation => universal,
        fidelity => validated_equivalent
    }),
    {ok, Before} = beam_agent_capabilities:status(hooks, claude),
    ?assertEqual(missing, maps:get(support_level, Before)),
    reset(),
    {ok, After} = beam_agent_capabilities:status(hooks, claude),
    ?assertEqual(full, maps:get(support_level, After)).

reset_removes_custom_backends_test() ->
    reset(),
    Caps = full_capability_set(full, direct_backend, exact),
    ok = beam_agent_capabilities:register_backend(temp_backend, Caps),
    ?assert(lists:member(temp_backend, beam_agent_capabilities:backends())),
    reset(),
    ?assertNot(lists:member(temp_backend, beam_agent_capabilities:backends())).

%%====================================================================
%% ensure_tables/0 idempotent
%%====================================================================

ensure_tables_idempotent_test() ->
    reset(),
    ok = beam_agent_capabilities:ensure_tables(),
    ok = beam_agent_capabilities:ensure_tables(),
    {ok, _} = beam_agent_capabilities:status(hooks, claude).

%%====================================================================
%% all/0 includes custom backends
%%====================================================================

all_includes_custom_backend_in_support_maps_test() ->
    reset(),
    Caps = full_capability_set(full, universal, exact),
    ok = beam_agent_capabilities:register_backend(custom_all, Caps),
    AllCaps = beam_agent_capabilities:all(),
    [First | _] = AllCaps,
    SupportMap = maps:get(support, First),
    ?assert(maps:is_key(custom_all, SupportMap)),
    reset().

%%====================================================================
%% assert_capability detects missing support level
%%====================================================================

assert_capability_detects_unsupported_test() ->
    reset(),
    ok = beam_agent_capabilities:register_capability(claude, hooks, #{
        support_level => missing,
        implementation => universal,
        fidelity => validated_equivalent
    }),
    ?assertEqual({error, {unsupported_capability, hooks, claude}},
        beam_agent_capabilities:assert_capability(hooks, claude)),
    reset().

%%====================================================================
%% Helpers
%%====================================================================

full_capability_set(SupportLevel, Implementation, Fidelity) ->
    CapIds = beam_agent_capabilities:capability_ids(),
    maps:from_list([{Id, #{support_level => SupportLevel,
                           implementation => Implementation,
                           fidelity => Fidelity}} || Id <- CapIds]).
