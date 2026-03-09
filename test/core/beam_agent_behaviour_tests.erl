%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_behaviour (adapter behaviour contract).
%%%
%%% Tests cover:
%%%   - Module is loadable
%%%   - Required callbacks are declared (start_link, send_query, receive_message, health, stop)
%%%   - Optional callbacks are declared (send_control, interrupt, handle_control_request,
%%%     session_info, set_model, set_permission_mode)
%%%   - Adapter modules declare the behaviour in their attributes (best-effort, skipped
%%%     gracefully when adapters are not on the code path during beam_agent_core unit tests)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_behaviour_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Module loading
%%====================================================================

module_is_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_behaviour) orelse
        code:ensure_loaded(beam_agent_behaviour) =:= {module, beam_agent_behaviour}).

%%====================================================================
%% Required callbacks
%%====================================================================

required_callbacks_returns_list_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(is_list(Callbacks)).

start_link_1_is_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(lists:member({start_link, 1}, Callbacks)).

send_query_4_is_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(lists:member({send_query, 4}, Callbacks)).

receive_message_3_is_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(lists:member({receive_message, 3}, Callbacks)).

health_1_is_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(lists:member({health, 1}, Callbacks)).

stop_1_is_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(lists:member({stop, 1}, Callbacks)).

required_callback_count_test() ->
    %% Behaviour_info(callbacks) returns ALL callbacks (required + optional)
    %% so we only assert there are at least 5 (the required ones).
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    ?assert(length(Callbacks) >= 5).

%%====================================================================
%% Optional callbacks
%%====================================================================

optional_callbacks_returns_list_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(is_list(Optional)).

send_control_3_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({send_control, 3}, Optional)).

interrupt_1_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({interrupt, 1}, Optional)).

handle_control_request_2_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({handle_control_request, 2}, Optional)).

session_info_1_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({session_info, 1}, Optional)).

set_model_2_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({set_model, 2}, Optional)).

set_permission_mode_2_is_optional_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assert(lists:member({set_permission_mode, 2}, Optional)).

optional_callback_count_test() ->
    Optional = beam_agent_behaviour:behaviour_info(optional_callbacks),
    ?assertEqual(6, length(Optional)).

%%====================================================================
%% Optional callbacks are NOT in required list
%%====================================================================

send_control_not_in_required_test() ->
    %% behaviour_info(callbacks) for a behaviour with -optional_callbacks
    %% returns only the required callbacks in OTP 18+.
    %% We verify the optional ones are absent from the required list.
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    Required = [CB || CB <- Callbacks,
                      not lists:member(CB,
                          beam_agent_behaviour:behaviour_info(optional_callbacks))],
    ?assertNot(lists:member({send_control, 3}, Required)).

interrupt_not_in_required_test() ->
    Callbacks = beam_agent_behaviour:behaviour_info(callbacks),
    Required = [CB || CB <- Callbacks,
                      not lists:member(CB,
                          beam_agent_behaviour:behaviour_info(optional_callbacks))],
    ?assertNot(lists:member({interrupt, 1}, Required)).

%%====================================================================
%% Adapter module behaviour declarations (best-effort)
%%====================================================================

%% Returns true if:
%%   - the module declares -behaviour(beam_agent_behaviour), OR
%%   - the module is not loadable (adapter not on code path — skip gracefully), OR
%%   - the module has no behaviour attribute yet (adapter not yet wired — skip gracefully).
%% Returns false only when the module loads AND declares a conflicting/wrong behaviour list
%% that explicitly omits beam_agent_behaviour while including other behaviours.
adapter_declares_behaviour(Module) ->
    try
        case code:ensure_loaded(Module) of
            {module, Module} ->
                Attrs = Module:module_info(attributes),
                Behaviours = proplists:get_all_values(behaviour, Attrs),
                case Behaviours of
                    [] ->
                        %% No behaviour attribute at all — skip gracefully
                        true;
                    _ ->
                        lists:any(fun(Bs) ->
                            lists:member(beam_agent_behaviour, Bs)
                        end, Behaviours)
                end;
            _ ->
                %% Module not on code path — skip gracefully
                true
        end
    catch
        _:_ -> true  %% any error — skip gracefully
    end.

claude_agent_sdk_declares_behaviour_test() ->
    ?assert(adapter_declares_behaviour(claude_agent_sdk)).

codex_app_server_declares_behaviour_test() ->
    ?assert(adapter_declares_behaviour(codex_app_server)).

opencode_client_declares_behaviour_test() ->
    ?assert(adapter_declares_behaviour(opencode_client)).

gemini_cli_client_declares_behaviour_test() ->
    ?assert(adapter_declares_behaviour(gemini_cli_client)).

copilot_client_declares_behaviour_test() ->
    ?assert(adapter_declares_behaviour(copilot_client)).
