-module(beam_agent_prompt_cache_core).
-moduledoc """
SDK-layer prompt cache for BeamAgent.

Provides hash-based deduplication of prompt responses at the SDK layer.
Process-free module — no resident processes, no background eviction.
ETS-backed cache with TTL-based expiry and caller-driven cleanup.

beam-agent talks to CLIs, not HTTP APIs — there is no transport-level
caching.  This module fills the gap by caching prompt/response pairs
keyed on `{Backend, Model, Prompt, Context}` so identical queries
avoid redundant CLI roundtrips.

Prompts are normalized before hashing (whitespace trimming, Unicode
NFC normalization) to maximise cache hit rates across cosmetically
different but semantically identical inputs.

For the public API that integrates with beam_agent session queries,
see `beam_agent_prompt_cache`.
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Cache key
    cache_key/3,
    cache_key/4,
    %% Prompt normalization
    normalize_prompt/1,
    %% Cache operations
    get/1,
    put/3,
    invalidate/1,
    evict_expired/0,
    %% Stats
    stats/0
]).

-export_type([
    cache_key/0,
    cache_opts/0,
    cache_stats/0,
    cache_hit_meta/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Opaque SHA-256 hash identifying a cached prompt.
-type cache_key() :: <<_:256>>.

%% Per-operation options for `put/3`.
-type cache_opts() :: #{
    ttl => pos_integer(),         %% TTL in milliseconds, default 300 000 (5 min)
    max_entries => pos_integer()  %% Max cache entries, default 1000
}.

%% Metadata returned alongside a cache hit.
-type cache_hit_meta() :: #{
    inserted_at := integer(),
    expires_at := integer(),
    byte_estimate := non_neg_integer(),
    age_ms := non_neg_integer()
}.

%% Aggregate cache statistics.
-type cache_stats() :: #{
    hits := non_neg_integer(),
    misses := non_neg_integer(),
    entries := non_neg_integer(),
    bytes_estimate := non_neg_integer()
}.

-define(CACHE_TABLE, beam_agent_prompt_cache).
-define(STATS_TABLE, beam_agent_prompt_cache_stats).

-define(DEFAULT_TTL, 300_000).       %% 5 minutes
-define(DEFAULT_MAX_ENTRIES, 1000).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the cache ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?CACHE_TABLE,
        [set, named_table, {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?STATS_TABLE,
        [set, named_table, {write_concurrency, true}]),
    ok.

-doc "Clear all cached data and reset statistics.".
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
Compute a deterministic cache key from backend, model, and prompt.

Convenience wrapper for `cache_key/4` with an empty context.
""".
-spec cache_key(atom() | binary(), binary(), binary()) -> cache_key().
cache_key(Backend, Model, Prompt) ->
    cache_key(Backend, Model, Prompt, <<>>).

-doc """
Compute a deterministic cache key from backend, model, prompt, and context.

The key is a SHA-256 hash of `{BackendBin, Model, NormalizedPrompt, Context}`.
The prompt is normalized (whitespace trimmed, Unicode NFC) before hashing
so that cosmetically different but equivalent inputs produce the same key.

`Context` is an opaque binary that callers use to scope the key — typically
the session's working directory or a caller-supplied scope tag.  An empty
binary means "no additional context".
""".
-spec cache_key(atom() | binary(), binary(), binary(), binary()) -> cache_key().
cache_key(Backend, Model, Prompt, Context)
  when is_binary(Model), is_binary(Prompt), is_binary(Context) ->
    BackendBin = normalize_backend(Backend),
    NormPrompt = normalize_prompt(Prompt),
    crypto:hash(sha256, term_to_binary({BackendBin, Model, NormPrompt, Context})).

-doc """
Normalize a prompt for cache key computation.

Trims leading/trailing whitespace and normalizes to Unicode NFC form.
Exported so callers can pre-normalize for inspection or testing.
""".
-spec normalize_prompt(binary()) -> binary().
normalize_prompt(Prompt) when is_binary(Prompt) ->
    Trimmed = string:trim(Prompt),
    unicode:characters_to_nfc_binary(Trimmed).

%%--------------------------------------------------------------------
%% Cache Operations
%%--------------------------------------------------------------------

-doc """
Look up a cached result by key.

Returns `{hit, Result, Metadata}` if a valid (non-expired) entry exists,
or `miss` if no entry exists or the entry has expired.  Expired entries
are removed lazily on lookup.
""".
-spec get(cache_key()) -> {hit, term(), cache_hit_meta()} | miss.
get(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    case beam_agent_ets:lookup(?CACHE_TABLE, Key) of
        [{Key, Result, InsertedAt, ExpiresAt, ByteEstimate}]
          when ExpiresAt > Now ->
            bump_hit(),
            {hit, Result, #{
                inserted_at => InsertedAt,
                expires_at => ExpiresAt,
                byte_estimate => ByteEstimate,
                age_ms => Now - InsertedAt
            }};
        [{Key, _Result, _InsertedAt, _ExpiresAt, _ByteEstimate}] ->
            %% Expired — remove lazily and report miss
            beam_agent_ets:delete(?CACHE_TABLE, Key),
            bump_miss(),
            miss;
        [] ->
            bump_miss(),
            miss
    end.

-doc """
Store a result in the cache under the given key.

Options:

  - `ttl` — time-to-live in milliseconds (default 300 000 / 5 minutes)
  - `max_entries` — eviction trigger threshold (default 1000)

When the cache exceeds `max_entries`, expired entries are evicted
first.  If still over capacity the oldest 10%% of entries are removed.
""".
-spec put(cache_key(), term(), cache_opts()) -> ok.
put(Key, Result, Opts)
  when is_binary(Key), byte_size(Key) =:= 32, is_map(Opts) ->
    ensure_tables(),
    TTL = maps:get(ttl, Opts, ?DEFAULT_TTL),
    MaxEntries = maps:get(max_entries, Opts, ?DEFAULT_MAX_ENTRIES),
    Now = erlang:system_time(millisecond),
    ExpiresAt = Now + TTL,
    ByteEstimate = erlang:external_size(Result),
    Entry = {Key, Result, Now, ExpiresAt, ByteEstimate},
    maybe_evict(MaxEntries),
    beam_agent_ets:insert(?CACHE_TABLE, Entry),
    ok.

-doc "Remove a specific entry from the cache by key.".
-spec invalidate(cache_key()) -> ok.
invalidate(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    beam_agent_ets:delete(?CACHE_TABLE, Key),
    ok.

-doc """
Remove all expired entries from the cache.

This is a caller-driven operation — no background process runs
eviction automatically.  Call this periodically or before cache
operations when freshness matters.

Returns the number of entries removed.
""".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Expired = beam_agent_ets:foldl(fun
        ({Key, _Result, _InsertedAt, ExpiresAt, _Bytes}, Acc)
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

-doc "Return aggregate cache statistics.".
-spec stats() -> cache_stats().
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

-doc "Atomically increment the hit counter.".
-spec bump_hit() -> ok.
bump_hit() ->
    _ = beam_agent_ets:update_counter(
        ?STATS_TABLE, hits, {2, 1}, {hits, 0}),
    ok.

-doc "Atomically increment the miss counter.".
-spec bump_miss() -> ok.
bump_miss() ->
    _ = beam_agent_ets:update_counter(
        ?STATS_TABLE, misses, {2, 1}, {misses, 0}),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec normalize_backend(atom() | binary()) -> binary().
normalize_backend(Backend) when is_atom(Backend) ->
    atom_to_binary(Backend, utf8);
normalize_backend(Backend) when is_binary(Backend) ->
    Backend.

-spec read_counter(atom()) -> non_neg_integer().
read_counter(Name) ->
    case beam_agent_ets:lookup(?STATS_TABLE, Name) of
        [{_, Value}] -> Value;
        [] -> 0
    end.

-spec fold_size() -> {non_neg_integer(), non_neg_integer()}.
fold_size() ->
    beam_agent_ets:foldl(fun
        ({_Key, _Result, _InsertedAt, _ExpiresAt, ByteEstimate},
         {Count, Bytes}) ->
            {Count + 1, Bytes + ByteEstimate}
    end, {0, 0}, ?CACHE_TABLE).

%% Benign race: concurrent callers may both pass the size check and
%% each evict, temporarily over-removing entries.  The cache self-heals
%% on the next put.  Adding serialization would violate the process-free
%% design.
-spec maybe_evict(pos_integer()) -> ok.
maybe_evict(MaxEntries) ->
    Size = beam_agent_ets:info(?CACHE_TABLE, size),
    case is_integer(Size) andalso Size >= MaxEntries of
        false ->
            ok;
        true ->
            %% First try evicting expired entries
            _ = evict_expired(),
            SizeAfter = beam_agent_ets:info(?CACHE_TABLE, size),
            case is_integer(SizeAfter) andalso SizeAfter >= MaxEntries of
                false ->
                    ok;
                true ->
                    %% Evict oldest 10% by InsertedAt
                    evict_oldest(max(1, MaxEntries div 10))
            end
    end.

-spec evict_oldest(pos_integer()) -> ok.
evict_oldest(Count) ->
    Entries = beam_agent_ets:foldl(fun
        ({Key, _Result, InsertedAt, _ExpiresAt, _Bytes}, Acc) ->
            [{InsertedAt, Key} | Acc]
    end, [], ?CACHE_TABLE),
    Sorted = lists:sort(Entries),
    ToDelete = lists:sublist(Sorted, Count),
    lists:foreach(fun({_InsertedAt, Key}) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, ToDelete),
    ok.
