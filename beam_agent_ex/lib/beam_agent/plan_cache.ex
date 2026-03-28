defmodule BeamAgent.PlanCache do
  @moduledoc """
  Elixir facade for agentic plan caching.

  Caches structured plan templates (tool call sequences) so that
  repeated agentic tasks can reuse a previously derived plan instead
  of asking the LLM to re-derive it from scratch.

  ## Quick Start

      key = BeamAgent.PlanCache.plan_key(:claude, "opus-4",
        "Run tests and report coverage")

      plan = %{
        steps: [
          %{tool: "run_tests", description: "Execute test suite", order: 1},
          %{tool: "parse_coverage", description: "Extract coverage", order: 2}
        ],
        task_signature: "Run tests and report coverage",
        step_count: 2
      }

      :ok = BeamAgent.PlanCache.put(key, plan)

      # Next time — check the cache first
      case BeamAgent.PlanCache.get(key) do
        {:hit, cached_plan, _meta} ->
          execute_plan(cached_plan)
          BeamAgent.PlanCache.record_success(key)
        :miss ->
          new_plan = derive_plan_from_llm(task)
          BeamAgent.PlanCache.put(key, new_plan)
      end

  ## Quality Tracking

  Plans track success and failure counts.  After executing a cached
  plan, call `record_success/1` or `record_failure/1`.  Plans with
  low success rates can be purged via `evict_low_quality/1`.
  """

  @typedoc "Opaque SHA-256 plan cache key (32 bytes)."
  @type plan_key :: :beam_agent_plan_cache.plan_key()

  @typedoc "A single step in an agentic plan."
  @type plan_step :: :beam_agent_plan_cache.plan_step()

  @typedoc "A cached plan template (sequence of tool call steps)."
  @type plan_template :: :beam_agent_plan_cache.plan_template()

  @typedoc "Per-operation cache options."
  @type plan_cache_opts :: :beam_agent_plan_cache.plan_cache_opts()

  @typedoc "Metadata returned alongside a plan cache hit."
  @type plan_hit_meta :: :beam_agent_plan_cache.plan_hit_meta()

  @typedoc "Aggregate plan cache statistics."
  @type plan_stats :: :beam_agent_plan_cache.plan_stats()

  # Plan Key

  @doc "Compute a plan cache key from backend, model, and task description."
  @spec plan_key(atom() | binary(), binary(), binary()) :: plan_key()
  defdelegate plan_key(backend, model, task_description),
    to: :beam_agent_plan_cache

  @doc "Compute a plan cache key with an explicit context scope."
  @spec plan_key(atom() | binary(), binary(), binary(), binary()) :: plan_key()
  defdelegate plan_key(backend, model, task_description, context),
    to: :beam_agent_plan_cache

  # Cache Operations

  @doc "Look up a cached plan by key."
  @spec get(plan_key()) ::
          {:hit, plan_template(), plan_hit_meta()} | :miss
  defdelegate get(key), to: :beam_agent_plan_cache

  @doc "Store a plan template with default options."
  @spec put(plan_key(), plan_template()) :: :ok
  defdelegate put(key, template), to: :beam_agent_plan_cache

  @doc "Store a plan template with explicit options."
  @spec put(plan_key(), plan_template(), plan_cache_opts()) :: :ok
  defdelegate put(key, template, opts), to: :beam_agent_plan_cache

  @doc "Remove a specific plan from the cache."
  @spec invalidate(plan_key()) :: :ok
  defdelegate invalidate(key), to: :beam_agent_plan_cache

  # Quality Tracking

  @doc "Record a successful execution of a cached plan."
  @spec record_success(plan_key()) :: :ok
  defdelegate record_success(key), to: :beam_agent_plan_cache

  @doc "Record a failed execution of a cached plan."
  @spec record_failure(plan_key()) :: :ok
  defdelegate record_failure(key), to: :beam_agent_plan_cache

  # Maintenance

  @doc "Clear all cached plans and reset statistics."
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_plan_cache

  @doc "Return aggregate plan cache statistics."
  @spec stats() :: plan_stats()
  defdelegate stats(), to: :beam_agent_plan_cache

  @doc "Remove all expired plan entries. Returns count removed."
  @spec evict_expired() :: non_neg_integer()
  defdelegate evict_expired(), to: :beam_agent_plan_cache

  @doc "Remove plans with success rate below threshold. Returns count removed."
  @spec evict_low_quality(float()) :: non_neg_integer()
  defdelegate evict_low_quality(min_success_rate), to: :beam_agent_plan_cache
end
