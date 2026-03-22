-module(copilot_protocol).
-moduledoc false.
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
         sdk_protocol_version/0,
         %% COP-7: Session-scoped RPC param builders
         build_model_get_current_params/1,
         build_mode_get_params/1,
         build_mode_set_params/2,
         build_plan_read_params/1,
         build_plan_update_params/2,
         build_plan_delete_params/1,
         build_get_foreground_params/1,
         build_set_foreground_params/2,
         build_log_params/3,
         build_workspace_list_files_params/1,
         build_workspace_read_file_params/2,
         build_workspace_create_file_params/3,
         build_agent_list_params/1,
         build_agent_get_current_params/1,
         build_agent_select_params/2,
         build_agent_deselect_params/1,
         build_agent_reload_params/1,
         build_skills_list_params/1,
         build_skills_enable_params/2,
         build_skills_disable_params/2,
         build_skills_reload_params/1,
         build_mcp_list_params/1,
         build_mcp_enable_params/2,
         build_mcp_disable_params/2,
         build_mcp_reload_params/1,
         build_fleet_start_params/2,
         build_plugins_list_params/1,
         build_compaction_compact_params/1,
         build_shell_exec_params/2,
         build_shell_kill_params/2,
         build_elicitation_params/2,
         build_tools_list_params/1,
         build_account_get_quota_params/0,
         build_extension_call_params/4]).
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
            {build_env, 1},
            {build_model_get_current_params, 1},
            {build_mode_get_params, 1},
            {build_mode_set_params, 2},
            {build_plan_read_params, 1},
            {build_plan_update_params, 2},
            {build_plan_delete_params, 1},
            {build_get_foreground_params, 1},
            {build_set_foreground_params, 2},
            {build_log_params, 3},
            {build_workspace_list_files_params, 1},
            {build_workspace_read_file_params, 2},
            {build_workspace_create_file_params, 3},
            {build_agent_list_params, 1},
            {build_agent_get_current_params, 1},
            {build_agent_select_params, 2},
            {build_agent_deselect_params, 1},
            {build_agent_reload_params, 1},
            {build_skills_list_params, 1},
            {build_skills_enable_params, 2},
            {build_skills_disable_params, 2},
            {build_skills_reload_params, 1},
            {build_mcp_list_params, 1},
            {build_mcp_enable_params, 2},
            {build_mcp_disable_params, 2},
            {build_mcp_reload_params, 1},
            {build_fleet_start_params, 2},
            {build_plugins_list_params, 1},
            {build_compaction_compact_params, 1},
            {build_shell_exec_params, 2},
            {build_shell_kill_params, 2},
            {build_elicitation_params, 2},
            {build_tools_list_params, 1},
            {build_account_get_quota_params, 0},
            {build_extension_call_params, 4}]}).
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
normalize_event(#{<<"type">> := ToolExec,
                  <<"data">> := Data})
  when ToolExec =:= <<"tool.execution_start">>;
       ToolExec =:= <<"tool.executing">> ->
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
normalize_event(#{<<"type">> := ToolComplete,
                  <<"data">> := Data})
  when ToolComplete =:= <<"tool.execution_complete">>;
       ToolComplete =:= <<"tool.completed">> ->
    ToolName =
        maps:get(<<"toolName">>,
                 Data,
                 maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    Content =
        maps:get(<<"output">>,
                 Data,
                 maps:get(<<"content">>, Data, <<>>)),
    IsError = maps:get(<<"isError">>, Data, false),
    Base = case IsError of
        true ->
            #{type => error,
              content => Content,
              error_type => tool_error,
              tool_name => ToolName};
        _ ->
            #{type => tool_result,
              tool_name => ToolName,
              content => Content}
    end,
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
normalize_event(#{<<"type">> := <<"external_tool.requested">>,
                  <<"data">> := Data}) ->
    #{type => tool_use,
      tool_name => maps:get(<<"toolName">>, Data,
                            maps:get(<<"tool_name">>, Data, <<>>)),
      tool_input => maps:get(<<"input">>, Data, #{}),
      request_id => maps:get(<<"requestId">>, Data,
                             maps:get(<<"request_id">>, Data, undefined)),
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"external_tool.completed">>,
                  <<"data">> := Data}) ->
    #{type => tool_result,
      tool_name => maps:get(<<"toolName">>, Data,
                            maps:get(<<"tool_name">>, Data, <<>>)),
      content => maps:get(<<"output">>, Data, <<>>),
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"permission.requested">>,
                  <<"data">> := Data}) ->
    #{type => control_request,
      subtype => <<"permission">>,
      request_id => maps:get(<<"requestId">>, Data,
                             maps:get(<<"request_id">>, Data, undefined)),
      request => maps:get(<<"request">>, Data, #{}),
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"permission.completed">>,
                  <<"data">> := Data}) ->
    #{type => system,
      subtype => <<"permission_completed">>,
      content => maps:get(<<"result">>, Data, <<>>),
      timestamp => erlang:system_time(millisecond)};
normalize_event(#{<<"type">> := <<"permission.request">>,
                  <<"data">> := Data}) ->
    Kind = maps:get(<<"kind">>, Data, <<"unknown">>),
    #{type => control_request,
      content => Data,
      subtype => permission_request,
      permission_kind => Kind};
normalize_event(#{<<"type">> := PermDone,
                  <<"data">> := Data})
  when PermDone =:= <<"permission.completed">>;
       PermDone =:= <<"permission.resolved">> ->
    #{type => control_response,
      content => Data,
      subtype => permission_completed};
normalize_event(#{<<"type">> := CompactStart,
                  <<"data">> := Data})
  when CompactStart =:= <<"session.compaction_start">>;
       CompactStart =:= <<"compaction.started">> ->
    #{type => system, subtype => compaction_start, content => Data};
normalize_event(#{<<"type">> := CompactDone,
                  <<"data">> := Data})
  when CompactDone =:= <<"session.compaction_complete">>;
       CompactDone =:= <<"compaction.completed">> ->
    #{type => system, subtype => compaction_complete, content => Data};
normalize_event(#{<<"type">> := PlanChange, <<"data">> := Data})
  when PlanChange =:= <<"session.plan_changed">>;
       PlanChange =:= <<"plan.update">> ->
    #{type => system, subtype => plan_changed, content => Data};
normalize_event(#{<<"type">> := <<"user.message">>, <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    #{type => user, content => Content};
%% Session lifecycle events
normalize_event(#{<<"type">> := <<"session.start">>, <<"data">> := Data}) ->
    #{type => system, subtype => session_start, content => Data};
normalize_event(#{<<"type">> := <<"session.title_changed">>, <<"data">> := Data}) ->
    #{type => system, subtype => title_changed,
      content => maps:get(<<"title">>, Data, <<>>)};
normalize_event(#{<<"type">> := <<"session.model_change">>, <<"data">> := Data}) ->
    #{type => system, subtype => model_changed, content => Data,
      model => maps:get(<<"model">>, Data,
                        maps:get(<<"modelId">>, Data, <<>>))};
normalize_event(#{<<"type">> := <<"session.mode_changed">>, <<"data">> := Data}) ->
    #{type => system, subtype => mode_changed, content => Data};
normalize_event(#{<<"type">> := <<"session.shutdown">>, <<"data">> := Data}) ->
    #{type => system, subtype => shutdown, content => Data};
normalize_event(#{<<"type">> := <<"session.usage_info">>, <<"data">> := Data}) ->
    #{type => system, subtype => usage_info, content => Data};
normalize_event(#{<<"type">> := <<"session.tools_updated">>, <<"data">> := Data}) ->
    #{type => system, subtype => tools_updated, content => Data};
normalize_event(#{<<"type">> := <<"session.skills_loaded">>, <<"data">> := Data}) ->
    #{type => system, subtype => skills_loaded, content => Data};
normalize_event(#{<<"type">> := <<"session.mcp_servers_loaded">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => mcp_servers_loaded, content => Data};
%% Turn lifecycle events
normalize_event(#{<<"type">> := <<"assistant.turn_start">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => turn_start, content => Data};
normalize_event(#{<<"type">> := <<"assistant.turn_end">>, <<"data">> := Data}) ->
    Base = #{type => system, subtype => turn_end, content => Data},
    maybe_add_usage(Base, Data);
normalize_event(#{<<"type">> := <<"assistant.usage">>, <<"data">> := Data}) ->
    Base = #{type => system, subtype => usage, content => Data},
    maybe_add_usage(Base, Data);
normalize_event(#{<<"type">> := <<"assistant.intent">>, <<"data">> := Data}) ->
    #{type => system, subtype => intent,
      content => maps:get(<<"intent">>, Data, <<>>)};
normalize_event(#{<<"type">> := <<"assistant.streaming_delta">>,
                  <<"data">> := Data}) ->
    #{type => text_delta,
      content => maps:get(<<"delta">>, Data,
                          maps:get(<<"content">>, Data, <<>>))};
%% Subagent events
normalize_event(#{<<"type">> := <<"subagent.started">>, <<"data">> := Data}) ->
    #{type => system, subtype => subagent_started, content => Data};
normalize_event(#{<<"type">> := <<"subagent.completed">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => subagent_completed, content => Data};
normalize_event(#{<<"type">> := <<"subagent.failed">>, <<"data">> := Data}) ->
    #{type => error,
      content => maps:get(<<"error">>, Data, <<>>),
      error_type => subagent_failed};
normalize_event(#{<<"type">> := <<"subagent.selected">>, <<"data">> := Data}) ->
    #{type => system, subtype => subagent_selected, content => Data};
normalize_event(#{<<"type">> := <<"subagent.deselected">>,
                  <<"data">> := Data}) ->
    #{type => system, subtype => subagent_deselected, content => Data};
%% Hook events
normalize_event(#{<<"type">> := <<"hook.start">>, <<"data">> := Data}) ->
    #{type => system, subtype => hook_start, content => Data};
normalize_event(#{<<"type">> := <<"hook.end">>, <<"data">> := Data}) ->
    #{type => system, subtype => hook_end, content => Data};
%% Skill events
normalize_event(#{<<"type">> := <<"skill.invoked">>, <<"data">> := Data}) ->
    #{type => system, subtype => skill_invoked, content => Data};
%% Elicitation events
normalize_event(#{<<"type">> := <<"elicitation.requested">>,
                  <<"data">> := Data}) ->
    #{type => control_request,
      subtype => <<"elicitation">>,
      request_id => maps:get(<<"requestId">>, Data,
                             maps:get(<<"request_id">>, Data, undefined)),
      request => Data};
normalize_event(#{<<"type">> := <<"elicitation.completed">>,
                  <<"data">> := Data}) ->
    #{type => control_response, subtype => elicitation_completed,
      content => Data};
%% Command events
normalize_event(#{<<"type">> := <<"command.queued">>, <<"data">> := Data}) ->
    #{type => system, subtype => command_queued, content => Data};
normalize_event(#{<<"type">> := <<"command.execute">>, <<"data">> := Data}) ->
    #{type => system, subtype => command_execute, content => Data};
normalize_event(#{<<"type">> := <<"command.completed">>, <<"data">> := Data}) ->
    #{type => system, subtype => command_completed, content => Data};
normalize_event(#{<<"type">> := <<"commands.changed">>, <<"data">> := Data}) ->
    #{type => system, subtype => commands_changed, content => Data};
normalize_event(#{<<"type">> := Type} = Event) ->
    Data = maps:get(<<"data">>, Event, #{}),
    #{type => categorize_event(Type),
      content => Data,
      subtype => Type,
      timestamp => erlang:system_time(millisecond)};
normalize_event(Event) when is_map(Event) ->
    #{type => raw, content => Event,
      timestamp => erlang:system_time(millisecond)}.

-spec categorize_event(binary()) -> beam_agent_core:message_type().
%% Session lifecycle
categorize_event(<<"session.", _/binary>>)          -> system;
%% Turn lifecycle
categorize_event(<<"assistant.turn_start">>)        -> system;
categorize_event(<<"assistant.turn_end">>)          -> system;
categorize_event(<<"assistant.usage">>)             -> system;
categorize_event(<<"assistant.intent">>)            -> system;
categorize_event(<<"assistant.streaming_delta">>)   -> text;
%% Subagents
categorize_event(<<"subagent.", _/binary>>)         -> system;
%% Hooks
categorize_event(<<"hook.", _/binary>>)             -> system;
%% Skills
categorize_event(<<"skill.", _/binary>>)            -> system;
%% Elicitation
categorize_event(<<"elicitation.requested">>)       -> control_request;
categorize_event(<<"elicitation.completed">>)       -> system;
%% External tools
categorize_event(<<"external_tool.", _/binary>>)    -> system;
%% Commands
categorize_event(<<"command.", _/binary>>)          -> system;
categorize_event(<<"commands.changed">>)            -> system;
%% Compaction (v2 legacy names)
categorize_event(<<"compaction.", _/binary>>)       -> system;
%% Plan (v2 legacy name)
categorize_event(<<"plan.", _/binary>>)             -> system;
%% Permission (v2 legacy names)
categorize_event(<<"permission.", _/binary>>)       -> system;
%% Agent
categorize_event(<<"agent.", _/binary>>)            -> system;
categorize_event(_)                                 -> raw.
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
    P18 = maybe_put_opt(<<"tools">>,
                        maps:get(sdk_tools, Opts, undefined),
                        fun build_tool_definitions/1,
                        P17),
    %% COP-1: session.create flags required by origin SDK
    P19 = case maps:get(permission_handler, Opts, undefined) of
        undefined -> P18;
        _         -> P18#{<<"requestPermission">> => true}
    end,
    P20 = case maps:get(user_input_handler, Opts, undefined) of
        undefined -> P19;
        _         -> P19#{<<"requestUserInput">> => true}
    end,
    P21 = case maps:get(sdk_hooks, Opts, undefined) of
        undefined -> P20;
        _         -> P20#{<<"hooks">> => true}
    end,
    P22 = P21#{<<"envValueMode">> => <<"direct">>},
    maybe_put(<<"agent">>,
              maps:get(agent, Opts, undefined),
              P22).
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
build_permission_result({deny, _Reason, by_rules}) ->
    #{<<"result">> => #{<<"kind">> => <<"denied-by-rules">>}};
build_permission_result({deny, _Reason, by_content_exclusion}) ->
    #{<<"result">> =>
          #{<<"kind">> => <<"denied-by-content-exclusion-policy">>}};
build_permission_result({deny, _Reason}) ->
    #{<<"result">> =>
          #{<<"kind">> => <<"denied-interactively-by-user">>}};
build_permission_result(#{<<"kind">> := Kind} = Result)
  when Kind =:= <<"approved">>;
       Kind =:= <<"denied-by-rules">>;
       Kind =:= <<"denied-by-content-exclusion-policy">>;
       Kind =:= <<"denied-interactively-by-user">>;
       Kind =:= <<"denied-no-approval-rule-and-could-not-request-from-user">> ->
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

%%--------------------------------------------------------------------
%% COP-7: Session-scoped RPC param builders
%%
%% Each function returns a params map for the named JSON-RPC method.
%% Usage:
%%   Params = copilot_protocol:build_mode_set_params(SId, Mode),
%%   copilot_protocol:encode_request(Id, <<"session.mode.set">>, Params)
%%--------------------------------------------------------------------

%% Session management

%% Params for session.model.getCurrent
-spec build_model_get_current_params(binary()) -> map().
build_model_get_current_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.mode.get
-spec build_mode_get_params(binary()) -> map().
build_mode_get_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.mode.set
-spec build_mode_set_params(binary(), binary()) -> map().
build_mode_set_params(SessionId, ModeId)
  when is_binary(SessionId), is_binary(ModeId) ->
    #{<<"sessionId">> => SessionId, <<"modeId">> => ModeId}.

%% Params for session.plan.read
-spec build_plan_read_params(binary()) -> map().
build_plan_read_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.plan.update
-spec build_plan_update_params(binary(), map()) -> map().
build_plan_update_params(SessionId, Plan)
  when is_binary(SessionId), is_map(Plan) ->
    #{<<"sessionId">> => SessionId, <<"plan">> => Plan}.

%% Params for session.plan.delete
-spec build_plan_delete_params(binary()) -> map().
build_plan_delete_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.getForeground
-spec build_get_foreground_params(binary()) -> map().
build_get_foreground_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.setForeground
-spec build_set_foreground_params(binary(), boolean()) -> map().
build_set_foreground_params(SessionId, Foreground)
  when is_binary(SessionId), is_boolean(Foreground) ->
    #{<<"sessionId">> => SessionId, <<"foreground">> => Foreground}.

%% Params for session.log
-spec build_log_params(binary(), binary(), binary()) -> map().
build_log_params(SessionId, Message, Level)
  when is_binary(SessionId), is_binary(Message), is_binary(Level) ->
    #{<<"sessionId">> => SessionId,
      <<"message">> => Message,
      <<"level">> => Level}.

%% Workspace

%% Params for session.workspace.listFiles
-spec build_workspace_list_files_params(binary()) -> map().
build_workspace_list_files_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.workspace.readFile
-spec build_workspace_read_file_params(binary(), binary()) -> map().
build_workspace_read_file_params(SessionId, Path)
  when is_binary(SessionId), is_binary(Path) ->
    #{<<"sessionId">> => SessionId, <<"path">> => Path}.

%% Params for session.workspace.createFile
-spec build_workspace_create_file_params(binary(), binary(), binary()) -> map().
build_workspace_create_file_params(SessionId, Path, Content)
  when is_binary(SessionId), is_binary(Path), is_binary(Content) ->
    #{<<"sessionId">> => SessionId,
      <<"path">> => Path,
      <<"content">> => Content}.

%% Agents

%% Params for session.agent.list
-spec build_agent_list_params(binary()) -> map().
build_agent_list_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.agent.getCurrent
-spec build_agent_get_current_params(binary()) -> map().
build_agent_get_current_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.agent.select
-spec build_agent_select_params(binary(), binary()) -> map().
build_agent_select_params(SessionId, AgentId)
  when is_binary(SessionId), is_binary(AgentId) ->
    #{<<"sessionId">> => SessionId, <<"agentId">> => AgentId}.

%% Params for session.agent.deselect
-spec build_agent_deselect_params(binary()) -> map().
build_agent_deselect_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.agent.reload
-spec build_agent_reload_params(binary()) -> map().
build_agent_reload_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Skills

%% Params for session.skills.list
-spec build_skills_list_params(binary()) -> map().
build_skills_list_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.skills.enable
-spec build_skills_enable_params(binary(), binary()) -> map().
build_skills_enable_params(SessionId, SkillId)
  when is_binary(SessionId), is_binary(SkillId) ->
    #{<<"sessionId">> => SessionId, <<"skillId">> => SkillId}.

%% Params for session.skills.disable
-spec build_skills_disable_params(binary(), binary()) -> map().
build_skills_disable_params(SessionId, SkillId)
  when is_binary(SessionId), is_binary(SkillId) ->
    #{<<"sessionId">> => SessionId, <<"skillId">> => SkillId}.

%% Params for session.skills.reload
-spec build_skills_reload_params(binary()) -> map().
build_skills_reload_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% MCP

%% Params for session.mcp.list
-spec build_mcp_list_params(binary()) -> map().
build_mcp_list_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.mcp.enable
-spec build_mcp_enable_params(binary(), binary()) -> map().
build_mcp_enable_params(SessionId, ServerId)
  when is_binary(SessionId), is_binary(ServerId) ->
    #{<<"sessionId">> => SessionId, <<"serverId">> => ServerId}.

%% Params for session.mcp.disable
-spec build_mcp_disable_params(binary(), binary()) -> map().
build_mcp_disable_params(SessionId, ServerId)
  when is_binary(SessionId), is_binary(ServerId) ->
    #{<<"sessionId">> => SessionId, <<"serverId">> => ServerId}.

%% Params for session.mcp.reload
-spec build_mcp_reload_params(binary()) -> map().
build_mcp_reload_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Other

%% Params for session.fleet.start
-spec build_fleet_start_params(binary(), map()) -> map().
build_fleet_start_params(SessionId, Config)
  when is_binary(SessionId), is_map(Config) ->
    #{<<"sessionId">> => SessionId, <<"config">> => Config}.

%% Params for session.plugins.list
-spec build_plugins_list_params(binary()) -> map().
build_plugins_list_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.compaction.compact
-spec build_compaction_compact_params(binary()) -> map().
build_compaction_compact_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for session.shell.exec
-spec build_shell_exec_params(binary(), binary()) -> map().
build_shell_exec_params(SessionId, Command)
  when is_binary(SessionId), is_binary(Command) ->
    #{<<"sessionId">> => SessionId, <<"command">> => Command}.

%% Params for session.shell.kill
-spec build_shell_kill_params(binary(), binary()) -> map().
build_shell_kill_params(SessionId, ShellId)
  when is_binary(SessionId), is_binary(ShellId) ->
    #{<<"sessionId">> => SessionId, <<"shellId">> => ShellId}.

%% Params for session.ui.elicitation
-spec build_elicitation_params(binary(), map()) -> map().
build_elicitation_params(SessionId, Elicitation)
  when is_binary(SessionId), is_map(Elicitation) ->
    Elicitation#{<<"sessionId">> => SessionId}.

%% Params for tools.list
-spec build_tools_list_params(binary()) -> map().
build_tools_list_params(SessionId) when is_binary(SessionId) ->
    #{<<"sessionId">> => SessionId}.

%% Params for account.getQuota
-spec build_account_get_quota_params() -> map().
build_account_get_quota_params() ->
    #{}.

%% Params for session.extensions.* (generic extension call)
-spec build_extension_call_params(binary(), binary(), binary(), map()) -> map().
build_extension_call_params(SessionId, ExtensionId, Method, Args)
  when is_binary(SessionId), is_binary(ExtensionId),
       is_binary(Method), is_map(Args) ->
    #{<<"sessionId">> => SessionId,
      <<"extensionId">> => ExtensionId,
      <<"method">> => Method,
      <<"args">> => Args}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

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
