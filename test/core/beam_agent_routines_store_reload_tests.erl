%%%-------------------------------------------------------------------
%%% @doc EUnit tests for reload bus integration in beam_agent_routines_store.
%%%
%%% Covers:
%%%   - put_job emits {beam_agent_reload, routines, _}
%%%   - delete_job emits {beam_agent_reload, routines, _}
%%%   - clear emits {beam_agent_reload, routines, _}
%%%   - Version counter increments across mutations
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_routines_store_reload_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

setup() ->
    cleanup_tables(),
    ok = beam_agent_reload_bus:ensure_tables(),
    ok = beam_agent_routines_store:ensure_tables(),
    ok = beam_agent_reload_bus:subscribe().

cleanup_tables() ->
    catch ets:delete(beam_agent_reload_subscribers),
    catch ets:delete(beam_agent_reload_version),
    catch ets:delete(beam_agent_routine_jobs),
    catch ets:delete(beam_agent_routine_due),
    catch ets:delete(beam_agent_routine_claims),
    ok.

expect_routines_reload() ->
    receive
        {beam_agent_reload, routines, Version} -> Version
    after 1000 ->
        ?assert(false)
    end.

test_job(Id) ->
    #{job_id => Id,
      name => <<"Test Job">>,
      description => <<"A test routine">>,
      schedule => <<"0 * * * *">>,
      enabled => true}.

%%====================================================================
%% Tests
%%====================================================================

put_job_notifies_reload_bus_test() ->
    setup(),
    ok = beam_agent_routines_store:put_job(test_job(<<"j1">>)),
    V = expect_routines_reload(),
    ?assert(V >= 1),
    cleanup_tables().

delete_job_notifies_reload_bus_test() ->
    setup(),
    ok = beam_agent_routines_store:put_job(test_job(<<"j1">>)),
    _ = expect_routines_reload(),
    ok = beam_agent_routines_store:delete_job(<<"j1">>),
    V2 = expect_routines_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

clear_notifies_reload_bus_test() ->
    setup(),
    ok = beam_agent_routines_store:put_job(test_job(<<"j1">>)),
    _ = expect_routines_reload(),
    ok = beam_agent_routines_store:clear(),
    V2 = expect_routines_reload(),
    ?assert(V2 >= 2),
    cleanup_tables().

version_increments_across_mutations_test() ->
    setup(),
    ok = beam_agent_routines_store:put_job(test_job(<<"j1">>)),
    V1 = expect_routines_reload(),
    ok = beam_agent_routines_store:put_job(test_job(<<"j2">>)),
    V2 = expect_routines_reload(),
    ok = beam_agent_routines_store:clear(),
    V3 = expect_routines_reload(),
    ?assert(V1 < V2),
    ?assert(V2 < V3),
    cleanup_tables().
