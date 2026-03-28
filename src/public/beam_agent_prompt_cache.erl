-module(beam_agent_prompt_cache).
-moduledoc """
Public API for SDK-layer prompt caching.

beam-agent talks to CLIs, not HTTP APIs — there is no transport-level
cache.  This module fills the gap with hash-based deduplication:
identical stateless queries to the same backend and model return a
cached response instead of making a redundant CLI roundtrip.

Caching is explicit and opt-in.  Use `cached_query/2,3` in place of
`beam_agent:query/2,3` when you want deduplication.  The module never
intercepts queries automatically; callers decide when caching is
appropriate.

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
    The cache keys by `{backend, model, prompt, context}` — session
    history or other dynamic state is NOT automatically part of the key
    unless you encode it into the prompt or cache context yourself.

## Security

Cache keys are derived from `{backend, model, prompt, context}`.  By
default, `cache_context` is `auto`, which uses the session's working
directory as the context (via `resolve_session_cwd/1`).  Calls from
different working directories will not share cache entries, but callers
in the same directory on the same BEAM node can.  Session identity and
caller identity are NOT part of the key.  If multiple callers share a
BEAM node and an effective context, any caller sending an identical
prompt to the same backend and model receives the same cached response.
Do NOT use this module when prompts or cache contexts contain
user-identifying data, access tokens, or session-scoped context.  Use
`beam_agent:query/2,3` directly in those cases.

## Example

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
%% First call queries the CLI:
{ok, Msgs1} = beam_agent_prompt_cache:cached_query(Session, <<\"What is OTP?\">>),
%% Second call returns cached result instantly:
{ok, Msgs2} = beam_agent_prompt_cache:cached_query(Session, <<\"What is OTP?\">>),
Msgs1 =:= Msgs2.   %% true
```
""".

-export([
    cached_query/2,
    cached_query/3,
    lookup/2,
    lookup/3,
    store/4,
    invalidate/2,
    invalidate/3,
    clear/0,
    stats/0,
    evict_expired/0
]).

-export_type([
    cache_key/0,
    cache_opts/0,
    cache_stats/0,
    cache_hit_meta/0
]).

%%--------------------------------------------------------------------
%% Types (re-exported from core)
%%--------------------------------------------------------------------

-type cache_key() :: beam_agent_prompt_cache_core:cache_key().
-type cache_opts() :: beam_agent_prompt_cache_core:cache_opts().
-type cache_stats() :: beam_agent_prompt_cache_core:cache_stats().
-type cache_hit_meta() :: beam_agent_prompt_cache_core:cache_hit_meta().

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc """
Query with transparent caching.

Computes a cache key from the session's backend, the effective model,
and the prompt.  On a cache hit the stored result is returned without
contacting the backend CLI.  On a miss the query is dispatched
normally via `beam_agent:query/2` and the response is cached.
""".
-spec cached_query(pid(), binary()) ->
    {ok, [beam_agent:message()]} | {error, term()}.
cached_query(Session, Prompt) ->
    cached_query(Session, Prompt, #{}).

-doc """
Query with transparent caching and explicit options.

Accepts all standard `beam_agent:query/3` options plus:

  - `cache_ttl` — TTL in milliseconds for this entry (default 300 000)
  - `cache_key` — caller-supplied key override (expert use)
  - `cache_max_entries` — eviction threshold (default 1000)
  - `cache_context` — context scope for the key: `auto` (default, uses
    session CWD), `none`, or an explicit binary
  - `cache_errors` — when `true`, cache error responses with a short
    TTL (default 5 000 ms) to prevent retry storms
  - `coalesce` — when `true`, concurrent identical queries are
    coalesced: only one CLI call fires, all callers receive the
    same result (default `false`)
  - `coalesce_timeout` — follower wait timeout in ms (default 60 000)
""".
-spec cached_query(pid(), binary(), map()) ->
    {ok, [beam_agent:message()]} | {error, term()}.
cached_query(Session, Prompt, Opts)
  when is_pid(Session), is_binary(Prompt), is_map(Opts) ->
    Key = resolve_key(Session, Prompt, Opts),
    case beam_agent_prompt_cache_core:get(Key) of
        {hit, {cached_error, Reason}, _Meta} ->
            {error, Reason};
        {hit, Result, _Meta} ->
            {ok, Result};
        miss ->
            case maps:get(coalesce, Opts, false) of
                true ->
                    CoalesceOpts = extract_coalesce_opts(Opts),
                    beam_agent_coalesce_core:execute_or_wait(
                        Key,
                        fun() -> do_query_and_cache(Session, Prompt, Key, Opts) end,
                        CoalesceOpts);
                false ->
                    do_query_and_cache(Session, Prompt, Key, Opts)
            end
    end.

-doc """
Check whether a cached result exists for the given session and prompt
without sending a query on miss.
""".
-spec lookup(pid(), binary()) ->
    {hit, [beam_agent:message()], cache_hit_meta()} | miss.
lookup(Session, Prompt) ->
    lookup(Session, Prompt, #{}).

-doc "Lookup with explicit options (see `cached_query/3` for option keys).".
-spec lookup(pid(), binary(), map()) ->
    {hit, [beam_agent:message()], cache_hit_meta()} | miss.
lookup(Session, Prompt, Opts)
  when is_pid(Session), is_binary(Prompt), is_map(Opts) ->
    Key = resolve_key(Session, Prompt, Opts),
    case beam_agent_prompt_cache_core:get(Key) of
        {hit, {cached_error, _Reason}, _Meta} ->
            miss;
        Other ->
            Other
    end.

-doc """
Manually store a result in the cache for the given session and prompt.
""".
-spec store(pid(), binary(), [beam_agent:message()], map()) -> ok.
store(Session, Prompt, Messages, Opts)
  when is_pid(Session), is_binary(Prompt), is_list(Messages), is_map(Opts) ->
    Key = resolve_key(Session, Prompt, Opts),
    CacheOpts = extract_cache_opts(Opts),
    beam_agent_prompt_cache_core:put(Key, Messages, CacheOpts).

-doc "Invalidate the cached result for the given session and prompt.".
-spec invalidate(pid(), binary()) -> ok.
invalidate(Session, Prompt) ->
    invalidate(Session, Prompt, #{}).

-doc "Invalidate with explicit options.".
-spec invalidate(pid(), binary(), map()) -> ok.
invalidate(Session, Prompt, Opts)
  when is_pid(Session), is_binary(Prompt), is_map(Opts) ->
    Key = resolve_key(Session, Prompt, Opts),
    beam_agent_prompt_cache_core:invalidate(Key).

-doc "Clear all cached entries and reset statistics.".
-spec clear() -> ok.
clear() ->
    beam_agent_prompt_cache_core:clear().

-doc "Return aggregate cache statistics (hits, misses, entries, bytes).".
-spec stats() -> cache_stats().
stats() ->
    beam_agent_prompt_cache_core:stats().

-doc """
Remove all expired entries.  Returns the count of entries removed.

Caller-driven — no background process.
""".
-spec evict_expired() -> non_neg_integer().
evict_expired() ->
    beam_agent_prompt_cache_core:evict_expired().

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% Resolve the cache key: use caller override or compute from session.
%% Caller-supplied keys are re-hashed with the session pid to prevent
%% cross-session cache poisoning.
-spec resolve_key(pid(), binary(), map()) -> cache_key().
resolve_key(Session, _Prompt, #{cache_key := Key})
  when is_binary(Key), byte_size(Key) =:= 32 ->
    SessionBin = term_to_binary(Session),
    crypto:hash(sha256, <<SessionBin/binary, Key/binary>>);
resolve_key(Session, Prompt, Opts) ->
    Backend = resolve_backend(Session),
    Model = resolve_model(Opts),
    Context = resolve_context(Session, Opts),
    beam_agent_prompt_cache_core:cache_key(Backend, Model, Prompt, Context).

%% Dialyzer infers a narrower success typing for beam_agent:backend/1
%% than the declared spec ({ok, backend()} | {error, term()}).
%% The {ok, _} arms are reachable at runtime for live sessions but
%% Dialyzer cannot prove it from the pid() input alone.
-dialyzer({no_match, resolve_backend/1}).
-spec resolve_backend(pid()) -> binary().
resolve_backend(Session) ->
    try beam_agent:backend(Session) of
        {ok, Backend} when is_atom(Backend) ->
            atom_to_binary(Backend, utf8);
        {ok, Backend} when is_binary(Backend) ->
            Backend;
        _ ->
            <<"unknown">>
    catch
        _:_ ->
            <<"unknown">>
    end.

-spec resolve_model(map()) -> binary().
resolve_model(Opts) ->
    case maps:get(model, Opts, undefined) of
        Model when is_binary(Model), byte_size(Model) > 0 ->
            Model;
        _ ->
            <<"default">>
    end.

-define(MAX_ENTRIES_CEILING, 10_000).
-define(DEFAULT_ERROR_TTL, 5_000).  %% 5 seconds — short enough to retry soon

%% Resolve the context component of the cache key.
%% `auto` (default) uses the session's working directory so that
%% identical prompts in different directories produce different keys.
-spec resolve_context(pid(), map()) -> binary().
resolve_context(Session, Opts) ->
    case maps:get(cache_context, Opts, auto) of
        none ->
            <<>>;
        auto ->
            resolve_session_cwd(Session);
        Custom when is_binary(Custom) ->
            Custom;
        _ ->
            %% Fallback to auto behavior for unexpected values
            resolve_session_cwd(Session)
    end.

-spec resolve_session_cwd(pid()) -> binary().
resolve_session_cwd(Session) ->
    try beam_agent:session_info(Session) of
        {ok, #{work_dir := CWD}} when is_binary(CWD) -> CWD;
        _ -> <<>>
    catch
        _:_ -> <<>>
    end.

%% Execute the query and cache the result (extracted for coalesce reuse).
-spec do_query_and_cache(pid(), binary(), cache_key(), map()) ->
    {ok, [beam_agent:message()]} | {error, term()}.
do_query_and_cache(Session, Prompt, Key, Opts) ->
    CacheOpts = extract_cache_opts(Opts),
    QueryOpts = strip_cache_opts(Opts),
    case beam_agent:query(Session, Prompt, QueryOpts) of
        {ok, Messages} = Ok ->
            beam_agent_prompt_cache_core:put(Key, Messages, CacheOpts),
            Ok;
        {error, Reason} = Error ->
            maybe_cache_error(Key, Reason, Opts, CacheOpts),
            Error
    end.

-spec extract_coalesce_opts(map()) -> beam_agent_coalesce_core:coalesce_opts().
extract_coalesce_opts(Opts) ->
    maps:from_list(lists:filtermap(fun
        ({coalesce_timeout, V}) when is_integer(V), V > 0 ->
            {true, {timeout, V}};
        (_) ->
            false
    end, maps:to_list(Opts))).

%% Cache an error response with a short TTL when `cache_errors => true`.
-spec maybe_cache_error(cache_key(), term(), map(), cache_opts()) -> ok.
maybe_cache_error(Key, Reason, Opts, CacheOpts) ->
    case maps:get(cache_errors, Opts, false) of
        true ->
            ErrorTTL = maps:get(cache_error_ttl, Opts, ?DEFAULT_ERROR_TTL),
            ErrorOpts = CacheOpts#{ttl => ErrorTTL},
            beam_agent_prompt_cache_core:put(Key, {cached_error, Reason}, ErrorOpts);
        false ->
            ok
    end.

-spec extract_cache_opts(map()) -> cache_opts().
extract_cache_opts(Opts) ->
    maps:from_list(lists:filtermap(fun
        ({cache_ttl, V}) when is_integer(V), V > 0 ->
            {true, {ttl, V}};
        ({cache_max_entries, V}) when is_integer(V), V > 0 ->
            {true, {max_entries, min(V, ?MAX_ENTRIES_CEILING)}};
        (_) ->
            false
    end, maps:to_list(Opts))).

-spec strip_cache_opts(map()) -> map().
strip_cache_opts(Opts) ->
    maps:without([cache_ttl, cache_key, cache_max_entries,
                  cache_context, cache_errors, cache_error_ttl,
                  coalesce, coalesce_timeout], Opts).
