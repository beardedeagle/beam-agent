%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_core (in-process MCP server support).
%%%
%%% Tests cover:
%%%   - Tool and server constructors
%%%   - Registry management (register, names, empty)
%%%   - CLI integration (servers_for_cli, servers_for_init)
%%%   - JSON-RPC dispatch (initialize, tools/list, tools/call)
%%%   - Handler success, error, crash, and timeout scenarios
%%%   - Unknown server, unknown tool, unknown method errors
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Constructor tests
%%====================================================================

tool_constructor_test() ->
    Handler = fun(_Input) -> {ok, [#{type => text, text => <<"hi">>}]} end,
    Tool = beam_agent_mcp_core:tool(<<"greet">>, <<"Greet user">>,
        #{<<"type">> => <<"object">>}, Handler),
    ?assertEqual(<<"greet">>, maps:get(name, Tool)),
    ?assertEqual(<<"Greet user">>, maps:get(description, Tool)),
    ?assertEqual(#{<<"type">> => <<"object">>}, maps:get(input_schema, Tool)),
    ?assert(is_function(maps:get(handler, Tool), 1)).

server_constructor_default_version_test() ->
    Tool = make_tool(<<"t1">>),
    Server = beam_agent_mcp_core:server(<<"my-server">>, [Tool]),
    ?assertEqual(<<"my-server">>, maps:get(name, Server)),
    ?assertEqual([Tool], maps:get(tools, Server)),
    ?assertEqual(<<"1.0.0">>, maps:get(version, Server)).

server_constructor_explicit_version_test() ->
    Tool = make_tool(<<"t1">>),
    Server = beam_agent_mcp_core:server(<<"s1">>, [Tool], <<"2.0.0">>),
    ?assertEqual(<<"2.0.0">>, maps:get(version, Server)).

%%====================================================================
%% Registry tests
%%====================================================================

empty_registry_test() ->
    Reg = beam_agent_mcp_core:new_registry(),
    ?assertEqual(#{}, Reg),
    ?assertEqual([], beam_agent_mcp_core:server_names(Reg)).

register_server_test() ->
    Server = beam_agent_mcp_core:server(<<"tools">>, [make_tool(<<"t1">>)]),
    Reg = beam_agent_mcp_core:register_server(Server, beam_agent_mcp_core:new_registry()),
    ?assertEqual([<<"tools">>], beam_agent_mcp_core:server_names(Reg)).

register_multiple_servers_test() ->
    S1 = beam_agent_mcp_core:server(<<"a">>, [make_tool(<<"t1">>)]),
    S2 = beam_agent_mcp_core:server(<<"b">>, [make_tool(<<"t2">>)]),
    Reg0 = beam_agent_mcp_core:new_registry(),
    Reg1 = beam_agent_mcp_core:register_server(S1, Reg0),
    Reg2 = beam_agent_mcp_core:register_server(S2, Reg1),
    Names = lists:sort(beam_agent_mcp_core:server_names(Reg2)),
    ?assertEqual([<<"a">>, <<"b">>], Names).

%%====================================================================
%% CLI integration tests
%%====================================================================

servers_for_cli_test() ->
    Server = beam_agent_mcp_core:server(<<"my-tools">>, [make_tool(<<"t1">>)]),
    Reg = beam_agent_mcp_core:register_server(Server, beam_agent_mcp_core:new_registry()),
    Config = beam_agent_mcp_core:servers_for_cli(Reg),
    McpServers = maps:get(<<"mcpServers">>, Config),
    ?assert(is_map(McpServers)),
    ToolConfig = maps:get(<<"my-tools">>, McpServers),
    ?assertEqual(<<"sdk">>, maps:get(<<"type">>, ToolConfig)),
    ?assertEqual(<<"my-tools">>, maps:get(<<"name">>, ToolConfig)).

servers_for_init_test() ->
    S1 = beam_agent_mcp_core:server(<<"a">>, []),
    S2 = beam_agent_mcp_core:server(<<"b">>, []),
    Reg0 = beam_agent_mcp_core:new_registry(),
    Reg = beam_agent_mcp_core:register_server(S2,
        beam_agent_mcp_core:register_server(S1, Reg0)),
    Names = lists:sort(beam_agent_mcp_core:servers_for_init(Reg)),
    ?assertEqual([<<"a">>, <<"b">>], Names).

%%====================================================================
%% JSON-RPC dispatch: initialize
%%====================================================================

initialize_test() ->
    {Reg, _} = make_registry(),
    Msg = #{<<"method">> => <<"initialize">>, <<"id">> => 1},
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Response)),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"2024-11-05">>, maps:get(<<"protocolVersion">>, Result)),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assertEqual(<<"test-server">>, maps:get(<<"name">>, ServerInfo)).

notifications_initialized_test() ->
    {Reg, _} = make_registry(),
    Msg = #{<<"method">> => <<"notifications/initialized">>},
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    ?assertEqual(#{}, Response).

%%====================================================================
%% JSON-RPC dispatch: tools/list
%%====================================================================

tools_list_test() ->
    {Reg, _} = make_registry(),
    Msg = #{<<"method">> => <<"tools/list">>, <<"id">> => 2},
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    Result = maps:get(<<"result">>, Response),
    Tools = maps:get(<<"tools">>, Result),
    ?assertEqual(1, length(Tools)),
    [ToolDef] = Tools,
    ?assertEqual(<<"echo">>, maps:get(<<"name">>, ToolDef)),
    ?assertEqual(<<"Echo input">>, maps:get(<<"description">>, ToolDef)),
    ?assert(is_map(maps:get(<<"inputSchema">>, ToolDef))).

%%====================================================================
%% JSON-RPC dispatch: tools/call — success
%%====================================================================

tools_call_success_test() ->
    {Reg, _} = make_registry(),
    Msg = #{
        <<"method">> => <<"tools/call">>,
        <<"id">> => 3,
        <<"params">> => #{
            <<"name">> => <<"echo">>,
            <<"arguments">> => #{<<"text">> => <<"hello">>}
        }
    },
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    ?assertEqual(3, maps:get(<<"id">>, Response)),
    Result = maps:get(<<"result">>, Response),
    Content = maps:get(<<"content">>, Result),
    ?assertEqual(1, length(Content)),
    [Block] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Block)).

%%====================================================================
%% JSON-RPC dispatch: tools/call — handler error
%%====================================================================

tools_call_handler_error_test() ->
    Handler = fun(_) -> {error, <<"something went wrong">>} end,
    Tool = beam_agent_mcp_core:tool(<<"fail">>, <<"Fails">>,
        #{<<"type">> => <<"object">>}, Handler),
    Server = beam_agent_mcp_core:server(<<"err-server">>, [Tool]),
    Reg = beam_agent_mcp_core:register_server(Server, beam_agent_mcp_core:new_registry()),
    Msg = #{
        <<"method">> => <<"tools/call">>,
        <<"id">> => 4,
        <<"params">> => #{<<"name">> => <<"fail">>, <<"arguments">> => #{}}
    },
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"err-server">>, Msg, Reg),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    [ErrBlock] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"something went wrong">>, maps:get(<<"text">>, ErrBlock)).

%%====================================================================
%% JSON-RPC dispatch: tools/call — handler crash
%%====================================================================

tools_call_handler_crash_test() ->
    Handler = fun(_) -> error(deliberate_crash) end,
    Tool = beam_agent_mcp_core:tool(<<"crash">>, <<"Crashes">>,
        #{<<"type">> => <<"object">>}, Handler),
    Server = beam_agent_mcp_core:server(<<"crash-server">>, [Tool]),
    Reg = beam_agent_mcp_core:register_server(Server, beam_agent_mcp_core:new_registry()),
    Msg = #{
        <<"method">> => <<"tools/call">>,
        <<"id">> => 5,
        <<"params">> => #{<<"name">> => <<"crash">>, <<"arguments">> => #{}}
    },
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"crash-server">>, Msg, Reg),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(true, maps:get(<<"isError">>, Result)).

%%====================================================================
%% JSON-RPC dispatch: tools/call — unknown tool
%%====================================================================

tools_call_unknown_tool_test() ->
    {Reg, _} = make_registry(),
    Msg = #{
        <<"method">> => <<"tools/call">>,
        <<"id">> => 6,
        <<"params">> => #{<<"name">> => <<"nonexistent">>,
                          <<"arguments">> => #{}}
    },
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32602, maps:get(<<"code">>, Error)).

%%====================================================================
%% JSON-RPC dispatch: unknown method
%%====================================================================

unknown_method_test() ->
    {Reg, _} = make_registry(),
    Msg = #{<<"method">> => <<"resources/list">>, <<"id">> => 7},
    {ok, Response} = beam_agent_mcp_core:handle_mcp_message(
        <<"test-server">>, Msg, Reg),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

%%====================================================================
%% Unknown server
%%====================================================================

unknown_server_test() ->
    {Reg, _} = make_registry(),
    Msg = #{<<"method">> => <<"initialize">>, <<"id">> => 8},
    ?assertMatch({error, _},
        beam_agent_mcp_core:handle_mcp_message(<<"no-such-server">>, Msg, Reg)).

%%====================================================================
%% Helpers
%%====================================================================

make_tool(Name) ->
    beam_agent_mcp_core:tool(Name, <<"Test tool">>,
        #{<<"type">> => <<"object">>},
        fun(_) -> {ok, [#{type => text, text => <<"ok">>}]} end).

make_registry() ->
    EchoHandler = fun(Input) ->
        Text = maps:get(<<"text">>, Input, <<"default">>),
        {ok, [#{type => text, text => Text}]}
    end,
    Tool = beam_agent_mcp_core:tool(<<"echo">>, <<"Echo input">>,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}},
        EchoHandler),
    Server = beam_agent_mcp_core:server(<<"test-server">>, [Tool]),
    Reg = beam_agent_mcp_core:register_server(Server, beam_agent_mcp_core:new_registry()),
    {Reg, Server}.
