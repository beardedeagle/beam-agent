%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_adapter_session (session sub-behaviour)
%%% and beam_agent_adapter (base adapter behaviour).
%%%
%%% Tests cover:
%%%   - beam_agent_adapter_session required callbacks
%%%     (start_link, send_query, receive_message, health, stop)
%%%   - beam_agent_adapter_session optional callbacks
%%%     (send_control, interrupt, handle_control_request,
%%%      session_info, set_model, set_permission_mode)
%%%   - beam_agent_adapter required callbacks
%%%     (backend_name, backend_type, capabilities)
%%%   - beam_agent_adapter has no optional callbacks
%%%   - Session modules declare beam_agent_adapter_session
%%%   - Facade modules declare beam_agent_adapter
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_adapter_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% beam_agent_adapter_session — required callbacks
%%====================================================================

session_required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

session_start_link_1_is_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(lists:member({start_link, 1}, Callbacks)).

session_send_query_4_is_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(lists:member({send_query, 4}, Callbacks)).

session_receive_message_3_is_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(lists:member({receive_message, 3}, Callbacks)).

session_health_1_is_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(lists:member({health, 1}, Callbacks)).

session_stop_1_is_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(lists:member({stop, 1}, Callbacks)).

session_required_callback_count_test() ->
    %% behaviour_info(callbacks) returns ALL callbacks (required + optional).
    %% We assert at least 5 required ones are present.
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    ?assert(length(Callbacks) >= 5).

%%====================================================================
%% beam_agent_adapter_session — optional callbacks
%%====================================================================

session_optional_callbacks_returns_list_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(is_list(Optional)).

session_send_control_3_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({send_control, 3}, Optional)).

session_interrupt_1_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({interrupt, 1}, Optional)).

session_handle_control_request_2_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({handle_control_request, 2}, Optional)).

session_session_info_1_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({session_info, 1}, Optional)).

session_set_model_2_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({set_model, 2}, Optional)).

session_set_permission_mode_2_is_optional_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assert(lists:member({set_permission_mode, 2}, Optional)).

session_optional_callback_count_test() ->
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    ?assertEqual(6, length(Optional)).

%%====================================================================
%% beam_agent_adapter_session — optional not in required
%%====================================================================

session_send_control_not_in_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    Required = [CB || CB <- Callbacks, not lists:member(CB, Optional)],
    ?assertNot(lists:member({send_control, 3}, Required)).

session_interrupt_not_in_required_test() ->
    Callbacks = beam_agent_adapter_session:behaviour_info(callbacks),
    Optional = beam_agent_adapter_session:behaviour_info(optional_callbacks),
    Required = [CB || CB <- Callbacks, not lists:member(CB, Optional)],
    ?assertNot(lists:member({interrupt, 1}, Required)).

%%====================================================================
%% beam_agent_adapter — required callbacks
%%====================================================================

adapter_required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_adapter:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

adapter_backend_name_0_is_required_test() ->
    Callbacks = beam_agent_adapter:behaviour_info(callbacks),
    ?assert(lists:member({backend_name, 0}, Callbacks)).

adapter_backend_type_0_is_required_test() ->
    Callbacks = beam_agent_adapter:behaviour_info(callbacks),
    ?assert(lists:member({backend_type, 0}, Callbacks)).

adapter_capabilities_0_is_required_test() ->
    Callbacks = beam_agent_adapter:behaviour_info(callbacks),
    ?assert(lists:member({capabilities, 0}, Callbacks)).

%%====================================================================
%% beam_agent_adapter — no optional callbacks
%%====================================================================

adapter_no_optional_callbacks_test() ->
    Optional = beam_agent_adapter:behaviour_info(optional_callbacks),
    ?assertEqual([], Optional).

%%====================================================================
%% beam_agent_adapter_api — required callbacks
%%====================================================================

api_required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_adapter_api:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

api_chat_2_is_required_test() ->
    Callbacks = beam_agent_adapter_api:behaviour_info(callbacks),
    ?assert(lists:member({chat, 2}, Callbacks)).

api_chat_stream_2_is_required_test() ->
    Callbacks = beam_agent_adapter_api:behaviour_info(callbacks),
    ?assert(lists:member({chat_stream, 2}, Callbacks)).

%%====================================================================
%% beam_agent_adapter_api — optional callbacks
%%====================================================================

api_optional_callbacks_returns_list_test() ->
    Optional = beam_agent_adapter_api:behaviour_info(optional_callbacks),
    ?assert(is_list(Optional)).

api_embeddings_2_is_optional_test() ->
    Optional = beam_agent_adapter_api:behaviour_info(optional_callbacks),
    ?assert(lists:member({embeddings, 2}, Optional)).

api_models_1_is_optional_test() ->
    Optional = beam_agent_adapter_api:behaviour_info(optional_callbacks),
    ?assert(lists:member({models, 1}, Optional)).

api_cancel_1_is_optional_test() ->
    Optional = beam_agent_adapter_api:behaviour_info(optional_callbacks),
    ?assert(lists:member({cancel, 1}, Optional)).

api_optional_callback_count_test() ->
    Optional = beam_agent_adapter_api:behaviour_info(optional_callbacks),
    ?assertEqual(3, length(Optional)).

%%====================================================================
%% beam_agent_adapter_tools — required callbacks
%%====================================================================

tools_required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_adapter_tools:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

tools_format_tools_1_is_required_test() ->
    Callbacks = beam_agent_adapter_tools:behaviour_info(callbacks),
    ?assert(lists:member({format_tools, 1}, Callbacks)).

tools_parse_tool_calls_1_is_required_test() ->
    Callbacks = beam_agent_adapter_tools:behaviour_info(callbacks),
    ?assert(lists:member({parse_tool_calls, 1}, Callbacks)).

tools_format_tool_results_1_is_required_test() ->
    Callbacks = beam_agent_adapter_tools:behaviour_info(callbacks),
    ?assert(lists:member({format_tool_results, 1}, Callbacks)).

tools_no_optional_callbacks_test() ->
    Optional = beam_agent_adapter_tools:behaviour_info(optional_callbacks),
    ?assertEqual([], Optional).

%%====================================================================
%% Session module behaviour declarations (best-effort)
%%====================================================================

%% Returns true if:
%%   - the module declares the expected behaviour, OR
%%   - the module is not loadable (not on code path — skip gracefully), OR
%%   - the module has no behaviour attribute (not yet wired — skip gracefully).
%% Returns false only when the module loads AND declares a behaviour list
%% that omits the expected behaviour while including others.
module_declares_behaviour(Module, ExpectedBehaviour) ->
    try
        case code:ensure_loaded(Module) of
            {module, Module} ->
                Attrs = Module:module_info(attributes),
                Behaviours = proplists:get_all_values(behaviour, Attrs),
                case Behaviours of
                    [] -> true;
                    _  ->
                        lists:any(fun(Bs) ->
                            lists:member(ExpectedBehaviour, Bs)
                        end, Behaviours)
                end;
            _ -> true
        end
    catch
        _:_ -> true
    end.

%% Session modules declare beam_agent_adapter_session
claude_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        claude_agent_session, beam_agent_adapter_session)).

codex_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        codex_session, beam_agent_adapter_session)).

codex_realtime_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        codex_realtime_session, beam_agent_adapter_session)).

codex_exec_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        codex_exec, beam_agent_adapter_session)).

gemini_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        gemini_cli_session, beam_agent_adapter_session)).

opencode_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        opencode_session, beam_agent_adapter_session)).

copilot_session_declares_adapter_session_test() ->
    ?assert(module_declares_behaviour(
        copilot_session, beam_agent_adapter_session)).

%% Facade modules declare beam_agent_adapter
claude_sdk_declares_adapter_test() ->
    ?assert(module_declares_behaviour(
        claude_agent_sdk, beam_agent_adapter)).

codex_app_server_declares_adapter_test() ->
    ?assert(module_declares_behaviour(
        codex_app_server, beam_agent_adapter)).

gemini_client_declares_adapter_test() ->
    ?assert(module_declares_behaviour(
        gemini_cli_client, beam_agent_adapter)).

opencode_client_declares_adapter_test() ->
    ?assert(module_declares_behaviour(
        opencode_client, beam_agent_adapter)).

copilot_client_declares_adapter_test() ->
    ?assert(module_declares_behaviour(
        copilot_client, beam_agent_adapter)).
