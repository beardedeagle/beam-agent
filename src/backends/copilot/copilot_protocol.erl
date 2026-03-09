-module(copilot_protocol).
-export([normalize_event/1,
         build_session_create_params/1,
         build_session_resume_params/2,
         build_session_send_params/3,
         build_tool_result/2,
         build_permission_result/1,
         build_hook_result/1,
         build_user_input_result/1,
         encode_request/3,
         encode_response/2,
         encode_error_response/3,
         encode_error_response/4,
         build_cli_args/1,
         build_env/1,
         sdk_protocol_version/0]).
-dialyzer({nowarn_function, [{normalize_event, 1}]}).
-dialyzer({no_underspecs,
           [{build_session_create_params, 1},
            {build_session_resume_params, 2},
            {build_session_send_params, 3},
            {build_tool_result, 2},
            {build_permission_result, 1},
            {build_hook_result, 1},
            {build_user_input_result, 1},
            {build_system_message_config, 1},
            {build_provider_config, 1},
            {build_mcp_servers_config, 1},
            {build_custom_agents_config, 1},
            {build_infinite_sessions_config, 1},
            {maybe_put, 3},
            {maybe_put_list, 3},
            {maybe_put_opt, 4},
            {build_cli_args, 1},
            {build_env, 1}]}).
-spec normalize_event(map()) -> beam_agent_core:message().
normalize_event(#{<<"type">> := <<"assistant.message">>,
                  <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    Base = #{type => assistant, content => Content},
    maybe_add_message_fields(Base, Data);
normalize_event(#{<<"type">> := <<"assistant.message_delta">>,
                  <<"data">> := Data}) ->
    DeltaContent =
        maps:get(<<"deltaContent">>,
                 Data,
                 maps:get(<<"delta_content">>, Data, <<>>)),
    #{type => text, content => DeltaContent};
normalize_event(#{<<"type">> := <<"assistant.reasoning">>,
                  <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    #{type => thinking, content => Content};
normalize_event(#{<<"type">> := <<"assistant.reasoning_delta">>,
                  <<"data">> := Data}) ->
    DeltaContent =
        maps:get(<<"deltaContent">>,
                 Data,
                 maps:get(<<"delta_content">>, Data, <<>>)),
    #{type => thinking, content => DeltaContent};
normalize_event(#{<<"type">> := <<"tool.executing">>,
                  <<"data">> := Data}) ->
    ToolName =
        maps:get(<<"toolName">>,
                 Data,
                 maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ToolInput =
        maps:get(<<"arguments">>,
                 Data,
                 maps:get(<<"toolInput">>, Data, #{})),
    Base =
        #{type => tool_use,
          tool_name => ToolName,
          tool_input => ToolInput},
    maybe_add_tool_id(Base, Data);
normalize_event(#{<<"type">> := <<"tool.completed">>,
                  <<"data">> := Data}) ->
    ToolName =
        maps:get(<<"toolName">>,
                 Data,
                 maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    Content =
        maps:get(<<"output">>,
                 Data,
                 maps:get(<<"content">>, Data, <<>>)),
    Base =
        #{type => tool_result,
          tool_name => ToolName,
          content => Content},
    maybe_add_tool_id(Base, Data);
normalize_event(#{<<"type">> := <<"tool.errored">>, <<"data">> := Data}) ->
    ToolName =
        maps:get(<<"toolName">>,
                 Data,
                 maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ErrorMsg =
        maps:get(<<"error">>,
                 Data,
                 maps:get(<<"message">>, Data, <<"tool error">>)),
    Base =
        #{type => error,
          content => ErrorMsg,
          error_type => tool_error,
          tool_name => ToolName},
    maybe_add_tool_id(Base, Data);
normalize_event(#{<<"type">> := <<"agent.toolCall">>,
                  <<"data">> := Data}) ->
    ToolName =
        maps:get(<<"toolName">>,
                 Data,
                 maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ToolInput =
        maps:get(<<"arguments">>,
                 Data,
                 maps:get(<<"toolInput">>, Data, #{})),
    Base =
        #{type => tool_use,
          tool_name => ToolName,
          tool_input => ToolInput},
    maybe_add_tool_id(Base, Data);
normalize_event(#{<<"type">> := <<"session.idle">>} = Event) ->
    Data = maps:get(<<"data">>, Event, #{}),
    Base = #{type => result},
    maybe_add_usage(Base, Data);
normalize_event(#{<<"type">> := <<"session.error">>, <<"data">> := Data}) ->
    Message =
        maps:get(<<"message">>,
                 Data,
                 maps:get(<<"error">>, Data, <<"session error">>)),
    #{type => error, content => Message, error_type => session_error};
normalize_event(#{<<"type">> := <<"session.resume">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => resume, content => Data};
normalize_event(#{<<"type">> := <<"permission.request">>,
                  <<"data">> := Data}) ->
    Kind = maps:get(<<"kind">>, Data, <<"unknown">>),
    #{type => control_request,
      content => Data,
      subtype => permission_request,
      permission_kind => Kind};
normalize_event(#{<<"type">> := <<"permission.resolved">>,
                  <<"data">> := Data}) ->
    #{type => control_response,
      content => Data,
      subtype => permission_resolved};
normalize_event(#{<<"type">> := <<"compaction.started">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => compaction_started, content => Data};
normalize_event(#{<<"type">> := <<"compaction.completed">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => compaction_completed, content => Data};
normalize_event(#{<<"type">> := <<"plan.update">>, <<"data">> := Data}) ->
    #{type => system, subtype => plan_update, content => Data};
normalize_event(#{<<"type">> := <<"user.message">>, <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    #{type => user, content => Content};
normalize_event(#{<<"type">> := Type} = Event) ->
    Data = maps:get(<<"data">>, Event, #{}),
    #{type => raw, content => Data, subtype => Type};
normalize_event(Event) when is_map(Event) ->
    #{type => raw, content => Event}.
-spec build_session_create_params(map()) -> map().
build_session_create_params(Opts) ->
    Params = #{},
    P1 =
        maybe_put(<<"sessionId">>,
                  maps:get(session_id, Opts, undefined),
                  Params),
    P2 = maybe_put(<<"model">>, maps:get(model, Opts, undefined), P1),
    P3 =
        maybe_put(<<"reasoningEffort">>,
                  maps:get(reasoning_effort, Opts, undefined),
                  P2),
    P4 =
        maybe_put(<<"workingDirectory">>,
                  maps:get(work_dir, Opts,
                           maps:get(working_directory, Opts, undefined)),
                  P3),
    P5 =
        maybe_put(<<"clientName">>,
                  maps:get(client_name, Opts, undefined),
                  P4),
    P6 =
        maybe_put(<<"streaming">>,
                  maps:get(streaming, Opts, undefined),
                  P5),
    P7 =
        maybe_put(<<"configDir">>,
                  maps:get(config_dir, Opts, undefined),
                  P6),
    P8 =
        maybe_put_list(<<"availableTools">>,
                       maps:get(available_tools, Opts, undefined),
                       P7),
    P9 =
        maybe_put_list(<<"excludedTools">>,
                       maps:get(excluded_tools, Opts, undefined),
                       P8),
    P10 =
        maybe_put_list(<<"skillDirectories">>,
                       maps:get(skill_directories, Opts, undefined),
                       P9),
    P11 =
        maybe_put_list(<<"disabledSkills">>,
                       maps:get(disabled_skills, Opts, undefined),
                       P10),
    P12 =
        maybe_put_opt(<<"systemMessage">>,
                      maps:get(system_message, Opts, undefined),
                      fun build_system_message_config/1,
                      P11),
    P13 =
        maybe_put_opt(<<"provider">>,
                      maps:get(provider, Opts, undefined),
                      fun build_provider_config/1,
                      P12),
    P14 =
        maybe_put_opt(<<"mcpServers">>,
                      maps:get(mcp_servers, Opts, undefined),
                      fun build_mcp_servers_config/1,
                      P13),
    P15 =
        maybe_put_opt(<<"customAgents">>,
                      maps:get(custom_agents, Opts, undefined),
                      fun build_custom_agents_config/1,
                      P14),
    P16 =
        maybe_put_opt(<<"infiniteSessions">>,
                      maps:get(infinite_sessions, Opts, undefined),
                      fun build_infinite_sessions_config/1,
                      P15),
    P17 =
        maybe_put(<<"outputFormat">>,
                  maps:get(output_format, Opts, undefined),
                  P16),
    maybe_put_opt(<<"tools">>,
                  maps:get(sdk_tools, Opts, undefined),
                  fun build_tool_definitions/1,
                  P17).
-spec build_session_resume_params(binary(), map()) -> map().
build_session_resume_params(SessionId, Opts) ->
    Base = build_session_create_params(Opts),
    P1 = Base#{<<"sessionId">> => SessionId},
    maybe_put(<<"disableResume">>,
              maps:get(disable_resume, Opts, undefined),
              P1).
-spec build_session_send_params(binary(), binary(), map()) -> map().
build_session_send_params(SessionId, Prompt, Params) ->
    Base = #{<<"sessionId">> => SessionId, <<"prompt">> => Prompt},
    P1 =
        maybe_put_list(<<"attachments">>,
                       maps:get(attachments, Params, undefined),
                       Base),
    P2 = maybe_put(<<"mode">>, maps:get(mode, Params, undefined), P1),
    maybe_put(<<"outputFormat">>,
              maps:get(output_format, Params, undefined),
              P2).
-spec build_tool_result(map(), map()) -> map().
build_tool_result(Result, _Context) ->
    Base = #{},
    P1 =
        maybe_put(<<"textResultForLlm">>,
                  maps:get(text_result, Result,
                           maps:get(<<"textResultForLlm">>,
                                    Result, undefined)),
                  Base),
    P2 =
        maybe_put(<<"resultType">>,
                  maps:get(result_type, Result,
                           maps:get(<<"resultType">>,
                                    Result,
                                    <<"success">>)),
                  P1),
    P3 =
        maybe_put(<<"error">>,
                  maps:get(error, Result,
                           maps:get(<<"error">>, Result, undefined)),
                  P2),
    maybe_put(<<"sessionLog">>,
              maps:get(session_log, Result,
                       maps:get(<<"sessionLog">>, Result, undefined)),
              P3).
-spec build_permission_result(beam_agent_core:permission_result() | map()) ->
                                 map().
build_permission_result({allow, _}) ->
    #{<<"result">> => #{<<"kind">> => <<"approved">>}};
build_permission_result({allow, _, _}) ->
    #{<<"result">> => #{<<"kind">> => <<"approved">>}};
build_permission_result({deny, _Reason}) ->
    #{<<"result">> =>
          #{<<"kind">> => <<"denied-interactively-by-user">>}};
build_permission_result(#{<<"kind">> := _} = Result) ->
    #{<<"result">> => Result};
build_permission_result(_) ->
    #{<<"result">> =>
          #{<<"kind">> =>
                <<"denied-no-approval-rule-and-could-not-request-from-u"
                  "ser">>}}.
-spec build_hook_result(term()) -> map().
build_hook_result(undefined) ->
    #{};
build_hook_result(Result) when is_map(Result) ->
    Result;
build_hook_result(_) ->
    #{}.
-spec build_user_input_result(map()) -> map().
build_user_input_result(#{answer := Answer} = Result) ->
    WasFreeform =
        maps:get(was_freeform, Result,
                 maps:get(wasFreeform, Result, false)),
    #{<<"answer">> => ensure_binary(Answer),
      <<"wasFreeform">> => WasFreeform};
build_user_input_result(#{<<"answer">> := _} = Result) ->
    Result;
build_user_input_result(_) ->
    #{<<"answer">> => <<>>, <<"wasFreeform">> => true}.
-spec encode_request(binary(), binary(), map() | undefined) -> map().
encode_request(Id, Method, undefined) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"method">> => Method,
      <<"params">> => #{}};
encode_request(Id, Method, Params) when is_map(Params) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"method">> => Method,
      <<"params">> => Params}.
-spec encode_response(binary() | integer(), term()) -> map().
encode_response(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"result">> => Result}.
-spec encode_error_response(binary() | integer(), integer(), binary()) ->
                               map().
encode_error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}}.
-spec encode_error_response(binary() | integer(),
                            integer(),
                            binary(),
                            term()) ->
                               map().
encode_error_response(Id, Code, Message, Data) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">> => Id,
      <<"error">> =>
          #{<<"code">> => Code,
            <<"message">> => Message,
            <<"data">> => Data}}.
-spec build_cli_args(map()) -> [string()].
build_cli_args(Opts) ->
    Base = ["server", "--stdio"],
    WithLogLevel =
        case maps:get(log_level, Opts, undefined) of
            undefined ->
                Base;
            Level when is_binary(Level) ->
                Base ++ ["--log-level", binary_to_list(Level)];
            Level when is_atom(Level) ->
                Base ++ ["--log-level", atom_to_list(Level)];
            Level when is_list(Level) ->
                Base ++ ["--log-level", Level]
        end,
    WithProtocol =
        WithLogLevel ++ ["--sdk-protocol-version", integer_to_list(3)],
    case maps:get(cli_args, Opts, undefined) of
        undefined ->
            WithProtocol;
        UserArgs when is_list(UserArgs) ->
            ["server" | UserExtra] = WithProtocol,
            ExtraStrings =
                [ 
                 ensure_list(A) ||
                     A <- UserArgs
                ],
            ["server" | ExtraStrings ++ UserExtra]
    end.
-spec build_env(map()) -> [{string(), string()}].
build_env(Opts) ->
    BaseEnv =
        [{"COPILOT_SDK_VERSION", "beam-" ++ "0.1.0"}, {"NO_COLOR", "1"}],
    TokenEnv =
        case maps:get(github_token, Opts, undefined) of
            undefined ->
                [];
            Token when is_binary(Token) ->
                [{"GITHUB_TOKEN", binary_to_list(Token)}];
            Token when is_list(Token) ->
                [{"GITHUB_TOKEN", Token}]
        end,
    UserEnv =
        case maps:get(env, Opts, undefined) of
            undefined ->
                [];
            Env when is_list(Env) ->
                [ 
                 {ensure_list(K), ensure_list(V)} ||
                     {K, V} <- Env
                ];
            Env when is_map(Env) ->
                [ 
                 {ensure_list(K), ensure_list(V)} ||
                     {K, V} <- maps:to_list(Env)
                ]
        end,
    BaseEnv ++ TokenEnv ++ UserEnv.
-spec sdk_protocol_version() -> 3.
sdk_protocol_version() ->
    3.
-spec maybe_add_message_fields(map(), map()) -> map().
maybe_add_message_fields(Base, Data) ->
    Fields =
        [{message_id, <<"messageId">>},
         {model, <<"model">>},
         {role, <<"role">>}],
    lists:foldl(fun({Key, WireKey}, Acc) ->
                       case maps:get(WireKey, Data, undefined) of
                           undefined ->
                               Acc;
                           Val ->
                               Acc#{Key => Val}
                       end
                end,
                Base, Fields).
-spec maybe_add_tool_id(beam_agent_core:message(), map()) ->
                           beam_agent_core:message().
maybe_add_tool_id(Base, Data) ->
    case
        maps:get(<<"toolCallId">>,
                 Data,
                 maps:get(<<"tool_call_id">>, Data, undefined))
    of
        undefined ->
            Base;
        ToolId ->
            Base#{tool_use_id => ToolId}
    end.
-spec maybe_add_usage(beam_agent_core:message(), map()) ->
                         beam_agent_core:message().
maybe_add_usage(Base, Data) ->
    case maps:get(<<"usage">>, Data, undefined) of
        undefined ->
            Base;
        Usage when is_map(Usage) ->
            Base#{usage => Usage}
    end.
-spec maybe_put(binary(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.
-spec maybe_put_list(binary(), term(), map()) -> map().
maybe_put_list(_Key, undefined, Map) ->
    Map;
maybe_put_list(_Key, [], Map) ->
    Map;
maybe_put_list(Key, List, Map) when is_list(List) ->
    Map#{Key => List}.
-spec maybe_put_opt(binary(), term(), fun((term()) -> term()), map()) ->
                       map().
maybe_put_opt(_Key, undefined, _Fun, Map) ->
    Map;
maybe_put_opt(Key, Value, Fun, Map) ->
    Map#{Key => Fun(Value)}.
-spec build_system_message_config(map() | binary()) -> map().
build_system_message_config(Config) when is_binary(Config) ->
    #{<<"mode">> => <<"append">>, <<"content">> => Config};
build_system_message_config(#{mode := <<"replace">>, content := Content}) ->
    #{<<"mode">> => <<"replace">>, <<"content">> => Content};
build_system_message_config(#{mode := replace, content := Content}) ->
    #{<<"mode">> => <<"replace">>, <<"content">> => Content};
build_system_message_config(#{content := Content}) ->
    #{<<"mode">> => <<"append">>, <<"content">> => Content};
build_system_message_config(Config) when is_map(Config) ->
    Config.
-spec build_provider_config(map()) -> map().
build_provider_config(Config) when is_map(Config) ->
    Mapping =
        [{type, <<"type">>},
         {wire_api, <<"wireApi">>},
         {base_url, <<"baseUrl">>},
         {api_key, <<"apiKey">>},
         {bearer_token, <<"bearerToken">>}],
    maps:fold(fun(K, V, Acc) ->
                     case lists:keyfind(K, 1, Mapping) of
                         {K, WireKey} ->
                             Acc#{WireKey => ensure_binary(V)};
                         false ->
                             Acc
                     end
              end,
              #{},
              Config).
-spec build_mcp_servers_config(map()) -> map().
build_mcp_servers_config(Config) when is_map(Config) ->
    Config.
-spec build_custom_agents_config(list()) -> list().
build_custom_agents_config(Agents) when is_list(Agents) ->
    Agents.
-spec build_infinite_sessions_config(map()) -> map().
build_infinite_sessions_config(Config) when is_map(Config) ->
    Config.
-spec build_tool_definitions([map()]) -> [map()].
build_tool_definitions(Tools) when is_list(Tools) ->
    [ 
     build_tool_def(T) ||
         T <- Tools
    ].
-spec build_tool_def(map()) -> map().
build_tool_def(#{name := Name, description := Desc} = Tool) ->
    Base =
        #{<<"name">> => ensure_binary(Name),
          <<"description">> => ensure_binary(Desc)},
    case maps:get(parameters, Tool, undefined) of
        undefined ->
            Base;
        Schema ->
            Base#{<<"parameters">> => Schema}
    end;
build_tool_def(#{name := Name} = Tool) ->
    Base = #{<<"name">> => ensure_binary(Name)},
    P1 =
        maybe_put(<<"description">>,
                  maps:get(description, Tool, undefined),
                  Base),
    case maps:get(parameters, Tool, undefined) of
        undefined ->
            P1;
        Schema ->
            P1#{<<"parameters">> => Schema}
    end;
build_tool_def(Tool) when is_map(Tool) ->
    maps:without([handler], Tool).
-spec ensure_binary(term()) -> binary().
ensure_binary(V) when is_binary(V) ->
    V;
ensure_binary(V) when is_list(V) ->
    list_to_binary(V);
ensure_binary(V) when is_atom(V) ->
    atom_to_binary(V);
ensure_binary(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).
-spec ensure_list(term()) -> string().
ensure_list(V) when is_list(V) ->
    V;
ensure_list(V) when is_binary(V) ->
    binary_to_list(V);
ensure_list(V) when is_atom(V) ->
    atom_to_list(V);
ensure_list(V) ->
    lists:flatten(io_lib:format("~p", [V])).
