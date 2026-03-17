%%%-------------------------------------------------------------------
%%% @doc Public API tests for beam_agent_context.
%%%-------------------------------------------------------------------
-module(beam_agent_context_tests).

-include_lib("eunit/include/eunit.hrl").

exports_context_surface_test() ->
    {module, beam_agent_context} = code:ensure_loaded(beam_agent_context),
    ?assert(erlang:function_exported(beam_agent_context, context_status, 1)),
    ?assert(erlang:function_exported(beam_agent_context, budget_estimate, 1)),
    ?assert(erlang:function_exported(beam_agent_context, compact_now, 2)),
    ?assert(erlang:function_exported(beam_agent_context, maybe_compact, 2)).

