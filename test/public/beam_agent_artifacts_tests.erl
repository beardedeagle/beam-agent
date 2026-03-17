%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_artifacts.
%%%-------------------------------------------------------------------
-module(beam_agent_artifacts_tests).

-include_lib("eunit/include/eunit.hrl").

exports_artifact_surface_test() ->
    {module, beam_agent_artifacts} = code:ensure_loaded(beam_agent_artifacts),
    ?assert(erlang:function_exported(beam_agent_artifacts, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, put, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, put, 2)),
    ?assert(erlang:function_exported(beam_agent_artifacts, get, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, list, 0)),
    ?assert(erlang:function_exported(beam_agent_artifacts, list, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, search, 1)),
    ?assert(erlang:function_exported(beam_agent_artifacts, search, 2)),
    ?assert(erlang:function_exported(beam_agent_artifacts, attach, 3)),
    ?assert(erlang:function_exported(beam_agent_artifacts, delete, 1)).

public_artifact_roundtrip_test() ->
    ok = beam_agent_artifacts:clear(),
    ok = beam_agent_runs:clear(),
    {ok, Run} = beam_agent_runs:start_run(<<"public-artifact-session">>, #{}),
    RunId = maps:get(run_id, Run),
    {ok, Artifact} = beam_agent_artifacts:put(#{
        run_id => RunId,
        kind => summary,
        title => <<"Public Artifact">>,
        body => <<"ready">>
    }),
    ArtifactId = maps:get(artifact_id, Artifact),
    ok = beam_agent_artifacts:attach(ArtifactId, message, <<"msg-public">>),
    {ok, [Match]} = beam_agent_artifacts:search(<<"public">>),
    ?assertEqual(ArtifactId, maps:get(artifact_id, Match)),
    ok = beam_agent_artifacts:delete(ArtifactId),
    ?assertEqual({error, not_found}, beam_agent_artifacts:get(ArtifactId)),
    ok = beam_agent_artifacts:clear(),
    ok = beam_agent_runs:clear().
