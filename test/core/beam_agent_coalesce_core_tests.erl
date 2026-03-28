%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_coalesce_core.
%%%
%%% Tests the ETS-based single-flight (request coalescing) pattern.
%%% No mocks — real concurrent processes exercise leader/follower
%%% coordination.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_coalesce_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

setup() ->
    beam_agent_coalesce_core:ensure_tables(),
    beam_agent_coalesce_core:clear(),
    ok.

%%====================================================================
%% Basic functionality
%%====================================================================

single_caller_executes_directly_test() ->
    setup(),
    Key = <<"single-caller">>,
    Result = beam_agent_coalesce_core:execute_or_wait(Key, fun() -> 42 end),
    ?assertEqual(42, Result).

single_caller_returns_complex_result_test() ->
    setup(),
    Key = <<"complex-result">>,
    Expected = {ok, [#{type => text, content => <<"hello">>}]},
    Result = beam_agent_coalesce_core:execute_or_wait(Key,
        fun() -> Expected end),
    ?assertEqual(Expected, Result).

different_keys_execute_independently_test() ->
    setup(),
    R1 = beam_agent_coalesce_core:execute_or_wait(<<"k1">>,
        fun() -> one end),
    R2 = beam_agent_coalesce_core:execute_or_wait(<<"k2">>,
        fun() -> two end),
    ?assertEqual(one, R1),
    ?assertEqual(two, R2).

%%====================================================================
%% Concurrent coalescing
%%====================================================================

concurrent_callers_coalesce_test() ->
    setup(),
    Key = <<"concurrent">>,
    Self = self(),
    CallCount = counters:new(1, [atomics]),
    %% Leader takes 50ms to complete
    Fun = fun() ->
        counters:add(CallCount, 1, 1),
        timer:sleep(50),
        the_result
    end,
    %% Test process becomes leader first
    _Leader = spawn(fun() ->
        R = beam_agent_coalesce_core:execute_or_wait(Key, Fun),
        Self ! {done, self(), R}
    end),
    timer:sleep(5),
    %% Spawn 4 followers that all request the same key
    Followers = [spawn(fun() ->
        R = beam_agent_coalesce_core:execute_or_wait(Key, Fun),
        Self ! {done, self(), R}
    end) || _ <- lists:seq(1, 4)],
    AllPids = [_Leader | Followers],
    %% Collect all results
    Results = [receive {done, P, R} -> R after 5000 -> timeout end
               || P <- AllPids],
    %% All callers got the same result
    lists:foreach(fun(R) ->
        ?assertEqual(the_result, R)
    end, Results),
    %% Fun was called at most twice (leader + maybe one race retry)
    ?assert(counters:get(CallCount, 1) =< 2).

%%====================================================================
%% Error handling
%%====================================================================

leader_exception_propagates_to_leader_test() ->
    setup(),
    Key = <<"error-leader">>,
    ?assertError(boom,
        beam_agent_coalesce_core:execute_or_wait(Key,
            fun() -> error(boom) end)).

leader_exception_propagates_to_followers_test() ->
    setup(),
    Key = <<"error-follower">>,
    Self = self(),
    %% Slow-failing leader
    Fun = fun() ->
        timer:sleep(30),
        error(kaboom)
    end,
    %% First process becomes leader (not linked — it will crash)
    Leader = spawn(fun() ->
        try
            beam_agent_coalesce_core:execute_or_wait(Key, Fun)
        catch _:_ -> ok
        end,
        Self ! {leader_done, self()}
    end),
    timer:sleep(5),
    %% Follower (not linked — catches the propagated error)
    Follower = spawn(fun() ->
        try
            beam_agent_coalesce_core:execute_or_wait(Key, Fun),
            Self ! {done, self(), unexpected_success}
        catch
            error:{coalesce_leader_failed, {error, kaboom}} ->
                Self ! {done, self(), got_error};
            error:kaboom ->
                %% Became leader via retry and hit the same error
                Self ! {done, self(), got_error}
        end
    end),
    %% Wait for both
    receive {leader_done, Leader} -> ok after 5000 -> error(leader_timeout) end,
    receive {done, Follower, got_error} -> ok after 5000 -> error(follower_timeout) end.

%%====================================================================
%% Leader crash recovery
%%====================================================================

follower_retries_on_leader_death_test() ->
    setup(),
    Key = <<"leader-death">>,
    Self = self(),
    %% Spawn a leader that dies mid-execution
    Leader = spawn(fun() ->
        beam_agent_coalesce_core:execute_or_wait(Key, fun() ->
            timer:sleep(100),
            never_reached
        end)
    end),
    timer:sleep(10),
    %% Spawn a follower (not linked)
    Follower = spawn(fun() ->
        R = beam_agent_coalesce_core:execute_or_wait(Key,
            fun() -> recovered end),
        Self ! {done, self(), R}
    end),
    timer:sleep(10),
    %% Kill the leader
    exit(Leader, kill),
    %% Follower should retry and become new leader
    receive
        {done, Follower, recovered} -> ok
    after 5000 ->
        error(follower_did_not_recover)
    end.

%%====================================================================
%% Timeout
%%====================================================================

follower_timeout_raises_error_test() ->
    setup(),
    Key = <<"timeout">>,
    Self = self(),
    %% Spawn a slow leader
    SlowLeader = spawn(fun() ->
        beam_agent_coalesce_core:execute_or_wait(Key, fun() ->
            timer:sleep(10_000),
            slow_result
        end)
    end),
    timer:sleep(10),
    %% Follower with short timeout (not linked)
    Follower = spawn(fun() ->
        try
            beam_agent_coalesce_core:execute_or_wait(Key,
                fun() -> fallback end,
                #{timeout => 50}),
            Self ! {done, self(), unexpected_success}
        catch
            error:coalesce_timeout ->
                Self ! {done, self(), got_timeout}
        end
    end),
    receive
        {done, Follower, got_timeout} -> ok
    after 5000 ->
        error(follower_did_not_timeout)
    end,
    %% Clean up the slow leader
    exit(SlowLeader, kill).

%%====================================================================
%% Table lifecycle
%%====================================================================

ensure_tables_is_idempotent_test() ->
    ok = beam_agent_coalesce_core:ensure_tables(),
    ok = beam_agent_coalesce_core:ensure_tables(),
    ok = beam_agent_coalesce_core:ensure_tables().

clear_wipes_state_test() ->
    setup(),
    ok = beam_agent_coalesce_core:clear().

%%====================================================================
%% Cleanup after execution
%%====================================================================

inflight_table_is_clean_after_execution_test() ->
    setup(),
    Key = <<"cleanup-check">>,
    _ = beam_agent_coalesce_core:execute_or_wait(Key, fun() -> ok end),
    ?assertEqual([], ets:lookup(beam_agent_coalesce_inflight, Key)).

inflight_table_is_clean_after_error_test() ->
    setup(),
    Key = <<"cleanup-error">>,
    try
        beam_agent_coalesce_core:execute_or_wait(Key,
            fun() -> error(oops) end)
    catch
        error:oops -> ok
    end,
    ?assertEqual([], ets:lookup(beam_agent_coalesce_inflight, Key)).
