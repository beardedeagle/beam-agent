%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_runs_core.
%%%-------------------------------------------------------------------
-module(beam_agent_runs_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    ok = beam_agent_runs_core:ensure_tables(),
    ok = beam_agent_runs_core:ensure_tables(),
    ok = beam_agent_runs_core:ensure_tables(),
    ok = beam_agent_runs_core:clear().

start_run_persists_scope_and_lists_by_filter_test() ->
    reset(),
    SessionId = unique_binary("runs-session"),
    ThreadId = unique_binary("runs-thread"),
    {ok, Run} = beam_agent_runs_core:start_run(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        kind => workflow,
        input => #{goal => <<"ship">>},
        metadata => #{origin => unit}
    }),
    ?assertMatch(<<"run_", _/binary>>, maps:get(run_id, Run)),
    ?assertEqual(running, maps:get(status, Run)),
    ?assertEqual(SessionId, maps:get(session_id, Run)),
    ?assertEqual(ThreadId, maps:get(thread_id, Run)),
    {ok, Run} = beam_agent_runs_core:get_run(maps:get(run_id, Run)),
    {ok, [Listed]} = beam_agent_runs_core:list_runs(#{session_id => SessionId}),
    ?assertEqual(maps:get(run_id, Run), maps:get(run_id, Listed)),
    reset().

child_run_inherits_parent_scope_test() ->
    reset(),
    SessionId = unique_binary("parent-session"),
    ThreadId = unique_binary("parent-thread"),
    {ok, Parent} = beam_agent_runs_core:start_run(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        kind => parent
    }),
    {ok, Child} = beam_agent_runs_core:start_run(#{
        parent_run_id => maps:get(run_id, Parent)
    }, #{
        kind => child
    }),
    ?assertEqual(maps:get(run_id, Parent), maps:get(parent_run_id, Child)),
    ?assertEqual(SessionId, maps:get(session_id, Child)),
    ?assertEqual(ThreadId, maps:get(thread_id, Child)),
    reset().

child_run_rejects_inconsistent_parent_scope_test() ->
    reset(),
    {ok, Parent} = beam_agent_runs_core:start_run(#{
        session_id => <<"sess-parent">>,
        thread_id => <<"thread-parent">>
    }, #{}),
    ?assertEqual({error, inconsistent_parent_scope},
        beam_agent_runs_core:start_run(#{
            parent_run_id => maps:get(run_id, Parent),
            session_id => <<"sess-other">>
        }, #{})),
    reset().

start_step_requires_active_run_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-step-inactive">>, #{}),
    {ok, _Cancelled} = beam_agent_runs_core:cancel_run(
        maps:get(run_id, Run),
        <<"stopped">>
    ),
    ?assertEqual({error, run_not_active},
        beam_agent_runs_core:start_step(maps:get(run_id, Run), #{})),
    reset().

complete_run_rejects_active_steps_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-active-step">>, #{}),
    {ok, _Step} = beam_agent_runs_core:start_step(maps:get(run_id, Run), #{
        kind => build
    }),
    ?assertEqual({error, active_steps},
        beam_agent_runs_core:complete_run(
            maps:get(run_id, Run),
            #{summary => <<"done">>}
        )),
    reset().

fail_run_cascades_running_steps_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-fail-run">>, #{}),
    RunId = maps:get(run_id, Run),
    {ok, ActiveStep} = beam_agent_runs_core:start_step(RunId, #{kind => compile}),
    {ok, DoneStep} = beam_agent_runs_core:start_step(RunId, #{kind => lint}),
    {ok, _CompletedDoneStep} = beam_agent_runs_core:complete_step(
        RunId,
        maps:get(step_id, DoneStep),
        #{status => ok}
    ),
    Failure = #{reason => <<"tool crashed">>},
    {ok, FailedRun} = beam_agent_runs_core:fail_run(RunId, Failure),
    ?assertEqual(failed, maps:get(status, FailedRun)),
    ?assertEqual(Failure, maps:get(error, FailedRun)),
    {ok, FailedActiveStep} = beam_agent_runs_core:get_step(
        RunId,
        maps:get(step_id, ActiveStep)
    ),
    ?assertEqual(failed, maps:get(status, FailedActiveStep)),
    ?assertEqual(Failure, maps:get(error, FailedActiveStep)),
    {ok, CompletedStep} = beam_agent_runs_core:get_step(
        RunId,
        maps:get(step_id, DoneStep)
    ),
    ?assertEqual(completed, maps:get(status, CompletedStep)),
    reset().

cancel_run_cascades_running_steps_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-cancel-run">>, #{}),
    RunId = maps:get(run_id, Run),
    {ok, Step} = beam_agent_runs_core:start_step(RunId, #{kind => review}),
    Reason = <<"user cancelled">>,
    {ok, CancelledRun} = beam_agent_runs_core:cancel_run(RunId, Reason),
    ?assertEqual(cancelled, maps:get(status, CancelledRun)),
    ?assertEqual(Reason, maps:get(cancel_reason, CancelledRun)),
    {ok, CancelledStep} = beam_agent_runs_core:get_step(
        RunId,
        maps:get(step_id, Step)
    ),
    ?assertEqual(cancelled, maps:get(status, CancelledStep)),
    ?assertEqual(Reason, maps:get(cancel_reason, CancelledStep)),
    reset().

step_lifecycle_roundtrip_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-step-roundtrip">>, #{
        kind => workflow
    }),
    RunId = maps:get(run_id, Run),
    StepId = <<"step-explicit">>,
    {ok, Step} = beam_agent_runs_core:start_step(RunId, #{
        step_id => StepId,
        kind => review,
        metadata => #{order => 1}
    }),
    ?assertEqual(StepId, maps:get(step_id, Step)),
    {ok, StoredStep} = beam_agent_runs_core:get_step(RunId, StepId),
    ?assertEqual(review, maps:get(kind, StoredStep)),
    {ok, CompletedStep} = beam_agent_runs_core:complete_step(RunId, StepId, #{ok => true}),
    ?assertEqual(completed, maps:get(status, CompletedStep)),
    {ok, ListedSteps} = beam_agent_runs_core:list_steps(RunId),
    ?assertEqual(1, length(ListedSteps)),
    {ok, CompletedRun} = beam_agent_runs_core:complete_run(RunId, #{summary => <<"ready">>}),
    ?assertEqual(completed, maps:get(status, CompletedRun)),
    reset().

list_runs_filters_by_status_test() ->
    reset(),
    SessionId = unique_binary("filter-session"),
    {ok, Run1} = beam_agent_runs_core:start_run(SessionId, #{kind => alpha}),
    timer:sleep(2),
    {ok, Run2} = beam_agent_runs_core:start_run(SessionId, #{kind => beta}),
    {ok, _CompletedRun1} = beam_agent_runs_core:complete_run(
        maps:get(run_id, Run1),
        #{done => true}
    ),
    {ok, [OnlyRunning]} = beam_agent_runs_core:list_runs(#{
        session_id => SessionId,
        status => running
    }),
    ?assertEqual(maps:get(run_id, Run2), maps:get(run_id, OnlyRunning)),
    reset().

list_steps_returns_oldest_first_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(<<"sess-step-order">>, #{}),
    RunId = maps:get(run_id, Run),
    {ok, First} = beam_agent_runs_core:start_step(RunId, #{kind => one}),
    timer:sleep(2),
    {ok, Second} = beam_agent_runs_core:start_step(RunId, #{kind => two}),
    {ok, [ListedFirst, ListedSecond]} = beam_agent_runs_core:list_steps(RunId),
    ?assertEqual(maps:get(step_id, First), maps:get(step_id, ListedFirst)),
    ?assertEqual(maps:get(step_id, Second), maps:get(step_id, ListedSecond)),
    reset().

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

reset() ->
    ok = beam_agent_runs_core:clear().

unique_binary(Prefix) ->
    list_to_binary(io_lib:format("~s-~p", [Prefix,
        erlang:unique_integer([positive, monotonic])])).
