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

seed_thread(SessionId, ThreadId, Count) ->
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

