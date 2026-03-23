%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_dispatch.
%%%
%%% Tests cover:
%%%   - Lifecycle state transitions (uninitialized → initializing → ready
%%%     → error | shutting_down, error → reset → uninitialized)
%%%   - Lifecycle transitions (mark_error, mark_shutting_down, reset)
%%%   - Lifecycle accessors (error_info, is_operational)
%%%   - Lifecycle gating (requests rejected before ready)
%%%   - Request/notification gating in error and shutting_down states
%%%   - Ping in all states
%%%   - Initialize handshake and capability negotiation
%%%   - Tool dispatch (list, call, errors)
%%%   - Provider dispatch (resources, prompts, completions, logging)
%%%   - Notification handling (initialized, cancelled, progress, roots)
%%%   - Unknown method handling
%%%   - Invalid message handling
%%%   - Subscribe/unsubscribe capability gating
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Helpers
%%====================================================================

%% Create a minimal dispatch state in uninitialized lifecycle.
make_state() ->
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test-server">>, <<"1.0.0">>),
    Caps = #{tools => #{listChanged => true}},
    beam_agent_mcp_dispatch:new(Info, Caps, #{}).

%% Create a state with a tool registry.
make_state_with_tools() ->
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test-server">>, <<"1.0.0">>),
    Caps = #{tools => #{listChanged => true}},
    Tool = beam_agent_tool_registry:tool(<<"echo">>, <<"Echo input">>,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}},
        fun(Input) ->
            Text = maps:get(<<"text">>, Input, <<"default">>),
            {ok, [#{type => text, text => Text}]}
        end),
    Server = beam_agent_tool_registry:server(<<"test">>, [Tool]),
    Registry = beam_agent_tool_registry:register_server(
                   Server, beam_agent_tool_registry:new_registry()),
    beam_agent_mcp_dispatch:new(Info, Caps, #{tool_registry => Registry}).

%% Create a state with a test provider.
make_state_with_provider() ->
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test-server">>, <<"1.0.0">>),
    Caps = #{tools => #{listChanged => true},
             resources => #{subscribe => true, listChanged => true},
             prompts => #{listChanged => true},
             completions => #{},
             logging => #{}},
    beam_agent_mcp_dispatch:new(Info, Caps, #{
        provider => beam_agent_mcp_dispatch_test_provider,
        provider_state => #{log_level => info}
    }).

%% Perform the initialize handshake and return the ready state.
do_initialize(State) ->
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"protocolVersion">> => <<"2025-06-18">>,
                    <<"capabilities">> => #{<<"roots">> =>
                                                #{<<"listChanged">> => true}},
                    <<"clientInfo">> => #{<<"name">> => <<"test-client">>,
                                          <<"version">> => <<"1.0">>}
                }},
    {_Resp, State1} = beam_agent_mcp_dispatch:handle_message(InitMsg, State),
    ?assertEqual(initializing, beam_agent_mcp_dispatch:lifecycle_state(State1)),

    InitializedMsg = #{<<"jsonrpc">> => <<"2.0">>,
                       <<"method">> => <<"notifications/initialized">>},
    {noreply, State2} = beam_agent_mcp_dispatch:handle_message(
                             InitializedMsg, State1),
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(State2)),
    State2.

%%====================================================================
%% Lifecycle Tests
%%====================================================================

new_state_is_uninitialized_test() ->
    State = make_state(),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_dispatch:lifecycle_state(State)),
    ?assertEqual(undefined,
                 beam_agent_mcp_dispatch:session_capabilities(State)).

initialize_transitions_to_initializing_test() ->
    State = make_state(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
            <<"method">> => <<"initialize">>,
            <<"params">> => #{<<"protocolVersion">> => <<"2025-06-18">>,
                              <<"capabilities">> => #{},
                              <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                                     <<"version">> => <<"1">>}
                             }},
    {Resp, NewState} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assertEqual(initializing,
                 beam_agent_mcp_dispatch:lifecycle_state(NewState)),
    %% Response should have result with protocolVersion
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(<<"2025-06-18">>, maps:get(<<"protocolVersion">>, Result)),
    %% Session capabilities should be set
    SessionCaps = beam_agent_mcp_dispatch:session_capabilities(NewState),
    ?assert(is_map(SessionCaps)),
    ?assert(maps:is_key(server, SessionCaps)),
    ?assert(maps:is_key(client, SessionCaps)).

initialized_notification_transitions_to_ready_test() ->
    State = make_state(),
    ReadyState = do_initialize(State),
    ?assertEqual(ready,
                 beam_agent_mcp_dispatch:lifecycle_state(ReadyState)).

initialize_rejected_when_not_uninitialized_test() ->
    State = make_state(),
    ReadyState = do_initialize(State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 99,
            <<"method">> => <<"initialize">>,
            <<"params">> => #{<<"protocolVersion">> => <<"2025-06-18">>,
                              <<"capabilities">> => #{},
                              <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                                     <<"version">> => <<"1">>}
                             }},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, ReadyState),
    ?assert(maps:is_key(<<"error">>, Resp)).

requests_rejected_before_ready_test() ->
    State = make_state(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 5,
            <<"method">> => <<"tools/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32600, maps:get(<<"code">>, Err)).

%%====================================================================
%% Ping Tests
%%====================================================================

ping_works_in_any_state_test() ->
    State = make_state(),
    PingMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 10,
                <<"method">> => <<"ping">>, <<"params">> => #{}},
    %% Uninitialized
    {Resp1, _} = beam_agent_mcp_dispatch:handle_message(PingMsg, State),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp1)),

    %% Ready
    ReadyState = do_initialize(State),
    {Resp2, _} = beam_agent_mcp_dispatch:handle_message(PingMsg, ReadyState),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp2)).

%%====================================================================
%% Tool Tests
%%====================================================================

tools_list_empty_registry_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
            <<"method">> => <<"tools/list">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual([], maps:get(<<"tools">>, Result)).

tools_list_with_registry_test() ->
    State = do_initialize(make_state_with_tools()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
            <<"method">> => <<"tools/list">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    Tools = maps:get(<<"tools">>, Result),
    ?assertEqual(1, length(Tools)),
    [Tool] = Tools,
    ?assertEqual(<<"echo">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Echo input">>, maps:get(<<"description">>, Tool)).

tools_call_success_test() ->
    State = do_initialize(make_state_with_tools()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{<<"name">> => <<"echo">>,
                              <<"arguments">> => #{<<"text">> => <<"hi">>}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    [Content] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"hi">>, maps:get(<<"text">>, Content)),
    ?assertNot(maps:is_key(<<"isError">>, Result)).

tools_call_unknown_tool_test() ->
    State = do_initialize(make_state_with_tools()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{<<"name">> => <<"nonexistent">>,
                              <<"arguments">> => #{}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(true, maps:get(<<"isError">>, Result)).

tools_call_no_registry_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 5,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{<<"name">> => <<"x">>,
                              <<"arguments">> => #{}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)).

%%====================================================================
%% Provider Tests — Resources
%%====================================================================

resources_list_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 10,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    Resources = maps:get(<<"resources">>, Result),
    ?assertEqual(1, length(Resources)),
    [Res] = Resources,
    ?assert(maps:is_key(<<"uri">>, Res)).

resources_read_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 11,
            <<"method">> => <<"resources/read">>,
            <<"params">> => #{<<"uri">> => <<"file:///test.txt">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    [Contents] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"file:///test.txt">>, maps:get(<<"uri">>, Contents)).

resources_read_missing_uri_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 12,
            <<"method">> => <<"resources/read">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)).

resources_templates_list_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 13,
            <<"method">> => <<"resources/templates/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    ?assert(maps:is_key(<<"resourceTemplates">>, Result)).

resources_subscribe_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 14,
            <<"method">> => <<"resources/subscribe">>,
            <<"params">> => #{<<"uri">> => <<"file:///test.txt">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp)).

resources_subscribe_not_supported_test() ->
    %% State without subscribe capability
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test">>, <<"1.0">>),
    Caps = #{resources => #{listChanged => true}},
    State0 = beam_agent_mcp_dispatch:new(Info, Caps, #{
        provider => beam_agent_mcp_dispatch_test_provider,
        provider_state => #{log_level => info}
    }),
    State = do_initialize(State0),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 15,
            <<"method">> => <<"resources/subscribe">>,
            <<"params">> => #{<<"uri">> => <<"file:///test.txt">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)).

%%====================================================================
%% Provider Tests — Prompts
%%====================================================================

prompts_list_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 20,
            <<"method">> => <<"prompts/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    [Prompt] = maps:get(<<"prompts">>, Result),
    ?assertEqual(<<"greet">>, maps:get(<<"name">>, Prompt)).

prompts_get_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 21,
            <<"method">> => <<"prompts/get">>,
            <<"params">> => #{<<"name">> => <<"greet">>,
                              <<"arguments">> => #{<<"user">> => <<"Alice">>}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    ?assert(maps:is_key(<<"messages">>, Result)),
    Messages = maps:get(<<"messages">>, Result),
    ?assert(length(Messages) > 0).

prompts_get_missing_name_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 22,
            <<"method">> => <<"prompts/get">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)).

%%====================================================================
%% Provider Tests — Completions
%%====================================================================

completion_complete_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 30,
            <<"method">> => <<"completion/complete">>,
            <<"params">> => #{<<"ref">> => #{<<"type">> => <<"ref/prompt">>,
                                             <<"name">> => <<"greet">>},
                              <<"argument">> => #{<<"name">> => <<"user">>,
                                                  <<"value">> => <<"Al">>}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Result = maps:get(<<"result">>, Resp),
    Completion = maps:get(<<"completion">>, Result),
    Values = maps:get(<<"values">>, Completion),
    ?assert(is_list(Values)),
    ?assert(length(Values) > 0).

%%====================================================================
%% Provider Tests — Logging
%%====================================================================

logging_set_level_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 40,
            <<"method">> => <<"logging/setLevel">>,
            <<"params">> => #{<<"level">> => <<"error">>}},
    {Resp, NewState} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp)),
    %% Provider state should be updated
    PState = maps:get(provider_state, NewState),
    ?assertEqual(error, maps:get(log_level, PState)).

%%====================================================================
%% Notification Tests
%%====================================================================

initialized_notification_ignored_when_not_initializing_test() ->
    State = make_state(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/initialized">>},
    {noreply, NewState} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_dispatch:lifecycle_state(NewState)).

cancelled_notification_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/cancelled">>,
            <<"params">> => #{<<"requestId">> => 42}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

progress_notification_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/progress">>,
            <<"params">> => #{<<"progressToken">> => <<"t">>,
                              <<"progress">> => 50}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

roots_list_changed_notification_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/roots/list_changed">>},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

unknown_notification_ignored_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/some_future_thing">>},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

%%====================================================================
%% Unknown Method Tests
%%====================================================================

unknown_method_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 99,
            <<"method">> => <<"bogus/method">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, Err)).

%%====================================================================
%% Capability Gating Tests
%%====================================================================

resources_method_rejected_without_capability_test() ->
    %% State with only tools capability
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 50,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, Err)).

prompts_method_rejected_without_capability_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 51,
            <<"method">> => <<"prompts/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"error">>, Resp)).

%%====================================================================
%% Invalid Message Tests
%%====================================================================

invalid_message_test() ->
    State = make_state(),
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(
                    #{<<"something">> => <<"weird">>}, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32600, maps:get(<<"code">>, Err)).

%%====================================================================
%% Client Response Ignored Tests
%%====================================================================

response_message_ignored_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
            <<"result">> => #{<<"ok">> => true}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

error_response_message_ignored_test() ->
    State = do_initialize(make_state()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
            <<"error">> => #{<<"code">> => -1, <<"message">> => <<"err">>}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, State).

%%====================================================================
%% Lifecycle Transition Tests — mark_error / mark_shutting_down / reset
%%====================================================================

mark_error_from_ready_test() ->
    State = do_initialize(make_state()),
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(State)),
    ErrorState = beam_agent_mcp_dispatch:mark_error(protocol_violation, State),
    ?assertEqual(error, beam_agent_mcp_dispatch:lifecycle_state(ErrorState)),
    ?assertEqual(protocol_violation,
                 beam_agent_mcp_dispatch:error_info(ErrorState)).

mark_error_from_uninitialized_test() ->
    State = make_state(),
    ErrorState = beam_agent_mcp_dispatch:mark_error(startup_failure, State),
    ?assertEqual(error, beam_agent_mcp_dispatch:lifecycle_state(ErrorState)),
    ?assertEqual(startup_failure,
                 beam_agent_mcp_dispatch:error_info(ErrorState)).

mark_error_from_initializing_test() ->
    State = make_state(),
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{<<"protocolVersion">> => <<"2025-06-18">>,
                                  <<"capabilities">> => #{},
                                  <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                                         <<"version">> => <<"1">>}}},
    {_Resp, InitializingState} = beam_agent_mcp_dispatch:handle_message(
                                      InitMsg, State),
    ?assertEqual(initializing,
                 beam_agent_mcp_dispatch:lifecycle_state(InitializingState)),
    ErrorState = beam_agent_mcp_dispatch:mark_error(timeout, InitializingState),
    ?assertEqual(error, beam_agent_mcp_dispatch:lifecycle_state(ErrorState)).

mark_shutting_down_from_ready_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    ?assertEqual(shutting_down,
                 beam_agent_mcp_dispatch:lifecycle_state(ShutState)).

mark_shutting_down_from_uninitialized_test() ->
    State = make_state(),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    ?assertEqual(shutting_down,
                 beam_agent_mcp_dispatch:lifecycle_state(ShutState)).

reset_from_error_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(some_reason, State),
    ResetState = beam_agent_mcp_dispatch:reset(ErrorState),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_dispatch:lifecycle_state(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_dispatch:error_info(ResetState)),
    ?assertEqual(undefined,
                 beam_agent_mcp_dispatch:session_capabilities(ResetState)).

reset_from_ready_raises_test() ->
    State = do_initialize(make_state()),
    ?assertError({invalid_reset, ready},
                 beam_agent_mcp_dispatch:reset(State)).

reset_from_uninitialized_raises_test() ->
    State = make_state(),
    ?assertError({invalid_reset, uninitialized},
                 beam_agent_mcp_dispatch:reset(State)).

reset_from_shutting_down_raises_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    ?assertError({invalid_reset, shutting_down},
                 beam_agent_mcp_dispatch:reset(ShutState)).

%%====================================================================
%% Accessor Tests — error_info / is_operational
%%====================================================================

error_info_undefined_when_not_error_test() ->
    State = make_state(),
    ?assertEqual(undefined, beam_agent_mcp_dispatch:error_info(State)),
    ReadyState = do_initialize(State),
    ?assertEqual(undefined, beam_agent_mcp_dispatch:error_info(ReadyState)).

is_operational_ready_test() ->
    State = do_initialize(make_state()),
    ?assert(beam_agent_mcp_dispatch:is_operational(State)).

is_operational_uninitialized_test() ->
    State = make_state(),
    ?assertNot(beam_agent_mcp_dispatch:is_operational(State)).

is_operational_error_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(oops, State),
    ?assertNot(beam_agent_mcp_dispatch:is_operational(ErrorState)).

is_operational_shutting_down_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    ?assertNot(beam_agent_mcp_dispatch:is_operational(ShutState)).

%%====================================================================
%% Request Gating — Error State
%%====================================================================

ping_works_in_error_state_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(broken, State),
    PingMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 20,
                <<"method">> => <<"ping">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(PingMsg, ErrorState),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp)).

initialize_accepted_in_error_state_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(broken, State),
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 21,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{<<"protocolVersion">> => <<"2025-06-18">>,
                                  <<"capabilities">> => #{},
                                  <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                                         <<"version">> => <<"1">>}}},
    {Resp, NewState} = beam_agent_mcp_dispatch:handle_message(
                             InitMsg, ErrorState),
    %% Should succeed (auto-reset then initialize)
    ?assert(maps:is_key(<<"result">>, Resp)),
    ?assertEqual(initializing,
                 beam_agent_mcp_dispatch:lifecycle_state(NewState)),
    %% error_info should be cleared by the reset
    ?assertEqual(undefined,
                 beam_agent_mcp_dispatch:error_info(NewState)).

tools_list_rejected_in_error_state_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(broken, State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 22,
            <<"method">> => <<"tools/list">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, ErrorState),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32603, maps:get(<<"code">>, Err)).

%%====================================================================
%% Request Gating — Shutting Down State
%%====================================================================

ping_works_in_shutting_down_state_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    PingMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 30,
                <<"method">> => <<"ping">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(PingMsg, ShutState),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp)).

tools_list_rejected_in_shutting_down_state_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 31,
            <<"method">> => <<"tools/list">>, <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, ShutState),
    ?assert(maps:is_key(<<"error">>, Resp)),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32600, maps:get(<<"code">>, Err)).

initialize_rejected_in_shutting_down_state_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 32,
            <<"method">> => <<"initialize">>,
            <<"params">> => #{<<"protocolVersion">> => <<"2025-06-18">>,
                              <<"capabilities">> => #{},
                              <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                                     <<"version">> => <<"1">>}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, ShutState),
    ?assert(maps:is_key(<<"error">>, Resp)).

%%====================================================================
%% M8: Protocol version validation in initialize handshake
%%====================================================================

initialize_stores_negotiated_version_test() ->
    %% After a successful initialize with matching version, state should
    %% hold the negotiated protocol version.
    State = make_state(),
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 100,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"protocolVersion">> => <<"2025-06-18">>,
                    <<"capabilities">> => #{},
                    <<"clientInfo">> => #{<<"name">> => <<"c">>,
                                          <<"version">> => <<"1">>}}},
    {_Resp, NewState} = beam_agent_mcp_dispatch:handle_message(
                            InitMsg, State),
    ?assertEqual(<<"2025-06-18">>,
                 maps:get(negotiated_protocol_version, NewState)).

initialize_accepts_mismatched_version_with_warning_test() ->
    %% A client sending a different version should still succeed (server
    %% logs a warning but proceeds), using its own version.
    State = make_state(),
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 101,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"protocolVersion">> => <<"2024-11-05">>,
                    <<"capabilities">> => #{},
                    <<"clientInfo">> => #{<<"name">> => <<"old-client">>,
                                          <<"version">> => <<"0.9">>}}},
    {Resp, NewState} = beam_agent_mcp_dispatch:handle_message(
                           InitMsg, State),
    %% Response is still valid (server doesn't reject on mismatch)
    ?assert(maps:is_key(<<"result">>, Resp)),
    %% Negotiated version is always the server's own version
    ?assertEqual(<<"2025-06-18">>,
                 maps:get(negotiated_protocol_version, NewState)).

initialize_accepts_missing_version_test() ->
    %% A client that omits protocolVersion should still succeed.
    State = make_state(),
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 102,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"capabilities">> => #{},
                    <<"clientInfo">> => #{<<"name">> => <<"legacy">>,
                                          <<"version">> => <<"1.0">>}}},
    {Resp, _NewState} = beam_agent_mcp_dispatch:handle_message(
                            InitMsg, State),
    ?assert(maps:is_key(<<"result">>, Resp)).

%%====================================================================
%% M10: Cursor type validation
%%====================================================================

resources_list_rejects_bad_cursor_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 200,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{<<"cursor">> => 42}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32602, maps:get(<<"code">>, Err)).

resources_list_accepts_binary_cursor_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 201,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{<<"cursor">> => <<"page-2">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"result">>, Resp)).

resources_list_accepts_missing_cursor_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 202,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    ?assert(maps:is_key(<<"result">>, Resp)).

resources_templates_list_rejects_bad_cursor_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 210,
            <<"method">> => <<"resources/templates/list">>,
            <<"params">> => #{<<"cursor">> => [bad]}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32602, maps:get(<<"code">>, Err)).

prompts_list_rejects_bad_cursor_test() ->
    State = do_initialize(make_state_with_provider()),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 220,
            <<"method">> => <<"prompts/list">>,
            <<"params">> => #{<<"cursor">> => #{}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32602, maps:get(<<"code">>, Err)).

%%====================================================================
%% M16: Safe defaults for State access
%%====================================================================

dispatch_provider_safe_when_no_server_caps_test() ->
    %% Build a state without server_capabilities (simulating a stripped state).
    %% dispatch_provider should return method_not_found instead of crashing.
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test">>, <<"1.0">>),
    %% Start with normal state, then manually remove server_capabilities
    BaseState = beam_agent_mcp_dispatch:new(Info, #{}, #{}),
    State = do_initialize(BaseState),
    StrippedState = maps:remove(server_capabilities, State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 300,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    %% Should return method_not_found (-32601), not crash
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, StrippedState),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32601, maps:get(<<"code">>, Err)).

%%====================================================================
%% L4: Notification flood protection
%%====================================================================

notification_flood_drops_when_limit_exceeded_test() ->
    %% Set limit to 2 notifications per interval.
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test">>, <<"1.0">>),
    Caps = #{tools => #{}},
    State0 = beam_agent_mcp_dispatch:new(Info, Caps,
                 #{max_notifications_per_interval => 2}),
    State1 = do_initialize_state(State0),

    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/progress">>,
              <<"params">> => #{}},

    %% First notification: accepted — window count becomes 1
    {noreply, State2} = beam_agent_mcp_dispatch:handle_message(Notif, State1),
    {Count2, _} = maps:get(notification_window, State2),
    ?assertEqual(1, Count2),

    %% Second notification: accepted — window count becomes 2
    {noreply, State3} = beam_agent_mcp_dispatch:handle_message(Notif, State2),
    {Count3, _} = maps:get(notification_window, State3),
    ?assertEqual(2, Count3),

    %% Third notification: dropped (over limit) — count stays at 2
    {noreply, State4} = beam_agent_mcp_dispatch:handle_message(Notif, State3),
    {Count4, _} = maps:get(notification_window, State4),
    ?assertEqual(2, Count4).

notification_flood_unlimited_when_zero_test() ->
    %% Default (limit=0) means unlimited.
    State = do_initialize(make_state()),
    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/progress">>,
              <<"params">> => #{}},
    %% Send 5 notifications — all accepted
    State1 = lists:foldl(fun(_, S) ->
        {noreply, S1} = beam_agent_mcp_dispatch:handle_message(Notif, S),
        S1
    end, State, lists:seq(1, 5)),
    {Count, _} = maps:get(notification_window, State1),
    ?assertEqual(5, Count).

notification_flood_resets_after_window_expires_test() ->
    %% Use a 1 ms window so we can test expiry without sleeping.
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test">>, <<"1.0">>),
    Caps = #{tools => #{}},
    State0 = beam_agent_mcp_dispatch:new(Info, Caps,
                 #{max_notifications_per_interval => 2,
                   notification_interval_ms => 1}),
    State1 = do_initialize_state(State0),

    Notif = #{<<"jsonrpc">> => <<"2.0">>,
              <<"method">> => <<"notifications/progress">>,
              <<"params">> => #{}},

    %% Fill the window: send 2 notifications.
    {noreply, State2} = beam_agent_mcp_dispatch:handle_message(Notif, State1),
    {noreply, State3} = beam_agent_mcp_dispatch:handle_message(Notif, State2),
    {Count3, _} = maps:get(notification_window, State3),
    ?assertEqual(2, Count3),

    %% Wait for the 1 ms window to expire, then send another notification.
    %% The counter must reset to 1 (window opened fresh).
    timer:sleep(5),
    {noreply, State4} = beam_agent_mcp_dispatch:handle_message(Notif, State3),
    {Count4, _} = maps:get(notification_window, State4),
    ?assertEqual(1, Count4).

notification_flood_initialized_bypasses_protection_test() ->
    %% notifications/initialized must always pass even at limit.
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test">>, <<"1.0">>),
    Caps = #{tools => #{}},
    State0 = beam_agent_mcp_dispatch:new(Info, Caps,
                 #{max_notifications_per_interval => 1}),
    %% Drive through initialize so lifecycle = initializing (awaiting initialized).
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"protocolVersion">> => <<"2025-06-18">>,
                    <<"capabilities">> => #{},
                    <<"clientInfo">> => #{<<"name">> => <<"tc">>,
                                          <<"version">> => <<"1">>}}},
    {_Resp, StateInit} = beam_agent_mcp_dispatch:handle_message(InitMsg, State0),
    %% Inject a fake window that is already full.
    StateInit2 = StateInit#{notification_window => {1, erlang:monotonic_time(millisecond)}},
    %% notifications/initialized must still transition to ready.
    InitedMsg = #{<<"jsonrpc">> => <<"2.0">>,
                  <<"method">> => <<"notifications/initialized">>},
    {noreply, StateFinal} = beam_agent_mcp_dispatch:handle_message(
                                InitedMsg, StateInit2),
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(StateFinal)).

%%====================================================================
%% Helpers (private to test module)
%%====================================================================

%% Like do_initialize/1 but works on any initial state (not just make_state()).
do_initialize_state(State) ->
    InitMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"method">> => <<"initialize">>,
                <<"params">> => #{
                    <<"protocolVersion">> => <<"2025-06-18">>,
                    <<"capabilities">> => #{},
                    <<"clientInfo">> => #{<<"name">> => <<"tc">>,
                                          <<"version">> => <<"1">>}}},
    {_Resp, State1} = beam_agent_mcp_dispatch:handle_message(InitMsg, State),
    InitedMsg = #{<<"jsonrpc">> => <<"2.0">>,
                  <<"method">> => <<"notifications/initialized">>},
    {noreply, State2} = beam_agent_mcp_dispatch:handle_message(
                            InitedMsg, State1),
    State2.

%%====================================================================
%% Notification Gating — Error / Shutting Down States
%%====================================================================

notifications_ignored_in_error_state_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(broken, State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/progress">>,
            <<"params">> => #{<<"progressToken">> => <<"t">>,
                              <<"progress">> => 50}},
    {noreply, ResultState} = beam_agent_mcp_dispatch:handle_message(
                                  Msg, ErrorState),
    ?assertEqual(error, beam_agent_mcp_dispatch:lifecycle_state(ResultState)).

notifications_ignored_in_shutting_down_state_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/roots/list_changed">>},
    {noreply, ResultState} = beam_agent_mcp_dispatch:handle_message(
                                  Msg, ShutState),
    ?assertEqual(shutting_down,
                 beam_agent_mcp_dispatch:lifecycle_state(ResultState)).

cancelled_notification_accepted_in_error_state_test() ->
    State = do_initialize(make_state()),
    ErrorState = beam_agent_mcp_dispatch:mark_error(broken, State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/cancelled">>,
            <<"params">> => #{<<"requestId">> => 99}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, ErrorState).

cancelled_notification_accepted_in_shutting_down_state_test() ->
    State = do_initialize(make_state()),
    ShutState = beam_agent_mcp_dispatch:mark_shutting_down(State),
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/cancelled">>,
            <<"params">> => #{<<"requestId">> => 99}},
    {noreply, _} = beam_agent_mcp_dispatch:handle_message(Msg, ShutState).

%%====================================================================
%% Provider Crash Isolation Tests (H4)
%%====================================================================

%% Helper: state wired to the crash provider, fully initialized.
make_state_with_crash_provider() ->
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"test-server">>, <<"1.0.0">>),
    Caps = #{tools => #{listChanged => true},
             resources => #{subscribe => true, listChanged => true},
             prompts => #{listChanged => true},
             completions => #{},
             logging => #{}},
    State0 = beam_agent_mcp_dispatch:new(Info, Caps, #{
        provider => beam_agent_mcp_dispatch_crash_provider,
        provider_state => #{}
    }),
    do_initialize(State0).

%% Verify the response is a JSON-RPC internal error (-32603).
assert_internal_error(Resp) ->
    ?assert(maps:is_key(<<"error">>, Resp),
            {expected_error_response, Resp}),
    Err = maps:get(<<"error">>, Resp),
    ?assertEqual(-32603, maps:get(<<"code">>, Err)).

provider_crash_resources_list_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 100,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_resources_read_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 101,
            <<"method">> => <<"resources/read">>,
            <<"params">> => #{<<"uri">> => <<"file:///crash.txt">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_resources_templates_list_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 102,
            <<"method">> => <<"resources/templates/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_prompts_list_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 103,
            <<"method">> => <<"prompts/list">>,
            <<"params">> => #{}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_prompts_get_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 104,
            <<"method">> => <<"prompts/get">>,
            <<"params">> => #{<<"name">> => <<"any">>,
                              <<"arguments">> => #{}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_completion_complete_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 105,
            <<"method">> => <<"completion/complete">>,
            <<"params">> => #{<<"ref">> => #{<<"type">> => <<"ref/prompt">>,
                                             <<"name">> => <<"any">>},
                              <<"argument">> => #{<<"name">> => <<"x">>,
                                                  <<"value">> => <<"y">>}}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

provider_crash_logging_set_level_returns_internal_error_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 106,
            <<"method">> => <<"logging/setLevel">>,
            <<"params">> => #{<<"level">> => <<"debug">>}},
    {Resp, _} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    assert_internal_error(Resp).

%% Verify that the session state is preserved (not crashed) after a
%% provider crash — the dispatch state returned is still usable.
provider_crash_does_not_corrupt_session_state_test() ->
    State = make_state_with_crash_provider(),
    Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 107,
            <<"method">> => <<"resources/list">>,
            <<"params">> => #{}},
    {_Resp, NewState} = beam_agent_mcp_dispatch:handle_message(Msg, State),
    %% Lifecycle must still be ready after a provider crash
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(NewState)),
    %% A subsequent ping must still work
    PingMsg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 108,
                <<"method">> => <<"ping">>, <<"params">> => #{}},
    {PingResp, _} = beam_agent_mcp_dispatch:handle_message(PingMsg, NewState),
    ?assertEqual(#{}, maps:get(<<"result">>, PingResp)).

%%====================================================================
%% Full Lifecycle Round-Trip: ready → error → reset → re-initialize
%%====================================================================

full_error_recovery_round_trip_test() ->
    %% Start fresh, get to ready
    State0 = do_initialize(make_state()),
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(State0)),
    ?assert(beam_agent_mcp_dispatch:is_operational(State0)),

    %% Mark error
    State1 = beam_agent_mcp_dispatch:mark_error(provider_crash, State0),
    ?assertEqual(error, beam_agent_mcp_dispatch:lifecycle_state(State1)),
    ?assertNot(beam_agent_mcp_dispatch:is_operational(State1)),
    ?assertEqual(provider_crash, beam_agent_mcp_dispatch:error_info(State1)),

    %% Reset back to uninitialized
    State2 = beam_agent_mcp_dispatch:reset(State1),
    ?assertEqual(uninitialized,
                 beam_agent_mcp_dispatch:lifecycle_state(State2)),
    ?assertEqual(undefined, beam_agent_mcp_dispatch:error_info(State2)),

    %% Re-initialize successfully
    State3 = do_initialize(State2),
    ?assertEqual(ready, beam_agent_mcp_dispatch:lifecycle_state(State3)),
    ?assert(beam_agent_mcp_dispatch:is_operational(State3)).
