defmodule BeamAgent.PromptCache do
  @moduledoc """
  Elixir facade for SDK-layer prompt caching.

  beam-agent talks to CLIs, not HTTP APIs — there is no transport-level
  cache.  This module fills the gap with hash-based deduplication:
  identical stateless queries to the same backend and model return a
  cached response instead of making a redundant CLI roundtrip.

  Caching is explicit and opt-in.  Use `cached_query/2,3` in place of
  `BeamAgent.query/2,3` when you want deduplication.

  Process-free.  No background eviction.  Caller-driven cleanup via
  `evict_expired/0`.

  ## When to use

    - Stateless / one-shot queries where the same prompt + model always
      yields an equivalent response.
    - Retry scenarios where a timed-out query may already have a cached
      response from a parallel or previous attempt.
    - Burst deduplication when multiple callers send the same prompt
      within a short window.

  ## When NOT to use

    - Conversational queries where session history affects the response.
      The cache keys by `{backend, model, prompt}` only — session state
      is NOT part of the key.

  ## Security

  Cache keys are derived from `{backend, model, prompt}` only.  Session
  identity and caller identity are NOT part of the key.  If multiple
  callers share a BEAM node, any caller sending an identical prompt to the
  same backend and model receives the same cached response.  Do NOT use
  this module when prompts contain user-identifying data, access tokens,
  or session-scoped context.  Use `BeamAgent.query/2,3` directly in
  those cases.

  ## Example

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, msgs1} = BeamAgent.PromptCache.cached_query(session, "What is OTP?")
      {:ok, msgs2} = BeamAgent.PromptCache.cached_query(session, "What is OTP?")
      msgs1 == msgs2   # true — second call was a cache hit
  """

  @typedoc "Opaque SHA-256 cache key (32 bytes)."
  @type cache_key :: :beam_agent_prompt_cache.cache_key()

  @typedoc "Per-operation cache options."
  @type cache_opts :: :beam_agent_prompt_cache.cache_opts()

  @typedoc "Aggregate cache statistics."
  @type cache_stats :: :beam_agent_prompt_cache.cache_stats()

  @typedoc "Metadata returned alongside a cache hit."
  @type cache_hit_meta :: :beam_agent_prompt_cache.cache_hit_meta()

  @doc """
  Query with transparent caching.

  On a cache hit, returns the stored result without contacting the
  backend CLI.  On a miss, dispatches the query and caches the response.
  """
  @spec cached_query(pid(), binary()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate cached_query(session, prompt), to: :beam_agent_prompt_cache

  @doc """
  Query with transparent caching and explicit options.

  Accepts all standard query options plus:
    - `cache_ttl` — TTL in milliseconds (default 300 000)
    - `cache_key` — caller-supplied key override
    - `cache_max_entries` — eviction threshold (default 1000)
  """
  @spec cached_query(pid(), binary(), map()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate cached_query(session, prompt, opts), to: :beam_agent_prompt_cache

  @doc "Check cache without querying the backend."
  @spec lookup(pid(), binary()) :: {:hit, [map()], cache_hit_meta()} | :miss
  defdelegate lookup(session, prompt), to: :beam_agent_prompt_cache

  @doc "Lookup with explicit options."
  @spec lookup(pid(), binary(), map()) ::
          {:hit, [map()], cache_hit_meta()} | :miss
  defdelegate lookup(session, prompt, opts), to: :beam_agent_prompt_cache

  @doc "Manually store a result in the cache."
  @spec store(pid(), binary(), [map()], map()) :: :ok
  defdelegate store(session, prompt, messages, opts), to: :beam_agent_prompt_cache

  @doc "Invalidate the cached result for a session and prompt."
  @spec invalidate(pid(), binary()) :: :ok
  defdelegate invalidate(session, prompt), to: :beam_agent_prompt_cache

  @doc "Invalidate with explicit options."
  @spec invalidate(pid(), binary(), map()) :: :ok
  defdelegate invalidate(session, prompt, opts), to: :beam_agent_prompt_cache

  @doc "Clear all cached entries and reset statistics."
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_prompt_cache

  @doc "Return aggregate cache statistics."
  @spec stats() :: cache_stats()
  defdelegate stats(), to: :beam_agent_prompt_cache

  @doc "Remove all expired entries. Returns the count removed."
  @spec evict_expired() :: non_neg_integer()
  defdelegate evict_expired(), to: :beam_agent_prompt_cache
end
