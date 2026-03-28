defmodule BeamAgent.ToolCache do
  @moduledoc """
  Elixir facade for caching deterministic tool results.

  Caches the output of MCP tool calls marked as `cacheable` in their
  tool definition.  Eliminates redundant tool invocations during
  agentic loops where the same tool is called repeatedly with the
  same arguments.

  ## Quick Start

      args = %{"path" => "/etc/hostname"}
      key = BeamAgent.ToolCache.cache_key("read_file", args)

      case BeamAgent.ToolCache.get(key) do
        {:hit, result, _meta} ->
          result
        :miss ->
          result = call_tool(tool, args)
          BeamAgent.ToolCache.put(key, "read_file", result)
          result
      end

  ## Per-Tool Invalidation

      # File was modified — invalidate all read_file cache entries
      :ok = BeamAgent.ToolCache.invalidate_tool("read_file")
  """

  @typedoc "Opaque SHA-256 tool cache key (32 bytes)."
  @type tool_cache_key :: :beam_agent_tool_cache.tool_cache_key()

  @typedoc "Per-operation cache options."
  @type tool_cache_opts :: :beam_agent_tool_cache.tool_cache_opts()

  @typedoc "Aggregate tool cache statistics."
  @type tool_cache_stats :: :beam_agent_tool_cache.tool_cache_stats()

  @typedoc "Metadata returned alongside a tool cache hit."
  @type tool_hit_meta :: :beam_agent_tool_cache.tool_hit_meta()

  # Cache Key

  @doc "Compute a cache key from tool name and arguments."
  @spec cache_key(binary(), map()) :: tool_cache_key()
  defdelegate cache_key(tool_name, args), to: :beam_agent_tool_cache

  # Cache Operations

  @doc "Look up a cached tool result by key."
  @spec get(tool_cache_key()) ::
          {:hit, term(), tool_hit_meta()} | :miss
  defdelegate get(key), to: :beam_agent_tool_cache

  @doc "Store a tool result with default options."
  @spec put(tool_cache_key(), binary(), term()) :: :ok
  defdelegate put(key, tool_name, result), to: :beam_agent_tool_cache

  @doc "Store a tool result with explicit options."
  @spec put(tool_cache_key(), binary(), term(), tool_cache_opts()) :: :ok
  defdelegate put(key, tool_name, result, opts), to: :beam_agent_tool_cache

  @doc "Remove a specific cached result by key."
  @spec invalidate(tool_cache_key()) :: :ok
  defdelegate invalidate(key), to: :beam_agent_tool_cache

  @doc "Invalidate all cached results for a specific tool."
  @spec invalidate_tool(binary()) :: :ok
  defdelegate invalidate_tool(tool_name), to: :beam_agent_tool_cache

  # Maintenance

  @doc "Clear all cached tool results and reset statistics."
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_tool_cache

  @doc "Return aggregate tool cache statistics."
  @spec stats() :: tool_cache_stats()
  defdelegate stats(), to: :beam_agent_tool_cache

  @doc "Remove all expired entries. Returns count removed."
  @spec evict_expired() :: non_neg_integer()
  defdelegate evict_expired(), to: :beam_agent_tool_cache
end
