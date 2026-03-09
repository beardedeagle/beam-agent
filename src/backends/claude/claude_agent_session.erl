-module(claude_agent_session).
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).
-export([start_link/1,send_query/4,receive_message/3,health/1,stop/1]).
-export([send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2]).
-export([cancel/2,
         rewind_files/2,
         stop_task/2,
         set_max_thinking_tokens/2,
         mcp_server_status/1,
         set_mcp_servers/2,
         reconnect_mcp_server/2,
         toggle_mcp_server/3]).
-export([callback_mode/0,init/1,terminate/3]).
-export([connecting/3,initializing/3,ready/3,active_query/3,error/3]).
-type state_name() ::
          connecting | initializing | ready | active_query | error.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).
-export_type([state_name/0]).
-dialyzer({no_underspecs,
           [{resume_args, 1},
            {permission_mode_args, 1},
            {tool_args, 1},
            {fork_session_args, 1},
            {settings_args, 1},
            {load_settings_object, 1},
            {load_settings_binary, 1},
            {decode_settings_json, 1},
            {normalize_json_map, 1},
            {build_cli_hook_matcher, 1},
            {new_hook_callback, 1},
            {invoke_hook_callback, 4},
            {normalize_hook_value, 3},
            {normalize_permission_handler_response, 2},
            {approve_permission_response, 3},
            {normalize_permission_result_map, 1},
            {normalize_permission_result_map, 2},
            {maybe_put_defined, 3},
            {debug_args, 1},
            {build_session_info, 1},
            {encode_system_prompt, 1},
            {encode_permission_mode, 1},
            {write_mcp_config, 1}]}).
-record(data,{port :: port() | undefined,
              buffer = <<>> :: binary(),
              buffer_max :: pos_integer(),
              pending = #{} :: #{binary() => gen_statem:from()},
              consumer :: gen_statem:from() | undefined,
              query_ref :: reference() | undefined,
              session_id :: binary() | undefined,
              opts :: map(),
              cli_path :: string(),
              system_info = #{} :: map(),
              init_response = #{} :: map(),
              permission_handler ::
                  fun((binary(), map(), map()) ->
                          beam_agent_core:permission_result()) |
                  undefined,
              user_input_handler ::
                  fun((map(), map()) -> {ok, binary()} | {error, term()}) |
                  undefined,
              sdk_mcp_registry ::
                  beam_agent_mcp_core:mcp_registry() | undefined,
              sdk_hook_registry ::
                  beam_agent_hooks_core:hook_registry() | undefined,
              hook_config = null :: map() | null,
              hook_callbacks = #{} :: #{binary() => fun()},
              mcp_config_path :: string() | undefined,
              query_start_time :: integer() | undefined}).
-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(claude_agent_session, Opts, []).
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
                    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).
-spec receive_message(pid(), reference(), timeout()) ->
                         {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 10000).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    send_control(Pid, <<"set_model">>, #{<<"model">> => Model}).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    send_control(Pid,
                 <<"set_permission_mode">>,
                 #{<<"permissionMode">> => Mode}).
-spec cancel(pid(), reference()) -> ok.
cancel(Pid, Ref) ->
    gen_statem:call(Pid, {cancel, Ref}, 5000).
-spec rewind_files(pid(), binary()) -> {ok, term()} | {error, term()}.
rewind_files(Pid, CheckpointUuid) ->
    send_control(Pid,
                 <<"rewind_files">>,
                 #{<<"checkpoint_uuid">> => CheckpointUuid}).
-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Pid, TaskId) ->
    send_control(Pid, <<"stop_task">>, #{<<"task_id">> => TaskId}).
-spec set_max_thinking_tokens(pid(), pos_integer()) ->
                                 {ok, term()} | {error, term()}.
set_max_thinking_tokens(Pid, MaxTokens)
    when is_integer(MaxTokens), MaxTokens > 0 ->
    send_control(Pid,
                 <<"set_max_thinking_tokens">>,
                 #{<<"maxThinkingTokens">> => MaxTokens}).
-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Pid) ->
    send_control(Pid, <<"mcp_status">>, #{}).
-spec set_mcp_servers(pid(), map()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Pid, Servers) when is_map(Servers) ->
    send_control(Pid,
                 <<"mcp_set_servers">>,
                 #{<<"servers">> => Servers}).
-spec reconnect_mcp_server(pid(), binary()) ->
                              {ok, term()} | {error, term()}.
reconnect_mcp_server(Pid, ServerName) when is_binary(ServerName) ->
    send_control(Pid,
                 <<"mcp_reconnect">>,
                 #{<<"serverName">> => ServerName}).
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
                           {ok, term()} | {error, term()}.
toggle_mcp_server(Pid, ServerName, Enabled)
    when is_binary(ServerName), is_boolean(Enabled) ->
    send_control(Pid,
                 <<"mcp_toggle">>,
                 #{<<"serverName">> => ServerName,
                   <<"enabled">> => Enabled}).
-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].
-spec init(map()) -> gen_statem:init_result(connecting) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = resolve_cli_path(maps:get(cli_path, Opts, "claude")),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    McpRegistry =
        build_mcp_registry(maps:get(sdk_mcp_servers, Opts, undefined)),
    HookRegistry =
        build_hook_registry(maps:get(sdk_hooks, Opts, undefined)),
    {HookConfig, HookCallbacks} =
        build_cli_hooks(maps:get(hooks, Opts, undefined)),
    McpConfigPath = write_mcp_config(McpRegistry),
    Args = build_cli_args(Opts, McpConfigPath),
    PortOpts = build_port_opts(Opts, Args),
    try
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        Data =
            #data{port = Port,
                  buffer_max = BufferMax,
                  opts = Opts,
                  cli_path = CliPath,
                  session_id = maps:get(session_id, Opts, undefined),
                  permission_handler = PermHandler,
                  user_input_handler = UserInputHandler,
                  sdk_mcp_registry = McpRegistry,
                  sdk_hook_registry = HookRegistry,
                  hook_config = HookConfig,
                  hook_callbacks = HookCallbacks,
                  mcp_config_path = McpConfigPath},
        {ok, connecting, Data}
    catch
        error:Reason ->
            cleanup_mcp_config(McpConfigPath),
            logger:warning("Claude session failed to open port: ~p",
                           [Reason]),
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.
-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = undefined} = Data) ->
    _ = fire_hook(session_end,
                  #{session_id => Data#data.session_id,
                    reason => Reason},
                  Data),
    cleanup_mcp_config(Data#data.mcp_config_path),
    ok;
terminate(Reason, _State, #data{port = Port} = Data) ->
    _ = fire_hook(session_end,
                  #{session_id => Data#data.session_id,
                    reason => Reason},
                  Data),
    catch port_close(Port),
    cleanup_mcp_config(Data#data.mcp_config_path),
    ok.
-spec connecting(gen_statem:event_type(), term(), #data{}) ->
                    state_callback_result().
connecting(enter, _OldState, _Data) ->
    beam_agent_telemetry_core:state_change(claude, undefined, connecting),
    {keep_state_and_data, [{state_timeout, 1000, connect_timeout}]};
connecting(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    Buffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    {next_state, initializing, Data#data{buffer = Buffer}};
connecting(info,
           {Port, {exit_status, Status}},
           #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {cli_exit, Status}}]};
connecting(state_timeout, connect_timeout, Data) ->
    {next_state, initializing, Data};
connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};
connecting({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
connecting({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, connecting}}]}.
-spec initializing(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
initializing(enter, _OldState, Data) ->
    beam_agent_telemetry_core:state_change(claude, connecting, initializing),
    ReqId = beam_agent_core:make_request_id(),
    InitRequest =
        build_init_request(Data#data.opts,
                           Data#data.sdk_mcp_registry,
                           Data#data.hook_config),
    InitMsg =
        #{<<"type">> => <<"control_request">>,
          <<"request_id">> => ReqId,
          <<"request">> => InitRequest},
    port_command(Data#data.port, beam_agent_jsonl:encode_line(InitMsg)),
    {keep_state, Data, [{state_timeout, 0, check_init_buffer}]};
initializing(state_timeout, check_init_buffer, Data) ->
    case try_extract_init_response(Data#data.buffer, Data) of
        {ok, SessionId, Remaining, Data2} ->
            {next_state, ready,
             Data2#data{buffer = Remaining, session_id = SessionId}};
        {not_ready, _, _Data2} ->
            {keep_state_and_data,
             [{state_timeout, 15000, init_timeout}]}
    end;
initializing(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    case try_extract_init_response(NewBuffer, Data) of
        {ok, SessionId, Remaining, Data2} ->
            {next_state, ready,
             Data2#data{buffer = Remaining, session_id = SessionId}};
        {not_ready, Buffer2, Data2} ->
            check_buffer_overflow(Data2#data{buffer = Buffer2})
    end;
initializing(info,
             {Port, {exit_status, Status}},
             #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {cli_exit_during_init, Status}}]};
initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {timeout, initializing}}]};
initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};
initializing({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
initializing({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, initializing}}]}.
-spec ready(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
ready(enter, initializing, Data) ->
    beam_agent_telemetry_core:state_change(claude, initializing, ready),
    _ = fire_hook(session_start,
                  #{session_id => Data#data.session_id,
                    system_info => Data#data.system_info},
                  Data),
    {keep_state, Data#data{consumer = undefined, query_ref = undefined}};
ready(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(claude, OldState, ready),
    {keep_state, Data#data{consumer = undefined, query_ref = undefined}};
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    case
        fire_hook(user_prompt_submit,
                  #{prompt => Prompt,
                    params => Params,
                    session_id => Data#data.session_id},
                  Data)
    of
        ok ->
            Ref = make_ref(),
            QueryMsg = build_query_message(Prompt, Params),
            port_command(Data#data.port,
                         beam_agent_jsonl:encode_line(QueryMsg)),
            StartTime =
                beam_agent_telemetry_core:span_start(claude, query,
                                                #{prompt => Prompt}),
            {next_state, active_query,
             Data#data{query_ref = Ref,
                       buffer = Data#data.buffer,
                       query_start_time = StartTime},
             [{reply, From, {ok, Ref}}]};
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]}
    end;
ready({call, From}, {send_control, Method, Params}, Data) ->
    send_control_impl(From, Method, Params, Data);
ready(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    {KeepData, Actions} =
        process_control_messages(Data#data{buffer = NewBuffer}),
    {keep_state, KeepData, Actions};
ready(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error,
     Data#data{port = undefined},
     [{next_event, internal, {cli_exit, Status}}]};
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {receive_message, _Ref}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
ready({call, From}, _Request, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, not_supported_in_ready}}]}.
-spec active_query(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
active_query(enter, ready, Data) ->
    beam_agent_telemetry_core:state_change(claude, ready, active_query),
    {keep_state, Data};
active_query({call, From},
             {receive_message, Ref},
             #data{query_ref = Ref} = Data) ->
    case try_extract_next_deliverable(Data) of
        {ok, Msg, Data2} ->
            case maps:get(type, Msg) of
                result ->
                    _ = fire_hook(stop,
                                  #{content =>
                                        maps:get(content, Msg, <<>>),
                                    stop_reason =>
                                        maps:get(stop_reason, Msg,
                                                 undefined),
                                    duration_ms =>
                                        maps:get(duration_ms, Msg,
                                                 undefined),
                                    session_id => Data2#data.session_id},
                                  Data2),
                    {next_state, ready, Data2,
                     [{reply, From, {ok, Msg}}]};
                tool_result ->
                    _ = fire_hook(post_tool_use,
                                  #{tool_name =>
                                        maps:get(tool_name, Msg, <<>>),
                                    content =>
                                        maps:get(content, Msg, <<>>),
                                    session_id => Data2#data.session_id},
                                  Data2),
                    {keep_state, Data2, [{reply, From, {ok, Msg}}]};
                error ->
                    {next_state, ready, Data2,
                     [{reply, From, {ok, Msg}}]};
                _Other ->
                    {keep_state, Data2, [{reply, From, {ok, Msg}}]}
            end;
        {none, Data2} ->
            {keep_state, Data2#data{consumer = From}}
    end;
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary,RawData/binary>>,
    Data2 = Data#data{buffer = NewBuffer},
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(NewBuffer),
                                                 Data#data.buffer_max),
            Actions =
                case Data#data.consumer of
                    undefined ->
                        [];
                    Consumer ->
                        [{reply, Consumer, {error, buffer_overflow}}]
                end,
            {next_state, error,
             Data2#data{consumer = undefined},
             [{next_event, internal, buffer_overflow} | Actions]};
        false ->
            maybe_deliver_to_consumer(Data2)
    end;
active_query(info,
             {Port, {exit_status, Status}},
             #data{port = Port} = Data) ->
    maybe_span_exception(Data, {cli_exit, Status}),
    Actions =
        case Data#data.consumer of
            undefined ->
                [];
            Consumer ->
                [{reply, Consumer, {error, {cli_exit, Status}}}]
        end,
    {next_state, error,
     Data#data{port = undefined,
               consumer = undefined,
               query_start_time = undefined},
     [{next_event, internal, {cli_exit, Status}} | Actions]};
active_query({call, From}, {send_control, Method, Params}, Data) ->
    send_control_impl(From, Method, Params, Data);
active_query({call, From}, interrupt, #data{port = Port} = Data) ->
    send_sigint(Port),
    Actions =
        case Data#data.consumer of
            undefined ->
                [{reply, From, ok}];
            Consumer ->
                [{reply, Consumer, {error, interrupted}},
                 {reply, From, ok}]
        end,
    {next_state, ready, Data#data{consumer = undefined}, Actions};
active_query({call, From}, {cancel, Ref}, #data{query_ref = Ref} = Data) ->
    Actions =
        case Data#data.consumer of
            undefined ->
                [{reply, From, ok}];
            Consumer ->
                [{reply, Consumer, {error, cancelled}},
                 {reply, From, ok}]
        end,
    {next_state, ready, Data#data{consumer = undefined}, Actions};
active_query({call, From}, {cancel, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From}, _Request, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, not_supported_during_query}}]}.
-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(claude, OldState, error),
    case Data#data.port of
        undefined ->
            ok;
        Port ->
            catch port_close(Port)
    end,
    maps:foreach(fun(_Id, From) ->
                        gen_statem:reply(From, {error, session_error})
                 end,
                 Data#data.pending),
    {keep_state,
     Data#data{port = undefined, pending = #{}},
     [{state_timeout, 60000, auto_stop}]};
error(state_timeout, auto_stop, _Data) ->
    {stop, {shutdown, session_error}};
error(internal, Reason, _Data) ->
    logger:error("claude_agent_session error: ~p", [Reason]),
    keep_state_and_data;
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
error({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.
-spec resolve_cli_path(file:filename_all()) -> string().
resolve_cli_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
resolve_cli_path(Path) when is_list(Path) ->
    Path;
resolve_cli_path(Path) when is_atom(Path) ->
    atom_to_list(Path).
-spec build_cli_args(map(), string() | undefined) -> [string()].
build_cli_args(Opts, McpConfigPath) ->
    Base =
        ["--output-format",
         "stream-json",
         "--input-format",
         "stream-json",
         "--verbose"],
    lists:append([Base,
                  session_id_args(Opts),
                  resume_args(Opts),
                  fork_session_args(Opts),
                  model_args(Opts),
                  fallback_model_args(Opts),
                  system_prompt_args(Opts),
                  max_turns_args(Opts),
                  permission_mode_args(Opts),
                  permission_prompt_tool_args(Opts),
                  tool_args(Opts),
                  settings_args(Opts),
                  add_dirs_args(Opts),
                  budget_args(Opts),
                  debug_args(Opts),
                  extra_args(Opts),
                  sdk_mcp_args(McpConfigPath)]).
-spec session_id_args(map()) -> [string()].
session_id_args(Opts) ->
    case maps:get(session_id, Opts, undefined) of
        undefined ->
            [];
        Id when is_binary(Id) ->
            ["--session-id", binary_to_list(Id)];
        Id when is_list(Id) ->
            ["--session-id", Id]
    end.
-spec resume_args(map()) -> [string()].
resume_args(Opts) ->
    R = case maps:get(resume, Opts, false) of
            true ->
                ["--resume"];
            false ->
                []
        end,
    C = case maps:get(continue, Opts, false) of
            true ->
                ["--continue"];
            false ->
                []
        end,
    R ++ C.
-spec fork_session_args(map()) -> [string()].
fork_session_args(Opts) ->
    case maps:get(fork_session, Opts, false) of
        true ->
            ["--fork-session"];
        false ->
            []
    end.
-spec model_args(map()) -> [string()].
model_args(Opts) ->
    case maps:get(model, Opts, undefined) of
        undefined ->
            [];
        Model when is_binary(Model) ->
            ["--model", binary_to_list(Model)];
        Model when is_list(Model) ->
            ["--model", Model]
    end.
-spec fallback_model_args(map()) -> [string()].
fallback_model_args(Opts) ->
    case maps:get(fallback_model, Opts, undefined) of
        undefined ->
            [];
        Model when is_binary(Model) ->
            ["--fallback-model", binary_to_list(Model)];
        Model when is_list(Model) ->
            ["--fallback-model", Model]
    end.
-spec system_prompt_args(map()) -> [string()].
system_prompt_args(Opts) ->
    case maps:get(system_prompt, Opts, undefined) of
        undefined ->
            [];
        #{type := preset} ->
            [];
        SP when is_binary(SP) ->
            ["--system-prompt", binary_to_list(SP)];
        SP when is_list(SP) ->
            ["--system-prompt", SP]
    end.
-spec max_turns_args(map()) -> [string()].
max_turns_args(Opts) ->
    case maps:get(max_turns, Opts, undefined) of
        undefined ->
            [];
        MT when is_integer(MT) ->
            ["--max-turns", integer_to_list(MT)]
    end.
-spec permission_mode_args(map()) -> [string()].
permission_mode_args(Opts) ->
    case maps:get(permission_mode, Opts, undefined) of
        undefined ->
            [];
        PM when is_atom(PM) ->
            ["--permission-mode",
             binary_to_list(encode_permission_mode(PM))];
        PM when is_binary(PM) ->
            ["--permission-mode", binary_to_list(PM)]
    end.
-spec permission_prompt_tool_args(map()) -> [string()].
permission_prompt_tool_args(Opts) ->
    case maps:get(permission_prompt_tool_name, Opts, undefined) of
        undefined ->
            [];
        Tool when is_binary(Tool) ->
            ["--permission-prompt-tool", binary_to_list(Tool)];
        Tool when is_list(Tool) ->
            ["--permission-prompt-tool", Tool]
    end.
-spec tool_args(map()) -> [string()].
tool_args(Opts) ->
    Tools =
        case maps:get(tools, Opts, undefined) of
            undefined ->
                [];
            ToolList when is_list(ToolList) ->
                ["--tools",
                 string:join([ 
                              binary_to_list(T) ||
                                  T <- ToolList
                             ],
                             ",")];
            #{type := preset, preset := _Preset} ->
                ["--tools", "default"];
            Preset when is_binary(Preset) ->
                ["--tools", binary_to_list(Preset)];
            Preset when is_list(Preset) ->
                ["--tools", Preset]
        end,
    AT =
        case maps:get(allowed_tools, Opts, undefined) of
            undefined ->
                [];
            Tools when is_list(Tools) ->
                ["--allowedTools",
                 binary_to_list(iolist_to_binary(json:encode(Tools)))]
        end,
    DT =
        case maps:get(disallowed_tools, Opts, undefined) of
            undefined ->
                [];
            DTools when is_list(DTools) ->
                ["--disallowedTools",
                 binary_to_list(iolist_to_binary(json:encode(DTools)))]
        end,
    Tools ++ AT ++ DT.
-spec settings_args(map()) -> [string()].
settings_args(Opts) ->
    case build_settings_value(Opts) of
        undefined ->
            [];
        Value ->
            ["--settings", binary_to_list(Value)]
    end.
-spec add_dirs_args(map()) -> [string()].
add_dirs_args(Opts) ->
    case maps:get(add_dirs, Opts, undefined) of
        undefined ->
            [];
        Dirs when is_list(Dirs) ->
            lists:append([ 
                          ["--add-dir", resolve_cli_path(Dir)] ||
                              Dir <- Dirs
                         ]);
        _ ->
            []
    end.
-spec budget_args(map()) -> [string()].
budget_args(Opts) ->
    case maps:get(max_budget_usd, Opts, undefined) of
        undefined ->
            [];
        Budget when is_number(Budget) ->
            ["--max-budget-usd",
             float_to_list(Budget * 1.0, [{decimals, 4}])]
    end.
-spec debug_args(map()) -> [string()].
debug_args(Opts) ->
    D = case maps:get(debug, Opts, false) of
            true ->
                ["--debug"];
            false ->
                []
        end,
    DF =
        case maps:get(debug_file, Opts, undefined) of
            undefined ->
                [];
            File when is_binary(File) ->
                ["--debug-file", binary_to_list(File)]
        end,
    D ++ DF.
-spec extra_args(map()) -> [string()].
extra_args(Opts) ->
    case maps:get(extra_args, Opts, undefined) of
        undefined ->
            [];
        ExtraMap when is_map(ExtraMap) ->
            maps:fold(fun(Key, null, Acc) ->
                             [binary_to_list(iolist_to_binary(["--",
                                                               Key])) |
                              Acc];
                         (Key, Val, Acc) ->
                             [binary_to_list(iolist_to_binary(["--",
                                                               Key])),
                              binary_to_list(Val) |
                              Acc]
                      end,
                      [], ExtraMap)
    end.
-spec build_settings_value(map()) -> binary() | undefined.
build_settings_value(Opts) ->
    Settings = maps:get(settings, Opts, undefined),
    Sandbox = maps:get(sandbox, Opts, undefined),
    case {Settings, Sandbox} of
        {undefined, undefined} ->
            undefined;
        {Value, undefined} when is_binary(Value) ->
            Value;
        {Value, undefined} when is_list(Value) ->
            list_to_binary(Value);
        _ ->
            SettingsObj0 = load_settings_object(Settings),
            SettingsObj =
                case Sandbox of
                    SandboxMap when is_map(SandboxMap) ->
                        SettingsObj0#{<<"sandbox">> =>
                                          normalize_json_map(SandboxMap)};
                    _ ->
                        SettingsObj0
                end,
            iolist_to_binary(json:encode(SettingsObj))
    end.
-spec load_settings_object(term()) -> map().
load_settings_object(undefined) ->
    #{};
load_settings_object(Value) when is_map(Value) ->
    normalize_json_map(Value);
load_settings_object(Value) when is_binary(Value) ->
    load_settings_binary(Value);
load_settings_object(Value) when is_list(Value) ->
    load_settings_binary(list_to_binary(Value));
load_settings_object(_) ->
    #{}.
-spec load_settings_binary(binary()) -> map().
load_settings_binary(Value) ->
    Trimmed = string:trim(Value),
    case looks_like_json(Trimmed) of
        true ->
            decode_settings_json(Trimmed);
        false ->
            case file:read_file(Trimmed) of
                {ok, Contents} ->
                    decode_settings_json(Contents);
                _ ->
                    #{}
            end
    end.
-spec looks_like_json(binary()) -> boolean().
looks_like_json(<<"{",_/binary>>) ->
    true;
looks_like_json(_) ->
    false.
-spec decode_settings_json(binary()) -> map().
decode_settings_json(JsonBin) ->
    try json:decode(JsonBin) of
        Map when is_map(Map) ->
            Map;
        _ ->
            #{}
    catch
        _:_ ->
            #{}
    end.
-spec normalize_json_map(map()) -> map().
normalize_json_map(Map) ->
    maps:from_list([ 
                    {normalize_json_key(Key),
                     normalize_json_value(Value)} ||
                        {Key, Value} <- maps:to_list(Map)
                   ]).
-spec normalize_json_value(term()) -> term().
normalize_json_value(Value) when is_map(Value) ->
    normalize_json_map(Value);
normalize_json_value(Value) when is_list(Value) ->
    [ 
     normalize_json_value(Item) ||
         Item <- Value
    ];
normalize_json_value(Value) when is_atom(Value) ->
    atom_to_binary(Value);
normalize_json_value(Value) ->
    Value.
-spec normalize_json_key(term()) -> binary().
normalize_json_key(Key) when is_binary(Key) ->
    Key;
normalize_json_key(Key) when is_atom(Key) ->
    atom_to_binary(Key);
normalize_json_key(Key) when is_list(Key) ->
    unicode:characters_to_binary(Key);
normalize_json_key(Key) ->
    unicode:characters_to_binary(io_lib:format("~p", [Key])).
-spec sdk_mcp_args(nonempty_string() | undefined) -> [nonempty_string()].
sdk_mcp_args(undefined) ->
    [];
sdk_mcp_args(Path) when is_list(Path) ->
    ["--mcp-config", Path].
-spec build_mcp_registry([beam_agent_mcp_core:sdk_mcp_server()] | undefined) ->
                            beam_agent_mcp_core:mcp_registry() | undefined.
build_mcp_registry(Servers) ->
    beam_agent_mcp_core:build_registry(Servers).
-spec build_hook_registry([beam_agent_hooks_core:hook_def()] | undefined) ->
                             beam_agent_hooks_core:hook_registry() |
                             undefined.
build_hook_registry(Hooks) ->
    beam_agent_hooks_core:build_registry(Hooks).
-spec fire_hook(beam_agent_hooks_core:hook_event(), map(), #data{}) ->
                   ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Reg}) ->
    beam_agent_hooks_core:fire(Event, Context#{event => Event}, Reg).
-spec write_mcp_config(beam_agent_mcp_core:mcp_registry() | undefined) ->
                          string() | undefined.
write_mcp_config(undefined) ->
    undefined;
write_mcp_config(Registry) when map_size(Registry) =:= 0 ->
    undefined;
write_mcp_config(Registry) ->
    ConfigMap = beam_agent_mcp_core:servers_for_cli(Registry),
    TmpPath =
        "/tmp/beam_sdk_mcp_"
        ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".json",
    JsonBin = iolist_to_binary(json:encode(ConfigMap)),
    ok = file:write_file(TmpPath, JsonBin),
    TmpPath.
-spec cleanup_mcp_config(string() | undefined) -> ok.
cleanup_mcp_config(undefined) ->
    ok;
cleanup_mcp_config(Path) when is_list(Path) ->
    _ = file:delete(Path),
    ok.
-spec send_sigint(port()) -> ok.
send_sigint(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill -INT " ++ integer_to_list(OsPid)),
            ok;
        undefined ->
            ok
    end.
-dialyzer({nowarn_function, {build_port_opts, 2}}).
-spec build_port_opts(map(), [string(), ...]) -> [atom() | tuple(), ...].
build_port_opts(Opts, Args) ->
    Base =
        [{args, Args}, binary, exit_status, use_stdio, stderr_to_stdout],
    WorkDirOpt =
        case maps:get(work_dir, Opts, undefined) of
            undefined ->
                [];
            Dir when is_binary(Dir) ->
                [{cd, binary_to_list(Dir)}];
            Dir when is_list(Dir) ->
                [{cd, Dir}]
        end,
    SdkEnv =
        [{"CLAUDE_CODE_ENTRYPOINT", "sdk-erl"},
         {"CLAUDE_AGENT_SDK_VERSION", "0.1.0"}],
    ClientAppEnv =
        case maps:get(client_app, Opts, undefined) of
            undefined ->
                [];
            App when is_binary(App) ->
                [{"CLAUDE_AGENT_SDK_CLIENT_APP", binary_to_list(App)}]
        end,
    UserEnv = maps:get(env, Opts, []),
    EnvOpt = [{env, SdkEnv ++ ClientAppEnv ++ UserEnv}],
    Base ++ WorkDirOpt ++ EnvOpt.
-spec build_init_request(map(),
                         beam_agent_mcp_core:mcp_registry() | undefined,
                         map() | null) ->
                            map().
build_init_request(Opts, McpRegistry, HookConfig) ->
    Base =
        #{<<"subtype">> => <<"initialize">>,
          <<"hooks">> => HookConfig,
          <<"agents">> => encode_value(maps:get(agents, Opts, #{}))},
    Additions =
        [{output_format, <<"outputFormat">>},
         {mcp_servers, <<"mcpServers">>},
         {plugins, <<"plugins">>},
         {setting_sources, <<"settingSources">>},
         {thinking, <<"thinking">>},
         {sandbox, <<"sandbox">>},
         {betas, <<"betas">>},
         {effort, <<"effort">>},
         {enable_file_checkpointing, <<"enableFileCheckpointing">>},
         {prompt_suggestions, <<"promptSuggestions">>},
         {include_partial_messages, <<"includePartialMessages">>},
         {persist_session, <<"persistSession">>}],
    M1 =
        lists:foldl(fun({OptKey, WireKey}, Acc) ->
                           case maps:get(OptKey, Opts, undefined) of
                               undefined ->
                                   Acc;
                               Value ->
                                   Acc#{WireKey => encode_value(Value)}
                           end
                    end,
                    Base, Additions),
    M2 =
        case McpRegistry of
            undefined ->
                M1;
            Reg when is_map(Reg), map_size(Reg) > 0 ->
                Names = beam_agent_mcp_core:servers_for_init(Reg),
                M1#{<<"sdkMcpServers">> => Names};
            _ ->
                M1
        end,
    case maps:get(system_prompt, Opts, undefined) of
        #{type := preset} = SP ->
            M2#{<<"systemPrompt">> => encode_system_prompt(SP)};
        _ ->
            M2
    end.
-spec build_query_message(binary(), beam_agent_core:query_opts()) -> map().
build_query_message(Prompt, Params) ->
    Base =
        #{<<"type">> => <<"user">>,
          <<"message">> =>
              #{<<"role">> => <<"user">>, <<"content">> => Prompt}},
    maps:fold(fun(system_prompt, V, Acc) when is_binary(V) ->
                     Acc#{<<"system_prompt">> => V};
                 (allowed_tools, V, Acc) ->
                     Acc#{<<"allowedTools">> => V};
                 (disallowed_tools, V, Acc) ->
                     Acc#{<<"disallowedTools">> => V};
                 (max_tokens, V, Acc) ->
                     Acc#{<<"maxTokens">> => V};
                 (max_turns, V, Acc) ->
                     Acc#{<<"maxTurns">> => V};
                 (model, V, Acc) ->
                     Acc#{<<"model">> => V};
                 (output_format, V, Acc) ->
                     Acc#{<<"outputFormat">> => V};
                 (effort, V, Acc) ->
                     Acc#{<<"effort">> => V};
                 (agent, V, Acc) ->
                     Acc#{<<"agent">> => V};
                 (max_budget_usd, V, Acc) ->
                     Acc#{<<"maxBudgetUsd">> => V};
                 (_Key, _V, Acc) ->
                     Acc
              end,
              Base, Params).
-spec try_extract_init_response(binary(), #data{}) ->
                                   {ok,
                                    binary() | undefined,
                                    binary(),
                                    #data{}} |
                                   {not_ready, binary(), #data{}}.
try_extract_init_response(Buffer, Data) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            {not_ready, Buffer, Data};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, #{<<"type">> := <<"system">>} = SysMsg} ->
                    Normalized = beam_agent_core:normalize_message(SysMsg),
                    SysInfo =
                        maps:get(system_info, Normalized,
                                 Data#data.system_info),
                    Data2 = Data#data{system_info = SysInfo},
                    try_extract_init_response(Rest, Data2);
                {ok, #{<<"type">> := <<"control_response">>} = Msg} ->
                    Response = maps:get(<<"response">>, Msg, #{}),
                    case maps:get(<<"subtype">>, Response, undefined) of
                        <<"success">> ->
                            SessionId =
                                maps:get(<<"session_id">>,
                                         Response, undefined),
                            Data2 = Data#data{init_response = Response},
                            {ok, SessionId, Rest, Data2};
                        _ ->
                            try_extract_init_response(Rest, Data)
                    end;
                {ok, _OtherMsg} ->
                    try_extract_init_response(Rest, Data);
                {error, _} ->
                    try_extract_init_response(Rest, Data)
            end
    end.
-spec try_extract_message(binary()) ->
                             {ok, beam_agent_core:message(), binary()} | none.
try_extract_message(Buffer) ->
    case beam_agent_jsonl:extract_line(Buffer) of
        none ->
            none;
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok, RawMsg} ->
                    Msg = beam_agent_core:normalize_message(RawMsg),
                    {ok, Msg, Rest};
                {error, _DecodeErr} ->
                    try_extract_message(Rest)
            end
    end.
-spec try_extract_next_deliverable(#data{}) ->
                                      {ok,
                                       beam_agent_core:message(),
                                       #data{}} |
                                      {none, #data{}}.
try_extract_next_deliverable(Data) ->
    case try_extract_message(Data#data.buffer) of
        {ok, #{type := control_request} = Msg, Remaining} ->
            handle_inbound_control_request(Msg, Data),
            try_extract_next_deliverable(Data#data{buffer = Remaining});
        {ok,
         #{type := control_response, request_id := ReqId} = CtrlResp,
         Remaining} ->
            case maps:take(ReqId, Data#data.pending) of
                {From, Pending2} ->
                    gen_statem:reply(From, {ok, CtrlResp}),
                    try_extract_next_deliverable(Data#data{buffer =
                                                               Remaining,
                                                           pending =
                                                               Pending2});
                error ->
                    try_extract_next_deliverable(Data#data{buffer =
                                                               Remaining})
            end;
        {ok, Msg, Remaining} ->
            {ok, Msg, Data#data{buffer = Remaining}};
        none ->
            {none, Data}
    end.
-spec drain_control_requests(#data{}) -> #data{}.
drain_control_requests(Data) ->
    case try_extract_message(Data#data.buffer) of
        {ok, #{type := control_request} = Msg, Remaining} ->
            handle_inbound_control_request(Msg,
                                           Data#data{buffer = Remaining}),
            drain_control_requests(Data#data{buffer = Remaining});
        {ok,
         #{type := control_response, request_id := ReqId} = CtrlResp,
         Remaining} ->
            case maps:take(ReqId, Data#data.pending) of
                {From, Pending2} ->
                    gen_statem:reply(From, {ok, CtrlResp}),
                    drain_control_requests(Data#data{buffer = Remaining,
                                                     pending = Pending2});
                error ->
                    drain_control_requests(Data#data{buffer = Remaining})
            end;
        {ok, _RegularMsg, _Remaining} ->
            Data;
        none ->
            Data
    end.
-spec maybe_deliver_to_consumer(#data{}) ->
                                   gen_statem:event_handler_result(active_query |
                                                                   ready).
maybe_deliver_to_consumer(#data{consumer = undefined} = Data) ->
    Data2 = drain_control_requests(Data),
    {keep_state, Data2};
maybe_deliver_to_consumer(#data{consumer = Consumer} = Data) ->
    case try_extract_next_deliverable(Data) of
        {ok, Msg, Data2} ->
            _ = track_message(Msg, Data2),
            case maps:get(type, Msg) of
                result ->
                    maybe_span_stop(Data2),
                    _ = fire_hook(stop,
                                  #{content =>
                                        maps:get(content, Msg, <<>>),
                                    stop_reason =>
                                        maps:get(stop_reason, Msg,
                                                 undefined),
                                    duration_ms =>
                                        maps:get(duration_ms, Msg,
                                                 undefined),
                                    session_id => Data2#data.session_id},
                                  Data2),
                    {next_state, ready,
                     Data2#data{consumer = undefined,
                                query_start_time = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                tool_result ->
                    _ = fire_hook(post_tool_use,
                                  #{tool_name =>
                                        maps:get(tool_name, Msg, <<>>),
                                    content =>
                                        maps:get(content, Msg, <<>>),
                                    session_id => Data2#data.session_id},
                                  Data2),
                    {keep_state,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                error ->
                    {next_state, ready,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                _Other ->
                    {keep_state,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]}
            end;
        {none, Data2} ->
            {keep_state, Data2}
    end.
-spec check_buffer_overflow(#data{}) ->
                               gen_statem:event_handler_result(initializing |
                                                               error).
check_buffer_overflow(#data{buffer = Buffer, buffer_max = Max} = Data) ->
    case byte_size(Buffer) > Max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(byte_size(Buffer), Max),
            {next_state, error, Data,
             [{next_event, internal, buffer_overflow}]};
        false ->
            {keep_state, Data}
    end.
-spec send_control_impl(gen_statem:from(), binary(), map(), #data{}) ->
                           gen_statem:event_handler_result(state_name()).
send_control_impl(From, Method, Params, Data) ->
    ReqId = beam_agent_core:make_request_id(),
    Request = Params#{<<"subtype">> => Method},
    ControlMsg =
        #{<<"type">> => <<"control_request">>,
          <<"request_id">> => ReqId,
          <<"request">> => Request},
    port_command(Data#data.port,
                 beam_agent_jsonl:encode_line(ControlMsg)),
    Pending = maps:put(ReqId, From, Data#data.pending),
    {keep_state, Data#data{pending = Pending}}.
-spec process_control_messages(#data{}) ->
                                  {#data{}, [gen_statem:action()]}.
process_control_messages(Data) ->
    process_control_messages_loop(Data, []).
-spec process_control_messages_loop(#data{}, [gen_statem:action()]) ->
                                       {#data{}, [gen_statem:action()]}.
process_control_messages_loop(Data, Actions) ->
    case beam_agent_jsonl:extract_line(Data#data.buffer) of
        none ->
            {Data, Actions};
        {ok, Line, Rest} ->
            case beam_agent_jsonl:decode_line(Line) of
                {ok,
                 #{<<"type">> := <<"control_response">>,
                   <<"request_id">> := ReqId} =
                     Msg} ->
                    case maps:take(ReqId, Data#data.pending) of
                        {From, Pending2} ->
                            Data2 =
                                Data#data{buffer = Rest,
                                          pending = Pending2},
                            process_control_messages_loop(Data2,
                                                          [{reply, From,
                                                            {ok, Msg}} |
                                                           Actions]);
                        error ->
                            process_control_messages_loop(Data#data{buffer =
                                                                        Rest},
                                                          Actions)
                    end;
                {ok, #{<<"type">> := <<"control_request">>} = RawMsg} ->
                    Msg = beam_agent_core:normalize_message(RawMsg),
                    handle_inbound_control_request(Msg, Data),
                    process_control_messages_loop(Data#data{buffer =
                                                                Rest},
                                                  Actions);
                _ ->
                    process_control_messages_loop(Data#data{buffer =
                                                                Rest},
                                                  Actions)
            end
    end.
-spec handle_inbound_control_request(beam_agent_core:message(), #data{}) ->
                                        ok.
handle_inbound_control_request(Msg, #data{port = Port} = Data) ->
    ReqId = maps:get(request_id, Msg, undefined),
    Request = maps:get(request, Msg, #{}),
    Subtype = maps:get(<<"subtype">>, Request, undefined),
    Response = build_inbound_response(Subtype, Request, Data),
    ResponseMsg =
        #{<<"type">> => <<"control_response">>,
          <<"request_id">> => ReqId,
          <<"response">> => Response},
    port_command(Port, beam_agent_jsonl:encode_line(ResponseMsg)),
    ok.
-spec build_inbound_response(binary() | undefined, map(), #data{}) ->
                                map().
build_inbound_response(<<"can_use_tool">>,
                       Request,
                       #data{permission_handler = Handler,
                             sdk_hook_registry = HookReg} =
                           Data) ->
    ToolName = maps:get(<<"tool_name">>, Request, <<>>),
    ToolInput =
        maps:get(<<"tool_input">>,
                 Request,
                 maps:get(<<"input">>, Request, #{})),
    ToolUseId = maps:get(<<"tool_use_id">>, Request, <<>>),
    AgentId = maps:get(<<"agent_id">>, Request, undefined),
    PermissionSuggestions =
        maps:get(<<"permission_suggestions">>, Request, []),
    BlockedPath = maps:get(<<"blocked_path">>, Request, undefined),
    HookCtx0 =
        #{tool_name => ToolName,
          permission_prompt_tool_name => ToolName,
          tool_input => ToolInput,
          tool_use_id => ToolUseId,
          permission_suggestions => PermissionSuggestions},
    HookCtx1 = maybe_put_defined(agent_id, AgentId, HookCtx0),
    HookCtx = maybe_put_defined(session_id, Data#data.session_id, HookCtx1),
    case fire_permission_hooks(HookCtx, HookReg) of
        {deny, Reason} ->
            #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
        ok when is_function(Handler, 3) ->
            Options =
                #{tool_use_id => ToolUseId,
                  agent_id => AgentId,
                  permission_suggestions => PermissionSuggestions,
                  blocked_path => BlockedPath},
            try Handler(ToolName, ToolInput, Options) of
                PermissionResult ->
                    normalize_permission_handler_response(PermissionResult,
                                                          ToolInput)
            catch
                Class:CrashReason:Stack ->
                    logger:error("permission_handler crashed: ~p:~p~n~p",
                                 [Class, CrashReason, Stack]),
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> => <<"Permission handler crashed">>}
            end;
        ok ->
            case maps:get(permission_default, Data#data.opts, deny) of
                allow ->
                    #{<<"subtype">> => <<"approve">>};
                _ ->
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> =>
                          <<"No permission handler registered">>}
            end
    end;
build_inbound_response(<<"hook_callback">>, Request, Data) ->
    handle_hook_callback(Request, Data);
build_inbound_response(<<"mcp_message">>,
                       Request,
                       #data{sdk_mcp_registry = Registry})
    when is_map(Registry) ->
    ServerName = maps:get(<<"server_name">>, Request, <<>>),
    Message = maps:get(<<"message">>, Request, #{}),
    case
        beam_agent_mcp_core:handle_mcp_message(ServerName, Message, Registry)
    of
        {ok, McpResponse} ->
            #{<<"subtype">> => <<"ok">>,
              <<"mcp_response">> => McpResponse};
        {error, _} ->
            #{<<"subtype">> => <<"ok">>}
    end;
build_inbound_response(<<"mcp_message">>, _Request, _Data) ->
    #{<<"subtype">> => <<"ok">>};
build_inbound_response(<<"elicitation">>,
                       Request,
                       #data{user_input_handler = Handler} = Data)
    when is_function(Handler, 2) ->
    ElicitRequest =
        #{message => maps:get(<<"message">>, Request, <<>>),
          schema => maps:get(<<"schema">>, Request, #{}),
          tool_use_id => maps:get(<<"tool_use_id">>, Request, undefined),
          agent_id => maps:get(<<"agent_id">>, Request, undefined)},
    Ctx = #{session_id => Data#data.session_id},
    try Handler(ElicitRequest, Ctx) of
        {ok, Answer} ->
            #{<<"subtype">> => <<"ok">>, <<"result">> => Answer};
        {error, Reason} when is_binary(Reason) ->
            #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
        {error, _} ->
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input denied">>}
    catch
        Class:CrashReason:Stack ->
            logger:error("user_input_handler crashed: ~p:~p~n~p",
                         [Class, CrashReason, Stack]),
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input handler crashed">>}
    end;
build_inbound_response(<<"elicitation">>, _Request, _Data) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => <<"No user input handler registered">>};
build_inbound_response(_, _Request, _Data) ->
    #{<<"subtype">> => <<"ok">>}.
-spec fire_permission_hooks(map(),
                            beam_agent_hooks_core:hook_registry() | undefined) ->
                               ok | {deny, binary()}.
fire_permission_hooks(HookCtx, HookReg) ->
    case
        beam_agent_hooks_core:fire(permission_request,
                              HookCtx#{event => permission_request},
                              HookReg)
    of
        {deny, Reason} ->
            {deny, Reason};
        ok ->
            beam_agent_hooks_core:fire(pre_tool_use,
                                  HookCtx#{event => pre_tool_use},
                                  HookReg)
    end.
-spec normalize_permission_handler_response(term(), map()) -> map().
normalize_permission_handler_response({allow, UpdatedInput},
                                      OriginalInput) ->
    approve_permission_response(UpdatedInput, OriginalInput, #{});
normalize_permission_handler_response({allow, UpdatedInput, Third},
                                      OriginalInput)
    when is_list(Third) ->
    approve_permission_response(UpdatedInput, OriginalInput,
                                #{<<"updatedPermissions">> => Third});
normalize_permission_handler_response({allow, UpdatedInput, Third},
                                      OriginalInput)
    when is_map(Third) ->
    approve_permission_response(UpdatedInput, OriginalInput,
                                normalize_permission_result_map(Third));
normalize_permission_handler_response({deny, Reason}, _OriginalInput)
    when is_binary(Reason) ->
    #{<<"subtype">> => <<"deny">>, <<"message">> => Reason};
normalize_permission_handler_response({deny, Reason, Interrupt},
                                      _OriginalInput)
    when is_binary(Reason), is_boolean(Interrupt) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => Reason,
      <<"interrupt">> => Interrupt};
normalize_permission_handler_response(Map, OriginalInput)
    when is_map(Map) ->
    normalize_permission_result_map(Map, OriginalInput);
normalize_permission_handler_response(_, _OriginalInput) ->
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => <<"Invalid permission handler response">>}.
-spec approve_permission_response(term(), map(), map()) -> map().
approve_permission_response(UpdatedInput, OriginalInput, Extra) ->
    Input =
        case UpdatedInput of
            undefined ->
                OriginalInput;
            null ->
                OriginalInput;
            Map when is_map(Map) ->
                Map;
            _ ->
                OriginalInput
        end,
    maps:merge(#{<<"subtype">> => <<"approve">>,
                 <<"updatedInput">> => Input},
               Extra).
-spec normalize_permission_result_map(map()) -> map().
normalize_permission_result_map(Map) ->
    normalize_permission_result_map(Map, #{}).
-spec normalize_permission_result_map(map(), map()) -> map().
normalize_permission_result_map(Map, OriginalInput) ->
    Behavior0 =
        maps:get(behavior, Map,
                 maps:get(<<"behavior">>,
                          Map,
                          maps:get(permission_decision, Map,
                                   maps:get(<<"permissionDecision">>,
                                            Map, allow)))),
    Behavior = normalize_permission_behavior(Behavior0),
    UpdatedInput =
        maps:get(updated_input, Map,
                 maps:get(<<"updatedInput">>,
                          Map,
                          maps:get(input, Map, OriginalInput))),
    Message =
        maps:get(message, Map,
                 maps:get(reason, Map,
                          maps:get(<<"message">>,
                                   Map,
                                   maps:get(<<"reason">>, Map, <<>>)))),
    Interrupt =
        maps:get(interrupt, Map, maps:get(<<"interrupt">>, Map, false)),
    UpdatedPermissions =
        maps:get(updated_permissions, Map,
                 maps:get(<<"updatedPermissions">>, Map, undefined)),
    RuleUpdate =
        maps:get(rule_update, Map,
                 maps:get(<<"ruleUpdate">>, Map, undefined)),
    case Behavior of
        deny ->
            Response0 =
                #{<<"subtype">> => <<"deny">>,
                  <<"message">> => ensure_binary(Message)},
            case Interrupt of
                true ->
                    Response0#{<<"interrupt">> => true};
                _ ->
                    Response0
            end;
        _ ->
            Extra0 =
                case UpdatedPermissions of
                    Permissions when is_list(Permissions) ->
                        #{<<"updatedPermissions">> => Permissions};
                    _ ->
                        #{}
                end,
            Extra =
                case RuleUpdate of
                    Rule when is_map(Rule) ->
                        Extra0#{<<"ruleUpdate">> => Rule};
                    _ ->
                        Extra0
                end,
            approve_permission_response(UpdatedInput, OriginalInput,
                                        Extra)
    end.
-spec normalize_permission_behavior(term()) -> allow | deny.
normalize_permission_behavior(allow) ->
    allow;
normalize_permission_behavior(approve) ->
    allow;
normalize_permission_behavior(<<"allow">>) ->
    allow;
normalize_permission_behavior(<<"approve">>) ->
    allow;
normalize_permission_behavior(deny) ->
    deny;
normalize_permission_behavior(block) ->
    deny;
normalize_permission_behavior(<<"deny">>) ->
    deny;
normalize_permission_behavior(<<"block">>) ->
    deny;
normalize_permission_behavior(_) ->
    allow.
-spec build_cli_hooks(map() | undefined) ->
                         {map() | null, #{binary() => fun()}}.
build_cli_hooks(undefined) ->
    {null, #{}};
build_cli_hooks(Hooks) when is_map(Hooks) ->
    {Config0, Callbacks} =
        maps:fold(fun build_cli_hook_event/3, {#{}, #{}}, Hooks),
    case map_size(Config0) of
        0 ->
            {null, Callbacks};
        _ ->
            {Config0, Callbacks}
    end;
build_cli_hooks(_) ->
    {null, #{}}.
-spec build_cli_hook_event(term(),
                           term(),
                           {map(), #{binary() => fun()}}) ->
                              {map(), #{binary() => fun()}}.
build_cli_hook_event(EventKey, Matchers0, {ConfigAcc, CallbackAcc}) ->
    EventName = hook_event_name(EventKey),
    {MatchersRev, Callbacks} = build_cli_hook_matchers(Matchers0),
    Matchers = lists:reverse(MatchersRev),
    case Matchers of
        [] ->
            {ConfigAcc, maps:merge(CallbackAcc, Callbacks)};
        _ ->
            {ConfigAcc#{EventName => Matchers},
             maps:merge(CallbackAcc, Callbacks)}
    end.
-spec build_cli_hook_matchers(term()) -> {[map()], #{binary() => fun()}}.
build_cli_hook_matchers(Matchers) when is_list(Matchers) ->
    lists:foldl(fun(Matcher, {MatcherAcc, CallbackAcc}) ->
                       case build_cli_hook_matcher(Matcher) of
                           skip ->
                               {MatcherAcc, CallbackAcc};
                           {Config, Callbacks} ->
                               {[Config | MatcherAcc],
                                maps:merge(CallbackAcc, Callbacks)}
                       end
                end,
                {[], #{}},
                Matchers);
build_cli_hook_matchers(Matcher) ->
    build_cli_hook_matchers([Matcher]).
-spec build_cli_hook_matcher(term()) ->
                                skip | {map(), #{binary() => fun()}}.
build_cli_hook_matcher(Matcher)
    when is_function(Matcher, 1); is_function(Matcher, 3) ->
    {CallbackId, Callback} = new_hook_callback(Matcher),
    {#{<<"matcher">> => null, <<"hookCallbackIds">> => [CallbackId]},
     #{CallbackId => Callback}};
build_cli_hook_matcher(Matcher) when is_map(Matcher) ->
    HooksValue =
        maps:get(hooks, Matcher, maps:get(<<"hooks">>, Matcher, [])),
    ExistingIds =
        maps:get(hookCallbackIds, Matcher,
                 maps:get(<<"hookCallbackIds">>, Matcher, [])),
    {CallbackIdsRev, CallbackMap} =
        build_hook_callback_ids(HooksValue, ExistingIds),
    CallbackIds = lists:reverse(CallbackIdsRev),
    Config0 =
        case
            maps:get(matcher, Matcher,
                     maps:get(<<"matcher">>, Matcher, undefined))
        of
            undefined ->
                #{};
            Value ->
                #{<<"matcher">> => normalize_hook_init_value(Value)}
        end,
    Config1 =
        case CallbackIds of
            [] ->
                Config0;
            _ ->
                Config0#{<<"hookCallbackIds">> => CallbackIds}
        end,
    Config2 =
        case
            maps:get(timeout, Matcher,
                     maps:get(<<"timeout">>, Matcher, undefined))
        of
            Timeout when is_integer(Timeout), Timeout > 0 ->
                Config1#{<<"timeout">> => Timeout};
            _ ->
                Config1
        end,
    case map_size(Config2) of
        0 ->
            skip;
        _ ->
            {Config2, CallbackMap}
    end;
build_cli_hook_matcher(_) ->
    skip.
-spec build_hook_callback_ids(term(), term()) ->
                                 {[binary()], #{binary() => fun()}}.
build_hook_callback_ids(HooksValue, ExistingIds0) ->
    ExistingIds =
        lists:foldl(fun(Id, Acc) ->
                           case normalize_callback_id(Id) of
                               NormalizedId
                                   when
                                       is_binary(NormalizedId),
                                       byte_size(NormalizedId) > 0 ->
                                   [NormalizedId | Acc];
                               _ ->
                                   Acc
                           end
                    end,
                    [],
                    normalize_list(ExistingIds0)),
    lists:foldl(fun(Hook, {IdsAcc, CallbackAcc}) ->
                       case Hook of
                           Fun
                               when
                                   is_function(Fun, 1);
                                   is_function(Fun, 3) ->
                               {CallbackId, Callback} =
                                   new_hook_callback(Fun),
                               {[CallbackId | IdsAcc],
                                CallbackAcc#{CallbackId => Callback}};
                           Id ->
                               case normalize_callback_id(Id) of
                                   NormalizedId
                                       when
                                           is_binary(NormalizedId),
                                           byte_size(NormalizedId) > 0 ->
                                       {[NormalizedId | IdsAcc],
                                        CallbackAcc};
                                   _ ->
                                       {IdsAcc, CallbackAcc}
                               end
                       end
                end,
                {ExistingIds, #{}},
                normalize_list(HooksValue)).
-spec normalize_callback_id(term()) -> binary() | term().
normalize_callback_id(Id) when is_binary(Id) ->
    Id;
normalize_callback_id(Id) when is_list(Id) ->
    unicode:characters_to_binary(Id);
normalize_callback_id(Id) ->
    Id.
-spec normalize_list(term()) -> [term()].
normalize_list(undefined) ->
    [];
normalize_list(null) ->
    [];
normalize_list(List) when is_list(List) ->
    List;
normalize_list(Value) ->
    [Value].
-spec new_hook_callback(fun()) -> {binary(), fun()}.
new_hook_callback(Callback) ->
    Id =
        <<"hook_",
          (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {Id, Callback}.
-spec hook_event_name(term()) -> binary().
hook_event_name(Name) when is_binary(Name) ->
    Name;
hook_event_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name);
hook_event_name(Name) when is_atom(Name) ->
    snake_to_pascal_binary(atom_to_list(Name));
hook_event_name(Name) ->
    unicode:characters_to_binary(io_lib:format("~p", [Name])).
-spec snake_to_pascal_binary(string()) -> binary().
snake_to_pascal_binary(Name) ->
    Parts = string:tokens(Name, "_"),
    iolist_to_binary([ 
                      capitalize_ascii(Part) ||
                          Part <- Parts,
                          Part =/= []
                     ]).
-spec capitalize_ascii([byte(), ...]) -> binary().
capitalize_ascii([H | T]) when H >= $a, H =< $z ->
    list_to_binary([H - 32 | T]);
capitalize_ascii(List) ->
    list_to_binary(List).
-spec handle_hook_callback(map(), #data{}) -> map().
handle_hook_callback(Request,
                     #data{hook_callbacks = HookCallbacks,
                           session_id = SessionId}) ->
    CallbackId =
        maps:get(<<"callback_id">>,
                 Request,
                 maps:get(callback_id, Request, undefined)),
    Input =
        maps:get(<<"input">>, Request, maps:get(input, Request, #{})),
    ToolUseId =
        maps:get(<<"tool_use_id">>,
                 Request,
                 maps:get(tool_use_id, Request, undefined)),
    Context =
        #{session_id => SessionId,
          signal => undefined,
          request => Request},
    case maps:get(CallbackId, HookCallbacks, undefined) of
        undefined ->
            logger:warning("Claude hook callback missing: ~p",
                           [CallbackId]),
            #{<<"decision">> => <<"block">>,
              <<"reason">> => <<"Hook callback not found">>};
        Callback ->
            try
                invoke_hook_callback(Callback, Input, ToolUseId,
                                     Context)
            of
                Result ->
                    normalize_hook_output(Result)
            catch
                Class:Reason:Stack ->
                    logger:error("hook callback crashed: ~p:~p~n~p",
                                 [Class, Reason, Stack]),
                    #{<<"decision">> => <<"block">>,
                      <<"reason">> => <<"Hook callback crashed">>}
            end
    end.
-spec invoke_hook_callback(fun(), term(), term(), map()) -> term().
invoke_hook_callback(Callback, Input, ToolUseId, Context)
    when is_function(Callback, 3) ->
    Callback(Input, ToolUseId, Context);
invoke_hook_callback(Callback, Input, ToolUseId, Context)
    when is_function(Callback, 1) ->
    Callback(Context#{input => Input, tool_use_id => ToolUseId});
invoke_hook_callback(Callback, _Input, _ToolUseId, _Context) ->
    Callback().
-spec normalize_hook_output(term()) -> map().
normalize_hook_output(ok) ->
    #{};
normalize_hook_output({ok, Map}) when is_map(Map) ->
    normalize_hook_map(Map, top);
normalize_hook_output({deny, Reason}) when is_binary(Reason) ->
    #{<<"decision">> => <<"block">>, <<"reason">> => Reason};
normalize_hook_output(Map) when is_map(Map) ->
    normalize_hook_map(Map, top);
normalize_hook_output(_) ->
    #{}.
-spec normalize_hook_map(map(), top | hook_specific | generic) -> map().
normalize_hook_map(Map, Kind) ->
    maps:fold(fun(Key, Value, Acc) ->
                     EncodedKey = normalize_hook_key(Key, Kind),
                     EncodedValue =
                         normalize_hook_value(EncodedKey, Value, Kind),
                     Acc#{EncodedKey => EncodedValue}
              end,
              #{},
              Map).
-spec normalize_hook_key(term(), top | hook_specific | generic) ->
                            binary().
normalize_hook_key(async_, top) ->
    <<"async">>;
normalize_hook_key(async, top) ->
    <<"async">>;
normalize_hook_key(continue_, top) ->
    <<"continue">>;
normalize_hook_key(continue, top) ->
    <<"continue">>;
normalize_hook_key(suppress_output, top) ->
    <<"suppressOutput">>;
normalize_hook_key(<<"suppressOutput">>, top) ->
    <<"suppressOutput">>;
normalize_hook_key(stop_reason, top) ->
    <<"stopReason">>;
normalize_hook_key(<<"stopReason">>, top) ->
    <<"stopReason">>;
normalize_hook_key(system_message, top) ->
    <<"systemMessage">>;
normalize_hook_key(<<"systemMessage">>, top) ->
    <<"systemMessage">>;
normalize_hook_key(hook_specific_output, top) ->
    <<"hookSpecificOutput">>;
normalize_hook_key(<<"hookSpecificOutput">>, top) ->
    <<"hookSpecificOutput">>;
normalize_hook_key(hook_event_name, hook_specific) ->
    <<"hookEventName">>;
normalize_hook_key(<<"hookEventName">>, hook_specific) ->
    <<"hookEventName">>;
normalize_hook_key(permission_decision, hook_specific) ->
    <<"permissionDecision">>;
normalize_hook_key(<<"permissionDecision">>, hook_specific) ->
    <<"permissionDecision">>;
normalize_hook_key(permission_decision_reason, hook_specific) ->
    <<"permissionDecisionReason">>;
normalize_hook_key(<<"permissionDecisionReason">>, hook_specific) ->
    <<"permissionDecisionReason">>;
normalize_hook_key(updated_input, hook_specific) ->
    <<"updatedInput">>;
normalize_hook_key(<<"updatedInput">>, hook_specific) ->
    <<"updatedInput">>;
normalize_hook_key(updated_permissions, hook_specific) ->
    <<"updatedPermissions">>;
normalize_hook_key(<<"updatedPermissions">>, hook_specific) ->
    <<"updatedPermissions">>;
normalize_hook_key(interrupt, hook_specific) ->
    <<"interrupt">>;
normalize_hook_key(<<"interrupt">>, hook_specific) ->
    <<"interrupt">>;
normalize_hook_key(additional_context, hook_specific) ->
    <<"additionalContext">>;
normalize_hook_key(<<"additionalContext">>, hook_specific) ->
    <<"additionalContext">>;
normalize_hook_key(updated_mcp_tool_output, hook_specific) ->
    <<"updatedMCPToolOutput">>;
normalize_hook_key(<<"updatedMCPToolOutput">>, hook_specific) ->
    <<"updatedMCPToolOutput">>;
normalize_hook_key(Key, _Kind) when is_binary(Key) ->
    Key;
normalize_hook_key(Key, _Kind) when is_atom(Key) ->
    atom_to_binary(Key);
normalize_hook_key(Key, _Kind) when is_list(Key) ->
    unicode:characters_to_binary(Key);
normalize_hook_key(Key, _Kind) ->
    unicode:characters_to_binary(io_lib:format("~p", [Key])).
-spec normalize_hook_value(binary(),
                           term(),
                           top | hook_specific | generic) ->
                              term().
normalize_hook_value(<<"hookSpecificOutput">>, Value, _Kind)
    when is_map(Value) ->
    normalize_hook_map(Value, hook_specific);
normalize_hook_value(_Key, Value, _Kind) ->
    normalize_hook_init_value(Value).
-spec normalize_hook_init_value(term()) -> term().
normalize_hook_init_value(Value) when is_map(Value) ->
    maps:fold(fun(Key, Inner, Acc) ->
                     NormalizedKey = normalize_hook_key(Key, generic),
                     Acc#{NormalizedKey =>
                              normalize_hook_init_value(Inner)}
              end,
              #{},
              Value);
normalize_hook_init_value(Value) when is_list(Value) ->
    case lists:all(fun erlang:is_integer/1, Value) of
        true ->
            unicode:characters_to_binary(Value);
        false ->
            [ 
             normalize_hook_init_value(Item) ||
                 Item <- Value
            ]
    end;
normalize_hook_init_value(Value)
    when is_atom(Value), Value =/= true, Value =/= false, Value =/= null ->
    atom_to_binary(Value);
normalize_hook_init_value(Value) ->
    Value.
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{session_id => Data#data.session_id,
      adapter => claude,
      backend => claude,
      system_info => Data#data.system_info,
      init_response => Data#data.init_response}.
-spec track_message(beam_agent_core:message(), #data{}) -> ok.
track_message(Msg, Data) ->
    SessionId = session_store_id(Data),
    ok =
        beam_agent_session_store_core:register_session(SessionId,
                                                  #{adapter => claude}),
    StoredMsg = maybe_tag_session_id(Msg, SessionId),
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            beam_agent_threads_core:record_thread_message(SessionId,
                                                     ThreadId,
                                                     StoredMsg);
        {error, none} ->
            beam_agent_session_store_core:record_message(SessionId,
                                                    StoredMsg)
    end,
    ok.
-spec session_store_id(#data{}) -> binary().
session_store_id(#data{session_id = SessionId})
    when is_binary(SessionId), byte_size(SessionId) > 0 ->
    SessionId;
session_store_id(_Data) ->
    unicode:characters_to_binary(pid_to_list(self())).
-spec maybe_tag_session_id(beam_agent_core:message(), binary()) ->
                              beam_agent_core:message().
maybe_tag_session_id(#{session_id := _} = Msg, _SessionId) ->
    Msg;
maybe_tag_session_id(Msg, SessionId) ->
    Msg#{session_id => SessionId}.
-spec encode_system_prompt(map()) -> map().
encode_system_prompt(#{type := preset, preset := Preset} = SP) ->
    Base = #{<<"type">> => <<"preset">>, <<"preset">> => Preset},
    case maps:get(append, SP, undefined) of
        undefined ->
            Base;
        Append ->
            Base#{<<"append">> => Append}
    end.
-spec encode_permission_mode(beam_agent_core:permission_mode()) -> binary().
encode_permission_mode(default) ->
    <<"default">>;
encode_permission_mode(accept_edits) ->
    <<"acceptEdits">>;
encode_permission_mode(bypass_permissions) ->
    <<"bypassPermissions">>;
encode_permission_mode(plan) ->
    <<"plan">>;
encode_permission_mode(dont_ask) ->
    <<"dontAsk">>.
-spec encode_value(term()) -> term().
encode_value(V) when is_atom(V), V =/= true, V =/= false, V =/= null ->
    atom_to_binary(V);
encode_value(V) ->
    V.
-spec maybe_put_defined(term(), term(), map()) -> map().
maybe_put_defined(_Key, undefined, Map) ->
    Map;
maybe_put_defined(Key, Value, Map) ->
    Map#{Key => Value}.
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
-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(claude, query, StartTime).
-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(claude, query, Reason).
