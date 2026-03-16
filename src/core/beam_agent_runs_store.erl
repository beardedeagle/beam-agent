-module(beam_agent_runs_store).
-moduledoc """
Internal ETS storage for BeamAgent runs and steps.

This module owns the raw persistence shape for durable run and step
records. It intentionally contains no lifecycle validation or transition
logic. Higher-level invariants such as parent scope inheritance,
terminal-state enforcement, and step cascading live in
beam_agent_runs_core.

The store is ETS-backed and uses beam_agent_ets so the same code works in
both public and hardened table-access modes. Reads stay direct. Writes are
proxied through the table owner in hardened mode.
""".

-export([
    ensure_tables/0,
    clear/0,
    insert_run/1,
    put_run/1,
    get_run/1,
    list_runs/1,
    insert_step/1,
    put_step/1,
    get_step/2,
    list_steps/1
]).

-export_type([run_record/0, step_record/0, run_filter/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type run_status() :: running | completed | failed | cancelled.
-type step_status() :: running | completed | failed | cancelled.
-type run_kind() :: atom() | binary().
-type step_kind() :: atom() | binary().

-type run_record() :: #{
    run_id := binary(),
    kind := run_kind(),
    status := run_status(),
    metadata := map(),
    created_at := integer(),
    updated_at := integer(),
    session_id => binary(),
    thread_id => binary(),
    parent_run_id => binary(),
    input => term(),
    output => term(),
    error => term(),
    cancel_reason => term(),
    completed_at => integer()
}.

-type step_record() :: #{
    step_id := binary(),
    run_id := binary(),
    kind := step_kind(),
    status := step_status(),
    metadata := map(),
    created_at := integer(),
    updated_at := integer(),
    session_id => binary(),
    thread_id => binary(),
    input => term(),
    output => term(),
    error => term(),
    cancel_reason => term(),
    completed_at => integer()
}.

-type run_filter() :: #{
    session_id => binary(),
    thread_id => binary(),
    parent_run_id => binary(),
    kind => run_kind(),
    status => run_status(),
    limit => pos_integer(),
    since => integer()
}.

-define(RUNS_TABLE, beam_agent_run_records).
-define(STEPS_TABLE, beam_agent_run_steps).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the runs ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?RUNS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?STEPS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear all run and step records.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?RUNS_TABLE),
    beam_agent_ets:delete_all_objects(?STEPS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Run Storage
%%--------------------------------------------------------------------

-doc "Insert a run only when its run_id is new.".
-spec insert_run(run_record()) -> boolean().
insert_run(#{run_id := RunId} = Run) when is_binary(RunId) ->
    ensure_tables(),
    beam_agent_ets:insert_new(?RUNS_TABLE, {RunId, Run}).

-doc "Overwrite or insert a run record.".
-spec put_run(run_record()) -> ok.
put_run(#{run_id := RunId} = Run) when is_binary(RunId) ->
    ensure_tables(),
    true = beam_agent_ets:insert(?RUNS_TABLE, {RunId, Run}),
    ok.

-doc "Fetch a run by id.".
-spec get_run(binary()) -> {ok, run_record()} | {error, not_found}.
get_run(RunId) when is_binary(RunId) ->
    ensure_tables(),
    case ets:lookup(?RUNS_TABLE, RunId) of
        [{_, Run}] -> {ok, Run};
        [] -> {error, not_found}
    end.

-doc "List runs matching an already-normalized filter map.".
-spec list_runs(run_filter()) -> {ok, [run_record()]}.
list_runs(Filter) when is_map(Filter) ->
    ensure_tables(),
    Runs = ets:foldl(fun
        ({_, Run}, Acc) ->
            case matches_filters(Run, Filter) of
                true -> [Run | Acc];
                false -> Acc
            end
    end, [], ?RUNS_TABLE),
    Sorted = lists:sort(fun sort_runs/2, Runs),
    {ok, apply_limit(Sorted, Filter)}.

%%--------------------------------------------------------------------
%% Step Storage
%%--------------------------------------------------------------------

-doc "Insert a step only when its {run_id, step_id} key is new.".
-spec insert_step(step_record()) -> boolean().
insert_step(#{run_id := RunId, step_id := StepId} = Step)
  when is_binary(RunId), is_binary(StepId) ->
    ensure_tables(),
    Key = {RunId, StepId},
    beam_agent_ets:insert_new(?STEPS_TABLE, {Key, Step}).

-doc "Overwrite or insert a step record.".
-spec put_step(step_record()) -> ok.
put_step(#{run_id := RunId, step_id := StepId} = Step)
  when is_binary(RunId), is_binary(StepId) ->
    ensure_tables(),
    Key = {RunId, StepId},
    true = beam_agent_ets:insert(?STEPS_TABLE, {Key, Step}),
    ok.

-doc "Fetch a step by run id and step id.".
-spec get_step(binary(), binary()) -> {ok, step_record()} | {error, not_found}.
get_step(RunId, StepId) when is_binary(RunId), is_binary(StepId) ->
    ensure_tables(),
    Key = {RunId, StepId},
    case ets:lookup(?STEPS_TABLE, Key) of
        [{_, Step}] -> {ok, Step};
        [] -> {error, not_found}
    end.

-doc "List steps for a run, oldest first.".
-spec list_steps(binary()) -> {ok, [step_record()]}.
list_steps(RunId) when is_binary(RunId) ->
    ensure_tables(),
    Steps = ets:foldl(fun
        ({{StepRunId, _}, Step}, Acc) when StepRunId =:= RunId ->
            [Step | Acc];
        (_, Acc) ->
            Acc
    end, [], ?STEPS_TABLE),
    Sorted = lists:sort(fun sort_steps/2, Steps),
    {ok, Sorted}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec matches_filters(run_record(), run_filter()) -> boolean().
matches_filters(Run, Filter) ->
    lists:all(fun
        ({limit, _}) ->
            true;
        ({since, Since}) ->
            maps:get(updated_at, Run, 0) >= Since;
        ({Key, Value}) ->
            maps:get(Key, Run, undefined) =:= Value
    end, maps:to_list(Filter)).

-spec apply_limit([run_record()], run_filter()) -> [run_record()].
apply_limit(Runs, Filter) ->
    case maps:get(limit, Filter, infinity) of
        infinity ->
            Runs;
        Limit when is_integer(Limit), Limit > 0 ->
            lists:sublist(Runs, Limit)
    end.

-spec sort_runs(run_record(), run_record()) -> boolean().
sort_runs(A, B) ->
    compare_desc(
        maps:get(updated_at, A, 0),
        maps:get(updated_at, B, 0),
        maps:get(run_id, A),
        maps:get(run_id, B)
    ).

-spec sort_steps(step_record(), step_record()) -> boolean().
sort_steps(A, B) ->
    compare_asc(
        maps:get(created_at, A, 0),
        maps:get(created_at, B, 0),
        maps:get(step_id, A),
        maps:get(step_id, B)
    ).

-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

-spec compare_asc(integer(), integer(), binary(), binary()) -> boolean().
compare_asc(Left, Right, _LeftId, _RightId) when Left < Right ->
    true;
compare_asc(Left, Right, _LeftId, _RightId) when Left > Right ->
    false;
compare_asc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.
