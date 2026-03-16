%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the beam_agent_session_engine public contract.
%%%
%%% This suite intentionally avoids fixture handlers/transports. The
%%% protocol and backend-specific lifecycle behavior is covered in
%%% backend protocol/contract tests; here we keep only direct surface
%%% guarantees that do not require test doubles.
%%%-------------------------------------------------------------------
-module(beam_agent_session_engine_tests).

-include_lib("eunit/include/eunit.hrl").

exports_start_link_2_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({start_link, 2}, Exports)).

exports_send_query_4_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({send_query, 4}, Exports)).

exports_receive_message_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({receive_message, 3}, Exports)).

exports_health_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({health, 1}, Exports)).

exports_stop_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({stop, 1}, Exports)).

exports_send_control_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({send_control, 3}, Exports)).

exports_interrupt_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({interrupt, 1}, Exports)).

exports_session_info_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({session_info, 1}, Exports)).

exports_set_model_2_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({set_model, 2}, Exports)).

exports_set_permission_mode_2_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({set_permission_mode, 2}, Exports)).

exports_callback_mode_0_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({callback_mode, 0}, Exports)).

exports_init_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({init, 1}, Exports)).

exports_terminate_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({terminate, 3}, Exports)).

exports_state_functions_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    lists:foreach(fun(Export) -> ?assert(lists:member(Export, Exports)) end,
        [{connecting, 3}, {initializing, 3}, {ready, 3},
         {active_query, 3}, {error, 3}]).

callback_mode_includes_state_functions_test() ->
    Mode = beam_agent_session_engine:callback_mode(),
    ?assert(lists:member(state_functions, Mode)).

callback_mode_includes_state_enter_test() ->
    Mode = beam_agent_session_engine:callback_mode(),
    ?assert(lists:member(state_enter, Mode)).
