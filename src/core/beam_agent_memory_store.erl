-module(beam_agent_memory_store).
-moduledoc """
Internal store-backed persistence for BeamAgent long-term memory.

This module owns the raw persistence shape for canonical memory records.
It intentionally does not decide search ranking, expiry policy, or scope
validation. Those concerns live in `beam_agent_memory_core`.
""".

-export([
    ensure_tables/0,
    clear/0,
    put_memory/1,
    get_memory/1,
    delete_memory/1,
    list_memories/1
]).

-export_type([
    memory_record/0,
    memory_filter/0,
    source_ref/0,
    scope/0
]).

-type memory_kind() :: atom() | binary().
-type ttl() :: non_neg_integer() | infinity.

-type scope() :: #{
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type source_ref() :: #{
    type := atom() | binary(),
    id := binary(),
    metadata => map()
}.

-type memory_record() :: #{
    memory_id := binary(),
    kind := memory_kind(),
    content := term(),
    attributes := map(),
    source_refs := [source_ref()],
    scope := scope(),
    pinned := boolean(),
    salience := non_neg_integer(),
    ttl := ttl(),
    created_at := integer(),
    updated_at := integer(),
    expires_at => integer()
}.

-type memory_filter() :: #{
    memory_id => binary(),
    kind => memory_kind(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    pinned => boolean(),
    source_ref_type => atom() | binary(),
    source_ref_id => binary(),
    limit => pos_integer(),
    since => integer()
}.

-define(MEMORY_TABLE, beam_agent_memory_records).
-define(STORE_DOMAIN, memory).

-doc "Ensure the memory ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?MEMORY_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Clear all memory records.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?MEMORY_TABLE),
    ok.

-doc "Insert or overwrite a memory record.".
-spec put_memory(memory_record()) -> ok.
put_memory(#{memory_id := MemoryId} = Memory) when is_binary(MemoryId) ->
    ensure_tables(),
    true = beam_agent_store:insert(?STORE_DOMAIN, ?MEMORY_TABLE, {MemoryId, Memory}),
    ok.

-doc "Fetch a memory record by id.".
-spec get_memory(binary()) -> {ok, memory_record()} | {error, not_found}.
get_memory(MemoryId) when is_binary(MemoryId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?MEMORY_TABLE, MemoryId) of
        [{_, Memory}] -> {ok, Memory};
        [] -> {error, not_found}
    end.

-doc "Delete a memory record by id.".
-spec delete_memory(binary()) -> ok | {error, not_found}.
delete_memory(MemoryId) when is_binary(MemoryId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?MEMORY_TABLE, MemoryId) of
        [{_, _Memory}] ->
            beam_agent_store:delete(?STORE_DOMAIN, ?MEMORY_TABLE, MemoryId),
            ok;
        [] ->
            {error, not_found}
    end.

-doc "List memories matching an already-normalized filter map.".
-spec list_memories(memory_filter()) -> {ok, [memory_record()]}.
list_memories(Filter) when is_map(Filter) ->
    ensure_tables(),
    Memories = beam_agent_store:foldl(?STORE_DOMAIN, fun
        ({_, Memory}, Acc) ->
            case matches_filters(Memory, Filter) of
                true -> [Memory | Acc];
                false -> Acc
            end
    end, [], ?MEMORY_TABLE),
    Sorted = lists:sort(fun sort_memories/2, Memories),
    {ok, apply_limit(Sorted, Filter)}.

-spec matches_filters(memory_record(), memory_filter()) -> boolean().
matches_filters(Memory, Filter) ->
    lists:all(fun
        ({limit, _}) ->
            true;
        ({since, Since}) ->
            maps:get(updated_at, Memory, 0) >= Since;
        ({session_id, SessionId}) ->
            scope_value(session_id, Memory) =:= SessionId;
        ({thread_id, ThreadId}) ->
            scope_value(thread_id, Memory) =:= ThreadId;
        ({run_id, RunId}) ->
            scope_value(run_id, Memory) =:= RunId;
        ({source_ref_type, RefType}) ->
            has_source_ref_type(RefType, maps:get(source_refs, Memory, []));
        ({source_ref_id, RefId}) ->
            has_source_ref_id(RefId, maps:get(source_refs, Memory, []));
        ({Key, Value}) ->
            maps:get(Key, Memory, undefined) =:= Value
    end, maps:to_list(Filter)).

-spec scope_value(atom(), memory_record()) -> term().
scope_value(Key, Memory) ->
    maps:get(Key, maps:get(scope, Memory, #{}), undefined).

-spec has_source_ref_type(atom() | binary(), [source_ref()]) -> boolean().
has_source_ref_type(RefType, SourceRefs) ->
    lists:any(fun
        (#{type := Type}) -> Type =:= RefType;
        (_) -> false
    end, SourceRefs).

-spec has_source_ref_id(binary(), [source_ref()]) -> boolean().
has_source_ref_id(RefId, SourceRefs) ->
    lists:any(fun
        (#{id := Id}) -> Id =:= RefId;
        (_) -> false
    end, SourceRefs).

-spec apply_limit([memory_record()], memory_filter()) -> [memory_record()].
apply_limit(Memories, Filter) ->
    case maps:get(limit, Filter, infinity) of
        infinity ->
            Memories;
        Limit when is_integer(Limit), Limit > 0 ->
            lists:sublist(Memories, Limit)
    end.

-spec sort_memories(memory_record(), memory_record()) -> boolean().
sort_memories(A, B) ->
    compare_desc(
        maps:get(updated_at, A, 0),
        maps:get(updated_at, B, 0),
        maps:get(memory_id, A),
        maps:get(memory_id, B)
    ).

-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.
