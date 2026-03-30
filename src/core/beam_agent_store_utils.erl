-module(beam_agent_store_utils).
-moduledoc """
Shared utility functions for BeamAgent domain store modules.

Provides common sort comparators, result limiting, and source-reference
matching used across `beam_agent_artifacts_store`, `beam_agent_memory_store`,
`beam_agent_runs_store`, `beam_agent_routines_store`,
`beam_agent_orchestrator_store`, and `beam_agent_policy_core`.

These were extracted to eliminate copy-paste drift across store modules.
""".

-export([
    compare_desc/4,
    compare_asc/4,
    apply_limit/2,
    has_source_ref_type/2,
    has_source_ref_id/2
]).

%%--------------------------------------------------------------------
%% Sort Comparators
%%--------------------------------------------------------------------

-doc """
Descending sort comparator with stable ID tiebreaker.

Compares two timestamps (integers) in descending order. When timestamps are
equal, falls back to lexicographic comparison of IDs for deterministic ordering.

Intended for use with `lists:sort/2`:
```erlang
lists:sort(fun(A, B) ->
    beam_agent_store_utils:compare_desc(
        maps:get(updated_at, A, 0), maps:get(updated_at, B, 0),
        maps:get(artifact_id, A), maps:get(artifact_id, B))
end, Records).
```
""".
-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

-doc """
Ascending sort comparator with stable ID tiebreaker.

Compares two timestamps (integers) in ascending order. When timestamps are
equal, falls back to lexicographic comparison of IDs for deterministic ordering.
""".
-spec compare_asc(integer(), integer(), binary(), binary()) -> boolean().
compare_asc(Left, Right, _LeftId, _RightId) when Left < Right ->
    true;
compare_asc(Left, Right, _LeftId, _RightId) when Left > Right ->
    false;
compare_asc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

%%--------------------------------------------------------------------
%% Result Limiting
%%--------------------------------------------------------------------

-doc """
Truncate a list to at most `Limit` elements.

Pass `infinity` to return the full list unchanged.
""".
-spec apply_limit(list(), infinity | pos_integer()) -> list().
apply_limit(List, infinity) ->
    List;
apply_limit(List, Limit) when is_integer(Limit), Limit > 0 ->
    lists:sublist(List, Limit).

%%--------------------------------------------------------------------
%% Source Reference Matching
%%--------------------------------------------------------------------

-doc """
Check whether any source reference in a list has the given type.

Source references are maps with at least a `type` field.
""".
-spec has_source_ref_type(atom() | binary(), [map()]) -> boolean().
has_source_ref_type(RefType, SourceRefs) ->
    lists:any(fun
        (#{type := Type}) -> Type =:= RefType;
        (_) -> false
    end, SourceRefs).

-doc """
Check whether any source reference in a list has the given id.

Source references are maps with at least an `id` field.
""".
-spec has_source_ref_id(binary(), [map()]) -> boolean().
has_source_ref_id(RefId, SourceRefs) ->
    lists:any(fun
        (#{id := Id}) -> Id =:= RefId;
        (_) -> false
    end, SourceRefs).
