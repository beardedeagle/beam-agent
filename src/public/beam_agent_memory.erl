-module(beam_agent_memory).
-moduledoc """
Public API for canonical BeamAgent long-term memory.

Memories are durable cross-session facts and notes that can be scoped to
sessions, threads, or runs, linked to artifacts and other typed references,
and recalled later using lexical search. The implementation is process-free
and uses the canonical store abstraction with ETS as the default adapter.

## Quick example

```erlang
{ok, Run} = beam_agent_runs:start_run(<<"sess_001">>, #{kind => workflow}),

{ok, Memory} = beam_agent_memory:remember(#{run_id => maps:get(run_id, Run)}, #{
    kind => note,
    content => <<"Prefer the safer diff path for release builds">>,
    salience => 25,
    source_refs => [#{type => artifact, id => <<"artifact_123">>}]
}),

{ok, Matches} = beam_agent_memory:recall(<<"sess_001">>, <<"safer diff">>),
true = lists:any(fun(Entry) ->
    maps:get(memory_id, Entry) =:= maps:get(memory_id, Memory)
end, Matches).
```
""".

-export([
    ensure_tables/0,
    clear/0,
    remember/2,
    remember/3,
    get/1,
    list/0,
    list/1,
    recall/2,
    search/1,
    search/2,
    forget/1,
    update/2,
    pin/1,
    unpin/1,
    expire/0,
    expire/1
]).

-export_type([
    scope/0,
    source_ref/0,
    memory_input/0,
    update_input/0,
    memory_filter/0,
    memory_record/0
]).

-type scope() :: beam_agent_memory_core:scope().
-type source_ref() :: beam_agent_memory_core:source_ref().
-type memory_input() :: beam_agent_memory_core:memory_input().
-type update_input() :: beam_agent_memory_core:update_input().
-type memory_filter() :: beam_agent_memory_core:memory_filter().
-type memory_record() :: beam_agent_memory_core:memory_record().

-doc "Ensure the memory store exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_memory_core:ensure_tables().

-doc "Clear all memories. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_memory_core:clear().

-doc "Remember content with embedded or explicit kind on a scope.".
-spec remember(binary() | scope(), memory_input()) ->
    {ok, memory_record()} | {error, term()}.
remember(Scope, MemoryInput) ->
    beam_agent_memory_core:remember(Scope, MemoryInput).

-doc "Remember content with an explicit kind on a scope.".
-spec remember(binary() | scope(), atom() | binary(), memory_input()) ->
    {ok, memory_record()} | {error, term()}.
remember(Scope, Kind, MemoryInput) ->
    beam_agent_memory_core:remember(Scope, Kind, MemoryInput).

-doc "Fetch a memory by id.".
-spec get(binary()) -> {ok, memory_record()} | {error, not_found}.
get(MemoryId) ->
    beam_agent_memory_core:get(MemoryId).

-doc "List all visible memories.".
-spec list() -> {ok, [memory_record()]}.
list() ->
    beam_agent_memory_core:list().

-doc "List memories with exact-match filters and visibility controls.".
-spec list(memory_filter()) -> {ok, [memory_record()]} | {error, term()}.
list(Filter) ->
    beam_agent_memory_core:list(Filter).

-doc "Recall memories for a scope using lexical search.".
-spec recall(binary() | scope(), binary()) ->
    {ok, [memory_record()]} | {error, term()}.
recall(Scope, Query) ->
    beam_agent_memory_core:recall(Scope, Query).

-doc "Search memories across all scopes.".
-spec search(binary()) -> {ok, [memory_record()]} | {error, term()}.
search(Query) ->
    beam_agent_memory_core:search(Query).

-doc "Search memories with a lexical query plus exact-match filters.".
-spec search(binary(), memory_filter()) ->
    {ok, [memory_record()]} | {error, term()}.
search(Query, Filter) ->
    beam_agent_memory_core:search(Query, Filter).

-doc "Forget a memory by id.".
-spec forget(binary()) -> ok | {error, not_found}.
forget(MemoryId) ->
    beam_agent_memory_core:forget(MemoryId).

-doc """
Update mutable fields of an existing memory record.

Accepts a map of fields to change. Mutable fields: `kind`, `content`,
`attributes`, `source_refs`, `ttl`, `pinned`, `salience`. Immutable fields
(`memory_id`, `scope`, `created_at`) are rejected with
`{error, {immutable_field, Field}}`.

When `ttl` is updated, `expires_at` is automatically recalculated from the
current time. The `updated_at` timestamp is always refreshed.
""".
-spec update(binary(), update_input()) ->
    {ok, memory_record()} | {error, not_found | {immutable_field, atom()} | term()}.
update(MemoryId, Changes) ->
    beam_agent_memory_core:update(MemoryId, Changes).

-doc "Pin a memory.".
-spec pin(binary()) -> ok | {error, not_found}.
pin(MemoryId) ->
    beam_agent_memory_core:pin(MemoryId).

-doc "Unpin a memory.".
-spec unpin(binary()) -> ok | {error, not_found}.
unpin(MemoryId) ->
    beam_agent_memory_core:unpin(MemoryId).

-doc "Expire all currently expired, unpinned memories.".
-spec expire() -> {ok, non_neg_integer()}.
expire() ->
    beam_agent_memory_core:expire().

-doc "Expire currently expired, unpinned memories matching a filter.".
-spec expire(memory_filter()) ->
    {ok, non_neg_integer()} |
    {error, {invalid_filter, before | include_expired | kind | limit | memory_id |
        min_salience | pinned | run_id | session_id | since | source_ref_id |
        source_ref_type | thread_id} |
        {invalid_scope, memory_id | run_id | session_id | source_ref_id | thread_id}}.
expire(Filter) ->
    beam_agent_memory_core:expire(Filter).
