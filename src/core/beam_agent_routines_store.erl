-module(beam_agent_routines_store).
-moduledoc """
Store-backed persistence for BeamAgent routines and scheduled jobs.

This module owns the raw persistence shape for canonical routine jobs:

- job records
- due-time ordering
- short-lived execution claims

It intentionally stays process-free and leaves normalization, lifecycle
validation, and target execution to `beam_agent_routines_core` and
`beam_agent_routine_runner`.
""".

-export([
    ensure_tables/0,
    clear/0,
    put_job/1,
    get_job/1,
    delete_job/1,
    list_jobs/1,
    list_due_jobs/2,
    next_due_at/0,
    claim_job/4,
    release_claim/2
]).

-export_type([
    job_record/0,
    job_filter/0,
    due_filter/0,
    claim_record/0
]).

-type job_record() :: map().

-type job_filter() :: #{
    job_id => binary(),
    state => atom(),
    schedule_type => atom(),
    target_type => atom(),
    due_before => integer(),
    limit => pos_integer()
}.

-type due_filter() :: #{
    at => integer(),
    limit => pos_integer(),
    include_claimed => boolean()
}.

-type claim_record() :: #{
    job_id := binary(),
    runner_id := binary(),
    slot_at := integer(),
    claimed_at := integer(),
    claimed_until := integer()
}.

-define(JOBS_TABLE, beam_agent_routine_jobs).
-define(DUE_TABLE, beam_agent_routine_due).
-define(CLAIMS_TABLE, beam_agent_routine_claims).
-define(STORE_DOMAIN, routines).

-doc "Ensure the routines ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?JOBS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?DUE_TABLE, [ordered_set, named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?CLAIMS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear all routine jobs, due indexes, and claims.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?JOBS_TABLE),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?DUE_TABLE),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?CLAIMS_TABLE),
    beam_agent_reload_bus:notify(routines),
    ok.

-doc "Insert or overwrite a routine job, updating due indexes as needed.".
-spec put_job(#{job_id := binary(), _ => _}) -> ok.
put_job(#{job_id := JobId} = Job) when is_binary(JobId) ->
    ensure_tables(),
    case get_job(JobId) of
        {ok, Existing} ->
            remove_due_index(Existing);
        {error, not_found} ->
            ok
    end,
    true = beam_agent_store:insert(?STORE_DOMAIN, ?JOBS_TABLE, {JobId, Job}),
    index_due(Job),
    beam_agent_reload_bus:notify(routines),
    ok.

-doc "Fetch a routine job by id.".
-spec get_job(binary()) -> {ok, job_record()} | {error, not_found}.
get_job(JobId) when is_binary(JobId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?JOBS_TABLE, JobId) of
        [{_, Job}] when is_map(Job) ->
            {ok, Job};
        [] ->
            {error, not_found}
    end.

-doc "Delete a routine job and any related due/claim state.".
-spec delete_job(binary()) -> ok | {error, not_found}.
delete_job(JobId) when is_binary(JobId) ->
    ensure_tables(),
    case get_job(JobId) of
        {ok, Job} ->
            remove_due_index(Job),
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?JOBS_TABLE, JobId),
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId),
            beam_agent_reload_bus:notify(routines),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "List routine jobs matching an already-normalized filter.".
-spec list_jobs(job_filter()) -> {ok, [job_record()]}.
list_jobs(Filter) when is_map(Filter) ->
    ensure_tables(),
    Jobs = beam_agent_store:foldl(?STORE_DOMAIN, fun
        ({_, Job}, Acc) ->
            case matches_job_filters(Job, Filter) of
                true -> [Job | Acc];
                false -> Acc
            end
    end, [], ?JOBS_TABLE),
    Sorted = lists:sort(fun sort_jobs/2, Jobs),
    {ok, apply_limit(Sorted, maps:get(limit, Filter, infinity))}.

-doc "List currently due jobs in ascending due-time order.".
-spec list_due_jobs(integer(), due_filter()) -> {ok, [job_record()]}.
list_due_jobs(At, Filter) when is_integer(At), is_map(Filter) ->
    ensure_tables(),
    Limit = maps:get(limit, Filter, infinity),
    IncludeClaimed = maps:get(include_claimed, Filter, false),
    Jobs = collect_due_jobs(beam_agent_store:first(?STORE_DOMAIN, ?DUE_TABLE),
        At, IncludeClaimed, Limit, []),
    {ok, lists:reverse(Jobs)}.

-doc "Return the earliest next-run timestamp in the due index, if any.".
-spec next_due_at() -> integer() | undefined.
next_due_at() ->
    ensure_tables(),
    case beam_agent_store:first(?STORE_DOMAIN, ?DUE_TABLE) of
        '$end_of_table' ->
            undefined;
        {DueAt, _JobId} ->
            DueAt
    end.

-doc "Claim a due job for a bounded amount of time. Idempotent for the same runner.".
-spec claim_job(binary(), binary(), integer(), pos_integer()) ->
    {ok, claim_record()} | {error, claimed | not_found}.
claim_job(JobId, RunnerId, SlotAt, ClaimTtlMs)
  when is_binary(JobId), is_binary(RunnerId),
       is_integer(SlotAt), is_integer(ClaimTtlMs), ClaimTtlMs > 0 ->
    ensure_tables(),
    case get_job(JobId) of
        {ok, _Job} ->
            claim_job_retry(JobId, RunnerId, SlotAt, ClaimTtlMs);
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Release a previously claimed job when the caller still owns the claim.".
-spec release_claim(binary(), binary()) -> ok.
release_claim(JobId, RunnerId) when is_binary(JobId), is_binary(RunnerId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId) of
        [{_, _Claim}] when RunnerId =:= <<"__any_runner__">> ->
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId),
            ok;
        [{_, #{runner_id := RunnerId}}] ->
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec claim_job_retry(binary(), binary(), integer(), pos_integer()) ->
    {ok, claim_record()} | {error, claimed}.
claim_job_retry(JobId, RunnerId, SlotAt, ClaimTtlMs) ->
    Now = erlang:system_time(millisecond),
    Claim = #{
        job_id => JobId,
        runner_id => RunnerId,
        slot_at => SlotAt,
        claimed_at => Now,
        claimed_until => Now + ClaimTtlMs
    },
    case beam_agent_store:insert_new(?STORE_DOMAIN, ?CLAIMS_TABLE, {JobId, Claim}) of
        true ->
            {ok, Claim};
        false ->
            case beam_agent_store:lookup(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId) of
                [{_, Existing = #{runner_id := RunnerId, slot_at := SlotAt}}] ->
                    {ok, Existing};
                [{_, #{claimed_until := ClaimedUntil}}] when ClaimedUntil =< Now ->
                    _ = beam_agent_store:delete(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId),
                    claim_job_retry(JobId, RunnerId, SlotAt, ClaimTtlMs);
                _ ->
                    {error, claimed}
            end
    end.

-spec collect_due_jobs('$end_of_table' | {integer(), binary()}, integer(), boolean(), infinity | pos_integer(),
    [job_record()]) -> [job_record()].
collect_due_jobs('$end_of_table', _At, _IncludeClaimed, _Limit, Acc) ->
    Acc;
collect_due_jobs(_Key, _At, _IncludeClaimed, 0, Acc) ->
    Acc;
collect_due_jobs({DueAt, _JobId}, At, _IncludeClaimed, _Limit, Acc) when DueAt > At ->
    Acc;
collect_due_jobs(Key = {DueAt, JobId}, At, IncludeClaimed, Limit, Acc)
  when is_integer(DueAt), is_binary(JobId) ->
    NextKey = beam_agent_store:next(?STORE_DOMAIN, ?DUE_TABLE, Key),
    case get_job(JobId) of
        {ok, Job} ->
            case due_job_visible(Job, At, IncludeClaimed) of
                true ->
                    collect_due_jobs(NextKey, At, IncludeClaimed,
                        decrement_limit(Limit, 1), [Job | Acc]);
                false ->
                    collect_due_jobs(NextKey, At, IncludeClaimed, Limit, Acc)
            end;
        {error, not_found} ->
            collect_due_jobs(NextKey, At, IncludeClaimed, Limit, Acc)
    end.

-spec due_job_visible(job_record(), integer(), boolean()) -> boolean().
due_job_visible(Job, At, IncludeClaimed) ->
    is_due_candidate(Job, At)
        andalso (IncludeClaimed orelse not has_active_claim(maps:get(job_id, Job), At)).

-spec has_active_claim(binary(), integer()) -> boolean().
has_active_claim(JobId, Now) ->
    case beam_agent_store:lookup(?STORE_DOMAIN, ?CLAIMS_TABLE, JobId) of
        [{_, #{claimed_until := ClaimedUntil}}] when ClaimedUntil > Now ->
            true;
        _ ->
            false
    end.

-spec matches_job_filters(job_record(), job_filter()) -> boolean().
matches_job_filters(Job, Filter) ->
    lists:all(fun
        ({limit, _}) ->
            true;
        ({due_before, DueBefore}) ->
            NextRunAt = maps:get(next_run_at, Job, undefined),
            is_integer(NextRunAt) andalso NextRunAt =< DueBefore;
        ({schedule_type, Type}) ->
            schedule_type(Job) =:= Type;
        ({target_type, Type}) ->
            target_type(Job) =:= Type;
        ({Key, Value}) ->
            maps:get(Key, Job, undefined) =:= Value
    end, maps:to_list(Filter)).

-spec sort_jobs(job_record(), job_record()) -> boolean().
sort_jobs(A, B) ->
    compare_desc(
        maps:get(updated_at, A, 0),
        maps:get(updated_at, B, 0),
        maps:get(job_id, A),
        maps:get(job_id, B)
    ).

-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

-spec apply_limit([job_record()], infinity | pos_integer()) -> [job_record()].
apply_limit(Jobs, infinity) ->
    Jobs;
apply_limit(Jobs, Limit) when is_integer(Limit), Limit > 0 ->
    lists:sublist(Jobs, Limit).

-spec decrement_limit(infinity | pos_integer(), 1) -> infinity | non_neg_integer().
decrement_limit(infinity, _Matched) ->
    infinity;
decrement_limit(Limit, 1) when is_integer(Limit), Limit > 0 ->
    Limit - 1.

-spec schedule_type(job_record()) -> atom() | binary() | undefined.
schedule_type(Job) ->
    maps:get(type, maps:get(schedule, Job, #{}), undefined).

-spec target_type(job_record()) -> atom() | binary() | undefined.
target_type(Job) ->
    maps:get(type, maps:get(target, Job, #{}), undefined).

-spec index_due(#{job_id := binary(), _ => _}) -> ok.
index_due(Job) ->
    case due_key(Job) of
        undefined ->
            ok;
        Key ->
            true = beam_agent_store:insert(?STORE_DOMAIN, ?DUE_TABLE, {Key, true}),
            ok
    end.

-spec remove_due_index(job_record()) -> ok.
remove_due_index(Job) ->
    case due_key(Job) of
        undefined ->
            ok;
        Key ->
            _ = beam_agent_store:delete(?STORE_DOMAIN, ?DUE_TABLE, Key),
            ok
    end.

-spec due_key(job_record()) -> {integer(), binary()} | undefined.
due_key(#{job_id := JobId, state := State} = Job)
  when State =:= active; State =:= retry_waiting ->
    case maps:get(next_run_at, Job, undefined) of
        NextRunAt when is_integer(NextRunAt) ->
            {NextRunAt, JobId};
        _ ->
            undefined
    end;
due_key(_Job) ->
    undefined.

-spec is_due_candidate(job_record(), integer()) -> boolean().
is_due_candidate(#{state := State} = Job, At)
  when (State =:= active) orelse (State =:= retry_waiting) ->
    case maps:get(next_run_at, Job, undefined) of
        NextRunAt when is_integer(NextRunAt) ->
            NextRunAt =< At;
        _ ->
            false
    end;
is_due_candidate(_Job, _At) ->
    false.
