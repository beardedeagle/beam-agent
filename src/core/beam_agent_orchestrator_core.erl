-module(beam_agent_orchestrator_core).
-moduledoc """
Canonical BeamAgent orchestration primitives.

This module exposes process-free parent-child orchestration mechanics over
canonical runs, sessions, threads, and the durable journal. It does not own a
scheduler, worker pool, or resident process. Consumers drive orchestration
from the processes they already own.

Two constraints shape the implementation:

- `beam_agent_runs` remains the canonical unit-of-work store.
- orchestration links must support cross-session children, which cannot be
  represented solely through `parent_run_id` in runs because run parent-scope
  inheritance intentionally enforces same-scope lineage.

The orchestrator therefore stores explicit lineage links in
`beam_agent_orchestrator_store` while keeping child execution state in
canonical runs.
""".

-export([
    ensure_tables/0,
    clear/0,
    spawn/2,
    delegate/3,
    await/2,
    collect/2,
    cancel/2,
    status/1,
    list_children/1
]).

-export_type([
    parent/0,
    relation/0,
    substrate/0,
    session_target/0,
    thread_target/0,
    spawn_opts/0,
    child/0,
    child_status/0,
    collect_opts/0,
    collect_result/0,
    await_result/0
]).

-type relation() :: beam_agent_orchestrator_store:relation().
-type substrate() :: beam_agent_orchestrator_store:substrate().
-type parent() :: binary() | beam_agent_runs_core:run().

-type session_target() ::
    inherit
  | none
  | binary()
  | pid()
  | #{
        kind := live,
        ref := pid(),
        stop_session => boolean()
    }
  | #{
        kind := session_id,
        id := binary()
    }
  | #{
        kind := routed,
        opts := map(),
        stop_session => boolean()
    }.

-type thread_target() ::
    inherit
  | none
  | binary()
  | #{
        thread_id := binary()
    }
  | #{
        start := map()
    }.

-type spawn_opts() :: #{
    run_id => binary(),
    kind => atom() | binary(),
    input => term(),
    metadata => map(),
    session => session_target(),
    thread => thread_target()
}.

-type child() :: #{
    relation := relation(),
    substrate := substrate(),
    parent_run_id := binary(),
    run := beam_agent_runs_core:run(),
    metadata := map(),
    task => term(),
    session_id => binary(),
    thread_id => binary(),
    session_ref => pid(),
    owns_session => boolean(),
    stop_session => boolean(),
    thread => map()
}.

-type child_status() :: #{
    run := beam_agent_runs_core:run(),
    relation => relation(),
    parent_run_id => binary(),
    substrate => substrate(),
    session_id => binary(),
    thread_id => binary(),
    child_count := non_neg_integer(),
    active_child_count := non_neg_integer(),
    step_count := non_neg_integer(),
    active_step_count := non_neg_integer(),
    awaitable := boolean(),
    metadata => map(),
    task => term()
}.

-type collect_opts() :: #{
    include_steps => boolean(),
    include_journal => boolean(),
    include_descendants => boolean()
}.

-type collect_result() :: #{
    run := beam_agent_runs_core:run(),
    children := [child()],
    descendants => [child()],
    steps => [beam_agent_runs_core:step()],
    journal => [beam_agent_journal_core:entry()],
    link => beam_agent_orchestrator_store:link_record()
}.

-type await_result() :: #{
    status := beam_agent_runs_core:run_status(),
    run := beam_agent_runs_core:run(),
    output => term(),
    error => term(),
    cancel_reason => term()
}.

-type normalized_spawn_opts() :: #{
    metadata := map(),
    session := normalized_session_target(),
    thread := normalized_thread_target(),
    kind => atom() | binary(),
    input => term(),
    run_id => binary()
}.

-type normalized_session_target() ::
    inherit
  | none
  | #{
        kind := live,
        ref := pid(),
        stop_session := boolean()
    }
  | #{
        kind := session_id,
        id := binary()
    }
  | #{
        kind := routed,
        opts := map(),
        stop_session := boolean()
    }.

-type normalized_thread_target() ::
    inherit
  | none
  | #{
        kind := thread_id,
        id := binary()
    }
  | #{
        kind := start,
        opts := map()
    }.

-type session_resolution() :: #{
    session_id => binary(),
    session_ref => pid(),
    owns_session := boolean(),
    stop_session := boolean(),
    session_inherited := boolean()
}.

-type thread_resolution() :: #{
    thread_id => binary(),
    thread => map(),
    thread_inherited := boolean(),
    thread_started := boolean()
}.
-type spawn_context() :: #{
    owns_session := boolean(),
    session_inherited := boolean(),
    stop_session := boolean(),
    thread_inherited => boolean(),
    thread_started => boolean(),
    session_id => binary(),
    session_ref => pid(),
    thread => map(),
    thread_id => binary()
}.
-type resolved_spawn_context() :: #{
    owns_session := boolean(),
    session_inherited := boolean(),
    stop_session := boolean(),
    thread_inherited := boolean(),
    thread_started := boolean(),
    session_id => binary(),
    session_ref => pid(),
    thread => map(),
    thread_id => binary()
}.
-type child_link() :: #{
    metadata := map(),
    parent_run_id := binary(),
    relation := relation(),
    substrate := substrate(),
    child_run_id => binary(),
    child_session_id => binary(),
    child_thread_id => binary(),
    created_at => integer(),
    owns_session => boolean(),
    sequence => pos_integer(),
    session_ref => pid(),
    stop_session => boolean(),
    task => term(),
    updated_at => integer()
}.
-type spawn_error() ::
    already_exists
  | inconsistent_parent_scope
  | parent_run_not_found
  | session_id_required_for_thread
  | {invalid_run_opt, kind | metadata | run_id}
  | {invalid_scope, atom()}
  | {policy_denied, binary()}
  | {unsupported_scope_key, atom()}.
-type collect_error() ::
    {invalid_collect_opt, include_descendants | include_journal | include_steps}
  | {unsupported_collect_opt, atom()}
  | {unsupported_spawn_opt, atom()}.
-type normalized_collect_opts() :: #{
    include_descendants := boolean(),
    include_journal := boolean(),
    include_steps := boolean()
}.
-type cancel_origin() :: root | {child_of, binary()}.
-type orchestrator_meta() :: #{
    orchestrator := #{atom() => term()},
    _ => term()
}.
-type orchestrator_pair_key() ::
    cancel_reason | error | metadata | output | parent_run_id | relation | session_id |
    substrate | task | thread_id.
-type orchestrator_optional_boolean_key() ::
    include_descendants | include_journal | include_steps.
-type orchestrator_operation() ::
    await | cancel | collect | delegate | list_children | spawn | status.
-type run_scope_map() :: #{atom() => term()}.
-type orchestrator_payload() :: #{
    child_run_id := binary(),
    parent_run_id := binary(),
    relation => relation(),
    substrate => substrate(),
    child_session_id => term(),
    child_thread_id => term(),
    origin => cancel_origin(),
    reason => term(),
    task => term()
}.

-define(DEFAULT_AWAIT_POLL_MS, 25).
-define(DEFAULT_KIND, orchestrator_child).

-doc "Ensure the orchestrator ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_orchestrator_store:ensure_tables().

-doc "Clear all orchestrator lineage state. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_orchestrator_store:clear().

-doc """
Create a child orchestration record, optionally opening a child session or
thread substrate.
""".
-spec spawn(parent(), spawn_opts()) ->
    {ok, child()} | {error, spawn_error() | {parent_not_running, beam_agent_runs_core:run_status()} |
        parent_not_found | {invalid_parent, parent()} |
        {unsupported_spawn_opt, atom()} | {invalid_spawn_opt, atom()} |
        session_required_for_thread | {invalid_session_target, session_target()} |
        {invalid_thread_target, thread_target()}}.
spawn(Parent, Opts) when is_map(Opts) ->
    TeleMeta = telemetry_spawn_meta(Parent, Opts),
    StartTime = telemetry_start(spawn, TeleMeta),
    Result = case resolve_parent_run(Parent) of
        {ok, ParentRun} ->
            case normalize_spawn_opts(Opts) of
                {ok, Normalized} ->
                    spawn_child(ParentRun, spawned, undefined, Normalized);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(spawn, StartTime, Result, TeleMeta),
    Result.

-doc """
Create a delegated child run under a parent run.

Delegation records the task payload and lineage immediately but does not start
any worker loop inside BeamAgent.
""".
-spec delegate(parent(), term(), map()) ->
    {ok, beam_agent_runs_core:run()} | {error, spawn_error() |
        {unsupported_delegate_opt, input} |
        {parent_not_running, beam_agent_runs_core:run_status()} |
        parent_not_found | {invalid_parent, parent()} |
        {unsupported_spawn_opt, atom()} | {invalid_spawn_opt, atom()} |
        session_required_for_thread | {invalid_session_target, session_target()} |
        {invalid_thread_target, thread_target()}}.
delegate(Parent, Task, Opts) when is_map(Opts) ->
    TeleMeta = (telemetry_spawn_meta(Parent, Opts))#{
        delegated => true,
        task_present => (Task =/= undefined)
    },
    StartTime = telemetry_start(delegate, TeleMeta),
    Result = case maps:is_key(input, Opts) of
        true ->
            {error, {unsupported_delegate_opt, input}};
        false ->
            case resolve_parent_run(Parent) of
                {ok, ParentRun} ->
                    case normalize_spawn_opts(Opts#{input => Task}) of
                        {ok, Normalized} ->
                            case spawn_child(ParentRun, delegated, Task, Normalized) of
                                {ok, #{run := ChildRun}} ->
                                    {ok, ChildRun};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end,
    telemetry_finish(delegate, StartTime, Result, TeleMeta),
    Result.

-doc """
Wait for a run to reach a terminal state by polling the canonical run store.
""".
-spec await(binary(), non_neg_integer()) ->
    {ok, await_result()} |
    {error, timeout | not_found | {invalid_timeout, non_neg_integer()}}.
await(RunId, Timeout)
  when is_binary(RunId), is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    TeleMeta = #{run_id => RunId, timeout => Timeout},
    StartTime = telemetry_start(await, TeleMeta),
    Result = await_loop(RunId, Deadline),
    telemetry_finish(await, StartTime, Result, TeleMeta),
    Result;
await(_RunId, Timeout) ->
    {error, {invalid_timeout, Timeout}}.

-doc """
Collect the canonical orchestration view for a run.

Supported opts:
  - `include_steps` (default `true`)
  - `include_journal` (default `true`)
  - `include_descendants` (default `false`)
""".
-spec collect(binary(), collect_opts()) -> {ok, collect_result()} | {error, not_found | collect_error()}.
collect(RunId, Opts) when is_binary(RunId), is_map(Opts) ->
    TeleMeta = (maps:with([include_steps, include_journal, include_descendants], Opts))#{
        run_id => RunId
    },
    StartTime = telemetry_start(collect, TeleMeta),
    Result = case normalize_collect_opts(Opts) of
        {ok, Normalized} ->
            case beam_agent_runs:get_run(RunId) of
                {ok, Run} ->
                    {ok, Children} = list_children(RunId),
                    Descendants = case maps:get(include_descendants, Normalized) of
                        true -> list_descendants(RunId);
                        false -> []
                    end,
                    StepsEntry = case maps:get(include_steps, Normalized) of
                        true ->
                            case beam_agent_runs:list_steps(RunId) of
                                {ok, Steps} -> [{steps, Steps}];
                                {error, not_found} -> [{steps, []}]
                            end;
                        false ->
                            []
                    end,
                    JournalEntry = case maps:get(include_journal, Normalized) of
                        true ->
                            JournalRunIds = case maps:get(include_descendants, Normalized) of
                                true ->
                                    [RunId | [CRunId ||
                                        #{run := #{run_id := CRunId}} <- Descendants]];
                                false ->
                                    [RunId]
                            end,
                            [{journal, collect_journal(JournalRunIds)}];
                        false ->
                            []
                    end,
                    LinkEntry = case beam_agent_orchestrator_store:get_link(RunId) of
                        {ok, Link} -> [{link, Link}];
                        {error, not_found} -> []
                    end,
                    Base = #{
                        run => Run,
                        children => Children
                    },
                    DescendantEntry = case maps:get(include_descendants, Normalized) of
                        true -> [{descendants, Descendants}];
                        false -> []
                    end,
                    {ok, maps:from_list(
                        maps:to_list(Base) ++ LinkEntry ++ StepsEntry ++
                        DescendantEntry ++ JournalEntry
                    )};
                {error, not_found} ->
                    {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(collect, StartTime, Result, TeleMeta),
    Result.

-doc """
Cancel a run and any active orchestrated descendants.
""".
-spec cancel(binary(), term()) -> ok | {error, not_found |
    {invalid_status_transition, beam_agent_runs_core:run_status(), cancelled}}.
cancel(RunId, Reason) when is_binary(RunId) ->
    StartTime = telemetry_start(cancel, #{run_id => RunId}),
    Result = case cancel_tree(RunId, Reason, root) of
        ok ->
            ok;
        {error, _} = Error ->
            Error
    end,
    case Result of
        ok ->
            telemetry_stop(cancel, StartTime, #{run_id => RunId}),
            ok;
        {error, _} = ErrorResult ->
            telemetry_exception(cancel, ErrorResult, #{run_id => RunId}),
            ErrorResult
    end.

-doc "Return a summary status map for a run and its direct children.".
-spec status(binary()) -> {ok, child_status()} | {error, not_found}.
status(RunId) when is_binary(RunId) ->
    StartTime = telemetry_start(status, #{run_id => RunId}),
    Result = case beam_agent_runs:get_run(RunId) of
        {ok, Run} ->
            {ok, Steps} = beam_agent_runs:list_steps(RunId),
            {ok, Children} = list_children(RunId),
            {ActiveStepCount, StepCount} = step_counts(Steps),
            {ActiveChildCount, ChildCount} = child_counts(Children),
            #{status := RunStatus} = Run,
            Base = #{
                run => Run,
                step_count => StepCount,
                active_step_count => ActiveStepCount,
                child_count => ChildCount,
                active_child_count => ActiveChildCount,
                awaitable => RunStatus =:= running
            },
            LinkInfo = case beam_agent_orchestrator_store:get_link(RunId) of
                {ok, Link} ->
                    link_status_entries(Link);
                {error, not_found} ->
                    []
            end,
            {ok, maps:from_list(maps:to_list(Base) ++ LinkInfo)};
        {error, not_found} ->
            {error, not_found}
    end,
    telemetry_finish(status, StartTime, Result, #{run_id => RunId}),
    Result.

-doc "List direct orchestrator children for a parent run, oldest first.".
-spec list_children(parent()) -> {ok, [child()]} | {error, parent_not_found | {invalid_parent, parent()}}.
list_children(Parent) ->
    TeleMeta = telemetry_parent_meta(Parent),
    StartTime = telemetry_start(list_children, TeleMeta),
    Result = case resolve_parent_run_id(Parent) of
        {ok, ParentRunId} ->
            {ok, Links} = beam_agent_orchestrator_store:list_children(ParentRunId),
            {ok, [child_view(Link) || Link <- Links]};
        {error, _} = Error ->
            Error
    end,
    case Result of
        {ok, Children} ->
            telemetry_stop(list_children, StartTime,
                TeleMeta#{result_count => length(Children)}),
            Result;
        {error, _} = ErrorResult ->
            telemetry_exception(list_children, ErrorResult, TeleMeta),
            ErrorResult
    end.

%%--------------------------------------------------------------------
%% Internal: spawn/delegate
%%--------------------------------------------------------------------

-spec spawn_child(beam_agent_runs_core:run(), relation(), term() | undefined,
    normalized_spawn_opts()) ->
    {ok, child()} | {error, spawn_error() |
        {parent_not_running, beam_agent_runs_core:run_status()} |
        session_required_for_thread | {invalid_session_target, session_target()} |
        {invalid_thread_target, thread_target()}}.
spawn_child(ParentRun, Relation, Task, Opts) ->
    ensure_tables(),
    case ensure_parent_running(ParentRun) of
        ok ->
            case resolve_spawn_context(ParentRun, Opts) of
                {ok, Ctx} ->
                    case persist_child_run(ParentRun, Relation, Task, Opts, Ctx) of
                        {ok, Child} ->
                            {ok, Child};
                        {error, _} = Error ->
                            cleanup_spawn_context(Ctx),
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec persist_child_run(beam_agent_runs_core:run(), relation(), term() | undefined,
    normalized_spawn_opts(), resolved_spawn_context()) ->
    {ok, child()} | {error, spawn_error()}.
persist_child_run(ParentRun, Relation, Task, Opts, Ctx) ->
    %% Use maps:find to surface a descriptive error when run_id is missing,
    %% preventing orphaned child runs with inconsistent lineage.
    ParentRunId = case maps:find(run_id, ParentRun) of
        {ok, Id} -> Id;
        error -> error({missing_run_id, ParentRun})
    end,
    RunScope = build_run_scope(Ctx),
    Substrate = determine_substrate(Ctx),
    Metadata = orchestrator_metadata(
        ParentRunId, Relation, Substrate, maps:get(metadata, Opts, #{}), Ctx
    ),
    case evaluate_orchestrator_policy(Relation, Metadata, ParentRun, Task, RunScope, Ctx) of
        allow ->
            RunOpts0 = #{
                kind => maps:get(kind, Opts, default_kind(Relation)),
                metadata => Metadata
            },
            RunOpts1 = maybe_put(run_id, maps:get(run_id, Opts, undefined), RunOpts0),
            RunOpts = maybe_put(input, maps:get(input, Opts, undefined), RunOpts1),
            case beam_agent_runs:start_run(RunScope, RunOpts) of
                {ok, Run} ->
                    %% Use maps:find to surface a descriptive error if start_run
                    %% returns a run without a run_id — would indicate a broken
                    %% runs implementation and should never be silently swallowed.
                    ChildRunId = case maps:find(run_id, Run) of
                        {ok, Cid} -> Cid;
                        error -> error({missing_run_id, Run})
                    end,
                    Now = erlang:system_time(millisecond),
                    Link = #{
                        child_run_id => ChildRunId,
                        parent_run_id => ParentRunId,
                        relation => Relation,
                        substrate => Substrate,
                        metadata => maps:get(metadata, Opts, #{}),
                        sequence => erlang:unique_integer([monotonic, positive]),
                        created_at => Now,
                        updated_at => Now
                    },
                    Link1 = maybe_put(child_session_id, maps:get(session_id, Run, undefined),
                        Link),
                    Link2 = maybe_put(child_thread_id, maps:get(thread_id, Run, undefined),
                        Link1),
                    Link3 = maybe_put(task, Task, Link2),
                    Link4 = maybe_put(session_ref, maps:get(session_ref, Ctx, undefined), Link3),
                    Link5 = maybe_put(owns_session, maps:get(owns_session, Ctx, undefined),
                        Link4),
                    Link6 = maybe_put(stop_session, maps:get(stop_session, Ctx, undefined),
                        Link5),
                    ok = beam_agent_orchestrator_store:put_link(Link6),
                    ok = append_orchestrator_event(orchestrator_event(Relation), #{
                        parent_run_id => ParentRunId,
                        child_run_id => ChildRunId,
                        relation => Relation,
                        substrate => Substrate,
                        child_session_id => maps:get(session_id, Run, undefined),
                        child_thread_id => maps:get(thread_id, Run, undefined),
                        task => Task
                    }),
                    ok = audit_orchestrator_event(Relation, Link6, allow, undefined),
                    {ok, child_from_parts(Link6, Run, maps:get(thread, Ctx, undefined))};
                {error, _} = Error ->
                    Error
            end;
        {deny, Reason} ->
            Link = #{
                parent_run_id => ParentRunId,
                relation => Relation,
                substrate => Substrate,
                metadata => maps:get(metadata, Opts, #{})
            },
            ok = audit_orchestrator_event(Relation, Link, deny, Reason),
            {error, {policy_denied, Reason}}
    end.

-spec resolve_spawn_context(beam_agent_runs_core:run(), normalized_spawn_opts()) ->
    {ok, resolved_spawn_context()} | {error, session_required_for_thread |
        {invalid_session_target, session_target()}}.
resolve_spawn_context(ParentRun, Opts) ->
    ParentSessionId = maps:get(session_id, ParentRun, undefined),
    ParentThreadId = maps:get(thread_id, ParentRun, undefined),
    case resolve_session_target(maps:get(session, Opts), ParentSessionId) of
        {ok, SessionCtx} ->
            case resolve_thread_target(maps:get(thread, Opts), SessionCtx, ParentThreadId) of
                {ok, ThreadCtx} ->
                    {ok, maps:merge(SessionCtx, ThreadCtx)};
                {error, _} = Error ->
                    cleanup_spawn_context(SessionCtx),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec resolve_session_target(normalized_session_target(), binary() | undefined) ->
    {ok, session_resolution()} | {error, {invalid_session_target, session_target()}}.
resolve_session_target(inherit, ParentSessionId) ->
    {ok, maybe_put(session_id, ParentSessionId, #{
        owns_session => false,
        stop_session => false,
        session_inherited => true
    })};
resolve_session_target(none, _ParentSessionId) ->
    {ok, #{
        owns_session => false,
        stop_session => false,
        session_inherited => false
    }};
resolve_session_target(#{kind := session_id, id := SessionId}, _ParentSessionId) ->
    {ok, #{
        session_id => SessionId,
        owns_session => false,
        stop_session => false,
        session_inherited => false
    }};
resolve_session_target(#{kind := live, ref := SessionRef, stop_session := StopSession},
    _ParentSessionId) ->
    {ok, #{
        session_id => beam_agent_core:session_identity(SessionRef),
        session_ref => SessionRef,
        owns_session => false,
        stop_session => StopSession,
        session_inherited => false
    }};
resolve_session_target(#{kind := routed, opts := SessionOpts, stop_session := StopSession},
    _ParentSessionId) ->
    case beam_agent:start_session(SessionOpts) of
        {ok, SessionRef} ->
            {ok, #{
                session_id => beam_agent_core:session_identity(SessionRef),
                session_ref => SessionRef,
                owns_session => true,
                stop_session => StopSession,
                session_inherited => false
            }};
        {error, _} = Error ->
            Error
    end.

-spec resolve_thread_target(normalized_thread_target(), session_resolution(),
    binary() | undefined) ->
    {ok, thread_resolution()} | {error, session_required_for_thread |
        {invalid_thread_target, thread_target()}}.
resolve_thread_target(inherit, SessionCtx, ParentThreadId) ->
    SessionId = maps:get(session_id, SessionCtx, undefined),
    case {ParentThreadId, SessionId, maps:get(session_inherited, SessionCtx, false)} of
        {ThreadId, _, true} when is_binary(ThreadId) ->
            {ok, #{
                thread_id => ThreadId,
                thread_inherited => true,
                thread_started => false
            }};
        _ ->
            {ok, #{
                thread_inherited => false,
                thread_started => false
            }}
    end;
resolve_thread_target(none, _SessionCtx, _ParentThreadId) ->
    {ok, #{
        thread_inherited => false,
        thread_started => false
    }};
resolve_thread_target(#{kind := thread_id, id := ThreadId}, SessionCtx, _ParentThreadId) ->
    with_thread_owner(SessionCtx, fun(Session) ->
        case beam_agent_threads:thread_resume(Session, ThreadId) of
            {ok, Thread} ->
                {ok, #{
                    thread_id => maps:get(thread_id, Thread),
                    thread => Thread,
                    thread_inherited => false,
                    thread_started => false
                }};
            {error, _} = Error ->
                Error
        end
    end);
resolve_thread_target(#{kind := start, opts := ThreadOpts}, SessionCtx, _ParentThreadId) ->
    with_thread_owner(SessionCtx, fun(Session) ->
        case beam_agent_threads:thread_start(Session, ThreadOpts) of
            {ok, Thread} ->
                {ok, #{
                    thread_id => maps:get(thread_id, Thread),
                    thread => Thread,
                    thread_inherited => false,
                    thread_started => true
                }};
            {error, _} = Error ->
                Error
        end
    end).

-spec with_thread_owner(session_resolution(),
    fun((pid() | binary()) -> {ok, thread_resolution()} | {error, session_required_for_thread})) ->
    {ok, thread_resolution()} | {error, session_required_for_thread}.
with_thread_owner(SessionCtx, Fun) ->
    case {maps:get(session_ref, SessionCtx, undefined), maps:get(session_id, SessionCtx, undefined)} of
        {SessionRef, _} when is_pid(SessionRef) ->
            Fun(SessionRef);
        {undefined, SessionId} when is_binary(SessionId) ->
            Fun(SessionId);
        _ ->
            {error, session_required_for_thread}
    end.

%%--------------------------------------------------------------------
%% Internal: await/collect/status/cancel
%%--------------------------------------------------------------------

-spec await_loop(binary(), integer()) ->
    {ok, await_result()} | {error, timeout | not_found}.
await_loop(RunId, Deadline) ->
    case beam_agent_runs:get_run(RunId) of
        {ok, Run} ->
            case terminal_await_result(Run) of
                {ok, Result} ->
                    {ok, Result};
                continue ->
                    case erlang:monotonic_time(millisecond) >= Deadline of
                        true ->
                            {error, timeout};
                        false ->
                            Remaining = Deadline - erlang:monotonic_time(millisecond),
                            timer:sleep(min_poll(Remaining)),
                            await_loop(RunId, Deadline)
                    end
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-spec terminal_await_result(beam_agent_runs_core:run()) ->
    {ok, await_result()} | continue.
terminal_await_result(#{status := running}) ->
    continue;
terminal_await_result(#{status := Status} = Run) ->
    Base = #{
        status => Status,
        run => Run
    },
    {ok, maps:from_list(
        maps:to_list(Base) ++
        maybe_pair(output, maps:get(output, Run, undefined)) ++
        maybe_pair(error, maps:get(error, Run, undefined)) ++
        maybe_pair(cancel_reason, maps:get(cancel_reason, Run, undefined))
    )}.

-spec cancel_tree(binary(), term(), root | {child_of, binary()}) ->
    ok | {error, not_found | {invalid_status_transition,
        beam_agent_runs_core:run_status(), cancelled}}.
cancel_tree(RunId, Reason, Origin) ->
    case beam_agent_runs:get_run(RunId) of
        {ok, Run} ->
            {ok, Links} = beam_agent_orchestrator_store:list_children(RunId),
            case lists:foldl(fun(#{child_run_id := ChildRunId} = _Link, ok) ->
                cancel_tree(ChildRunId,
                    descendant_cancel_reason(RunId, Reason), {child_of, RunId});
                (_Link, {error, _} = Error) ->
                    Error
            end, ok, Links) of
                ok ->
                    cancel_single_run(Run, Reason, Origin);
                {error, _} = Error ->
                    Error
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-spec cancel_single_run(beam_agent_runs_core:run(), term(), cancel_origin()) ->
    ok | {error, not_found | {invalid_status_transition, cancelled | completed | failed,
        cancelled}}.
cancel_single_run(#{run_id := RunId, status := running}, Reason, Origin) ->
    case beam_agent_runs:cancel_run(RunId, Reason) of
        {ok, _Cancelled} ->
            case beam_agent_orchestrator_store:get_link(RunId) of
                {ok, #{parent_run_id := ParentRunId} = Link} ->
                    maybe_stop_link_session(Link),
                    ok = append_orchestrator_event(<<"orchestrator_cancelled">>, #{
                        child_run_id => RunId,
                        parent_run_id => ParentRunId,
                        origin => Origin,
                        reason => Reason
                    }),
                    ok = audit_orchestrator_event(cancelled, Link, allow,
                        undefined);
                {error, not_found} ->
                    ok
            end,
            ok;
        {error, _} = Error ->
            Error
    end;
cancel_single_run(_Run, _Reason, _Origin) ->
    ok.

%%--------------------------------------------------------------------
%% Internal: normalization
%%--------------------------------------------------------------------

-spec normalize_spawn_opts(map()) -> {ok, normalized_spawn_opts()} | {error,
    {unsupported_spawn_opt, atom()} | {invalid_spawn_opt, run_id | kind | metadata} |
    {invalid_session_target, session_target()} | {invalid_thread_target, thread_target()}}.
normalize_spawn_opts(Opts) when is_map(Opts) ->
    Allowed = [run_id, kind, input, metadata, session, thread],
    case validate_allowed_keys(Opts, Allowed, unsupported_spawn_opt) of
        ok ->
            case normalize_optional_run_id(Opts) of
                {ok, RunId} ->
                    case normalize_optional_kind(Opts) of
                        {ok, Kind} ->
                            case normalize_metadata(Opts) of
                                {ok, Metadata} ->
                                    case normalize_session_target(maps:get(session, Opts, inherit)) of
                                        {ok, Session} ->
                                            case normalize_thread_target(maps:get(thread, Opts,
                                                inherit)) of
                                                {ok, Thread} ->
                                                    Normalized0 = #{
                                                        metadata => Metadata,
                                                        session => Session,
                                                        thread => Thread
                                                    },
                                                    Normalized1 = maybe_put(kind, Kind,
                                                        Normalized0),
                                                    Normalized2 = maybe_put(run_id, RunId,
                                                        Normalized1),
                                                    {ok, maybe_put(input,
                                                        maps:get(input, Opts, undefined),
                                                        Normalized2)};
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

-spec normalize_session_target(term()) ->
    {ok, normalized_session_target()} | {error, {invalid_session_target, term()}}.
normalize_session_target(inherit) ->
    {ok, inherit};
normalize_session_target(none) ->
    {ok, none};
normalize_session_target(SessionId) when is_binary(SessionId), byte_size(SessionId) > 0 ->
    {ok, #{kind => session_id, id => SessionId}};
normalize_session_target(SessionRef) when is_pid(SessionRef) ->
    {ok, #{kind => live, ref => SessionRef, stop_session => false}};
normalize_session_target(#{kind := live, ref := SessionRef} = Target) when is_pid(SessionRef) ->
    {ok, #{
        kind => live,
        ref => SessionRef,
        stop_session => maps:get(stop_session, Target, false)
    }};
normalize_session_target(#{kind := session_id, id := SessionId})
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    {ok, #{kind => session_id, id => SessionId}};
normalize_session_target(#{kind := routed, opts := SessionOpts} = Target)
  when is_map(SessionOpts) ->
    {ok, #{
        kind => routed,
        opts => SessionOpts,
        stop_session => maps:get(stop_session, Target, true)
    }};
normalize_session_target(Target) ->
    {error, {invalid_session_target, Target}}.

-spec normalize_thread_target(term()) ->
    {ok, normalized_thread_target()} | {error, {invalid_thread_target, term()}}.
normalize_thread_target(inherit) ->
    {ok, inherit};
normalize_thread_target(none) ->
    {ok, none};
normalize_thread_target(ThreadId) when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
    {ok, #{kind => thread_id, id => ThreadId}};
normalize_thread_target(#{thread_id := ThreadId})
  when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
    {ok, #{kind => thread_id, id => ThreadId}};
normalize_thread_target(#{start := ThreadOpts}) when is_map(ThreadOpts) ->
    {ok, #{kind => start, opts => ThreadOpts}};
normalize_thread_target(Target) ->
    {error, {invalid_thread_target, Target}}.

-spec normalize_collect_opts(map()) ->
    {ok, normalized_collect_opts()} | {error, collect_error()}.
normalize_collect_opts(Opts) ->
    Allowed = [include_steps, include_journal, include_descendants],
    case validate_allowed_keys(Opts, Allowed, unsupported_collect_opt) of
        ok ->
            case normalize_optional_boolean(include_steps, Opts, true) of
                {ok, IncludeSteps} ->
                    case normalize_optional_boolean(include_journal, Opts, true) of
                        {ok, IncludeJournal} ->
                            case normalize_optional_boolean(include_descendants, Opts,
                                false) of
                                {ok, IncludeDescendants} ->
                                    {ok, #{
                                        include_steps => IncludeSteps,
                                        include_journal => IncludeJournal,
                                        include_descendants => IncludeDescendants
                                    }};
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

%%--------------------------------------------------------------------
%% Internal: parent/session helpers
%%--------------------------------------------------------------------

-spec resolve_parent_run(parent()) -> {ok, beam_agent_runs_core:run()} | {error, parent_not_found | {invalid_parent, parent()}}.
resolve_parent_run(ParentRunId) when is_binary(ParentRunId), byte_size(ParentRunId) > 0 ->
    case beam_agent_runs:get_run(ParentRunId) of
        {ok, Run} -> {ok, Run};
        {error, not_found} -> {error, parent_not_found}
    end;
resolve_parent_run(#{run_id := ParentRunId}) when is_binary(ParentRunId) ->
    resolve_parent_run(ParentRunId);
resolve_parent_run(Parent) ->
    {error, {invalid_parent, Parent}}.

-spec resolve_parent_run_id(parent()) -> {ok, binary()} | {error, parent_not_found |
    {invalid_parent, binary()}}.
resolve_parent_run_id(Parent) ->
    case resolve_parent_run(Parent) of
        {ok, #{run_id := RunId}} -> {ok, RunId};
        {error, _} = Error -> Error
    end.

-spec ensure_parent_running(beam_agent_runs_core:run()) ->
    ok | {error, {parent_not_running, beam_agent_runs_core:run_status()}}.
ensure_parent_running(#{status := running}) ->
    ok;
ensure_parent_running(#{status := Status}) ->
    {error, {parent_not_running, Status}}.

-spec build_run_scope(resolved_spawn_context()) -> run_scope_map().
build_run_scope(Ctx) ->
    Scope0 = #{},
    Scope1 = maybe_put(session_id, maps:get(session_id, Ctx, undefined), Scope0),
    maybe_put(thread_id, maps:get(thread_id, Ctx, undefined), Scope1).

-spec determine_substrate(resolved_spawn_context()) -> substrate().
determine_substrate(Ctx) ->
    SessionChanged = not maps:get(session_inherited, Ctx, false) andalso
        maps:is_key(session_id, Ctx),
    ThreadPresent = maps:is_key(thread_id, Ctx),
    ThreadChanged = ThreadPresent andalso
        ((not maps:get(thread_inherited, Ctx, false) andalso
            maps:get(thread_started, Ctx, false))
            orelse
            (not maps:get(thread_inherited, Ctx, false) andalso
                maps:is_key(thread, Ctx))),
    case {SessionChanged, ThreadPresent, ThreadChanged} of
        {true, true, _} -> session_thread;
        {true, false, _} -> session;
        {false, true, true} -> thread;
        _ -> run
    end.

-spec orchestrator_metadata(binary(), relation(), substrate(), map(), resolved_spawn_context()) ->
    orchestrator_meta().
orchestrator_metadata(ParentRunId, Relation, Substrate, Metadata, Ctx) ->
    Orchestrator = #{
        parent_run_id => ParentRunId,
        relation => Relation,
        substrate => Substrate
    },
    Orchestrator1 = maybe_put(child_session_id, maps:get(session_id, Ctx, undefined),
        Orchestrator),
    Orchestrator2 = maybe_put(child_thread_id, maps:get(thread_id, Ctx, undefined),
        Orchestrator1),
    Metadata#{orchestrator => Orchestrator2}.

-spec child_view(beam_agent_orchestrator_store:link_record()) -> child().
child_view(#{child_run_id := ChildRunId} = Link) ->
    case beam_agent_runs:get_run(ChildRunId) of
        {ok, Run} ->
            child_from_parts(Link, Run, undefined);
        {error, not_found} ->
            MissingRun = #{
                run_id => ChildRunId,
                kind => missing,
                status => cancelled,
                metadata => #{},
                created_at => maps:get(created_at, Link, 0),
                updated_at => maps:get(updated_at, Link, 0),
                cancel_reason => missing_run
            },
            child_from_parts(Link, MissingRun, undefined)
    end.

-spec child_from_parts(beam_agent_orchestrator_store:link_record(),
    beam_agent_runs_core:run(), map() | undefined) -> child().
child_from_parts(#{relation := Relation, substrate := Substrate,
                   parent_run_id := ParentRunId} = Link, Run, Thread) ->
    Base = #{
        relation => Relation,
        substrate => Substrate,
        parent_run_id => ParentRunId,
        run => Run,
        metadata => maps:get(metadata, Link, #{})
    },
    Base1 = maybe_put(task, maps:get(task, Link, undefined), Base),
    Base2 = maybe_put(session_id, maps:get(child_session_id, Link,
        maps:get(session_id, Run, undefined)), Base1),
    Base3 = maybe_put(thread_id, maps:get(child_thread_id, Link,
        maps:get(thread_id, Run, undefined)), Base2),
    Base4 = maybe_put(session_ref, maps:get(session_ref, Link, undefined), Base3),
    Base5 = maybe_put(owns_session, maps:get(owns_session, Link, undefined), Base4),
    Base6 = maybe_put(stop_session, maps:get(stop_session, Link, undefined), Base5),
    maybe_put(thread, Thread, Base6).

-spec child_status_active(child()) -> boolean().
child_status_active(#{run := #{status := running}}) ->
    true;
child_status_active(_) ->
    false.

-spec evaluate_orchestrator_policy(relation(), orchestrator_meta(),
    beam_agent_runs_core:run(), term() | undefined, run_scope_map(), resolved_spawn_context()) ->
    allow | {deny, binary()}.
evaluate_orchestrator_policy(Relation, Metadata, ParentRun, Task, RunScope, Ctx) ->
    ProfileId = maps:get(policy_profile_id, Metadata, undefined),
    beam_agent_policy_core:evaluate(ProfileId, orchestrator, #{
        relation => Relation,
        parent_run_id => maps:get(run_id, ParentRun),
        task => Task,
        metadata => Metadata,
        run_scope => RunScope,
        context => maps:without([session_ref], Ctx)
    }).

-spec audit_orchestrator_event(relation() | cancelled, child_link(),
    allow | deny, binary() | undefined) -> ok.
audit_orchestrator_event(Action, Link, Decision, Reason) ->
    Scope0 = #{},
    Scope1 = maybe_put(run_id, maps:get(child_run_id, Link, undefined), Scope0),
    Scope2 = maybe_put(session_id, maps:get(child_session_id, Link, undefined), Scope1),
    Scope3 = maybe_put(thread_id, maps:get(child_thread_id, Link, undefined), Scope2),
    Scope = maybe_put(profile_id,
        maps:get(policy_profile_id, maps:get(metadata, Link, #{}), undefined), Scope3),
    Details0 = #{
        decision => Decision,
        relation => maps:get(relation, Link, undefined),
        parent_run_id => maps:get(parent_run_id, Link, undefined),
        substrate => maps:get(substrate, Link, undefined)
    },
    Details1 = maybe_put(task, maps:get(task, Link, undefined), Details0),
    Details = maybe_put(reason, Reason, Details1),
    case beam_agent_audit_core:record(orchestrator, Action, Scope, Details) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

-spec list_descendants(binary()) -> [child()].
list_descendants(ParentRunId) ->
    lists:reverse(list_descendants_acc(ParentRunId, [])).

-spec list_descendants_acc(binary(), [child()]) -> [child()].
list_descendants_acc(ParentRunId, Acc0) ->
    case list_children(ParentRunId) of
        {ok, Children} ->
            lists:foldl(fun(#{run := #{run_id := ChildRunId}} = Child, Acc) ->
                list_descendants_acc(ChildRunId, [Child | Acc])
            end, Acc0, Children);
        {error, _} ->
            Acc0
    end.

-spec collect_journal([binary()]) -> [beam_agent_journal_core:entry()].
collect_journal(RunIds) ->
    Entries = lists:foldl(fun(RunId, Acc) ->
        case beam_agent_journal:list(#{run_id => RunId}) of
            {ok, RunEntries} -> lists:reverse(RunEntries, Acc);
            {error, _} -> Acc
        end
    end, [], lists:usort(RunIds)),
    lists:sort(fun(A, B) ->
        compare_sequence(maps:get(sequence, A, 0), maps:get(sequence, B, 0),
            maps:get(event_id, A), maps:get(event_id, B))
    end, Entries).

-spec step_counts([beam_agent_runs_core:step()]) -> {non_neg_integer(), non_neg_integer()}.
step_counts(Steps) ->
    {length([Step || Step <- Steps, maps:get(status, Step) =:= running]), length(Steps)}.

-spec child_counts([child()]) -> {non_neg_integer(), non_neg_integer()}.
child_counts(Children) ->
    {length([Child || Child <- Children, child_status_active(Child)]), length(Children)}.

-spec descendant_cancel_reason(binary(), term()) ->
    #{cancelled_by_parent := binary(), reason := term()}.
%% NOTE: reason is genuinely term() here since it wraps caller-provided cancel reasons
descendant_cancel_reason(ParentRunId, Reason) ->
    #{
        cancelled_by_parent => ParentRunId,
        reason => Reason
    }.

-spec maybe_stop_link_session(beam_agent_orchestrator_store:link_record()) -> ok.
maybe_stop_link_session(Link) ->
    case {maps:get(owns_session, Link, false), maps:get(stop_session, Link, false),
          maps:get(session_ref, Link, undefined)} of
        {true, true, SessionRef} when is_pid(SessionRef) ->
            _ = beam_agent:stop(SessionRef),
            ok;
        _ ->
            ok
    end.

-spec cleanup_spawn_context(spawn_context()) -> ok.
cleanup_spawn_context(Ctx) ->
    case {maps:get(owns_session, Ctx, false), maps:get(session_ref, Ctx, undefined)} of
        {true, SessionRef} when is_pid(SessionRef) ->
            _ = beam_agent:stop(SessionRef),
            ok;
        _ ->
            ok
    end.

-spec append_orchestrator_event(<<_:128, _:_*16>>, orchestrator_payload()) -> ok.
append_orchestrator_event(EventType, Payload0) ->
    Payload = maps:filter(fun(_Key, Value) -> Value =/= undefined end, Payload0),
    Event0 = #{
        tags => [orchestrator],
        payload => Payload
    },
    Event1 = maybe_put(run_id, maps:get(child_run_id, Payload, undefined), Event0),
    Event2 = maybe_put(session_id, maps:get(child_session_id, Payload, undefined), Event1),
    Event3 = maybe_put(thread_id, maps:get(child_thread_id, Payload, undefined), Event2),
    case beam_agent_journal:append(EventType, Event3) of
        {ok, _Entry} -> ok;
        {error, _} -> ok
    end.

-spec orchestrator_event(relation()) -> <<_:128, _:_*16>>.
orchestrator_event(spawned) ->
    <<"orchestrator_spawned">>;
orchestrator_event(delegated) ->
    <<"orchestrator_delegated">>.

-spec link_status_entries(child_link()) -> [{orchestrator_pair_key(), term()}].
link_status_entries(Link) ->
    maybe_pair(relation, maps:get(relation, Link, undefined)) ++
    maybe_pair(parent_run_id, maps:get(parent_run_id, Link, undefined)) ++
    maybe_pair(substrate, maps:get(substrate, Link, undefined)) ++
    maybe_pair(session_id, maps:get(child_session_id, Link, undefined)) ++
    maybe_pair(thread_id, maps:get(child_thread_id, Link, undefined)) ++
    maybe_pair(metadata, maps:get(metadata, Link, undefined)) ++
    maybe_pair(task, maps:get(task, Link, undefined)).

-spec default_kind(relation()) -> delegated_task | orchestrator_child.
default_kind(spawned) ->
    ?DEFAULT_KIND;
default_kind(delegated) ->
    delegated_task.

-spec min_poll(integer()) -> non_neg_integer().
min_poll(Remaining) when Remaining =< 0 ->
    0;
min_poll(Remaining) when Remaining < ?DEFAULT_AWAIT_POLL_MS ->
    Remaining;
min_poll(_Remaining) ->
    ?DEFAULT_AWAIT_POLL_MS.

-spec compare_sequence(integer(), integer(), binary(), binary()) -> boolean().
compare_sequence(Left, Right, _LeftId, _RightId) when Left < Right ->
    true;
compare_sequence(Left, Right, _LeftId, _RightId) when Left > Right ->
    false;
compare_sequence(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

-spec validate_allowed_keys(map(), [atom()], atom()) -> ok | {error, {atom(), atom()}}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case [Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [Unsupported | _] ->
            {error, {ErrorTag, Unsupported}}
    end.

-spec normalize_optional_run_id(map()) ->
    {ok, binary() | undefined} | {error, {invalid_spawn_opt, run_id}}.
normalize_optional_run_id(Opts) ->
    case maps:get(run_id, Opts, undefined) of
        undefined ->
            {ok, undefined};
        RunId when is_binary(RunId), byte_size(RunId) > 0 ->
            {ok, RunId};
        _ ->
            {error, {invalid_spawn_opt, run_id}}
    end.

-spec normalize_optional_kind(map()) ->
    {ok, atom() | binary() | undefined} | {error, {invalid_spawn_opt, kind}}.
normalize_optional_kind(Opts) ->
    case maps:get(kind, Opts, undefined) of
        undefined ->
            {ok, undefined};
        Kind when is_atom(Kind) ->
            {ok, Kind};
        Kind when is_binary(Kind), Kind =/= <<>> ->
            {ok, Kind};
        _ ->
            {error, {invalid_spawn_opt, kind}}
    end.

-spec normalize_metadata(map()) ->
    {ok, map()} | {error, {invalid_spawn_opt, metadata}}.
normalize_metadata(Opts) ->
    case maps:get(metadata, Opts, #{}) of
        Metadata when is_map(Metadata) ->
            {ok, Metadata};
        _ ->
            {error, {invalid_spawn_opt, metadata}}
    end.

-spec normalize_optional_boolean(orchestrator_optional_boolean_key(), map(), boolean()) ->
    {ok, boolean()} | {error, {invalid_collect_opt, orchestrator_optional_boolean_key()}}.
normalize_optional_boolean(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_boolean(Value) ->
            {ok, Value};
        _ ->
            {error, {invalid_collect_opt, Key}}
    end.

-spec maybe_put(atom(), term(), #{atom() => term()}) -> #{atom() => term()}.
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec maybe_pair(orchestrator_pair_key(), term()) -> [{orchestrator_pair_key(), term()}].
maybe_pair(_Key, undefined) ->
    [];
maybe_pair(Key, Value) ->
    [{Key, Value}].

-spec telemetry_start(orchestrator_operation(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry:span_start(orchestrator, Operation,
        compact_telemetry(Metadata)).

-spec telemetry_stop(orchestrator_operation(), integer(), map()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry:span_stop(orchestrator, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(orchestrator_operation(),
    {error, not_found | spawn_error() | collect_error()} | not_found | spawn_error() | collect_error(),
    map()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry:span_exception(orchestrator, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_finish(await | collect | delegate | spawn | status, integer(),
    {ok, map()} | {error, timeout | not_found | spawn_error() | collect_error()}, map()) -> ok.
telemetry_finish(Operation, StartTime, {ok, Result}, Metadata) when is_map(Result) ->
    telemetry_stop(Operation, StartTime, maps:merge(Metadata, telemetry_result_meta(Result)));
telemetry_finish(Operation, StartTime, {error, timeout}, Metadata) ->
    telemetry_stop(Operation, StartTime, Metadata#{timeout => true});
telemetry_finish(Operation, StartTime, {error, not_found}, Metadata) ->
    telemetry_stop(Operation, StartTime, Metadata#{found => false});
telemetry_finish(Operation, _StartTime, {error, Reason}, Metadata) ->
    telemetry_exception(Operation, Reason, Metadata).

-spec telemetry_parent_meta(parent()) -> map().
telemetry_parent_meta(#{run_id := RunId}) ->
    #{parent_run_id => RunId};
telemetry_parent_meta(RunId) when is_binary(RunId) ->
    #{parent_run_id => RunId};
telemetry_parent_meta(_Other) ->
    #{}.

-spec telemetry_spawn_meta(parent(), map()) -> map().
telemetry_spawn_meta(Parent, Opts) ->
    maps:merge(telemetry_parent_meta(Parent),
        maps:with([run_id, kind], Opts)).

-spec telemetry_result_meta(map()) -> map().
telemetry_result_meta(#{run := Run} = Result) when is_map(Run) ->
    Base = telemetry_run_meta(Run),
    Base1 = case maps:get(children, Result, undefined) of
        Children when is_list(Children) -> Base#{child_count => length(Children)};
        _ -> Base
    end,
    Base2 = case maps:get(descendants, Result, undefined) of
        Descendants when is_list(Descendants) ->
            Base1#{descendant_count => length(Descendants)};
        _ ->
            Base1
    end,
    case maps:get(steps, Result, undefined) of
        Steps when is_list(Steps) -> Base2#{step_count => length(Steps)};
        _ -> Base2
    end;
telemetry_result_meta(#{run_id := _} = Run) ->
    telemetry_run_meta(Run);
telemetry_result_meta(#{relation := _, run := Run} = Child) when is_map(Run) ->
    maps:merge(telemetry_run_meta(Run), maps:with([parent_run_id, substrate], Child));
telemetry_result_meta(#{status := Status, run := Run}) when is_map(Run) ->
    (telemetry_run_meta(Run))#{status => Status};
telemetry_result_meta(_Other) ->
    #{}.

-spec telemetry_run_meta(map()) -> map().
telemetry_run_meta(Run) ->
    maps:with([run_id, session_id, thread_id, kind, status], Run).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).
