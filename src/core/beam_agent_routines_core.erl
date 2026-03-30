-module(beam_agent_routines_core).
-moduledoc """
Canonical process-free routines and scheduled execution for BeamAgent.

Routines are durable job records that describe delayed or recurring work.
They do not own timers or daemon processes; instead, BeamAgent exposes a
caller-driven runner surface that external schedulers or existing owner
processes can invoke.

This module owns:

- job normalization and validation
- schedule normalization and advancement
- mutable routine job state transitions
- journal emission for routine lifecycle events

Target execution itself lives in `beam_agent_routine_runner`.
""".

-export([
    ensure_tables/0,
    clear/0,
    create/1,
    update/2,
    cancel/1,
    get/1,
    list/0,
    list/1,
    due/0,
    due/1,
    list_due/0,
    list_due/1,
    next_due_at/0,
    claim_due_job/4,
    release_due_job/2,
    scheduled_execution_started/4,
    scheduled_execution_succeeded/5,
    scheduled_execution_failed/5,
    manual_execution_succeeded/4,
    manual_execution_failed/4
]).

-export_type([
    schedule/0,
    retry_policy/0,
    session_target/0,
    thread_target/0,
    target/0,
    job_input/0,
    job_patch/0,
    job_record/0,
    job_filter/0,
    due_filter/0
]).

-type schedule() ::
    #{
        type := once,
        at := integer()
    }
  | #{
        type := interval,
        every_ms := pos_integer(),
        start_at => integer(),
        catch_up => boolean()
    }.

-type retry_policy() :: #{
    max_attempts => pos_integer(),
    backoff_ms => non_neg_integer()
}.

-type session_target() ::
    #{
        kind := live,
        ref := pid()
    }
  | #{
        kind := routed,
        opts := beam_agent_core:session_opts()
    }.

-type thread_target() ::
    #{
        thread_id := binary()
    }
  | #{
        start := map()
    }.

-type target() ::
    #{
        type := run,
        scope => beam_agent_runs_core:scope(),
        run_opts => beam_agent_runs_core:run_opts(),
        outcome => completed | failed | cancelled,
        result => term(),
        error => term(),
        cancel_reason => term()
    }
  | #{
        type := query,
        session := session_target(),
        prompt := binary(),
        query_opts => beam_agent_core:query_opts(),
        thread => thread_target(),
        stop_session => boolean()
    }.

-type job_input() :: #{
    job_id => binary(),
    schedule := schedule(),
    target := target(),
    payload => term(),
    routing_policy => map(),
    retry_policy => retry_policy(),
    idempotency_key => binary(),
    state => active | paused,
    next_run_at => integer(),
    metadata => map()
}.

-type job_patch() :: #{
    schedule => schedule(),
    target => target(),
    payload => term(),
    routing_policy => map(),
    retry_policy => retry_policy(),
    idempotency_key => binary(),
    state => active | paused,
    next_run_at => integer(),
    metadata => map()
}.

-type job_state() ::
    active
  | running
  | retry_waiting
  | paused
  | completed
  | exhausted
  | cancelled.

-type job_record() :: #{
    job_id := binary(),
    schedule := schedule(),
    target := target(),
    payload => term(),
    routing_policy := map(),
    retry_policy := retry_policy(),
    idempotency_key := binary(),
    state := job_state(),
    metadata => map(),
    next_run_at => integer(),
    current_run_id => binary(),
    current_slot_at => integer(),
    attempt_count := non_neg_integer(),
    last_run_id => binary(),
    last_run_at => integer(),
    last_result => map(),
    last_error => term(),
    created_at := integer(),
    updated_at := integer(),
    cancelled_at => integer(),
    completed_at => integer()
}.

-type job_filter() :: beam_agent_routines_store:job_filter().
-type due_filter() :: beam_agent_routines_store:due_filter().

-type normalized_job_input() :: #{
    schedule := schedule(),
    target := target(),
    routing_policy := map(),
    retry_policy := retry_policy(),
    idempotency_key := binary(),
    state := active | paused,
    job_id => binary(),
    payload => term(),
    next_run_at => integer(),
    metadata => map()
}.

-type normalized_patch() :: #{
    schedule => schedule(),
    target => target(),
    routing_policy => map(),
    retry_policy => retry_policy(),
    idempotency_key => binary(),
    state => active | paused,
    payload => term(),
    next_run_at => integer(),
    metadata => map()
}.
-type routine_validation_tag() :: invalid_job | invalid_patch.
-type routine_normalize_error_tag() ::
    invalid_job
  | unsupported_filter
  | unsupported_job_key
  | unsupported_patch_key
  | unsupported_retry_key
  | unsupported_schedule_key
  | unsupported_session_target_key
  | unsupported_target_key
  | unsupported_thread_key.
-type routine_normalize_error() :: {routine_normalize_error_tag(), atom()}.
-type thread_target_error() ::
    {invalid_job, thread}
  | {unsupported_thread_key, atom()}.
-type routine_error_tag() ::
    routine_normalize_error_tag()
  | invalid_patch
  | policy_denied
  | invalid_filter.
-type routine_error() ::
    routine_normalize_error()
  | {invalid_patch, atom()}
  | {invalid_filter, atom()}
  | {policy_denied, binary()}.
-type routine_action() :: cancelled | created | updated.
-type routine_operation() :: cancel | create | list_due | update.
-type routine_optional_key() ::
    cancel_reason | due_before | error | job_id | limit | metadata | next_run_at |
    outcome | payload | profile_id | result | run_id | thread.
-type routine_run_target_base() :: #{
    type := run,
    scope := beam_agent_runs_core:scope(),
    run_opts := map(),
    outcome => completed | failed | cancelled,
    result => term(),
    error => term(),
    cancel_reason => term()
}.
-type routine_query_target_base() :: #{
    type := query,
    session := session_target(),
    prompt := binary(),
    query_opts := map(),
    stop_session := boolean(),
    thread => thread_target()
}.
-type routine_put_map() ::
    due_filter()
  | job_filter()
  | job_record()
  | normalized_job_input()
  | normalized_patch()
  | routine_run_target_base()
  | routine_query_target_base()
  | #{decision := allow, patch => map()}
  | #{run_id => binary()}
  | #{
        payload := map(),
        tags := [routine | query | run, ...],
        timestamp := integer()
    }.
-type routine_telemetry_meta() :: #{
    at => integer(),
    due_before => integer(),
    found => boolean(),
    idempotency_key => binary(),
    job_id => binary(),
    last_run_id => binary(),
    limit => pos_integer(),
    next_run_at => integer(),
    result_count => non_neg_integer(),
    state => job_state()
}.
-type routine_audit_details() :: #{
    decision := allow,
    patch => map()
}.

-doc "Ensure the routines store tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_routines_store:ensure_tables().

-doc "Clear all routines state. Intended for tests and full resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_routines_store:clear().

-doc "Create a new routine job.".
-spec create(map()) ->
    {ok, job_record()} |
    {error, already_exists | {unsupported_job_key, atom()} |
        {unsupported_schedule_key, atom()} | {unsupported_target_key, atom()} |
        {unsupported_session_target_key, atom()} | {unsupported_thread_key, atom()} |
        {unsupported_retry_key, atom()} | {invalid_job, atom()}}.
create(JobInput) when is_map(JobInput) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    TeleMeta = telemetry_job_input_meta(JobInput),
    StartTime = telemetry_start(create, TeleMeta),
    Result = case normalize_job_input(JobInput, Now) of
        {ok, Normalized} ->
            case evaluate_routine_policy(Normalized) of
                allow ->
            JobId = maps:get(job_id, Normalized, generate_job_id()),
            NextRunAt = compute_initial_next_run_at(
                maps:get(schedule, Normalized),
                maps:get(next_run_at, Normalized, undefined),
                Now
            ),
            Job0 = #{
                job_id => JobId,
                schedule => maps:get(schedule, Normalized),
                target => maps:get(target, Normalized),
                routing_policy => maps:get(routing_policy, Normalized),
                retry_policy => maps:get(retry_policy, Normalized),
                idempotency_key => maps:get(idempotency_key, Normalized),
                state => maps:get(state, Normalized),
                metadata => maps:get(metadata, Normalized, #{}),
                attempt_count => 0,
                created_at => Now,
                updated_at => Now
            },
            Job1 = maybe_put(payload, maps:get(payload, Normalized, undefined), Job0),
            Job2 = maybe_put_next_run_at(Job1, NextRunAt),
            case beam_agent_routines_store:get_job(JobId) of
                {ok, _Existing} ->
                    {error, already_exists};
                {error, not_found} ->
                    ok = beam_agent_routines_store:put_job(Job2),
                    {ok, _} = append_job_event(<<"routine_created">>, Job2, #{}),
                    ok = audit_routine_event(created, Job2, #{decision => allow}),
                    {ok, Job2}
            end;
                {deny, Reason} ->
                    {error, {policy_denied, Reason}}
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(create, StartTime, Result, TeleMeta),
    Result.

-doc "Update a routine job. Busy or terminal jobs reject mutable updates.".
-spec update(binary(), map()) ->
    {ok, job_record()} |
    {error, not_found | job_busy | job_terminal |
        {unsupported_patch_key, atom()} | {unsupported_schedule_key, atom()} |
        {unsupported_target_key, atom()} | {unsupported_session_target_key, atom()} |
        {unsupported_thread_key, atom()} | {unsupported_retry_key, atom()} |
        {invalid_patch, atom()}}.
update(JobId, Patch) when is_binary(JobId), is_map(Patch) ->
    ensure_tables(),
    TeleMeta = telemetry_patch_meta(JobId, Patch),
    StartTime = telemetry_start(update, TeleMeta),
    Result = case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            case allow_update(maps:get(state, Job)) of
                ok ->
                    Now = erlang:system_time(millisecond),
                    case normalize_patch(Patch) of
                        {ok, Normalized} ->
                            Updated = apply_patch(Job, Normalized, Now),
                            ok = beam_agent_routines_store:put_job(Updated),
                            {ok, _} = append_job_event(<<"routine_updated">>, Updated, #{
                                patch => redacted_patch(Normalized)
                            }),
                            ok = audit_routine_event(updated, Updated, #{
                                decision => allow,
                                patch => redacted_patch(Normalized)
                            }),
                            {ok, Updated};
                        {error, _} = Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        {error, not_found} ->
            {error, not_found}
    end,
    telemetry_finish(update, StartTime, Result, TeleMeta),
    Result.

-doc "Cancel a routine job and cancel any currently active canonical run.".
-spec cancel(binary()) -> ok | {error, not_found}.
cancel(JobId) when is_binary(JobId) ->
    ensure_tables(),
    StartTime = telemetry_start(cancel, #{job_id => JobId}),
    Result = case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            maybe_cancel_current_run(Job),
            Now = erlang:system_time(millisecond),
            Cancelled0 = Job#{
                state => cancelled,
                updated_at => Now,
                cancelled_at => Now
            },
            Cancelled1 = maps:without([next_run_at, current_run_id, current_slot_at],
                Cancelled0),
            Cancelled2 = Cancelled1#{attempt_count => 0},
            ok = beam_agent_routines_store:put_job(Cancelled2),
            ok = beam_agent_routines_store:release_claim(JobId, any_runner()),
            {ok, _} = append_job_event(<<"routine_cancelled">>, Cancelled2, #{}),
            ok = audit_routine_event(cancelled, Cancelled2, #{decision => allow}),
            ok;
        {error, not_found} ->
            {error, not_found}
    end,
    case Result of
        ok ->
            telemetry_stop(cancel, StartTime, #{job_id => JobId, state => cancelled}),
            ok;
        {error, not_found} = ErrorResult ->
            telemetry_stop(cancel, StartTime, #{job_id => JobId, found => false}),
            ErrorResult
    end.

-doc "Fetch a routine job by id.".
-spec get(binary()) -> {ok, job_record()} | {error, not_found}.
get(JobId) when is_binary(JobId) ->
    beam_agent_routines_store:get_job(JobId).

-doc "List all routine jobs without filters.".
-spec list() -> {ok, [job_record()]}.
list() ->
    list(#{}).

-doc "List routine jobs with exact-match filters.".
-spec list(job_filter()) -> {ok, [job_record()]} | {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
list(Filter) when is_map(Filter) ->
    case normalize_job_filter(Filter) of
        {ok, Normalized} ->
            beam_agent_routines_store:list_jobs(Normalized);
        {error, _} = Error ->
            Error
    end.

-doc "Alias for list_due/0.".
-spec due() -> {ok, [job_record()]}.
due() ->
    list_due().

-doc "Alias for list_due/1.".
-spec due(map()) -> {ok, [job_record()]} | {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
due(Filter) ->
    list_due(Filter).

-doc "List jobs currently due as of now.".
-spec list_due() -> {ok, [job_record()]}.
list_due() ->
    list_due(#{}).

-doc "List jobs currently due using an explicit due filter.".
-spec list_due(map()) -> {ok, [job_record()]} | {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
list_due(Filter) when is_map(Filter) ->
    Now = maps:get(at, Filter, erlang:system_time(millisecond)),
    TeleMeta = telemetry_due_filter_meta(Filter, Now),
    StartTime = telemetry_start(list_due, TeleMeta),
    case normalize_due_filter(Filter, Now) of
        {ok, Normalized} ->
            {ok, Jobs} = Result = beam_agent_routines_store:list_due_jobs(Now, Normalized),
            telemetry_stop(list_due, StartTime,
                TeleMeta#{result_count => length(Jobs)}),
            Result;
        {error, _} = Error ->
            telemetry_exception(list_due, Error, TeleMeta),
            Error
    end.

-doc "Return the earliest next-run timestamp in the routines due index.".
-spec next_due_at() -> {ok, integer()} | {error, none}.
next_due_at() ->
    case beam_agent_routines_store:next_due_at() of
        undefined -> {error, none};
        DueAt when is_integer(DueAt) -> {ok, DueAt}
    end.

-doc "Claim a due job for runner-driven execution.".
-spec claim_due_job(binary(), binary(), integer(), pos_integer()) ->
    {ok, beam_agent_routines_store:claim_record()} | {error, not_found | already_claimed | stale_slot}.
claim_due_job(JobId, RunnerId, SlotAt, ClaimTtlMs) ->
    beam_agent_routines_store:claim_job(JobId, RunnerId, SlotAt, ClaimTtlMs).

-doc "Release a due-job claim.".
-spec release_due_job(binary(), binary()) -> ok.
release_due_job(JobId, RunnerId) ->
    case RunnerId of
        any when is_atom(any) ->
            ok = beam_agent_routines_store:release_claim(JobId, any_runner());
        _ ->
            ok = beam_agent_routines_store:release_claim(JobId, RunnerId)
    end.

-doc "Mark a scheduled execution as started.".
-spec scheduled_execution_started(binary(), binary(), integer(), integer()) ->
    {ok, job_record()} | {error, not_found | stale_slot | stale_retry_state | invalid_state}.
scheduled_execution_started(JobId, RunId, SlotAt, Now)
  when is_binary(JobId), is_binary(RunId), is_integer(SlotAt), is_integer(Now) ->
    case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            case can_start_scheduled_execution(Job, RunId, SlotAt) of
                ok ->
                    Attempt = maps:get(attempt_count, Job, 0) + 1,
                    Updated = Job#{
                        state => running,
                        current_run_id => RunId,
                        current_slot_at => SlotAt,
                        attempt_count => Attempt,
                        last_run_id => RunId,
                        last_run_at => Now,
                        updated_at => Now
                    },
                    ok = beam_agent_routines_store:put_job(Updated),
                    {ok, Updated};
                {error, _} = Error ->
                    Error
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Mark a scheduled execution as succeeded and advance the schedule.".
-spec scheduled_execution_succeeded(binary(), binary(), integer(), map(), integer()) ->
    {ok, job_record()} | {error, not_found | stale_run_mismatch}.
scheduled_execution_succeeded(JobId, RunId, SlotAt, Result, Now)
  when is_binary(JobId), is_binary(RunId), is_integer(SlotAt), is_map(Result),
       is_integer(Now) ->
    case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            case validate_current_run(Job, RunId, SlotAt) of
                ok ->
                    {NextState, NextRunAt} =
                        next_after_success(maps:get(schedule, Job), SlotAt, Now),
                    Updated0 = Job#{
                        state => NextState,
                        attempt_count => 0,
                        last_run_id => RunId,
                        last_run_at => Now,
                        last_result => Result,
                        updated_at => Now
                    },
                    Updated1 = maps:without([current_run_id, current_slot_at, last_error],
                        Updated0),
                    Updated2 = maybe_put_next_run_at(Updated1, NextRunAt),
                    Updated3 = maybe_put_terminal_timestamp(Updated2, NextState, Now),
                    ok = beam_agent_routines_store:put_job(Updated3),
                    {ok, Updated3};
                {error, _} = Error ->
                    Error
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Mark a scheduled execution as failed and decide whether to retry or terminalize.".
-spec scheduled_execution_failed(binary(), binary(), integer(), term(), integer()) ->  %% Error is genuinely term(): caller-provided failure reason
    {ok, retry_scheduled | exhausted | active, job_record()} | {error, not_found | stale_run_mismatch}.
scheduled_execution_failed(JobId, RunId, SlotAt, Error, Now)
  when is_binary(JobId), is_binary(RunId), is_integer(SlotAt), is_integer(Now) ->
    case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            case validate_current_run(Job, RunId, SlotAt) of
                ok ->
                    RetryPolicy = maps:get(retry_policy, Job),
                    Attempt = maps:get(attempt_count, Job, 1),
                    case Attempt < maps:get(max_attempts, RetryPolicy, 1) of
                        true ->
                            RetryAt = Now + maps:get(backoff_ms, RetryPolicy, 0),
                            Updated = Job#{
                                state => retry_waiting,
                                next_run_at => RetryAt,
                                last_run_id => RunId,
                                last_run_at => Now,
                                last_error => Error,
                                updated_at => Now
                            },
                            ok = beam_agent_routines_store:put_job(Updated),
                            {ok, retry_scheduled, Updated};
                        false ->
                            {NextState, NextRunAt} =
                                next_after_failure(maps:get(schedule, Job), SlotAt, Now),
                            Updated0 = Job#{
                                state => NextState,
                                attempt_count => 0,
                                last_run_id => RunId,
                                last_run_at => Now,
                                last_error => Error,
                                updated_at => Now
                            },
                            Updated1 = maps:without([current_run_id, current_slot_at, last_result],
                                Updated0),
                            Updated2 = maybe_put_next_run_at(Updated1, NextRunAt),
                            Updated3 = maybe_put_terminal_timestamp(Updated2, NextState, Now),
                            ok = beam_agent_routines_store:put_job(Updated3),
                            {ok, NextState, Updated3}
                    end;
                {error, _} = Error0 ->
                    Error0
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Record the result of a manual run_now execution without changing schedule state.".
-spec manual_execution_succeeded(binary(), binary(), map(), integer()) ->
    {ok, job_record()} | {error, not_found | job_busy | job_terminal}.
manual_execution_succeeded(JobId, RunId, Result, Now)
  when is_binary(JobId), is_binary(RunId), is_map(Result), is_integer(Now) ->
    manual_execution_update(JobId, fun(Job) ->
        Job#{
            last_run_id => RunId,
            last_run_at => Now,
            last_result => Result,
            updated_at => Now
        }
    end).

-doc "Record the failure of a manual run_now execution without changing schedule state.".
-spec manual_execution_failed(binary(), binary(), term(), integer()) ->  %% Error is genuinely term(): caller-provided failure reason
    {ok, job_record()} | {error, not_found | job_busy | job_terminal}.
manual_execution_failed(JobId, RunId, Error, Now)
  when is_binary(JobId), is_binary(RunId), is_integer(Now) ->
    manual_execution_update(JobId, fun(Job) ->
        Job#{
            last_run_id => RunId,
            last_run_at => Now,
            last_error => Error,
            updated_at => Now
        }
    end).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec manual_execution_update(binary(), fun((job_record()) -> job_record())) ->
    {ok, job_record()} | {error, not_found | job_busy | job_terminal}.
manual_execution_update(JobId, Fun) ->
    case beam_agent_routines_store:get_job(JobId) of
        {ok, Job} ->
            case allow_manual_run(maps:get(state, Job)) of
                ok ->
                    Updated = Fun(Job),
                    ok = beam_agent_routines_store:put_job(Updated),
                    {ok, Updated};
                {error, _} = Error ->
                    Error
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-spec normalize_job_input(map(), integer()) ->
    {ok, normalized_job_input()} | {error, routine_normalize_error() | {invalid_job, atom()}}.
normalize_job_input(JobInput, Now) ->
    Allowed = [job_id, schedule, target, payload, routing_policy,
        retry_policy, idempotency_key, state, next_run_at, metadata],
    case validate_allowed_keys(JobInput, Allowed, unsupported_job_key) of
        ok ->
            case normalize_optional_binary(job_id, JobInput, invalid_job) of
                {ok, JobId} ->
                    case normalize_schedule(maps:get(schedule, JobInput, undefined), Now) of
                        {ok, Schedule} ->
                            case normalize_target(maps:get(target, JobInput, undefined)) of
                                {ok, Target} ->
                                    case normalize_routing_policy(
                                        maps:get(routing_policy, JobInput, #{}),
                                        invalid_job
                                    ) of
                                        {ok, RoutingPolicy} ->
                                            case normalize_retry_policy(
                                                maps:get(retry_policy, JobInput, #{})) of
                                                {ok, RetryPolicy} ->
                                                    case normalize_idempotency_key(
                                                        maps:get(idempotency_key,
                                                            JobInput, undefined),
                                                        JobId
                                                    ) of
                                                        {ok, IdempotencyKey} ->
                                                            case normalize_initial_state(
                                                                maps:get(state, JobInput,
                                                                    active)) of
                                                                {ok, State} ->
                                                                    case normalize_next_run_override(
                                                                        maps:get(next_run_at,
                                                                            JobInput,
                                                                            undefined),
                                                                        invalid_job
                                                                    ) of
                                                                        {ok, NextRunAt} ->
                                                                            Normalized0 = #{
                                                                                schedule => Schedule,
                                                                                target => Target,
                                                                                routing_policy => RoutingPolicy,
                                                                                retry_policy => RetryPolicy,
                                                                                idempotency_key => IdempotencyKey,
                                                                                state => State
                                                                            },
                                                                            Normalized1 = maybe_put(
                                                                                job_id,
                                                                                JobId,
                                                                                Normalized0),
                                                                            Normalized2 = maybe_put(
                                                                                payload,
                                                                                maps:get(payload,
                                                                                    JobInput,
                                                                                    undefined),
                                                                                Normalized1),
                                                                            Normalized3 = maybe_put(
                                                                                metadata,
                                                                                maps:get(metadata,
                                                                                    JobInput,
                                                                                    undefined),
                                                                                Normalized2),
                                                                            {ok, maybe_put(
                                                                                next_run_at,
                                                                                NextRunAt,
                                                                                Normalized3)};
                                                                        {error, _} = Error ->
                                                                            Error
                                                                    end;
                                                                {error, _} = Error ->
                                                                    Error
                                                            end;
                                                        {error, _} = Error ->
                                                            Error
                                                    end;
                                                {error, _} = Error ->
                                                    Error
                                            end;
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_patch(map()) -> {ok, normalized_patch()} | {error, routine_error()}.
normalize_patch(Patch) ->
    Allowed = [schedule, target, payload, routing_policy, retry_policy,
        idempotency_key, state, next_run_at, metadata],
    case validate_allowed_keys(Patch, Allowed, unsupported_patch_key) of
        ok ->
            normalize_patch_entries(maps:to_list(Patch), #{});
        {error, _} = Error ->
            Error
    end.

-spec normalize_patch_entries([{atom(), term()}], normalized_patch()) ->
    {ok, normalized_patch()} | {error, routine_error()}.
normalize_patch_entries([], Acc) ->
    {ok, Acc};
normalize_patch_entries([{schedule, Value} | Rest], Acc) ->
    case normalize_schedule(Value, erlang:system_time(millisecond)) of
        {ok, Schedule} ->
            normalize_patch_entries(Rest, Acc#{schedule => Schedule});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{target, Value} | Rest], Acc) ->
    case normalize_target(Value) of
        {ok, Target} ->
            normalize_patch_entries(Rest, Acc#{target => Target});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{routing_policy, Value} | Rest], Acc) ->
    case normalize_routing_policy(Value, invalid_patch) of
        {ok, RoutingPolicy} ->
            normalize_patch_entries(Rest, Acc#{routing_policy => RoutingPolicy});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{retry_policy, Value} | Rest], Acc) ->
    case normalize_retry_policy(Value) of
        {ok, RetryPolicy} ->
            normalize_patch_entries(Rest, Acc#{retry_policy => RetryPolicy});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{idempotency_key, Value} | Rest], Acc) ->
    case normalize_optional_binary_value(Value, invalid_patch) of
        {ok, Key} when is_binary(Key) ->
            normalize_patch_entries(Rest, Acc#{idempotency_key => Key});
        {ok, undefined} ->
            {error, {invalid_patch, idempotency_key}};
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{state, Value} | Rest], Acc) ->
    case normalize_initial_state(Value) of
        {ok, State} ->
            normalize_patch_entries(Rest, Acc#{state => State});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{next_run_at, Value} | Rest], Acc) ->
    case normalize_next_run_override(Value, invalid_patch) of
        {ok, NextRunAt} ->
            normalize_patch_entries(Rest, Acc#{next_run_at => NextRunAt});
        {error, _} = Error ->
            Error
    end;
normalize_patch_entries([{payload, Value} | Rest], Acc) ->
    normalize_patch_entries(Rest, Acc#{payload => Value});
normalize_patch_entries([{metadata, Value} | Rest], Acc) when is_map(Value) ->
    normalize_patch_entries(Rest, Acc#{metadata => Value});
normalize_patch_entries([{metadata, _Value} | _Rest], _Acc) ->
    {error, {invalid_patch, metadata}}.

-spec apply_patch(job_record(), normalized_patch(), integer()) -> job_record().
apply_patch(Job, Patch, Now) ->
    ScheduleChanged = maps:is_key(schedule, Patch),
    Schedule = maps:get(schedule, Patch, maps:get(schedule, Job)),
    Patched0 = maps:merge(Job, maps:without([next_run_at], Patch)),
    Patched1 = Patched0#{schedule => Schedule, updated_at => Now},
    NextRunAt = case maps:is_key(next_run_at, Patch) of
        true ->
            maps:get(next_run_at, Patch);
        false ->
            case {ScheduleChanged, maps:get(state, Patch, maps:get(state, Job))} of
                {true, paused} ->
                    maps:get(next_run_at, Job,
                        compute_initial_next_run_at(Schedule, undefined, Now));
                {true, _Other} ->
                    compute_initial_next_run_at(Schedule, undefined, Now);
                {false, paused} ->
                    maps:get(next_run_at, Job, compute_initial_next_run_at(Schedule,
                        undefined, Now));
                {false, _Other} ->
                    maps:get(next_run_at, Job,
                        compute_initial_next_run_at(Schedule, undefined, Now))
            end
    end,
    maybe_put_next_run_at(Patched1, NextRunAt).

-spec normalize_schedule(term(), integer()) ->  %% Input is genuinely term(): validates arbitrary user data
    {ok, schedule()} | {error, {invalid_job, schedule} | {unsupported_schedule_key, atom()}}.
normalize_schedule(#{type := once, at := At} = Schedule, _Now)
  when is_integer(At), At >= 0 ->
    Allowed = [type, at],
    case validate_allowed_keys(Schedule, Allowed, unsupported_schedule_key) of
        ok ->
            {ok, #{type => once, at => At}};
        {error, _} = Error ->
            Error
    end;
normalize_schedule(#{type := interval, every_ms := EveryMs} = Schedule, Now)
  when is_integer(EveryMs), EveryMs > 0 ->
    Allowed = [type, every_ms, start_at, catch_up],
    case validate_allowed_keys(Schedule, Allowed, unsupported_schedule_key) of
        ok ->
            StartAt = maps:get(start_at, Schedule, Now),
            CatchUp = maps:get(catch_up, Schedule, false),
            case is_integer(StartAt) andalso StartAt >= 0 andalso is_boolean(CatchUp) of
                true ->
                    {ok, #{
                        type => interval,
                        every_ms => EveryMs,
                        start_at => StartAt,
                        catch_up => CatchUp
                    }};
                false ->
                    {error, {invalid_job, schedule}}
            end;
        {error, _} = Error ->
            Error
    end;
normalize_schedule(_, _Now) ->
    {error, {invalid_job, schedule}}.

-spec normalize_target(term()) -> {ok, target()} | {error, {invalid_job, atom()} |  %% Input is genuinely term(): validates arbitrary user data
    {unsupported_target_key, atom()} | {unsupported_session_target_key, atom()} |
    {unsupported_thread_key, atom()}}.
normalize_target(#{type := run} = Target) ->
    Allowed = [type, scope, run_opts, outcome, result, error, cancel_reason],
    case validate_allowed_keys(Target, Allowed, unsupported_target_key) of
        ok ->
            Scope = maps:get(scope, Target, #{}),
            RunOpts = maps:get(run_opts, Target, #{}),
            case ((is_binary(Scope) orelse is_map(Scope)) andalso is_map(RunOpts)) of
                true ->
                    Target0 = #{
                        type => run,
                        scope => Scope,
                        run_opts => RunOpts
                    },
                    Target1 = maybe_put(outcome, maps:get(outcome, Target, undefined), Target0),
                    Target2 = maybe_put(result, maps:get(result, Target, undefined), Target1),
                    Target3 = maybe_put(error, maps:get(error, Target, undefined), Target2),
                    {ok, maybe_put(cancel_reason,
                        maps:get(cancel_reason, Target, undefined), Target3)};
                false ->
                    {error, {invalid_job, target}}
            end;
        {error, _} = Error ->
            Error
    end;
normalize_target(#{type := query, session := Session, prompt := Prompt} = Target)
  when is_binary(Prompt) ->
    Allowed = [type, session, prompt, query_opts, thread, stop_session],
    case validate_allowed_keys(Target, Allowed, unsupported_target_key) of
        ok ->
            case normalize_session_target(Session) of
                {ok, SessionTarget} ->
                    case normalize_thread_target(maps:get(thread, Target, undefined)) of
                        {ok, ThreadTarget} ->
                            QueryOpts = maps:get(query_opts, Target, #{}),
                            StopSession = maps:get(stop_session, Target,
                                session_target_is_routed(SessionTarget)),
                            case is_map(QueryOpts) andalso is_boolean(StopSession) of
                                true ->
                                    Target0 = #{
                                        type => query,
                                        session => SessionTarget,
                                        prompt => Prompt,
                                        query_opts => QueryOpts,
                                        stop_session => StopSession
                                    },
                                    {ok, maybe_put(thread, ThreadTarget, Target0)};
                                false ->
                                    {error, {invalid_job, target}}
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
normalize_target(_) ->
    {error, {invalid_job, target}}.

-spec normalize_session_target(term()) -> {ok, session_target()} | {error,  %% Input is genuinely term(): validates arbitrary user data
    {invalid_job, session} | {unsupported_session_target_key, atom()}}.
normalize_session_target(#{kind := live, ref := Ref} = Target) when is_pid(Ref) ->
    Allowed = [kind, ref],
    case validate_allowed_keys(Target, Allowed, unsupported_session_target_key) of
        ok ->
            {ok, #{kind => live, ref => Ref}};
        {error, _} = Error ->
            Error
    end;
normalize_session_target(#{kind := routed, opts := Opts} = Target) when is_map(Opts) ->
    Allowed = [kind, opts],
    case validate_allowed_keys(Target, Allowed, unsupported_session_target_key) of
        ok ->
            {ok, #{kind => routed, opts => Opts}};
        {error, _} = Error ->
            Error
    end;
normalize_session_target(_) ->
    {error, {invalid_job, session}}.

-spec normalize_thread_target(term()) ->
    {ok, thread_target() | undefined} | {error, thread_target_error()}.
normalize_thread_target(undefined) ->
    {ok, undefined};
normalize_thread_target(#{thread_id := ThreadId} = Target) when is_binary(ThreadId) ->
    Allowed = [thread_id],
    case validate_allowed_keys(Target, Allowed, unsupported_thread_key) of
        ok ->
            {ok, #{thread_id => ThreadId}};
        {error, _} = Error ->
            Error
    end;
normalize_thread_target(#{start := StartOpts} = Target) when is_map(StartOpts) ->
    Allowed = [start],
    case validate_allowed_keys(Target, Allowed, unsupported_thread_key) of
        ok ->
            {ok, #{start => StartOpts}};
        {error, _} = Error ->
            Error
    end;
normalize_thread_target(_) ->
    {error, {invalid_job, thread}}.

-spec normalize_retry_policy(term()) -> {ok, retry_policy()} | {error,  %% Input is genuinely term(): validates arbitrary user data
    {invalid_job, retry_policy} | {unsupported_retry_key, atom()}}.
normalize_retry_policy(Policy) when is_map(Policy) ->
    Allowed = [max_attempts, backoff_ms],
    case validate_allowed_keys(Policy, Allowed, unsupported_retry_key) of
        ok ->
            MaxAttempts = maps:get(max_attempts, Policy, 1),
            BackoffMs = maps:get(backoff_ms, Policy, 0),
            case is_integer(MaxAttempts) andalso MaxAttempts > 0
              andalso is_integer(BackoffMs) andalso BackoffMs >= 0 of
                true ->
                    {ok, #{
                        max_attempts => MaxAttempts,
                        backoff_ms => BackoffMs
                    }};
                false ->
                    {error, {invalid_job, retry_policy}}
            end;
        {error, _} = Error ->
            Error
    end;
normalize_retry_policy(_) ->
    {error, {invalid_job, retry_policy}}.

-spec normalize_routing_policy(term(), routine_validation_tag()) ->
    {ok, map()} | {error, {routine_validation_tag(), routing_policy}}.
normalize_routing_policy(Policy, _Kind) when is_map(Policy) ->
    {ok, Policy};
normalize_routing_policy(_, Kind) ->
    {error, {Kind, routing_policy}}.

-spec normalize_idempotency_key(term(), binary() | undefined) ->  %% Input is genuinely term(): validates arbitrary user data
    {ok, binary()} | {error, {invalid_job, job_id | value} | {invalid_patch, job_id | value}}.
normalize_idempotency_key(undefined, MaybeJobId) when is_binary(MaybeJobId) ->
    {ok, <<<<"routine:">>/binary, MaybeJobId/binary>>};
normalize_idempotency_key(undefined, undefined) ->
    {ok, generate_idempotency_key()};
normalize_idempotency_key(Value, _MaybeJobId) ->
    normalize_optional_binary_value(Value, invalid_job).

-spec normalize_initial_state(term()) ->
    {ok, active | paused} | {error, {invalid_job, state}}.
normalize_initial_state(active) ->
    {ok, active};
normalize_initial_state(paused) ->
    {ok, paused};
normalize_initial_state(_) ->
    {error, {invalid_job, state}}.

-spec normalize_next_run_override(term(), routine_validation_tag()) ->
    {ok, non_neg_integer() | undefined} |
    {error, {routine_validation_tag(), next_run_at}}.
normalize_next_run_override(undefined, _Kind) ->
    {ok, undefined};
normalize_next_run_override(Value, _Kind) when is_integer(Value), Value >= 0 ->
    {ok, Value};
normalize_next_run_override(_Value, Kind) ->
    {error, {Kind, next_run_at}}.

-spec normalize_job_filter(map()) -> {ok, job_filter()} | {error, {unsupported_filter, atom()} | {invalid_filter, limit}}.
normalize_job_filter(Filter) ->
    Allowed = [job_id, state, schedule_type, target_type, due_before, limit],
    case validate_allowed_keys(Filter, Allowed, unsupported_filter) of
        ok ->
            case normalize_limit(Filter) of
                {ok, Limit} ->
                    {ok, maybe_put(limit, Limit,
                        maybe_put(due_before, maps:get(due_before, Filter, undefined),
                        maps:with([job_id, state, schedule_type, target_type], Filter)))};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_due_filter(map(), integer()) -> {ok, due_filter()} | {error, {unsupported_filter, atom()} | {invalid_filter, limit | include_claimed}}.
normalize_due_filter(Filter, Now) ->
    Allowed = [at, limit, include_claimed],
    case validate_allowed_keys(Filter, Allowed, unsupported_filter) of
        ok ->
            case normalize_limit(Filter) of
                {ok, Limit} ->
                    IncludeClaimed = maps:get(include_claimed, Filter, false),
                    case is_boolean(IncludeClaimed) of
                        true ->
                            Normalized0 = #{at => Now, include_claimed => IncludeClaimed},
                            {ok, maybe_put(limit, Limit, Normalized0)};
                        false ->
                            {error, {invalid_filter, include_claimed}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_limit(map()) ->
    {ok, pos_integer() | undefined} | {error, {invalid_filter, limit}}.
normalize_limit(Filter) ->
    case maps:get(limit, Filter, undefined) of
        undefined ->
            {ok, undefined};
        Limit when is_integer(Limit), Limit > 0 ->
            {ok, Limit};
        _ ->
            {error, {invalid_filter, limit}}
    end.

-spec allow_update(job_state()) -> ok | {error, job_busy | job_terminal}.
allow_update(active) ->
    ok;
allow_update(paused) ->
    ok;
allow_update(running) ->
    {error, job_busy};
allow_update(retry_waiting) ->
    {error, job_busy};
allow_update(_Terminal) ->
    {error, job_terminal}.

-spec allow_manual_run(job_state()) -> ok | {error, job_busy | job_terminal}.
allow_manual_run(active) ->
    ok;
allow_manual_run(paused) ->
    ok;
allow_manual_run(completed) ->
    ok;
allow_manual_run(exhausted) ->
    ok;
allow_manual_run(cancelled) ->
    {error, job_terminal};
allow_manual_run(running) ->
    {error, job_busy};
allow_manual_run(retry_waiting) ->
    {error, job_busy}.

-spec compute_initial_next_run_at(schedule(), integer() | undefined, integer()) -> integer().
compute_initial_next_run_at(_Schedule, Override, _Now) when is_integer(Override) ->
    Override;
compute_initial_next_run_at(#{type := once, at := At}, _Override, _Now) ->
    At;
compute_initial_next_run_at(#{type := interval, start_at := StartAt}, _Override, _Now) ->
    StartAt.

-spec next_after_success(schedule(), integer(), integer()) ->
    {active, integer()} | {completed, undefined}.
next_after_success(#{type := once}, _SlotAt, _Now) ->
    {completed, undefined};
next_after_success(#{type := interval, every_ms := EveryMs, catch_up := true},
    SlotAt, _Now) ->
    {active, SlotAt + EveryMs};
next_after_success(#{type := interval, every_ms := EveryMs}, _SlotAt, Now) ->
    {active, Now + EveryMs}.

-spec next_after_failure(schedule(), integer(), integer()) ->
    {active, integer()} | {exhausted, undefined}.
next_after_failure(#{type := once}, _SlotAt, _Now) ->
    {exhausted, undefined};
next_after_failure(#{type := interval, every_ms := EveryMs, catch_up := true},
    SlotAt, _Now) ->
    {active, SlotAt + EveryMs};
next_after_failure(#{type := interval, every_ms := EveryMs}, _SlotAt, Now) ->
    {active, Now + EveryMs}.

-spec can_start_scheduled_execution(job_record(), binary(), integer()) ->
    ok | {error, stale_slot | stale_retry_state | invalid_state}.
can_start_scheduled_execution(#{state := active} = Job, RunId, SlotAt) ->
    case {maps:get(current_run_id, Job, undefined), maps:get(current_slot_at, Job, undefined)} of
        {undefined, undefined} ->
            case maps:get(next_run_at, Job, undefined) of
                SlotAt -> ok;
                _ -> {error, stale_slot}
            end;
        {RunId, SlotAt} ->
            ok;
        _ ->
            {error, stale_retry_state}
    end;
can_start_scheduled_execution(#{state := retry_waiting} = Job, _RunId, SlotAt) ->
    case maps:get(next_run_at, Job, undefined) of
        SlotAt ->
            ok;
        _Other ->
            {error, stale_retry_state}
    end;
can_start_scheduled_execution(_Job, _RunId, _SlotAt) ->
    {error, invalid_state}.

-spec validate_current_run(job_record(), binary(), integer()) -> ok | {error, stale_run_mismatch}.
validate_current_run(Job, RunId, SlotAt) ->
    case {maps:get(current_run_id, Job, undefined), maps:get(current_slot_at, Job, undefined)} of
        {RunId, SlotAt} ->
            ok;
        _ ->
            {error, stale_run_mismatch}
    end.

-spec maybe_cancel_current_run(job_record()) -> ok.
maybe_cancel_current_run(Job) ->
    case maps:get(current_run_id, Job, undefined) of
        RunId when is_binary(RunId) ->
            _ = beam_agent_runs:cancel_run(RunId, #{
                reason => routine_cancelled,
                job_id => maps:get(job_id, Job)
            }),
            ok;
        _ ->
            ok
    end.

-spec maybe_put_next_run_at(job_record(), integer() | undefined) -> job_record().
maybe_put_next_run_at(Job, NextRunAt) when is_integer(NextRunAt) ->
    Job#{next_run_at => NextRunAt};
maybe_put_next_run_at(Job, undefined) ->
    maps:without([next_run_at], Job).

-spec maybe_put_terminal_timestamp(job_record(), job_state(), integer()) -> job_record().
maybe_put_terminal_timestamp(Job, completed, Now) ->
    Job#{completed_at => Now};
maybe_put_terminal_timestamp(Job, exhausted, Now) ->
    Job#{completed_at => Now};
maybe_put_terminal_timestamp(Job, _Other, _Now) ->
    maps:without([completed_at], Job).

-spec append_job_event(binary(), job_record(), map()) ->
    {ok, beam_agent_journal_core:entry()} | {error, already_exists |
        session_id_required_for_thread |
        {invalid_event, atom()} | {invalid_event_type, binary()}}.
append_job_event(EventType, Job, PayloadExtra) ->
    Payload = maps:merge(#{
        job_id => maps:get(job_id, Job),
        state => maps:get(state, Job),
        schedule_type => maps:get(type, maps:get(schedule, Job)),
        target_type => maps:get(type, maps:get(target, Job))
    }, PayloadExtra),
    Event0 = #{
        timestamp => erlang:system_time(millisecond),
        tags => [routine, maps:get(type, maps:get(target, Job))],
        payload => Payload
    },
    Event = maybe_put(run_id, maps:get(last_run_id, Job, undefined), Event0),
    beam_agent_journal_core:append(EventType, Event).

-spec evaluate_routine_policy(job_record() | normalized_job_input()) -> allow | {deny, binary()}.
evaluate_routine_policy(JobOrInput) ->
    Metadata = maps:get(metadata, JobOrInput, #{}),
    ProfileId = maps:get(policy_profile_id, Metadata, undefined),
    Context = #{
        schedule => maps:get(schedule, JobOrInput, undefined),
        target => maps:get(target, JobOrInput, undefined),
        payload => maps:get(payload, JobOrInput, undefined),
        metadata => Metadata
    },
    case beam_agent_policy_core:evaluate(ProfileId, routine, Context) of
        allow ->
            allow;
        {deny, Reason} ->
            _ = beam_agent_audit_core:record(routine, policy_denied,
                routine_audit_scope(JobOrInput, ProfileId), #{
                    decision => deny,
                    reason => Reason
                }),
            {deny, Reason}
    end.

-spec audit_routine_event(routine_action(), job_record(),
    #{decision := allow} | routine_audit_details()) -> ok.
audit_routine_event(Action, Job, ExtraDetails) ->
    Metadata = maps:get(metadata, Job, #{}),
    ProfileId = maps:get(policy_profile_id, Metadata, undefined),
    Details = maps:merge(#{
        decision => allow,
        job_id => maps:get(job_id, Job),
        state => maps:get(state, Job),
        target_type => maps:get(type, maps:get(target, Job))
    }, ExtraDetails),
    case beam_agent_audit_core:record(routine, Action, routine_audit_scope(Job, ProfileId),
             Details) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

-spec routine_audit_scope(map(), binary() | undefined) -> map().
routine_audit_scope(JobOrInput, ProfileId) ->
    maybe_put(profile_id, ProfileId, #{
        run_id => maps:get(last_run_id, JobOrInput, undefined)
    }).

-spec validate_allowed_keys(map(), [atom()], routine_error_tag()) ->
    ok | {error, routine_error()}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case lists:dropwhile(fun(Key) -> lists:member(Key, Allowed) end,
        maps:keys(Map)) of
        [] ->
            ok;
        [Key | _] ->
            {error, {ErrorTag, Key}}
    end.

-spec normalize_optional_binary(job_id, map(), invalid_job) ->
    {ok, binary() | undefined} |
    {error, {invalid_job, job_id | value} | {invalid_patch, job_id | value}}.
normalize_optional_binary(Key, Map, ErrorKind) ->
    normalize_optional_binary_value(maps:get(Key, Map, undefined), ErrorKind, Key).

-spec normalize_optional_binary_value(term(), routine_validation_tag()) ->
    {ok, binary() | undefined} |
    {error, {invalid_job, job_id | value} | {invalid_patch, job_id | value}}.
normalize_optional_binary_value(Value, ErrorKind) ->
    normalize_optional_binary_value(Value, ErrorKind, value).

-spec normalize_optional_binary_value(term(), routine_validation_tag(), job_id | value) ->
    {ok, binary() | undefined} |
    {error, {invalid_job, job_id | value} | {invalid_patch, job_id | value}}.
normalize_optional_binary_value(undefined, _ErrorKind, _Key) ->
    {ok, undefined};
normalize_optional_binary_value(Value, _ErrorKind, _Key)
  when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_optional_binary_value(_Value, ErrorKind, Key) ->
    {error, {ErrorKind, Key}}.

-spec maybe_put(routine_optional_key(), term(), routine_put_map()) -> routine_put_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec redacted_patch(normalized_patch()) -> map().
redacted_patch(Patch) ->
    case maps:is_key(payload, Patch) of
        true ->
            Patch#{payload => redacted};
        false ->
            Patch
    end.

-spec generate_job_id() -> binary().
generate_job_id() ->
    list_to_binary(io_lib:format("routine_~p",
        [erlang:unique_integer([positive, monotonic])])).

-spec generate_idempotency_key() -> binary().
generate_idempotency_key() ->
    list_to_binary(io_lib:format("routine:idempotency:~p",
        [erlang:unique_integer([positive, monotonic])])).

-spec session_target_is_routed(session_target()) -> boolean().
session_target_is_routed(#{kind := routed}) ->
    true;
session_target_is_routed(_) ->
    false.

-spec any_runner() -> <<_:112>>.
any_runner() ->
    <<"__any_runner__">>.

-spec telemetry_start(routine_operation(), routine_telemetry_meta()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry:span_start(routine, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(routine_operation(), integer(), routine_telemetry_meta()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry:span_stop(routine, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(create | list_due | update,
    already_exists | job_busy | job_terminal | not_found | {error, routine_error()},
    routine_telemetry_meta()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry:span_exception(routine, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_finish(create | update, integer(),
    {ok, job_record()} | {error, already_exists | job_busy | job_terminal | not_found |
        routine_error()}, routine_telemetry_meta()) -> ok.
telemetry_finish(Operation, StartTime, {ok, Job}, Metadata) ->
    telemetry_stop(Operation, StartTime, maps:merge(Metadata, telemetry_job_meta(Job)));
telemetry_finish(Operation, _StartTime, {error, Reason}, Metadata) ->
    telemetry_exception(Operation, Reason, Metadata).

-spec telemetry_job_input_meta(map()) -> map().
telemetry_job_input_meta(JobInput) ->
    maps:with([job_id, idempotency_key, next_run_at, state], JobInput).

-spec telemetry_patch_meta(binary(), map()) ->
    #{job_id := binary(), next_run_at => integer(), state => active | paused}.
telemetry_patch_meta(JobId, Patch) ->
    (maps:with([state, next_run_at], Patch))#{job_id => JobId}.

-spec telemetry_due_filter_meta(map(), integer()) -> map().
telemetry_due_filter_meta(Filter, Now) ->
    (maps:with([limit, due_before], Filter))#{at => Now}.

-spec telemetry_job_meta(job_record()) -> routine_telemetry_meta().
telemetry_job_meta(Job) ->
    maps:with([job_id, state, next_run_at, attempt_count, last_run_id], Job).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).
