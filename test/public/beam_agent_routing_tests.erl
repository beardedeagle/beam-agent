%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_routing.
%%%-------------------------------------------------------------------
-module(beam_agent_routing_tests).

-include_lib("eunit/include/eunit.hrl").

exports_routing_surface_test() ->
    {module, beam_agent_routing} = code:ensure_loaded(beam_agent_routing),
    ?assert(erlang:function_exported(beam_agent_routing, ensure_tables, 0)),
    ?assert(erlang:function_exported(beam_agent_routing, clear, 0)),
    ?assert(erlang:function_exported(beam_agent_routing, select_backend, 1)),
    ?assert(erlang:function_exported(beam_agent_routing, select_backend, 2)).

public_routing_roundtrip_test() ->
    ok = beam_agent_routing:clear(),
    {ok, Decision} = beam_agent_routing:select_backend(#{
        policy => preferred_then_fallback,
        preferred_backends => [codex, gemini],
        excluded_backends => [codex]
    }),
    ?assertEqual(gemini, maps:get(backend, Decision)),
    ok = beam_agent_routing:clear().

