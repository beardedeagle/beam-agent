-module(beam_agent_artifacts_store).
-moduledoc """
Internal store-backed persistence for BeamAgent artifacts.

This module owns the raw persistence shape for canonical artifact records.
It does not validate scope consistency or search semantics. Those concerns
belong in beam_agent_artifacts_core. The default adapter is ETS via
`beam_agent_store_ets`.
""".

-export([
    ensure_tables/0,
    clear/0,
    put_artifact/1,
    get_artifact/1,
    delete_artifact/1,
    list_artifacts/1
]).

-export_type([
    artifact_record/0,
    artifact_filter/0,
    source_ref/0
]).

-type artifact_kind() :: atom() | binary().
-type artifact_format() :: atom() | binary().

-type source_ref() :: #{
    type := atom() | binary(),
    id := binary(),
    metadata => map()
}.

-type artifact_record() :: #{
    artifact_id := binary(),
    kind := artifact_kind(),
    title := binary(),
    body := term(),
    format := artifact_format(),
    source_refs := [source_ref()],
    metadata := map(),
    created_at := integer(),
    updated_at := integer(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type artifact_filter() :: #{
    artifact_id => binary(),
    kind => artifact_kind(),
    format => artifact_format(),
    title => binary(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    source_ref_type => atom() | binary(),
    source_ref_id => binary(),
    limit => pos_integer(),
    since => integer()
}.

-define(DOMAINS_TABLE, beam_agent_domains).
-define(STORE_DOMAIN, artifacts).

-doc "Ensure the shared domains table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?DOMAINS_TABLE, [set,
        named_table,
        {read_concurrency, true}]).

-doc "Clear all artifact records.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?DOMAINS_TABLE, {{artifact, '_'}, '_'}),
    ok.

-doc "Insert or overwrite an artifact record.".
-spec put_artifact(artifact_record()) -> ok.
put_artifact(#{artifact_id := ArtifactId} = Artifact) when is_binary(ArtifactId) ->
    ensure_tables(),
    true = beam_agent_store:insert(?STORE_DOMAIN, ?DOMAINS_TABLE,
        {{artifact, ArtifactId}, Artifact}),
    ok.

-doc "Fetch an artifact by id.".
-spec get_artifact(binary()) -> {ok, artifact_record()} | {error, not_found}.
get_artifact(ArtifactId) when is_binary(ArtifactId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?DOMAINS_TABLE, {artifact, ArtifactId}) of
        [{_, Artifact}] -> {ok, Artifact};
        [] -> {error, not_found}
    end.

-doc "Delete an artifact by id.".
-spec delete_artifact(binary()) -> ok | {error, not_found}.
delete_artifact(ArtifactId) when is_binary(ArtifactId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?DOMAINS_TABLE, {artifact, ArtifactId}) of
        [{_, _Artifact}] ->
            beam_agent_store:delete(?STORE_DOMAIN, ?DOMAINS_TABLE, {artifact, ArtifactId}),
            ok;
        [] ->
            {error, not_found}
    end.

-doc "List artifacts matching an already-normalized filter map.".
-spec list_artifacts(artifact_filter()) -> {ok, [artifact_record()]}.
list_artifacts(Filter) when is_map(Filter) ->
    ensure_tables(),
    Artifacts = beam_agent_store:foldl(?STORE_DOMAIN, fun
        ({{artifact, _}, Artifact}, Acc) ->
            case matches_filters(Artifact, Filter) of
                true -> [Artifact | Acc];
                false -> Acc
            end;
        (_, Acc) ->
            Acc
    end, [], ?DOMAINS_TABLE),
    Sorted = lists:sort(fun sort_artifacts/2, Artifacts),
    {ok, apply_limit(Sorted, Filter)}.

-spec matches_filters(artifact_record(), artifact_filter()) -> boolean().
matches_filters(Artifact, Filter) ->
    lists:all(fun
        ({limit, _}) ->
            true;
        ({since, Since}) ->
            maps:get(updated_at, Artifact, 0) >= Since;
        ({source_ref_type, RefType}) ->
            has_source_ref_type(RefType, maps:get(source_refs, Artifact, []));
        ({source_ref_id, RefId}) ->
            has_source_ref_id(RefId, maps:get(source_refs, Artifact, []));
        ({Key, Value}) ->
            maps:get(Key, Artifact, undefined) =:= Value
    end, maps:to_list(Filter)).

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

-spec apply_limit([artifact_record()], artifact_filter()) -> [artifact_record()].
apply_limit(Artifacts, Filter) ->
    case maps:get(limit, Filter, infinity) of
        infinity ->
            Artifacts;
        Limit when is_integer(Limit), Limit > 0 ->
            lists:sublist(Artifacts, Limit)
    end.

-spec sort_artifacts(artifact_record(), artifact_record()) -> boolean().
sort_artifacts(A, B) ->
    compare_desc(
        maps:get(updated_at, A, 0),
        maps:get(updated_at, B, 0),
        maps:get(artifact_id, A),
        maps:get(artifact_id, B)
    ).

-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.
