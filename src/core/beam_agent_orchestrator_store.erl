-module(beam_agent_orchestrator_store).
-moduledoc """
Store-backed persistence for BeamAgent orchestrator lineage records.

This module owns the raw persistence shape for orchestration links:

- child-run to parent-run lineage
- parent-run child indexes
- optional live session references owned by the orchestrator slice

It intentionally does not decide lifecycle policy, await semantics, or
collection behavior. Those concerns belong in `beam_agent_orchestrator_core`.
""".

-export([
    ensure_tables/0,
    clear/0,
    put_link/1,
    get_link/1,
    delete_link/1,
    list_children/1
]).

-export_type([
    relation/0,
    substrate/0,
    link_record/0
]).

-type relation() :: spawned | delegated.
-type substrate() :: run | session | thread | session_thread.

-type link_record() :: #{
    child_run_id := binary(),
    parent_run_id := binary(),
    relation := relation(),
    substrate := substrate(),
    metadata := map(),
    sequence := pos_integer(),
    created_at := integer(),
    updated_at := integer(),
    child_session_id => binary(),
    child_thread_id => binary(),
    task => term(),
    session_ref => pid(),
    owns_session => boolean(),
    stop_session => boolean()
}.

-define(DOMAINS_TABLE, beam_agent_domains).
-define(CHILDREN_TABLE, beam_agent_orchestrator_children).
-define(STORE_DOMAIN, orchestrator).

-doc "Ensure the orchestrator ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?DOMAINS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?CHILDREN_TABLE, [bag, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear all orchestrator lineage state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?DOMAINS_TABLE, {{orch_link, '_'}, '_'}),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?CHILDREN_TABLE),
    ok.

-doc "Insert or overwrite a lineage record and keep the parent index in sync.".
-spec put_link(link_record()) -> ok.
put_link(#{child_run_id := ChildRunId, parent_run_id := ParentRunId} = Link)
  when is_binary(ChildRunId), is_binary(ParentRunId) ->
    ensure_tables(),
    case get_link(ChildRunId) of
        {ok, Existing} ->
            maybe_delete_parent_index(Existing);
        {error, not_found} ->
            ok
    end,
    true = beam_agent_store:insert(?STORE_DOMAIN, ?DOMAINS_TABLE,
        {{orch_link, ChildRunId}, Link}),
    true = beam_agent_store:insert(?STORE_DOMAIN, ?CHILDREN_TABLE,
        {ParentRunId, ChildRunId}),
    ok.

-doc "Fetch a lineage record by child run id.".
-spec get_link(binary()) -> {ok, link_record()} | {error, not_found}.
get_link(ChildRunId) when is_binary(ChildRunId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?DOMAINS_TABLE, {orch_link, ChildRunId}) of
        [{_, Link}] when is_map(Link) ->
            {ok, Link};
        [] ->
            {error, not_found}
    end.

-doc "Delete a lineage record and remove its parent index entry.".
-spec delete_link(binary()) -> ok | {error, not_found}.
delete_link(ChildRunId) when is_binary(ChildRunId) ->
    ensure_tables(),
    case get_link(ChildRunId) of
        {ok, Link} ->
            maybe_delete_parent_index(Link),
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?DOMAINS_TABLE,
                {orch_link, ChildRunId}),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "List direct child lineage records for a parent run, oldest first.".
-spec list_children(binary()) -> {ok, [link_record()]}.
list_children(ParentRunId) when is_binary(ParentRunId) ->
    ensure_tables(),
    ChildRunIds = beam_agent_store:foldl(?STORE_DOMAIN, fun
        ({ParentId, ChildRunId}, Acc) when ParentId =:= ParentRunId,
                                           is_binary(ChildRunId) ->
            [ChildRunId | Acc];
        (_, Acc) ->
            Acc
    end, [], ?CHILDREN_TABLE),
    Links = lists:foldl(fun(ChildRunId, Acc) ->
        case get_link(ChildRunId) of
            {ok, Link} -> [Link | Acc];
            {error, not_found} -> Acc
        end
    end, [], ChildRunIds),
    {ok, lists:sort(fun sort_links/2, Links)}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec maybe_delete_parent_index(link_record()) -> ok.
maybe_delete_parent_index(#{parent_run_id := ParentRunId, child_run_id := ChildRunId}) ->
    _ = beam_agent_store:delete_object(?STORE_DOMAIN, ?CHILDREN_TABLE,
        {ParentRunId, ChildRunId}),
    ok.

-spec sort_links(link_record(), link_record()) -> boolean().
sort_links(A, B) ->
    beam_agent_store_utils:compare_asc(
        maps:get(sequence, A, maps:get(created_at, A, 0)),
        maps:get(sequence, B, maps:get(created_at, B, 0)),
        maps:get(child_run_id, A),
        maps:get(child_run_id, B)
    ).
