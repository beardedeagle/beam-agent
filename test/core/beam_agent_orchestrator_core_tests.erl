%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_orchestrator_core.
%%%-------------------------------------------------------------------
-module(beam_agent_orchestrator_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    reset(),
    ok = beam_agent_orchestrator_core:ensure_tables(),
    ok = beam_agent_orchestrator_core:ensure_tables(),
    ok = beam_agent_orchestrator_core:ensure_tables(),
    reset().

spawn_creates_cross_session_child_lineage_test() ->
    reset(),
    ParentSessionId = unique_binary("orchestrator-parent-session"),
    ChildSessionId = unique_binary("orchestrator-child-session"),
    beam_agent_test_helpers:register_session(ParentSessionId, gemini),
    beam_agent_test_helpers:register_session(ChildSessionId, codex),
    {ok, ParentRun} = beam_agent_runs:start_run(ParentSessionId, #{kind => parent}),
    ParentRunId = maps:get(run_id, ParentRun),
    {ok, Child} = beam_agent_orchestrator_core:spawn(ParentRunId, #{
        session => ChildSessionId,
        metadata => #{origin => spawn}
    }),
    ChildRun = maps:get(run, Child),
    ?assertEqual(ParentRunId, maps:get(parent_run_id, Child)),
    ?assertEqual(session, maps:get(substrate, Child)),
    ?assertEqual(ChildSessionId, maps:get(session_id, ChildRun)),
    {ok, [Listed]} = beam_agent_orchestrator_core:list_children(ParentRunId),
    ?assertEqual(maps:get(run_id, ChildRun), maps:get(run_id, maps:get(run, Listed))),
    reset().

spawn_can_open_child_thread_under_parent_session_test() ->
    reset(),
    SessionId = unique_binary("orchestrator-thread-session"),
    beam_agent_test_helpers:register_session(SessionId, gemini),
    {ok, ParentRun} = beam_agent_runs:start_run(SessionId, #{
        kind => parent,
        metadata => #{scope => thread}
    }),
    ParentRunId = maps:get(run_id, ParentRun),
    {ok, Child} = beam_agent_orchestrator_core:spawn(ParentRunId, #{
        thread => #{start => #{name => <<"child-thread">>}}
    }),
    ChildRun = maps:get(run, Child),
    ?assertEqual(thread, maps:get(substrate, Child)),
    ?assert(is_binary(maps:get(thread_id, ChildRun))),
    ?assertMatch(#{thread_id := _}, maps:get(thread, Child)),
    reset().

delegate_collects_lineage_and_journal_test() ->
    reset(),
    SessionId = unique_binary("orchestrator-delegate-session"),
    beam_agent_test_helpers:register_session(SessionId, gemini),
    {ok, ParentRun} = beam_agent_runs:start_run(SessionId, #{kind => parent}),
    ParentRunId = maps:get(run_id, ParentRun),
    Task = #{goal => <<"inspect">>, priority => high},
    {ok, ChildRun} = beam_agent_orchestrator_core:delegate(ParentRunId, Task, #{
        metadata => #{lane => analysis}
    }),
    ChildRunId = maps:get(run_id, ChildRun),
    ?assertEqual({error, timeout}, beam_agent_orchestrator_core:await(ChildRunId, 0)),
    {ok, _Completed} = beam_agent_runs:complete_run(ChildRunId, #{done => true}),
    {ok, Awaited} = beam_agent_orchestrator_core:await(ChildRunId, 10),
    ?assertEqual(completed, maps:get(status, Awaited)),
    {ok, Collected} = beam_agent_orchestrator_core:collect(ChildRunId, #{}),
    ?assertEqual(Task, maps:get(task, maps:get(link, Collected))),
    EventTypes = [maps:get(event_type, Entry) || Entry <- maps:get(journal, Collected)],
    ?assert(lists:member(<<"run_started">>, EventTypes)),
    ?assert(lists:member(<<"orchestrator_delegated">>, EventTypes)),
    reset().

cancel_cascades_to_active_descendants_only_test() ->
    reset(),
    SessionId = unique_binary("orchestrator-cancel-session"),
    beam_agent_test_helpers:register_session(SessionId, gemini),
    {ok, ParentRun} = beam_agent_runs:start_run(SessionId, #{kind => parent}),
    ParentRunId = maps:get(run_id, ParentRun),
    {ok, Child1} = beam_agent_orchestrator_core:delegate(ParentRunId, #{task => one}, #{}),
    {ok, Child2} = beam_agent_orchestrator_core:delegate(ParentRunId, #{task => two}, #{}),
    Child1RunId = maps:get(run_id, Child1),
    Child2RunId = maps:get(run_id, Child2),
    {ok, _CompletedChild1} = beam_agent_runs:complete_run(Child1RunId, #{ok => true}),
    ok = beam_agent_orchestrator_core:cancel(ParentRunId, <<"stop">>),
    {ok, CancelledParent} = beam_agent_runs:get_run(ParentRunId),
    {ok, CompletedChild1} = beam_agent_runs:get_run(Child1RunId),
    {ok, CancelledChild2} = beam_agent_runs:get_run(Child2RunId),
    ?assertEqual(cancelled, maps:get(status, CancelledParent)),
    ?assertEqual(completed, maps:get(status, CompletedChild1)),
    ?assertEqual(cancelled, maps:get(status, CancelledChild2)),
    ?assertMatch(#{cancelled_by_parent := ParentRunId},
        maps:get(cancel_reason, CancelledChild2)),
    {ok, [FirstListed, SecondListed]} = beam_agent_orchestrator_core:list_children(ParentRunId),
    ListedStatuses = [maps:get(status, maps:get(run, Child)) ||
        Child <- [FirstListed, SecondListed]],
    ?assertEqual([completed, cancelled], ListedStatuses),
    reset().

reset() ->
    ok = beam_agent_orchestrator_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_journal_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_session_store_core:clear().

unique_binary(Prefix) ->
    list_to_binary(io_lib:format("~s-~p", [Prefix,
        erlang:unique_integer([positive, monotonic])])).
