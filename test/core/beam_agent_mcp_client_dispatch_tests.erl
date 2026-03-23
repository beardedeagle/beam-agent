%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_client_dispatch.
%%%
%%% Tests cover:
%%%   - State construction and accessors
%%%   - Lifecycle state machine (uninitialized → initializing → ready
%%%     → error | disconnected | shutting_down, error/disconnected → reset)
%%%   - Lifecycle transitions (mark_error, mark_disconnected, mark_shutting_down, reset)
%%%   - Lifecycle accessors (error_info, is_operational)
%%%   - Lifecycle gating (send_* rejected in wrong state)
%%%   - Lifecycle gating in error, disconnected, and shutting_down states
%%%   - Initialize error response → error state transition
%%%   - Ping in all states
%%%   - Outgoing request generation (tools, resources, prompts,
%%%     completions, logging)
%%%   - Request ID generation and tracking
%%%   - Response matching and pending request cleanup
%%%   - Initialize response handling and capability negotiation
%%%   - Error response handling
%%%   - Server-initiated request dispatch (sampling, elicitation, roots)
%%%   - Capability gating for server requests
%%%   - Handler-missing error responses
%%%   - Notification dispatch (list_changed, progress, logging, cancelled)
%%%   - Timeout tracking and cleanup
%%%   - Cancellation with pending request removal
%%%   - Generic send_request
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_client_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% State Construction
%%====================================================================

new_state_test() ->
    State = make_state(),
    ?assertEqual(uninitialized, beam_agent_mcp_client_dispatch:lifecycle_state(State)),
    ?assertEqual(undefined, beam_agent_mcp_client_dispatch:server_capabilities(State)),
    ?assertEqual(undefined, beam_agent_mcp_client_dispatch:session_capabilities(State)),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State)).

new_state_without_handler_test() ->
    State = beam_agent_mcp_client_dispatch:new(
        make_client_info(), make_client_caps(), #{}),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State)).

%%====================================================================
%% H5: max_pending limit
%%====================================================================

max_pending_default_is_zero_test() ->
    State = make_state(),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:max_pending(State)).

max_pending_configured_value_test() ->
    State = beam_agent_mcp_client_dispatch:new(
        make_client_info(), make_client_caps(),
        #{max_pending => 5}),
    ?assertEqual(5, beam_agent_mcp_client_dispatch:max_pending(State)).

max_pending_unlimited_allows_many_requests_test() ->
    State = make_ready_state(),  %% default max_pending=0 (unlimited)
    {_, S1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    {_, S2} = beam_agent_mcp_client_dispatch:send_tools_list(S1),
    {_, S3} = beam_agent_mcp_client_dispatch:send_tools_list(S2),
    ?assertEqual(3, beam_agent_mcp_client_dispatch:pending_count(S3)).

max_pending_enforced_on_send_test() ->
    State = make_ready_state_with_max_pending(2),
    {_, S1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    {_, S2} = beam_agent_mcp_client_dispatch:send_tools_list(S1),
    ?assertEqual(2, beam_agent_mcp_client_dispatch:pending_count(S2)),
    %% Third request exceeds limit
    ?assertError({max_pending_exceeded, 2, 2},
        beam_agent_mcp_client_dispatch:send_tools_list(S2)).

max_pending_allows_after_response_clears_slot_test() ->
    State = make_ready_state_with_max_pending(1),
    {_Msg, S1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(S1)),
    %% Respond to clear the pending slot
    Id = find_pending_id(S1),
    Resp = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
             <<"result">> => #{<<"tools">> => []}},
    {response, _, _, S2} =
        beam_agent_mcp_client_dispatch:handle_message(Resp, S1),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(S2)),
    %% Now a new request succeeds
    {_, S3} = beam_agent_mcp_client_dispatch:send_tools_list(S2),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(S3)).

max_pending_applies_to_ping_too_test() ->
    %% Ping uses the same track_request path — max_pending applies
    State = make_ready_state_with_max_pending(1),
    {_, S1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    ?assertError({max_pending_exceeded, 1, 1},
        beam_agent_mcp_client_dispatch:send_ping(S1)).

%%====================================================================
%% Lifecycle: Initialize
%%====================================================================

send_initialize_test() ->
    State = make_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    %% Check message structure
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(<<"initialize">>, maps:get(<<"method">>, Msg)),
    ?assert(is_map(maps:get(<<"params">>, Msg))),
    %% Lifecycle transitions to initializing
    ?assertEqual(initializing,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State1)),
    %% Request is tracked
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

send_initialize_wrong_state_test() ->
    State = make_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    %% Cannot initialize again
    ?assertError({invalid_lifecycle, initializing, initialize},
                 beam_agent_mcp_client_dispatch:send_initialize(State1)).

initialize_response_transitions_to_ready_test() ->
    State = make_state(),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    %% Simulate server initialize response
    Response = make_initialize_response(1),
    {response, 1, _Result, State2} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ?assertEqual(ready,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)),
    %% Server capabilities should be decoded
    ?assertNotEqual(undefined,
                    beam_agent_mcp_client_dispatch:server_capabilities(State2)),
    %% Session capabilities should be negotiated
    ?assertNotEqual(undefined,
                    beam_agent_mcp_client_dispatch:session_capabilities(State2)),
    %% Pending request is cleared
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

%%====================================================================
%% M8: Protocol version validation in initialize response
%%====================================================================

initialize_rejects_unsupported_server_version_test() ->
    State = make_state(),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    %% Craft response with unsupported protocol version
    Response = #{<<"jsonrpc">> => <<"2.0">>,
                 <<"id">> => 1,
                 <<"result">> => #{
                     <<"protocolVersion">> => <<"2024-11-05">>,
                     <<"capabilities">> => #{},
                     <<"serverInfo">> => #{<<"name">> => <<"old-server">>,
                                           <<"version">> => <<"0.1">>}}},
    {error_response, 1, -32600, _ErrMsg, ErrState} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ?assertEqual(error,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ErrState)),
    ?assertEqual({unsupported_protocol_version, <<"2024-11-05">>},
                 maps:get(error_info, ErrState)).

initialize_accepts_missing_server_version_test() ->
    State = make_state(),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    %% Response omits protocolVersion — accepted leniently
    Response = #{<<"jsonrpc">> => <<"2.0">>,
                 <<"id">> => 1,
                 <<"result">> => #{
                     <<"capabilities">> => #{},
                     <<"serverInfo">> => #{<<"name">> => <<"minimal">>,
                                           <<"version">> => <<"1.0">>}}},
    {response, 1, _Result, State2} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ?assertEqual(ready,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)),
    ?assertEqual(<<"2025-06-18">>,
                 maps:get(negotiated_protocol_version, State2)).

initialize_stores_server_version_when_supported_test() ->
    State = make_state(),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    Response = make_initialize_response(1),
    {response, 1, _Result, State2} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ?assertEqual(<<"2025-06-18">>,
                 maps:get(negotiated_protocol_version, State2)).

%%====================================================================
%% Lifecycle Gating
%%====================================================================

send_tools_list_requires_ready_test() ->
    State = make_state(),
    ?assertError({not_ready, uninitialized},
                 beam_agent_mcp_client_dispatch:send_tools_list(State)).

send_resources_list_requires_ready_test() ->
    State = make_state(),
    ?assertError({not_ready, uninitialized},
                 beam_agent_mcp_client_dispatch:send_resources_list(State)).

send_prompts_list_requires_ready_test() ->
    State = make_state(),
    ?assertError({not_ready, uninitialized},
                 beam_agent_mcp_client_dispatch:send_prompts_list(State)).

send_logging_set_level_requires_ready_test() ->
    State = make_state(),
    ?assertError({not_ready, uninitialized},
                 beam_agent_mcp_client_dispatch:send_logging_set_level(
                     info, State)).

%%====================================================================
%% Ping — Any State
%%====================================================================

ping_uninitialized_test() ->
    State = make_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_ping(State),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

ping_initializing_test() ->
    {_InitMsg, State} = beam_agent_mcp_client_dispatch:send_initialize(
                             make_state()),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_ping(State),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)),
    %% 2 pending: initialize + ping
    ?assertEqual(2, beam_agent_mcp_client_dispatch:pending_count(State1)).

ping_ready_test() ->
    State = make_ready_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_ping(State),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

server_ping_request_test() ->
    State = make_ready_state(),
    PingReq = #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"ping">>,
                <<"id">> => <<"server-1">>},
    {server_request, Resp, _State1} =
        beam_agent_mcp_client_dispatch:handle_message(PingReq, State),
    ?assertEqual(<<"server-1">>, maps:get(<<"id">>, Resp)),
    ?assert(maps:is_key(<<"result">>, Resp)).

%%====================================================================
%% Outgoing Requests — Tools
%%====================================================================

send_tools_list_test() ->
    State = make_ready_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    ?assertEqual(<<"tools/list">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

send_tools_list_with_cursor_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_tools_list(
                    <<"cursor-abc">>, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"cursor-abc">>, maps:get(<<"cursor">>, Params)).

send_tools_call_test() ->
    State = make_ready_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_call(
                         <<"my-tool">>, #{<<"arg">> => <<"val">>}, State),
    ?assertEqual(<<"tools/call">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"my-tool">>, maps:get(<<"name">>, Params)),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

%%====================================================================
%% Outgoing Requests — Resources
%%====================================================================

send_resources_list_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_list(State),
    ?assertEqual(<<"resources/list">>, maps:get(<<"method">>, Msg)).

send_resources_list_with_cursor_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_list(
                    <<"c1">>, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"c1">>, maps:get(<<"cursor">>, Params)).

send_resources_read_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_read(
                    <<"file:///test.txt">>, State),
    ?assertEqual(<<"resources/read">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"file:///test.txt">>, maps:get(<<"uri">>, Params)).

send_resources_templates_list_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_templates_list(
                    State),
    ?assertEqual(<<"resources/templates/list">>, maps:get(<<"method">>, Msg)).

send_resources_templates_list_with_cursor_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_templates_list(
                    <<"c2">>, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"c2">>, maps:get(<<"cursor">>, Params)).

send_resources_subscribe_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_subscribe(
                    <<"file:///watch.txt">>, State),
    ?assertEqual(<<"resources/subscribe">>, maps:get(<<"method">>, Msg)).

send_resources_unsubscribe_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_resources_unsubscribe(
                    <<"file:///watch.txt">>, State),
    ?assertEqual(<<"resources/unsubscribe">>, maps:get(<<"method">>, Msg)).

%%====================================================================
%% Outgoing Requests — Prompts
%%====================================================================

send_prompts_list_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_prompts_list(State),
    ?assertEqual(<<"prompts/list">>, maps:get(<<"method">>, Msg)).

send_prompts_list_with_cursor_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_prompts_list(
                    <<"pc1">>, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"pc1">>, maps:get(<<"cursor">>, Params)).

send_prompts_get_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_prompts_get(
                    <<"greet">>, State),
    ?assertEqual(<<"prompts/get">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"greet">>, maps:get(<<"name">>, Params)).

send_prompts_get_with_arguments_test() ->
    State = make_ready_state(),
    Args = #{<<"user">> => <<"alice">>},
    {Msg, _} = beam_agent_mcp_client_dispatch:send_prompts_get(
                    <<"greet">>, Args, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(Args, maps:get(<<"arguments">>, Params)).

%%====================================================================
%% Outgoing Requests — Completions
%%====================================================================

send_completion_complete_test() ->
    State = make_ready_state(),
    Ref = #{<<"type">> => <<"ref/prompt">>, <<"name">> => <<"greet">>},
    Arg = #{<<"name">> => <<"user">>, <<"value">> => <<"al">>},
    {Msg, _} = beam_agent_mcp_client_dispatch:send_completion_complete(
                    Ref, Arg, State),
    ?assertEqual(<<"completion/complete">>, maps:get(<<"method">>, Msg)).

send_completion_complete_with_context_test() ->
    State = make_ready_state(),
    Ref = #{<<"type">> => <<"ref/prompt">>, <<"name">> => <<"greet">>},
    Arg = #{<<"name">> => <<"user">>, <<"value">> => <<"al">>},
    Ctx = #{<<"previousArgs">> => #{}},
    {Msg, _} = beam_agent_mcp_client_dispatch:send_completion_complete(
                    Ref, Arg, Ctx, State),
    ?assertEqual(<<"completion/complete">>, maps:get(<<"method">>, Msg)).

%%====================================================================
%% Outgoing Requests — Logging
%%====================================================================

send_logging_set_level_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_logging_set_level(
                    debug, State),
    ?assertEqual(<<"logging/setLevel">>, maps:get(<<"method">>, Msg)).

%%====================================================================
%% Outgoing Requests — Generic
%%====================================================================

send_request_generic_test() ->
    State = make_ready_state(),
    {Msg, State1} = beam_agent_mcp_client_dispatch:send_request(
                         <<"custom/method">>,
                         #{<<"key">> => <<"val">>}, State),
    ?assertEqual(<<"custom/method">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)).

%%====================================================================
%% Request ID Generation
%%====================================================================

request_ids_are_monotonic_test() ->
    State = make_ready_state(),
    {Msg1, State1} = beam_agent_mcp_client_dispatch:send_ping(State),
    {Msg2, _State2} = beam_agent_mcp_client_dispatch:send_ping(State1),
    Id1 = maps:get(<<"id">>, Msg1),
    Id2 = maps:get(<<"id">>, Msg2),
    ?assert(Id2 > Id1).

%%====================================================================
%% Response Matching
%%====================================================================

response_matches_pending_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    %% The request ID is the first ID after ready state setup
    Id = find_pending_id(State1),
    Response = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                 <<"result">> => #{<<"tools">> => []}},
    {response, Id, Result, State2} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ?assertEqual(#{<<"tools">> => []}, Result),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

response_unknown_id_ignored_test() ->
    State = make_ready_state(),
    Response = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 99999,
                 <<"result">> => #{}},
    {noreply, State1} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State1)).

error_response_clears_pending_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    Id = find_pending_id(State1),
    ErrResp = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                <<"error">> => #{<<"code">> => -32601,
                                 <<"message">> => <<"Not found">>}},
    {error_response, Id, -32601, <<"Not found">>, State2} =
        beam_agent_mcp_client_dispatch:handle_message(ErrResp, State1),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

%%====================================================================
%% Server-Initiated Requests — Sampling
%%====================================================================

sampling_request_test() ->
    State = make_ready_state(),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-1">>,
            <<"method">> => <<"sampling/createMessage">>,
            <<"params">> => #{
                <<"messages">> => [#{<<"role">> => <<"user">>,
                                     <<"content">> => #{}}],
                <<"maxTokens">> => 100
            }},
    {server_request, Resp, State1} =
        beam_agent_mcp_client_dispatch:handle_message(Req, State),
    ?assertEqual(<<"srv-1">>, maps:get(<<"id">>, Resp)),
    ?assert(maps:is_key(<<"result">>, Resp)),
    %% Handler state was updated
    HState = maps:get(handler_state, State1),
    ?assertEqual(true, maps:get(sampling_called, HState)).

%%====================================================================
%% Server-Initiated Requests — Elicitation
%%====================================================================

elicitation_request_test() ->
    State = make_ready_state(),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-2">>,
            <<"method">> => <<"elicitation/create">>,
            <<"params">> => #{<<"message">> => <<"Continue?">>}},
    {server_request, Resp, State1} =
        beam_agent_mcp_client_dispatch:handle_message(Req, State),
    ?assertEqual(<<"srv-2">>, maps:get(<<"id">>, Resp)),
    ?assert(maps:is_key(<<"result">>, Resp)),
    HState = maps:get(handler_state, State1),
    ?assertEqual(true, maps:get(elicitation_called, HState)).

%%====================================================================
%% Server-Initiated Requests — Roots
%%====================================================================

roots_list_request_test() ->
    State = make_ready_state(),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-3">>,
            <<"method">> => <<"roots/list">>,
            <<"params">> => #{}},
    {server_request, Resp, State1} =
        beam_agent_mcp_client_dispatch:handle_message(Req, State),
    ?assertEqual(<<"srv-3">>, maps:get(<<"id">>, Resp)),
    Result = maps:get(<<"result">>, Resp),
    Roots = maps:get(<<"roots">>, Result),
    ?assertEqual(2, length(Roots)),
    HState = maps:get(handler_state, State1),
    ?assertEqual(true, maps:get(roots_called, HState)).

%%====================================================================
%% Server-Initiated Requests — Capability Gating
%%====================================================================

sampling_rejected_when_not_advertised_test() ->
    %% Create state without sampling capability
    State = make_ready_state_with_caps(#{roots => #{listChanged => true}}),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-4">>,
            <<"method">> => <<"sampling/createMessage">>,
            <<"params">> => #{}},
    {server_request, Resp, _} =
        beam_agent_mcp_client_dispatch:handle_message(Req, State),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

%%====================================================================
%% Server-Initiated Requests — No Handler
%%====================================================================

sampling_rejected_when_no_handler_test() ->
    State = beam_agent_mcp_client_dispatch:new(
        make_client_info(),
        #{sampling => #{}, roots => #{listChanged => true},
          elicitation => #{}},
        #{}),
    ReadyState = force_ready(State),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-5">>,
            <<"method">> => <<"sampling/createMessage">>,
            <<"params">> => #{}},
    {server_request, Resp, _} =
        beam_agent_mcp_client_dispatch:handle_message(Req, ReadyState),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(-32603, maps:get(<<"code">>, Error)).

%%====================================================================
%% Server-Initiated Requests — Unknown Method
%%====================================================================

unknown_server_request_test() ->
    State = make_ready_state(),
    Req = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"srv-6">>,
            <<"method">> => <<"unknown/method">>,
            <<"params">> => #{}},
    {server_request, Resp, _} =
        beam_agent_mcp_client_dispatch:handle_message(Req, State),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

%%====================================================================
%% Notifications
%%====================================================================

tools_list_changed_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/tools/list_changed">>},
    {notification, <<"notifications/tools/list_changed">>, _, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

resources_list_changed_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/resources/list_changed">>},
    {notification, <<"notifications/resources/list_changed">>, _, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

resources_updated_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/resources/updated">>,
              <<"params">> => #{<<"uri">> => <<"file:///test.txt">>}},
    {notification, <<"notifications/resources/updated">>,
     #{<<"uri">> := <<"file:///test.txt">>}, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

prompts_list_changed_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/prompts/list_changed">>},
    {notification, <<"notifications/prompts/list_changed">>, _, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

logging_message_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/message">>,
              <<"params">> => #{<<"level">> => <<"info">>,
                                <<"data">> => <<"hello">>}},
    {notification, <<"notifications/message">>, Params, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Params)).

progress_notification_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/progress">>,
              <<"params">> => #{<<"progressToken">> => <<"t1">>,
                                <<"progress">> => 50}},
    {notification, <<"notifications/progress">>, _, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

cancelled_notification_removes_pending_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    Id = find_pending_id(State1),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/cancelled">>,
              <<"params">> => #{<<"requestId">> => Id}},
    {notification, <<"notifications/cancelled">>, _, State2} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State1),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

unknown_notification_surfaced_test() ->
    State = make_ready_state(),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/custom">>},
    {notification, <<"notifications/custom">>, _, _} =
        beam_agent_mcp_client_dispatch:handle_message(Notif, State).

%%====================================================================
%% Outgoing Notifications
%%====================================================================

send_cancelled_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    Id = find_pending_id(State1),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)),
    {CancelMsg, State2} =
        beam_agent_mcp_client_dispatch:send_cancelled(Id, State1),
    ?assertEqual(<<"notifications/cancelled">>,
                 maps:get(<<"method">>, CancelMsg)),
    %% Pending request removed
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

send_cancelled_with_reason_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    Id = find_pending_id(State1),
    {CancelMsg, _} =
        beam_agent_mcp_client_dispatch:send_cancelled(
            Id, <<"User cancelled">>, State1),
    Params = maps:get(<<"params">>, CancelMsg),
    ?assertEqual(<<"User cancelled">>, maps:get(<<"reason">>, Params)).

send_progress_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_progress(
                    <<"tok-1">>, 50, State),
    ?assertEqual(<<"notifications/progress">>, maps:get(<<"method">>, Msg)).

send_progress_with_total_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_progress(
                    <<"tok-2">>, 25, 100, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(100, maps:get(<<"total">>, Params)).

send_progress_with_message_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_progress(
                    <<"tok-3">>, 75, 100, <<"Almost done">>, State),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"Almost done">>, maps:get(<<"message">>, Params)).

send_roots_list_changed_test() ->
    State = make_ready_state(),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_roots_list_changed(State),
    ?assertEqual(<<"notifications/roots/list_changed">>,
                 maps:get(<<"method">>, Msg)).

send_roots_list_changed_requires_ready_test() ->
    State = make_state(),
    ?assertError({not_ready, uninitialized},
                 beam_agent_mcp_client_dispatch:send_roots_list_changed(State)).

%%====================================================================
%% Timeout Tracking
%%====================================================================

check_timeouts_none_expired_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    %% Check with a time before the deadline
    Now = erlang:monotonic_time(millisecond),
    {TimedOut, State2} =
        beam_agent_mcp_client_dispatch:check_timeouts(Now, State1),
    ?assertEqual([], TimedOut),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State2)).

check_timeouts_expired_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    %% Check with a time far in the future (past deadline)
    FarFuture = erlang:monotonic_time(millisecond) + 60000,
    {TimedOut, State2} =
        beam_agent_mcp_client_dispatch:check_timeouts(FarFuture, State1),
    ?assertEqual(1, length(TimedOut)),
    [Info] = TimedOut,
    ?assertEqual(<<"tools/list">>, maps:get(method, Info)),
    ?assert(maps:is_key(id, Info)),
    ?assert(maps:is_key(sent_at, Info)),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State2)).

check_timeouts_partial_test() ->
    State = make_ready_state(),
    {_Msg1, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    {_Msg2, State2} = beam_agent_mcp_client_dispatch:send_ping(State1),
    ?assertEqual(2, beam_agent_mcp_client_dispatch:pending_count(State2)),
    %% Both should time out with far future
    FarFuture = erlang:monotonic_time(millisecond) + 60000,
    {TimedOut, State3} =
        beam_agent_mcp_client_dispatch:check_timeouts(FarFuture, State2),
    ?assertEqual(2, length(TimedOut)),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(State3)).

%%====================================================================
%% Invalid Messages
%%====================================================================

invalid_message_ignored_test() ->
    State = make_ready_state(),
    {noreply, _} = beam_agent_mcp_client_dispatch:handle_message(
                        #{<<"garbage">> => true}, State).

%%====================================================================
%% Helpers
%%====================================================================

make_client_info() ->
    beam_agent_mcp_protocol:implementation_info(
        <<"test-client">>, <<"1.0.0">>).

make_client_caps() ->
    #{sampling => #{}, roots => #{listChanged => true},
      elicitation => #{}}.

make_state() ->
    beam_agent_mcp_client_dispatch:new(
        make_client_info(),
        make_client_caps(),
        #{handler => beam_agent_mcp_client_dispatch_test_handler,
          handler_state => #{}}).

make_ready_state() ->
    make_ready_state_with_caps(make_client_caps()).

make_ready_state_with_max_pending(MaxPending) ->
    State0 = beam_agent_mcp_client_dispatch:new(
        make_client_info(),
        make_client_caps(),
        #{handler => beam_agent_mcp_client_dispatch_test_handler,
          handler_state => #{},
          max_pending => MaxPending}),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State0),
    Response = make_initialize_response(1),
    {response, 1, _Result, ReadyState} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ReadyState.

make_ready_state_with_caps(ClientCaps) ->
    State0 = beam_agent_mcp_client_dispatch:new(
        make_client_info(),
        ClientCaps,
        #{handler => beam_agent_mcp_client_dispatch_test_handler,
          handler_state => #{}}),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State0),
    Response = make_initialize_response(1),
    {response, 1, _Result, ReadyState} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State1),
    ReadyState.

make_initialize_response(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"result">> => #{
          <<"protocolVersion">> => beam_agent_mcp_protocol:protocol_version(),
          <<"capabilities">> => #{
              <<"tools">> => #{<<"listChanged">> => true},
              <<"resources">> => #{<<"listChanged">> => true,
                                   <<"subscribe">> => true},
              <<"prompts">> => #{<<"listChanged">> => true},
              <<"completions">> => #{},
              <<"logging">> => #{}
          },
          <<"serverInfo">> => #{
              <<"name">> => <<"test-server">>,
              <<"version">> => <<"1.0.0">>
          }
      }}.

%% Force a state to ready lifecycle (for testing handler-missing scenarios).
force_ready(State) ->
    State#{lifecycle => ready}.

%% Find the first pending request ID in a state.
find_pending_id(#{pending := Pending}) ->
    case maps:keys(Pending) of
        [Id | _] -> Id;
        [] -> error(no_pending_requests)
    end.

%%====================================================================
%% Lifecycle Transition Tests — mark_error
%%====================================================================

mark_error_from_ready_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(
                     protocol_violation, State),
    ?assertEqual(error,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ErrorState)),
    ?assertEqual(protocol_violation,
                 beam_agent_mcp_client_dispatch:error_info(ErrorState)).

mark_error_from_uninitialized_test() ->
    State = make_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(
                     startup_failure, State),
    ?assertEqual(error,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ErrorState)).

mark_error_from_initializing_test() ->
    {_Msg, State} = beam_agent_mcp_client_dispatch:send_initialize(
                         make_state()),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(timeout, State),
    ?assertEqual(error,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ErrorState)).

%%====================================================================
%% Lifecycle Transition Tests — mark_disconnected
%%====================================================================

mark_disconnected_from_ready_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   transport_closed, State),
    ?assertEqual(disconnected,
                 beam_agent_mcp_client_dispatch:lifecycle_state(DisState)),
    ?assertEqual(transport_closed,
                 beam_agent_mcp_client_dispatch:error_info(DisState)).

mark_disconnected_from_initializing_test() ->
    {_Msg, State} = beam_agent_mcp_client_dispatch:send_initialize(
                         make_state()),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   tcp_reset, State),
    ?assertEqual(disconnected,
                 beam_agent_mcp_client_dispatch:lifecycle_state(DisState)).

mark_disconnected_from_uninitialized_raises_test() ->
    State = make_state(),
    ?assertError({invalid_disconnect, uninitialized},
                 beam_agent_mcp_client_dispatch:mark_disconnected(
                     closed, State)).

mark_disconnected_from_error_raises_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State),
    ?assertError({invalid_disconnect, error},
                 beam_agent_mcp_client_dispatch:mark_disconnected(
                     closed, ErrorState)).

mark_disconnected_from_shutting_down_raises_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertError({invalid_disconnect, shutting_down},
                 beam_agent_mcp_client_dispatch:mark_disconnected(
                     closed, ShutState)).

%%====================================================================
%% Lifecycle Transition Tests — mark_shutting_down
%%====================================================================

mark_shutting_down_from_ready_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertEqual(shutting_down,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ShutState)).

mark_shutting_down_from_uninitialized_test() ->
    State = make_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertEqual(shutting_down,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ShutState)).

%%====================================================================
%% Lifecycle Transition Tests — reset
%%====================================================================

reset_from_error_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State),
    ResetState = beam_agent_mcp_client_dispatch:reset(ErrorState),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:error_info(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:server_capabilities(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:session_capabilities(ResetState)),
    ?assertEqual(0,
                 beam_agent_mcp_client_dispatch:pending_count(ResetState)).

reset_from_disconnected_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   transport_closed, State),
    ResetState = beam_agent_mcp_client_dispatch:reset(DisState),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_client_dispatch:lifecycle_state(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:error_info(ResetState)).

reset_clears_pending_requests_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    ?assertEqual(1, beam_agent_mcp_client_dispatch:pending_count(State1)),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State1),
    ResetState = beam_agent_mcp_client_dispatch:reset(ErrorState),
    ?assertEqual(0, beam_agent_mcp_client_dispatch:pending_count(ResetState)).

reset_preserves_next_id_test() ->
    State = make_ready_state(),
    %% Send a few requests to bump the ID counter
    {_Msg1, State1} = beam_agent_mcp_client_dispatch:send_ping(State),
    {_Msg2, State2} = beam_agent_mcp_client_dispatch:send_ping(State1),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State2),
    ResetState = beam_agent_mcp_client_dispatch:reset(ErrorState),
    %% After reset, send another ping — ID should be higher than before
    {Msg3, _} = beam_agent_mcp_client_dispatch:send_ping(ResetState),
    Id3 = maps:get(<<"id">>, Msg3),
    ?assert(Id3 > 2).

reset_from_ready_raises_test() ->
    State = make_ready_state(),
    ?assertError({invalid_reset, ready},
                 beam_agent_mcp_client_dispatch:reset(State)).

reset_from_uninitialized_raises_test() ->
    State = make_state(),
    ?assertError({invalid_reset, uninitialized},
                 beam_agent_mcp_client_dispatch:reset(State)).

reset_from_shutting_down_raises_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertError({invalid_reset, shutting_down},
                 beam_agent_mcp_client_dispatch:reset(ShutState)).

%%====================================================================
%% Accessor Tests — error_info / is_operational
%%====================================================================

error_info_in_error_state_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(
                     #{code => -1, reason => <<"bad">>}, State),
    ?assertEqual(#{code => -1, reason => <<"bad">>},
                 beam_agent_mcp_client_dispatch:error_info(ErrorState)).

error_info_in_disconnected_state_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   tcp_reset, State),
    ?assertEqual(tcp_reset,
                 beam_agent_mcp_client_dispatch:error_info(DisState)).

error_info_undefined_when_not_error_test() ->
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:error_info(make_state())),
    ?assertEqual(undefined,
                 beam_agent_mcp_client_dispatch:error_info(make_ready_state())).

is_operational_ready_test() ->
    ?assert(beam_agent_mcp_client_dispatch:is_operational(make_ready_state())).

is_operational_uninitialized_test() ->
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(make_state())).

is_operational_error_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(oops, State),
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(ErrorState)).

is_operational_disconnected_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   closed, State),
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(DisState)).

is_operational_shutting_down_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(ShutState)).

%%====================================================================
%% Lifecycle Gating — Error / Disconnected / Shutting Down
%%====================================================================

send_tools_list_rejected_in_error_state_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State),
    ?assertError({not_ready, error, _},
                 beam_agent_mcp_client_dispatch:send_tools_list(ErrorState)).

send_tools_list_rejected_in_disconnected_state_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   closed, State),
    ?assertError({not_ready, disconnected, _},
                 beam_agent_mcp_client_dispatch:send_tools_list(DisState)).

send_tools_list_rejected_in_shutting_down_state_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    ?assertError({not_ready, shutting_down, _},
                 beam_agent_mcp_client_dispatch:send_tools_list(ShutState)).

send_roots_list_changed_rejected_in_error_state_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State),
    ?assertError({not_ready, error, _},
                 beam_agent_mcp_client_dispatch:send_roots_list_changed(
                     ErrorState)).

%%====================================================================
%% Ping — Error / Disconnected / Shutting Down States
%%====================================================================

ping_works_in_error_state_test() ->
    State = make_ready_state(),
    ErrorState = beam_agent_mcp_client_dispatch:mark_error(broken, State),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_ping(ErrorState),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)).

ping_works_in_disconnected_state_test() ->
    State = make_ready_state(),
    DisState = beam_agent_mcp_client_dispatch:mark_disconnected(
                   closed, State),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_ping(DisState),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)).

ping_works_in_shutting_down_state_test() ->
    State = make_ready_state(),
    ShutState = beam_agent_mcp_client_dispatch:mark_shutting_down(State),
    {Msg, _} = beam_agent_mcp_client_dispatch:send_ping(ShutState),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)).

%%====================================================================
%% Initialize Error → Error State Transition
%%====================================================================

initialize_error_response_transitions_to_error_test() ->
    State = make_state(),
    {_InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
    ?assertEqual(initializing,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State1)),
    %% Simulate server rejecting initialize with an error
    ErrResp = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"error">> => #{<<"code">> => -32600,
                                 <<"message">> => <<"Unsupported version">>}},
    {error_response, 1, -32600, <<"Unsupported version">>, State2} =
        beam_agent_mcp_client_dispatch:handle_message(ErrResp, State1),
    ?assertEqual(error,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)),
    %% error_info should contain the error details
    Info = beam_agent_mcp_client_dispatch:error_info(State2),
    ?assertEqual(-32600, maps:get(code, Info)),
    ?assertEqual(<<"Unsupported version">>, maps:get(message, Info)).

non_init_error_response_stays_ready_test() ->
    State = make_ready_state(),
    {_Msg, State1} = beam_agent_mcp_client_dispatch:send_tools_list(State),
    Id = find_pending_id(State1),
    ErrResp = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                <<"error">> => #{<<"code">> => -32601,
                                 <<"message">> => <<"Not found">>}},
    {error_response, Id, -32601, <<"Not found">>, State2} =
        beam_agent_mcp_client_dispatch:handle_message(ErrResp, State1),
    %% Should still be ready — only init errors transition to error
    ?assertEqual(ready,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)).

%%====================================================================
%% Full Lifecycle Round-Trip Tests
%%====================================================================

full_error_recovery_round_trip_test() ->
    %% Start fresh, get to ready
    State0 = make_ready_state(),
    ?assert(beam_agent_mcp_client_dispatch:is_operational(State0)),

    %% Mark error
    State1 = beam_agent_mcp_client_dispatch:mark_error(provider_crash, State0),
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(State1)),
    ?assertEqual(provider_crash,
                 beam_agent_mcp_client_dispatch:error_info(State1)),

    %% Reset
    State2 = beam_agent_mcp_client_dispatch:reset(State1),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)),

    %% Re-initialize
    {_InitMsg, State3} = beam_agent_mcp_client_dispatch:send_initialize(State2),
    Response = make_initialize_response(
                   maps:get(<<"id">>, _InitMsg)),
    {response, _, _Result, State4} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State3),
    ?assert(beam_agent_mcp_client_dispatch:is_operational(State4)).

full_disconnect_recovery_round_trip_test() ->
    %% Start fresh, get to ready
    State0 = make_ready_state(),
    ?assert(beam_agent_mcp_client_dispatch:is_operational(State0)),

    %% Disconnect
    State1 = beam_agent_mcp_client_dispatch:mark_disconnected(
                 tcp_reset, State0),
    ?assertNot(beam_agent_mcp_client_dispatch:is_operational(State1)),
    ?assertEqual(tcp_reset,
                 beam_agent_mcp_client_dispatch:error_info(State1)),

    %% Reset
    State2 = beam_agent_mcp_client_dispatch:reset(State1),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_client_dispatch:lifecycle_state(State2)),

    %% Re-initialize
    {InitMsg, State3} = beam_agent_mcp_client_dispatch:send_initialize(State2),
    Response = make_initialize_response(maps:get(<<"id">>, InitMsg)),
    {response, _, _Result, State4} =
        beam_agent_mcp_client_dispatch:handle_message(Response, State3),
    ?assert(beam_agent_mcp_client_dispatch:is_operational(State4)).
