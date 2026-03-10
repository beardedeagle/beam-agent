%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_dispatch.
%%%
%%% Tests cover:
%%%   - Lifecycle state transitions (uninitialized → initializing → ready)
%%%   - Lifecycle gating (requests rejected before ready)
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
    Tool = beam_agent_mcp_core:tool(<<"echo">>, <<"Echo input">>,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}},
        fun(Input) ->
            Text = maps:get(<<"text">>, Input, <<"default">>),
            {ok, [#{type => text, text => Text}]}
        end),
    Server = beam_agent_mcp_core:server(<<"test">>, [Tool]),
    Registry = beam_agent_mcp_core:register_server(
                   Server, beam_agent_mcp_core:new_registry()),
    beam_agent_mcp_dispatch:new(Info, Caps, #{tool_registry => Registry}).

%% Create a state with a mock provider.
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
    ?assertEqual(1, length(Resources)).

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
    ?assert(maps:is_key(<<"messages">>, Result)).

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
    ?assert(is_list(maps:get(<<"values">>, Completion))).

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
