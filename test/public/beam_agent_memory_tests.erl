%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_memory.
%%%-------------------------------------------------------------------
-module(beam_agent_memory_tests).

-include_lib("eunit/include/eunit.hrl").

exports_memory_surface_test() ->
    {module, beam_agent_memory} = code:ensure_loaded(beam_agent_memory),
    ?assert(erlang:function_exported(beam_agent_memory, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, remember, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, remember, 3)),
    ?assert(erlang:function_exported(beam_agent_memory, get, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, list, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, list, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, recall, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, search, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, search, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, forget, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, pin, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, unpin, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, update, 2)),
    ?assert(erlang:function_exported(beam_agent_memory, expire, 0)),
    ?assert(erlang:function_exported(beam_agent_memory, expire, 1)),
    ?assert(erlang:function_exported(beam_agent_memory, configure_persistence, 1)).

public_memory_roundtrip_test() ->
    ok = beam_agent_memory:clear(),
    {ok, Memory} = beam_agent_memory:remember(<<"public-memory-session">>, #{
        kind => note,
        content => <<"remember public memory">>,
        attributes => #{topic => <<"memory">>},
        salience => 5
    }),
    MemoryId = maps:get(memory_id, Memory),
    ok = beam_agent_memory:pin(MemoryId),
    {ok, [Match]} = beam_agent_memory:recall(
        <<"public-memory-session">>,
        <<"public memory">>
    ),
    ?assertEqual(MemoryId, maps:get(memory_id, Match)),
    ok = beam_agent_memory:unpin(MemoryId),
    {ok, Updated} = beam_agent_memory:update(MemoryId, #{
        content => <<"updated public memory">>,
        salience => 15
    }),
    ?assertEqual(MemoryId, maps:get(memory_id, Updated)),
    ?assertEqual(<<"updated public memory">>, maps:get(content, Updated)),
    ?assertEqual(15, maps:get(salience, Updated)),
    ok = beam_agent_memory:forget(MemoryId),
    ?assertEqual({error, not_found}, beam_agent_memory:get(MemoryId)),
    ok = beam_agent_memory:clear().

%%====================================================================
%% configure_persistence/1
%%====================================================================

configure_persistence_accepts_valid_ets_config_test() ->
    ok = beam_agent_memory:ensure_tables(),
    ?assertEqual(ok,
        beam_agent_memory:configure_persistence(#{
            adapter => beam_agent_store_ets
        })),
    ok = beam_agent_memory:clear().

configure_persistence_rejects_invalid_adapter_test() ->
    ok = beam_agent_memory:ensure_tables(),
    ?assertMatch({error, {invalid_adapter, _}},
        beam_agent_memory:configure_persistence(#{
            adapter => totally_bogus_adapter
        })),
    ok = beam_agent_memory:clear().

configure_persistence_memories_survive_reconfig_test() ->
    ok = beam_agent_memory:clear(),
    {ok, Memory} = beam_agent_memory:remember(<<"persist-test-session">>, #{
        kind => note,
        content => <<"survive reconfig">>,
        salience => 10
    }),
    MemoryId = maps:get(memory_id, Memory),
    %% Reconfigure to same adapter (ETS) — memories should survive
    ok = beam_agent_memory:configure_persistence(#{
        adapter => beam_agent_store_ets
    }),
    {ok, Found} = beam_agent_memory:get(MemoryId),
    ?assertEqual(<<"survive reconfig">>, maps:get(content, Found)),
    ok = beam_agent_memory:clear().
