-module(beam_agent_routine_runner).
-moduledoc """
Caller-driven routine execution for BeamAgent.

This module does not start its own scheduler loop or own resident processes.
Consumers invoke it directly from their own timer, Oban/Quantum job, supervisor,
or other existing owner process.
""".

-export([
    run_now/1,
    run_due/0,
    run_due/1
]).

-type run_result() :: #{
    job_id := binary(),
    slot_at := integer(),
    run := beam_agent_runs_core:run()
}.

-doc "Execute a routine immediately without advancing its schedule.".
-spec run_now(binary()) -> {ok, beam_agent_runs_core:run()} | {error, term()}.
run_now(JobId) when is_binary(JobId) ->
    case beam_agent_routines_core:get(JobId) of
        {ok, Job} ->
            Now = erlang:system_time(millisecond),
            {Run, Outcome, Payload} = execute_job(Job, Now, true),
            RunId = maps:get(run_id, Run),
            case Outcome of
                completed ->
                    {ok, _Updated} = beam_agent_routines_core:manual_execution_succeeded(
                        JobId, RunId, result_map(Payload), Now),
                    ok = append_execution_event(<<"routine_run_completed">>, JobId, RunId, Now),
                    {ok, Run};
                cancelled ->
                    {ok, _Updated} = beam_agent_routines_core:manual_execution_succeeded(
                        JobId, RunId, result_map(Payload), Now),
                    ok = append_execution_event(<<"routine_run_cancelled">>, JobId, RunId, Now),
                    {ok, Run};
                failed ->
                    {ok, _Updated} = beam_agent_routines_core:manual_execution_failed(
                        JobId, RunId, Payload, Now),
                    ok = append_execution_event(<<"routine_run_failed">>, JobId, RunId, Now),
                    {ok, Run}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Execute every currently due routine with default runner options.".
-spec run_due() -> {ok, [run_result()]} | {error, term()}.
run_due() ->
    run_due(#{}).

-doc """
Execute all due routines at or before `Opts.now`.

Supported opts:
  - `now`
  - `limit`
  - `runner_id`
  - `claim_ttl_ms`
""".
-spec run_due(map()) -> {ok, [run_result()]} | {error, term()}.
run_due(Opts) when is_map(Opts) ->
    Now = maps:get(now, Opts, erlang:system_time(millisecond)),
    RunnerId = maps:get(runner_id, Opts, default_runner_id()),
    ClaimTtlMs = maps:get(claim_ttl_ms, Opts, 60000),
    DueFilter = (maps:with([limit], Opts))#{at => Now},
    case beam_agent_routines_core:list_due(DueFilter) of
        {ok, Jobs} ->
            Results = lists:foldl(fun(Job, Acc) ->
                SlotAt = maps:get(next_run_at, Job),
                JobId = maps:get(job_id, Job),
                case beam_agent_routines_core:claim_due_job(
                    JobId, RunnerId, SlotAt, ClaimTtlMs) of
                    {ok, _Claim} ->
                        try
                            {Run, Outcome, Payload} = execute_job(Job, SlotAt, false),
                            RunId = maps:get(run_id, Run),
                            case beam_agent_routines_core:scheduled_execution_started(
                                JobId, RunId, SlotAt, Now) of
                                {ok, _Started} ->
                                    ok = finish_scheduled(JobId, RunId, SlotAt,
                                        Outcome, Payload, Now),
                                    [#{
                                        job_id => JobId,
                                        status => executed,
                                        outcome => Outcome,
                                        slot_at => SlotAt,
                                        run => Run
                                    } | Acc];
                                {error, _} ->
                                    Acc
                            end
                        after
                            ok = beam_agent_routines_core:release_due_job(JobId, RunnerId)
                        end;
                    {error, claimed} ->
                        Acc;
                    {error, not_found} ->
                        Acc
                end
            end, [], Jobs),
            {ok, lists:reverse(Results)};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec execute_job(map(), integer(), boolean()) ->
    {beam_agent_runs_core:run(), completed | failed | cancelled, term()}.
execute_job(Job, SlotAt, Manual) ->
    Target = maps:get(target, Job),
    case maps:get(type, Target) of
        run ->
            execute_run_target(Job, Target, SlotAt, Manual);
        query ->
            execute_query_target(Job, Target, SlotAt, Manual)
    end.

-spec execute_run_target(map(), map(), integer(), boolean()) ->
    {beam_agent_runs_core:run(), completed | failed | cancelled, term()}.
execute_run_target(Job, Target, SlotAt, Manual) ->
    Scope = maps:get(scope, Target, #{}),
    RunOpts0 = maps:get(run_opts, Target, #{}),
    Metadata0 = maps:get(metadata, RunOpts0, #{}),
    RunOpts = RunOpts0#{
        kind => maps:get(kind, RunOpts0, routine),
        input => maps:get(input, RunOpts0, maps:get(payload, Job, undefined)),
        metadata => maps:merge(Metadata0, routine_metadata(Job, SlotAt, Manual, run))
    },
    {ok, Run0} = beam_agent_runs:start_run(Scope, RunOpts),
    case maps:get(outcome, Target, completed) of
        completed ->
            Result = maps:get(result, Target, maps:get(payload, Job, undefined)),
            {ok, Run} = beam_agent_runs:complete_run(maps:get(run_id, Run0), Result),
            {Run, completed, Result};
        failed ->
            ErrorTerm = maps:get(error, Target, #{reason => <<"routine failed">>}),
            {ok, Run} = beam_agent_runs:fail_run(maps:get(run_id, Run0), ErrorTerm),
            {Run, failed, ErrorTerm};
        cancelled ->
            Reason = maps:get(cancel_reason, Target, <<"routine cancelled">>),
            {ok, Run} = beam_agent_runs:cancel_run(maps:get(run_id, Run0), Reason),
            {Run, cancelled, Reason}
    end.

-spec execute_query_target(map(), map(), integer(), boolean()) ->
    {beam_agent_runs_core:run(), completed | failed | cancelled, term()}.
execute_query_target(Job, Target, SlotAt, Manual) ->
    case open_session(Target, maps:get(routing_policy, Job, #{})) of
        {ok, Session, StopSession} ->
            try
                BaseScope = #{session_id => beam_agent_core:session_identity(Session)},
                case prepare_thread(Session, maps:get(thread, Target, undefined)) of
                    {ok, ThreadScope} ->
                        Scope = maps:merge(BaseScope, ThreadScope),
                        run_query(Session, Scope, Job, Target, SlotAt, Manual);
                    {error, Reason} ->
                        Run = bootstrap_failed_run(BaseScope, Job, Target, SlotAt, Manual,
                            Reason),
                        {Run, failed, Reason}
                end
            after
                maybe_stop_session(Session, StopSession)
            end;
        {error, Reason} ->
            Run = bootstrap_failed_run(#{}, Job, Target, SlotAt, Manual, Reason),
            {Run, failed, Reason}
    end.

-spec run_query(pid(), map(), map(), map(), integer(), boolean()) ->
    {beam_agent_runs_core:run(), completed | failed | cancelled, term()}.
run_query(Session, Scope, Job, Target, SlotAt, Manual) ->
    RunOpts = #{
        kind => routine,
        input => #{prompt => maps:get(prompt, Target)},
        metadata => routine_metadata(Job, SlotAt, Manual, query)
    },
    {ok, Run0} = beam_agent_runs:start_run(Scope, RunOpts),
    RunId = maps:get(run_id, Run0),
    {ok, Step} = beam_agent_runs:start_step(RunId, #{
        kind => execute,
        metadata => #{prompt => maps:get(prompt, Target)}
    }),
    QueryOpts0 = maps:get(query_opts, Target, #{}),
    QueryOpts1 = maybe_put(thread_id, maps:get(thread_id, Scope, undefined), QueryOpts0),
    case beam_agent:query(Session, maps:get(prompt, Target), QueryOpts1) of
        {ok, Messages} ->
            Result0 = #{
                message_count => length(Messages),
                final_content => final_content(Messages)
            },
            {ok, _StepDone} = beam_agent_runs:complete_step(
                RunId, maps:get(step_id, Step), Result0),
            ContextResult = maybe_run_context_policy(Job, Scope),
            Result = maybe_put(context, ContextResult, Result0),
            {ok, Run} = beam_agent_runs:complete_run(RunId, Result),
            {Run, completed, Result};
        {error, Reason} ->
            {ok, _StepFailed} = beam_agent_runs:fail_step(
                RunId, maps:get(step_id, Step), Reason),
            {ok, Run} = beam_agent_runs:fail_run(RunId, Reason),
            {Run, failed, Reason}
    end.

-spec open_session(map(), map()) -> {ok, pid(), boolean()} | {error, term()}.
open_session(#{session := #{kind := live, ref := Session}}, _RoutingPolicy) ->
    {ok, Session, false};
open_session(#{session := #{kind := routed, opts := SessionOpts0}, stop_session := StopSession},
    RoutingPolicy) ->
    SessionOpts = merge_routing_policy(SessionOpts0, RoutingPolicy),
    case beam_agent:start_session(SessionOpts) of
        {ok, Session} -> {ok, Session, StopSession};
        {error, _} = Error -> Error
    end.

-spec prepare_thread(pid(), map() | undefined) -> {ok, map()} | {error, term()}.
prepare_thread(_Session, undefined) ->
    {ok, #{}};
prepare_thread(Session, #{thread_id := ThreadId}) ->
    case beam_agent_threads:thread_resume(Session, ThreadId) of
        {ok, _Thread} -> {ok, #{thread_id => ThreadId}};
        {error, _} = Error -> Error
    end;
prepare_thread(Session, #{start := ThreadOpts}) ->
    case beam_agent_threads:thread_start(Session, ThreadOpts) of
        {ok, Thread} -> {ok, #{thread_id => maps:get(thread_id, Thread)}};
        {error, _} = Error -> Error
    end.

-spec bootstrap_failed_run(map(), map(), map(), integer(), boolean(), term()) ->
    beam_agent_runs_core:run().
bootstrap_failed_run(Scope, Job, _Target, SlotAt, Manual, Reason) ->
    RunOpts = #{
        kind => routine,
        input => maps:get(payload, Job, undefined),
        metadata => maps:merge(
            #{bootstrap_failure => true},
            routine_metadata(Job, SlotAt, Manual, query)
        )
    },
    {ok, Run0} = beam_agent_runs:start_run(Scope, RunOpts),
    {ok, Run} = beam_agent_runs:fail_run(maps:get(run_id, Run0), Reason),
    Run.

-spec finish_scheduled(binary(), binary(), integer(), completed | failed | cancelled,
    term(), integer()) -> ok.
finish_scheduled(JobId, RunId, SlotAt, completed, Payload, Now) ->
    Result = result_map(Payload),
    {ok, _Updated} = beam_agent_routines_core:scheduled_execution_succeeded(
        JobId, RunId, SlotAt, Result, Now),
    ok = append_execution_event(<<"routine_run_completed">>, JobId, RunId, Now),
    ok;
finish_scheduled(JobId, RunId, SlotAt, cancelled, Payload, Now) ->
    Result = result_map(Payload),
    {ok, _Updated} = beam_agent_routines_core:scheduled_execution_succeeded(
        JobId, RunId, SlotAt, Result, Now),
    ok = append_execution_event(<<"routine_run_cancelled">>, JobId, RunId, Now),
    ok;
finish_scheduled(JobId, RunId, SlotAt, failed, Payload, Now) ->
    {ok, State, _Updated} = beam_agent_routines_core:scheduled_execution_failed(
        JobId, RunId, SlotAt, Payload, Now),
    EventType = case State of
        retry_scheduled -> <<"routine_retry_scheduled">>;
        _ -> <<"routine_run_failed">>
    end,
    ok = append_execution_event(EventType, JobId, RunId, Now),
    ok.

-spec merge_routing_policy(map(), map()) -> map().
merge_routing_policy(SessionOpts, RoutingPolicy) when map_size(RoutingPolicy) =:= 0 ->
    SessionOpts;
merge_routing_policy(SessionOpts, RoutingPolicy) ->
    Existing = maps:get(routing, SessionOpts, #{}),
    SessionOpts#{routing => maps:merge(Existing, RoutingPolicy)}.

-spec maybe_stop_session(pid(), boolean()) -> ok.
maybe_stop_session(Session, true) ->
    beam_agent:stop(Session);
maybe_stop_session(_Session, false) ->
    ok.

-spec maybe_run_context_policy(map(), map()) -> map() | undefined.
maybe_run_context_policy(Job, Scope) ->
    case maps:get(context_policy, maps:get(metadata, Job, #{}), undefined) of
        Policy when is_map(Policy) ->
            case beam_agent_context:maybe_compact(Scope, Policy) of
                {ok, Result} -> Result;
                {error, _} -> undefined
            end;
        _ ->
            undefined
    end.

-spec routine_metadata(map(), integer(), boolean(), atom()) -> map().
routine_metadata(Job, SlotAt, Manual, TargetType) ->
    #{
        job_id => maps:get(job_id, Job),
        slot_at => SlotAt,
        manual => Manual,
        target_type => TargetType
    }.

-spec final_content([map()]) -> binary() | undefined.
final_content(Messages) ->
    case lists:reverse(Messages) of
        [#{content := Content} | _] when is_binary(Content) -> Content;
        _ -> undefined
    end.

-spec result_map(term()) -> map().
result_map(Result) when is_map(Result) ->
    Result;
result_map(Result) ->
    #{result => Result}.

-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec default_runner_id() -> binary().
default_runner_id() ->
    unicode:characters_to_binary(erlang:pid_to_list(self())).

-spec append_execution_event(binary(), binary(), binary(), integer()) -> ok.
append_execution_event(EventType, JobId, RunId, Now) ->
    _ = beam_agent_journal_core:append(EventType, #{
        timestamp => Now,
        run_id => RunId,
        tags => [routine],
        payload => #{job_id => JobId}
    }),
    ok.
