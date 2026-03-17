%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_orchestrator.
%%%-------------------------------------------------------------------
-module(beam_agent_orchestrator_tests).

-include_lib("eunit/include/eunit.hrl").

exports_orchestrator_surface_test() ->
    {module, beam_agent_orchestrator} = code:ensure_loaded(beam_agent_orchestrator),
    ?assert(erlang:function_exported(beam_agent_orchestrator, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, spawn, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, delegate, 3)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, await, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, collect, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, cancel, 2)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, status, 1)),
    ?assert(erlang:function_exported(beam_agent_orchestrator, list_children, 1)).

public_orchestrator_roundtrip_test() ->
    reset(),
    SessionId = unique_binary("public-orchestrator-session"),
    beam_agent_test_helpers:register_session(SessionId, gemini),
    {ok, ParentRun} = beam_agent_runs:start_run(SessionId, #{kind => parent}),
    ParentRunId = maps:get(run_id, ParentRun),
    {ok, ChildRun} = beam_agent_orchestrator:delegate(ParentRunId, #{task => <<"review">>}, #{
        metadata => #{origin => public_test}
    }),
    ChildRunId = maps:get(run_id, ChildRun),
    {ok, _CompletedChild} = beam_agent_runs:complete_run(ChildRunId, #{approved => true}),
    {ok, Status} = beam_agent_orchestrator:status(ChildRunId),
    ?assertEqual(0, maps:get(child_count, Status)),
    {ok, Collected} = beam_agent_orchestrator:collect(ChildRunId, #{}),
    LinkTask = maps:get(task, maps:get(link, Collected)),
    ?assertEqual(<<"review">>, maps:get(task, LinkTask)),
    {ok, [Listed]} = beam_agent_orchestrator:list_children(ParentRunId),
    ?assertEqual(ChildRunId, maps:get(run_id, maps:get(run, Listed))),
    ok = beam_agent_orchestrator:cancel(ParentRunId, <<"done">>),
    reset().

reset() ->
    ok = beam_agent_orchestrator:clear(),
    ok = beam_agent_runs:clear(),
    ok = beam_agent_journal:clear(),
    ok = beam_agent_threads:clear(),
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_session_store_core:clear().

unique_binary(Prefix) ->
    list_to_binary(io_lib:format("~s-~p", [Prefix,
        erlang:unique_integer([positive, monotonic])])).
