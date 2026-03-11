%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_client_dispatch.
%%%
%%% Tests cover:
%%%   - State construction and accessors
%%%   - Lifecycle state machine (uninitialized → initializing → ready)
%%%   - Lifecycle gating (send_* rejected in wrong state)
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
