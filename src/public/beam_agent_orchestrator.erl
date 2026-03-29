-module(beam_agent_orchestrator).
-moduledoc """
Public API for canonical BeamAgent orchestration primitives.

`beam_agent_orchestrator` models parent-child execution relationships on top of
canonical runs, sessions, threads, and the durable journal. It intentionally
does not start a worker pool or scheduler process. Callers invoke these
functions from processes they already own.

Child runs remain the durable source of execution truth. The orchestrator layer
adds explicit cross-session lineage so a parent run can delegate or spawn work
without weakening the existing same-scope constraints inside `beam_agent_runs`.

Use this module when you need to:

  - record parent-child delegation lineage across sessions or threads
  - await terminal run state from caller-owned control flow
  - collect a durable execution picture that includes descendants and journal
    records
  - cancel a run tree without creating a resident orchestration service
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

-type parent() :: beam_agent_orchestrator_core:parent().
-type relation() :: beam_agent_orchestrator_core:relation().
-type substrate() :: beam_agent_orchestrator_core:substrate().
-type session_target() :: beam_agent_orchestrator_core:session_target().
-type thread_target() :: beam_agent_orchestrator_core:thread_target().
-type spawn_opts() :: beam_agent_orchestrator_core:spawn_opts().
-type child() :: beam_agent_orchestrator_core:child().
-type child_status() :: beam_agent_orchestrator_core:child_status().
-type collect_opts() :: beam_agent_orchestrator_core:collect_opts().
-type collect_result() :: beam_agent_orchestrator_core:collect_result().
-type await_result() :: beam_agent_orchestrator_core:await_result().

-doc "Ensure the orchestrator ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_orchestrator_core:ensure_tables().

-doc "Clear all orchestrator lineage state. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_orchestrator_core:clear().

-doc """
Create a child orchestration record, optionally opening a child session or
thread substrate.
""".
-spec spawn(parent(), spawn_opts()) -> {ok, child()} | {error, term()}.
spawn(Parent, Opts) ->
    beam_agent_orchestrator_core:spawn(Parent, Opts).

-doc """
Create a delegated child run under a parent run.

The delegated child is recorded immediately as a canonical run plus explicit
lineage metadata. BeamAgent does not start a worker process for it.
""".
-spec delegate(parent(), term(), map()) ->
    {ok, beam_agent_runs:run()} | {error, term()}.
delegate(Parent, Task, Opts) ->
    beam_agent_orchestrator_core:delegate(Parent, Task, Opts).

-doc "Wait for a run to reach a terminal state by polling the canonical run store.".
-spec await(binary(), non_neg_integer()) ->
    {ok, await_result()} | {error, timeout | not_found | {invalid_timeout, term()}}.
await(RunId, Timeout) ->
    beam_agent_orchestrator_core:await(RunId, Timeout).

-doc """
Collect the canonical orchestration view for a run.

Supported opts:
  - `include_steps`
  - `include_journal`
  - `include_descendants`
""".
-spec collect(binary(), collect_opts()) ->
    {ok, collect_result()} | {error, term()}.
collect(RunId, Opts) ->
    beam_agent_orchestrator_core:collect(RunId, Opts).

-doc "Cancel a run and any active orchestrated descendants.".
-spec cancel(binary(), term()) -> ok | {error, not_found}.
cancel(RunId, Reason) ->
    beam_agent_orchestrator_core:cancel(RunId, Reason).

-doc "Return a summary status map for a run and its direct children.".
-spec status(binary()) -> {ok, child_status()} | {error, not_found}.
status(RunId) ->
    beam_agent_orchestrator_core:status(RunId).

-doc "List direct orchestrator children for a parent run, oldest first.".
-spec list_children(parent()) -> {ok, [child()]} | {error, term()}.
list_children(Parent) ->
    beam_agent_orchestrator_core:list_children(Parent).
