-module(beam_agent_memory_core).
-moduledoc """
Canonical long-term memory primitives for BeamAgent.

The memory subsystem is deliberately process-free. Records live in the
configured store adapter, defaulting to ETS through `beam_agent_store_ets`.
This module owns:

- scope validation and inference
- lexical search and recall ranking
- TTL/expiry semantics
- journaling for lifecycle-changing memory operations

It does not introduce assistant-product policy such as workspace ranking or
persona-specific salience. Those remain the concern of higher-order consumers
such as MonkeyClaw.
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
    pin/1,
    unpin/1,
    expire/0,
    expire/1
]).

-export_type([
    scope/0,
    source_ref/0,
    memory_input/0,
    memory_filter/0,
    memory_record/0
]).

-type scope() :: beam_agent_memory_store:scope().
-type source_ref() :: beam_agent_memory_store:source_ref().
-type memory_record() :: beam_agent_memory_store:memory_record().
-type memory_kind() :: atom() | binary().
-type ttl() :: non_neg_integer() | infinity.

-type memory_input() :: binary() | #{
    memory_id => binary(),
    kind => memory_kind(),
    content => term(),
    attributes => map(),
    source_refs => [source_ref()],
    ttl => ttl(),
    pinned => boolean(),
    salience => non_neg_integer(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
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
    since => integer(),
    include_expired => boolean(),
    min_salience => non_neg_integer(),
    before => integer()
}.

-doc "Ensure the memory store exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_memory_store:ensure_tables().

-doc "Clear all memory records. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_memory_store:clear().

-doc "Remember content with embedded or explicit kind on a scope.".
-spec remember(binary() | scope(), memory_input()) ->
    {ok, memory_record()} | {error, term()}.
remember(ScopeInput, MemoryInput) ->
    case normalize_memory_input(undefined, MemoryInput) of
        {ok, Input, EmbeddedScope} ->
            remember_normalized(ScopeInput, EmbeddedScope, Input);
        {error, _} = Error ->
            Error
    end.

-doc "Remember content with an explicit kind on a scope.".
-spec remember(binary() | scope(), memory_kind(), memory_input()) ->
    {ok, memory_record()} | {error, term()}.
remember(ScopeInput, Kind, MemoryInput) when is_atom(Kind); is_binary(Kind) ->
    case normalize_kind(kind, Kind, invalid_memory) of
        {ok, NormalizedKind} ->
            case normalize_memory_input(NormalizedKind, MemoryInput) of
                {ok, Input, EmbeddedScope} ->
                    remember_normalized(ScopeInput, EmbeddedScope, Input);
                {error, _} = Error ->
                    Error
            end;
        {error, _Reason} ->
            {error, {invalid_memory, kind}}
    end.

-doc "Fetch a memory record by id.".
-spec get(binary()) -> {ok, memory_record()} | {error, not_found}.
get(MemoryId) when is_binary(MemoryId) ->
    beam_agent_memory_store:get_memory(MemoryId).

-doc "List all non-expired memories.".
-spec list() -> {ok, [memory_record()]}.
list() ->
    list(#{}).

-doc "List memories with exact-match filters and optional visibility controls.".
-spec list(memory_filter()) -> {ok, [memory_record()]} | {error, term()}.
list(FilterInput) when is_map(FilterInput) ->
    case normalize_filter(FilterInput) of
        {ok, Normalized} ->
            do_list(Normalized);
        {error, _} = Error ->
            Error
    end.

-doc "Recall memories for a scope using lexical search.".
-spec recall(binary() | scope(), binary()) ->
    {ok, [memory_record()]} | {error, term()}.
recall(ScopeInput, Query) when is_binary(Query) ->
    case normalize_scope_filter(ScopeInput) of
        {ok, ScopeFilter} ->
            search(Query, ScopeFilter);
        {error, _} = Error ->
            Error
    end.

-doc "Search memories across all scopes.".
-spec search(binary()) -> {ok, [memory_record()]} | {error, term()}.
search(Query) when is_binary(Query) ->
    search(Query, #{}).

-doc "Search memories with a lexical query plus exact-match filters.".
-spec search(binary(), memory_filter()) ->
    {ok, [memory_record()]} | {error, term()}.
search(Query, FilterInput) when is_binary(Query), is_map(FilterInput) ->
    case normalize_filter(FilterInput) of
        {ok, Normalized} ->
            do_search(Query, Normalized);
        {error, _} = Error ->
            Error
    end.

-doc "Forget a memory by id.".
-spec forget(binary()) -> ok | {error, not_found}.
forget(MemoryId) when is_binary(MemoryId) ->
    case beam_agent_memory_store:get_memory(MemoryId) of
        {ok, Memory} ->
            ok = beam_agent_memory_store:delete_memory(MemoryId),
            {ok, _Entry} = append_memory_event(<<"memory_forgotten">>, Memory, #{}),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Pin a memory to keep it visible regardless of TTL expiry.".
-spec pin(binary()) -> ok | {error, not_found}.
pin(MemoryId) when is_binary(MemoryId) ->
    update_pinned(MemoryId, true, <<"memory_pinned">>).

-doc "Unpin a memory.".
-spec unpin(binary()) -> ok | {error, not_found}.
unpin(MemoryId) when is_binary(MemoryId) ->
    update_pinned(MemoryId, false, <<"memory_unpinned">>).

-doc "Expire all currently expired, unpinned memories.".
-spec expire() -> {ok, non_neg_integer()}.
expire() ->
    expire(#{}).

-doc "Expire currently expired, unpinned memories matching a filter.".
-spec expire(memory_filter()) -> {ok, non_neg_integer()} | {error, term()}.
expire(FilterInput) when is_map(FilterInput) ->
    case normalize_filter(FilterInput) of
        {ok, Normalized} ->
            Now = maps:get(before, Normalized, current_time_ms()),
            BaseFilter = maps:remove(before, maps:remove(limit, Normalized)),
            {ok, Memories0} = do_list(maps:put(include_expired, true, BaseFilter)),
            Expirable = [Memory || Memory <- Memories0,
                memory_should_expire(Memory, Now)],
            lists:foreach(fun(Memory) ->
                ok = beam_agent_memory_store:delete_memory(maps:get(memory_id, Memory)),
                {ok, _Entry} = append_memory_event(<<"memory_expired">>, Memory, #{
                    before => Now
                })
            end, Expirable),
            {ok, length(Expirable)};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec remember_normalized(binary() | scope(), scope(), map()) ->
    {ok, memory_record()} | {error, term()}.
remember_normalized(ScopeInput, EmbeddedScope, Input) ->
    case normalize_scope_input(ScopeInput) of
        {ok, ExplicitScope} ->
            case merge_scopes(ExplicitScope, EmbeddedScope) of
                {ok, Scope0} ->
                    SourceRefs = maps:get(source_refs, Input, []),
                    case resolve_scope(Scope0, SourceRefs) of
                        {ok, Scope} ->
                            Now = current_time_ms(),
                            Memory = #{
                                memory_id => maps:get(memory_id, Input, generate_memory_id()),
                                kind => maps:get(kind, Input),
                                content => maps:get(content, Input),
                                attributes => maps:get(attributes, Input, #{}),
                                source_refs => SourceRefs,
                                scope => Scope,
                                pinned => maps:get(pinned, Input, false),
                                salience => maps:get(salience, Input, 0),
                                ttl => maps:get(ttl, Input, infinity),
                                created_at => Now,
                                updated_at => Now
                            },
                            Memory2 = maybe_put(expires_at, expires_at(Memory, Now), Memory),
                            ok = beam_agent_memory_store:put_memory(Memory2),
                            {ok, _Entry} = append_memory_event(<<"memory_remembered">>,
                                Memory2, #{}),
                            {ok, Memory2};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec do_list(memory_filter()) -> {ok, [memory_record()]}.
do_list(Filter) ->
    StoreFilter = store_filter(Filter),
    IncludeExpired = maps:get(include_expired, Filter, false),
    MinSalience = maps:get(min_salience, Filter, 0),
    Limit = maps:get(limit, Filter, infinity),
    Now = current_time_ms(),
    {ok, Memories0} = beam_agent_memory_store:list_memories(StoreFilter),
    Memories1 = [Memory || Memory <- Memories0,
        memory_visible(Memory, IncludeExpired, Now),
        maps:get(salience, Memory, 0) >= MinSalience],
    {ok, maybe_limit(Memories1, Limit)}.

-spec do_search(binary(), memory_filter()) -> {ok, [memory_record()]}.
do_search(Query, Filter) ->
    {ok, Memories0} = do_list(maps:remove(limit, Filter)),
    Tokens = tokenize(Query),
    Limit = maps:get(limit, Filter, infinity),
    Memories = case Tokens of
        [] ->
            maybe_limit(Memories0, Limit);
        _ ->
            Scored = [{search_sort_key(score_memory(Tokens, Memory), Memory), Memory}
                || Memory <- Memories0,
                   score_memory(Tokens, Memory) > 0],
            Sorted = lists:sort(fun({KeyA, _}, {KeyB, _}) -> KeyA =< KeyB end,
                Scored),
            maybe_limit([Memory || {_, Memory} <- Sorted], Limit)
    end,
    {ok, Memories}.

-spec update_pinned(binary(), boolean(), binary()) -> ok | {error, not_found}.
update_pinned(MemoryId, DesiredPinned, EventType) ->
    case beam_agent_memory_store:get_memory(MemoryId) of
        {ok, Memory} ->
            case maps:get(pinned, Memory, false) of
                DesiredPinned ->
                    ok;
                _ ->
                    Updated = Memory#{
                        pinned => DesiredPinned,
                        updated_at => current_time_ms()
                    },
                    ok = beam_agent_memory_store:put_memory(Updated),
                    {ok, _Entry} = append_memory_event(EventType, Updated, #{}),
                    ok
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-spec normalize_scope_input(binary() | scope()) -> {ok, scope()} | {error, term()}.
normalize_scope_input(SessionId) when is_binary(SessionId) ->
    {ok, #{session_id => SessionId}};
normalize_scope_input(Scope) when is_map(Scope) ->
    Scope0 = maps:with([session_id, thread_id, run_id], Scope),
    case normalize_optional_binary_value(session_id, maps:get(session_id, Scope0, undefined),
             invalid_scope) of
        {ok, SessionId} ->
            case normalize_optional_binary_value(thread_id,
                     maps:get(thread_id, Scope0, undefined), invalid_scope) of
                {ok, ThreadId} ->
                    case normalize_optional_binary_value(run_id,
                             maps:get(run_id, Scope0, undefined), invalid_scope) of
                        {ok, RunId} ->
                            Scope1 = maybe_put(session_id, SessionId, #{}),
                            Scope2 = maybe_put(thread_id, ThreadId, Scope1),
                            Scope3 = maybe_put(run_id, RunId, Scope2),
                            validate_scope(Scope3);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
normalize_scope_input(_) ->
    {error, invalid_scope}.

-spec normalize_scope_filter(binary() | scope()) -> {ok, memory_filter()} | {error, term()}.
normalize_scope_filter(ScopeInput) ->
    case normalize_scope_input(ScopeInput) of
        {ok, Scope} ->
            {ok, maps:with([session_id, thread_id, run_id], Scope)};
        {error, _} = Error ->
            Error
    end.

-spec normalize_memory_input(memory_kind() | undefined, memory_input()) ->
    {ok, map(), scope()} | {error, term()}.
normalize_memory_input(KindOverride, Input) when is_binary(Input) ->
    normalize_memory_input(KindOverride, #{content => Input});
normalize_memory_input(KindOverride, Input) when is_map(Input) ->
    EmbeddedScope0 = maps:with([session_id, thread_id, run_id], Input),
    case normalize_scope_input(maps:merge(#{}, EmbeddedScope0)) of
        {ok, EmbeddedScope} ->
            do_normalize_memory_input(KindOverride, Input, EmbeddedScope);
        {error, invalid_scope} ->
            {error, invalid_scope};
        {error, _} = Error ->
            Error
    end;
normalize_memory_input(_KindOverride, _Input) ->
    {error, invalid_memory}.

-spec do_normalize_memory_input(memory_kind() | undefined, map(), scope()) ->
    {ok, map(), scope()} | {error, term()}.
do_normalize_memory_input(KindOverride, Input, EmbeddedScope) ->
    case normalize_memory_id(maps:get(memory_id, Input, undefined)) of
        {ok, MemoryId} ->
            case normalize_kind_value(KindOverride, maps:get(kind, Input, undefined)) of
                {ok, Kind} ->
                    case normalize_content(maps:get(content, Input, undefined)) of
                        {ok, Content} ->
                            case normalize_attributes(maps:get(attributes, Input, #{})) of
                                {ok, Attributes} ->
                                    case normalize_source_refs(maps:get(source_refs, Input, [])) of
                                        {ok, SourceRefs} ->
                                            case normalize_ttl(maps:get(ttl, Input, infinity)) of
                                                {ok, Ttl} ->
                                                    case normalize_pinned(
                                                             maps:get(pinned, Input, false)) of
                                                        {ok, Pinned} ->
                                                            case normalize_salience(
                                                                     maps:get(salience, Input, 0)) of
                                                                {ok, Salience} ->
                                                                    Normalized0 = #{
                                                                        kind => Kind,
                                                                        content => Content,
                                                                        attributes => Attributes,
                                                                        source_refs => SourceRefs,
                                                                        ttl => Ttl,
                                                                        pinned => Pinned,
                                                                        salience => Salience
                                                                    },
                                                                    Normalized = maybe_put(
                                                                        memory_id, MemoryId,
                                                                        Normalized0),
                                                                    {ok, Normalized, EmbeddedScope};
                                                                {error, _} = Error ->
                                                                    Error
                                                            end;
                                                        {error, _} = Error ->
                                                            Error
                                                    end;
                                                {error, _} = Error ->
                                                    Error
                                            end;
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_memory_id(term()) -> {ok, binary() | undefined} | {error, term()}.
normalize_memory_id(undefined) ->
    {ok, undefined};
normalize_memory_id(MemoryId) when is_binary(MemoryId), byte_size(MemoryId) > 0 ->
    {ok, MemoryId};
normalize_memory_id(_Other) ->
    {error, {invalid_memory, memory_id}}.

-spec normalize_kind_value(memory_kind() | undefined, term()) ->
    {ok, memory_kind()} | {error, term()}.
normalize_kind_value(undefined, undefined) ->
    {ok, note};
normalize_kind_value(undefined, Kind) ->
    case normalize_kind(kind, Kind, invalid_memory) of
        {ok, NormalizedKind} -> {ok, NormalizedKind};
        {error, _} -> {error, {invalid_memory, kind}}
    end;
normalize_kind_value(KindOverride, _Other) ->
    {ok, KindOverride}.

-spec normalize_content(term()) -> {ok, term()} | {error, {invalid_memory, content}}.
normalize_content(undefined) ->
    {error, {invalid_memory, content}};
normalize_content(Content) ->
    {ok, Content}.

-spec normalize_attributes(term()) -> {ok, map()} | {error, {invalid_memory, attributes}}.
normalize_attributes(Attributes) when is_map(Attributes) ->
    {ok, Attributes};
normalize_attributes(_Other) ->
    {error, {invalid_memory, attributes}}.

-spec normalize_source_refs(term()) -> {ok, [source_ref()]} | {error, term()}.
normalize_source_refs(SourceRefs) when is_list(SourceRefs) ->
    lists:foldl(fun
        (_Ref, {error, _} = Error) ->
            Error;
        (Ref, {ok, Acc}) ->
            case normalize_source_ref(Ref) of
                {ok, Normalized} -> {ok, Acc ++ [Normalized]};
                {error, _} = Error -> Error
            end
    end, {ok, []}, SourceRefs);
normalize_source_refs(_Other) ->
    {error, {invalid_memory, source_refs}}.

-spec normalize_source_ref(term()) -> {ok, source_ref()} | {error, term()}.
normalize_source_ref(#{type := Type, id := Id} = Ref)
  when is_binary(Id), byte_size(Id) > 0 ->
    case normalize_ref_type(Type) of
        {ok, RefType} ->
            case maps:get(metadata, Ref, #{}) of
                Metadata when is_map(Metadata) ->
                    {ok, #{
                        type => RefType,
                        id => Id,
                        metadata => Metadata
                    }};
                _Other ->
                    {error, {invalid_memory, source_refs}}
            end;
        {error, invalid_ref_type} ->
            {error, {invalid_memory, source_refs}}
    end;
normalize_source_ref(_) ->
    {error, {invalid_memory, source_refs}}.

-spec normalize_ttl(term()) -> {ok, ttl()} | {error, {invalid_memory, ttl}}.
normalize_ttl(infinity) ->
    {ok, infinity};
normalize_ttl(Ttl) when is_integer(Ttl), Ttl >= 0 ->
    {ok, Ttl};
normalize_ttl(_Other) ->
    {error, {invalid_memory, ttl}}.

-spec normalize_pinned(term()) -> {ok, boolean()} | {error, {invalid_memory, pinned}}.
normalize_pinned(Pinned) when is_boolean(Pinned) ->
    {ok, Pinned};
normalize_pinned(_Other) ->
    {error, {invalid_memory, pinned}}.

-spec normalize_salience(term()) -> {ok, non_neg_integer()} |
    {error, {invalid_memory, salience}}.
normalize_salience(Salience) when is_integer(Salience), Salience >= 0 ->
    {ok, Salience};
normalize_salience(_Other) ->
    {error, {invalid_memory, salience}}.

-spec validate_scope(scope()) -> {ok, scope()} | {error, term()}.
validate_scope(#{thread_id := _ThreadId} = Scope)
  when not is_map_key(session_id, Scope) ->
    {error, session_id_required_for_thread};
validate_scope(Scope) ->
    {ok, Scope}.

-spec merge_scopes(scope(), scope()) -> {ok, scope()} | {error, term()}.
merge_scopes(Left, Right) ->
    SessionId = choose_scope(maps:get(session_id, Left, undefined),
        maps:get(session_id, Right, undefined)),
    ThreadId = choose_scope(maps:get(thread_id, Left, undefined),
        maps:get(thread_id, Right, undefined)),
    RunId = choose_scope(maps:get(run_id, Left, undefined),
        maps:get(run_id, Right, undefined)),
    case consistent_scope(maps:get(session_id, Left, undefined),
             maps:get(session_id, Right, undefined))
         andalso consistent_scope(maps:get(thread_id, Left, undefined),
             maps:get(thread_id, Right, undefined))
         andalso consistent_scope(maps:get(run_id, Left, undefined),
             maps:get(run_id, Right, undefined)) of
        true ->
            validate_scope(
                maybe_put(run_id, RunId,
                    maybe_put(thread_id, ThreadId,
                        maybe_put(session_id, SessionId, #{}))));
        false ->
            {error, inconsistent_scope}
    end.

-spec resolve_scope(scope(), [source_ref()]) -> {ok, scope()} | {error, term()}.
resolve_scope(Scope, SourceRefs) ->
    case resolve_run_scope(Scope) of
        {ok, Scope1} ->
            lists:foldl(fun
                (_Ref, {error, _} = Error) ->
                    Error;
                (Ref, {ok, AccScope}) ->
                    resolve_source_ref_scope(AccScope, Ref)
            end, {ok, Scope1}, SourceRefs);
        {error, _} = Error ->
            Error
    end.

-spec resolve_run_scope(scope()) -> {ok, scope()} | {error, term()}.
resolve_run_scope(#{run_id := RunId} = Scope) ->
    case beam_agent_runs_core:get_run(RunId) of
        {ok, Run} ->
            ScopeFromRun = maps:with([session_id, thread_id], Run),
            case merge_scopes(Scope, ScopeFromRun) of
                {ok, Scope2} -> {ok, Scope2};
                {error, inconsistent_scope} -> {error, inconsistent_run_scope}
            end;
        {error, not_found} ->
            {error, run_not_found}
    end;
resolve_run_scope(Scope) ->
    validate_scope(Scope).

-spec resolve_source_ref_scope(scope(), source_ref()) -> {ok, scope()} | {error, term()}.
resolve_source_ref_scope(Scope, #{type := Type, id := RefId}) ->
    case Type of
        session ->
            merge_scopes(Scope, #{session_id => RefId});
        <<"session">> ->
            merge_scopes(Scope, #{session_id => RefId});
        thread ->
            merge_scopes(Scope, #{thread_id => RefId});
        <<"thread">> ->
            merge_scopes(Scope, #{thread_id => RefId});
        run ->
            merge_scopes(Scope, #{run_id => RefId});
        <<"run">> ->
            merge_scopes(Scope, #{run_id => RefId});
        artifact ->
            resolve_artifact_scope(Scope, RefId);
        <<"artifact">> ->
            resolve_artifact_scope(Scope, RefId);
        _Other ->
            {ok, Scope}
    end.

-spec resolve_artifact_scope(scope(), binary()) -> {ok, scope()} | {error, term()}.
resolve_artifact_scope(Scope, ArtifactId) ->
    case beam_agent_artifacts_core:get(ArtifactId) of
        {ok, Artifact} ->
            ArtifactScope = maps:filter(fun(Key, _Value) ->
                lists:member(Key, [session_id, thread_id, run_id])
            end, Artifact),
            case merge_scopes(Scope, ArtifactScope) of
                {ok, Scope2} -> {ok, Scope2};
                {error, inconsistent_scope} -> {error, inconsistent_artifact_scope}
            end;
        {error, not_found} ->
            {error, artifact_not_found}
    end.

-spec normalize_filter(memory_filter()) -> {ok, memory_filter()} | {error, term()}.
normalize_filter(Filter) ->
    case normalize_optional_binary_value(memory_id, maps:get(memory_id, Filter, undefined),
             invalid_filter) of
        {ok, MemoryId} ->
            case normalize_optional_kind(Filter, kind) of
                {ok, Kind} ->
                    case normalize_optional_binary_value(session_id,
                             maps:get(session_id, Filter, undefined), invalid_filter) of
                        {ok, SessionId} ->
                            case normalize_optional_binary_value(thread_id,
                                     maps:get(thread_id, Filter, undefined),
                                     invalid_filter) of
                                {ok, ThreadId} ->
                                    case normalize_optional_binary_value(run_id,
                                             maps:get(run_id, Filter, undefined),
                                             invalid_filter) of
                                        {ok, RunId} ->
                                            case normalize_optional_boolean(Filter, pinned) of
                                                {ok, Pinned} ->
                                                    case normalize_optional_ref_type(Filter) of
                                                        {ok, RefType} ->
                                                            case normalize_optional_binary_value(
                                                                     source_ref_id,
                                                                     maps:get(source_ref_id,
                                                                         Filter, undefined),
                                                                     invalid_filter) of
                                                                {ok, RefId} ->
                                                                    case normalize_limit(Filter) of
                                                                        {ok, Limit} ->
                                                                            case normalize_since(
                                                                                     Filter) of
                                                                                {ok, Since} ->
                                                                                    case normalize_optional_boolean(
                                                                                             Filter,
                                                                                             include_expired) of
                                                                                        {ok, IncludeExpired} ->
                                                                                            case normalize_optional_nonneg_integer(
                                                                                                     Filter,
                                                                                                     min_salience) of
                                                                                                {ok, MinSalience} ->
                                                                                                    case normalize_before(
                                                                                                             Filter) of
                                                                                                        {ok, Before} ->
                                                                                                            Filter0 = maybe_put(
                                                                                                                memory_id,
                                                                                                                MemoryId,
                                                                                                                #{}),
                                                                                                            Filter1 = maybe_put(
                                                                                                                kind,
                                                                                                                Kind,
                                                                                                                Filter0),
                                                                                                            Filter2 = maybe_put(
                                                                                                                session_id,
                                                                                                                SessionId,
                                                                                                                Filter1),
                                                                                                            Filter3 = maybe_put(
                                                                                                                thread_id,
                                                                                                                ThreadId,
                                                                                                                Filter2),
                                                                                                            Filter4 = maybe_put(
                                                                                                                run_id,
                                                                                                                RunId,
                                                                                                                Filter3),
                                                                                                            Filter5 = maybe_put(
                                                                                                                pinned,
                                                                                                                Pinned,
                                                                                                                Filter4),
                                                                                                            Filter6 = maybe_put(
                                                                                                                source_ref_type,
                                                                                                                RefType,
                                                                                                                Filter5),
                                                                                                            Filter7 = maybe_put(
                                                                                                                source_ref_id,
                                                                                                                RefId,
                                                                                                                Filter6),
                                                                                                            Filter8 = maybe_put(
                                                                                                                since,
                                                                                                                Since,
                                                                                                                Filter7),
                                                                                                            Filter9 = maybe_put(
                                                                                                                limit,
                                                                                                                Limit,
                                                                                                                Filter8),
                                                                                                            Filter10 = maybe_put(
                                                                                                                include_expired,
                                                                                                                IncludeExpired,
                                                                                                                Filter9),
                                                                                                            Filter11 = maybe_put(
                                                                                                                min_salience,
                                                                                                                MinSalience,
                                                                                                                Filter10),
                                                                                                            validate_filter_scope(
                                                                                                                maybe_put(before,
                                                                                                                    Before,
                                                                                                                    Filter11));
                                                                                                        {error, _} = Error ->
                                                                                                            Error
                                                                                                    end;
                                                                                                {error, _} = Error ->
                                                                                                    Error
                                                                                            end;
                                                                                        {error, _} = Error ->
                                                                                            Error
                                                                                    end;
                                                                                {error, _} = Error ->
                                                                                    Error
                                                                            end;
                                                                        {error, _} = Error ->
                                                                            Error
                                                                    end;
                                                                {error, _} = Error ->
                                                                    Error
                                                            end;
                                                        {error, _} = Error ->
                                                            Error
                                                    end;
                                                {error, _} = Error ->
                                                    Error
                                            end;
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec validate_filter_scope(memory_filter()) -> {ok, memory_filter()} | {error, term()}.
validate_filter_scope(#{thread_id := _ThreadId} = Filter)
  when not is_map_key(session_id, Filter) ->
    {error, {invalid_filter, thread_id}};
validate_filter_scope(Filter) ->
    {ok, Filter}.

-spec store_filter(memory_filter()) -> beam_agent_memory_store:memory_filter().
store_filter(Filter) ->
    maps:without([include_expired, min_salience, before, limit], Filter).

-spec normalize_optional_kind(map(), atom()) ->
    {ok, atom() | binary() | undefined} | {error, term()}.
normalize_optional_kind(Filter, Key) ->
    case maps:find(Key, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} ->
            case normalize_kind(Key, Value, invalid_filter) of
                {ok, Kind} -> {ok, Kind};
                {error, _} -> {error, {invalid_filter, Key}}
            end
    end.

-spec normalize_kind(atom(), term(), atom()) ->
    {ok, atom() | binary()} | {error, term()}.
normalize_kind(_Key, Value, _Namespace) when is_atom(Value) ->
    {ok, Value};
normalize_kind(_Key, Value, _Namespace)
  when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_kind(Key, _Other, invalid_memory) ->
    {error, {invalid_memory, Key}};
normalize_kind(Key, _Other, invalid_filter) ->
    {error, {invalid_filter, Key}}.

-spec normalize_ref_type(term()) -> {ok, atom() | binary()} | {error, invalid_ref_type}.
normalize_ref_type(Value) when is_atom(Value) ->
    {ok, Value};
normalize_ref_type(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_ref_type(_Value) ->
    {error, invalid_ref_type}.

-spec normalize_optional_ref_type(map()) ->
    {ok, atom() | binary() | undefined} | {error, term()}.
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

-spec normalize_optional_binary_value(atom(), term(), atom()) ->
    {ok, binary() | undefined} | {error, term()}.
normalize_optional_binary_value(_Key, undefined, _Namespace) ->
    {ok, undefined};
normalize_optional_binary_value(_Key, Value, _Namespace)
  when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_optional_binary_value(Key, _Value, invalid_scope) ->
    {error, {invalid_scope, Key}};
normalize_optional_binary_value(Key, _Value, invalid_filter) ->
    {error, {invalid_filter, Key}}.

-spec normalize_optional_boolean(map(), atom()) ->
    {ok, boolean() | undefined} | {error, term()}.
normalize_optional_boolean(Filter, Key) ->
    case maps:find(Key, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} when is_boolean(Value) ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_filter, Key}}
    end.

-spec normalize_limit(map()) -> {ok, pos_integer() | undefined} | {error, term()}.
normalize_limit(Filter) ->
    case maps:find(limit, Filter) of
        error ->
            {ok, undefined};
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            {ok, Limit};
        {ok, _Other} ->
            {error, {invalid_filter, limit}}
    end.

-spec normalize_since(map()) -> {ok, integer() | undefined} | {error, term()}.
normalize_since(Filter) ->
    case maps:find(since, Filter) of
        error ->
            {ok, undefined};
        {ok, Since} when is_integer(Since) ->
            {ok, Since};
        {ok, _Other} ->
            {error, {invalid_filter, since}}
    end.

-spec normalize_before(map()) -> {ok, integer() | undefined} | {error, term()}.
normalize_before(Filter) ->
    case maps:find(before, Filter) of
        error ->
            {ok, undefined};
        {ok, Before} when is_integer(Before) ->
            {ok, Before};
        {ok, _Other} ->
            {error, {invalid_filter, before}}
    end.

-spec normalize_optional_nonneg_integer(map(), atom()) ->
    {ok, non_neg_integer() | undefined} | {error, term()}.
normalize_optional_nonneg_integer(Filter, Key) ->
    case maps:find(Key, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} when is_integer(Value), Value >= 0 ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_filter, Key}}
    end.

-spec memory_visible(memory_record(), boolean(), integer()) -> boolean().
memory_visible(_Memory, true, _Now) ->
    true;
memory_visible(Memory, false, Now) ->
    case maps:get(pinned, Memory, false) of
        true ->
            true;
        false ->
            case maps:get(expires_at, Memory, undefined) of
                undefined -> true;
                ExpiresAt when is_integer(ExpiresAt) -> ExpiresAt > Now
            end
    end.

-spec memory_should_expire(memory_record(), integer()) -> boolean().
memory_should_expire(Memory, Now) ->
    case maps:get(pinned, Memory, false) of
        true ->
            false;
        false ->
            case maps:get(expires_at, Memory, undefined) of
                undefined -> false;
                ExpiresAt when is_integer(ExpiresAt) -> ExpiresAt =< Now
            end
    end.

-spec expires_at(map(), integer()) -> integer() | undefined.
expires_at(#{ttl := infinity}, _Now) ->
    undefined;
expires_at(#{ttl := Ttl}, Now) when is_integer(Ttl), Ttl >= 0 ->
    Now + Ttl.

-spec maybe_limit([term()], infinity | pos_integer() | undefined) -> [term()].
maybe_limit(Items, infinity) ->
    Items;
maybe_limit(Items, undefined) ->
    Items;
maybe_limit(Items, Limit) when is_integer(Limit), Limit > 0 ->
    lists:sublist(Items, Limit).

-spec tokenize(binary()) -> [binary()].
tokenize(Query) ->
    Lower = lower_binary(Query),
    [Token || Token <- re:split(Lower, "[^[:alnum:]]+",
        [trim, {return, binary}, unicode]), Token =/= <<>>].

-spec score_memory([binary()], memory_record()) -> non_neg_integer().
score_memory(Tokens, Memory) ->
    Blob = search_blob(Memory),
    TokenScore = lists:sum([match_count(Blob, Token) || Token <- Tokens]),
    case TokenScore of
        0 ->
            0;
        _ ->
            TokenScore +
                pinned_bonus(Memory) +
                salience_bonus(Memory)
    end.

-spec match_count(binary(), binary()) -> non_neg_integer().
match_count(_Blob, <<>>) ->
    0;
match_count(Blob, Token) ->
    length(binary:matches(Blob, Token)).

-spec search_blob(memory_record()) -> binary().
search_blob(Memory) ->
    lower_binary(iolist_to_binary(lists:join(<<" ">>,
        term_text_fragments([
            maps:get(kind, Memory),
            maps:get(content, Memory),
            maps:get(attributes, Memory, #{}),
            maps:get(source_refs, Memory, [])
        ])))).

-spec term_text_fragments(term()) -> [binary()].
term_text_fragments(Term) when is_binary(Term) ->
    [Term];
term_text_fragments(Term) when is_atom(Term) ->
    [atom_to_binary(Term, utf8)];
term_text_fragments(Term) when is_integer(Term); is_float(Term) ->
    [iolist_to_binary(io_lib:format("~p", [Term]))];
term_text_fragments(Term) when is_list(Term) ->
    case maybe_text_list(Term) of
        true -> [unicode:characters_to_binary(Term)];
        false -> lists:flatmap(fun term_text_fragments/1, Term)
    end;
term_text_fragments(Term) when is_map(Term) ->
    lists:flatmap(fun({Key, Value}) ->
        term_text_fragments(Key) ++ term_text_fragments(Value)
    end, maps:to_list(Term));
term_text_fragments(Term) when is_tuple(Term) ->
    lists:flatmap(fun term_text_fragments/1, tuple_to_list(Term));
term_text_fragments(Term) ->
    [iolist_to_binary(io_lib:format("~tp", [Term]))].

-spec maybe_text_list(list()) -> boolean().
maybe_text_list(List) ->
    lists:all(fun erlang:is_integer/1, List).

-spec lower_binary(binary()) -> binary().
lower_binary(Binary) ->
    unicode:characters_to_binary(
        string:lowercase(unicode:characters_to_list(Binary))
    ).

-spec pinned_bonus(memory_record()) -> non_neg_integer().
pinned_bonus(Memory) ->
    case maps:get(pinned, Memory, false) of
        true -> 50;
        false -> 0
    end.

-spec salience_bonus(memory_record()) -> non_neg_integer().
salience_bonus(Memory) ->
    maps:get(salience, Memory, 0).

-spec search_sort_key(non_neg_integer(), memory_record()) -> tuple().
search_sort_key(Score, Memory) ->
    {
        -Score,
        pin_sort_key(Memory),
        -maps:get(salience, Memory, 0),
        -maps:get(updated_at, Memory, 0),
        maps:get(memory_id, Memory)
    }.

-spec pin_sort_key(memory_record()) -> 0 | 1.
pin_sort_key(Memory) ->
    case maps:get(pinned, Memory, false) of
        true -> 0;
        false -> 1
    end.

-spec append_memory_event(binary(), memory_record(), map()) ->
    {ok, beam_agent_journal_core:entry()} | {error, term()}.
append_memory_event(EventType, Memory, ExtraPayload) ->
    Scope = maps:get(scope, Memory, #{}),
    Event0 = #{
        tags => [memory],
        payload => maps:merge(#{memory => memory_summary(Memory)}, ExtraPayload)
    },
    Event1 = maybe_put(session_id, maps:get(session_id, Scope, undefined), Event0),
    Event2 = maybe_put(thread_id, maps:get(thread_id, Scope, undefined), Event1),
    Event3 = maybe_put(run_id, maps:get(run_id, Scope, undefined), Event2),
    beam_agent_journal_core:append(EventType, Event3).

-spec memory_summary(memory_record()) -> map().
memory_summary(Memory) ->
    #{
        memory_id => maps:get(memory_id, Memory),
        kind => maps:get(kind, Memory),
        scope => maps:get(scope, Memory, #{}),
        pinned => maps:get(pinned, Memory, false),
        salience => maps:get(salience, Memory, 0),
        ttl => maps:get(ttl, Memory, infinity),
        source_refs => maps:get(source_refs, Memory, []),
        created_at => maps:get(created_at, Memory),
        updated_at => maps:get(updated_at, Memory)
    }.

-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec consistent_scope(term(), term()) -> boolean().
consistent_scope(undefined, _Value) -> true;
consistent_scope(_Value, undefined) -> true;
consistent_scope(Value, Value) -> true;
consistent_scope(_Left, _Right) -> false.

-spec choose_scope(term(), term()) -> term().
choose_scope(undefined, Value) -> Value;
choose_scope(Value, _Fallback) -> Value.

-spec current_time_ms() -> integer().
current_time_ms() ->
    erlang:system_time(millisecond).

-spec generate_memory_id() -> binary().
generate_memory_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<"memory_", Hex/binary>>.
