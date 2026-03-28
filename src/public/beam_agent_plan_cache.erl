-module(beam_agent_plan_cache).
-moduledoc """
Public API for agentic plan caching.

Caches structured plan templates (tool call sequences) so that
repeated agentic tasks can reuse a previously derived plan instead
of asking the LLM to re-derive it from scratch.

## Quick Start

```erlang
%% After the LLM produces a plan, cache it
Key = beam_agent_plan_cache:plan_key(claude, <<"opus-4">>,
    <<"Run tests and report coverage">>),
Plan = #{steps => [
    #{tool => <<"run_tests">>, description => <<"Execute test suite">>,
      order => 1},
    #{tool => <<"parse_coverage">>, description => <<"Extract coverage">>,
      order => 2}
], task_signature => <<"Run tests and report coverage">>,
   step_count => 2},
ok = beam_agent_plan_cache:put(Key, Plan),

%% Next time the same task is requested, check the cache
case beam_agent_plan_cache:get(Key) of
    {hit, CachedPlan, Meta} ->
        %% Reuse the plan — saves an LLM call
        execute_plan(CachedPlan),
        beam_agent_plan_cache:record_success(Key);
    miss ->
        %% Derive a new plan from the LLM
        NewPlan = derive_plan_from_llm(Task),
        beam_agent_plan_cache:put(Key, NewPlan)
end.
```

## Quality Tracking

Plans track success and failure counts.  After executing a cached
plan, call `record_success/1` or `record_failure/1` to update the
quality signal.  Plans with low success rates can be purged via
`evict_low_quality/1`.

## Context-Aware Keys

Plan keys include an optional context parameter (typically the
session's working directory) to differentiate identical tasks in
different environments.
""".

-export([
    %% Plan key
    plan_key/3,
    plan_key/4,
    %% Cache operations
    get/1,
    put/2,
    put/3,
    invalidate/1,
    %% Quality tracking
    record_success/1,
    record_failure/1,
    %% Maintenance
    clear/0,
    stats/0,
    evict_expired/0,
    evict_low_quality/1
]).

-export_type([
    plan_key/0,
    plan_step/0,
    plan_template/0,
    plan_cache_opts/0,
    plan_hit_meta/0,
    plan_stats/0
]).

%%--------------------------------------------------------------------
%% Types (re-exported from core)
%%--------------------------------------------------------------------

-type plan_key() :: beam_agent_plan_cache_core:plan_key().
-type plan_step() :: beam_agent_plan_cache_core:plan_step().
-type plan_template() :: beam_agent_plan_cache_core:plan_template().
-type plan_cache_opts() :: beam_agent_plan_cache_core:plan_cache_opts().
-type plan_hit_meta() :: beam_agent_plan_cache_core:plan_hit_meta().
-type plan_stats() :: beam_agent_plan_cache_core:plan_stats().

%%--------------------------------------------------------------------
%% Plan Key
%%--------------------------------------------------------------------

-doc "Compute a plan cache key from backend, model, and task description.".
-spec plan_key(atom() | binary(), binary(), binary()) -> plan_key().
plan_key(Backend, Model, TaskDescription) ->
    beam_agent_plan_cache_core:plan_key(Backend, Model, TaskDescription).

-doc "Compute a plan cache key with an explicit context scope.".
-spec plan_key(atom() | binary(), binary(), binary(), binary()) -> plan_key().
plan_key(Backend, Model, TaskDescription, Context) ->
    beam_agent_plan_cache_core:plan_key(
        Backend, Model, TaskDescription, Context).

%%--------------------------------------------------------------------
%% Cache Operations
%%--------------------------------------------------------------------

-doc """
Look up a cached plan by key.

Returns `{hit, PlanTemplate, Meta}` with quality metrics, or `miss`.
""".
-spec get(plan_key()) ->
    {hit, plan_template(), plan_hit_meta()} | miss.
get(Key) ->
    beam_agent_plan_cache_core:get(Key).

-doc "Store a plan template with default options.".
-spec put(plan_key(), plan_template()) -> ok.
put(Key, Template) ->
    put(Key, Template, #{}).

-doc """
Store a plan template with explicit options.

Options:
  - `ttl` — time-to-live in ms (default 1 800 000 / 30 min)
  - `max_entries` — eviction threshold (default 500)
""".
-spec put(plan_key(), plan_template(), plan_cache_opts()) -> ok.
put(Key, Template, Opts) ->
    beam_agent_plan_cache_core:put(Key, Template, Opts).

-doc "Remove a specific plan from the cache.".
-spec invalidate(plan_key()) -> ok.
invalidate(Key) ->
    beam_agent_plan_cache_core:invalidate(Key).

%%--------------------------------------------------------------------
%% Quality Tracking
%%--------------------------------------------------------------------

-doc "Record a successful execution of a cached plan.".
-spec record_success(plan_key()) -> ok.
record_success(Key) ->
    beam_agent_plan_cache_core:record_success(Key).

-doc "Record a failed execution of a cached plan.".
-spec record_failure(plan_key()) -> ok.
record_failure(Key) ->
    beam_agent_plan_cache_core:record_failure(Key).

%%--------------------------------------------------------------------
%% Maintenance
%%--------------------------------------------------------------------

-doc "Clear all cached plans and reset statistics.".
-spec clear() -> ok.
clear() ->
    beam_agent_plan_cache_core:clear().

-doc "Return aggregate plan cache statistics.".
-spec stats() -> plan_stats().
stats() ->
    beam_agent_plan_cache_core:stats().

-doc "Remove all expired plan entries. Returns count removed.".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    beam_agent_plan_cache_core:evict_expired().

-doc """
Remove plans whose success rate is below the threshold.

Only evaluates plans executed at least once.  Returns count removed.
""".
-spec evict_low_quality(float()) -> non_neg_integer().
evict_low_quality(MinSuccessRate) ->
    beam_agent_plan_cache_core:evict_low_quality(MinSuccessRate).
