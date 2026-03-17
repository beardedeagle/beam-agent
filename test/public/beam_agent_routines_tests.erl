%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_routines.
%%%-------------------------------------------------------------------
-module(beam_agent_routines_tests).

-include_lib("eunit/include/eunit.hrl").

exports_routines_surface_test() ->
    {module, beam_agent_routines} = code:ensure_loaded(beam_agent_routines),
    ?assert(erlang:function_exported(beam_agent_routines, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, create, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, update, 2)),
    ?assert(erlang:function_exported(beam_agent_routines, cancel, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, get, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, list, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, list, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, due, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, due, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, next_due_at, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, run_now, 1)),
    ?assert(erlang:function_exported(beam_agent_routines, run_due, 0)),
    ?assert(erlang:function_exported(beam_agent_routines, run_due, 1)).

public_routine_roundtrip_test() ->
    ok = beam_agent_routines:clear(),
    DueAt = erlang:system_time(millisecond) - 100,
    {ok, Job} = beam_agent_routines:create(#{
        schedule => #{type => once, at => DueAt},
        target => #{
            type => run,
            scope => <<"public-routines-session">>,
            run_opts => #{kind => routine},
            outcome => completed,
            result => #{ok => true}
        }
    }),
    {ok, [Result]} = beam_agent_routines:run_due(),
    Run = maps:get(run, Result),
    ?assertEqual(completed, maps:get(status, Run)),
    {ok, StoredJob} = beam_agent_routines:get(maps:get(job_id, Job)),
    ?assertEqual(completed, maps:get(state, StoredJob)),
    ok = beam_agent_routines:clear().
