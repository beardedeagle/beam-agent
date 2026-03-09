-module(codex_protocol).
-export([normalize_notification/2,
         thread_start_params/1,
         thread_resume_params/2,
         thread_fork_params/2,
         thread_list_params/1,
         fuzzy_file_search_session_start_params/2,
         fuzzy_file_search_session_update_params/2,
         fuzzy_file_search_session_stop_params/1,
         turn_start_params/2,
         turn_start_params/3,
         turn_steer_params/3,
         turn_steer_params/4,
         initialize_params/1,
         command_exec_params/2,
         command_write_stdin_params/3,
         command_approval_response/1,
         file_approval_response/1,
         request_user_input_response/1,
         text_input/1,
         parse_approval_decision/1,
         encode_approval_decision/1,
         encode_ask_for_approval/1,
         encode_sandbox_mode/1]).
-export_type([approval_decision/0,
              file_approval_decision/0,
              ask_for_approval/0,
              sandbox_mode/0,
              user_input/0]).
-dialyzer({nowarn_function, [{normalize_notification, 2}]}).
-dialyzer({no_underspecs,
           [{thread_start_params, 1},
            {thread_resume_params, 2},
            {thread_fork_params, 2},
            {thread_list_params, 1},
            {fuzzy_file_search_session_start_params, 2},
            {fuzzy_file_search_session_update_params, 2},
            {fuzzy_file_search_session_stop_params, 1},
            {turn_start_params, 2},
            {turn_start_params, 3},
            {turn_steer_params, 3},
            {turn_steer_params, 4},
            {initialize_params, 1},
            {command_exec_params, 2},
            {command_write_stdin_params, 3},
            {command_approval_response, 1},
            {file_approval_response, 1},
            {build_prompt_inputs, 2},
            {text_input, 1},
            {encode_approval_decision, 1},
            {encode_ask_for_approval, 1},
            {encode_sandbox_mode, 1},
            {maybe_put, 3},
            {maybe_put_opt, 4}]}).
-type approval_decision() ::
          accept | accept_for_session | decline | cancel.
-type file_approval_decision() ::
          accept | accept_for_session | decline | cancel.
-type ask_for_approval() ::
          untrusted | on_failure | on_request | reject | never.
-type sandbox_mode() :: read_only | workspace_write | danger_full_access.
-type user_input() :: #{binary() => term()}.
-spec normalize_notification(binary(), map()) -> beam_agent_core:message().
normalize_notification(<<"item/agentMessage/delta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => text,
      content => Delta,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/started">>,
                       #{<<"item">> := Item} = Params) ->
    normalize_item_started(maps:get(<<"type">>, Item, <<>>),
                           Item, Params);
normalize_notification(<<"item/started">>, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)};
normalize_notification(<<"item/completed">>,
                       #{<<"item">> := Item} = Params) ->
    normalize_item_completed(maps:get(<<"type">>, Item, <<>>),
                             Item, Params);
normalize_notification(<<"item/completed">>, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)};
normalize_notification(<<"turn/completed">>, Params) ->
    Status = maps:get(<<"status">>, Params, <<>>),
    ErrorMsg =
        case maps:find(<<"error">>, Params) of
            {ok, E} when is_binary(E) ->
                E;
            {ok, E} when is_map(E) ->
                maps:get(<<"message">>, E, <<>>);
            _ ->
                <<>>
        end,
    Base =
        #{type => result,
          content => ErrorMsg,
          timestamp => erlang:system_time(millisecond),
          raw => Params},
    maybe_put(subtype, Status, Base);
normalize_notification(<<"turn/started">>, Params) ->
    #{type => system,
      content => <<"turn started">>,
      subtype => <<"turn_started">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/commandExecution/outputDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => stream_event,
      content => Delta,
      subtype => <<"command_output">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/fileChange/outputDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => stream_event,
      content => Delta,
      subtype => <<"file_output">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/reasoning/textDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => thinking,
      content => Delta,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"error">>, Params) ->
    Msg = maps:get(<<"message">>, Params, <<>>),
    Base =
        #{type => error,
          content => Msg,
          timestamp => erlang:system_time(millisecond),
          raw => Params},
    case maps:find(<<"willRetry">>, Params) of
        {ok, WR} ->
            Base#{subtype =>
                      if
                          WR ->
                              <<"will_retry">>;
                          true ->
                              <<"final">>
                      end};
        error ->
            Base
    end;
normalize_notification(<<"thread/status/changed">>, Params) ->
    Status = maps:get(<<"status">>, Params, <<>>),
    #{type => system,
      content => <<"thread status: ",Status/binary>>,
      subtype => <<"thread_status_changed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/closed">>, Params) ->
    ThreadId = maps:get(<<"threadId">>, Params, <<>>),
    #{type => system,
      content => <<"thread closed: ",ThreadId/binary>>,
      subtype => <<"thread_closed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/name/updated">>, Params) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    #{type => system,
      content => <<"thread renamed: ",Name/binary>>,
      subtype => <<"thread_name_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/compacted">>, Params) ->
    #{type => system,
      content => <<"thread compacted">>,
      subtype => <<"thread_compacted">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"turn/diff/updated">>, Params) ->
    #{type => stream_event,
      content => maps:get(<<"diff">>, Params, <<>>),
      subtype => <<"turn_diff_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"turn/plan/updated">>, Params) ->
    #{type => stream_event,
      content => maps:get(<<"plan">>, Params, <<>>),
      subtype => <<"turn_plan_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/plan/delta">>, Params) ->
    #{type => stream_event,
      content => maps:get(<<"delta">>, Params, <<>>),
      subtype => <<"plan_delta">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/commandExecution/terminalInteraction">>,
                       Params) ->
    #{type => stream_event,
      content => maps:get(<<"stdin">>, Params, <<>>),
      subtype => <<"command_stdin">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"serverRequest/resolved">>, Params) ->
    #{type => system,
      content => <<"server request resolved">>,
      subtype => <<"server_request_resolved">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/mcpToolCall/progress">>, Params) ->
    #{type => stream_event,
      content => maps:get(<<"message">>, Params, <<>>),
      subtype => <<"mcp_tool_progress">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"mcpServer/oauthLogin/completed">>, Params) ->
    #{type => system,
      content => <<"mcp oauth completed">>,
      subtype => <<"mcp_oauth_completed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"account/updated">>, Params) ->
    #{type => system,
      content => <<"account updated">>,
      subtype => <<"account_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"account/rateLimits/updated">>, Params) ->
    #{type => system,
      content => <<"account rate limits updated">>,
      subtype => <<"account_rate_limits_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"app/list/updated">>, Params) ->
    #{type => system,
      content => <<"apps updated">>,
      subtype => <<"apps_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/reasoning/summaryTextDelta">>, Params) ->
    #{type => thinking,
      content => maps:get(<<"delta">>, Params, <<>>),
      subtype => <<"reasoning_summary_delta">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"item/reasoning/summaryPartAdded">>, Params) ->
    #{type => thinking,
      content => maps:get(<<"text">>, Params, <<>>),
      subtype => <<"reasoning_summary_part_added">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"model/rerouted">>, Params) ->
    #{type => system,
      content => <<"model rerouted">>,
      subtype => <<"model_rerouted">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"deprecationNotice">>, Params) ->
    #{type => system,
      content => maps:get(<<"message">>, Params, <<>>),
      subtype => <<"deprecation_notice">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"configWarning">>, Params) ->
    #{type => system,
      content => maps:get(<<"message">>, Params, <<>>),
      subtype => <<"config_warning">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"fuzzyFileSearch/sessionUpdated">>, Params) ->
    #{type => stream_event,
      content => maps:get(<<"query">>, Params, <<>>),
      subtype => <<"fuzzy_file_search_updated">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"fuzzyFileSearch/sessionCompleted">>, Params) ->
    #{type => system,
      content => maps:get(<<"query">>, Params, <<>>),
      subtype => <<"fuzzy_file_search_completed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/realtime/started">>, Params) ->
    #{type => system,
      content => <<"thread realtime started">>,
      subtype => <<"thread_realtime_started">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/realtime/itemAdded">>, Params) ->
    #{type => stream_event,
      content => <<"thread realtime item added">>,
      subtype => <<"thread_realtime_item_added">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/realtime/outputAudio/delta">>, Params) ->
    #{type => stream_event,
      content => <<"thread realtime audio delta">>,
      subtype => <<"thread_realtime_output_audio_delta">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/realtime/error">>, Params) ->
    #{type => error,
      content =>
          maps:get(<<"message">>, Params, <<"thread realtime error">>),
      subtype => <<"thread_realtime_error">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"thread/realtime/closed">>, Params) ->
    #{type => system,
      content =>
          maps:get(<<"reason">>, Params, <<"thread realtime closed">>),
      subtype => <<"thread_realtime_closed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"windowsSandbox/setupCompleted">>, Params) ->
    #{type => system,
      content => <<"windows sandbox setup completed">>,
      subtype => <<"windows_sandbox_setup_completed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(<<"account/login/completed">>, Params) ->
    #{type => system,
      content => <<"account login completed">>,
      subtype => <<"account_login_completed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_notification(_Method, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)}.
-spec normalize_item_started(binary(), map(), map()) ->
                                beam_agent_core:message().
normalize_item_started(<<"AgentMessage">>, Item, Params) ->
    Content =
        maps:get(<<"content">>, Item, maps:get(<<"text">>, Item, <<>>)),
    #{type => text,
      content => Content,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_item_started(<<"CommandExecution">>, Item, Params) ->
    #{type => tool_use,
      tool_name =>
          maps:get(<<"command">>,
                   Item,
                   maps:get(<<"callId">>, Item, <<"command">>)),
      tool_input => maps:get(<<"args">>, Item, #{}),
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_item_started(<<"FileChange">>, Item, Params) ->
    #{type => tool_use,
      tool_name => maps:get(<<"filePath">>, Item, <<"file_change">>),
      tool_input =>
          #{<<"action">> => maps:get(<<"action">>, Item, <<>>)},
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_item_started(_Type, _Item, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)}.
-spec normalize_item_completed(binary(), map(), map()) ->
                                  beam_agent_core:message().
normalize_item_completed(<<"CommandExecution">>, Item, Params) ->
    Output = maps:get(<<"output">>, Item, <<>>),
    #{type => tool_result,
      tool_name =>
          maps:get(<<"command">>,
                   Item,
                   maps:get(<<"callId">>, Item, <<"command">>)),
      content => Output,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_item_completed(<<"FileChange">>, Item, Params) ->
    Output = maps:get(<<"output">>, Item, <<>>),
    #{type => tool_result,
      tool_name => maps:get(<<"filePath">>, Item, <<"file_change">>),
      content => Output,
      timestamp => erlang:system_time(millisecond),
      raw => Params};
normalize_item_completed(_Type, _Item, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)}.
-spec thread_start_params(map()) -> map().
thread_start_params(Opts) ->
    M0 = #{},
    M1 = maybe_put_opt(<<"model">>, model, Opts, M0),
    M2 = maybe_put_opt(<<"modelProvider">>, model_provider, Opts, M1),
    M3 = maybe_put_opt(<<"serviceTier">>, service_tier, Opts, M2),
    M4 = maybe_put_opt(<<"cwd">>, cwd, Opts, M3),
    M5 = maybe_put_opt(<<"approvalPolicy">>, approval_policy, Opts, M4),
    M6 =
        maybe_put_opt(<<"sandbox">>,
                      sandbox, Opts,
                      maybe_put_opt(<<"sandbox">>,
                                    sandbox_mode, Opts, M5)),
    M7 = maybe_put_opt(<<"config">>, config, Opts, M6),
    M8 = maybe_put_opt(<<"serviceName">>, service_name, Opts, M7),
    M9 =
        maybe_put_opt(<<"baseInstructions">>,
                      base_instructions, Opts, M8),
    M10 =
        maybe_put_opt(<<"developerInstructions">>,
                      developer_instructions, Opts, M9),
    M11 = maybe_put_opt(<<"personality">>, personality, Opts, M10),
    M12 = maybe_put_opt(<<"ephemeral">>, ephemeral, Opts, M11),
    M13 =
        maybe_put(<<"experimentalRawEvents">>,
                  maps:get(experimental_raw_events, Opts, false),
                  M12),
    maybe_put(<<"persistExtendedHistory">>,
              maps:get(persist_extended_history, Opts, false),
              M13).
-spec thread_resume_params(binary(), map()) -> map().
thread_resume_params(ThreadId, Opts)
    when is_binary(ThreadId), is_map(Opts) ->
    M0 = #{<<"threadId">> => ThreadId},
    M1 = maybe_put_opt(<<"history">>, history, Opts, M0),
    M2 = maybe_put_opt(<<"path">>, path, Opts, M1),
    M3 = maybe_put_opt(<<"model">>, model, Opts, M2),
    M4 = maybe_put_opt(<<"modelProvider">>, model_provider, Opts, M3),
    M5 =
        maybe_put_opt(<<"cwd">>,
                      cwd, Opts,
                      maybe_put_opt(<<"cwd">>,
                                    working_directory, Opts, M4)),
    M6 = maybe_put_opt(<<"approvalPolicy">>, approval_policy, Opts, M5),
    M7 =
        maybe_put_opt(<<"sandbox">>,
                      sandbox, Opts,
                      maybe_put_opt(<<"sandbox">>,
                                    sandbox_mode, Opts, M6)),
    M8 = maybe_put_opt(<<"config">>, config, Opts, M7),
    M9 =
        maybe_put_opt(<<"baseInstructions">>,
                      base_instructions, Opts, M8),
    M10 =
        maybe_put_opt(<<"developerInstructions">>,
                      developer_instructions, Opts, M9),
    M11 = maybe_put_opt(<<"personality">>, personality, Opts, M10),
    maybe_put_opt(<<"experimentalRawEvents">>,
                  experimental_raw_events, Opts, M11).
-spec thread_fork_params(binary(), map()) -> map().
thread_fork_params(ThreadId, Opts)
    when is_binary(ThreadId), is_map(Opts) ->
    M0 = #{<<"threadId">> => ThreadId},
    M1 = maybe_put_opt(<<"path">>, path, Opts, M0),
    M2 = maybe_put_opt(<<"model">>, model, Opts, M1),
    M3 = maybe_put_opt(<<"modelProvider">>, model_provider, Opts, M2),
    M4 =
        maybe_put_opt(<<"cwd">>,
                      cwd, Opts,
                      maybe_put_opt(<<"cwd">>,
                                    working_directory, Opts, M3)),
    M5 = maybe_put_opt(<<"approvalPolicy">>, approval_policy, Opts, M4),
    M6 =
        maybe_put_opt(<<"sandbox">>,
                      sandbox, Opts,
                      maybe_put_opt(<<"sandbox">>,
                                    sandbox_mode, Opts, M5)),
    M7 = maybe_put_opt(<<"config">>, config, Opts, M6),
    M8 =
        maybe_put_opt(<<"baseInstructions">>,
                      base_instructions, Opts, M7),
    maybe_put_opt(<<"developerInstructions">>,
                  developer_instructions, Opts, M8).
-spec thread_list_params(map()) -> map().
thread_list_params(Opts) when is_map(Opts) ->
    M0 = #{},
    M1 = maybe_put_opt(<<"cursor">>, cursor, Opts, M0),
    M2 = maybe_put_opt(<<"limit">>, limit, Opts, M1),
    M3 =
        maybe_put_opt(<<"sortKey">>,
                      sort_key, Opts,
                      maybe_put_opt(<<"sortKey">>,
                                    <<"sortKey">>,
                                    Opts,
                                    maybe_put_opt(<<"sortKey">>,
                                                  sortKey, Opts, M2))),
    M4 =
        maybe_put_opt(<<"modelProviders">>,
                      model_providers, Opts,
                      maybe_put_opt(<<"modelProviders">>,
                                    <<"modelProviders">>,
                                    Opts,
                                    maybe_put_opt(<<"modelProviders">>,
                                                  modelProviders, Opts,
                                                  M3))),
    maybe_put_opt(<<"archived">>, archived, Opts, M4).

-spec fuzzy_file_search_session_start_params(term(), [term()]) -> map().
fuzzy_file_search_session_start_params(SessionId, Roots) when is_list(Roots) ->
    #{<<"sessionId">> => ensure_binary(SessionId),
      <<"roots">> => [ensure_binary(Root) || Root <- Roots]}.

-spec fuzzy_file_search_session_update_params(term(), term()) -> map().
fuzzy_file_search_session_update_params(SessionId, Query) ->
    #{<<"sessionId">> => ensure_binary(SessionId),
      <<"query">> => ensure_binary(Query)}.

-spec fuzzy_file_search_session_stop_params(term()) -> map().
fuzzy_file_search_session_stop_params(SessionId) ->
    #{<<"sessionId">> => ensure_binary(SessionId)}.

-spec turn_start_params(binary(), binary() | [user_input()]) -> map().
turn_start_params(ThreadId, Prompt) when is_binary(Prompt) ->
    turn_start_params(ThreadId, [text_input(Prompt)], #{});
turn_start_params(ThreadId, Inputs) when is_list(Inputs) ->
    turn_start_params(ThreadId, Inputs, #{}).
-spec turn_start_params(binary(), binary() | [user_input()], map()) ->
                           map().
turn_start_params(ThreadId, Prompt, Opts) when is_binary(Prompt) ->
    Inputs =
        build_prompt_inputs(Prompt, maps:get(attachments, Opts, [])),
    turn_start_params(ThreadId, Inputs, Opts);
turn_start_params(ThreadId, Inputs, Opts) when is_list(Inputs) ->
    NormalizedInputs =
        [ 
         normalize_user_input(Input) ||
             Input <- Inputs
        ],
    M0 = #{<<"threadId">> => ThreadId, <<"input">> => NormalizedInputs},
    M1 = maybe_put_opt(<<"cwd">>, cwd, Opts, M0),
    M2 = maybe_put_opt(<<"approvalPolicy">>, approval_policy, Opts, M1),
    M3 =
        maybe_put_opt(<<"sandboxPolicy">>,
                      sandbox_policy, Opts,
                      maybe_put_opt(<<"sandboxPolicy">>,
                                    sandbox_mode, Opts, M2)),
    M4 = maybe_put_opt(<<"model">>, model, Opts, M3),
    M5 = maybe_put_opt(<<"serviceTier">>, service_tier, Opts, M4),
    M6 = maybe_put_opt(<<"effort">>, effort, Opts, M5),
    M7 = maybe_put_opt(<<"summary">>, summary, Opts, M6),
    M8 = maybe_put_opt(<<"personality">>, personality, Opts, M7),
    M9 =
        maybe_put_opt(<<"outputSchema">>,
                      output_schema, Opts,
                      maybe_put_opt(<<"outputSchema">>,
                                    output_format, Opts, M8)),
    maybe_put_opt(<<"collaborationMode">>, collaboration_mode, Opts, M9).
-spec turn_steer_params(binary(), binary(), binary() | [user_input()]) ->
                           map().
turn_steer_params(ThreadId, TurnId, Prompt) when is_binary(Prompt) ->
    turn_steer_params(ThreadId, TurnId, [text_input(Prompt)], #{});
turn_steer_params(ThreadId, TurnId, Inputs) when is_list(Inputs) ->
    turn_steer_params(ThreadId, TurnId, Inputs, #{}).
-spec turn_steer_params(binary(),
                        binary(),
                        binary() | [user_input()],
                        map()) ->
                           map().
turn_steer_params(ThreadId, TurnId, Prompt, Opts) when is_binary(Prompt) ->
    Inputs =
        build_prompt_inputs(Prompt, maps:get(attachments, Opts, [])),
    turn_steer_params(ThreadId, TurnId, Inputs, Opts);
turn_steer_params(ThreadId, TurnId, Inputs, Opts)
    when
        is_binary(ThreadId),
        is_binary(TurnId),
        is_list(Inputs),
        is_map(Opts) ->
    NormalizedInputs =
        [ 
         normalize_user_input(Input) ||
             Input <- Inputs
        ],
    M0 =
        #{<<"threadId">> => ThreadId,
          <<"expectedTurnId">> => TurnId,
          <<"input">> => NormalizedInputs},
    maybe_put_opt(<<"cwd">>, cwd, Opts, M0).
-spec initialize_params(map()) -> map().
initialize_params(Opts) ->
    ClientInfo =
        #{<<"name">> => <<"beam_agent_sdk">>,
          <<"version">> => <<"0.1.0">>},
    M0 = #{<<"clientInfo">> => ClientInfo},
    M1 = maybe_put_opt(<<"model">>, model, Opts, M0),
    M2 = maybe_put_opt(<<"askForApproval">>, approval_policy, Opts, M1),
    M3 = maybe_put_opt(<<"sandboxMode">>, sandbox_mode, Opts, M2),
    maybe_put_opt(<<"outputFormat">>, output_format, Opts, M3).
-spec command_exec_params(binary() | [binary()], map()) -> map().
command_exec_params(Command, Opts) when is_binary(Command), is_map(Opts) ->
    command_exec_params([Command], Opts);
command_exec_params(Command, Opts) when is_list(Command), is_map(Opts) ->
    M0 =
        #{<<"command">> =>
              [ 
               ensure_binary(Part) ||
                   Part <- Command
              ]},
    M1 =
        maybe_put_opt(<<"timeoutMs">>,
                      timeout_ms, Opts,
                      maybe_put_opt(<<"timeoutMs">>, timeout, Opts, M0)),
    M2 = maybe_put_opt(<<"cwd">>, cwd, Opts, M1),
    maybe_put_opt(<<"sandboxPolicy">>,
                  sandbox_policy, Opts,
                  maybe_put_opt(<<"sandboxPolicy">>,
                                sandbox_mode, Opts, M2)).
-spec command_write_stdin_params(binary(), binary(), map()) -> map().
command_write_stdin_params(ProcessId, Stdin, Opts)
    when is_binary(ProcessId), is_binary(Stdin), is_map(Opts) ->
    M0 = #{<<"processId">> => ProcessId, <<"stdin">> => Stdin},
    M1 = maybe_put_opt(<<"threadId">>, thread_id, Opts, M0),
    M2 = maybe_put_opt(<<"turnId">>, turn_id, Opts, M1),
    M3 = maybe_put_opt(<<"itemId">>, item_id, Opts, M2),
    M4 = maybe_put_opt(<<"yieldTimeMs">>, yield_time_ms, Opts, M3),
    maybe_put_opt(<<"maxOutputTokens">>, max_output_tokens, Opts, M4).
-spec command_approval_response(approval_decision()) -> map().
command_approval_response(Decision) ->
    #{<<"decision">> => encode_approval_decision(Decision)}.
-spec file_approval_response(file_approval_decision()) -> map().
file_approval_response(Decision) ->
    #{<<"decision">> => encode_approval_decision(Decision)}.
-spec text_input(binary()) -> user_input().
text_input(Text) when is_binary(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text}.
-spec request_user_input_response(map()) -> map().
request_user_input_response(#{answers := Answers}) ->
    #{<<"answers">> => normalize_user_input_answers(Answers)};
request_user_input_response(#{<<"answers">> := Answers}) ->
    #{<<"answers">> => normalize_user_input_answers(Answers)};
request_user_input_response(Answers) when is_map(Answers) ->
    #{<<"answers">> => normalize_user_input_answers(Answers)};
request_user_input_response(_) ->
    #{<<"answers">> => #{}}.
-spec parse_approval_decision(binary()) -> approval_decision().
parse_approval_decision(<<"accept">>) ->
    accept;
parse_approval_decision(<<"acceptForSession">>) ->
    accept_for_session;
parse_approval_decision(<<"decline">>) ->
    decline;
parse_approval_decision(<<"cancel">>) ->
    cancel;
parse_approval_decision(_) ->
    decline.
-spec encode_approval_decision(approval_decision()) -> binary().
encode_approval_decision(accept) ->
    <<"accept">>;
encode_approval_decision(accept_for_session) ->
    <<"acceptForSession">>;
encode_approval_decision(decline) ->
    <<"decline">>;
encode_approval_decision(cancel) ->
    <<"cancel">>.
-spec encode_ask_for_approval(ask_for_approval()) -> binary().
encode_ask_for_approval(untrusted) ->
    <<"untrusted">>;
encode_ask_for_approval(on_failure) ->
    <<"on-failure">>;
encode_ask_for_approval(on_request) ->
    <<"on-request">>;
encode_ask_for_approval(reject) ->
    <<"reject">>;
encode_ask_for_approval(never) ->
    <<"never">>.
-spec encode_sandbox_mode(sandbox_mode()) -> binary().
encode_sandbox_mode(read_only) ->
    <<"read-only">>;
encode_sandbox_mode(workspace_write) ->
    <<"workspace-write">>;
encode_sandbox_mode(danger_full_access) ->
    <<"danger-full-access">>.
-spec maybe_put(term(), term(), map()) -> map().
maybe_put(_Key, <<>>, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.
-spec maybe_put_opt(binary(), atom() | binary(), map(), map()) -> map().
maybe_put_opt(WireKey, OptKey, Opts, Map) ->
    case maps:find(OptKey, Opts) of
        {ok, V} ->
            Map#{WireKey => V};
        error ->
            Map
    end.
-spec build_prompt_inputs(binary(), [map()] | undefined) ->
                             nonempty_list(user_input()).
build_prompt_inputs(Prompt, undefined) ->
    [text_input(Prompt)];
build_prompt_inputs(Prompt, Attachments) when is_list(Attachments) ->
    [text_input(Prompt) |
     [ 
      normalize_attachment(Attachment) ||
          Attachment <- Attachments
     ]].
-spec normalize_user_input(map() | binary()) -> user_input().
normalize_user_input(Input) when is_binary(Input) ->
    text_input(Input);
normalize_user_input(#{<<"type">> := _} = Input) ->
    normalize_attachment(Input);
normalize_user_input(#{type := _} = Input) ->
    normalize_attachment(Input);
normalize_user_input(Input) when is_map(Input) ->
    normalize_attachment(Input).
-spec normalize_attachment(map()) -> user_input().
normalize_attachment(#{<<"type">> := <<"text">>} = Attachment) ->
    #{<<"type">> => <<"text">>,
      <<"text">> => maps:get(<<"text">>, Attachment, <<>>)};
normalize_attachment(#{type := text} = Attachment) ->
    #{<<"type">> => <<"text">>,
      <<"text">> => maps:get(text, Attachment, <<>>)};
normalize_attachment(#{<<"type">> := <<"image">>} = Attachment) ->
    #{<<"type">> => <<"image">>,
      <<"url">> =>
          attachment_value(Attachment,
                           [<<"url">>, <<"image_url">>, <<"imageUrl">>],
                           <<>>)};
normalize_attachment(#{type := image} = Attachment) ->
    #{<<"type">> => <<"image">>,
      <<"url">> =>
          attachment_value(Attachment, [url, image_url, imageUrl], <<>>)};
normalize_attachment(#{<<"type">> := Type} = Attachment)
    when Type =:= <<"localImage">>; Type =:= <<"local_image">> ->
    #{<<"type">> => <<"localImage">>,
      <<"path">> => attachment_value(Attachment, [<<"path">>], <<>>)};
normalize_attachment(#{type := Type} = Attachment)
    when Type =:= local_image; Type =:= localImage ->
    #{<<"type">> => <<"localImage">>,
      <<"path">> => attachment_value(Attachment, [path], <<>>)};
normalize_attachment(#{<<"type">> := <<"skill">>} = Attachment) ->
    #{<<"type">> => <<"skill">>,
      <<"name">> => attachment_value(Attachment, [<<"name">>], <<>>),
      <<"path">> => attachment_value(Attachment, [<<"path">>], <<>>)};
normalize_attachment(#{type := skill} = Attachment) ->
    #{<<"type">> => <<"skill">>,
      <<"name">> => attachment_value(Attachment, [name], <<>>),
      <<"path">> => attachment_value(Attachment, [path], <<>>)};
normalize_attachment(#{<<"type">> := <<"mention">>} = Attachment) ->
    #{<<"type">> => <<"mention">>,
      <<"name">> => attachment_value(Attachment, [<<"name">>], <<>>),
      <<"path">> => attachment_value(Attachment, [<<"path">>], <<>>)};
normalize_attachment(#{type := mention} = Attachment) ->
    #{<<"type">> => <<"mention">>,
      <<"name">> => attachment_value(Attachment, [name], <<>>),
      <<"path">> => attachment_value(Attachment, [path], <<>>)};
normalize_attachment(Attachment) ->
    Map0 =
        maps:fold(fun(Key, Value, Acc) when is_atom(Key) ->
                         Acc#{atom_to_binary(Key, utf8) => Value};
                     (Key, Value, Acc) ->
                         Acc#{Key => Value}
                  end,
                  #{},
                  Attachment),
    case maps:is_key(<<"type">>, Map0) of
        true ->
            Map0;
        false ->
            Map0#{<<"type">> => <<"text">>}
    end.
-spec normalize_user_input_answers(map()) -> map().
normalize_user_input_answers(Answers) ->
    maps:fold(fun normalize_user_input_answer/3, #{}, Answers).
-spec normalize_user_input_answer(term(), term(), map()) -> map().
normalize_user_input_answer(Key, Value, Acc) ->
    Answer =
        case Value of
            Bin when is_binary(Bin) ->
                #{<<"answers">> => [Bin]};
            List when is_list(List) ->
                #{<<"answers">> =>
                      [ 
                       ensure_binary(Item) ||
                           Item <- List
                      ]};
            #{answers := Answers} ->
                #{<<"answers">> =>
                      [ 
                       ensure_binary(Item) ||
                           Item <- Answers
                      ]};
            #{<<"answers">> := Answers} ->
                #{<<"answers">> =>
                      [ 
                       ensure_binary(Item) ||
                           Item <- Answers
                      ]};
            _ ->
                #{<<"answers">> => []}
        end,
    Acc#{ensure_binary(Key) => Answer}.
-spec attachment_value(map(), [term()], binary()) -> binary().
attachment_value(Attachment, [Key | Rest], Default) ->
    case maps:find(Key, Attachment) of
        {ok, Value} when is_binary(Value) ->
            Value;
        {ok, Value} when is_list(Value) ->
            unicode:characters_to_binary(Value);
        {ok, Value} when is_atom(Value) ->
            atom_to_binary(Value);
        _ ->
            attachment_value(Attachment, Rest, Default)
    end;
attachment_value(_Attachment, [], Default) ->
    Default.
-spec ensure_binary(term()) -> binary().
ensure_binary(Value) when is_binary(Value) ->
    Value;
ensure_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
ensure_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value);
ensure_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
ensure_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).
