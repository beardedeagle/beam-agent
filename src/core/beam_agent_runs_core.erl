-module(beam_agent_runs_core).
-moduledoc """
Canonical run and step lifecycle primitives for BeamAgent.

Runs provide durable units of work that are richer than opaque task
registration. A run can be scoped to a session and thread, can inherit
scope from a parent run, and can own multiple steps. Steps are linked to
their parent run and inherit its session/thread scope.

This module validates lifecycle transitions and keeps the store coherent:

- child runs inherit or validate parent scope
- steps can only start on active runs
- completed runs cannot leave active steps behind
- failed or cancelled runs cascade terminal state to active steps

The implementation is ETS-backed through beam_agent_runs_store and does
not introduce an extra process layer. That is intentional: runs are
shared metadata, not active execution loops, so ETS plus the existing
hardened write proxy is the right level of machinery here.
""".

-export([
    ensure_tables/0,
    clear/0,
    start_run/2,
    get_run/1,
    list_runs/0,
    list_runs/1,
    complete_run/2,
    fail_run/2,
    cancel_run/2,
    start_step/2,
    get_step/2,
    list_steps/1,
    complete_step/3,
    fail_step/3,
    cancel_step/3
]).

-export_type([
    scope/0,
    run/0,
    step/0,
    run_status/0,
    step_status/0,
    run_opts/0,
    step_opts/0,
    run_filter/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type run_status() :: running | completed | failed | cancelled.
-type step_status() :: running | completed | failed | cancelled.
-type terminal_status() :: completed | failed | cancelled.
-type terminal_current_status() :: completed | failed | cancelled.
-type run_kind() :: atom() | binary().
-type step_kind() :: atom() | binary().

-type scope() :: binary() | #{
    session_id => binary(),
    thread_id => binary(),
    parent_run_id => binary()
}.

-type run_opts() :: #{
    run_id => binary(),
    kind => run_kind(),
    input => term(),
    metadata => map()
}.

-type step_opts() :: #{
    step_id => binary(),
    kind => step_kind(),
    input => term(),
    metadata => map()
}.

-type run_filter() :: beam_agent_runs_store:run_filter().
-type run() :: beam_agent_runs_store:run_record().
-type step() :: beam_agent_runs_store:step_record().

-type normalized_scope() :: #{
    session_id => binary(),
    thread_id => binary(),
    parent_run_id => binary()
}.

-type normalized_run_opts() :: #{
    kind := run_kind(),
    metadata := map(),
    run_id => binary(),
    input => term()
}.

-type normalized_step_opts() :: #{
    kind := step_kind(),
    metadata := map(),
    step_id => binary(),
    input => term()
}.
-type normalize_binary_key() :: parent_run_id | run_id | session_id | step_id | thread_id.
-type journal_error() ::
    already_exists
  | session_id_required_for_thread
  | {invalid_event, event_id | payload | run_id | session_id | tags | thread_id | timestamp}
  | {invalid_event_type, binary()}.
-type run_event_type_binary() :: <<_:80, _:_*24>>.
-type step_event_type_binary() :: <<_:88, _:_*24>>.
-type telemetry_domain() :: run | step.
-type telemetry_operation() ::
    start_run | start_step | complete_run | complete_step |
    fail_run | fail_step | cancel_run | cancel_step.
-type run_transition_error() ::
    {error, {invalid_status_transition, terminal_current_status(), terminal_status()}}.
-type step_transition_error() ::
    {error, {invalid_status_transition, terminal_current_status(), terminal_status()}}.
-type run_telemetry_request_meta() :: #{
    requested_kind := run_kind() | undefined,
    run_id := binary() | undefined,
    session_id => binary(),
    thread_id => binary(),
    parent_run_id => binary()
}.
-type step_telemetry_request_meta() :: #{
    run_id := binary(),
    requested_kind := step_kind() | undefined,
    step_id := binary() | undefined
}.
-type run_telemetry_meta() :: #{
    run_id := binary(),
    kind := run_kind(),
    status := run_status()
}.
-type step_telemetry_meta() :: #{
    run_id := binary(),
    step_id := binary(),
    kind := step_kind(),
    status := step_status()
}.
-type telemetry_result() ::
    {ok, run() | step()} |
    {error,
        active_steps
      | already_exists
      | inconsistent_parent_scope
      | not_found
      | parent_run_not_found
      | run_not_active
      | session_id_required_for_thread
      | {invalid_run_opt, kind | metadata | run_id}
      | {invalid_scope, atom()}
      | {invalid_step_opt, kind | metadata | step_id}
      | {unsupported_scope_key, atom()}
      | {invalid_status_transition, terminal_current_status(), terminal_status()}}.
-type telemetry_metadata() :: #{
    run_id := binary() | undefined,
    parent_run_id => binary(),
    requested_kind => run_kind() | step_kind() | undefined,
    session_id => binary(),
    step_id => binary() | undefined,
    target_status => terminal_status(),
    thread_id => binary()
}.
-type runs_put_key() ::
    input | kind | limit | parent_run_id | run_id | session_id | since | status |
    step_id | thread_id.
-type runs_event_map() :: #{
    payload := #{run => map()} | #{step => map()},
    tags := [run | step, ...],
    created_at => integer(),
    metadata => map(),
    updated_at => integer(),
    runs_put_key() => term()
}.
-type runs_put_map() ::
    normalized_scope()
  | normalized_run_opts()
  | normalized_step_opts()
  | run_filter()
  | run()
  | step()
  | runs_event_map().

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the run and step ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_runs_store:ensure_tables().

-doc "Clear all run and step records. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_runs_store:clear().

%%--------------------------------------------------------------------
%% Run Lifecycle
%%--------------------------------------------------------------------

-doc """
Start a new run.

Scope may be:
  - a binary session id
  - a map containing `session_id`, `thread_id`, and/or `parent_run_id`

When `parent_run_id` is present, the child run inherits the parent's
session/thread scope unless the caller provides matching explicit values.
""".
-spec start_run(scope(), run_opts()) ->
    {ok, run()} |
    {error, already_exists | parent_run_not_found | inconsistent_parent_scope |
        session_id_required_for_thread | {unsupported_scope_key, atom()} |
        {unsupported_run_opt, atom()} | {invalid_scope, atom()} |
        {invalid_run_opt, atom()}}.
start_run(Scope, Opts) when (is_binary(Scope) orelse is_map(Scope)), is_map(Opts) ->
    ensure_tables(),
    TeleMeta = telemetry_scope_meta(Scope),
    StartTime = telemetry_start(run, start_run, telemetry_run_request_meta(Opts, TeleMeta)),
    Result = case normalize_scope(Scope) of
        {ok, Scope1} ->
            case normalize_run_opts(Opts) of
                {ok, Opts1} ->
                    Now = erlang:system_time(millisecond),
                    RunId = maps:get(run_id, Opts1, generate_run_id()),
                    Run0 = #{
                        run_id => RunId,
                        kind => maps:get(kind, Opts1),
                        status => running,
                        metadata => maps:get(metadata, Opts1),
                        created_at => Now,
                        updated_at => Now
                    },
                    Run1 = maybe_put(input, maps:get(input, Opts1, undefined), Run0),
                    Run2 = maps:merge(Run1, Scope1),
                    case beam_agent_runs_store:insert_run(Run2) of
                        true ->
                            {ok, _Entry} = append_run_event(<<"run_started">>, Run2),
                            emit_state_change(run, created, running, telemetry_run_meta(Run2)),
                            {ok, Run2};
                        false -> {error, already_exists}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    telemetry_finish(run, start_run, StartTime, Result, TeleMeta),
    Result.

-doc "Fetch a run by id.".
-spec get_run(binary()) -> {ok, run()} | {error, not_found}.
get_run(RunId) when is_binary(RunId) ->
    beam_agent_runs_store:get_run(RunId).

-doc "List runs without filters.".
-spec list_runs() -> {ok, [run()]}.
list_runs() ->
    list_runs(#{}).

-doc """
List runs with exact-match filters.

Supported filters:
  - `session_id`
  - `thread_id`
  - `parent_run_id`
  - `kind`
  - `status`
  - `since` (updated_at unix milliseconds)
  - `limit`
""".
-spec list_runs(run_filter()) ->
    {ok, [run()]} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
list_runs(Filter) when is_map(Filter) ->
    case normalize_run_filter(Filter) of
        {ok, Normalized} -> beam_agent_runs_store:list_runs(Normalized);
        Error -> Error
    end.

-doc """
Complete a running run.

Runs may only complete once all of their steps are already terminal.
Use `complete_step/3` first, or fail/cancel the run to cascade active
step state.
""".
-spec complete_run(binary(), term()) ->  %% Result is genuinely term(): caller-provided completion value
    {ok, run()} |
    {error, not_found | active_steps |
        {invalid_status_transition, run_status(), completed}}.
complete_run(RunId, Result) when is_binary(RunId) ->
    TeleMeta = #{run_id => RunId},
    StartTime = telemetry_start(run, complete_run, TeleMeta),
    Outcome = case beam_agent_runs_store:get_run(RunId) of
        {ok, Run} ->
            case ensure_run_transition(Run, completed) of
                ok ->
                    case active_steps(RunId) of
                        [] ->
                            Now = erlang:system_time(millisecond),
                            Updated = terminalize_run(Run, completed, Result, undefined,
                                undefined, Now),
                            ok = beam_agent_runs_store:put_run(Updated),
                            {ok, _Entry} = append_run_event(<<"run_completed">>, Updated),
                            emit_state_change(run, maps:get(status, Run), completed,
                                telemetry_run_meta(Updated)),
                            {ok, Updated};
                        [_ | _] ->
                            {error, active_steps}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    telemetry_finish(run, complete_run, StartTime, Outcome, TeleMeta),
    Outcome.

-doc "Fail a running run and cascade failure to active steps.".
-spec fail_run(binary(), term()) ->  %% ErrorTerm is genuinely term(): caller-provided error reason
    {ok, run()} |
    {error, not_found | {invalid_status_transition, run_status(), failed}}.
fail_run(RunId, ErrorTerm) when is_binary(RunId) ->
    transition_run_with_step_cascade(RunId, failed, ErrorTerm).

-doc "Cancel a running run and cascade cancellation to active steps.".
-spec cancel_run(binary(), term()) ->  %% Reason is genuinely term(): caller-provided cancellation reason
    {ok, run()} |
    {error, not_found | {invalid_status_transition, run_status(), cancelled}}.
cancel_run(RunId, Reason) when is_binary(RunId) ->
    transition_run_with_step_cascade(RunId, cancelled, Reason).

%%--------------------------------------------------------------------
%% Step Lifecycle
%%--------------------------------------------------------------------

-doc """
Start a new step under a run.

Steps inherit the run's session/thread scope and can only be started
while the run itself is still running.
""".
-spec start_step(binary(), step_opts()) ->
    {ok, step()} |
    {error, not_found | already_exists | run_not_active |
        {unsupported_step_opt, atom()} | {invalid_step_opt, atom()}}.
start_step(RunId, Opts) when is_binary(RunId), is_map(Opts) ->
    ensure_tables(),
    TeleMeta = telemetry_step_request_meta(RunId, Opts),
    StartTime = telemetry_start(step, start_step, TeleMeta),
    Result = case beam_agent_runs_store:get_run(RunId) of
        {ok, Run} ->
            case maps:get(status, Run) of
                running ->
                    case normalize_step_opts(Opts) of
                        {ok, Opts1} ->
                            Now = erlang:system_time(millisecond),
                            StepId = maps:get(step_id, Opts1, generate_step_id()),
                            Step0 = #{
                                step_id => StepId,
                                run_id => RunId,
                                kind => maps:get(kind, Opts1),
                                status => running,
                                metadata => maps:get(metadata, Opts1),
                                created_at => Now,
                                updated_at => Now
                            },
                            Step1 = maybe_put(input, maps:get(input, Opts1, undefined), Step0),
                            Step2 = inherit_run_scope(Run, Step1),
                            case beam_agent_runs_store:insert_step(Step2) of
                                true ->
                                    ok = touch_run(Run, Now),
                                    {ok, _Entry} = append_step_event(<<"step_started">>, Step2),
                                    emit_state_change(step, created, running,
                                        telemetry_step_meta(Step2)),
                                    {ok, Step2};
                                false ->
                                    {error, already_exists}
                            end;
                        Error ->
                            Error
                    end;
                _ ->
                    {error, run_not_active}
            end;
        Error ->
            Error
    end,
    telemetry_finish(step, start_step, StartTime, Result, TeleMeta),
    Result.

-doc "Fetch a step by run id and step id.".
-spec get_step(binary(), binary()) -> {ok, step()} | {error, not_found}.
get_step(RunId, StepId) when is_binary(RunId), is_binary(StepId) ->
    beam_agent_runs_store:get_step(RunId, StepId).

-doc "List steps for a run, oldest first.".
-spec list_steps(binary()) -> {ok, [step()]} | {error, not_found}.
list_steps(RunId) when is_binary(RunId) ->
    case beam_agent_runs_store:get_run(RunId) of
        {ok, _Run} ->
            beam_agent_runs_store:list_steps(RunId);
        Error ->
            Error
    end.

-doc "Complete a running step.".
-spec complete_step(binary(), binary(), term()) ->  %% Result is genuinely term(): caller-provided completion value
    {ok, step()} |
    {error, not_found | {invalid_status_transition, step_status(), completed}}.
complete_step(RunId, StepId, Result)
  when is_binary(RunId), is_binary(StepId) ->
    transition_step(RunId, StepId, completed, Result).

-doc "Fail a running step.".
-spec fail_step(binary(), binary(), term()) ->  %% ErrorTerm is genuinely term(): caller-provided error reason
    {ok, step()} |
    {error, not_found | {invalid_status_transition, step_status(), failed}}.
fail_step(RunId, StepId, ErrorTerm)
  when is_binary(RunId), is_binary(StepId) ->
    transition_step(RunId, StepId, failed, ErrorTerm).

-doc "Cancel a running step.".
-spec cancel_step(binary(), binary(), term()) ->  %% Reason is genuinely term(): caller-provided cancellation reason
    {ok, step()} |
    {error, not_found | {invalid_status_transition, step_status(), cancelled}}.
cancel_step(RunId, StepId, Reason)
  when is_binary(RunId), is_binary(StepId) ->
    transition_step(RunId, StepId, cancelled, Reason).

%%--------------------------------------------------------------------
%% Internal: Normalization
%%--------------------------------------------------------------------

-spec normalize_scope(scope()) ->
    {ok, normalized_scope()} |
    {error, parent_run_not_found | inconsistent_parent_scope |
        session_id_required_for_thread | {unsupported_scope_key, atom()} |
        {invalid_scope, atom()}}.
normalize_scope(SessionId) when is_binary(SessionId) ->
    {ok, #{session_id => SessionId}};
normalize_scope(Scope) when is_map(Scope) ->
    Allowed = [session_id, thread_id, parent_run_id],
    case validate_allowed_keys(Scope, Allowed, unsupported_scope_key) of
        ok ->
            case normalize_optional_binary(session_id, Scope) of
                {ok, SessionId} ->
                    case normalize_optional_binary(thread_id, Scope) of
                        {ok, ThreadId} ->
                            case normalize_optional_binary(parent_run_id, Scope) of
                                {ok, ParentRunId} ->
                                    resolve_parent_scope(SessionId, ThreadId, ParentRunId);
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec normalize_run_opts(map()) ->
    {ok, normalized_run_opts()} |
    {error, {unsupported_run_opt, atom()} | {invalid_run_opt, atom()}}.
normalize_run_opts(Opts) ->
    Allowed = [run_id, kind, input, metadata],
    case validate_allowed_keys(Opts, Allowed, unsupported_run_opt) of
        ok ->
            case normalize_optional_binary(run_id, Opts) of
                {ok, RunId} ->
                    case normalize_kind(kind, maps:get(kind, Opts, generic), invalid_run_opt) of
                        {ok, Kind} ->
                            case normalize_metadata(Opts, invalid_run_opt) of
                                {ok, Metadata} ->
                                    Normalized0 = #{
                                        kind => Kind,
                                        metadata => Metadata
                                    },
                                    Normalized1 =
                                        maybe_put(run_id, RunId, Normalized0),
                                    {ok, maybe_put(input,
                                        maps:get(input, Opts, undefined), Normalized1)};
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

-spec normalize_step_opts(map()) ->
    {ok, normalized_step_opts()} |
    {error, {unsupported_step_opt, atom()} | {invalid_step_opt, atom()}}.
normalize_step_opts(Opts) ->
    Allowed = [step_id, kind, input, metadata],
    case validate_allowed_keys(Opts, Allowed, unsupported_step_opt) of
        ok ->
            case normalize_optional_binary(step_id, Opts) of
                {ok, StepId} ->
                    case normalize_kind(kind, maps:get(kind, Opts, generic), invalid_step_opt) of
                        {ok, Kind} ->
                            case normalize_metadata(Opts, invalid_step_opt) of
                                {ok, Metadata} ->
                                    Normalized0 = #{
                                        kind => Kind,
                                        metadata => Metadata
                                    },
                                    Normalized1 =
                                        maybe_put(step_id, StepId, Normalized0),
                                    {ok, maybe_put(input,
                                        maps:get(input, Opts, undefined), Normalized1)};
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

-spec normalize_run_filter(map()) ->
    {ok, run_filter()} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
normalize_run_filter(Filter) ->
    Allowed = [session_id, thread_id, parent_run_id, kind, status, limit, since],
    case validate_allowed_keys(Filter, Allowed, unsupported_filter) of
        ok ->
            case normalize_optional_binary(session_id, Filter) of
                {ok, SessionId} ->
                    case normalize_optional_binary(thread_id, Filter) of
                        {ok, ThreadId} ->
                            case normalize_optional_binary(parent_run_id, Filter) of
                                {ok, ParentRunId} ->
                                    case normalize_optional_kind(Filter) of
                                        {ok, Kind} ->
                                            case normalize_optional_status(Filter) of
                                                {ok, Status} ->
                                                    case normalize_limit(Filter) of
                                                        {ok, Limit} ->
                                                            case normalize_since(Filter) of
                                                                {ok, Since} ->
                                                                    Normalized0 = #{},
                                                                    Normalized1 =
                                                                        maybe_put(session_id,
                                                                            SessionId, Normalized0),
                                                                    Normalized2 =
                                                                        maybe_put(thread_id,
                                                                            ThreadId, Normalized1),
                                                                    Normalized3 =
                                                                        maybe_put(parent_run_id,
                                                                            ParentRunId,
                                                                            Normalized2),
                                                                    Normalized4 =
                                                                        maybe_put(kind, Kind,
                                                                            Normalized3),
                                                                    Normalized5 =
                                                                        maybe_put(status, Status,
                                                                            Normalized4),
                                                                    Normalized6 =
                                                                        maybe_put(since, Since,
                                                                            Normalized5),
                                                                    {ok, maybe_put(limit, Limit,
                                                                        Normalized6)};
                                                                Error ->
                                                                    Error
                                                            end;
                                                        Error ->
                                                            Error
                                                    end;
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Transitions
%%--------------------------------------------------------------------

-spec transition_run_with_step_cascade(binary(), failed | cancelled, term()) ->  %% Payload is genuinely term(): caller-provided error/cancel payload
    {ok, run()} |
    {error, not_found | {invalid_status_transition, run_status(), failed | cancelled}}.
transition_run_with_step_cascade(RunId, TargetStatus, Payload) ->
    TeleMeta = #{run_id => RunId, target_status => TargetStatus},
    Operation = run_transition_operation(TargetStatus),
    StartTime = telemetry_start(run, Operation, TeleMeta),
    Result = case beam_agent_runs_store:get_run(RunId) of
        {ok, Run} ->
            case ensure_run_transition(Run, TargetStatus) of
                ok ->
                    Now = erlang:system_time(millisecond),
                    ok = cascade_active_steps(RunId, TargetStatus, Payload, Now),
                    Updated = terminalize_run(Run, TargetStatus, undefined, Payload,
                        Payload, Now),
                    ok = beam_agent_runs_store:put_run(Updated),
                    {ok, _Entry} = append_run_event(run_event_type(TargetStatus), Updated),
                    emit_state_change(run, maps:get(status, Run), TargetStatus,
                        telemetry_run_meta(Updated)),
                    {ok, Updated};
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    telemetry_finish(run, Operation, StartTime, Result, TeleMeta),
    Result.

-spec transition_step(binary(), binary(), completed | failed | cancelled, term()) ->  %% Payload is genuinely term(): caller-provided result/error/cancel payload
    {ok, step()} |
    {error, not_found | {invalid_status_transition, step_status(),
        completed | failed | cancelled}}.
transition_step(RunId, StepId, TargetStatus, Payload) ->
    TeleMeta = #{run_id => RunId, step_id => StepId, target_status => TargetStatus},
    Operation = step_transition_operation(TargetStatus),
    StartTime = telemetry_start(step, Operation, TeleMeta),
    Result = case beam_agent_runs_store:get_step(RunId, StepId) of
        {ok, Step} ->
            case ensure_step_transition(Step, TargetStatus) of
                ok ->
                    Now = erlang:system_time(millisecond),
                    Updated = terminalize_step(Step, TargetStatus, Payload, Now),
                    ok = beam_agent_runs_store:put_step(Updated),
                    ok = touch_run_id(RunId, Now),
                    {ok, _Entry} = append_step_event(step_event_type(TargetStatus), Updated),
                    emit_state_change(step, maps:get(status, Step), TargetStatus,
                        telemetry_step_meta(Updated)),
                    {ok, Updated};
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    telemetry_finish(step, Operation, StartTime, Result, TeleMeta),
    Result.

-spec ensure_run_transition(run(), terminal_status()) ->
    ok | run_transition_error().
ensure_run_transition(#{status := running}, _Target) ->
    ok;
ensure_run_transition(#{status := Current}, Target) ->
    {error, {invalid_status_transition, Current, Target}}.

-spec ensure_step_transition(step(), terminal_status()) ->
    ok | step_transition_error().
ensure_step_transition(#{status := running}, _Target) ->
    ok;
ensure_step_transition(#{status := Current}, Target) ->
    {error, {invalid_status_transition, Current, Target}}.

-spec active_steps(binary()) -> [step()].
active_steps(RunId) ->
    {ok, Steps} = beam_agent_runs_store:list_steps(RunId),
    [Step || #{status := running} = Step <- Steps].

-spec cascade_active_steps(binary(), failed | cancelled, term(), integer()) -> ok.  %% Payload is genuinely term(): cascaded from caller-provided error/cancel payload
cascade_active_steps(RunId, TargetStatus, Payload, Now) ->
    {ok, Steps} = beam_agent_runs_store:list_steps(RunId),
    lists:foreach(fun
        (#{status := running} = Step) ->
            Updated = terminalize_step(Step, TargetStatus, Payload, Now),
            ok = beam_agent_runs_store:put_step(Updated),
            {ok, _Entry} = append_step_event(step_event_type(TargetStatus), Updated);
        (_) ->
            ok
    end, Steps),
    ok.

-spec terminalize_run(run(), completed | failed | cancelled, term(), term(), term(),  %% Result/ErrorTerm/CancelReason are genuinely term(): caller-provided payloads
    integer()) -> run().
terminalize_run(Run, completed, Result, _ErrorTerm, _CancelReason, Now) ->
    (maps:without([error, cancel_reason], Run))#{
        status => completed,
        output => Result,
        completed_at => Now,
        updated_at => Now
    };
terminalize_run(Run, failed, _Result, ErrorTerm, _CancelReason, Now) ->
    (maps:without([output, cancel_reason], Run))#{
        status => failed,
        error => ErrorTerm,
        completed_at => Now,
        updated_at => Now
    };
terminalize_run(Run, cancelled, _Result, _ErrorTerm, CancelReason, Now) ->
    (maps:without([output, error], Run))#{
        status => cancelled,
        cancel_reason => CancelReason,
        completed_at => Now,
        updated_at => Now
    }.

-spec terminalize_step(step(), completed | failed | cancelled, term(), integer()) -> step().  %% Payload is genuinely term(): caller-provided result/error/cancel payload
terminalize_step(Step, completed, Result, Now) ->
    (maps:without([error, cancel_reason], Step))#{
        status => completed,
        output => Result,
        completed_at => Now,
        updated_at => Now
    };
terminalize_step(Step, failed, ErrorTerm, Now) ->
    (maps:without([output, cancel_reason], Step))#{
        status => failed,
        error => ErrorTerm,
        completed_at => Now,
        updated_at => Now
    };
terminalize_step(Step, cancelled, Reason, Now) ->
    (maps:without([output, error], Step))#{
        status => cancelled,
        cancel_reason => Reason,
        completed_at => Now,
        updated_at => Now
    }.

-spec touch_run(run(), integer()) -> ok.
touch_run(Run, Now) ->
    ok = beam_agent_runs_store:put_run(Run#{updated_at => Now}).

-spec touch_run_id(binary(), integer()) -> ok.
touch_run_id(RunId, Now) ->
    case beam_agent_runs_store:get_run(RunId) of
        {ok, Run} ->
            touch_run(Run, Now);
        {error, not_found} ->
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Scope Helpers
%%--------------------------------------------------------------------

-spec resolve_parent_scope(binary() | undefined, binary() | undefined, binary() | undefined) ->
    {ok, normalized_scope()} |
    {error, parent_run_not_found | inconsistent_parent_scope |
        session_id_required_for_thread}.
resolve_parent_scope(SessionId, ThreadId, undefined) ->
    case {SessionId, ThreadId} of
        {undefined, undefined} ->
            {ok, #{}};
        {undefined, _Thread} ->
            {error, session_id_required_for_thread};
        {_Session, undefined} ->
            {ok, #{session_id => SessionId}};
        {_Session, _Thread} ->
            {ok, #{session_id => SessionId, thread_id => ThreadId}}
    end;
resolve_parent_scope(SessionId, ThreadId, ParentRunId) ->
    case beam_agent_runs_store:get_run(ParentRunId) of
        {ok, ParentRun} ->
            case merge_parent_scope(session_id, SessionId, ParentRun) of
                {ok, ResolvedSessionId} ->
                    case merge_parent_scope(thread_id, ThreadId, ParentRun) of
                        {ok, ResolvedThreadId} ->
                            case {ResolvedSessionId, ResolvedThreadId} of
                                {undefined, undefined} ->
                                    {ok, #{parent_run_id => ParentRunId}};
                                {undefined, _Thread} ->
                                    {error, session_id_required_for_thread};
                                {_Session, undefined} ->
                                    {ok, #{
                                        parent_run_id => ParentRunId,
                                        session_id => ResolvedSessionId
                                    }};
                                {_Session, _Thread} ->
                                    {ok, #{
                                        parent_run_id => ParentRunId,
                                        session_id => ResolvedSessionId,
                                        thread_id => ResolvedThreadId
                                    }}
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        {error, not_found} ->
            {error, parent_run_not_found}
    end.

-spec merge_parent_scope(session_id | thread_id, binary() | undefined, run()) ->
    {ok, binary() | undefined} | {error, inconsistent_parent_scope}.
merge_parent_scope(Key, ExplicitValue, ParentRun) ->
    ParentValue = maps:get(Key, ParentRun, undefined),
    case {ExplicitValue, ParentValue} of
        {undefined, undefined} ->
            {ok, undefined};
        {undefined, Value} ->
            {ok, Value};
        {Value, undefined} ->
            {ok, Value};
        {Value, Value} ->
            {ok, Value};
        {_Explicit, _Parent} ->
            {error, inconsistent_parent_scope}
    end.

-spec inherit_run_scope(run(), step()) -> step().
inherit_run_scope(Run, Step) ->
    Step1 = maybe_put(session_id, maps:get(session_id, Run, undefined), Step),
    maybe_put(thread_id, maps:get(thread_id, Run, undefined), Step1).

%%--------------------------------------------------------------------
%% Internal: Validation Helpers
%%--------------------------------------------------------------------

-spec validate_allowed_keys(map(), [atom()], atom()) -> ok | {error, {atom(), atom()}}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case [Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [BadKey | _] ->
            {error, {ErrorTag, BadKey}}
    end.

-spec normalize_optional_binary(normalize_binary_key(), map()) ->
    {ok, binary() | undefined} |
    {error,
        {invalid_filter, normalize_binary_key()} |
        {invalid_run_opt, run_id} |
        {invalid_scope, parent_run_id | session_id | thread_id} |
        {invalid_step_opt, step_id}}.
normalize_optional_binary(Key, Map) ->
    case maps:find(Key, Map) of
        error ->
            {ok, undefined};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 ->
            {ok, Value};
        {ok, _Value} when Key =:= session_id; Key =:= thread_id; Key =:= parent_run_id ->
            {error, {invalid_scope, Key}};
        {ok, _Value} when Key =:= run_id ->
            {error, {invalid_run_opt, Key}};
        {ok, _Value} when Key =:= step_id ->
            {error, {invalid_step_opt, Key}};
        {ok, _Value} ->
            {error, {invalid_filter, Key}}
    end.

-spec normalize_kind(kind, term(), invalid_run_opt | invalid_step_opt | invalid_filter) ->  %% Value is genuinely term(): validates arbitrary user input
    {ok, atom() | binary()} |
    {error, {invalid_run_opt | invalid_step_opt | invalid_filter, kind}}.
normalize_kind(_Key, Value, _ErrorTag) when is_atom(Value) ->
    {ok, Value};
normalize_kind(_Key, Value, _ErrorTag) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_kind(Key, _Value, ErrorTag) ->
    {error, {ErrorTag, Key}}.

-spec normalize_metadata(map(), invalid_run_opt | invalid_step_opt) ->
    {ok, map()} | {error, {invalid_run_opt | invalid_step_opt, metadata}}.
normalize_metadata(Opts, ErrorTag) ->
    case maps:get(metadata, Opts, #{}) of
        Metadata when is_map(Metadata) ->
            {ok, Metadata};
        _Other ->
            {error, {ErrorTag, metadata}}
    end.

-spec normalize_optional_kind(map()) ->
    {ok, run_kind() | undefined} | {error, {invalid_filter, kind}}.
normalize_optional_kind(Filter) ->
    case maps:find(kind, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} ->
            normalize_kind(kind, Value, invalid_filter)
    end.

-spec normalize_optional_status(map()) ->
    {ok, run_status() | undefined} | {error, {invalid_filter, status}}.
normalize_optional_status(Filter) ->
    case maps:find(status, Filter) of
        error ->
            {ok, undefined};
        {ok, Status} when Status =:= running; Status =:= completed;
                           Status =:= failed; Status =:= cancelled ->
            {ok, Status};
        {ok, _Other} ->
            {error, {invalid_filter, status}}
    end.

-spec normalize_limit(map()) ->
    {ok, pos_integer() | undefined} | {error, {invalid_filter, limit}}.
normalize_limit(Filter) ->
    case maps:find(limit, Filter) of
        error ->
            {ok, undefined};
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            {ok, Limit};
        {ok, _Other} ->
            {error, {invalid_filter, limit}}
    end.

-spec normalize_since(map()) ->
    {ok, integer() | undefined} | {error, {invalid_filter, since}}.
normalize_since(Filter) ->
    case maps:find(since, Filter) of
        error ->
            {ok, undefined};
        {ok, Since} when is_integer(Since) ->
            {ok, Since};
        {ok, _Other} ->
            {error, {invalid_filter, since}}
    end.

%%--------------------------------------------------------------------
%% Internal: Misc Helpers
%%--------------------------------------------------------------------

-spec maybe_put(runs_put_key(), term(), runs_put_map()) -> runs_put_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec generate_run_id() -> <<_:32, _:_*8>>.
generate_run_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<"run_", Hex/binary>>.

-spec generate_step_id() -> <<_:40, _:_*8>>.
generate_step_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<"step_", Hex/binary>>.

-spec run_event_type(failed | cancelled) -> run_event_type_binary().
run_event_type(failed) -> <<"run_failed">>;
run_event_type(cancelled) -> <<"run_cancelled">>.

-spec step_event_type(completed | failed | cancelled) -> step_event_type_binary().
step_event_type(completed) -> <<"step_completed">>;
step_event_type(failed) -> <<"step_failed">>;
step_event_type(cancelled) -> <<"step_cancelled">>.

-spec append_run_event(<<_:64, _:_*8>>, run()) ->
    {ok, beam_agent_journal_core:entry()} | {error, journal_error()}.
append_run_event(EventType, Run) ->
    Event0 = #{
        run_id => maps:get(run_id, Run),
        tags => [run],
        payload => #{run => Run}
    },
    Event1 = maybe_put(session_id, maps:get(session_id, Run, undefined), Event0),
    Event2 = maybe_put(thread_id, maps:get(thread_id, Run, undefined), Event1),
    beam_agent_journal_core:append(EventType, Event2).

-spec append_step_event(<<_:64, _:_*8>>, step()) ->
    {ok, beam_agent_journal_core:entry()} | {error, journal_error()}.
append_step_event(EventType, Step) ->
    Event0 = #{
        run_id => maps:get(run_id, Step),
        tags => [run, step],
        payload => #{step => Step}
    },
    Event1 = maybe_put(session_id, maps:get(session_id, Step, undefined), Event0),
    Event2 = maybe_put(thread_id, maps:get(thread_id, Step, undefined), Event1),
    beam_agent_journal_core:append(EventType, Event2).

-spec telemetry_scope_meta(scope()) -> map().
telemetry_scope_meta(SessionId) when is_binary(SessionId) ->
    #{session_id => SessionId};
telemetry_scope_meta(Scope) when is_map(Scope) ->
    maps:with([session_id, thread_id, parent_run_id], Scope).

-spec telemetry_run_request_meta(map(), map()) -> run_telemetry_request_meta().
telemetry_run_request_meta(Opts, ScopeMeta) ->
    ScopeMeta#{
        requested_kind => maps:get(kind, Opts, undefined),
        run_id => maps:get(run_id, Opts, undefined)
    }.

-spec telemetry_step_request_meta(binary(), map()) -> step_telemetry_request_meta().
telemetry_step_request_meta(RunId, Opts) ->
    #{
        run_id => RunId,
        requested_kind => maps:get(kind, Opts, undefined),
        step_id => maps:get(step_id, Opts, undefined)
    }.

-spec telemetry_run_meta(run()) -> run_telemetry_meta().
telemetry_run_meta(Run) ->
    #{
        run_id => maps:get(run_id, Run),
        kind => maps:get(kind, Run),
        status => maps:get(status, Run)
    }.

-spec telemetry_step_meta(step()) -> step_telemetry_meta().
telemetry_step_meta(Step) ->
    #{
        run_id => maps:get(run_id, Step),
        step_id => maps:get(step_id, Step),
        kind => maps:get(kind, Step),
        status => maps:get(status, Step)
    }.

-spec run_transition_operation(failed | cancelled) ->
    fail_run | cancel_run.
run_transition_operation(failed) -> fail_run;
run_transition_operation(cancelled) -> cancel_run.

-spec step_transition_operation(completed | failed | cancelled) ->
    complete_step | fail_step | cancel_step.
step_transition_operation(completed) -> complete_step;
step_transition_operation(failed) -> fail_step;
step_transition_operation(cancelled) -> cancel_step.

-spec telemetry_start(telemetry_domain(), telemetry_operation(),
    run_telemetry_request_meta() | step_telemetry_request_meta() | telemetry_metadata()) ->
    integer().
telemetry_start(Domain, Operation, Metadata) ->
    beam_agent_telemetry:span_start(Domain, Operation, compact_telemetry(Metadata)).

-spec telemetry_finish(telemetry_domain(), telemetry_operation(), integer(),
    telemetry_result(),
    run_telemetry_request_meta() | step_telemetry_request_meta() | telemetry_metadata()) -> ok.
telemetry_finish(Domain, Operation, StartTime, {ok, Value}, Metadata) when is_map(Value) ->
    beam_agent_telemetry:span_stop(Domain, Operation, StartTime,
        compact_telemetry(maps:merge(Metadata, success_telemetry(Value))));
telemetry_finish(Domain, Operation, _StartTime, {error, Reason}, Metadata) ->
    beam_agent_telemetry:span_exception(Domain, Operation, Reason,
        compact_telemetry(Metadata)).

-spec emit_state_change(telemetry_domain(), created | running | terminal_current_status(),
    running | terminal_status(), run_telemetry_meta() | step_telemetry_meta()) -> ok.
emit_state_change(Domain, FromState, ToState, Metadata) ->
    beam_agent_telemetry:state_change(Domain, FromState, ToState,
        compact_telemetry(Metadata)).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).

-spec success_telemetry(run() | step()) -> map().
success_telemetry(Value) ->
    maps:with([run_id, step_id, session_id, thread_id, kind, status], Value).
