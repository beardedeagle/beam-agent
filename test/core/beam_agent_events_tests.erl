%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_events (universal event stream).
%%%
%%% Tests cover:
%%%   - Subscribe, publish, and receive events
%%%   - Complete (end-of-stream) signal
%%%   - Publish to dead subscriber (no crash, message discarded)
%%%   - cleanup_dead_subscriber removes ETS records
%%%   - cleanup_dead_subscriber is idempotent
%%%   - Hardened mode: automatic cleanup on subscriber death
%%%   - monitor_for_cleanup returns ignored in public mode
%%%
%%% All tests use real ETS tables and real processes — zero mocks.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_events_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test helpers
%%====================================================================

%% Tear down hardened mode state and restore a clean slate.
%% Kills the owner, erases persistent terms, and deletes event tables
%% so they can be recreated fresh in the correct mode.
cleanup_hardened() ->
    case beam_agent_table_owner:owner_pid() of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            unlink(Pid),
            exit(Pid, kill),
            wait_for_death(Pid)
    end,
    _ = persistent_term:erase(beam_agent_table_access_mode),
    _ = persistent_term:erase(beam_agent_table_owner_pid),
    _ = persistent_term:erase(beam_agent_tables_initialized),
    flush_transfers(),
    delete_table_if_exists(beam_agent_event_subscriptions),
    delete_table_if_exists(beam_agent_event_session_refs),
    ok.

wait_for_death(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        error({process_still_alive, Pid})
    end.

flush_transfers() ->
    receive
        {'ETS-TRANSFER', _, _, _} -> flush_transfers()
    after 0 -> ok
    end.

delete_table_if_exists(Name) ->
    case ets:whereis(Name) of
        undefined -> ok;
        _Tid ->
            try ets:delete(Name)
            catch error:badarg -> ok
            end
    end.

%%====================================================================
%% Basic subscribe/publish/receive tests
%%====================================================================

subscribe_publish_receive_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"events-session">>),
    ok = beam_agent_events:publish(<<"events-session">>,
        #{type => system, subtype => <<"tick">>}),
    ?assertEqual({ok, #{type => system, subtype => <<"tick">>}},
        beam_agent_events:receive_event(Ref, 0)),
    ?assertEqual(ok, beam_agent_events:unsubscribe(<<"events-session">>, Ref)),
    ok = beam_agent_events:clear().

complete_stream_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"events-complete">>),
    ok = beam_agent_events:complete(<<"events-complete">>),
    ?assertEqual({error, complete}, beam_agent_events:receive_event(Ref, 0)),
    ok = beam_agent_events:clear().

%%====================================================================
%% Dead subscriber tests (Path 3 — send blindly, no is_process_alive)
%%====================================================================

publish_to_dead_subscriber_no_crash_test() ->
    %% Publishing to a dead subscriber must not crash.
    %% The BEAM silently discards messages sent to dead pids.
    ok = beam_agent_events:clear(),
    Self = self(),
    Subscriber = spawn(fun() ->
        {ok, Ref} = beam_agent_events:subscribe(<<"dead-sub">>),
        Self ! {subscribed, Ref},
        receive stop -> ok end
    end),
    Ref = receive {subscribed, R} -> R after 5000 -> error(timeout) end,
    %% Kill the subscriber.
    exit(Subscriber, kill),
    wait_for_death(Subscriber),
    %% Publish — must not crash despite the subscriber being dead.
    ?assertEqual(ok, beam_agent_events:publish(<<"dead-sub">>,
        #{event => test})),
    %% Clean up the stale ETS entry manually (public mode pattern).
    beam_agent_events:cleanup_dead_subscriber(<<"dead-sub">>, Ref),
    ok = beam_agent_events:clear().

publish_multiple_with_mixed_liveness_test() ->
    %% One subscriber alive, one dead. Publish delivers to the live one
    %% and silently skips the dead one.
    ok = beam_agent_events:clear(),
    Self = self(),
    %% Live subscriber (this process).
    {ok, LiveRef} = beam_agent_events:subscribe(<<"mixed-sub">>),
    %% Dead subscriber.
    Doomed = spawn(fun() ->
        {ok, Ref} = beam_agent_events:subscribe(<<"mixed-sub">>),
        Self ! {subscribed, Ref},
        receive stop -> ok end
    end),
    DeadRef = receive {subscribed, R} -> R after 5000 -> error(timeout) end,
    exit(Doomed, kill),
    wait_for_death(Doomed),
    %% Publish — live subscriber should receive the event.
    ok = beam_agent_events:publish(<<"mixed-sub">>, #{event => hello}),
    ?assertEqual({ok, #{event => hello}},
        beam_agent_events:receive_event(LiveRef, 0)),
    %% Clean up.
    beam_agent_events:cleanup_dead_subscriber(<<"mixed-sub">>, DeadRef),
    ok = beam_agent_events:unsubscribe(<<"mixed-sub">>, LiveRef),
    ok = beam_agent_events:clear().

%%====================================================================
%% cleanup_dead_subscriber tests
%%====================================================================

cleanup_dead_subscriber_removes_records_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"cleanup-test">>),
    %% Verify records exist.
    ?assertNotEqual([], ets:lookup(beam_agent_event_subscriptions, Ref)),
    ?assertNotEqual([],
        ets:lookup(beam_agent_event_session_refs, <<"cleanup-test">>)),
    %% Clean up.
    ?assertEqual(ok, beam_agent_events:cleanup_dead_subscriber(
        <<"cleanup-test">>, Ref)),
    %% Records are gone.
    ?assertEqual([], ets:lookup(beam_agent_event_subscriptions, Ref)),
    ?assertEqual([],
        ets:lookup(beam_agent_event_session_refs, <<"cleanup-test">>)),
    ok = beam_agent_events:clear().

cleanup_dead_subscriber_idempotent_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"idempotent-test">>),
    ?assertEqual(ok, beam_agent_events:cleanup_dead_subscriber(
        <<"idempotent-test">>, Ref)),
    %% Second call is a no-op — no crash.
    ?assertEqual(ok, beam_agent_events:cleanup_dead_subscriber(
        <<"idempotent-test">>, Ref)),
    ok = beam_agent_events:clear().

%%====================================================================
%% Public mode monitor tests
%%====================================================================

monitor_for_cleanup_ignored_in_public_mode_test() ->
    %% In public mode, monitor_for_cleanup returns ignored because
    %% there is no owner process to receive DOWN messages.
    cleanup_hardened(),
    ok = beam_agent_table_owner:init(#{table_access => public}),
    ?assertEqual(ignored, beam_agent_table_owner:monitor_for_cleanup(
        self(),
        {beam_agent_events, cleanup_dead_subscriber,
         [<<"x">>, make_ref()]})),
    cleanup_hardened().

%%====================================================================
%% Hardened mode integration tests (Path 2 — owner monitors subs)
%%====================================================================

hardened_auto_cleanup_on_subscriber_death_test() ->
    %% In hardened mode, the table owner monitors subscribers.
    %% When a subscriber dies, the owner executes the cleanup callback
    %% and removes the ETS records automatically.
    cleanup_hardened(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    ok = beam_agent_events:ensure_tables(),
    Self = self(),
    Subscriber = spawn(fun() ->
        {ok, Ref} = beam_agent_events:subscribe(<<"hardened-test">>),
        Self ! {subscribed, Ref},
        receive stop -> ok end
    end),
    Ref = receive {subscribed, R} -> R after 5000 -> error(timeout) end,
    %% Verify ETS records exist.
    ?assertNotEqual([], ets:lookup(beam_agent_event_subscriptions, Ref)),
    ?assertNotEqual([],
        ets:lookup(beam_agent_event_session_refs, <<"hardened-test">>)),
    %% Kill the subscriber — the table owner should clean up via DOWN.
    exit(Subscriber, kill),
    wait_for_death(Subscriber),
    %% Give the owner loop one iteration to process the DOWN message.
    timer:sleep(50),
    %% ETS records should be gone — cleaned up automatically.
    ?assertEqual([], ets:lookup(beam_agent_event_subscriptions, Ref)),
    ?assertEqual([],
        ets:lookup(beam_agent_event_session_refs, <<"hardened-test">>)),
    cleanup_hardened().

hardened_multiple_subscribers_independent_cleanup_test() ->
    %% Killing one subscriber must not affect another.
    cleanup_hardened(),
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    ok = beam_agent_events:ensure_tables(),
    Self = self(),
    %% Subscriber A — will be killed.
    SubA = spawn(fun() ->
        {ok, Ref} = beam_agent_events:subscribe(<<"multi-hard">>),
        Self ! {sub_a, Ref},
        receive stop -> ok end
    end),
    RefA = receive {sub_a, RA} -> RA after 5000 -> error(timeout) end,
    %% Subscriber B — stays alive.
    SubB = spawn(fun() ->
        {ok, Ref} = beam_agent_events:subscribe(<<"multi-hard">>),
        Self ! {sub_b, Ref},
        receive stop -> ok end
    end),
    RefB = receive {sub_b, RB} -> RB after 5000 -> error(timeout) end,
    %% Kill A only.
    exit(SubA, kill),
    wait_for_death(SubA),
    timer:sleep(50),
    %% A's records are cleaned up.
    ?assertEqual([], ets:lookup(beam_agent_event_subscriptions, RefA)),
    %% B's records are untouched.
    ?assertNotEqual([], ets:lookup(beam_agent_event_subscriptions, RefB)),
    %% Clean up B.
    exit(SubB, kill),
    wait_for_death(SubB),
    timer:sleep(50),
    ?assertEqual([], ets:lookup(beam_agent_event_subscriptions, RefB)),
    cleanup_hardened().
