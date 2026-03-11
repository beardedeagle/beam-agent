%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport (transport behaviour contract).
%%%
%%% Tests cover:
%%%   - Module is loadable
%%%   - All 6 required callbacks are declared
%%%     (start, send, close, is_ready, status, classify_message)
%%%   - No optional callbacks exist
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_transport_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Module loading
%%====================================================================

module_is_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_transport) orelse
        code:ensure_loaded(beam_agent_transport) =:= {module, beam_agent_transport}).

%%====================================================================
%% Required callbacks
%%====================================================================

required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

start_1_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({start, 1}, Callbacks)).

send_2_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({send, 2}, Callbacks)).

close_1_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({close, 1}, Callbacks)).

is_ready_1_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({is_ready, 1}, Callbacks)).

status_1_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({status, 1}, Callbacks)).

classify_message_2_is_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(lists:member({classify_message, 2}, Callbacks)).

required_callback_count_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assertEqual(6, length(Callbacks)).

%%====================================================================
%% No optional callbacks
%%====================================================================

no_optional_callbacks_test() ->
    Optional = beam_agent_transport:behaviour_info(optional_callbacks),
    ?assertEqual([], Optional).
