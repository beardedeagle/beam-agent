-module(beam_agent_tool_cache_core).
-moduledoc """
ETS-backed cache for deterministic tool results.

Caches the output of MCP tool calls whose results are deterministic
(file reads, directory listings, symbol searches, etc.).  Tool authors
mark tools as `cacheable` in the tool definition; this module handles
the storage, retrieval, and eviction of cached results.

Process-free.  No resident processes, no background eviction.
ETS-backed cache with TTL expiry, per-tool invalidation, and
caller-driven cleanup.

## When to Use

  - Tools whose output is determined entirely by their input arguments
    and the current filesystem/environment state.
  - High-frequency tool calls during agentic loops (e.g. repeated
    file reads of the same path).

## When NOT to Use

  - Tools with side effects (writes, network calls, mutations).
  - Tools whose output depends on external state that changes between
    calls (real-time data, user interaction state).

## Per-Tool Invalidation

When the environment changes (file modified, branch switched, etc.),
call `invalidate_tool/1` to clear all cached results for a specific
tool.  This is coarse-grained but safe — the cache rebuilds
transparently on the next call.
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Cache key
    cache_key/2,
    %% Cache operations
    get/1,
    put/4,
    invalidate/1,
    invalidate_tool/1,
    evict_expired/0,
    %% Stats
    stats/0
]).

-export_type([
    tool_cache_key/0,
    tool_cache_opts/0,
    tool_cache_stats/0,
    tool_hit_meta/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Opaque SHA-256 hash identifying a cached tool result.
-type tool_cache_key() :: <<_:256>>.

%% Per-operation options for `put/4`.
-type tool_cache_opts() :: #{
    ttl => pos_integer(),          %% TTL in ms, default 120 000 (2 min)
    max_entries => pos_integer()   %% Eviction threshold, default 2000
}.

%% Metadata returned alongside a cache hit.
-type tool_hit_meta() :: #{
    tool_name := binary(),
    inserted_at := integer(),
    expires_at := integer(),
    byte_estimate := non_neg_integer(),
    age_ms := non_neg_integer()
}.

%% Aggregate tool cache statistics.
-type tool_cache_stats() :: #{
    hits := non_neg_integer(),
    misses := non_neg_integer(),
    entries := non_neg_integer(),
    bytes_estimate := non_neg_integer()
}.

%%--------------------------------------------------------------------
%% ETS Tables
%%--------------------------------------------------------------------

%% Entry: {Key, ToolName, Result, InsertedAt, ExpiresAt, ByteEstimate}
-define(CACHE_TABLE, beam_agent_tool_cache).
-define(STATS_TABLE, beam_agent_tool_cache_stats).

-define(DEFAULT_TTL, 120_000).        %% 2 minutes
-define(DEFAULT_MAX_ENTRIES, 2000).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the tool cache ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?CACHE_TABLE,
        [set, named_table, {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?STATS_TABLE,
        [set, named_table, {write_concurrency, true}]),
    ok.

-doc "Clear all cached tool results and reset statistics.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?CACHE_TABLE),
    beam_agent_ets:delete_all_objects(?STATS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Cache Key
%%--------------------------------------------------------------------

-doc """
Compute a deterministic cache key from tool name and arguments.

Arguments are sorted by key before hashing to ensure determinism
regardless of map iteration order.
""".
-spec cache_key(binary(), map()) -> tool_cache_key().
cache_key(ToolName, Args) when is_binary(ToolName), is_map(Args) ->
    SortedArgs = lists:sort(maps:to_list(Args)),
    crypto:hash(sha256, term_to_binary({ToolName, SortedArgs})).

%%--------------------------------------------------------------------
%% Cache Operations
%%--------------------------------------------------------------------

-doc """
Look up a cached tool result by key.

Returns `{hit, Result, Meta}` if a valid (non-expired) entry exists,
or `miss` otherwise.  Expired entries are removed lazily.
""".
-spec get(tool_cache_key()) ->
    {hit, term(), tool_hit_meta()} | miss.
get(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    case beam_agent_ets:lookup(?CACHE_TABLE, Key) of
        [{Key, ToolName, Result, InsertedAt, ExpiresAt, Bytes}]
          when ExpiresAt > Now ->
            bump_hit(),
            {hit, Result, #{
                tool_name => ToolName,
                inserted_at => InsertedAt,
                expires_at => ExpiresAt,
                byte_estimate => Bytes,
                age_ms => Now - InsertedAt
            }};
        [{Key, _TN, _R, _IA, _EA, _B}] ->
            %% Expired — lazy removal
            beam_agent_ets:delete(?CACHE_TABLE, Key),
            bump_miss(),
            miss;
        [] ->
            bump_miss(),
            miss
    end.

-doc """
Store a tool result in the cache.

The `ToolName` is stored alongside the result for per-tool
invalidation via `invalidate_tool/1`.

Options:
  - `ttl` — time-to-live in ms (default 120 000 / 2 min)
  - `max_entries` — eviction threshold (default 2000)
""".
-spec put(tool_cache_key(), binary(), term(), tool_cache_opts()) -> ok.
put(Key, ToolName, Result, Opts)
  when is_binary(Key), byte_size(Key) =:= 32,
       is_binary(ToolName), is_map(Opts) ->
    ensure_tables(),
    TTL = maps:get(ttl, Opts, ?DEFAULT_TTL),
    MaxEntries = maps:get(max_entries, Opts, ?DEFAULT_MAX_ENTRIES),
    Now = erlang:system_time(millisecond),
    ExpiresAt = Now + TTL,
    Bytes = erlang:external_size(Result),
    Entry = {Key, ToolName, Result, Now, ExpiresAt, Bytes},
    maybe_evict(MaxEntries),
    beam_agent_ets:insert(?CACHE_TABLE, Entry),
    ok.

-doc "Remove a specific cached result by key.".
-spec invalidate(tool_cache_key()) -> ok.
invalidate(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    beam_agent_ets:delete(?CACHE_TABLE, Key),
    ok.

-doc """
Invalidate all cached results for a specific tool.

Removes every entry whose tool name matches, regardless of
arguments.  Use this when the environment changes in a way that
affects all results for the tool (e.g. file modified for a
file-reading tool).
""".
-spec invalidate_tool(binary()) -> ok.
invalidate_tool(ToolName) when is_binary(ToolName) ->
    ensure_tables(),
    beam_agent_ets:match_delete(?CACHE_TABLE,
        {'_', ToolName, '_', '_', '_', '_'}),
    ok.

%%--------------------------------------------------------------------
%% Eviction
%%--------------------------------------------------------------------

-doc "Remove all expired tool cache entries. Returns count removed.".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Expired = beam_agent_ets:foldl(fun
        ({Key, _TN, _R, _IA, ExpiresAt, _B}, Acc)
          when ExpiresAt =< Now ->
            [Key | Acc];
        (_Entry, Acc) ->
            Acc
    end, [], ?CACHE_TABLE),
    lists:foreach(fun(Key) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, Expired),
    length(Expired).

%%--------------------------------------------------------------------
%% Stats
%%--------------------------------------------------------------------

-doc "Return aggregate tool cache statistics.".
-spec stats() -> tool_cache_stats().
stats() ->
    ensure_tables(),
    Hits = read_counter(hits),
    Misses = read_counter(misses),
    {Entries, BytesEstimate} = fold_size(),
    #{
        hits => Hits,
        misses => Misses,
        entries => Entries,
        bytes_estimate => BytesEstimate
    }.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec bump_hit() -> ok.
bump_hit() ->
    _ = beam_agent_ets:update_counter(
        ?STATS_TABLE, hits, {2, 1}, {hits, 0}),
    ok.

-spec bump_miss() -> ok.
bump_miss() ->
    _ = beam_agent_ets:update_counter(
        ?STATS_TABLE, misses, {2, 1}, {misses, 0}),
    ok.

-spec read_counter(atom()) -> non_neg_integer().
read_counter(Name) ->
    case beam_agent_ets:lookup(?STATS_TABLE, Name) of
        [{_, Value}] -> Value;
        [] -> 0
    end.

-spec fold_size() -> {non_neg_integer(), non_neg_integer()}.
fold_size() ->
    beam_agent_ets:foldl(fun
        ({_Key, _TN, _R, _IA, _EA, Bytes}, {Count, Total}) ->
            {Count + 1, Total + Bytes}
    end, {0, 0}, ?CACHE_TABLE).

-spec maybe_evict(pos_integer()) -> ok.
maybe_evict(MaxEntries) ->
    Size = beam_agent_ets:info(?CACHE_TABLE, size),
    case is_integer(Size) andalso Size >= MaxEntries of
        false ->
            ok;
        true ->
            _ = evict_expired(),
            SizeAfter = beam_agent_ets:info(?CACHE_TABLE, size),
            case is_integer(SizeAfter) andalso SizeAfter >= MaxEntries of
                false ->
                    ok;
                true ->
                    evict_oldest(max(1, MaxEntries div 10))
            end
    end.

-spec evict_oldest(pos_integer()) -> ok.
evict_oldest(Count) ->
    Entries = beam_agent_ets:foldl(fun
        ({Key, _TN, _R, InsertedAt, _EA, _B}, Acc) ->
            [{InsertedAt, Key} | Acc]
    end, [], ?CACHE_TABLE),
    Sorted = lists:sort(Entries),
    ToDelete = lists:sublist(Sorted, Count),
    lists:foreach(fun({_IA, Key}) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, ToDelete),
    ok.
