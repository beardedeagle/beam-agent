-module(beam_agent_plan_cache_core).
-moduledoc """
ETS-backed cache for agentic plan templates.

Caches structured plan templates (sequences of tool calls) so that
repeated tasks can skip the LLM plan-derivation step and reuse a
previously successful plan.  Inspired by the NeurIPS 2025 finding
that caching agentic plans can reduce cost by 50%% and latency by
27%%.

Process-free.  No resident processes, no background eviction.
ETS-backed cache with TTL expiry, quality tracking, and
caller-driven cleanup.

## Quality Tracking

Each cached plan tracks success and failure counts.  Plans with low
success rates can be evicted via `evict_low_quality/1`, allowing the
system to self-heal by discarding plans that don't work in practice.

## When to Use

  - Multi-step agentic workflows where the LLM derives a tool call
    sequence from a task description.
  - Repeated tasks (CI pipelines, scheduled analyses, batch operations)
    where the same plan structure applies across runs.

## When NOT to Use

  - One-off tasks that won't repeat.
  - Tasks where the plan must vary based on dynamic context that
    changes between runs.
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Plan key
    plan_key/3,
    plan_key/4,
    %% Cache operations
    get/1,
    put/3,
    invalidate/1,
    evict_expired/0,
    evict_low_quality/1,
    %% Quality tracking
    record_success/1,
    record_failure/1,
    %% Stats
    stats/0
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
%% Types
%%--------------------------------------------------------------------

%% Opaque SHA-256 hash identifying a cached plan.
-type plan_key() :: <<_:256>>.

%% A single step in an agentic plan.
-type plan_step() :: #{
    tool := binary(),
    description := binary(),
    args_template => map(),
    order := non_neg_integer()
}.

%% A cached plan template — the sequence of tool calls.
-type plan_template() :: #{
    steps := [plan_step()],
    task_signature := binary(),
    step_count := non_neg_integer()
}.

%% Per-operation options for `put/3`.
-type plan_cache_opts() :: #{
    ttl => pos_integer(),          %% TTL in ms, default 1 800 000 (30 min)
    max_entries => pos_integer()   %% Eviction threshold, default 500
}.

%% Metadata returned alongside a cache hit.
-type plan_hit_meta() :: #{
    inserted_at := integer(),
    expires_at := integer(),
    byte_estimate := non_neg_integer(),
    age_ms := non_neg_integer(),
    success_count := non_neg_integer(),
    failure_count := non_neg_integer(),
    success_rate := float()
}.

%% Aggregate plan cache statistics.
-type plan_stats() :: #{
    hits := non_neg_integer(),
    misses := non_neg_integer(),
    entries := non_neg_integer(),
    bytes_estimate := non_neg_integer()
}.

%%--------------------------------------------------------------------
%% ETS Tables
%%--------------------------------------------------------------------

%% Entry: {Key, PlanTemplate, InsertedAt, ExpiresAt, ByteEstimate,
%%          SuccessCount, FailureCount}
-define(CACHE_TABLE, beam_agent_plan_cache).
-define(STATS_TABLE, beam_agent_plan_cache_stats).

-define(DEFAULT_TTL, 1_800_000).       %% 30 minutes
-define(DEFAULT_MAX_ENTRIES, 500).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the plan cache ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?CACHE_TABLE,
        [set, named_table, {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?STATS_TABLE,
        [set, named_table, {write_concurrency, true}]),
    ok.

-doc "Clear all cached plans and reset statistics.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?CACHE_TABLE),
    beam_agent_ets:delete_all_objects(?STATS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Plan Key
%%--------------------------------------------------------------------

-doc "Compute a plan cache key from backend, model, and task description.".
-spec plan_key(atom() | binary(), binary(), binary()) -> plan_key().
plan_key(Backend, Model, TaskDescription) ->
    plan_key(Backend, Model, TaskDescription, <<>>).

-doc """
Compute a plan cache key from backend, model, task description, and context.

The key is a SHA-256 hash.  The task description is normalized
(whitespace trimmed, Unicode NFC) before hashing.
""".
-spec plan_key(atom() | binary(), binary(), binary(), binary()) -> plan_key().
plan_key(Backend, Model, TaskDescription, Context)
  when is_binary(Model), is_binary(TaskDescription), is_binary(Context) ->
    BackendBin = normalize_backend(Backend),
    NormTask = normalize_text(TaskDescription),
    crypto:hash(sha256, term_to_binary({BackendBin, Model, NormTask, Context})).

%%--------------------------------------------------------------------
%% Cache Operations
%%--------------------------------------------------------------------

-doc """
Look up a cached plan by key.

Returns `{hit, PlanTemplate, Meta}` if a valid (non-expired) entry
exists, or `miss` otherwise.  Expired entries are removed lazily.
""".
-spec get(plan_key()) -> {hit, plan_template(), plan_hit_meta()} | miss.
get(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    case beam_agent_ets:lookup(?CACHE_TABLE, Key) of
        [{Key, Template, InsertedAt, ExpiresAt, Bytes, SC, FC}]
          when ExpiresAt > Now ->
            bump_hit(),
            Rate = case SC + FC of
                0 -> 1.0;
                Total -> SC / Total
            end,
            {hit, Template, #{
                inserted_at => InsertedAt,
                expires_at => ExpiresAt,
                byte_estimate => Bytes,
                age_ms => Now - InsertedAt,
                success_count => SC,
                failure_count => FC,
                success_rate => Rate
            }};
        [{Key, _Template, _IA, _EA, _B, _SC, _FC}] ->
            %% Expired — lazy removal
            beam_agent_ets:delete(?CACHE_TABLE, Key),
            bump_miss(),
            miss;
        [] ->
            bump_miss(),
            miss
    end.

-doc """
Store a plan template in the cache.

Options:
  - `ttl` — time-to-live in milliseconds (default 1 800 000 / 30 min)
  - `max_entries` — eviction threshold (default 500)
""".
-spec put(plan_key(), plan_template(), plan_cache_opts()) -> ok.
put(Key, Template, Opts)
  when is_binary(Key), byte_size(Key) =:= 32,
       is_map(Template), is_map(Opts) ->
    ensure_tables(),
    TTL = maps:get(ttl, Opts, ?DEFAULT_TTL),
    MaxEntries = maps:get(max_entries, Opts, ?DEFAULT_MAX_ENTRIES),
    Now = erlang:system_time(millisecond),
    ExpiresAt = Now + TTL,
    Bytes = erlang:external_size(Template),
    Entry = {Key, Template, Now, ExpiresAt, Bytes, 0, 0},
    maybe_evict(MaxEntries),
    beam_agent_ets:insert(?CACHE_TABLE, Entry),
    ok.

-doc "Remove a specific plan from the cache.".
-spec invalidate(plan_key()) -> ok.
invalidate(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    beam_agent_ets:delete(?CACHE_TABLE, Key),
    ok.

%%--------------------------------------------------------------------
%% Quality Tracking
%%--------------------------------------------------------------------

-doc """
Record a successful plan execution.

Atomically increments the success counter for the plan.
""".
-spec record_success(plan_key()) -> ok.
record_success(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    try
        _ = beam_agent_ets:update_counter(?CACHE_TABLE, Key, {6, 1}),
        ok
    catch
        error:badarg -> ok  %% Key not in cache
    end.

-doc """
Record a failed plan execution.

Atomically increments the failure counter for the plan.
""".
-spec record_failure(plan_key()) -> ok.
record_failure(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    ensure_tables(),
    try
        _ = beam_agent_ets:update_counter(?CACHE_TABLE, Key, {7, 1}),
        ok
    catch
        error:badarg -> ok  %% Key not in cache
    end.

%%--------------------------------------------------------------------
%% Eviction
%%--------------------------------------------------------------------

-doc """
Remove all expired plan entries.  Returns the count removed.
""".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Expired = beam_agent_ets:foldl(fun
        ({Key, _T, _IA, ExpiresAt, _B, _SC, _FC}, Acc)
          when ExpiresAt =< Now ->
            [Key | Acc];
        (_Entry, Acc) ->
            Acc
    end, [], ?CACHE_TABLE),
    lists:foreach(fun(Key) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, Expired),
    length(Expired).

-doc """
Remove plans whose success rate is below the given threshold.

Only evaluates plans that have been executed at least once
(success + failure > 0).  Returns the count of plans removed.

Example: `evict_low_quality(0.5)` removes plans with < 50%% success.
""".
-spec evict_low_quality(float()) -> non_neg_integer().
evict_low_quality(MinSuccessRate)
  when is_float(MinSuccessRate), MinSuccessRate >= 0.0,
       MinSuccessRate =< 1.0 ->
    ensure_tables(),
    LowQuality = beam_agent_ets:foldl(fun
        ({Key, _T, _IA, _EA, _B, SC, FC}, Acc)
          when SC + FC > 0 ->
            Rate = SC / (SC + FC),
            case Rate < MinSuccessRate of
                true -> [Key | Acc];
                false -> Acc
            end;
        (_Entry, Acc) ->
            Acc
    end, [], ?CACHE_TABLE),
    lists:foreach(fun(Key) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, LowQuality),
    length(LowQuality).

%%--------------------------------------------------------------------
%% Stats
%%--------------------------------------------------------------------

-doc "Return aggregate plan cache statistics.".
-spec stats() -> plan_stats().
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

-spec normalize_backend(atom() | binary()) -> binary().
normalize_backend(Backend) when is_atom(Backend) ->
    atom_to_binary(Backend, utf8);
normalize_backend(Backend) when is_binary(Backend) ->
    Backend.

%% Trim whitespace and normalize to NFC — same semantics as
%% beam_agent_prompt_cache_core:normalize_prompt/1 but decoupled
%% to avoid cross-module dependency.
-spec normalize_text(binary()) -> binary().
normalize_text(Text) when is_binary(Text) ->
    Trimmed = string:trim(Text),
    unicode:characters_to_nfc_binary(Trimmed).

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
        ({_Key, _T, _IA, _EA, Bytes, _SC, _FC}, {Count, Total}) ->
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
        ({Key, _T, InsertedAt, _EA, _B, _SC, _FC}, Acc) ->
            [{InsertedAt, Key} | Acc]
    end, [], ?CACHE_TABLE),
    Sorted = lists:sort(Entries),
    ToDelete = lists:sublist(Sorted, Count),
    lists:foreach(fun({_IA, Key}) ->
        beam_agent_ets:delete(?CACHE_TABLE, Key)
    end, ToDelete),
    ok.
