-module(beam_agent_tool_cache).
-moduledoc """
Public API for caching deterministic tool results.

Caches the output of MCP tool calls marked as `cacheable` in their
tool definition.  Eliminates redundant tool invocations during
agentic loops where the same tool is called repeatedly with the
same arguments.

## Quick Start

```erlang
%% Define a cacheable tool
Tool = beam_agent_tool_registry:tool(
    <<"read_file">>, <<"Read file contents">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"path">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Path = maps:get(<<"path">>, Input),
        {ok, Content} = file:read_file(Path),
        {ok, [#{type => text, text => Content}]}
    end),
CacheableTool = Tool#{cacheable => true, cache_ttl => 60000},

%% Use cached_call instead of direct handler invocation
Args = #{<<"path">> => <<"/etc/hostname">>},
Key = beam_agent_tool_cache:cache_key(<<"read_file">>, Args),
case beam_agent_tool_cache:get(Key) of
    {hit, Result, _Meta} ->
        Result;
    miss ->
        Result = call_tool(Tool, Args),
        beam_agent_tool_cache:put(Key, <<"read_file">>, Result),
        Result
end.
```

## Per-Tool Invalidation

When the environment changes, invalidate all cached results for
affected tools:

```erlang
%% File was modified — invalidate the read_file cache
ok = beam_agent_tool_cache:invalidate_tool(<<"read_file">>).
```
""".

-export([
    %% Cache key
    cache_key/2,
    %% Cache operations
    get/1,
    put/3,
    put/4,
    invalidate/1,
    invalidate_tool/1,
    %% Maintenance
    clear/0,
    stats/0,
    evict_expired/0
]).

-export_type([
    tool_cache_key/0,
    tool_cache_opts/0,
    tool_cache_stats/0,
    tool_hit_meta/0
]).

%%--------------------------------------------------------------------
%% Types (re-exported from core)
%%--------------------------------------------------------------------

-type tool_cache_key() :: beam_agent_tool_cache_core:tool_cache_key().
-type tool_cache_opts() :: beam_agent_tool_cache_core:tool_cache_opts().
-type tool_cache_stats() :: beam_agent_tool_cache_core:tool_cache_stats().
-type tool_hit_meta() :: beam_agent_tool_cache_core:tool_hit_meta().

%%--------------------------------------------------------------------
%% Cache Key
%%--------------------------------------------------------------------

-doc """
Compute a cache key from tool name and arguments.

Arguments are sorted by key for deterministic hashing.
""".
-spec cache_key(binary(), map()) -> tool_cache_key().
cache_key(ToolName, Args) ->
    beam_agent_tool_cache_core:cache_key(ToolName, Args).

%%--------------------------------------------------------------------
%% Cache Operations
%%--------------------------------------------------------------------

-doc """
Look up a cached tool result by key.

Returns `{hit, Result, Meta}` or `miss`.
""".
-spec get(tool_cache_key()) ->
    {hit, term(), tool_hit_meta()} | miss.
get(Key) ->
    beam_agent_tool_cache_core:get(Key).

-doc "Store a tool result with default options.".
-spec put(tool_cache_key(), binary(), term()) -> ok.
put(Key, ToolName, Result) ->
    put(Key, ToolName, Result, #{}).

-doc """
Store a tool result with explicit options.

Options:
  - `ttl` — time-to-live in ms (default 120 000 / 2 min)
  - `max_entries` — eviction threshold (default 2000)
""".
-spec put(tool_cache_key(), binary(), term(), tool_cache_opts()) -> ok.
put(Key, ToolName, Result, Opts) ->
    beam_agent_tool_cache_core:put(Key, ToolName, Result, Opts).

-doc "Remove a specific cached result by key.".
-spec invalidate(tool_cache_key()) -> ok.
invalidate(Key) ->
    beam_agent_tool_cache_core:invalidate(Key).

-doc """
Invalidate all cached results for a specific tool.

Removes every entry whose tool name matches, regardless of
the arguments used.
""".
-spec invalidate_tool(binary()) -> ok.
invalidate_tool(ToolName) ->
    beam_agent_tool_cache_core:invalidate_tool(ToolName).

%%--------------------------------------------------------------------
%% Maintenance
%%--------------------------------------------------------------------

-doc "Clear all cached tool results and reset statistics.".
-spec clear() -> ok.
clear() ->
    beam_agent_tool_cache_core:clear().

-doc "Return aggregate tool cache statistics.".
-spec stats() -> tool_cache_stats().
stats() ->
    beam_agent_tool_cache_core:stats().

-doc "Remove all expired entries. Returns count removed.".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    beam_agent_tool_cache_core:evict_expired().
