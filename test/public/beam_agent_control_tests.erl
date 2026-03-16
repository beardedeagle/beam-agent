%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_control task/run bridging.
%%%-------------------------------------------------------------------
-module(beam_agent_control_tests).

-include_lib("eunit/include/eunit.hrl").

public_register_task_exposes_run_link_test() ->
    beam_agent_control:clear(),
    beam_agent_runs:clear(),
    SessionId = <<"public-control-task">>,
    Pid = spawn(fun() -> timer:sleep(60000) end),
    ok = beam_agent_control:register_task(SessionId, <<"task-public">>, Pid),
    {ok, [Task]} = beam_agent_control:list_tasks(SessionId),
    RunId = maps:get(run_id, Task),
    {ok, Run} = beam_agent_runs:get_run(RunId),
    ?assertEqual(running, maps:get(status, Run)),
    exit(Pid, kill),
    beam_agent_control:clear(),
    beam_agent_runs:clear().

public_stop_task_cancels_linked_run_test() ->
    beam_agent_control:clear(),
    beam_agent_runs:clear(),
    SessionId = <<"public-control-stop">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    ok = beam_agent_control:register_task(SessionId, <<"task-stop-public">>, Pid),
    {ok, [Task0]} = beam_agent_control:list_tasks(SessionId),
    RunId = maps:get(run_id, Task0),
    ok = beam_agent_control:stop_task(SessionId, <<"task-stop-public">>),
    {ok, Run} = beam_agent_runs:get_run(RunId),
    ?assertEqual(cancelled, maps:get(status, Run)),
    beam_agent_control:clear(),
    beam_agent_runs:clear().
