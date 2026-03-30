-module(beam_agent_memory).
-moduledoc """
Public API for canonical BeamAgent long-term memory.

This module is the stable public API facade for long-term memory. It adds
input validation guards and telemetry emission on top of the core
implementation in `beam_agent_memory_core`.

Every public function validates its arguments before delegation and emits
`[:beam_agent, :memory, :function_name, :start | :stop]` telemetry events
with duration measurements and result status metadata. Telemetry emission is
safe when the `telemetry` library is not loaded.

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

== Architecture

This module is the stable public API facade for long-term memory. It delegates
most operations to `beam_agent_memory_core`, which owns the implementation
and search logic. The one exception is `configure_persistence/1`, which routes
to `beam_agent_store:configure_domain/2` for adapter configuration. The
two-layer split decouples the public API contract from internal implementation,
allowing the core module to be refactored freely without breaking callers.
Type aliases re-exported here let callers depend on
`beam_agent_memory:memory_record()` rather than the internal module name.
""".

-export([
    ensure_tables/0,
    clear/0,
    configure_persistence/1,
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
    memory_record/0,
    scope_error/0,
    memory_input_error/0,
    memory_update_error/0,
    memory_filter_error/0,
    memory_operation/0
]).

-type scope() :: beam_agent_memory_core:scope().
-type source_ref() :: beam_agent_memory_core:source_ref().
-type memory_input() :: beam_agent_memory_core:memory_input().
-type update_input() :: beam_agent_memory_core:update_input().
-type memory_filter() :: beam_agent_memory_core:memory_filter().
-type memory_record() :: beam_agent_memory_core:memory_record().
-type scope_error() :: beam_agent_memory_core:scope_error().
-type memory_input_error() :: beam_agent_memory_core:memory_input_error().
-type memory_update_error() :: beam_agent_memory_core:memory_update_error().
-type memory_filter_error() :: beam_agent_memory_core:memory_filter_error().
-type memory_operation() :: beam_agent_memory_core:memory_operation().

-doc "Ensure the memory store exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    with_telemetry(ensure_tables, 0, fun() ->
        beam_agent_memory_core:ensure_tables()
    end).

-doc "Clear all memories. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    with_telemetry(clear, 0, fun() ->
        beam_agent_memory_core:clear()
    end).

-doc """
Configure a persistence adapter for the memory domain.

By default memories live in ETS and vanish on VM restart. Call this
function to switch to a durable adapter such as `beam_agent_store_dets`.

```erlang
beam_agent_memory:configure_persistence(#{
    adapter => beam_agent_store_dets,
    options => #{data_dir => "/tmp/beam_agent"}
}).
```

When using DETS, callers must call
`beam_agent_store_dets:close_table(beam_agent_memory_records)` during
application shutdown to flush pending writes.
""".
-spec configure_persistence(beam_agent_store:store_config()) ->
    ok | {error, invalid_options | {invalid_adapter, atom()} | {bad_arg, binary()}}.
configure_persistence(Config) when is_map(Config) ->
    with_telemetry(configure_persistence, 1, fun() ->
        beam_agent_store:configure_domain(memory, Config)
    end);
configure_persistence(_) ->
    {error, {bad_arg, <<"config must be a map">>}}.

-doc "Remember content with embedded or explicit kind on a scope.".
-spec remember(binary() | scope(), memory_input()) ->
    {ok, memory_record()} | {error, memory_input_error() | {bad_arg, binary()}}.
remember(Scope, MemoryInput) when is_binary(Scope), is_map(MemoryInput) ->
    with_telemetry(remember, 2, fun() ->
        beam_agent_memory_core:remember(Scope, MemoryInput)
    end);
remember(Scope, MemoryInput) when is_binary(Scope), is_binary(MemoryInput) ->
    with_telemetry(remember, 2, fun() ->
        beam_agent_memory_core:remember(Scope, MemoryInput)
    end);
remember(Scope, MemoryInput) when is_map(Scope), is_map(MemoryInput) ->
    with_telemetry(remember, 2, fun() ->
        beam_agent_memory_core:remember(Scope, MemoryInput)
    end);
remember(Scope, MemoryInput) when is_map(Scope), is_binary(MemoryInput) ->
    with_telemetry(remember, 2, fun() ->
        beam_agent_memory_core:remember(Scope, MemoryInput)
    end);
remember(_, _) ->
    {error, {bad_arg, <<"scope must be a binary or map; memory_input must be a binary or map">>}}.

-doc "Remember content with an explicit kind on a scope.".
-spec remember(binary() | scope(), atom() | binary(), memory_input()) ->
    {ok, memory_record()} | {error, memory_input_error() | {bad_arg, binary()}}.
remember(Scope, Kind, MemoryInput)
  when (is_binary(Scope) orelse is_map(Scope)),
       (is_atom(Kind) orelse is_binary(Kind)),
       (is_map(MemoryInput) orelse is_binary(MemoryInput)) ->
    with_telemetry(remember, 3, fun() ->
        beam_agent_memory_core:remember(Scope, Kind, MemoryInput)
    end);
remember(Scope, _, _) when not is_binary(Scope), not is_map(Scope) ->
    {error, {bad_arg, <<"scope must be a binary or map">>}};
remember(_, Kind, _) when not is_atom(Kind), not is_binary(Kind) ->
    {error, {bad_arg, <<"kind must be an atom or binary">>}};
remember(_, _, _) ->
    {error, {bad_arg, <<"memory_input must be a binary or map">>}}.

-doc "Fetch a memory by id.".
-spec get(binary()) -> {ok, memory_record()} | {error, not_found | {bad_arg, binary()}}.
get(MemoryId) when is_binary(MemoryId) ->
    with_telemetry(get, 1, fun() ->
        beam_agent_memory_core:get(MemoryId)
    end);
get(_) ->
    {error, {bad_arg, <<"memory_id must be a binary">>}}.

-doc "List all visible memories.".
-spec list() -> {ok, [memory_record()]}.
list() ->
    with_telemetry(list, 0, fun() ->
        beam_agent_memory_core:list()
    end).

-doc "List memories with exact-match filters and visibility controls.".
-spec list(memory_filter()) -> {ok, [memory_record()]} | {error, memory_filter_error() | {bad_arg, binary()}}.
list(Filter) when is_map(Filter) ->
    with_telemetry(list, 1, fun() ->
        beam_agent_memory_core:list(Filter)
    end);
list(_) ->
    {error, {bad_arg, <<"filter must be a map">>}}.

-doc "Recall memories for a scope using lexical search.".
-spec recall(binary() | scope(), binary()) ->
    {ok, [memory_record()]} | {error, scope_error() | memory_filter_error() | {bad_arg, binary()}}.
recall(Scope, Query) when is_binary(Scope), is_binary(Query) ->
    with_telemetry(recall, 2, fun() ->
        beam_agent_memory_core:recall(Scope, Query)
    end);
recall(Scope, Query) when is_map(Scope), is_binary(Query) ->
    with_telemetry(recall, 2, fun() ->
        beam_agent_memory_core:recall(Scope, Query)
    end);
recall(_, Query) when not is_binary(Query) ->
    {error, {bad_arg, <<"query must be a binary">>}};
recall(_, _) ->
    {error, {bad_arg, <<"scope must be a binary or map">>}}.

-doc "Search memories across all scopes.".
-spec search(binary()) -> {ok, [memory_record()]} | {error, {bad_arg, binary()}}.
search(Query) when is_binary(Query) ->
    with_telemetry(search, 1, fun() ->
        beam_agent_memory_core:search(Query)
    end);
search(_) ->
    {error, {bad_arg, <<"query must be a binary">>}}.

-doc "Search memories with a lexical query plus exact-match filters.".
-spec search(binary(), memory_filter()) ->
    {ok, [memory_record()]} | {error, memory_filter_error() | {bad_arg, binary()}}.
search(Query, Filter) when is_binary(Query), is_map(Filter) ->
    with_telemetry(search, 2, fun() ->
        beam_agent_memory_core:search(Query, Filter)
    end);
search(Query, _) when not is_binary(Query) ->
    {error, {bad_arg, <<"query must be a binary">>}};
search(_, _) ->
    {error, {bad_arg, <<"filter must be a map">>}}.

-doc "Forget a memory by id.".
-spec forget(binary()) -> ok | {error, not_found | {bad_arg, binary()}}.
forget(MemoryId) when is_binary(MemoryId) ->
    with_telemetry(forget, 1, fun() ->
        beam_agent_memory_core:forget(MemoryId)
    end);
forget(_) ->
    {error, {bad_arg, <<"memory_id must be a binary">>}}.

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
    {ok, memory_record()} | {error, memory_update_error() | {bad_arg, binary()}}.
update(MemoryId, Changes) when is_binary(MemoryId), is_map(Changes) ->
    with_telemetry(update, 2, fun() ->
        beam_agent_memory_core:update(MemoryId, Changes)
    end);
update(MemoryId, _) when not is_binary(MemoryId) ->
    {error, {bad_arg, <<"memory_id must be a binary">>}};
update(_, _) ->
    {error, {bad_arg, <<"changes must be a map">>}}.

-doc "Pin a memory.".
-spec pin(binary()) -> ok | {error, not_found | {bad_arg, binary()}}.
pin(MemoryId) when is_binary(MemoryId) ->
    with_telemetry(pin, 1, fun() ->
        beam_agent_memory_core:pin(MemoryId)
    end);
pin(_) ->
    {error, {bad_arg, <<"memory_id must be a binary">>}}.

-doc "Unpin a memory.".
-spec unpin(binary()) -> ok | {error, not_found | {bad_arg, binary()}}.
unpin(MemoryId) when is_binary(MemoryId) ->
    with_telemetry(unpin, 1, fun() ->
        beam_agent_memory_core:unpin(MemoryId)
    end);
unpin(_) ->
    {error, {bad_arg, <<"memory_id must be a binary">>}}.

-doc "Expire all currently expired, unpinned memories.".
-spec expire() -> {ok, non_neg_integer()}.
expire() ->
    with_telemetry(expire, 0, fun() ->
        beam_agent_memory_core:expire()
    end).

-doc "Expire currently expired, unpinned memories matching a filter.".
-spec expire(memory_filter()) -> {ok, non_neg_integer()} | {error, memory_filter_error() | {bad_arg, binary()}}.
expire(Filter) when is_map(Filter) ->
    with_telemetry(expire, 1, fun() ->
        beam_agent_memory_core:expire(Filter)
    end);
expire(_) ->
    {error, {bad_arg, <<"filter must be a map">>}}.

%%--------------------------------------------------------------------
%% Internal — telemetry wrapper
%%--------------------------------------------------------------------

with_telemetry(Function, Arity, Fun) ->
    StartTime = beam_agent_telemetry:span_start(memory, Function, #{arity => Arity}),
    Result = Fun(),
    Status = case Result of
        {ok, _} -> ok;
        ok -> ok;
        {error, _} -> error
    end,
    beam_agent_telemetry:span_stop(memory, Function, StartTime, #{
        function => Function,
        arity => Arity,
        status => Status
    }),
    Result.
