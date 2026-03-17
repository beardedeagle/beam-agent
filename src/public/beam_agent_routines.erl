-module(beam_agent_routines).
-moduledoc """
Public API for canonical BeamAgent routines and scheduled execution.

Routines are durable scheduled jobs stored in the canonical BeamAgent store.
They intentionally do not own a scheduler process. Instead, BeamAgent exposes
CRUD plus explicit runner entrypoints so consumers can drive due work from an
existing process they already own.

Supported schedules in this slice:

- one-shot jobs (`type => once`)
- interval jobs (`type => interval`)

Supported targets in this slice:

- `run` for canonical run creation without backend execution
- `query` for live-session or routed-session prompt execution

The runner records routine executions as canonical runs plus journal entries.
This keeps scheduled work aligned with the rest of the BeamAgent substrate.
""".

-export([
    ensure_tables/0,
    clear/0,
    create/1,
    update/2,
    cancel/1,
    run_now/1,
    run_due/0,
    run_due/1,
    get/1,
    list/0,
    list/1,
    due/0,
    due/1,
    list_due/0,
    list_due/1,
    next_due_at/0
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

-type schedule() :: beam_agent_routines_core:schedule().
-type retry_policy() :: beam_agent_routines_core:retry_policy().
-type session_target() :: beam_agent_routines_core:session_target().
-type thread_target() :: beam_agent_routines_core:thread_target().
-type target() :: beam_agent_routines_core:target().
-type job_input() :: beam_agent_routines_core:job_input().
-type job_patch() :: beam_agent_routines_core:job_patch().
-type job_record() :: beam_agent_routines_core:job_record().
-type job_filter() :: beam_agent_routines_core:job_filter().
-type due_filter() :: beam_agent_routines_core:due_filter().

-doc "Ensure the routines ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_routines_core:ensure_tables().

-doc "Clear all routines state. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_routines_core:clear().

-doc "Create a routine job.".
-spec create(job_input()) -> {ok, job_record()} | {error, term()}.
create(Job) ->
    beam_agent_routines_core:create(Job).

-doc "Update a routine job.".
-spec update(binary(), job_patch()) -> {ok, job_record()} | {error, term()}.
update(JobId, Patch) ->
    beam_agent_routines_core:update(JobId, Patch).

-doc "Cancel a routine job and any active canonical run tied to it.".
-spec cancel(binary()) -> ok | {error, not_found}.
cancel(JobId) ->
    beam_agent_routines_core:cancel(JobId).

-doc "Execute a routine job immediately without changing its normal cadence.".
-spec run_now(binary()) -> {ok, beam_agent_runs:run()} | {error, term()}.
run_now(JobId) ->
    beam_agent_routine_runner:run_now(JobId).

-doc "Execute all currently due jobs with default runner options.".
-spec run_due() -> {ok, [map()]} | {error, term()}.
run_due() ->
    beam_agent_routine_runner:run_due().

-doc "Execute currently due jobs from the calling process.".
-spec run_due(map()) -> {ok, [map()]} | {error, term()}.
run_due(Opts) ->
    beam_agent_routine_runner:run_due(Opts).

-doc "Fetch a routine job by id.".
-spec get(binary()) -> {ok, job_record()} | {error, not_found}.
get(JobId) ->
    beam_agent_routines_core:get(JobId).

-doc "List all routine jobs without filters.".
-spec list() -> {ok, [job_record()]}.
list() ->
    beam_agent_routines_core:list().

-doc "List routine jobs using exact-match filters.".
-spec list(job_filter()) -> {ok, [job_record()]} | {error, term()}.
list(Filter) ->
    beam_agent_routines_core:list(Filter).

-doc "List jobs that are currently due as of now.".
-spec due() -> {ok, [job_record()]}.
due() ->
    list_due().

-doc "List jobs that are currently due using an explicit due filter.".
-spec due(due_filter()) -> {ok, [job_record()]} | {error, term()}.
due(Filter) ->
    list_due(Filter).

-doc "List jobs that are currently due as of now.".
-spec list_due() -> {ok, [job_record()]}.
list_due() ->
    beam_agent_routines_core:list_due().

-doc "List jobs that are due as of the supplied due filter.".
-spec list_due(due_filter()) -> {ok, [job_record()]} | {error, term()}.
list_due(Filter) ->
    beam_agent_routines_core:list_due(Filter).

-doc "Return the earliest next-run timestamp in the routines due index.".
-spec next_due_at() -> {ok, integer()} | {error, none}.
next_due_at() ->
    beam_agent_routines_core:next_due_at().
