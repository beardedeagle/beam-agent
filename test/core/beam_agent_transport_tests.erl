%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport (transport behaviour contract).
%%%
%%% Tests cover:
%%%   - Module is loadable
%%%   - Required callbacks are declared (start, send, close, is_ready)
%%%   - Optional callback is declared (status)
%%%   - Optional callback is absent from the required-only list
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

required_callback_count_test() ->
    %% behaviour_info(callbacks) returns ALL callbacks (required + optional).
    %% At minimum the 4 required callbacks must be present.
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    ?assert(length(Callbacks) >= 4).

%%====================================================================
%% Optional callbacks
%%====================================================================

optional_callbacks_returns_list_test() ->
    Optional = beam_agent_transport:behaviour_info(optional_callbacks),
    ?assert(is_list(Optional)).

status_1_is_optional_test() ->
    Optional = beam_agent_transport:behaviour_info(optional_callbacks),
    ?assert(lists:member({status, 1}, Optional)).

optional_callback_count_test() ->
    Optional = beam_agent_transport:behaviour_info(optional_callbacks),
    ?assertEqual(1, length(Optional)).

%%====================================================================
%% Optional callback is not in required-only list
%%====================================================================

status_not_in_required_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    Required = [CB || CB <- Callbacks,
                      not lists:member(CB,
                          beam_agent_transport:behaviour_info(optional_callbacks))],
    ?assertNot(lists:member({status, 1}, Required)).

required_only_has_four_entries_test() ->
    Callbacks = beam_agent_transport:behaviour_info(callbacks),
    Optional = beam_agent_transport:behaviour_info(optional_callbacks),
    Required = [CB || CB <- Callbacks, not lists:member(CB, Optional)],
    ?assertEqual(4, length(Required)).
