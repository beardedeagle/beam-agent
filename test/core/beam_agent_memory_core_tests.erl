%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_memory_core.
%%%-------------------------------------------------------------------
-module(beam_agent_memory_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tables_idempotent_test() ->
    ok = beam_agent_memory_core:ensure_tables(),
    ok = beam_agent_memory_core:ensure_tables(),
    reset().

remember_and_get_roundtrip_test() ->
    reset(),
    SessionId = unique_binary("memory-session"),
    {ok, Memory} = beam_agent_memory_core:remember(SessionId, #{
        kind => note,
        content => <<"Remember the diff pipeline">>,
        attributes => #{topic => <<"release">>},
        salience => 10
    }),
    ?assertMatch(<<"memory_", _/binary>>, maps:get(memory_id, Memory)),
    ?assertEqual(#{session_id => SessionId}, maps:get(scope, Memory)),
    {ok, Stored} = beam_agent_memory_core:get(maps:get(memory_id, Memory)),
    ?assertEqual(maps:get(memory_id, Memory), maps:get(memory_id, Stored)),
    {ok, [Listed]} = beam_agent_memory_core:list(#{session_id => SessionId}),
    ?assertEqual(maps:get(memory_id, Memory), maps:get(memory_id, Listed)),
    reset().

remember_derives_scope_from_run_and_artifact_refs_test() ->
    reset(),
    SessionId = unique_binary("memory-run-session"),
    ThreadId = unique_binary("memory-run-thread"),
    {ok, Run} = beam_agent_runs_core:start_run(#{
        session_id => SessionId,
        thread_id => ThreadId
    }, #{
        kind => workflow
    }),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        run_id => maps:get(run_id, Run),
        kind => summary,
        title => <<"Memory Artifact">>,
        body => <<"artifact body">>
    }),
    {ok, Memory} = beam_agent_memory_core:remember(#{}, #{
        content => <<"Derived from artifact">>,
        source_refs => [
            #{type => artifact, id => maps:get(artifact_id, Artifact)}
        ]
    }),
    Scope = maps:get(scope, Memory),
    ?assertEqual(SessionId, maps:get(session_id, Scope)),
    ?assertEqual(ThreadId, maps:get(thread_id, Scope)),
    ?assertEqual(maps:get(run_id, Run), maps:get(run_id, Scope)),
    reset().

remember_rejects_thread_without_session_test() ->
    reset(),
    ?assertEqual({error, session_id_required_for_thread},
        beam_agent_memory_core:remember(#{thread_id => <<"thread-only">>}, #{
            content => <<"bad scope">>
        })),
    reset().

remember_rejects_inconsistent_artifact_scope_test() ->
    reset(),
    {ok, Run} = beam_agent_runs_core:start_run(#{
        session_id => <<"artifact-scope-session">>,
        thread_id => <<"artifact-scope-thread">>
    }, #{
        kind => workflow
    }),
    {ok, Artifact} = beam_agent_artifacts_core:put(#{
        run_id => maps:get(run_id, Run),
        kind => summary,
        title => <<"Scoped Artifact">>,
        body => <<"artifact body">>
    }),
    ?assertEqual({error, inconsistent_artifact_scope},
        beam_agent_memory_core:remember(<<"other-session">>, #{
            content => <<"scope mismatch">>,
            source_refs => [
                #{type => artifact, id => maps:get(artifact_id, Artifact)}
            ]
        })),
    reset().

recall_scopes_search_results_test() ->
    reset(),
    {ok, _One} = beam_agent_memory_core:remember(<<"recall-session-one">>, #{
        content => <<"deploy with safer diff path">>,
        salience => 1
    }),
    {ok, _Two} = beam_agent_memory_core:remember(<<"recall-session-two">>, #{
        content => <<"deploy with safer diff path">>,
        salience => 1
    }),
    {ok, [Match]} = beam_agent_memory_core:recall(
        <<"recall-session-one">>,
        <<"safer diff">>
    ),
    ?assertEqual(<<"recall-session-one">>,
        maps:get(session_id, maps:get(scope, Match))),
    reset().

search_prefers_pinned_and_salience_test() ->
    reset(),
    {ok, _Low} = beam_agent_memory_core:remember(<<"search-rank">>, #{
        content => <<"alpha beta gamma">>,
        salience => 1
    }),
    {ok, High} = beam_agent_memory_core:remember(<<"search-rank">>, #{
        content => <<"alpha beta gamma">>,
        salience => 20
    }),
    ok = beam_agent_memory_core:pin(maps:get(memory_id, High)),
    {ok, [First | _Rest]} = beam_agent_memory_core:search(<<"alpha beta">>, #{
        session_id => <<"search-rank">>
    }),
    ?assertEqual(maps:get(memory_id, High), maps:get(memory_id, First)),
    reset().

pin_unpin_forget_and_journal_events_test() ->
    reset(),
    {ok, Memory} = beam_agent_memory_core:remember(<<"memory-journal">>, #{
        content => <<"journal this memory">>
    }),
    MemoryId = maps:get(memory_id, Memory),
    ok = beam_agent_memory_core:pin(MemoryId),
    ok = beam_agent_memory_core:unpin(MemoryId),
    ok = beam_agent_memory_core:forget(MemoryId),
    ?assertEqual({error, not_found}, beam_agent_memory_core:get(MemoryId)),
    {ok, Entries} = beam_agent_journal_core:list(#{tag => memory}),
    EventTypes = [maps:get(event_type, Entry) || Entry <- Entries],
    ?assertEqual([
        <<"memory_remembered">>,
        <<"memory_pinned">>,
        <<"memory_unpinned">>,
        <<"memory_forgotten">>
    ], EventTypes),
    reset().

list_excludes_expired_by_default_but_can_include_expired_test() ->
    reset(),
    {ok, Expired} = beam_agent_memory_core:remember(<<"memory-expired-list">>, #{
        content => <<"expired now">>,
        ttl => 0
    }),
    ?assertEqual({ok, []},
        beam_agent_memory_core:list(#{session_id => <<"memory-expired-list">>})),
    {ok, [VisibleExpired]} = beam_agent_memory_core:list(#{
        session_id => <<"memory-expired-list">>,
        include_expired => true
    }),
    ?assertEqual(maps:get(memory_id, Expired), maps:get(memory_id, VisibleExpired)),
    reset().

expire_removes_unpinned_memories_only_test() ->
    reset(),
    {ok, Expired} = beam_agent_memory_core:remember(<<"memory-expire">>, #{
        content => <<"expire me">>,
        ttl => 0
    }),
    {ok, Pinned} = beam_agent_memory_core:remember(<<"memory-expire">>, #{
        content => <<"keep me">>,
        ttl => 0,
        pinned => true
    }),
    {ok, 1} = beam_agent_memory_core:expire(#{session_id => <<"memory-expire">>}),
    ?assertEqual({error, not_found},
        beam_agent_memory_core:get(maps:get(memory_id, Expired))),
    {ok, _Pinned} = beam_agent_memory_core:get(maps:get(memory_id, Pinned)),
    {ok, Entries} = beam_agent_journal_core:list(#{tag => memory}),
    ?assert(lists:member(<<"memory_expired">>,
        [maps:get(event_type, Entry) || Entry <- Entries])),
    reset().

reset() ->
    ok = beam_agent_memory_core:clear(),
    ok = beam_agent_runs_core:clear(),
    ok = beam_agent_artifacts_core:clear(),
    ok = beam_agent_journal_core:clear().

unique_binary(Prefix) ->
    list_to_binary(io_lib:format("~s-~p", [Prefix,
        erlang:unique_integer([positive, monotonic])])).
