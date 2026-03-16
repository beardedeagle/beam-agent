-module(beam_agent_runs).
-moduledoc """
Public API for canonical BeamAgent runs and steps.

This module provides durable units of work that live above transient task
processes. A run represents a single orchestrated unit of work and can be
linked to a session, a thread, and a parent run. A step represents a
sub-unit of work within a run and inherits its parent run's session/thread
scope.

Runs and steps are stored in ETS through the universal layer, so they are
available across all supported agentic coder backends without adapter-
specific logic. This makes them suitable for orchestration, audit trails,
future artifacts/journal linking, and higher-level products such as
MonkeyClaw.

## Getting Started

```erlang
%% Start a run scoped to a session and thread:
{ok, Run} = beam_agent_runs:start_run(#{
    session_id => <<"sess_001">>,
    thread_id => <<"thread_abc">>
}, #{
    kind => workflow,
    input => #{goal => <<"Ship the feature">>}
}),

%% Start and finish a step:
{ok, Step} = beam_agent_runs:start_step(maps:get(run_id, Run), #{
    kind => review
}),
{ok, _CompletedStep} = beam_agent_runs:complete_step(
    maps:get(run_id, Run),
    maps:get(step_id, Step),
    #{status => ok}
),

%% Finish the run once all steps are terminal:
{ok, _CompletedRun} = beam_agent_runs:complete_run(
    maps:get(run_id, Run),
    #{summary => <<"Done">>}
).
```

## Key Concepts

- Run scope: a run can carry `session_id`, `thread_id`, and `parent_run_id`.
  Child runs inherit scope from their parent unless the caller supplies the
  same explicit values.

- Step inheritance: steps automatically inherit the parent run's
  `session_id` and `thread_id`. They are always keyed by `{run_id, step_id}`.

- Terminal safety: runs cannot complete while they still have active steps.
  Failing or cancelling a run cascades terminal state to active steps so no
  run is left with dangling work.

## Architecture

This module is a thin public wrapper over `beam_agent_runs_core`. The core
module performs validation and lifecycle transitions while
`beam_agent_runs_store` owns the ETS tables:

- `beam_agent_run_records`
- `beam_agent_run_steps`

Writes go through `beam_agent_ets`, so hardened table mode works without
changing the public API.
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

-doc "Run scope passed to `start_run/2`.".
-type scope() :: beam_agent_runs_core:scope().

-doc "Run lifecycle status.".
-type run_status() :: beam_agent_runs_core:run_status().

-doc "Step lifecycle status.".
-type step_status() :: beam_agent_runs_core:step_status().

-doc "Options for `start_run/2`.".
-type run_opts() :: beam_agent_runs_core:run_opts().

-doc "Options for `start_step/2`.".
-type step_opts() :: beam_agent_runs_core:step_opts().

-doc "Filter map accepted by `list_runs/1`.".
-type run_filter() :: beam_agent_runs_core:run_filter().

-doc "Run record returned by the public API.".
-type run() :: beam_agent_runs_core:run().

-doc "Step record returned by the public API.".
-type step() :: beam_agent_runs_core:step().

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the runs ETS tables exist.

Creates the underlying run and step tables on demand. This call is
idempotent and safe to make from any process.
""".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_runs_core:ensure_tables().

-doc """
Clear all run and step data.

This is a destructive reset intended for tests or full in-memory store
resets.
""".
-spec clear() -> ok.
clear() ->
    beam_agent_runs_core:clear().

%%--------------------------------------------------------------------
%% Run Lifecycle
%%--------------------------------------------------------------------

-doc """
Start a run with the given scope and options.

Scope may be a binary session id or a map containing `session_id`,
`thread_id`, and/or `parent_run_id`.

Returns `{ok, Run}` on success or `{error, Reason}` if the scope or
options are invalid, the parent run cannot be found, or the run id is
already in use.
""".
-spec start_run(scope(), run_opts()) ->
    {ok, run()} | {error, term()}.
start_run(Scope, Opts) ->
    beam_agent_runs_core:start_run(Scope, Opts).

-doc """
Get a run by id.

Returns `{ok, Run}` or `{error, not_found}`.
""".
-spec get_run(binary()) -> {ok, run()} | {error, not_found}.
get_run(RunId) ->
    beam_agent_runs_core:get_run(RunId).

-doc "List all runs without filters.".
-spec list_runs() -> {ok, [run()]}.
list_runs() ->
    beam_agent_runs_core:list_runs().

-doc """
List runs with exact-match filters.

Supported filters are `session_id`, `thread_id`, `parent_run_id`, `kind`,
`status`, `since`, and `limit`.
""".
-spec list_runs(run_filter()) -> {ok, [run()]} | {error, term()}.
list_runs(Filter) ->
    beam_agent_runs_core:list_runs(Filter).

-doc """
Complete a run once all of its steps are already terminal.

Returns `{error, active_steps}` if the run still has running steps.
""".
-spec complete_run(binary(), term()) -> {ok, run()} | {error, term()}.
complete_run(RunId, Result) ->
    beam_agent_runs_core:complete_run(RunId, Result).

-doc "Fail a run and cascade failure to active steps.".
-spec fail_run(binary(), term()) -> {ok, run()} | {error, term()}.
fail_run(RunId, ErrorTerm) ->
    beam_agent_runs_core:fail_run(RunId, ErrorTerm).

-doc "Cancel a run and cascade cancellation to active steps.".
-spec cancel_run(binary(), term()) -> {ok, run()} | {error, term()}.
cancel_run(RunId, Reason) ->
    beam_agent_runs_core:cancel_run(RunId, Reason).

%%--------------------------------------------------------------------
%% Step Lifecycle
%%--------------------------------------------------------------------

-doc """
Start a step within a run.

The step inherits the run's session/thread scope. Steps can only be
started while the parent run is still active.
""".
-spec start_step(binary(), step_opts()) -> {ok, step()} | {error, term()}.
start_step(RunId, Opts) ->
    beam_agent_runs_core:start_step(RunId, Opts).

-doc "Get a step by run id and step id.".
-spec get_step(binary(), binary()) -> {ok, step()} | {error, not_found}.
get_step(RunId, StepId) ->
    beam_agent_runs_core:get_step(RunId, StepId).

-doc "List the steps for a run, oldest first.".
-spec list_steps(binary()) -> {ok, [step()]} | {error, not_found}.
list_steps(RunId) ->
    beam_agent_runs_core:list_steps(RunId).

-doc "Complete a running step.".
-spec complete_step(binary(), binary(), term()) -> {ok, step()} | {error, term()}.
complete_step(RunId, StepId, Result) ->
    beam_agent_runs_core:complete_step(RunId, StepId, Result).

-doc "Fail a running step.".
-spec fail_step(binary(), binary(), term()) -> {ok, step()} | {error, term()}.
fail_step(RunId, StepId, ErrorTerm) ->
    beam_agent_runs_core:fail_step(RunId, StepId, ErrorTerm).

-doc "Cancel a running step.".
-spec cancel_step(binary(), binary(), term()) -> {ok, step()} | {error, term()}.
cancel_step(RunId, StepId, Reason) ->
    beam_agent_runs_core:cancel_step(RunId, StepId, Reason).
