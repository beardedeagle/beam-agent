-module(beam_agent_artifacts_core).
-compile({no_auto_import, [put/2]}).
-moduledoc """
Canonical artifact and context store for BeamAgent.

Artifacts are durable runtime outputs such as plans, diffs, reviews,
summaries, approval packets, and benchmark reports. They are modeled as
typed records linked to sessions, threads, and runs, with exact-match
filtering and simple tokenized text search.

This module keeps artifact handling process-free and storage-backed. It
validates run/thread/session linkage, normalizes source references, and
delegates persistence to beam_agent_artifacts_store.
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

-type artifact_kind() :: atom() | binary().
-type artifact_format() :: atom() | binary().

-type scope() :: binary() | #{
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type source_ref() :: beam_agent_artifacts_store:source_ref().
-type optional_binary_key() ::
    artifact_id | run_id | session_id | source_ref_id | thread_id | title.
-type kind_key() :: format | kind.
-type artifact_error_tag() :: invalid_artifact | invalid_filter | invalid_scope.
-type artifact_event_operation() :: created | deleted | updated.
-type artifact_event_payload() :: #{
    operation => artifact_event_operation(),
    source_ref => source_ref()
}.
-type journal_error() ::
    already_exists
  | session_id_required_for_thread
  | {invalid_event, event_id | payload | run_id | session_id | tags | thread_id | timestamp}
  | {invalid_event_type, binary()}.
-type artifact_operation() :: put | get | list | search | attach | delete.
-type artifact_exception() ::
    {error,
        inconsistent_run_scope
      | inconsistent_scope
      | not_found
      | run_not_found
      | session_id_required_for_thread
      | {invalid_artifact | invalid_filter | invalid_scope |
            unsupported_artifact_key | unsupported_filter | unsupported_scope_key, atom()}}.
-type artifact_summary() :: #{
    artifact_id := binary(),
    created_at := integer(),
    format := artifact_format(),
    kind := artifact_kind(),
    metadata := map(),
    source_refs := [source_ref()],
    title := binary(),
    updated_at := integer(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.
-type artifact_meta_map() :: #{
    created_at => integer(),
    id => binary(),
    payload => #{
        artifact := map(),
        operation := artifact_event_operation(),
        source_ref => map()
    },
    source_refs => [map()],
    tags => [artifact, ...],
    type => atom() | binary(),
    updated_at => integer(),
    artifact_id | body | format | kind | limit | metadata | run_id | session_id |
        since | source_ref_id | source_ref_type | thread_id | title => term()
}.

-type artifact_input() :: #{
    artifact_id => binary(),
    kind => artifact_kind(),
    title => binary(),
    body => term(),
    format => artifact_format(),
    source_refs => [source_ref()],
    metadata => map(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type artifact_filter() :: beam_agent_artifacts_store:artifact_filter().
-type artifact() :: beam_agent_artifacts_store:artifact_record().

-type normalized_scope() :: #{
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type normalized_input() :: #{
    artifact_id => binary(),
    kind := artifact_kind(),
    title => binary(),
    body => term(),
    format := artifact_format(),
    source_refs := [source_ref()],
    metadata := map(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-doc "Ensure the artifacts ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_artifacts_store:ensure_tables().

-doc "Clear all artifacts. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_artifacts_store:clear().

-doc """
Insert or update an artifact.

Scope can be embedded directly in the artifact map.
""".
-spec put(artifact_input()) ->
    {ok, artifact()} |
    {error, run_not_found | inconsistent_run_scope | session_id_required_for_thread |
        {unsupported_artifact_key, atom()} | {invalid_artifact, atom()}}.
put(Artifact) when is_map(Artifact) ->
    ?MODULE:put(#{}, Artifact).

-doc """
Insert or update an artifact with explicit scope.

Scope may be:
  - a binary session id
  - a map containing `session_id`, `thread_id`, and/or `run_id`
""".
-spec put(scope(), artifact_input()) ->
    {ok, artifact()} |
    {error, run_not_found | inconsistent_run_scope | session_id_required_for_thread |
        {unsupported_scope_key, atom()} | {unsupported_artifact_key, atom()} |
        {invalid_scope, atom()} | {invalid_artifact, atom()}}.
put(Scope, Artifact) when (is_binary(Scope) orelse is_map(Scope)), is_map(Artifact) ->
    ensure_tables(),
    TeleMeta = maps:merge(telemetry_scope_meta(Scope),
        telemetry_artifact_request_meta(Artifact)),
    StartTime = telemetry_start(put, TeleMeta),
    Result = case normalize_scope(Scope) of
        {ok, Scope1} ->
            Merged = maps:merge(Artifact, Scope1),
            case normalize_artifact(Merged) of
                {ok, Normalized} ->
                    Now = erlang:system_time(millisecond),
                    ArtifactId = maps:get(artifact_id, Normalized, generate_artifact_id()),
                    case beam_agent_artifacts_store:get_artifact(ArtifactId) of
                        {ok, Existing} ->
                            CreatedAt = maps:get(created_at, Existing),
                            Stored = build_artifact_record(ArtifactId, Normalized, CreatedAt, Now),
                            ok = beam_agent_artifacts_store:put_artifact(Stored),
                            {ok, _Entry} = append_artifact_event(<<"artifact_updated">>, Stored, #{
                                operation => updated
                            }),
                            {ok, Stored, updated};
                        {error, not_found} ->
                            Stored = build_artifact_record(ArtifactId, Normalized, Now, Now),
                            ok = beam_agent_artifacts_store:put_artifact(Stored),
                            {ok, _Entry} = append_artifact_event(<<"artifact_created">>, Stored, #{
                                operation => created
                            }),
                            {ok, Stored, created}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    case Result of
        {ok, StoredArtifact, Operation} ->
            telemetry_stop(put, StartTime, (telemetry_artifact_meta(StoredArtifact))#{
                operation => Operation
            }),
            {ok, StoredArtifact};
        {error, _} = ErrorResult ->
            telemetry_exception(put, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc "Fetch an artifact by id.".
-spec get(binary()) -> {ok, artifact()} | {error, not_found}.
get(ArtifactId) when is_binary(ArtifactId) ->
    StartTime = telemetry_start(get, #{artifact_id => ArtifactId}),
    case beam_agent_artifacts_store:get_artifact(ArtifactId) of
        {ok, Artifact} = Result ->
            telemetry_stop(get, StartTime, (telemetry_artifact_meta(Artifact))#{found => true}),
            Result;
        {error, not_found} = Error ->
            telemetry_stop(get, StartTime, #{artifact_id => ArtifactId, found => false}),
            Error
    end.

-doc "List all artifacts without filters.".
-spec list() -> {ok, [artifact()]}.
list() ->
    list(#{}).

-doc "List artifacts with exact-match filters.".
-spec list(artifact_filter()) ->
    {ok, [artifact()]} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
list(Filter) when is_map(Filter) ->
    TeleMeta = telemetry_filter_meta(Filter),
    StartTime = telemetry_start(list, TeleMeta),
    case normalize_filter(Filter) of
        {ok, Normalized} ->
            case beam_agent_artifacts_store:list_artifacts(Normalized) of
                {ok, Artifacts} = Result ->
                    telemetry_stop(list, StartTime, TeleMeta#{result_count => length(Artifacts)}),
                    Result
            end;
        {error, _} = Error ->
            telemetry_exception(list, Error, TeleMeta),
            Error
    end.

-doc "Search artifacts by tokenized, case-insensitive title/body/metadata text.".
-spec search(binary()) -> {ok, [artifact()]}.
search(Query) when is_binary(Query) ->
    search(Query, #{}).

-spec search(binary(), artifact_filter()) ->
    {ok, [artifact()]} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
search(Query, Filter) when is_binary(Query), is_map(Filter) ->
    QueryText = string:trim(Query),
    LowerTokens = query_tokens(QueryText),
    TeleMeta = (telemetry_filter_meta(Filter))#{
        query_length => byte_size(Query),
        query_token_count => length(LowerTokens)
    },
    StartTime = telemetry_start(search, TeleMeta),
    case list(Filter) of
        {ok, Artifacts} ->
            case QueryText of
                <<>> ->
                    telemetry_stop(search, StartTime, TeleMeta#{result_count => length(Artifacts)}),
                    {ok, Artifacts};
                _ ->
                    Results = [Artifact || Artifact <- Artifacts,
                        artifact_matches_query(LowerTokens, Artifact)],
                    telemetry_stop(search, StartTime, TeleMeta#{result_count => length(Results)}),
                    {ok, Results}
            end;
        {error, _} = Error ->
            telemetry_exception(search, Error, TeleMeta),
            Error
    end.

-doc """
Attach a typed reference to an existing artifact.

Special handling exists for `session`, `thread`, and `run` references so the
artifact's dedicated scope fields stay aligned with its source refs.
""".
-spec attach(binary(), atom() | binary(), binary()) ->
    ok | {error, not_found | run_not_found | session_id_required_for_thread |
        inconsistent_run_scope | inconsistent_scope}.
attach(ArtifactId, RefType, RefId)
  when is_binary(ArtifactId), is_binary(RefId),
       (is_atom(RefType) orelse is_binary(RefType)) ->
    TeleMeta = #{
        artifact_id => ArtifactId,
        source_ref_id => RefId,
        source_ref_type => RefType
    },
    StartTime = telemetry_start(attach, TeleMeta),
    Result = case beam_agent_artifacts_store:get_artifact(ArtifactId) of
        {ok, Artifact} ->
            case normalize_source_ref(#{type => RefType, id => RefId}) of
                {ok, Ref} ->
                    Now = erlang:system_time(millisecond),
                    case apply_attachment(Artifact, Ref, Now) of
                        {ok, Updated} ->
                            ok = beam_agent_artifacts_store:put_artifact(Updated),
                            {ok, _Entry} = append_artifact_event(<<"artifact_attached">>, Updated, #{
                                source_ref => Ref
                            }),
                            {ok, Updated};
                        Error ->
                            Error
                    end;
                {error, _} ->
                    {error, inconsistent_scope}
            end;
        {error, not_found} ->
            {error, not_found}
    end,
    case Result of
        {ok, UpdatedArtifact} ->
            telemetry_stop(attach, StartTime,
                maps:merge(TeleMeta, telemetry_artifact_meta(UpdatedArtifact))),
            ok;
        {error, _} = ErrorResult ->
            telemetry_exception(attach, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc "Delete an artifact by id.".
-spec delete(binary()) -> ok | {error, not_found}.
delete(ArtifactId) when is_binary(ArtifactId) ->
    StartTime = telemetry_start(delete, #{artifact_id => ArtifactId}),
    Result = case beam_agent_artifacts_store:get_artifact(ArtifactId) of
        {ok, Artifact} ->
            ok = beam_agent_artifacts_store:delete_artifact(ArtifactId),
            {ok, _Entry} = append_artifact_event(<<"artifact_deleted">>, Artifact, #{
                operation => deleted
            }),
            {ok, Artifact};
        {error, not_found} ->
            {error, not_found}
    end,
    case Result of
        {ok, DeletedArtifact} ->
            telemetry_stop(delete, StartTime, (telemetry_artifact_meta(DeletedArtifact))#{
                operation => deleted
            }),
            ok;
        {error, _} = ErrorResult ->
            telemetry_exception(delete, ErrorResult, #{artifact_id => ArtifactId}),
            ErrorResult
    end.

-spec normalize_scope(scope()) ->
    {ok, normalized_scope()} |
    {error, run_not_found | inconsistent_run_scope |
        session_id_required_for_thread | {unsupported_scope_key, atom()} |
        {invalid_scope, atom()}}.
normalize_scope(SessionId) when is_binary(SessionId) ->
    {ok, #{session_id => SessionId}};
normalize_scope(Scope) when is_map(Scope) ->
    Allowed = [session_id, thread_id, run_id],
    case validate_allowed_keys(Scope, Allowed, unsupported_scope_key) of
        ok ->
            case normalize_optional_binary(session_id, Scope, invalid_scope) of
                {ok, SessionId} ->
                    case normalize_optional_binary(thread_id, Scope, invalid_scope) of
                        {ok, ThreadId} ->
                            case normalize_optional_binary(run_id, Scope, invalid_scope) of
                                {ok, RunId} ->
                                    resolve_scope(SessionId, ThreadId, RunId);
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec resolve_scope(binary() | undefined, binary() | undefined, binary() | undefined) ->
    {ok, normalized_scope()} |
    {error, run_not_found | inconsistent_run_scope | session_id_required_for_thread}.
resolve_scope(SessionId, ThreadId, undefined) ->
    case {SessionId, ThreadId} of
        {undefined, undefined} ->
            {ok, #{}};
        {undefined, _Thread} ->
            {error, session_id_required_for_thread};
        {_Session, undefined} ->
            {ok, #{session_id => SessionId}};
        {_Session, _Thread} ->
            {ok, #{session_id => SessionId, thread_id => ThreadId}}
    end;
resolve_scope(SessionId, ThreadId, RunId) ->
    case beam_agent_runs_core:get_run(RunId) of
        {ok, Run} ->
            ResolvedSessionId = maps:get(session_id, Run, undefined),
            ResolvedThreadId = maps:get(thread_id, Run, undefined),
            case consistent_scope(SessionId, ResolvedSessionId)
                 andalso consistent_scope(ThreadId, ResolvedThreadId) of
                true ->
                    Scope0 = #{run_id => RunId},
                    Scope1 = maybe_put(session_id,
                        choose_scope(SessionId, ResolvedSessionId), Scope0),
                    {ok, maybe_put(thread_id,
                        choose_scope(ThreadId, ResolvedThreadId), Scope1)};
                false ->
                    {error, inconsistent_run_scope}
            end;
        {error, not_found} ->
            {error, run_not_found}
    end.

-spec normalize_artifact(map()) ->
    {ok, normalized_input()} |
    {error, run_not_found | inconsistent_run_scope |
        session_id_required_for_thread | {unsupported_artifact_key, atom()} |
        {invalid_scope, atom()} | {invalid_artifact, atom()}}.
normalize_artifact(Artifact) ->
    Allowed = [artifact_id, kind, title, body, format, source_refs, metadata,
               session_id, thread_id, run_id],
    case validate_allowed_keys(Artifact, Allowed, unsupported_artifact_key) of
        ok ->
            case normalize_optional_binary(artifact_id, Artifact, invalid_artifact) of
                {ok, ArtifactId} ->
                    case normalize_kind(kind, maps:get(kind, Artifact, generic), invalid_artifact) of
                        {ok, Kind} ->
                            case normalize_optional_binary(title, Artifact, invalid_artifact) of
                                {ok, Title} ->
                                    case normalize_kind(format, maps:get(format, Artifact, plain_text),
                                               invalid_artifact) of
                                        {ok, Format} ->
                                            case normalize_source_refs(Artifact) of
                                                {ok, SourceRefs} ->
                                                    case normalize_metadata(Artifact) of
                                                        {ok, Metadata} ->
                                                            ScopeInput = maps:with(
                                                                [session_id, thread_id, run_id],
                                                                Artifact),
                                                            case normalize_scope(ScopeInput) of
                                                                {ok, Scope} ->
                                                                    Normalized0 = #{
                                                                        kind => Kind,
                                                                        format => Format,
                                                                        source_refs => SourceRefs,
                                                                        metadata => Metadata
                                                                    },
                                                                    Normalized1 =
                                                                        maybe_put(artifact_id,
                                                                            ArtifactId, Normalized0),
                                                                    Normalized2 =
                                                                        maybe_put(title, Title,
                                                                            Normalized1),
                                                                    Normalized3 =
                                                                        maybe_put(body,
                                                                            maps:get(body, Artifact,
                                                                                undefined),
                                                                            Normalized2),
                                                                    {ok, maps:merge(Normalized3, Scope)};
                                                                Error ->
                                                                    Error
                                                            end;
                                                        Error ->
                                                            Error
                                                    end;
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec normalize_filter(map()) ->
    {ok, artifact_filter()} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
normalize_filter(Filter) ->
    Allowed = [artifact_id, kind, format, title, session_id, thread_id, run_id,
               source_ref_type, source_ref_id, limit, since],
    case validate_allowed_keys(Filter, Allowed, unsupported_filter) of
        ok ->
            case normalize_optional_binary(artifact_id, Filter, invalid_filter) of
                {ok, ArtifactId} ->
                    case normalize_optional_kind(Filter, kind) of
                        {ok, Kind} ->
                            case normalize_optional_kind(Filter, format) of
                                {ok, Format} ->
                                    case normalize_optional_binary(title, Filter, invalid_filter) of
                                        {ok, Title} ->
                                            case normalize_optional_binary(session_id, Filter,
                                                       invalid_filter) of
                                                {ok, SessionId} ->
                                                    case normalize_optional_binary(thread_id, Filter,
                                                               invalid_filter) of
                                                        {ok, ThreadId} ->
                                                            case normalize_optional_binary(run_id,
                                                                       Filter, invalid_filter) of
                                                                {ok, RunId} ->
                                                                    case normalize_optional_ref_type(
                                                                               Filter) of
                                                                        {ok, RefType} ->
                                                                            case normalize_optional_binary(
                                                                                       source_ref_id,
                                                                                       Filter,
                                                                                       invalid_filter) of
                                                                                {ok, RefId} ->
                                                                                    case normalize_limit(
                                                                                               Filter) of
                                                                                        {ok, Limit} ->
                                                                                            case normalize_since(
                                                                                                       Filter) of
                                                                                                {ok, Since} ->
                                                                                                    Normalized0 = #{},
                                                                                                    Normalized1 = maybe_put(
                                                                                                        artifact_id,
                                                                                                        ArtifactId,
                                                                                                        Normalized0),
                                                                                                    Normalized2 = maybe_put(
                                                                                                        kind, Kind,
                                                                                                        Normalized1),
                                                                                                    Normalized3 = maybe_put(
                                                                                                        format, Format,
                                                                                                        Normalized2),
                                                                                                    Normalized4 = maybe_put(
                                                                                                        title, Title,
                                                                                                        Normalized3),
                                                                                                    Normalized5 = maybe_put(
                                                                                                        session_id,
                                                                                                        SessionId,
                                                                                                        Normalized4),
                                                                                                    Normalized6 = maybe_put(
                                                                                                        thread_id,
                                                                                                        ThreadId,
                                                                                                        Normalized5),
                                                                                                    Normalized7 = maybe_put(
                                                                                                        run_id, RunId,
                                                                                                        Normalized6),
                                                                                                    Normalized8 = maybe_put(
                                                                                                        source_ref_type,
                                                                                                        RefType,
                                                                                                        Normalized7),
                                                                                                    Normalized9 = maybe_put(
                                                                                                        source_ref_id,
                                                                                                        RefId,
                                                                                                        Normalized8),
                                                                                                    Normalized10 = maybe_put(
                                                                                                        since, Since,
                                                                                                        Normalized9),
                                                                                                    {ok, maybe_put(limit,
                                                                                                        Limit,
                                                                                                        Normalized10)};
                                                                                                Error ->
                                                                                                    Error
                                                                                            end;
                                                                                        Error ->
                                                                                            Error
                                                                                    end;
                                                                                Error ->
                                                                                    Error
                                                                            end;
                                                                        Error ->
                                                                            Error
                                                                    end;
                                                                Error ->
                                                                    Error
                                                            end;
                                                        Error ->
                                                            Error
                                                    end;
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec normalize_source_refs(map()) ->
    {ok, [source_ref()]} | {error, {invalid_artifact, source_refs}}.
normalize_source_refs(Artifact) ->
    case maps:get(source_refs, Artifact, []) of
        SourceRefs when is_list(SourceRefs) ->
            normalize_source_refs_list(SourceRefs, []);
        _Other ->
            {error, {invalid_artifact, source_refs}}
    end.

-spec normalize_source_refs_list([term()], [source_ref()]) ->
    {ok, [source_ref()]} | {error, {invalid_artifact, source_refs}}.
normalize_source_refs_list([], Acc) ->
    {ok, dedupe_source_refs(lists:reverse(Acc))};
normalize_source_refs_list([Ref | Rest], Acc) ->
    case normalize_source_ref(Ref) of
        {ok, NormalizedRef} ->
            normalize_source_refs_list(Rest, [NormalizedRef | Acc]);
        {error, _} ->
            {error, {invalid_artifact, source_refs}}
    end.

-spec normalize_source_ref(term()) -> {ok, source_ref()} | {error, invalid_source_ref}.
normalize_source_ref(#{type := RefType, id := RefId} = Ref) ->
    case normalize_ref_type(RefType) of
        {ok, Type1} ->
            case RefId of
                Id when is_binary(Id), byte_size(Id) > 0 ->
                    case maps:get(metadata, Ref, #{}) of
                        Metadata when is_map(Metadata) ->
                            {ok, maybe_put(metadata, Metadata, #{
                                type => Type1,
                                id => Id
                            })};
                        _Other ->
                            {error, invalid_source_ref}
                    end;
                _Other ->
                    {error, invalid_source_ref}
            end;
        {error, invalid_ref_type} ->
            {error, invalid_source_ref}
    end;
normalize_source_ref(_Other) ->
    {error, invalid_source_ref}.

-spec apply_attachment(artifact(), source_ref(), integer()) ->
    {ok, artifact()} |
    {error, run_not_found | session_id_required_for_thread |
        inconsistent_run_scope | inconsistent_scope}.
apply_attachment(Artifact, #{type := session, id := SessionId} = Ref, Now) ->
    case consistent_scope(maps:get(session_id, Artifact, undefined), SessionId) of
        true ->
            {ok, updated_artifact(Artifact#{session_id => SessionId}, Ref, Now)};
        false ->
            {error, inconsistent_scope}
    end;
apply_attachment(Artifact, #{type := <<"session">>, id := _SessionId} = Ref, Now) ->
    apply_attachment(Artifact, Ref#{type => session}, Now);
apply_attachment(Artifact, #{type := thread, id := ThreadId} = Ref, Now) ->
    case maps:get(session_id, Artifact, undefined) of
        undefined ->
            {error, session_id_required_for_thread};
        _SessionId ->
            case consistent_scope(maps:get(thread_id, Artifact, undefined), ThreadId) of
                true ->
                    {ok, updated_artifact(Artifact#{thread_id => ThreadId}, Ref, Now)};
                false ->
                    {error, inconsistent_scope}
            end
    end;
apply_attachment(Artifact, #{type := <<"thread">>, id := ThreadId} = Ref, Now) ->
    apply_attachment(Artifact, Ref#{type => thread, id => ThreadId}, Now);
apply_attachment(Artifact, #{type := run, id := RunId} = Ref, Now) ->
    case beam_agent_runs_core:get_run(RunId) of
        {ok, Run} ->
            RunSessionId = maps:get(session_id, Run, undefined),
            RunThreadId = maps:get(thread_id, Run, undefined),
            case consistent_scope(maps:get(run_id, Artifact, undefined), RunId)
                 andalso consistent_scope(maps:get(session_id, Artifact, undefined), RunSessionId)
                 andalso consistent_scope(maps:get(thread_id, Artifact, undefined), RunThreadId) of
                true ->
                    Artifact1 = maybe_put(session_id, RunSessionId,
                        maybe_put(thread_id, RunThreadId, Artifact#{run_id => RunId})),
                    {ok, updated_artifact(Artifact1, Ref, Now)};
                false ->
                    {error, inconsistent_run_scope}
            end;
        {error, not_found} ->
            {error, run_not_found}
    end;
apply_attachment(Artifact, #{type := <<"run">>, id := RunId} = Ref, Now) ->
    apply_attachment(Artifact, Ref#{type => run, id => RunId}, Now);
apply_attachment(Artifact, Ref, Now) ->
    {ok, updated_artifact(Artifact, Ref, Now)}.

-spec updated_artifact(artifact(), source_ref(), integer()) -> artifact().
updated_artifact(Artifact, Ref, Now) ->
    SourceRefs = dedupe_source_refs([Ref | maps:get(source_refs, Artifact, [])]),
    Artifact#{
        source_refs => SourceRefs,
        updated_at => Now
    }.

-spec build_artifact_record(binary(), normalized_input(), integer(), integer()) -> artifact().
build_artifact_record(ArtifactId, Artifact, CreatedAt, UpdatedAt) ->
    Title = maps:get(title, Artifact, ArtifactId),
    Body = maps:get(body, Artifact, <<>>),
    Base = #{
        artifact_id => ArtifactId,
        kind => maps:get(kind, Artifact),
        title => Title,
        body => Body,
        format => maps:get(format, Artifact),
        source_refs => canonical_source_refs(Artifact),
        metadata => maps:get(metadata, Artifact),
        created_at => CreatedAt,
        updated_at => UpdatedAt
    },
    Base1 = maybe_put(session_id, maps:get(session_id, Artifact, undefined), Base),
    Base2 = maybe_put(thread_id, maps:get(thread_id, Artifact, undefined), Base1),
    maybe_put(run_id, maps:get(run_id, Artifact, undefined), Base2).

-spec canonical_source_refs(normalized_input()) -> [source_ref()].
canonical_source_refs(Artifact) ->
    SourceRefs = maps:get(source_refs, Artifact),
    SourceRefs1 = case maps:get(session_id, Artifact, undefined) of
        undefined -> SourceRefs;
        SessionId -> [#{type => session, id => SessionId} | SourceRefs]
    end,
    SourceRefs2 = case maps:get(thread_id, Artifact, undefined) of
        undefined -> SourceRefs1;
        ThreadId -> [#{type => thread, id => ThreadId} | SourceRefs1]
    end,
    SourceRefs3 = case maps:get(run_id, Artifact, undefined) of
        undefined -> SourceRefs2;
        RunId -> [#{type => run, id => RunId} | SourceRefs2]
    end,
    dedupe_source_refs(SourceRefs3).

-spec dedupe_source_refs([source_ref()]) -> [source_ref()].
dedupe_source_refs(SourceRefs) ->
    lists:reverse(lists:foldl(fun(Ref, Acc) ->
        case has_exact_source_ref(Ref, Acc) of
            true -> Acc;
            false -> [Ref | Acc]
        end
    end, [], SourceRefs)).

-spec has_exact_source_ref(source_ref(), [source_ref()]) -> boolean().
has_exact_source_ref(#{type := RefType, id := RefId}, SourceRefs) ->
    lists:any(fun
        (#{type := Type, id := Id}) -> Type =:= RefType andalso Id =:= RefId;
        (_) -> false
    end, SourceRefs).

-spec artifact_matches_query([binary()], artifact()) -> boolean().
artifact_matches_query(Tokens, Artifact) ->
    Haystack = lower_binary(iolist_to_binary([
        normalize_text(maps:get(kind, Artifact, generic)),
        <<"\n">>,
        maps:get(title, Artifact, <<>>),
        <<"\n">>,
        normalize_text(maps:get(body, Artifact, <<>>)),
        <<"\n">>,
        normalize_text(maps:get(metadata, Artifact, #{}))
    ])),
    lists:all(fun(Token) ->
        binary:match(Haystack, Token) =/= nomatch
    end, Tokens).

-spec query_tokens(binary()) -> [binary()].
query_tokens(Query) ->
    [Token || Token <- binary:split(lower_binary(Query), <<" ">>, [global, trim_all]),
        Token =/= <<>>].

-spec lower_binary(binary()) -> binary().
lower_binary(Bin) ->
    string:lowercase(Bin).

-spec normalize_text(term()) -> binary().
normalize_text(Bin) when is_binary(Bin) ->
    Bin;
normalize_text(List) when is_list(List) ->
    try unicode:characters_to_binary(List) of
        Binary -> Binary
    catch
        _:_ ->
            iolist_to_binary(io_lib:format("~0tp", [List]))
    end;
normalize_text(Term) ->
    iolist_to_binary(io_lib:format("~0tp", [Term])).

-spec validate_allowed_keys(map(), [atom()], atom()) -> ok | {error, {atom(), atom()}}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case [Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)] of
        [] -> ok;
        [BadKey | _] -> {error, {ErrorTag, BadKey}}
    end.

-spec normalize_optional_binary(optional_binary_key(), map(), artifact_error_tag()) ->
    {ok, binary() | undefined} | {error, {artifact_error_tag(), optional_binary_key()}}.
normalize_optional_binary(Key, Map, ErrorTag) ->
    case maps:find(Key, Map) of
        error ->
            {ok, undefined};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 ->
            {ok, Value};
        {ok, _Other} ->
            {error, {ErrorTag, Key}}
    end.

-spec normalize_kind(kind_key(), term(), invalid_artifact | invalid_filter) ->
    {ok, atom() | binary()} | {error, {invalid_artifact | invalid_filter, kind_key()}}.
normalize_kind(_Key, Value, _ErrorTag) when is_atom(Value) ->
    {ok, Value};
normalize_kind(_Key, Value, _ErrorTag) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_kind(Key, _Value, ErrorTag) ->
    {error, {ErrorTag, Key}}.

-spec normalize_metadata(map()) -> {ok, map()} | {error, {invalid_artifact, metadata}}.
normalize_metadata(Artifact) ->
    case maps:get(metadata, Artifact, #{}) of
        Metadata when is_map(Metadata) ->
            {ok, Metadata};
        _Other ->
            {error, {invalid_artifact, metadata}}
    end.

-spec normalize_optional_kind(map(), atom()) ->
    {ok, atom() | binary() | undefined} | {error, {invalid_filter, atom()}}.
normalize_optional_kind(Filter, Key) ->
    case maps:find(Key, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} ->
            normalize_kind(Key, Value, invalid_filter)
    end.

-spec normalize_optional_ref_type(map()) ->
    {ok, atom() | binary() | undefined} | {error, {invalid_filter, source_ref_type}}.
normalize_optional_ref_type(Filter) ->
    case maps:find(source_ref_type, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} ->
            case normalize_ref_type(Value) of
                {ok, Type} -> {ok, Type};
                {error, invalid_ref_type} -> {error, {invalid_filter, source_ref_type}}
            end
    end.

-spec normalize_ref_type(term()) -> {ok, atom() | binary()} | {error, invalid_ref_type}.
normalize_ref_type(Value) when is_atom(Value) ->
    {ok, Value};
normalize_ref_type(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_ref_type(_Value) ->
    {error, invalid_ref_type}.

-spec normalize_limit(map()) ->
    {ok, pos_integer() | undefined} | {error, {invalid_filter, limit}}.
normalize_limit(Filter) ->
    case maps:find(limit, Filter) of
        error ->
            {ok, undefined};
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            {ok, Limit};
        {ok, _Other} ->
            {error, {invalid_filter, limit}}
    end.

-spec normalize_since(map()) ->
    {ok, integer() | undefined} | {error, {invalid_filter, since}}.
normalize_since(Filter) ->
    case maps:find(since, Filter) of
        error ->
            {ok, undefined};
        {ok, Since} when is_integer(Since) ->
            {ok, Since};
        {ok, _Other} ->
            {error, {invalid_filter, since}}
    end.

-spec append_artifact_event(<<_:64, _:_*8>>, artifact(), artifact_event_payload()) ->
    {ok, beam_agent_journal_core:entry()} | {error, journal_error()}.
append_artifact_event(EventType, Artifact, ExtraPayload) ->
    Event0 = #{
        tags => [artifact],
        payload => maps:merge(artifact_journal_payload(Artifact), ExtraPayload)
    },
    Event1 = maybe_put(session_id, maps:get(session_id, Artifact, undefined), Event0),
    Event2 = maybe_put(thread_id, maps:get(thread_id, Artifact, undefined), Event1),
    Event3 = maybe_put(run_id, maps:get(run_id, Artifact, undefined), Event2),
    beam_agent_journal_core:append(EventType, Event3).

-spec artifact_journal_payload(artifact()) -> #{artifact := artifact_summary()}.
artifact_journal_payload(Artifact) ->
    #{artifact => artifact_summary(Artifact)}.

-spec artifact_summary(artifact()) -> artifact_summary().
artifact_summary(Artifact) ->
    maps:remove(body, Artifact).

-spec telemetry_start(artifact_operation(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry_core:span_start(artifact, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(artifact_operation(), integer(), map()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry_core:span_stop(artifact, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(put | list | search | attach | delete, artifact_exception(), map()) ->
    ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry_core:span_exception(artifact, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_scope_meta(scope()) -> map().
telemetry_scope_meta(SessionId) when is_binary(SessionId) ->
    #{session_id => SessionId};
telemetry_scope_meta(Scope) when is_map(Scope) ->
    maps:with([session_id, thread_id, run_id], Scope).

-spec telemetry_artifact_request_meta(map()) -> map().
telemetry_artifact_request_meta(Artifact) ->
    maps:with([artifact_id, kind, format, session_id, thread_id, run_id], Artifact).

-spec telemetry_filter_meta(map()) -> map().
telemetry_filter_meta(Filter) ->
    maps:with([artifact_id, kind, format, session_id, thread_id, run_id, limit], Filter).

-spec telemetry_artifact_meta(artifact()) -> map().
telemetry_artifact_meta(Artifact) ->
    maps:with([artifact_id, kind, format, session_id, thread_id, run_id], Artifact).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).

-spec maybe_put(artifact_id | body | format | kind | limit | metadata | run_id |
    session_id | since | source_ref_id | source_ref_type | thread_id | title,
    term(), artifact_meta_map()) -> artifact_meta_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec consistent_scope(binary() | undefined, binary() | undefined) -> boolean().
consistent_scope(undefined, _Value) -> true;
consistent_scope(_Value, undefined) -> true;
consistent_scope(Value, Value) -> true;
consistent_scope(_Left, _Right) -> false.

-spec choose_scope(binary() | undefined, binary() | undefined) -> binary() | undefined.
choose_scope(undefined, Value) -> Value;
choose_scope(Value, _Fallback) -> Value.

-spec generate_artifact_id() -> <<_:64, _:_*8>>.
generate_artifact_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<"artifact_", Hex/binary>>.
