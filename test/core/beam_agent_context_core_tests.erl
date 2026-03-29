%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_context_core.
%%%-------------------------------------------------------------------
-module(beam_agent_context_core_tests).

-include_lib("eunit/include/eunit.hrl").

maybe_compact_is_noop_below_threshold_test() ->
    reset(),
    SessionId = <<"context-noop-session">>,
    ThreadId = seed_thread(SessionId, <<"context-noop-thread">>, 2),
    {ok, Result} = beam_agent_context_core:maybe_compact(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        message_count_threshold => 10,
        visible_message_threshold => 10
    }),
    ?assertEqual(false, maps:get(compacted, Result)),
    ?assertEqual([], maps:get(triggers, Result)),
    reset().

maybe_compact_compacts_and_summarizes_when_threshold_is_hit_test() ->
    reset(),
    SessionId = <<"context-compact-session">>,
    ThreadId = seed_thread(SessionId, <<"context-compact-thread">>, 3),
    {ok, Result} = beam_agent_context_core:maybe_compact(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        message_count_threshold => 2
    }),
    ?assertEqual(true, maps:get(compacted, Result)),
    SessionSummary = maps:get(summary, maps:get(session_summary, Result)),
    ?assert(is_map(SessionSummary)),
    ThreadResult = maps:get(thread_compaction, Result),
    Thread = maps:get(thread, ThreadResult),
    ?assertEqual(0, maps:get(visible_message_count, Thread)),
    reset().

compact_now_can_promote_summary_to_memory_test() ->
    reset(),
    SessionId = <<"context-memory-session">>,
    ThreadId = seed_thread(SessionId, <<"context-memory-thread">>, 2),
    {ok, Result} = beam_agent_context_core:compact_now(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        promote_to_memory => true
    }),
    MemoryResult = maps:get(memory, Result),
    ?assertEqual(true, maps:get(promoted, MemoryResult)),
    {ok, Memories} = beam_agent_memory:list(#{session_id => SessionId}),
    ?assertEqual(1, length(Memories)),
    reset().

context_status_reports_summary_and_memory_counts_test() ->
    reset(),
    SessionId = <<"context-status-session">>,
    ThreadId = seed_thread(SessionId, <<"context-status-thread">>, 2),
    {ok, _} = beam_agent_context_core:compact_now(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        promote_to_memory => true
    }),
    {ok, Status} = beam_agent_context_core:context_status(#{
        session_id => SessionId,
        thread_id => ThreadId
    }),
    Budget = maps:get(budget, Status),
    ?assertEqual(true, maps:get(summary_present, Budget)),
    ?assertEqual(1, maps:get(memory_count, Budget)),
    ?assert(maps:is_key(thread, Status)),
    reset().

%%====================================================================
%% M17: safe budget map access in compaction_triggers
%%====================================================================

%% budget_estimate returns a result even when the session has 0 messages —
%% the maps:get/3 default-0 paths in compaction_triggers must not crash.
budget_estimate_returns_ok_with_zero_messages_test() ->
    reset(),
    SessionId = <<"ctx-budget-zero-session">>,
    _ThreadId = seed_thread(SessionId, <<"ctx-budget-zero-thread">>, 0),
    {ok, Budget} = beam_agent_context_core:budget_estimate(SessionId),
    ?assertEqual(0, maps:get(session_message_count, Budget)),
    ?assertEqual(0, maps:get(estimated_token_count, Budget)),
    ?assert(is_list(maps:get(triggers, Budget))),
    reset().

%% maybe_compact with very low thresholds fires triggers — exercises
%% all four maps:get/3 paths in compaction_triggers/2 with real Budget values.
budget_triggers_fire_when_threshold_is_zero_test() ->
    reset(),
    SessionId = <<"ctx-trigger-fire-session">>,
    _ThreadId = seed_thread(SessionId, <<"ctx-trigger-fire-thread">>, 1),
    {ok, Result} = beam_agent_context_core:maybe_compact(SessionId, #{
        message_count_threshold => 0,
        visible_message_threshold => 0,
        estimated_token_threshold => 0
    }),
    Triggers = maps:get(triggers, Result),
    ?assert(lists:member(message_count_threshold, Triggers)),
    reset().

%%====================================================================
%% z9r.11: pre_compact hook receives budget + triggers
%%====================================================================

%% compact_now fires pre_compact with budget snapshot and triggers.
compact_now_pre_compact_hook_receives_budget_test() ->
    reset(),
    SessionId = <<"ctx-hook-budget-cn">>,
    ThreadId = seed_thread(SessionId, <<"ctx-hook-budget-cn-t">>, 3),
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_compact,
        fun(Ctx) ->
            Self ! {Ref, Ctx},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    {ok, _} = beam_agent_context_core:compact_now(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{sdk_hook_registry => Reg}),
    receive
        {Ref, Ctx} ->
            ?assertEqual(pre_compact, maps:get(event, Ctx)),
            ?assertEqual(SessionId, maps:get(session_id, Ctx)),
            Budget = maps:get(budget, Ctx),
            ?assert(is_map(Budget)),
            ?assert(maps:is_key(estimated_token_count, Budget)),
            ?assert(maps:is_key(session_message_count, Budget)),
            ?assert(maps:is_key(triggers, Budget)),
            ?assert(is_list(maps:get(triggers, Ctx)))
    after 1000 ->
        ?assert(false)
    end,
    reset().

%% maybe_compact fires pre_compact with budget and matching triggers.
maybe_compact_pre_compact_hook_receives_budget_test() ->
    reset(),
    SessionId = <<"ctx-hook-budget-mc">>,
    ThreadId = seed_thread(SessionId, <<"ctx-hook-budget-mc-t">>, 3),
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_compact,
        fun(Ctx) ->
            Self ! {Ref, Ctx},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    {ok, _} = beam_agent_context_core:maybe_compact(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        sdk_hook_registry => Reg,
        message_count_threshold => 1
    }),
    receive
        {Ref, Ctx} ->
            ?assertEqual(pre_compact, maps:get(event, Ctx)),
            ?assertEqual(SessionId, maps:get(session_id, Ctx)),
            Budget = maps:get(budget, Ctx),
            ?assert(is_map(Budget)),
            ?assert(maps:is_key(estimated_token_count, Budget)),
            Triggers = maps:get(triggers, Ctx),
            ?assert(is_list(Triggers)),
            ?assert(lists:member(message_count_threshold, Triggers))
    after 1000 ->
        ?assert(false)
    end,
    reset().

%% maybe_compact below threshold: no hook fired, no budget in context.
maybe_compact_no_hook_when_below_threshold_test() ->
    reset(),
    SessionId = <<"ctx-hook-nohook">>,
    ThreadId = seed_thread(SessionId, <<"ctx-hook-nohook-t">>, 2),
    Self = self(),
    Ref = make_ref(),
    H = beam_agent_hooks_core:hook(pre_compact,
        fun(Ctx) ->
            Self ! {Ref, Ctx},
            {ok, Ctx}
        end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    {ok, Result} = beam_agent_context_core:maybe_compact(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        sdk_hook_registry => Reg,
        message_count_threshold => 100,
        visible_message_threshold => 100
    }),
    ?assertEqual(false, maps:get(compacted, Result)),
    receive
        {Ref, _} -> ?assert(false)
    after 100 ->
        ok
    end,
    reset().

%% pre_compact hook can deny compaction with budget-aware logic.
compact_now_pre_compact_hook_denies_with_budget_test() ->
    reset(),
    SessionId = <<"ctx-hook-deny-budget">>,
    ThreadId = seed_thread(SessionId, <<"ctx-hook-deny-budget-t">>, 3),
    H = beam_agent_hooks_core:hook(pre_compact,
        fun(Ctx) ->
            Budget = maps:get(budget, Ctx),
            case maps:get(estimated_token_count, Budget, 0) < 1000 of
                true -> {deny, <<"tokens too low">>};
                false -> {ok, Ctx}
            end
        end),
    Reg = beam_agent_hooks_core:register_hook(H, beam_agent_hooks_core:new_registry()),
    ?assertMatch({error, {hook_denied, <<"tokens too low">>}},
        beam_agent_context_core:compact_now(#{
            session_id => SessionId,
            thread_id => ThreadId
        }, #{sdk_hook_registry => Reg})),
    reset().

seed_thread(SessionId, ThreadId, Count) ->
    %% Ensure a session exists in the store so budget_estimate can find it
    %% even when Count is 0 (no messages to auto-vivify the session).
    ok = beam_agent_session_store_core:register_session(SessionId, #{}),
    {ok, _Thread} = beam_agent_threads_core:start_thread(SessionId, #{
        thread_id => ThreadId,
        name => ThreadId
    }),
    ok = lists:foreach(fun(Index) ->
        beam_agent_threads_core:record_thread_message(SessionId, ThreadId, #{
            type => user,
            content => list_to_binary(io_lib:format("message-~p", [Index]))
        })
    end, lists:seq(1, Count)),
    ThreadId.

reset() ->
    ok = beam_agent_memory:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok.

