%%%-------------------------------------------------------------------
%%% @doc Telemetry emission tests for canonical BeamAgent domains.
%%%-------------------------------------------------------------------
-module(beam_agent_domain_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

run_lifecycle_emits_state_change_test() ->
    ensure_telemetry(),
    reset(),
    HandlerId = attach_handler([beam_agent, run, state_change]),
    {ok, Run} = beam_agent_runs_core:start_run(#{}, #{kind => telemetry}),
    receive
        {telemetry_event, [beam_agent, run, state_change], _Measurements, Metadata} ->
            ?assertEqual(created, maps:get(from_state, Metadata)),
            ?assertEqual(running, maps:get(to_state, Metadata)),
            ?assertEqual(maps:get(run_id, Run), maps:get(run_id, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(HandlerId),
    reset().

artifact_put_and_search_emit_spans_test() ->
    ensure_telemetry(),
    reset(),
    PutHandler = attach_handler([beam_agent, artifact, put, stop]),
    SearchHandler = attach_handler([beam_agent, artifact, search, stop]),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        kind => note,
        title => <<"Telemetry artifact">>,
        body => <<"searchable content">>,
        format => markdown
    }),
    {ok, [_]} = beam_agent_artifacts_core:search(<<"searchable">>),
    receive
        {telemetry_event, [beam_agent, artifact, put, stop], _Measurements, Metadata} ->
            ?assertEqual(maps:get(artifact_id, Artifact), maps:get(artifact_id, Metadata)),
            ?assertEqual(created, maps:get(operation, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    receive
        {telemetry_event, [beam_agent, artifact, search, stop], _Measurements2, Metadata2} ->
            ?assertEqual(1, maps:get(result_count, Metadata2))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(PutHandler),
    detach_handler(SearchHandler),
    reset().

journal_append_and_stream_emit_spans_test() ->
    ensure_telemetry(),
    reset(),
    AppendHandler = attach_handler([beam_agent, journal, append, stop]),
    StreamHandler = attach_handler([beam_agent, journal, stream_from, stop]),
    {ok, Entry} = beam_agent_journal_core:append(<<"telemetry_event">>, #{
        tags => [telemetry],
        payload => #{label => <<"journal">>}
    }),
    {ok, [Replay]} = beam_agent_journal_core:stream_from(0, #{
        event_type => <<"telemetry_event">>
    }),
    ?assertEqual(maps:get(event_id, Entry), maps:get(event_id, Replay)),
    receive
        {telemetry_event, [beam_agent, journal, append, stop], _Measurements, Metadata} ->
            ?assertEqual(maps:get(event_id, Entry), maps:get(event_id, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    receive
        {telemetry_event, [beam_agent, journal, stream_from, stop], _Measurements2, Metadata2} ->
            ?assertEqual(1, maps:get(result_count, Metadata2))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(AppendHandler),
    detach_handler(StreamHandler),
    reset().

memory_remember_and_search_emit_spans_test() ->
    ensure_telemetry(),
    reset(),
    RememberHandler = attach_handler([beam_agent, memory, remember, stop]),
    SearchHandler = attach_handler([beam_agent, memory, search, stop]),
    {ok, Memory} = beam_agent_memory_core:remember(#{}, #{
        kind => note,
        content => <<"beam agent telemetry memory">>,
        attributes => #{topic => telemetry}
    }),
    {ok, [_]} = beam_agent_memory_core:search(<<"telemetry">>),
    receive
        {telemetry_event, [beam_agent, memory, remember, stop], _Measurements, Metadata} ->
            ?assertEqual(maps:get(memory_id, Memory), maps:get(memory_id, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    receive
        {telemetry_event, [beam_agent, memory, search, stop], _Measurements2, Metadata2} ->
            ?assertEqual(1, maps:get(result_count, Metadata2))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(RememberHandler),
    detach_handler(SearchHandler),
    reset().

routing_select_backend_emits_span_test() ->
    ensure_telemetry(),
    reset(),
    HandlerId = attach_handler([beam_agent, routing, select_backend, stop]),
    {ok, Decision} = beam_agent_routing_core:select_backend(#{
        policy => preferred_then_fallback,
        preferred_backends => [gemini, codex]
    }),
    receive
        {telemetry_event, [beam_agent, routing, select_backend, stop], _Measurements, Metadata} ->
            ?assertEqual(maps:get(backend, Decision), maps:get(backend, Metadata)),
            ?assertEqual(allow, maps:get(decision, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(HandlerId),
    reset().

context_maybe_compact_emits_stop_and_state_change_test() ->
    ensure_telemetry(),
    reset(),
    StopHandler = attach_handler([beam_agent, context, maybe_compact, stop]),
    StateHandler = attach_handler([beam_agent, context, state_change]),
    SessionId = <<"telemetry-context-session">>,
    ThreadId = seed_thread(SessionId, <<"telemetry-context-thread">>, 3),
    {ok, Result} = beam_agent_context_core:maybe_compact(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        message_count_threshold => 2
    }),
    ?assertEqual(true, maps:get(compacted, Result)),
    receive
        {telemetry_event, [beam_agent, context, maybe_compact, stop], _Measurements, Metadata} ->
            ?assertEqual(true, maps:get(compacted, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    receive
        {telemetry_event, [beam_agent, context, state_change], _Measurements2, Metadata2} ->
            ?assertEqual(stable, maps:get(from_state, Metadata2)),
            ?assertEqual(compacted, maps:get(to_state, Metadata2)),
            ?assertEqual(SessionId, maps:get(session_id, Metadata2))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(StopHandler),
    detach_handler(StateHandler),
    reset().

routine_run_due_emits_execution_span_test() ->
    ensure_telemetry(),
    reset(),
    HandlerId = attach_handler([beam_agent, routine, run_due, stop]),
    Now = erlang:system_time(millisecond),
    {ok, _Job} = beam_agent_routines_core:create(#{
        schedule => #{type => once, at => Now - 10},
        target => #{
            type => run,
            outcome => completed,
            result => #{done => true}
        },
        metadata => #{label => telemetry}
    }),
    {ok, [Result]} = beam_agent_routine_runner:run_due(#{now => Now}),
    ?assertEqual(executed, maps:get(status, Result)),
    receive
        {telemetry_event, [beam_agent, routine, run_due, stop], _Measurements, Metadata} ->
            ?assertEqual(1, maps:get(due_count, Metadata)),
            ?assertEqual(1, maps:get(executed_count, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(HandlerId),
    reset().

orchestrator_delegate_emits_span_test() ->
    ensure_telemetry(),
    reset(),
    HandlerId = attach_handler([beam_agent, orchestrator, delegate, stop]),
    {ok, ParentRun} = beam_agent_runs_core:start_run(#{}, #{kind => parent}),
    ParentRunId = maps:get(run_id, ParentRun),
    {ok, ChildRun} = beam_agent_orchestrator_core:delegate(ParentRunId, #{goal => inspect}, #{}),
    receive
        {telemetry_event, [beam_agent, orchestrator, delegate, stop], _Measurements, Metadata} ->
            ?assertEqual(maps:get(run_id, ChildRun), maps:get(run_id, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(HandlerId),
    reset().

policy_and_audit_emit_spans_test() ->
    ensure_telemetry(),
    reset(),
    PolicyHandler = attach_handler([beam_agent, policy, evaluate, stop]),
    AuditHandler = attach_handler([beam_agent, audit, record, stop]),
    ProfileId = <<"telemetry-policy">>,
    ok = beam_agent_policy_core:put_profile(ProfileId, #{
        default => deny,
        rules => [
            #{action => backend, decision => allow, match => {eq, backend, gemini}}
        ]
    }),
    ?assertEqual(allow, beam_agent_policy_core:evaluate(ProfileId, backend, #{backend => gemini})),
    {ok, _Entry} = beam_agent_audit_core:record(policy, decision, #{
        profile_id => ProfileId
    }, #{
        decision => allow
    }),
    receive
        {telemetry_event, [beam_agent, policy, evaluate, stop], _Measurements, Metadata} ->
            ?assertEqual(allow, maps:get(decision, Metadata))
    after 1000 ->
        ?assert(false)
    end,
    receive
        {telemetry_event, [beam_agent, audit, record, stop], _Measurements2, Metadata2} ->
            ?assertEqual(ProfileId, maps:get(profile_id, Metadata2))
    after 1000 ->
        ?assert(false)
    end,
    detach_handler(PolicyHandler),
    detach_handler(AuditHandler),
    reset().

attach_handler(EventName) ->
    Self = self(),
    HandlerId = {telemetry_test, EventName, erlang:unique_integer([positive, monotonic])},
    ok = telemetry:attach(HandlerId, EventName,
        fun(ObservedEvent, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, ObservedEvent, Measurements, Metadata}
        end, []),
    HandlerId.

detach_handler(HandlerId) ->
    telemetry:detach(HandlerId).

ensure_telemetry() ->
    {ok, _} = application:ensure_all_started(telemetry).

seed_thread(SessionId, ThreadId, Count) ->
    {ok, _Thread} = beam_agent_threads_core:start_thread(SessionId, #{
        thread_id => ThreadId,
        name => ThreadId
    }),
    ok = lists:foreach(fun(Index) ->
        beam_agent_threads_core:record_thread_message(SessionId, ThreadId, #{
            type => user,
            content => list_to_binary(io_lib:format("message-~p", [Index]))
        })
    end, lists:seq(1, Count)),
    ThreadId.

reset() ->
    ok = beam_agent_orchestrator_core:clear(),
    ok = beam_agent_routines_core:clear(),
    ok = beam_agent_routing_core:clear(),
    ok = beam_agent_policy_core:clear(),
    ok = beam_agent_memory_core:clear(),
    ok = beam_agent_journal_core:clear(),
    ok = beam_agent_artifacts_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_session_store_core:clear().
