-module(beam_agent_coalesce_core).
-moduledoc """
ETS-based in-flight request coalescing (single-flight pattern).

When multiple callers concurrently request the same cache key, only the
first caller (the "leader") executes the actual work.  Subsequent callers
("followers") wait for the leader's result.  This prevents thundering-herd
problems and redundant CLI calls.

Process-free design: no resident processes are spawned.  Uses
`ets:insert_new/2` as an atomic CAS operation.  Leader and followers
communicate via standard Erlang message passing using the caller's own
processes.

Followers monitor the leader.  If the leader crashes mid-execution,
followers detect the DOWN and retry (one becomes the new leader).

## Benign Races

Concurrent callers may both attempt `insert_new` after the leader
finishes and deletes its entry.  At most one will win; the others
fall through to the follower path and immediately retry when they
see the inflight table is empty.  This self-heals with no data loss.
""".

-export([
    ensure_tables/0,
    execute_or_wait/2,
    execute_or_wait/3,
    clear/0
]).

-export_type([
    coalesce_opts/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type coalesce_opts() :: #{
    timeout => pos_integer()   %% Max wait time for followers (ms), default 60 000
}.

%%--------------------------------------------------------------------
%% Tables
%%--------------------------------------------------------------------

-define(INFLIGHT_TABLE, beam_agent_coalesce_inflight).
-define(WAITERS_TABLE, beam_agent_coalesce_waiters).

-define(DEFAULT_TIMEOUT, 60_000).
-define(MAX_RETRIES, 3).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the coalescing ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?INFLIGHT_TABLE,
        [set, named_table, {write_concurrency, true}]),
    beam_agent_ets:ensure_table(?WAITERS_TABLE,
        [bag, named_table, {write_concurrency, true}]),
    ok.

-doc "Clear all in-flight tracking state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?INFLIGHT_TABLE),
    beam_agent_ets:delete_all_objects(?WAITERS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc """
Execute `Fun` or wait for an in-flight execution with the same `Key`.

Convenience wrapper with default options.
""".
-spec execute_or_wait(binary(), fun(() -> term())) -> term().
execute_or_wait(Key, Fun) ->
    execute_or_wait(Key, Fun, #{}).

-doc """
Execute `Fun` or coalesce with an existing in-flight call for `Key`.

If no call is in flight for `Key`, this caller becomes the leader and
executes `Fun`.  If a call IS in flight, this caller waits for the
leader's result (up to `timeout` milliseconds).

Options:
  - `timeout` — follower wait timeout in ms (default 60 000)

The leader's return value is propagated to all followers.  If the
leader raises an exception, followers receive
`{error, {coalesce_leader_failed, {Class, Reason}}}`.

If the leader's process dies (e.g. killed), followers retry and one
becomes the new leader.  Retries are bounded to avoid infinite loops.
""".
-spec execute_or_wait(binary(), fun(() -> term()), coalesce_opts()) -> term().
execute_or_wait(Key, Fun, Opts) when is_binary(Key), is_function(Fun, 0) ->
    ensure_tables(),
    do_execute_or_wait(Key, Fun, Opts, 0).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec do_execute_or_wait(binary(), fun(() -> term()), coalesce_opts(),
                         non_neg_integer()) -> term().
do_execute_or_wait(_Key, Fun, _Opts, Retries) when Retries >= ?MAX_RETRIES ->
    %% Exhausted retries — just execute directly to avoid deadlock
    Fun();
do_execute_or_wait(Key, Fun, Opts, Retries) ->
    case beam_agent_ets:insert_new(?INFLIGHT_TABLE, {Key, self()}) of
        true ->
            leader_execute(Key, Fun);
        false ->
            follower_wait(Key, Fun, Opts, Retries)
    end.

-spec leader_execute(binary(), fun(() -> term())) -> term().
leader_execute(Key, Fun) ->
    try Fun() of
        Result ->
            broadcast_and_cleanup(Key, {ok, Result}),
            Result
    catch
        Class:Reason:Stack ->
            broadcast_and_cleanup(Key, {error, {Class, Reason}}),
            erlang:raise(Class, Reason, Stack)
    end.

%% Dialyzer narrows the error tuple further than the spec — intentional.
-dialyzer({nowarn_function, [broadcast_and_cleanup/2, unwrap_result/1]}).
-spec broadcast_and_cleanup(binary(), {ok, term()} | {error, term()}) -> ok.
broadcast_and_cleanup(Key, Result) ->
    Waiters = beam_agent_ets:lookup(?WAITERS_TABLE, Key),
    lists:foreach(fun({_Key, Pid, Ref}) ->
        Pid ! {beam_agent_coalesce, Ref, Result}
    end, Waiters),
    beam_agent_ets:match_delete(?WAITERS_TABLE, {Key, '_', '_'}),
    beam_agent_ets:delete(?INFLIGHT_TABLE, Key),
    ok.

-spec follower_wait(binary(), fun(() -> term()), coalesce_opts(),
                    non_neg_integer()) -> term().
follower_wait(Key, Fun, Opts, Retries) ->
    Ref = make_ref(),
    beam_agent_ets:insert(?WAITERS_TABLE, {Key, self(), Ref}),
    %% Race check: leader may have finished between our insert_new
    %% and waiter registration.
    case beam_agent_ets:lookup(?INFLIGHT_TABLE, Key) of
        [] ->
            %% Leader already finished — check if we got the message
            beam_agent_ets:delete_object(?WAITERS_TABLE, {Key, self(), Ref}),
            receive
                {beam_agent_coalesce, Ref, Result} ->
                    unwrap_result(Result)
            after 0 ->
                %% Missed the broadcast — retry (will likely become leader)
                do_execute_or_wait(Key, Fun, Opts, Retries + 1)
            end;
        [{Key, LeaderPid}] ->
            MonRef = monitor(process, LeaderPid),
            Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
            receive
                {beam_agent_coalesce, Ref, Result} ->
                    demonitor(MonRef, [flush]),
                    unwrap_result(Result);
                {'DOWN', MonRef, process, LeaderPid, _Reason} ->
                    %% Leader died — check if result was sent before death
                    beam_agent_ets:delete_object(
                        ?WAITERS_TABLE, {Key, self(), Ref}),
                    %% Only delete inflight if it's still the dead leader
                    beam_agent_ets:delete_object(
                        ?INFLIGHT_TABLE, {Key, LeaderPid}),
                    receive
                        {beam_agent_coalesce, Ref, Result} ->
                            unwrap_result(Result)
                    after 0 ->
                        %% No result from dead leader — retry
                        do_execute_or_wait(Key, Fun, Opts, Retries + 1)
                    end
            after Timeout ->
                demonitor(MonRef, [flush]),
                beam_agent_ets:delete_object(
                    ?WAITERS_TABLE, {Key, self(), Ref}),
                error(coalesce_timeout)
            end
    end.

-spec unwrap_result({ok, term()} | {error, term()}) -> term().
unwrap_result({ok, Result}) ->
    Result;
unwrap_result({error, {Class, Reason}}) ->
    error({coalesce_leader_failed, {Class, Reason}}).
