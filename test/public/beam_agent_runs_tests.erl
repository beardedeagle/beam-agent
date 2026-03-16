%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the public beam_agent_runs facade.
%%%-------------------------------------------------------------------
-module(beam_agent_runs_tests).

-include_lib("eunit/include/eunit.hrl").

exports_run_lifecycle_surface_test() ->
    {module, beam_agent_runs} = code:ensure_loaded(beam_agent_runs),
    ?assert(erlang:function_exported(beam_agent_runs, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_runs, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_runs, start_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, get_run, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, list_runs, 0)),
    ?assert(erlang:function_exported(beam_agent_runs, list_runs, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, complete_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, fail_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, cancel_run, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, start_step, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, get_step, 2)),
    ?assert(erlang:function_exported(beam_agent_runs, list_steps, 1)),
    ?assert(erlang:function_exported(beam_agent_runs, complete_step, 3)),
    ?assert(erlang:function_exported(beam_agent_runs, fail_step, 3)),
    ?assert(erlang:function_exported(beam_agent_runs, cancel_step, 3)).

public_run_roundtrip_test() ->
    ok = beam_agent_runs:clear(),
    SessionId = <<"public-runs-session">>,
    {ok, Run} = beam_agent_runs:start_run(SessionId, #{kind => workflow}),
    RunId = maps:get(run_id, Run),
    {ok, Step} = beam_agent_runs:start_step(RunId, #{kind => review}),
    StepId = maps:get(step_id, Step),
    {ok, _CompletedStep} = beam_agent_runs:complete_step(RunId, StepId, #{ok => true}),
    {ok, CompletedRun} = beam_agent_runs:complete_run(RunId, #{summary => <<"done">>}),
    ?assertEqual(completed, maps:get(status, CompletedRun)),
    {ok, [ListedRun]} = beam_agent_runs:list_runs(#{session_id => SessionId}),
    ?assertEqual(RunId, maps:get(run_id, ListedRun)),
    ok = beam_agent_runs:clear().
