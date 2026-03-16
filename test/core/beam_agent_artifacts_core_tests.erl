%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_artifacts_core.
%%%-------------------------------------------------------------------
-module(beam_agent_artifacts_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    ok = beam_agent_artifacts_core:ensure_tables(),
    ok = beam_agent_artifacts_core:ensure_tables(),
    ok = beam_agent_artifacts_core:ensure_tables(),
    reset().

put_generates_defaults_test() ->
    reset(),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        kind => plan,
        title => <<"Execution Plan">>,
        body => <<"1. Build\n2. Verify">>
    }),
    ?assertMatch(<<"artifact_", _/binary>>, maps:get(artifact_id, Artifact)),
    ?assertEqual(plan, maps:get(kind, Artifact)),
    ?assertEqual(plain_text, maps:get(format, Artifact)),
    ?assertEqual([], maps:get(source_refs, Artifact)),
    {ok, Artifact} = beam_agent_artifacts_core:get(maps:get(artifact_id, Artifact)),
    reset().

put_with_run_scope_infers_scope_refs_test() ->
    reset(),
    SessionId = <<"artifact-run-session">>,
    ThreadId = <<"artifact-run-thread">>,
    {ok, Run} = beam_agent_runs_core:start_run(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        kind => workflow
    }),
    RunId = maps:get(run_id, Run),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        run_id => RunId,
        kind => summary,
        body => <<"Completed">>
    }),
    ?assertEqual(SessionId, maps:get(session_id, Artifact)),
    ?assertEqual(ThreadId, maps:get(thread_id, Artifact)),
    ?assertEqual(RunId, maps:get(run_id, Artifact)),
    Refs = maps:get(source_refs, Artifact),
    ?assert(lists:any(fun(#{type := run, id := RunId0}) -> RunId0 =:= RunId; (_) -> false end, Refs)),
    ?assert(lists:any(fun(#{type := session, id := SessionId0}) -> SessionId0 =:= SessionId; (_) -> false end, Refs)),
    ?assert(lists:any(fun(#{type := thread, id := ThreadId0}) -> ThreadId0 =:= ThreadId; (_) -> false end, Refs)),
    reset().

put_updates_existing_artifact_preserves_created_at_test() ->
    reset(),
    ArtifactId = <<"artifact-explicit-1">>,
    {ok, First} = beam_agent_artifacts_core:put(#{
        artifact_id => ArtifactId,
        kind => diff,
        body => <<"before">>
    }),
    timer:sleep(2),
    {ok, Updated} = beam_agent_artifacts_core:put(#{
        artifact_id => ArtifactId,
        kind => diff,
        body => <<"after">>
    }),
    ?assertEqual(maps:get(created_at, First), maps:get(created_at, Updated)),
    ?assert(maps:get(updated_at, Updated) > maps:get(updated_at, First)),
    ?assertEqual(<<"after">>, maps:get(body, Updated)),
    reset().

put_rejects_thread_without_session_test() ->
    reset(),
    ?assertEqual({error, session_id_required_for_thread},
        beam_agent_artifacts_core:put(#{
            thread_id => <<"thread-only">>,
            body => <<"bad">>
        })),
    reset().

attach_run_ref_infers_scope_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(#{
        session_id => <<"attach-run-session">>,
        thread_id => <<"attach-run-thread">>
    }, #{}),
    RunId = maps:get(run_id, Run),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        kind => review,
        body => <<"Looks good">>
    }),
    ArtifactId = maps:get(artifact_id, Artifact),
    ok = beam_agent_artifacts_core:attach(ArtifactId, run, RunId),
    {ok, Attached} = beam_agent_artifacts_core:get(ArtifactId),
    ?assertEqual(RunId, maps:get(run_id, Attached)),
    ?assertEqual(<<"attach-run-session">>, maps:get(session_id, Attached)),
    ?assertEqual(<<"attach-run-thread">>, maps:get(thread_id, Attached)),
    reset().

attach_thread_without_session_requires_session_test() ->
    reset(),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{body => <<"orphan">>}),
    ?assertEqual({error, session_id_required_for_thread},
        beam_agent_artifacts_core:attach(
            maps:get(artifact_id, Artifact),
            thread,
            <<"thread-orphan">>
        )),
    reset().

search_matches_title_and_body_case_insensitive_test() ->
    reset(),
    {ok, _Artifact1} = beam_agent_artifacts_core:put(#{
        kind => plan,
        title => <<"Ship Plan">>,
        body => <<"Implement the artifact store">>
    }),
    {ok, _Artifact2} = beam_agent_artifacts_core:put(#{
        kind => review,
        title => <<"Review Notes">>,
        body => <<"Looks good">>
    }),
    {ok, Matches} = beam_agent_artifacts_core:search(<<"ship artifact">>),
    ?assertEqual(1, length(Matches)),
    [Match] = Matches,
    ?assertEqual(<<"Ship Plan">>, maps:get(title, Match)),
    reset().

list_filters_by_source_ref_test() ->
    reset(),
    {ok, Artifact1} = beam_agent_artifacts_core:put(#{
        kind => note,
        body => <<"alpha">>,
        source_refs => [#{type => message, id => <<"msg-1">>}]
    }),
    {ok, _Artifact2} = beam_agent_artifacts_core:put(#{
        kind => note,
        body => <<"beta">>,
        source_refs => [#{type => message, id => <<"msg-2">>}]
    }),
    {ok, Matches} = beam_agent_artifacts_core:list(#{
        source_ref_type => message,
        source_ref_id => <<"msg-1">>
    }),
    ?assertEqual(1, length(Matches)),
    [Match] = Matches,
    ?assertEqual(maps:get(artifact_id, Artifact1), maps:get(artifact_id, Match)),
    reset().

delete_removes_artifact_test() ->
    reset(),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{body => <<"delete me">>}),
    ArtifactId = maps:get(artifact_id, Artifact),
    ok = beam_agent_artifacts_core:delete(ArtifactId),
    ?assertEqual({error, not_found}, beam_agent_artifacts_core:get(ArtifactId)),
    reset().

journal_records_artifact_lifecycle_test() ->
    reset(),
    SessionId = <<"artifact-journal-session">>,
    {ok, Artifact0} = beam_agent_artifacts_core:put(SessionId, #{
        kind => summary,
        title => <<"Artifact Journal">>,
        body => <<"v1">>
    }),
    ArtifactId = maps:get(artifact_id, Artifact0),
    ok = beam_agent_artifacts_core:attach(ArtifactId, message, <<"msg-1">>),
    {ok, _Artifact1} = beam_agent_artifacts_core:put(SessionId, #{
        artifact_id => ArtifactId,
        kind => summary,
        title => <<"Artifact Journal">>,
        body => <<"v2">>
    }),
    ok = beam_agent_artifacts_core:delete(ArtifactId),
    {ok, Entries} = beam_agent_journal_core:list(#{session_id => SessionId, tag => artifact}),
    EventTypes = [maps:get(event_type, Entry) || Entry <- Entries],
    ?assertEqual([
        <<"artifact_created">>,
        <<"artifact_attached">>,
        <<"artifact_updated">>,
        <<"artifact_deleted">>
    ], EventTypes),
    reset().

reset() ->
    ok = beam_agent_artifacts_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_journal_core:clear().
