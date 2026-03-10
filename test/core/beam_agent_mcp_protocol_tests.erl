%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_protocol.
%%%
%%% Tests cover:
%%%   - Protocol metadata
%%%   - JSON-RPC 2.0 envelope constructors (request, response, error,
%%%     notification)
%%%   - All MCP message constructors (lifecycle, tools, resources,
%%%     prompts, completions, logging, sampling, elicitation, roots,
%%%     progress, cancellation)
%%%   - Capability negotiation and querying
%%%   - Message validation (requests, notifications, responses, errors,
%%%     invalid messages)
%%%   - Type validators (tool, resource, prompt)
%%%   - Content constructors
%%%   - Type constructors (implementation_info, tool_annotation,
%%%     resource_annotation, model_preferences)
%%%   - Wire encoding correctness (optional fields omitted when
%%%     undefined, required fields always present)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Protocol Metadata
%%====================================================================

protocol_version_test() ->
    ?assertEqual(<<"2025-06-18">>,
                 beam_agent_mcp_protocol:protocol_version()).

%%====================================================================
%% JSON-RPC 2.0 Envelope Constructors
%%====================================================================

request_test() ->
    Msg = beam_agent_mcp_protocol:request(1, <<"test/method">>,
                                          #{<<"key">> => <<"val">>}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(1, maps:get(<<"id">>, Msg)),
    ?assertEqual(<<"test/method">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(#{<<"key">> => <<"val">>}, maps:get(<<"params">>, Msg)).

request_with_progress_token_test() ->
    Msg = beam_agent_mcp_protocol:request(2, <<"tools/call">>,
                                          #{<<"name">> => <<"t1">>},
                                          <<"tok-1">>),
    Params = maps:get(<<"params">>, Msg),
    Meta = maps:get(<<"_meta">>, Params),
    ?assertEqual(<<"tok-1">>, maps:get(<<"progressToken">>, Meta)),
    ?assertEqual(<<"t1">>, maps:get(<<"name">>, Params)).

response_test() ->
    Msg = beam_agent_mcp_protocol:response(42, #{<<"ok">> => true}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(42, maps:get(<<"id">>, Msg)),
    ?assertEqual(#{<<"ok">> => true}, maps:get(<<"result">>, Msg)).

error_response_no_data_test() ->
    Msg = beam_agent_mcp_protocol:error_response(3, -32601,
                                                  <<"Method not found">>),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(3, maps:get(<<"id">>, Msg)),
    Err = maps:get(<<"error">>, Msg),
    ?assertEqual(-32601, maps:get(<<"code">>, Err)),
    ?assertEqual(<<"Method not found">>, maps:get(<<"message">>, Err)),
    ?assertNot(maps:is_key(<<"data">>, Err)).

error_response_with_data_test() ->
    Msg = beam_agent_mcp_protocol:error_response(4, -32602,
                                                  <<"Invalid params">>,
                                                  #{<<"detail">> => <<"x">>}),
    Err = maps:get(<<"error">>, Msg),
    ?assertEqual(#{<<"detail">> => <<"x">>}, maps:get(<<"data">>, Err)).

notification_no_params_test() ->
    Msg = beam_agent_mcp_protocol:notification(<<"notifications/initialized">>),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(<<"notifications/initialized">>, maps:get(<<"method">>, Msg)),
    ?assertNot(maps:is_key(<<"id">>, Msg)),
    ?assertNot(maps:is_key(<<"params">>, Msg)).

notification_with_params_test() ->
    Msg = beam_agent_mcp_protocol:notification(<<"notifications/progress">>,
                                               #{<<"progress">> => 50}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg)),
    ?assertEqual(#{<<"progress">> => 50}, maps:get(<<"params">>, Msg)).

%%====================================================================
%% Lifecycle Messages
%%====================================================================

initialize_request_test() ->
    Info = beam_agent_mcp_protocol:implementation_info(<<"test">>, <<"1.0">>),
    Caps = #{roots => #{listChanged => true}},
    Msg = beam_agent_mcp_protocol:initialize_request(1, Info, Caps),
    ?assertEqual(<<"initialize">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"2025-06-18">>, maps:get(<<"protocolVersion">>, Params)),
    ClientInfo = maps:get(<<"clientInfo">>, Params),
    ?assertEqual(<<"test">>, maps:get(<<"name">>, ClientInfo)),
    ClientCaps = maps:get(<<"capabilities">>, Params),
    ?assert(maps:is_key(<<"roots">>, ClientCaps)).

initialize_response_test() ->
    Info = beam_agent_mcp_protocol:implementation_info(
               <<"myserver">>, <<"2.0">>, <<"My Server">>),
    Caps = #{tools => #{listChanged => true},
             resources => #{subscribe => true, listChanged => false}},
    Msg = beam_agent_mcp_protocol:initialize_response(1, Info, Caps),
    Result = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"2025-06-18">>, maps:get(<<"protocolVersion">>, Result)),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assertEqual(<<"myserver">>, maps:get(<<"name">>, ServerInfo)),
    ?assertEqual(<<"My Server">>, maps:get(<<"title">>, ServerInfo)),
    ServerCaps = maps:get(<<"capabilities">>, Result),
    ?assert(maps:is_key(<<"tools">>, ServerCaps)),
    ?assert(maps:is_key(<<"resources">>, ServerCaps)).

initialized_notification_test() ->
    Msg = beam_agent_mcp_protocol:initialized_notification(),
    ?assertEqual(<<"notifications/initialized">>, maps:get(<<"method">>, Msg)),
    ?assertNot(maps:is_key(<<"id">>, Msg)).

ping_request_test() ->
    Msg = beam_agent_mcp_protocol:ping_request(99),
    ?assertEqual(<<"ping">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(99, maps:get(<<"id">>, Msg)).

ping_response_test() ->
    Msg = beam_agent_mcp_protocol:ping_response(99),
    ?assertEqual(#{}, maps:get(<<"result">>, Msg)).

%%====================================================================
%% Tool Messages
%%====================================================================

tools_list_request_no_cursor_test() ->
    Msg = beam_agent_mcp_protocol:tools_list_request(1),
    ?assertEqual(<<"tools/list">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertNot(maps:is_key(<<"cursor">>, Params)).

tools_list_request_with_cursor_test() ->
    Msg = beam_agent_mcp_protocol:tools_list_request(1, <<"cursor-abc">>),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"cursor-abc">>, maps:get(<<"cursor">>, Params)).

tools_list_response_no_pagination_test() ->
    Tool = #{name => <<"grep">>, inputSchema => #{<<"type">> => <<"object">>},
             description => <<"Search files">>},
    Msg = beam_agent_mcp_protocol:tools_list_response(1, [Tool]),
    Result = maps:get(<<"result">>, Msg),
    [WireTool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"grep">>, maps:get(<<"name">>, WireTool)),
    ?assertEqual(<<"Search files">>, maps:get(<<"description">>, WireTool)),
    ?assertNot(maps:is_key(<<"nextCursor">>, Result)).

tools_list_response_with_pagination_test() ->
    Tool = #{name => <<"t1">>, inputSchema => #{}},
    Msg = beam_agent_mcp_protocol:tools_list_response(1, [Tool], <<"next">>),
    Result = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"next">>, maps:get(<<"nextCursor">>, Result)).

tools_call_request_test() ->
    Msg = beam_agent_mcp_protocol:tools_call_request(
              5, <<"Bash">>, #{<<"command">> => <<"ls">>}),
    ?assertEqual(<<"tools/call">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"Bash">>, maps:get(<<"name">>, Params)),
    ?assertEqual(#{<<"command">> => <<"ls">>},
                 maps:get(<<"arguments">>, Params)).

tools_call_request_with_progress_test() ->
    Msg = beam_agent_mcp_protocol:tools_call_request(
              6, <<"Bash">>, #{}, <<"prog-1">>),
    Params = maps:get(<<"params">>, Msg),
    Meta = maps:get(<<"_meta">>, Params),
    ?assertEqual(<<"prog-1">>, maps:get(<<"progressToken">>, Meta)).

tools_call_response_result_test() ->
    Result = #{content => [#{type => text, text => <<"output">>}]},
    Msg = beam_agent_mcp_protocol:tools_call_response(5, Result),
    WireResult = maps:get(<<"result">>, Msg),
    [Block] = maps:get(<<"content">>, WireResult),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"output">>, maps:get(<<"text">>, Block)),
    ?assertNot(maps:is_key(<<"isError">>, WireResult)).

tools_call_response_error_test() ->
    Content = [#{type => text, text => <<"failed">>}],
    Msg = beam_agent_mcp_protocol:tools_call_response(5, Content, true),
    WireResult = maps:get(<<"result">>, Msg),
    ?assertEqual(true, maps:get(<<"isError">>, WireResult)).

tools_list_changed_notification_test() ->
    Msg = beam_agent_mcp_protocol:tools_list_changed_notification(),
    ?assertEqual(<<"notifications/tools/list_changed">>,
                 maps:get(<<"method">>, Msg)).

%%====================================================================
%% Resource Messages
%%====================================================================

resources_list_request_test() ->
    Msg = beam_agent_mcp_protocol:resources_list_request(1),
    ?assertEqual(<<"resources/list">>, maps:get(<<"method">>, Msg)).

resources_list_response_test() ->
    Res = #{uri => <<"file:///a.txt">>, name => <<"a.txt">>,
            title => <<"File A">>, mimeType => <<"text/plain">>},
    Msg = beam_agent_mcp_protocol:resources_list_response(1, [Res]),
    Result = maps:get(<<"result">>, Msg),
    [WireRes] = maps:get(<<"resources">>, Result),
    ?assertEqual(<<"file:///a.txt">>, maps:get(<<"uri">>, WireRes)),
    ?assertEqual(<<"a.txt">>, maps:get(<<"name">>, WireRes)),
    ?assertEqual(<<"File A">>, maps:get(<<"title">>, WireRes)),
    ?assertEqual(<<"text/plain">>, maps:get(<<"mimeType">>, WireRes)).

resources_list_response_with_pagination_test() ->
    Res = #{uri => <<"u">>, name => <<"n">>},
    Msg = beam_agent_mcp_protocol:resources_list_response(
              1, [Res], <<"page2">>),
    Result = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"page2">>, maps:get(<<"nextCursor">>, Result)).

resources_read_request_test() ->
    Msg = beam_agent_mcp_protocol:resources_read_request(
              2, <<"file:///a.txt">>),
    ?assertEqual(<<"resources/read">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"file:///a.txt">>, maps:get(<<"uri">>, Params)).

resources_read_response_test() ->
    Contents = #{uri => <<"file:///a.txt">>,
                 mimeType => <<"text/plain">>,
                 text => <<"hello">>},
    Msg = beam_agent_mcp_protocol:resources_read_response(2, [Contents]),
    Result = maps:get(<<"result">>, Msg),
    [WireContents] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"file:///a.txt">>, maps:get(<<"uri">>, WireContents)),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, WireContents)).

resources_read_response_blob_test() ->
    Contents = #{uri => <<"file:///img.png">>,
                 mimeType => <<"image/png">>,
                 blob => <<"base64data">>},
    Msg = beam_agent_mcp_protocol:resources_read_response(3, [Contents]),
    [WireContents] = maps:get(<<"contents">>,
                              maps:get(<<"result">>, Msg)),
    ?assertEqual(<<"base64data">>, maps:get(<<"blob">>, WireContents)),
    ?assertNot(maps:is_key(<<"text">>, WireContents)).

resources_templates_list_request_test() ->
    Msg = beam_agent_mcp_protocol:resources_templates_list_request(1),
    ?assertEqual(<<"resources/templates/list">>,
                 maps:get(<<"method">>, Msg)).

resources_templates_list_response_test() ->
    Tpl = #{uriTemplate => <<"file:///{path}">>, name => <<"file">>},
    Msg = beam_agent_mcp_protocol:resources_templates_list_response(
              1, [Tpl]),
    Result = maps:get(<<"result">>, Msg),
    [WireTpl] = maps:get(<<"resourceTemplates">>, Result),
    ?assertEqual(<<"file:///{path}">>,
                 maps:get(<<"uriTemplate">>, WireTpl)).

resources_subscribe_request_test() ->
    Msg = beam_agent_mcp_protocol:resources_subscribe_request(
              1, <<"file:///a">>),
    ?assertEqual(<<"resources/subscribe">>, maps:get(<<"method">>, Msg)),
    ?assertEqual(<<"file:///a">>,
                 maps:get(<<"uri">>, maps:get(<<"params">>, Msg))).

resources_unsubscribe_request_test() ->
    Msg = beam_agent_mcp_protocol:resources_unsubscribe_request(
              1, <<"file:///a">>),
    ?assertEqual(<<"resources/unsubscribe">>, maps:get(<<"method">>, Msg)).

resources_list_changed_notification_test() ->
    Msg = beam_agent_mcp_protocol:resources_list_changed_notification(),
    ?assertEqual(<<"notifications/resources/list_changed">>,
                 maps:get(<<"method">>, Msg)).

resource_updated_notification_test() ->
    Msg = beam_agent_mcp_protocol:resource_updated_notification(
              <<"file:///a">>),
    ?assertEqual(<<"notifications/resources/updated">>,
                 maps:get(<<"method">>, Msg)),
    ?assertEqual(<<"file:///a">>,
                 maps:get(<<"uri">>, maps:get(<<"params">>, Msg))).

%%====================================================================
%% Resource Annotations
%%====================================================================

resource_with_annotations_test() ->
    Res = #{uri => <<"u">>, name => <<"n">>,
            annotations => #{audience => [<<"user">>],
                             priority => 0.8,
                             lastModified => <<"2025-01-01T00:00:00Z">>}},
    Msg = beam_agent_mcp_protocol:resources_list_response(1, [Res]),
    [WireRes] = maps:get(<<"resources">>,
                         maps:get(<<"result">>, Msg)),
    Ann = maps:get(<<"annotations">>, WireRes),
    ?assertEqual([<<"user">>], maps:get(<<"audience">>, Ann)),
    ?assertEqual(0.8, maps:get(<<"priority">>, Ann)),
    ?assertEqual(<<"2025-01-01T00:00:00Z">>,
                 maps:get(<<"lastModified">>, Ann)).

resource_without_annotations_test() ->
    Res = #{uri => <<"u">>, name => <<"n">>},
    Msg = beam_agent_mcp_protocol:resources_list_response(1, [Res]),
    [WireRes] = maps:get(<<"resources">>,
                         maps:get(<<"result">>, Msg)),
    ?assertNot(maps:is_key(<<"annotations">>, WireRes)).

%%====================================================================
%% Prompt Messages
%%====================================================================

prompts_list_request_test() ->
    Msg = beam_agent_mcp_protocol:prompts_list_request(1),
    ?assertEqual(<<"prompts/list">>, maps:get(<<"method">>, Msg)).

prompts_list_response_test() ->
    Prompt = #{name => <<"code_review">>,
               title => <<"Code Review">>,
               description => <<"Reviews code">>,
               arguments => [#{name => <<"code">>, required => true}]},
    Msg = beam_agent_mcp_protocol:prompts_list_response(1, [Prompt]),
    Result = maps:get(<<"result">>, Msg),
    [WirePrompt] = maps:get(<<"prompts">>, Result),
    ?assertEqual(<<"code_review">>, maps:get(<<"name">>, WirePrompt)),
    ?assertEqual(<<"Code Review">>, maps:get(<<"title">>, WirePrompt)),
    [Arg] = maps:get(<<"arguments">>, WirePrompt),
    ?assertEqual(<<"code">>, maps:get(<<"name">>, Arg)),
    ?assertEqual(true, maps:get(<<"required">>, Arg)).

prompts_get_request_no_args_test() ->
    Msg = beam_agent_mcp_protocol:prompts_get_request(2, <<"code_review">>),
    ?assertEqual(<<"prompts/get">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"code_review">>, maps:get(<<"name">>, Params)),
    ?assertNot(maps:is_key(<<"arguments">>, Params)).

prompts_get_request_with_args_test() ->
    Args = #{<<"code">> => <<"def hello(): pass">>},
    Msg = beam_agent_mcp_protocol:prompts_get_request(
              2, <<"code_review">>, Args),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(Args, maps:get(<<"arguments">>, Params)).

prompts_get_response_test() ->
    Messages = [#{role => <<"user">>,
                  content => #{type => text, text => <<"Review this">>}}],
    Msg = beam_agent_mcp_protocol:prompts_get_response(2, Messages),
    Result = maps:get(<<"result">>, Msg),
    [WireMsg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, WireMsg)),
    WireContent = maps:get(<<"content">>, WireMsg),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, WireContent)).

prompts_get_response_with_description_test() ->
    Messages = [#{role => <<"user">>,
                  content => #{type => text, text => <<"hi">>}}],
    Msg = beam_agent_mcp_protocol:prompts_get_response(
              2, Messages, <<"A description">>),
    Result = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"A description">>,
                 maps:get(<<"description">>, Result)).

prompts_list_changed_notification_test() ->
    Msg = beam_agent_mcp_protocol:prompts_list_changed_notification(),
    ?assertEqual(<<"notifications/prompts/list_changed">>,
                 maps:get(<<"method">>, Msg)).

%%====================================================================
%% Completion Messages
%%====================================================================

completion_complete_request_test() ->
    Ref = #{type => <<"ref/prompt">>, name => <<"code_review">>},
    Arg = #{<<"name">> => <<"language">>, <<"value">> => <<"py">>},
    Msg = beam_agent_mcp_protocol:completion_complete_request(1, Ref, Arg),
    ?assertEqual(<<"completion/complete">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(Ref, maps:get(<<"ref">>, Params)),
    ?assertEqual(Arg, maps:get(<<"argument">>, Params)).

completion_complete_request_with_context_test() ->
    Ref = #{type => <<"ref/prompt">>, name => <<"p">>},
    Arg = #{<<"name">> => <<"framework">>, <<"value">> => <<"fla">>},
    Ctx = #{<<"arguments">> => #{<<"language">> => <<"python">>}},
    Msg = beam_agent_mcp_protocol:completion_complete_request(
              1, Ref, Arg, Ctx),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(Ctx, maps:get(<<"context">>, Params)).

completion_complete_response_test() ->
    CompResult = #{values => [<<"python">>, <<"pytorch">>],
                   total => 10, hasMore => true},
    Msg = beam_agent_mcp_protocol:completion_complete_response(1, CompResult),
    Result = maps:get(<<"result">>, Msg),
    Completion = maps:get(<<"completion">>, Result),
    ?assertEqual([<<"python">>, <<"pytorch">>],
                 maps:get(<<"values">>, Completion)),
    ?assertEqual(10, maps:get(<<"total">>, Completion)),
    ?assertEqual(true, maps:get(<<"hasMore">>, Completion)).

%%====================================================================
%% Logging Messages
%%====================================================================

logging_set_level_request_test() ->
    Msg = beam_agent_mcp_protocol:logging_set_level_request(1, info),
    ?assertEqual(<<"logging/setLevel">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Params)).

logging_set_level_response_test() ->
    Msg = beam_agent_mcp_protocol:logging_set_level_response(1),
    ?assertEqual(#{}, maps:get(<<"result">>, Msg)).

logging_message_notification_test() ->
    Msg = beam_agent_mcp_protocol:logging_message_notification(
              error, <<"database">>,
              #{<<"error">> => <<"Connection failed">>}),
    ?assertEqual(<<"notifications/message">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Params)),
    ?assertEqual(<<"database">>, maps:get(<<"logger">>, Params)),
    ?assertEqual(#{<<"error">> => <<"Connection failed">>},
                 maps:get(<<"data">>, Params)).

%%====================================================================
%% Sampling Messages
%%====================================================================

sampling_create_message_request_test() ->
    Params = #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                    <<"content">> =>
                                        #{<<"type">> => <<"text">>,
                                          <<"text">> => <<"Hello">>}}],
               <<"maxTokens">> => 100},
    Msg = beam_agent_mcp_protocol:sampling_create_message_request(1, Params),
    ?assertEqual(<<"sampling/createMessage">>, maps:get(<<"method">>, Msg)).

sampling_create_message_response_test() ->
    Result = #{role => <<"assistant">>,
               content => #{type => text, text => <<"Paris">>},
               model => <<"claude-3-sonnet">>,
               stopReason => <<"endTurn">>},
    Msg = beam_agent_mcp_protocol:sampling_create_message_response(1, Result),
    WireResult = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, WireResult)),
    ?assertEqual(<<"claude-3-sonnet">>, maps:get(<<"model">>, WireResult)),
    ?assertEqual(<<"endTurn">>, maps:get(<<"stopReason">>, WireResult)).

%%====================================================================
%% Elicitation Messages
%%====================================================================

elicitation_create_request_test() ->
    Schema = #{<<"type">> => <<"object">>,
               <<"properties">> => #{<<"name">> =>
                                         #{<<"type">> => <<"string">>}},
               <<"required">> => [<<"name">>]},
    Msg = beam_agent_mcp_protocol:elicitation_create_request(
              1, <<"Enter your name">>, Schema),
    ?assertEqual(<<"elicitation/create">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"Enter your name">>, maps:get(<<"message">>, Params)),
    ?assertEqual(Schema, maps:get(<<"requestedSchema">>, Params)).

elicitation_create_response_accept_test() ->
    Result = #{action => accept, content => #{<<"name">> => <<"Alice">>}},
    Msg = beam_agent_mcp_protocol:elicitation_create_response(1, Result),
    WireResult = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"accept">>, maps:get(<<"action">>, WireResult)),
    ?assertEqual(#{<<"name">> => <<"Alice">>},
                 maps:get(<<"content">>, WireResult)).

elicitation_create_response_decline_test() ->
    Result = #{action => decline},
    Msg = beam_agent_mcp_protocol:elicitation_create_response(1, Result),
    WireResult = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"decline">>, maps:get(<<"action">>, WireResult)),
    ?assertNot(maps:is_key(<<"content">>, WireResult)).

elicitation_create_response_cancel_test() ->
    Result = #{action => cancel},
    Msg = beam_agent_mcp_protocol:elicitation_create_response(1, Result),
    WireResult = maps:get(<<"result">>, Msg),
    ?assertEqual(<<"cancel">>, maps:get(<<"action">>, WireResult)).

%%====================================================================
%% Roots Messages
%%====================================================================

roots_list_request_test() ->
    Msg = beam_agent_mcp_protocol:roots_list_request(1),
    ?assertEqual(<<"roots/list">>, maps:get(<<"method">>, Msg)).

roots_list_response_test() ->
    Roots = [#{uri => <<"file:///home/user/project">>,
               name => <<"project">>},
             #{uri => <<"file:///data">>}],
    Msg = beam_agent_mcp_protocol:roots_list_response(1, Roots),
    Result = maps:get(<<"result">>, Msg),
    WireRoots = maps:get(<<"roots">>, Result),
    ?assertEqual(2, length(WireRoots)),
    [R1, R2] = WireRoots,
    ?assertEqual(<<"file:///home/user/project">>,
                 maps:get(<<"uri">>, R1)),
    ?assertEqual(<<"project">>, maps:get(<<"name">>, R1)),
    ?assertEqual(<<"file:///data">>, maps:get(<<"uri">>, R2)),
    ?assertNot(maps:is_key(<<"name">>, R2)).

roots_list_changed_notification_test() ->
    Msg = beam_agent_mcp_protocol:roots_list_changed_notification(),
    ?assertEqual(<<"notifications/roots/list_changed">>,
                 maps:get(<<"method">>, Msg)).

%%====================================================================
%% Progress & Cancellation
%%====================================================================

progress_notification_basic_test() ->
    Msg = beam_agent_mcp_protocol:progress_notification(<<"tok">>, 50),
    ?assertEqual(<<"notifications/progress">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"tok">>, maps:get(<<"progressToken">>, Params)),
    ?assertEqual(50, maps:get(<<"progress">>, Params)),
    ?assertNot(maps:is_key(<<"total">>, Params)).

progress_notification_with_total_test() ->
    Msg = beam_agent_mcp_protocol:progress_notification(1, 50, 100),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(100, maps:get(<<"total">>, Params)).

progress_notification_with_message_test() ->
    Msg = beam_agent_mcp_protocol:progress_notification(
              1, 50, 100, <<"Processing...">>),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"Processing...">>, maps:get(<<"message">>, Params)).

cancelled_notification_no_reason_test() ->
    Msg = beam_agent_mcp_protocol:cancelled_notification(42),
    ?assertEqual(<<"notifications/cancelled">>, maps:get(<<"method">>, Msg)),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(42, maps:get(<<"requestId">>, Params)),
    ?assertNot(maps:is_key(<<"reason">>, Params)).

cancelled_notification_with_reason_test() ->
    Msg = beam_agent_mcp_protocol:cancelled_notification(
              42, <<"User requested cancellation">>),
    Params = maps:get(<<"params">>, Msg),
    ?assertEqual(<<"User requested cancellation">>,
                 maps:get(<<"reason">>, Params)).

%%====================================================================
%% Content Constructors
%%====================================================================

text_content_test() ->
    C = beam_agent_mcp_protocol:text_content(<<"hello">>),
    ?assertEqual(text, maps:get(type, C)),
    ?assertEqual(<<"hello">>, maps:get(text, C)).

image_content_test() ->
    C = beam_agent_mcp_protocol:image_content(<<"abc">>, <<"image/png">>),
    ?assertEqual(image, maps:get(type, C)),
    ?assertEqual(<<"abc">>, maps:get(data, C)),
    ?assertEqual(<<"image/png">>, maps:get(mimeType, C)).

audio_content_test() ->
    C = beam_agent_mcp_protocol:audio_content(<<"wav">>, <<"audio/wav">>),
    ?assertEqual(audio, maps:get(type, C)),
    ?assertEqual(<<"wav">>, maps:get(data, C)).

resource_content_test() ->
    Res = #{uri => <<"file:///a">>, text => <<"content">>},
    C = beam_agent_mcp_protocol:resource_content(Res),
    ?assertEqual(resource, maps:get(type, C)),
    ?assertEqual(Res, maps:get(resource, C)).

resource_link_content_test() ->
    C = beam_agent_mcp_protocol:resource_link_content(
            <<"file:///a">>, <<"text/plain">>),
    ?assertEqual(resource_link, maps:get(type, C)),
    ?assertEqual(<<"file:///a">>, maps:get(uri, C)).

%%====================================================================
%% Type Constructors
%%====================================================================

implementation_info_test() ->
    I = beam_agent_mcp_protocol:implementation_info(<<"n">>, <<"v">>),
    ?assertEqual(<<"n">>, maps:get(name, I)),
    ?assertEqual(<<"v">>, maps:get(version, I)),
    ?assertNot(maps:is_key(title, I)).

implementation_info_with_title_test() ->
    I = beam_agent_mcp_protocol:implementation_info(<<"n">>, <<"v">>, <<"t">>),
    ?assertEqual(<<"t">>, maps:get(title, I)).

tool_annotation_empty_test() ->
    ?assertEqual(#{}, beam_agent_mcp_protocol:tool_annotation()).

tool_annotation_filters_keys_test() ->
    Ann = beam_agent_mcp_protocol:tool_annotation(
              #{readOnlyHint => true, bogus => 42,
                destructiveHint => false}),
    ?assertEqual(true, maps:get(readOnlyHint, Ann)),
    ?assertEqual(false, maps:get(destructiveHint, Ann)),
    ?assertNot(maps:is_key(bogus, Ann)).

resource_annotation_empty_test() ->
    ?assertEqual(#{}, beam_agent_mcp_protocol:resource_annotation()).

resource_annotation_filters_keys_test() ->
    Ann = beam_agent_mcp_protocol:resource_annotation(
              #{audience => [<<"user">>], priority => 0.5,
                bogus => 42}),
    ?assertEqual([<<"user">>], maps:get(audience, Ann)),
    ?assertEqual(0.5, maps:get(priority, Ann)),
    ?assertNot(maps:is_key(bogus, Ann)).

model_preferences_empty_test() ->
    ?assertEqual(#{}, beam_agent_mcp_protocol:model_preferences()).

model_preferences_filters_keys_test() ->
    P = beam_agent_mcp_protocol:model_preferences(
            #{hints => [#{name => <<"claude">>}],
              costPriority => 0.3,
              extra => true}),
    ?assert(maps:is_key(hints, P)),
    ?assertEqual(0.3, maps:get(costPriority, P)),
    ?assertNot(maps:is_key(extra, P)).

%%====================================================================
%% Capability Negotiation
%%====================================================================

negotiate_capabilities_test() ->
    ServerCaps = #{tools => #{listChanged => true},
                   resources => #{subscribe => true, listChanged => true}},
    ClientCaps = #{roots => #{listChanged => true},
                   sampling => #{}},
    Session = beam_agent_mcp_protocol:negotiate_capabilities(
                  ServerCaps, ClientCaps),
    ?assertEqual(ServerCaps, maps:get(server, Session)),
    ?assertEqual(ClientCaps, maps:get(client, Session)),
    ?assertEqual(<<"2025-06-18">>, maps:get(protocol_version, Session)).

default_server_capabilities_test() ->
    Caps = beam_agent_mcp_protocol:default_server_capabilities(),
    ?assert(maps:is_key(tools, Caps)),
    ?assertEqual(true, maps:get(listChanged, maps:get(tools, Caps))).

default_client_capabilities_test() ->
    Caps = beam_agent_mcp_protocol:default_client_capabilities(),
    ?assert(maps:is_key(roots, Caps)).

capability_supported_server_side_test() ->
    Session = beam_agent_mcp_protocol:negotiate_capabilities(
                  #{tools => #{}, resources => #{}, logging => #{}},
                  #{roots => #{}}),
    ?assert(beam_agent_mcp_protocol:capability_supported(tools, Session)),
    ?assert(beam_agent_mcp_protocol:capability_supported(resources, Session)),
    ?assert(beam_agent_mcp_protocol:capability_supported(logging, Session)),
    ?assertNot(beam_agent_mcp_protocol:capability_supported(
                   prompts, Session)),
    ?assertNot(beam_agent_mcp_protocol:capability_supported(
                   completions, Session)).

capability_supported_client_side_test() ->
    Session = beam_agent_mcp_protocol:negotiate_capabilities(
                  #{tools => #{}},
                  #{roots => #{}, sampling => #{}, elicitation => #{}}),
    ?assert(beam_agent_mcp_protocol:capability_supported(roots, Session)),
    ?assert(beam_agent_mcp_protocol:capability_supported(sampling, Session)),
    ?assert(beam_agent_mcp_protocol:capability_supported(
                elicitation, Session)).

capability_supported_unknown_family_test() ->
    Session = beam_agent_mcp_protocol:negotiate_capabilities(#{}, #{}),
    ?assertNot(beam_agent_mcp_protocol:capability_supported(
                   unknown_family, Session)).

%%====================================================================
%% Validation — Messages
%%====================================================================

validate_request_test() ->
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"tools/list">>,
            <<"params">> => #{<<"cursor">> => <<"abc">>}},
    ?assertMatch({request, 1, <<"tools/list">>, #{<<"cursor">> := <<"abc">>}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_request_no_params_test() ->
    Msg = #{<<"id">> => 2, <<"method">> => <<"ping">>},
    ?assertMatch({request, 2, <<"ping">>, #{}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_notification_test() ->
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/initialized">>},
    ?assertMatch({notification, <<"notifications/initialized">>, #{}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_notification_with_params_test() ->
    Msg = #{<<"method">> => <<"notifications/progress">>,
            <<"params">> => #{<<"progress">> => 50}},
    ?assertMatch({notification, <<"notifications/progress">>,
                  #{<<"progress">> := 50}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_response_test() ->
    Msg = #{<<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"result">> => #{<<"tools">> => []}},
    ?assertMatch({response, 1, #{<<"tools">> := []}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_error_response_test() ->
    Msg = #{<<"id">> => 1,
            <<"error">> => #{<<"code">> => -32601,
                             <<"message">> => <<"Method not found">>}},
    ?assertMatch({error_response, 1, -32601,
                  <<"Method not found">>, undefined},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_error_response_with_data_test() ->
    Msg = #{<<"id">> => 1,
            <<"error">> => #{<<"code">> => -32602,
                             <<"message">> => <<"Invalid">>,
                             <<"data">> => <<"details">>}},
    ?assertMatch({error_response, 1, -32602, <<"Invalid">>, <<"details">>},
                 beam_agent_mcp_protocol:validate_message(Msg)).

validate_invalid_non_map_test() ->
    ?assertMatch({invalid, {not_a_map, _}},
                 beam_agent_mcp_protocol:validate_message(42)).

validate_invalid_unrecognized_test() ->
    ?assertMatch({invalid, {unrecognized_message, _}},
                 beam_agent_mcp_protocol:validate_message(
                     #{<<"something">> => <<"else">>})).

validate_invalid_bad_params_test() ->
    Msg = #{<<"method">> => <<"test">>, <<"id">> => 1,
            <<"params">> => <<"not a map">>},
    ?assertMatch({invalid, {bad_params, _}},
                 beam_agent_mcp_protocol:validate_message(Msg)).

%%====================================================================
%% Validation — Types
%%====================================================================

validate_tool_valid_test() ->
    ?assertEqual(ok, beam_agent_mcp_protocol:validate_tool(
                         #{name => <<"t">>, inputSchema => #{}})).

validate_tool_missing_schema_test() ->
    ?assertMatch({error, {missing_field, inputSchema}},
                 beam_agent_mcp_protocol:validate_tool(
                     #{name => <<"t">>})).

validate_tool_missing_name_test() ->
    ?assertMatch({error, {missing_field, name}},
                 beam_agent_mcp_protocol:validate_tool(
                     #{inputSchema => #{}})).

validate_tool_missing_both_test() ->
    ?assertMatch({error, {missing_fields, _}},
                 beam_agent_mcp_protocol:validate_tool(#{})).

validate_resource_valid_test() ->
    ?assertEqual(ok, beam_agent_mcp_protocol:validate_resource(
                         #{uri => <<"u">>, name => <<"n">>})).

validate_resource_missing_name_test() ->
    ?assertMatch({error, {missing_field, name}},
                 beam_agent_mcp_protocol:validate_resource(
                     #{uri => <<"u">>})).

validate_resource_missing_uri_test() ->
    ?assertMatch({error, {missing_field, uri}},
                 beam_agent_mcp_protocol:validate_resource(
                     #{name => <<"n">>})).

validate_prompt_valid_test() ->
    ?assertEqual(ok, beam_agent_mcp_protocol:validate_prompt(
                         #{name => <<"p">>})).

validate_prompt_missing_name_test() ->
    ?assertMatch({error, {missing_field, name}},
                 beam_agent_mcp_protocol:validate_prompt(#{})).

%%====================================================================
%% Error Codes
%%====================================================================

error_codes_test() ->
    ?assertEqual(-32700, beam_agent_mcp_protocol:error_parse()),
    ?assertEqual(-32600, beam_agent_mcp_protocol:error_invalid_request()),
    ?assertEqual(-32601, beam_agent_mcp_protocol:error_method_not_found()),
    ?assertEqual(-32602, beam_agent_mcp_protocol:error_invalid_params()),
    ?assertEqual(-32603, beam_agent_mcp_protocol:error_internal()),
    ?assertEqual(-32002, beam_agent_mcp_protocol:error_resource_not_found()).

%%====================================================================
%% Wire Encoding — Optional Fields Omitted
%%====================================================================

tool_encoding_minimal_test() ->
    Tool = #{name => <<"t">>, inputSchema => #{}},
    Msg = beam_agent_mcp_protocol:tools_list_response(1, [Tool]),
    [WireTool] = maps:get(<<"tools">>, maps:get(<<"result">>, Msg)),
    ?assertEqual(<<"t">>, maps:get(<<"name">>, WireTool)),
    ?assertNot(maps:is_key(<<"title">>, WireTool)),
    ?assertNot(maps:is_key(<<"description">>, WireTool)),
    ?assertNot(maps:is_key(<<"outputSchema">>, WireTool)),
    ?assertNot(maps:is_key(<<"annotations">>, WireTool)).

tool_encoding_full_test() ->
    Tool = #{name => <<"t">>, inputSchema => #{},
             title => <<"Tool T">>,
             description => <<"Desc">>,
             outputSchema => #{<<"type">> => <<"string">>},
             annotations => #{readOnlyHint => true}},
    Msg = beam_agent_mcp_protocol:tools_list_response(1, [Tool]),
    [WireTool] = maps:get(<<"tools">>, maps:get(<<"result">>, Msg)),
    ?assertEqual(<<"Tool T">>, maps:get(<<"title">>, WireTool)),
    ?assertEqual(<<"Desc">>, maps:get(<<"description">>, WireTool)),
    ?assert(maps:is_key(<<"outputSchema">>, WireTool)),
    Ann = maps:get(<<"annotations">>, WireTool),
    ?assertEqual(true, maps:get(<<"readOnlyHint">>, Ann)).

prompt_encoding_minimal_test() ->
    Prompt = #{name => <<"p">>},
    Msg = beam_agent_mcp_protocol:prompts_list_response(1, [Prompt]),
    [WirePrompt] = maps:get(<<"prompts">>, maps:get(<<"result">>, Msg)),
    ?assertEqual(<<"p">>, maps:get(<<"name">>, WirePrompt)),
    ?assertNot(maps:is_key(<<"title">>, WirePrompt)),
    ?assertNot(maps:is_key(<<"description">>, WirePrompt)),
    ?assertNot(maps:is_key(<<"arguments">>, WirePrompt)).

%% All messages include jsonrpc field
all_constructors_include_jsonrpc_test() ->
    Messages = [
        beam_agent_mcp_protocol:request(1, <<"m">>, #{}),
        beam_agent_mcp_protocol:response(1, #{}),
        beam_agent_mcp_protocol:error_response(1, -1, <<"e">>),
        beam_agent_mcp_protocol:notification(<<"n">>),
        beam_agent_mcp_protocol:notification(<<"n">>, #{}),
        beam_agent_mcp_protocol:ping_request(1),
        beam_agent_mcp_protocol:ping_response(1),
        beam_agent_mcp_protocol:initialized_notification(),
        beam_agent_mcp_protocol:tools_list_changed_notification(),
        beam_agent_mcp_protocol:resources_list_changed_notification(),
        beam_agent_mcp_protocol:prompts_list_changed_notification(),
        beam_agent_mcp_protocol:roots_list_changed_notification(),
        beam_agent_mcp_protocol:cancelled_notification(1),
        beam_agent_mcp_protocol:progress_notification(1, 50)
    ],
    lists:foreach(fun(Msg) ->
        ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Msg))
    end, Messages).

%% Content with annotations encodes correctly
content_with_annotations_encoding_test() ->
    Content = #{type => text, text => <<"hi">>,
                annotations => #{audience => [<<"user">>],
                                 priority => 1.0}},
    Result = #{content => [Content]},
    Msg = beam_agent_mcp_protocol:tools_call_response(1, Result),
    WireResult = maps:get(<<"result">>, Msg),
    [WireContent] = maps:get(<<"content">>, WireResult),
    Ann = maps:get(<<"annotations">>, WireContent),
    ?assertEqual([<<"user">>], maps:get(<<"audience">>, Ann)),
    ?assertEqual(1.0, maps:get(<<"priority">>, Ann)).
