-module(beam_agent_artifacts).
-moduledoc """
Public API for canonical BeamAgent artifacts.

This module is the stable public API facade for artifacts. It adds input
validation guards and telemetry emission on top of the core implementation
in `beam_agent_artifacts_core`.

Every public function validates its arguments before delegation and emits
`[:beam_agent, :artifacts, :function_name, :start | :stop]` telemetry events
with duration measurements and result status metadata. Telemetry emission is
safe when the `telemetry` library is not loaded.

Artifacts are durable context objects such as plans, diffs, reviews,
summaries, approval packets, benchmark reports, and transcript snapshots.
They are stored independently of live session processes and can be linked
to sessions, threads, runs, and other typed references.

This module is a thin public wrapper over `beam_agent_artifacts_core`.
The core module validates scope and search behavior, while
`beam_agent_artifacts_store` owns the ETS table.

## Quick example

```erlang
{ok, Run} = beam_agent_runs:start_run(<<"sess_001">>, #{kind => workflow}),

{ok, Artifact} = beam_agent_artifacts:put(#{
    run_id => maps:get(run_id, Run),
    kind => plan,
    title => <<"Execution Plan">>,
    body => <<"1. Implement\n2. Verify">>,
    format => markdown
}),

ok = beam_agent_artifacts:attach(
    maps:get(artifact_id, Artifact),
    message,
    <<"msg_123">>
),

{ok, Matches} = beam_agent_artifacts:search(<<"implement">>).
```
""".

-export([
    ensure_tables/0,
    clear/0,
    put/1,
    put/2,
    get/1,
    list/0,
    list/1,
    search/1,
    search/2,
    attach/3,
    delete/1
]).

-export_type([
    scope/0,
    artifact/0,
    artifact_input/0,
    artifact_filter/0,
    source_ref/0
]).

-doc "Artifact scope passed to `put/2`.".
-type scope() :: beam_agent_artifacts_core:scope().

-doc "Artifact source reference map.".
-type source_ref() :: beam_agent_artifacts_core:source_ref().

-doc "Artifact input map accepted by `put/1,2`.".
-type artifact_input() :: beam_agent_artifacts_core:artifact_input().

-doc "Artifact filter accepted by `list/1` and `search/2`.".
-type artifact_filter() :: beam_agent_artifacts_core:artifact_filter().

-doc "Canonical artifact record returned by the public API.".
-type artifact() :: beam_agent_artifacts_core:artifact().

-doc "Ensure the artifacts ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    with_telemetry(ensure_tables, 0, fun() ->
        beam_agent_artifacts_core:ensure_tables()
    end).

-doc "Clear all artifacts. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    with_telemetry(clear, 0, fun() ->
        beam_agent_artifacts_core:clear()
    end).

-doc "Insert or update an artifact using embedded scope.".
-spec put(artifact_input()) -> {ok, artifact()} | {error, term()}.
put(Artifact) when is_map(Artifact) ->
    with_telemetry(put, 1, fun() ->
        beam_agent_artifacts_core:put(Artifact)
    end);
put(_) ->
    {error, {bad_arg, <<"artifact must be a map">>}}.

-doc "Insert or update an artifact with explicit scope.".
-spec put(scope(), artifact_input()) -> {ok, artifact()} | {error, term()}.
put(Scope, Artifact) when is_binary(Scope), is_map(Artifact) ->
    with_telemetry(put, 2, fun() ->
        beam_agent_artifacts_core:put(Scope, Artifact)
    end);
put(Scope, Artifact) when is_map(Scope), is_map(Artifact) ->
    with_telemetry(put, 2, fun() ->
        beam_agent_artifacts_core:put(Scope, Artifact)
    end);
put(_, Artifact) when is_map(Artifact) ->
    {error, {bad_arg, <<"scope must be a binary or map">>}};
put(_, _) ->
    {error, {bad_arg, <<"artifact must be a map">>}}.

-doc "Fetch an artifact by id.".
-spec get(binary()) -> {ok, artifact()} | {error, not_found | {bad_arg, binary()}}.
get(ArtifactId) when is_binary(ArtifactId) ->
    with_telemetry(get, 1, fun() ->
        beam_agent_artifacts_core:get(ArtifactId)
    end);
get(_) ->
    {error, {bad_arg, <<"artifact_id must be a binary">>}}.

-doc "List all artifacts without filters.".
-spec list() -> {ok, [artifact()]}.
list() ->
    with_telemetry(list, 0, fun() ->
        beam_agent_artifacts_core:list()
    end).

-doc "List artifacts with exact-match filters.".
-spec list(artifact_filter()) -> {ok, [artifact()]} | {error, term()}.
list(Filter) when is_map(Filter) ->
    with_telemetry(list, 1, fun() ->
        beam_agent_artifacts_core:list(Filter)
    end);
list(_) ->
    {error, {bad_arg, <<"filter must be a map">>}}.

-doc "Search artifacts with a case-insensitive tokenized query.".
-spec search(binary()) -> {ok, [artifact()]} | {error, {bad_arg, binary()}}.
search(Query) when is_binary(Query) ->
    with_telemetry(search, 1, fun() ->
        beam_agent_artifacts_core:search(Query)
    end);
search(_) ->
    {error, {bad_arg, <<"query must be a binary">>}}.

-doc "Search artifacts with a query plus exact-match filters.".
-spec search(binary(), artifact_filter()) -> {ok, [artifact()]} | {error, term()}.
search(Query, Filter) when is_binary(Query), is_map(Filter) ->
    with_telemetry(search, 2, fun() ->
        beam_agent_artifacts_core:search(Query, Filter)
    end);
search(Query, _) when not is_binary(Query) ->
    {error, {bad_arg, <<"query must be a binary">>}};
search(_, _) ->
    {error, {bad_arg, <<"filter must be a map">>}}.

-doc "Attach a typed source reference to an existing artifact.".
-spec attach(binary(), atom() | binary(), binary()) ->
    ok |
    {error, inconsistent_run_scope | inconsistent_scope | not_found |
        run_not_found | session_id_required_for_thread | {bad_arg, binary()}}.
attach(ArtifactId, RefType, RefId)
  when is_binary(ArtifactId), (is_atom(RefType) orelse is_binary(RefType)), is_binary(RefId) ->
    with_telemetry(attach, 3, fun() ->
        beam_agent_artifacts_core:attach(ArtifactId, RefType, RefId)
    end);
attach(ArtifactId, _, _) when not is_binary(ArtifactId) ->
    {error, {bad_arg, <<"artifact_id must be a binary">>}};
attach(_, RefType, _) when not is_atom(RefType), not is_binary(RefType) ->
    {error, {bad_arg, <<"ref_type must be an atom or binary">>}};
attach(_, _, _) ->
    {error, {bad_arg, <<"ref_id must be a binary">>}}.

-doc "Delete an artifact by id.".
-spec delete(binary()) -> ok | {error, not_found | {bad_arg, binary()}}.
delete(ArtifactId) when is_binary(ArtifactId) ->
    with_telemetry(delete, 1, fun() ->
        beam_agent_artifacts_core:delete(ArtifactId)
    end);
delete(_) ->
    {error, {bad_arg, <<"artifact_id must be a binary">>}}.

%%--------------------------------------------------------------------
%% Internal — telemetry wrapper
%%--------------------------------------------------------------------

with_telemetry(Function, Arity, Fun) ->
    StartTime = beam_agent_telemetry:span_start(artifacts, Function, #{arity => Arity}),
    Result = Fun(),
    Status = case Result of
        {ok, _} -> ok;
        ok -> ok;
        {error, _} -> error
    end,
    beam_agent_telemetry:span_stop(artifacts, Function, StartTime, #{
        function => Function,
        arity => Arity,
        status => Status
    }),
    Result.
