%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_routines_core and runner behavior.
%%%-------------------------------------------------------------------
-module(beam_agent_routines_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    ok = beam_agent_routines_core:ensure_tables(),
    ok = beam_agent_routines_core:ensure_tables(),
    reset().

create_once_job_persists_and_lists_by_filter_test() ->
    reset(),
    At = erlang:system_time(millisecond) + 1000,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(completed, #{result => #{ok => true}}),
        metadata => #{origin => unit}
    }),
    ?assertMatch(<<"routine_", _/binary>>, maps:get(job_id, Job)),
    ?assertEqual(active, maps:get(state, Job)),
    ?assertEqual(At, maps:get(next_run_at, Job)),
    {ok, Job} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    {ok, [Listed]} = beam_agent_routines_core:list(#{
        job_id => maps:get(job_id, Job)
    }),
    ?assertEqual(maps:get(job_id, Job), maps:get(job_id, Listed)),
    reset().

update_interval_job_recomputes_due_time_test() ->
    reset(),
    StartAt = erlang:system_time(millisecond) + 1000,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => interval, every_ms => 5000, start_at => StartAt},
        target => run_target(completed, #{result => done})
    }),
    {ok, Updated} = beam_agent_routines_core:update(maps:get(job_id, Job), #{
        schedule => #{type => interval, every_ms => 1000, start_at => StartAt + 250}
    }),
    ?assertEqual(StartAt + 250, maps:get(next_run_at, Updated)),
    reset().

cancelled_jobs_are_removed_from_due_listing_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(completed, #{result => ok})
    }),
    ok = beam_agent_routines_core:cancel(maps:get(job_id, Job)),
    {ok, []} = beam_agent_routines_core:list_due(),
    reset().

run_due_executes_once_job_and_marks_it_completed_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(completed, #{result => #{summary => <<"done">>}})
    }),
    {ok, [Result]} = beam_agent_routine_runner:run_due(),
    Run = maps:get(run, Result),
    ?assertEqual(executed, maps:get(status, Result)),
    ?assertEqual(completed, maps:get(status, Run)),
    {ok, StoredJob} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    ?assertEqual(completed, maps:get(state, StoredJob)),
    ?assertEqual(undefined, maps:get(next_run_at, StoredJob, undefined)),
    reset().

run_due_advances_interval_jobs_to_next_slot_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => interval, every_ms => 5000, start_at => At},
        target => run_target(completed, #{result => tick})
    }),
    {ok, [_Result]} = beam_agent_routine_runner:run_due(),
    {ok, StoredJob} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    ?assertEqual(active, maps:get(state, StoredJob)),
    ?assert(maps:get(next_run_at, StoredJob) >= At + 5000),
    reset().

run_due_deduplicates_same_slot_via_execution_record_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, _Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(completed, #{result => ok}),
        idempotency_key => <<"same-slot">>
    }),
    {ok, [First]} = beam_agent_routine_runner:run_due(),
    {ok, []} = beam_agent_routine_runner:run_due(),
    ?assertEqual(executed, maps:get(status, First)),
    {ok, Entries} = beam_agent_journal_core:list(#{tag => routine}),
    EventTypes = [maps:get(event_type, Entry) || Entry <- Entries],
    ?assert(lists:member(<<"routine_run_completed">>, EventTypes)),
    reset().

failed_once_job_uses_retry_backoff_then_exhausts_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(failed, #{error => #{reason => <<"boom">>}}),
        retry_policy => #{max_attempts => 2, backoff_ms => 25}
    }),
    {ok, [_First]} = beam_agent_routine_runner:run_due(),
    {ok, AfterFirst} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    ?assert(lists:member(maps:get(state, AfterFirst), [active, retry_waiting])),
    ?assert(maps:get(next_run_at, AfterFirst) > At),
    RetryAt = maps:get(next_run_at, AfterFirst),
    {ok, [_Second]} = beam_agent_routine_runner:run_due(#{now => RetryAt}),
    {ok, Exhausted} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    ?assertEqual(exhausted, maps:get(state, Exhausted)),
    ?assertEqual(undefined, maps:get(next_run_at, Exhausted, undefined)),
    reset().

run_now_executes_without_advancing_interval_schedule_test() ->
    reset(),
    StartAt = erlang:system_time(millisecond) + 5000,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => interval, every_ms => 1000, start_at => StartAt},
        target => run_target(completed, #{result => manual})
    }),
    {ok, Run} = beam_agent_routine_runner:run_now(maps:get(job_id, Job)),
    ?assertEqual(completed, maps:get(status, Run)),
    {ok, StoredJob} = beam_agent_routines_core:get(maps:get(job_id, Job)),
    ?assertEqual(active, maps:get(state, StoredJob)),
    ?assertEqual(StartAt, maps:get(next_run_at, StoredJob)),
    reset().

next_due_at_returns_earliest_due_timestamp_test() ->
    reset(),
    At1 = erlang:system_time(millisecond) + 1000,
    At2 = At1 + 500,
    {ok, _Job1} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At2},
        target => run_target(completed, #{result => later})
    }),
    {ok, _Job2} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At1},
        target => run_target(completed, #{result => sooner})
    }),
    ?assertEqual({ok, At1}, beam_agent_routines_core:next_due_at()),
    reset().

journal_records_routine_lifecycle_events_test() ->
    reset(),
    At = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => At},
        target => run_target(completed, #{result => ok})
    }),
    {ok, [_]} = beam_agent_routine_runner:run_due(),
    {ok, Entries} = beam_agent_journal_core:list(#{tag => routine}),
    EventTypes = [maps:get(event_type, Entry) || Entry <- Entries],
    ?assert(lists:member(<<"routine_created">>, EventTypes)),
    ?assert(lists:member(<<"routine_run_completed">>, EventTypes)),
    ok = beam_agent_routines_core:cancel(maps:get(job_id, Job)),
    {ok, AfterCancelEntries} = beam_agent_journal_core:list(#{tag => routine}),
    AfterCancelTypes = [maps:get(event_type, Entry) || Entry <- AfterCancelEntries],
    ?assert(lists:member(<<"routine_cancelled">>, AfterCancelTypes)),
    reset().

run_target(Outcome, Extra) ->
    maps:merge(#{
        type => run,
        scope => <<"routine-test-session">>,
        run_opts => #{kind => routine},
        outcome => Outcome
    }, Extra).

reset() ->
    ok = beam_agent_routines_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_journal_core:clear().
