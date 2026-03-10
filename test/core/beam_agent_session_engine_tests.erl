%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_session_engine.
%%%
%%% Uses a mock handler (`mock_session_handler`) that implements the
%%% beam_agent_session_handler behaviour with a mock transport to test
%%% the engine's state machine lifecycle, consumer management, query
%%% flow, control delegation, and error handling.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_session_engine_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Mock handler module
%%====================================================================

%% The mock handler is defined in mock_session_handler.erl (test helper).
%% It uses mock_session_transport for byte I/O.

%%====================================================================
%% Test fixtures
%%====================================================================

setup() ->
    _ = application:ensure_all_started(telemetry),
    ok.

cleanup(_) ->
    ok.

%%====================================================================
%% Module loading
%%====================================================================

module_is_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_session_engine) orelse
        code:ensure_loaded(beam_agent_session_engine) =:=
            {module, beam_agent_session_engine}).

%%====================================================================
%% Public API exports
%%====================================================================

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

%%====================================================================
%% gen_statem callback exports
%%====================================================================

exports_callback_mode_0_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({callback_mode, 0}, Exports)).

exports_init_1_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({init, 1}, Exports)).

exports_terminate_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({terminate, 3}, Exports)).

%%====================================================================
%% State function exports
%%====================================================================

exports_connecting_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({connecting, 3}, Exports)).

exports_initializing_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({initializing, 3}, Exports)).

exports_ready_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({ready, 3}, Exports)).

exports_active_query_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({active_query, 3}, Exports)).

exports_error_3_test() ->
    Exports = beam_agent_session_engine:module_info(exports),
    ?assert(lists:member({error, 3}, Exports)).

%%====================================================================
%% callback_mode
%%====================================================================

callback_mode_includes_state_functions_test() ->
    Mode = beam_agent_session_engine:callback_mode(),
    ?assert(lists:member(state_functions, Mode)).

callback_mode_includes_state_enter_test() ->
    Mode = beam_agent_session_engine:callback_mode(),
    ?assert(lists:member(state_enter, Mode)).

%%====================================================================
%% Integration tests with mock handler
%%====================================================================

start_and_health_test_() ->
    {"engine starts with mock handler and reports health",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          ?assertEqual(ready, beam_agent_session_engine:health(Pid)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

session_id_generated_when_absent_test_() ->
    {"engine generates session_id when not provided",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          {ok, Info} = beam_agent_session_engine:session_info(Pid),
          SessionId = maps:get(session_id, Info),
          ?assert(is_binary(SessionId)),
          ?assertMatch(<<"session_", _/binary>>, SessionId),
          beam_agent_session_engine:stop(Pid)
      end}}}.

session_id_preserved_when_provided_test_() ->
    {"engine preserves session_id from opts",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                session_id => <<"my-session-42">>}),
          {ok, Info} = beam_agent_session_engine:session_info(Pid),
          ?assertEqual(<<"my-session-42">>, maps:get(session_id, Info)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

session_info_includes_backend_test_() ->
    {"session_info includes backend name from handler",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          {ok, Info} = beam_agent_session_engine:session_info(Pid),
          ?assertEqual(mock, maps:get(backend, Info)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

set_model_default_test_() ->
    {"set_model stores model when handler doesn't implement callback",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          {ok, <<"gpt-5">>} = beam_agent_session_engine:set_model(
              Pid, <<"gpt-5">>),
          {ok, Info} = beam_agent_session_engine:session_info(Pid),
          ?assertEqual(<<"gpt-5">>, maps:get(model, Info)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

set_permission_mode_default_test_() ->
    {"set_permission_mode stores mode when handler doesn't implement",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          {ok, <<"plan">>} = beam_agent_session_engine:set_permission_mode(
              Pid, <<"plan">>),
          {ok, Info} = beam_agent_session_engine:session_info(Pid),
          ?assertEqual(<<"plan">>, maps:get(permission_mode, Info)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

query_flow_test_() ->
    {"send_query → receive_message → result cycle",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                mock_response => [#{type => assistant,
                                    content => <<"hello">>},
                                  #{type => result,
                                    content => <<"done">>}]}),
          ?assertEqual(ready, beam_agent_session_engine:health(Pid)),
          {ok, Ref} = beam_agent_session_engine:send_query(
              Pid, <<"test">>, #{}, 5000),
          ?assert(is_reference(Ref)),
          %% Should transition to active_query
          ?assertEqual(active_query, beam_agent_session_engine:health(Pid)),
          %% Receive assistant message
          {ok, Msg1} = beam_agent_session_engine:receive_message(
              Pid, Ref, 5000),
          ?assertEqual(assistant, maps:get(type, Msg1)),
          %% Receive result message — transitions back to ready
          {ok, Msg2} = beam_agent_session_engine:receive_message(
              Pid, Ref, 5000),
          ?assertEqual(result, maps:get(type, Msg2)),
          ?assertEqual(ready, beam_agent_session_engine:health(Pid)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

query_in_progress_rejected_test_() ->
    {"second query rejected during active_query",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                mock_response => [#{type => result,
                                    content => <<"done">>}]}),
          {ok, _Ref} = beam_agent_session_engine:send_query(
              Pid, <<"q1">>, #{}, 5000),
          Result = beam_agent_session_engine:send_query(
              Pid, <<"q2">>, #{}, 5000),
          ?assertEqual({error, query_in_progress}, Result),
          beam_agent_session_engine:stop(Pid)
      end}}}.

bad_ref_rejected_test_() ->
    {"receive_message with wrong ref returns bad_ref",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                mock_response => [#{type => result,
                                    content => <<"done">>}]}),
          {ok, _Ref} = beam_agent_session_engine:send_query(
              Pid, <<"q">>, #{}, 5000),
          BadRef = make_ref(),
          Result = beam_agent_session_engine:receive_message(
              Pid, BadRef, 5000),
          ?assertEqual({error, bad_ref}, Result),
          beam_agent_session_engine:stop(Pid)
      end}}}.

cancel_test_() ->
    {"cancel during active_query transitions to ready",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                mock_response => []}),  % no auto-response
          {ok, Ref} = beam_agent_session_engine:send_query(
              Pid, <<"q">>, #{}, 5000),
          ?assertEqual(active_query, beam_agent_session_engine:health(Pid)),
          ok = gen_statem:call(Pid, {cancel, Ref}, 5000),
          ?assertEqual(ready, beam_agent_session_engine:health(Pid)),
          beam_agent_session_engine:stop(Pid)
      end}}}.

send_control_not_supported_test_() ->
    {"send_control returns not_supported when handler lacks callback",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler, #{initial_state => ready}),
          Result = beam_agent_session_engine:send_control(
              Pid, <<"some_method">>, #{}),
          ?assertEqual({error, not_supported}, Result),
          beam_agent_session_engine:stop(Pid)
      end}}}.

interrupt_not_supported_test_() ->
    {"interrupt returns not_supported when handler lacks callback",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                mock_response => []}),
          {ok, _Ref} = beam_agent_session_engine:send_query(
              Pid, <<"q">>, #{}, 5000),
          Result = beam_agent_session_engine:interrupt(Pid),
          ?assertEqual({error, not_supported}, Result),
          beam_agent_session_engine:stop(Pid)
      end}}}.

error_state_rejects_queries_test_() ->
    {"error state rejects all calls except health and session_info",
     {setup, fun setup/0, fun cleanup/1,
      {timeout, 10, fun() ->
          {ok, Pid} = beam_agent_session_engine:start_link(
              mock_session_handler,
              #{initial_state => ready,
                force_error => true}),
          %% force_error makes mock transition to error on first data
          timer:sleep(200),
          ?assertEqual(error, beam_agent_session_engine:health(Pid)),
          {ok, _Info} = beam_agent_session_engine:session_info(Pid),
          Result = beam_agent_session_engine:send_query(
              Pid, <<"q">>, #{}, 5000),
          ?assertEqual({error, session_error}, Result),
          beam_agent_session_engine:stop(Pid)
      end}}}.
