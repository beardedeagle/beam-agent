-module(opencode_session).
-behaviour(gen_statem).
-behaviour(beam_agent_behaviour).
-export([start_link/1,
         send_query/4,
         receive_message/3,
         subscribe_events/1,
         receive_event/3,
         unsubscribe_events/2,
         health/1,
         stop/1]).
-export([send_control/3,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2]).
-export([callback_mode/0,init/1,terminate/3]).
-export([connecting/3,initializing/3,ready/3,active_query/3,error/3]).
-type state_name() ::
          connecting | initializing | ready | active_query | error.
-type state_callback_result() ::
          gen_statem:state_enter_result(state_name()) |
          gen_statem:event_handler_result(state_name()).
-type rest_purpose() ::
          create_session | send_message | abort_query |
          permission_reply | app_info | app_init | app_log | app_modes |
          list_sessions | get_session | delete_session | config_read |
          config_update | config_providers | find_text | find_files |
          find_symbols | file_list | file_read | file_status |
          provider_list | provider_auth_methods |
          provider_oauth_authorize | provider_oauth_callback |
          list_commands | mcp_status | add_mcp_server | list_agents |
          revert_session | unrevert_session | share_session |
          unshare_session | summarize_session | session_init |
          session_messages | prompt_async | shell_command |
          tui_append_prompt | tui_open_help |
          send_command | server_health.
-export_type([state_name/0]).
-dialyzer({no_underspecs,
           [{post_json, 5},
            {patch_json, 5},
            {get_request, 3},
            {delete_request, 3},
            {build_sse_path, 1},
            {build_sse_headers, 1},
            {dispatch_sse_events, 2},
            {fire_hook, 3},
            {maybe_reply, 2},
            {build_summarize_body, 2}]}).
-dialyzer({no_extra_return, [{set_permission_mode, 2}]}).
-dialyzer({nowarn_function, [{handle_permission, 3}]}).
-record(data,{conn_pid :: pid() | undefined,
              conn_monitor :: reference() | undefined,
              sse_ref :: reference() | undefined,
              sse_state :: opencode_sse:parse_state(),
              rest_pending =
                  #{} ::
                      #{reference() =>
                            {rest_purpose(),
                             gen_statem:from() | undefined,
                             binary()}},
              consumer :: gen_statem:from() | undefined,
              event_consumer :: gen_statem:from() | undefined,
              query_ref :: reference() | undefined,
              event_ref :: reference() | undefined,
              msg_queue :: queue:queue() | undefined,
              event_queue :: queue:queue() | undefined,
              session_id :: binary() | undefined,
              directory :: binary(),
              opts :: map(),
              host :: binary(),
              port :: inet:port_number(),
              base_path = <<>> :: binary(),
              auth :: {basic, binary()} | none,
              model :: map() | undefined,
              buffer_max :: pos_integer(),
              permission_handler ::
                  fun((binary(), map(), map()) ->
                          beam_agent_core:permission_result()) |
                  undefined,
              sdk_mcp_registry ::
                  beam_agent_mcp_core:mcp_registry() | undefined,
              sdk_hook_registry ::
                  beam_agent_hooks_core:hook_registry() | undefined,
              query_start_time :: integer() | undefined}).
-spec start_link(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(opencode_session, Opts, []).
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
                    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).
-spec receive_message(pid(), reference(), timeout()) ->
                         {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

-spec subscribe_events(pid()) -> {ok, reference()}.
subscribe_events(Pid) ->
    gen_statem:call(Pid, subscribe_events, 5000).

-spec receive_event(pid(), reference(), timeout()) ->
                       {ok, beam_agent_core:message()} | {error, term()}.
receive_event(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_event, Ref}, Timeout).

-spec unsubscribe_events(pid(), reference()) -> ok | {error, term()}.
unsubscribe_events(Pid, Ref) ->
    gen_statem:call(Pid, {unsubscribe_events, Ref}, 5000).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).
-spec send_control(pid(), binary(), map()) -> {error, not_supported}.
send_control(_Pid, _Method, _Params) ->
    {error, not_supported}.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, abort, 10000).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(_Pid, _Mode) ->
    {error, not_supported}.
-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].
-spec init(map()) -> gen_statem:init_result(connecting) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    BaseUrl = maps:get(base_url, Opts, "http://localhost:4096"),
    Directory = maps:get(directory, Opts, <<".">>),
    BufferMax = maps:get(buffer_max, Opts, 2 * 1024 * 1024),
    Model = maps:get(model, Opts, undefined),
    PermissionHandler = maps:get(permission_handler, Opts, undefined),
    McpRegistry = build_mcp_registry(Opts),
    HookRegistry = build_hook_registry(Opts),
    Auth =
        case maps:get(auth, Opts, none) of
            none ->
                none;
            {basic, U, P} ->
                opencode_http:encode_basic_auth(U, P);
            {basic, Encoded} when is_binary(Encoded) ->
                {basic, Encoded}
        end,
    {Host, Port, BasePath} = opencode_http:parse_base_url(BaseUrl),
    case gun:open(binary_to_list(Host), Port, #{protocols => [http]}) of
        {ok, ConnPid} ->
            MonRef = monitor(process, ConnPid),
            Data =
                #data{conn_pid = ConnPid,
                      conn_monitor = MonRef,
                      sse_state = opencode_sse:new_state(),
                      opts = Opts,
                      host = Host,
                      port = Port,
                      base_path = BasePath,
                      auth = Auth,
                      directory = Directory,
                      buffer_max = BufferMax,
                      model = Model,
                      permission_handler = PermissionHandler,
                      sdk_mcp_registry = McpRegistry,
                      sdk_hook_registry = HookRegistry,
                      msg_queue = queue:new(),
                      event_queue = queue:new()},
            {ok, connecting, Data};
        {error, Reason} ->
            {stop, {gun_open_failed, Reason}}
    end.
-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{conn_pid = ConnPid} = Data) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  Data),
    close_gun(ConnPid),
    ok.
-spec connecting(gen_statem:event_type(), term(), #data{}) ->
                    state_callback_result().
connecting(enter, connecting, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, undefined, connecting),
    {keep_state_and_data, [{state_timeout, 15000, connect_timeout}]};
connecting(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, OldState, connecting),
    {keep_state_and_data, [{state_timeout, 15000, connect_timeout}]};
connecting(info,
           {gun_up, ConnPid, http},
           #data{conn_pid = ConnPid} = Data) ->
    SsePath = build_sse_path(Data),
    SseHeaders = build_sse_headers(Data),
    SseRef = gun:get(ConnPid, SsePath, SseHeaders),
    {keep_state, Data#data{sse_ref = SseRef}};
connecting(info,
           {gun_response, ConnPid, SseRef, nofin, 200, _Headers},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    {keep_state, Data};
connecting(info,
           {gun_response, ConnPid, SseRef, _IsFin, Status, _Headers},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = _Data) ->
    logger:error("OpenCode SSE stream got unexpected status ~p in conne"
                 "cting",
                 [Status]),
    {next_state, error, _Data, [{state_timeout, 60000, auto_stop}]};
connecting(info,
           {gun_data, ConnPid, SseRef, _IsFin, RawData},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = observe_sse_events(Events, Data#data{sse_state = NewSseState}),
            case check_server_connected(Events) of
                true ->
                    {next_state, initializing, Data1};
                false ->
                    {keep_state, Data1}
            end;
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in connecting"),
            {next_state, error, Data,
             [{state_timeout, 60000, auto_stop}]}
    end;
connecting(state_timeout, connect_timeout, Data) ->
    logger:error("OpenCode connection timed out"),
    {next_state, error, Data, [{state_timeout, 60000, auto_stop}]};
connecting(info,
           {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
           #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in connecting: ~p",
                 [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
connecting(info,
           {'DOWN', MonRef, process, ConnPid, Reason},
           #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in connecting: ~p",
                 [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
connecting({call, From}, subscribe_events, Data) ->
    {Ref, Data1} = subscribe_event_stream(Data),
    {keep_state, Data1, [{reply, From, {ok, Ref}}]};
connecting({call, From}, {receive_event, Ref}, #data{event_ref = Ref} = Data) ->
    try_deliver_event(From, Data);
connecting({call, From}, {receive_event, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
connecting({call, From}, {unsubscribe_events, Ref}, #data{event_ref = Ref} = Data) ->
    {keep_state, clear_event_subscription(Data), [{reply, From, ok}]};
connecting({call, From}, {unsubscribe_events, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
connecting(info, _UnexpectedMsg, _Data) ->
    keep_state_and_data;
connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};
connecting({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.
-spec initializing(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
initializing(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(opencode, OldState, initializing),
    Body = build_session_create_body(Data),
    Data1 =
        post_json(<<"/session">>, Body, create_session, undefined, Data),
    {keep_state, Data1};
initializing(info,
             {gun_response, ConnPid, Ref, nofin, _Status, _Headers},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, From, _}} ->
            Pending1 =
                maps:put(Ref, {create_session, From, <<>>}, Pending),
            {keep_state, Data#data{rest_pending = Pending1}};
        _ ->
            {keep_state, Data}
    end;
initializing(info,
             {gun_data, ConnPid, Ref, fin, Body},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, _From, Acc}} ->
            FullBody = <<Acc/binary,(iolist_to_binary(Body))/binary>>,
            Pending1 = maps:remove(Ref, Pending),
            Data1 = Data#data{rest_pending = Pending1},
            case json:decode(FullBody) of
                SessionMap when is_map(SessionMap) ->
                    SessionId =
                        maps:get(<<"id">>, SessionMap, undefined),
                    Data2 = Data1#data{session_id = SessionId},
                    _ = fire_hook(session_start,
                                  #{event => session_start,
                                    session_id => SessionId},
                                  Data2),
                    {next_state, ready, Data2};
                _ ->
                    logger:error("OpenCode: failed to decode session cr"
                                 "eate response"),
                    {next_state, error, Data1,
                     [{state_timeout, 60000, auto_stop}]}
            end;
        _ ->
            {keep_state, Data}
    end;
initializing(info,
             {gun_data, ConnPid, Ref, nofin, Body},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, From, Acc}} ->
            NewAcc = <<Acc/binary,(iolist_to_binary(Body))/binary>>,
            Pending1 =
                maps:put(Ref, {create_session, From, NewAcc}, Pending),
            {keep_state, Data#data{rest_pending = Pending1}};
        _ ->
            {keep_state, Data}
    end;
initializing(info,
             {gun_data, ConnPid, SseRef, _IsFin, RawData},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = observe_sse_events(Events, Data#data{sse_state = NewSseState}),
            {keep_state, Data1};
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in initializing"),
            {next_state, error, Data,
             [{state_timeout, 60000, auto_stop}]}
    end;
initializing(info,
             {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
             #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in initializing: ~p",
                 [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
initializing(info,
             {'DOWN', MonRef, process, ConnPid, Reason},
             #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in initializing: ~p",
                 [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
initializing({call, From}, subscribe_events, Data) ->
    {Ref, Data1} = subscribe_event_stream(Data),
    {keep_state, Data1, [{reply, From, {ok, Ref}}]};
initializing({call, From}, {receive_event, Ref}, #data{event_ref = Ref} = Data) ->
    try_deliver_event(From, Data);
initializing({call, From}, {receive_event, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
initializing({call, From}, {unsubscribe_events, Ref}, #data{event_ref = Ref} = Data) ->
    {keep_state, clear_event_subscription(Data), [{reply, From, ok}]};
initializing({call, From}, {unsubscribe_events, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};
initializing({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.
-spec ready(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
ready(enter, initializing, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, initializing, ready),
    keep_state_and_data;
ready(enter, active_query, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, active_query, ready),
    keep_state_and_data;
ready(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, OldState, ready),
    keep_state_and_data;
ready(info,
      {gun_data, ConnPid, SseRef, _IsFin, RawData},
      #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = observe_sse_events(Events, Data#data{sse_state = NewSseState}),
            {keep_state, Data1};
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in ready"),
            {next_state, error, Data,
             [{state_timeout, 60000, auto_stop}]}
    end;
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    HookCtx =
        #{event => user_prompt_submit,
          prompt => Prompt,
          params => Params},
    case fire_hook(user_prompt_submit, HookCtx, Data) of
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_send_query(From, Prompt, Params, Data)
    end;
ready({call, From}, subscribe_events, Data) ->
    {Ref, Data1} = subscribe_event_stream(Data),
    {keep_state, Data1, [{reply, From, {ok, Ref}}]};
ready({call, From}, {receive_event, Ref}, #data{event_ref = Ref} = Data) ->
    try_deliver_event(From, Data);
ready({call, From}, {receive_event, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
ready({call, From}, {unsubscribe_events, Ref}, #data{event_ref = Ref} = Data) ->
    {keep_state, clear_event_subscription(Data), [{reply, From, ok}]};
ready({call, From}, {unsubscribe_events, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
ready({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};
ready({call, From},
      {receive_message, Ref},
      #data{query_ref = Ref, msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state,
             Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state,
             Data#data{query_ref = undefined, msg_queue = undefined},
             [{reply, From, {error, complete}}]}
    end;
ready({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
ready({call, From}, app_info, Data) ->
    Data1 = get_request(<<"/app">>, {app_info, From}, Data),
    {keep_state, Data1};
ready({call, From}, app_init, Data) ->
    Data1 = post_json(<<"/app/init">>, #{}, app_init, From, Data),
    {keep_state, Data1};
ready({call, From}, {app_log, Body}, Data) when is_map(Body) ->
    Data1 = post_json(<<"/log">>, Body, app_log, From, Data),
    {keep_state, Data1};
ready({call, From}, app_modes, Data) ->
    Data1 = get_request(<<"/mode">>, {app_modes, From}, Data),
    {keep_state, Data1};
ready({call, From}, list_sessions, Data) ->
    Data1 = get_request(<<"/session">>, {list_sessions, From}, Data),
    {keep_state, Data1};
ready({call, From}, {get_session, Id}, Data) ->
    Path = <<"/session/",Id/binary>>,
    Data1 = get_request(Path, {get_session, From}, Data),
    {keep_state, Data1};
ready({call, From}, {delete_session, Id}, Data) ->
    Path = <<"/session/",Id/binary>>,
    Data1 = delete_request(Path, {delete_session, From}, Data),
    {keep_state, Data1};
ready({call, From}, config_read, Data) ->
    Data1 = get_request(<<"/config">>, {config_read, From}, Data),
    {keep_state, Data1};
ready({call, From}, {config_update, Body}, Data) when is_map(Body) ->
    Data1 = patch_json(<<"/config">>, Body, config_update, From, Data),
    {keep_state, Data1};
ready({call, From}, config_providers, Data) ->
    Data1 =
        get_request(<<"/config/providers">>,
                    {config_providers, From},
                    Data),
    {keep_state, Data1};
ready({call, From}, {find_text, Pattern}, Data) when is_binary(Pattern) ->
    Path = build_query_path(<<"/find">>, #{pattern => Pattern}),
    Data1 = get_request(Path, {find_text, From}, Data),
    {keep_state, Data1};
ready({call, From}, {find_files, Opts}, Data) when is_map(Opts) ->
    Path = build_query_path(<<"/find/file">>, Opts),
    Data1 = get_request(Path, {find_files, From}, Data),
    {keep_state, Data1};
ready({call, From}, {find_symbols, Query}, Data) when is_binary(Query) ->
    Path = build_query_path(<<"/find/symbol">>, #{query => Query}),
    Data1 = get_request(Path, {find_symbols, From}, Data),
    {keep_state, Data1};
ready({call, From}, {file_list, PathValue}, Data)
    when is_binary(PathValue) ->
    Path = build_query_path(<<"/file">>, #{path => PathValue}),
    Data1 = get_request(Path, {file_list, From}, Data),
    {keep_state, Data1};
ready({call, From}, {file_read, PathValue}, Data)
    when is_binary(PathValue) ->
    Path = build_query_path(<<"/file/content">>, #{path => PathValue}),
    Data1 = get_request(Path, {file_read, From}, Data),
    {keep_state, Data1};
ready({call, From}, file_status, Data) ->
    Data1 = get_request(<<"/file/status">>, {file_status, From}, Data),
    {keep_state, Data1};
ready({call, From}, provider_list, Data) ->
    Data1 = get_request(<<"/provider">>, {provider_list, From}, Data),
    {keep_state, Data1};
ready({call, From}, provider_auth_methods, Data) ->
    Data1 =
        get_request(<<"/provider/auth">>,
                    {provider_auth_methods, From},
                    Data),
    {keep_state, Data1};
ready({call, From}, {provider_oauth_authorize, ProviderId, Body}, Data)
    when is_binary(ProviderId), is_map(Body) ->
    Path = <<"/provider/",ProviderId/binary,"/oauth/authorize">>,
    Data1 = post_json(Path, Body, provider_oauth_authorize, From, Data),
    {keep_state, Data1};
ready({call, From}, {provider_oauth_callback, ProviderId, Body}, Data)
    when is_binary(ProviderId), is_map(Body) ->
    Path = <<"/provider/",ProviderId/binary,"/oauth/callback">>,
    Data1 = post_json(Path, Body, provider_oauth_callback, From, Data),
    {keep_state, Data1};
ready({call, From}, list_commands, Data) ->
    Data1 = get_request(<<"/command">>, {list_commands, From}, Data),
    {keep_state, Data1};
ready({call, From}, mcp_status, Data) ->
    Data1 = get_request(<<"/mcp">>, {mcp_status, From}, Data),
    {keep_state, Data1};
ready({call, From}, {add_mcp_server, Body}, Data) when is_map(Body) ->
    Data1 = post_json(<<"/mcp">>, Body, add_mcp_server, From, Data),
    {keep_state, Data1};
ready({call, From}, list_agents, Data) ->
    Data1 = get_request(<<"/agent">>, {list_agents, From}, Data),
    {keep_state, Data1};
ready({call, From},
      {revert_session, Selector},
      #data{session_id = SessionId} = Data) ->
    case build_revert_body(Selector) of
        {ok, Body} ->
            Path = <<"/session/",SessionId/binary,"/revert">>,
            Data1 = post_json(Path, Body, revert_session, From, Data),
            {keep_state, Data1};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;
ready({call, From},
      unrevert_session,
      #data{session_id = SessionId} = Data) ->
    Path = <<"/session/",SessionId/binary,"/unrevert">>,
    Data1 = post_json(Path, #{}, unrevert_session, From, Data),
    {keep_state, Data1};
ready({call, From}, share_session, #data{session_id = SessionId} = Data) ->
    Path = <<"/session/",SessionId/binary,"/share">>,
    Data1 = post_json(Path, #{}, share_session, From, Data),
    {keep_state, Data1};
ready({call, From},
      unshare_session,
      #data{session_id = SessionId} = Data) ->
    Path = <<"/session/",SessionId/binary,"/share">>,
    Data1 = delete_request(Path, {unshare_session, From}, Data),
    {keep_state, Data1};
ready({call, From},
      {summarize_session, Opts},
      #data{session_id = SessionId, model = Model} = Data) ->
    case build_summarize_body(Opts, Model) of
        {ok, Body} ->
            Path = <<"/session/",SessionId/binary,"/summarize">>,
            Data1 = post_json(Path, Body, summarize_session, From, Data),
            {keep_state, Data1};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;
ready({call, From},
      {session_init, Opts},
      #data{session_id = SessionId, opts = SessionOpts} = Data)
    when is_binary(SessionId), is_map(Opts) ->
    case
        opencode_protocol:build_session_init_input(maps:merge(SessionOpts,
                                                              Opts))
    of
        {ok, Body} ->
            Path = <<"/session/",SessionId/binary,"/init">>,
            Data1 = post_json(Path, Body, session_init, From, Data),
            {keep_state, Data1};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;
ready({call, From},
      session_messages,
      #data{session_id = SessionId} = Data)
    when is_binary(SessionId) ->
    Path = <<"/session/",SessionId/binary,"/message">>,
    Data1 = get_request(Path, {session_messages, From}, Data),
    {keep_state, Data1};
ready({call, From},
      {session_messages, Opts},
      #data{session_id = SessionId} = Data)
    when is_binary(SessionId), is_map(Opts) ->
    Path0 = <<"/session/",SessionId/binary,"/message">>,
    Path = build_query_path(Path0, Opts),
    Data1 = get_request(Path, {session_messages, From}, Data),
    {keep_state, Data1};
ready({call, From},
      {prompt_async, Prompt, Params},
      #data{session_id = SessionId, opts = SessionOpts} = Data)
    when is_binary(SessionId), is_binary(Prompt), is_map(Params) ->
    Path = <<"/session/",SessionId/binary,"/prompt_async">>,
    Body =
        opencode_protocol:build_prompt_input(Prompt,
                                             merge_query_defaults(Params,
                                                                  SessionOpts)),
    Data1 = post_json(Path, Body, prompt_async, From, Data),
    {keep_state, Data1};
ready({call, From},
      {shell_command, Command, Opts},
      #data{session_id = SessionId, opts = SessionOpts} = Data)
    when is_binary(SessionId), is_binary(Command), is_map(Opts) ->
    case
        opencode_protocol:build_shell_input(Command,
                                            maps:merge(SessionOpts,
                                                       Opts))
    of
        {ok, Body} ->
            Path = <<"/session/",SessionId/binary,"/shell">>,
            Data1 = post_json(Path, Body, shell_command, From, Data),
            {keep_state, Data1};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;
ready({call, From}, {tui_append_prompt, Text}, Data)
    when is_binary(Text) ->
    Data1 =
        post_json(<<"/tui/append-prompt">>,
                  #{<<"text">> => Text},
                  tui_append_prompt,
                  From,
                  Data),
    {keep_state, Data1};
ready({call, From}, tui_open_help, Data) ->
    Data1 = post_json(<<"/tui/open-help">>, #{}, tui_open_help, From, Data),
    {keep_state, Data1};
ready({call, From}, {send_command, Command, Params}, Data) ->
    SessionId = Data#data.session_id,
    Path = <<"/session/",SessionId/binary,"/command">>,
    Body = Params#{<<"command">> => Command},
    Data1 = post_json(Path, Body, send_command, From, Data),
    {keep_state, Data1};
ready({call, From}, server_health, Data) ->
    Data1 = get_request(<<"/health">>, {server_health, From}, Data),
    {keep_state, Data1};
ready(info,
      {gun_response, ConnPid, Ref, IsFin, Status, _Headers},
      #data{conn_pid = ConnPid} = Data) ->
    handle_rest_response_headers(Ref, IsFin, Status, Data);
ready(info,
      {gun_data, ConnPid, Ref, IsFin, Body},
      #data{conn_pid = ConnPid} = Data) ->
    handle_rest_body(Ref, IsFin, Body, Data);
ready(info,
      {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
      #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in ready: ~p", [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
ready(info,
      {'DOWN', MonRef, process, ConnPid, Reason},
      #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in ready: ~p", [Reason]),
    {next_state, error,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
ready(info, _UnexpectedMsg, _Data) ->
    keep_state_and_data;
ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.
-spec active_query(gen_statem:event_type(), term(), #data{}) ->
                      state_callback_result().
active_query(enter, ready, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, ready, active_query),
    keep_state_and_data;
active_query(enter, OldState, _Data) ->
    beam_agent_telemetry_core:state_change(opencode, OldState, active_query),
    keep_state_and_data;
active_query(info,
             {gun_data, ConnPid, SseRef, _IsFin, RawData},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = Data#data{sse_state = NewSseState},
            dispatch_sse_events(Events, Data1);
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in active_query"),
            ErrMsg =
                #{type => error,
                  content => <<"SSE buffer overflow">>,
                  subtype => <<"buffer_overflow">>},
            Q1 = queue:in(ErrMsg, Data#data.msg_queue),
            {next_state, error,
             Data#data{msg_queue = Q1},
             [{state_timeout, 60000, auto_stop}]}
    end;
active_query(info,
             {gun_response, ConnPid, Ref, IsFin, Status, _Headers},
             #data{conn_pid = ConnPid} = Data) ->
    handle_rest_response_headers(Ref, IsFin, Status, Data);
active_query(info,
             {gun_data, ConnPid, Ref, IsFin, Body},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data)
    when Ref =/= SseRef ->
    handle_rest_body(Ref, IsFin, Body, Data);
active_query({call, From},
             {receive_message, Ref},
             #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, subscribe_events, Data) ->
    {Ref, Data1} = subscribe_event_stream(Data),
    {keep_state, Data1, [{reply, From, {ok, Ref}}]};
active_query({call, From}, {receive_event, Ref}, #data{event_ref = Ref} = Data) ->
    try_deliver_event(From, Data);
active_query({call, From}, {receive_event, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, {unsubscribe_events, Ref}, #data{event_ref = Ref} = Data) ->
    {keep_state, clear_event_subscription(Data), [{reply, From, ok}]};
active_query({call, From}, {unsubscribe_events, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From}, abort, Data) ->
    Data1 = do_abort(Data),
    {keep_state, Data1, [{reply, From, ok}]};
active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};
active_query({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
active_query({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};
active_query(info,
             {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
             #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in active_query: ~p",
                 [Reason]),
    maybe_span_exception(Data, {gun_down, Reason}),
    ErrorMsg =
        #{type => error,
          content => <<"connection lost">>,
          timestamp => erlang:system_time(millisecond)},
    Data1 =
        Data#data{conn_pid = undefined,
                  sse_ref = undefined,
                  query_start_time = undefined},
    deliver_or_enqueue(ErrorMsg, Data1,
                       fun(D) ->
                              {next_state, error,
                               D#data{consumer = undefined,
                                      query_ref = undefined},
                               [{state_timeout, 60000, auto_stop}]}
                       end);
active_query(info,
             {'DOWN', MonRef, process, ConnPid, Reason},
             #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in active_query: ~p",
                 [Reason]),
    maybe_span_exception(Data, {gun_crash, Reason}),
    ErrorMsg =
        #{type => error,
          content => <<"gun process crashed">>,
          timestamp => erlang:system_time(millisecond)},
    Data1 =
        Data#data{conn_pid = undefined,
                  sse_ref = undefined,
                  query_start_time = undefined},
    deliver_or_enqueue(ErrorMsg, Data1,
                       fun(D) ->
                              {next_state, error,
                               D#data{consumer = undefined,
                                      query_ref = undefined},
                               [{state_timeout, 60000, auto_stop}]}
                       end);
active_query(info, _UnexpectedMsg, _Data) ->
    keep_state_and_data;
active_query({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.
-spec error(gen_statem:event_type(), term(), #data{}) ->
               state_callback_result().
error(enter, OldState, Data) ->
    beam_agent_telemetry_core:state_change(opencode, OldState, error),
    close_gun(Data#data.conn_pid),
    {keep_state,
     Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, 60000, auto_stop}]};
error(state_timeout, auto_stop, _Data) ->
    {stop, normal};
error({call, From}, subscribe_events, Data) ->
    {Ref, Data1} = subscribe_event_stream(Data),
    {keep_state, Data1, [{reply, From, {ok, Ref}}]};
error({call, From}, {receive_event, Ref}, #data{event_ref = Ref} = Data) ->
    try_deliver_event(From, Data);
error({call, From}, {receive_event, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
error({call, From}, {unsubscribe_events, Ref}, #data{event_ref = Ref} = Data) ->
    {keep_state, clear_event_subscription(Data), [{reply, From, ok}]};
error({call, From}, {unsubscribe_events, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};
error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.
-spec do_send_query(gen_statem:from(), binary(), map(), #data{}) ->
                       state_callback_result().
do_send_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime =
        beam_agent_telemetry_core:span_start(opencode, query,
                                        #{prompt => Prompt}),
    SessionId = Data#data.session_id,
    Path = <<"/session/",SessionId/binary,"/message">>,
    MergedOpts0 =
        case Data#data.model of
            undefined ->
                Params;
            Model ->
                maps:put(model, Model, Params)
        end,
    MergedOpts = merge_query_defaults(MergedOpts0, Data#data.opts),
    Body = opencode_protocol:build_prompt_input(Prompt, MergedOpts),
    Data1 =
        Data#data{consumer = From,
                  query_ref = Ref,
                  msg_queue = queue:new(),
                  query_start_time = StartTime},
    Data2 = post_json(Path, Body, send_message, undefined, Data1),
    {next_state, active_query, Data2, [{reply, From, {ok, Ref}}]}.
-spec do_abort(#data{}) -> #data{}.
do_abort(#data{session_id = SessionId} = Data)
    when SessionId =/= undefined ->
    Path = <<"/session/",SessionId/binary,"/abort">>,
    post_json(Path, #{}, abort_query, undefined, Data);
do_abort(Data) ->
    Data.
-spec check_server_connected([opencode_sse:sse_event()]) -> boolean().
check_server_connected([]) ->
    false;
check_server_connected([#{event := <<"server.connected">>} | _]) ->
    true;
check_server_connected([_ | Rest]) ->
    check_server_connected(Rest).

-spec observe_sse_events([opencode_sse:sse_event()], #data{}) -> #data{}.
observe_sse_events([], Data) ->
    Data;
observe_sse_events([SseEvent | Rest], Data) ->
    Data1 =
        case normalize_sse_event(SseEvent) of
            skip ->
                Data;
            #{type := control_request,
              request_id := PermId,
              request := Meta} = Msg ->
                handle_permission(PermId, Meta, enqueue_event(Msg, Data));
            Msg ->
                enqueue_event(Msg, Data)
        end,
    observe_sse_events(Rest, Data1).

-spec normalize_sse_event(opencode_sse:sse_event()) ->
                             beam_agent_core:message() | skip.
normalize_sse_event(SseEvent) ->
    RawData = maps:get(data, SseEvent, <<>>),
    Payload =
        case RawData of
            <<>> ->
                #{};
            Json ->
                try
                    json:decode(Json)
                catch
                    _:_ ->
                        #{}
                end
        end,
    opencode_protocol:normalize_event(SseEvent#{data => Payload}).

-spec dispatch_sse_events([opencode_sse:sse_event()], #data{}) ->
                             state_callback_result().
dispatch_sse_events([], Data) ->
    {keep_state, Data};
dispatch_sse_events([SseEvent | Rest], Data) ->
    case normalize_sse_event(SseEvent) of
        skip ->
            dispatch_sse_events(Rest, Data);
        #{type := control_request,
          request_id := PermId,
          request := Meta} = Msg ->
            Data1 = handle_permission(PermId, Meta, enqueue_event(Msg, Data)),
            dispatch_sse_events(Rest, Data1);
        #{type := result} = ResultMsg ->
            maybe_span_stop(Data),
            _ = fire_hook(stop,
                          #{event => stop, stop_reason => idle},
                          Data),
            Data1 = enqueue_event(ResultMsg, Data),
            deliver_or_enqueue(ResultMsg, Data1,
                               fun(D) ->
                                      {next_state, ready,
                                       D#data{consumer = undefined,
                                              query_start_time =
                                                  undefined}}
                               end);
        #{type := error} = ErrMsg ->
            maybe_span_exception(Data, session_error),
            Data1 = enqueue_event(ErrMsg, Data),
            deliver_or_enqueue(ErrMsg, Data1,
                               fun(D) ->
                                      {next_state, ready,
                                       D#data{consumer = undefined,
                                              query_start_time =
                                                  undefined}}
                               end);
        Msg ->
            Data1 = enqueue_event(Msg, Data),
            deliver_or_enqueue(Msg, Data1,
                               fun(D) ->
                                      dispatch_sse_events(Rest, D)
                               end)
    end.
-spec handle_permission(binary(), map(), #data{}) -> #data{}.
handle_permission(PermId, Metadata, Data) ->
    Decision =
        case Data#data.permission_handler of
            undefined ->
                <<"deny">>;
            Handler ->
                try Handler(PermId, Metadata, #{}) of
                    {allow, _} ->
                        <<"allow">>;
                    {allow, _, _} ->
                        <<"allow">>;
                    {deny, _} ->
                        <<"deny">>;
                    _Other ->
                        <<"deny">>
                catch
                    _:_ ->
                        <<"deny">>
                end
        end,
    Body = opencode_protocol:build_permission_reply(PermId, Decision),
    Path = <<"/permission/",PermId/binary,"/reply">>,
    post_json(Path, Body, permission_reply, undefined, Data).
-spec post_json(binary(),
                map(),
                rest_purpose(),
                gen_statem:from() | undefined,
                #data{}) ->
                   #data{}.
post_json(EndpointPath, Body, Purpose, From, Data) ->
    FullPath =
        opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers =
        opencode_http:common_headers(Data#data.auth,
                                     Data#data.directory),
    Encoded = json:encode(Body),
    Ref =
        gun:post(Data#data.conn_pid,
                 binary_to_list(FullPath),
                 Headers, Encoded),
    Pending =
        maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.
-spec patch_json(binary(),
                 map(),
                 rest_purpose(),
                 gen_statem:from() | undefined,
                 #data{}) ->
                    #data{}.
patch_json(EndpointPath, Body, Purpose, From, Data) ->
    FullPath =
        opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers =
        opencode_http:common_headers(Data#data.auth,
                                     Data#data.directory),
    Encoded = json:encode(Body),
    Ref =
        gun:patch(Data#data.conn_pid,
                  binary_to_list(FullPath),
                  Headers, Encoded),
    Pending =
        maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.
-spec get_request(binary(),
                  {rest_purpose(), gen_statem:from()},
                  #data{}) ->
                     #data{}.
get_request(EndpointPath, {Purpose, From}, Data) ->
    FullPath =
        opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers =
        opencode_http:common_headers(Data#data.auth,
                                     Data#data.directory),
    Ref = gun:get(Data#data.conn_pid, binary_to_list(FullPath), Headers),
    Pending =
        maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.
-spec delete_request(binary(),
                     {rest_purpose(), gen_statem:from()},
                     #data{}) ->
                        #data{}.
delete_request(EndpointPath, {Purpose, From}, Data) ->
    FullPath =
        opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers =
        opencode_http:common_headers(Data#data.auth,
                                     Data#data.directory),
    Ref =
        gun:delete(Data#data.conn_pid,
                   binary_to_list(FullPath),
                   Headers),
    Pending =
        maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.
-spec build_query_path(binary(), map()) -> binary().
build_query_path(EndpointPath, Query) when is_map(Query) ->
    Pairs =
        [ 
         {normalize_query_key(Key), normalize_query_value(Value)} ||
             {Key, Value} <- maps:to_list(Query),
             Value =/= undefined,
             Value =/= null
        ],
    case Pairs of
        [] ->
            EndpointPath;
        _ ->
            QueryString =
                unicode:characters_to_binary(uri_string:compose_query(Pairs)),
            <<EndpointPath/binary,"?",QueryString/binary>>
    end.
-spec normalize_query_key(term()) -> unicode:chardata().
normalize_query_key(Key) when is_atom(Key) ->
    atom_to_list(Key);
normalize_query_key(Key) when is_binary(Key) ->
    binary_to_list(Key);
normalize_query_key(Key) when is_list(Key) ->
    Key;
normalize_query_key(Key) ->
    binary_to_list(iolist_to_binary(io_lib:format("~p", [Key]))).
-spec normalize_query_value(term()) -> unicode:chardata().
normalize_query_value(true) ->
    "true";
normalize_query_value(false) ->
    "false";
normalize_query_value(Value) when is_integer(Value) ->
    integer_to_list(Value);
normalize_query_value(Value) when is_float(Value) ->
    binary_to_list(iolist_to_binary(io_lib:format("~g", [Value])));
normalize_query_value(Value) when is_atom(Value) ->
    atom_to_list(Value);
normalize_query_value(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_query_value(Value) when is_list(Value) ->
    Value;
normalize_query_value(Value) ->
    binary_to_list(iolist_to_binary(io_lib:format("~p", [Value]))).
-spec handle_rest_response_headers(reference(),
                                   fin | nofin,
                                   integer(),
                                   #data{}) ->
                                      state_callback_result().
handle_rest_response_headers(Ref, IsFin, _Status,
                             #data{rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        error ->
            {keep_state, Data};
        {ok, {Purpose, From, Acc}} ->
            case IsFin of
                fin ->
                    Pending1 = maps:remove(Ref, Pending),
                    handle_rest_complete(Purpose, From, Acc,
                                         Data#data{rest_pending =
                                                       Pending1});
                nofin ->
                    {keep_state, Data}
            end
    end.
-spec handle_rest_body(reference(), fin | nofin, iodata(), #data{}) ->
                          state_callback_result().
handle_rest_body(Ref, IsFin, Body, #data{rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        error ->
            {keep_state, Data};
        {ok, {Purpose, From, Acc}} ->
            NewAcc = <<Acc/binary,(iolist_to_binary(Body))/binary>>,
            case IsFin of
                nofin ->
                    Pending1 =
                        maps:put(Ref, {Purpose, From, NewAcc}, Pending),
                    {keep_state, Data#data{rest_pending = Pending1}};
                fin ->
                    Pending1 = maps:remove(Ref, Pending),
                    handle_rest_complete(Purpose, From, NewAcc,
                                         Data#data{rest_pending =
                                                       Pending1})
            end
    end.
-spec handle_rest_complete(rest_purpose(),
                           gen_statem:from() | undefined,
                           binary(),
                           #data{}) ->
                              state_callback_result().
handle_rest_complete(create_session, _From, Body, Data) ->
    case json:decode(Body) of
        SessionMap when is_map(SessionMap) ->
            SessionId =
                maps:get(<<"id">>, SessionMap, Data#data.session_id),
            {keep_state, Data#data{session_id = SessionId}};
        _ ->
            {keep_state, Data}
    end;
handle_rest_complete(send_message, _From, _Body, Data) ->
    {keep_state, Data};
handle_rest_complete(abort_query, _From, _Body, Data) ->
    {keep_state, Data};
handle_rest_complete(permission_reply, _From, _Body, Data) ->
    {keep_state, Data};
handle_rest_complete(app_info, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(app_init, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(app_log, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(app_modes, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(list_sessions, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(get_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(delete_session, From, _Body, Data) ->
    maybe_reply(From, {ok, deleted}),
    {keep_state, Data};
handle_rest_complete(config_read, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(config_update, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(config_providers, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(find_text, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(find_files, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(find_symbols, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(file_list, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(file_read, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(file_status, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(provider_list, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(provider_auth_methods, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(provider_oauth_authorize, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(provider_oauth_callback, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(list_commands, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(mcp_status, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(add_mcp_server, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(list_agents, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(revert_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(unrevert_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(share_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(unshare_session, From, _Body, Data) ->
    maybe_reply(From, {ok, deleted}),
    {keep_state, Data};
handle_rest_complete(summarize_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(session_init, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(session_messages, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(prompt_async, From, _Body, Data) ->
    maybe_reply(From, {ok, accepted}),
    {keep_state, Data};
handle_rest_complete(shell_command, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(tui_append_prompt, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(tui_open_help, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(send_command, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};
handle_rest_complete(server_health, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data}.
-spec decode_json_result(binary()) ->
                            {ok, term()} | {error, decode_failed}.
decode_json_result(<<>>) ->
    {ok, #{}};
decode_json_result(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        _:_ ->
            {error, decode_failed}
    end.
-spec maybe_reply(gen_statem:from() | undefined, term()) -> ok.
maybe_reply(undefined, _Result) ->
    ok;
maybe_reply(From, Result) ->
    gen_statem:reply(From, Result).
-spec build_revert_body(map()) ->
                           {ok, map()} | {error, invalid_selector}.
build_revert_body(Selector) when is_map(Selector) ->
    MessageId =
        maps:get(message_id, Selector,
                 maps:get(messageID, Selector,
                          maps:get(uuid, Selector, undefined))),
    case MessageId of
        MessageIdBin when is_binary(MessageIdBin) ->
            Body0 = #{<<"messageID">> => MessageIdBin},
            Body1 =
                case
                    maps:get(part_id, Selector,
                             maps:get(partID, Selector, undefined))
                of
                    PartId when is_binary(PartId) ->
                        Body0#{<<"partID">> => PartId};
                    _ ->
                        Body0
                end,
            {ok, Body1};
        _ ->
            {error, invalid_selector}
    end;
build_revert_body(_) ->
    {error, invalid_selector}.
-spec build_summarize_body(map(), map() | undefined) ->
                              {ok, map()} |
                              {error, invalid_summary_opts}.
build_summarize_body(Opts, Model) when is_map(Opts) ->
    ModelId =
        maps:get(model_id, Opts,
                 maps:get(modelID, Opts, extract_model_id(Model))),
    ProviderId =
        maps:get(provider_id, Opts,
                 maps:get(providerID, Opts, extract_provider_id(Model))),
    case {ModelId, ProviderId} of
        {ModelIdBin, ProviderIdBin}
            when is_binary(ModelIdBin), is_binary(ProviderIdBin) ->
            Body0 =
                #{<<"modelID">> => ModelIdBin,
                  <<"providerID">> => ProviderIdBin},
            Body1 =
                case
                    maps:get(message_id, Opts,
                             maps:get(messageID, Opts, undefined))
                of
                    MessageId when is_binary(MessageId) ->
                        Body0#{<<"messageID">> => MessageId};
                    _ ->
                        Body0
                end,
            {ok, Body1};
        _ ->
            {error, invalid_summary_opts}
    end.
-spec extract_model_id(map() | undefined) -> binary() | undefined.
extract_model_id(#{<<"id">> := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(#{id := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(#{<<"modelID">> := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(_) ->
    undefined.
-spec extract_provider_id(map() | undefined) -> binary() | undefined.
extract_provider_id(#{<<"providerID">> := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(#{provider_id := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(#{providerID := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(_) ->
    undefined.
-spec try_deliver_message(gen_statem:from(), #data{}) ->
                             state_callback_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state,
             Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state, Data#data{consumer = From}}
    end.

-spec try_deliver_event(gen_statem:from(), #data{}) -> state_callback_result().
try_deliver_event(From, #data{event_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state,
             Data#data{event_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state, Data#data{event_consumer = From}}
    end.

-spec subscribe_event_stream(#data{}) -> {reference(), #data{}}.
subscribe_event_stream(Data) ->
    Ref = make_ref(),
    {Ref,
     Data#data{event_ref = Ref,
               event_consumer = undefined,
               event_queue = queue:new()}}.

-spec clear_event_subscription(#data{}) -> #data{}.
clear_event_subscription(Data) ->
    Data#data{event_ref = undefined,
              event_consumer = undefined,
              event_queue = queue:new()}.

-spec enqueue_event(beam_agent_core:message(), #data{}) -> #data{}.
enqueue_event(_Msg, #data{event_ref = undefined} = Data) ->
    Data;
enqueue_event(Msg, #data{event_consumer = undefined, event_queue = Q} = Data) ->
    Data#data{event_queue = queue:in(Msg, Q)};
enqueue_event(Msg, #data{event_consumer = From} = Data) ->
    gen_statem:reply(From, {ok, Msg}),
    Data#data{event_consumer = undefined}.

-spec deliver_or_enqueue(beam_agent_core:message(),
                         #data{},
                         fun((#data{}) -> state_callback_result())) ->
                            state_callback_result().
deliver_or_enqueue(Msg,
                   #data{consumer = undefined, msg_queue = Q} = Data,
                   Continue) ->
    _ = track_message(Msg, Data),
    Q1 = queue:in(Msg, Q),
    Continue(Data#data{msg_queue = Q1});
deliver_or_enqueue(Msg, #data{consumer = From} = Data, Continue) ->
    _ = track_message(Msg, Data),
    Data1 = Data#data{consumer = undefined},
    case Continue(Data1) of
        {next_state, NewState, NewData} ->
            {next_state, NewState, NewData, [{reply, From, {ok, Msg}}]};
        {next_state, NewState, NewData, Actions} ->
            {next_state, NewState, NewData,
             [{reply, From, {ok, Msg}} | Actions]};
        {keep_state, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}}]};
        {keep_state, NewData, Actions} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}} | Actions]}
    end.
-spec fire_hook(beam_agent_hooks_core:hook_event(),
                beam_agent_hooks_core:hook_context(),
                #data{}) ->
                   ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    beam_agent_hooks_core:fire(Event, Context, Registry).
-spec build_sse_path(#data{}) -> string().
build_sse_path(#data{base_path = Base}) ->
    binary_to_list(<<Base/binary,"/event">>).
-spec build_sse_headers(#data{}) -> [{binary(), binary()}].
build_sse_headers(#data{auth = Auth, directory = Dir}) ->
    [{<<"accept">>, <<"text/event-stream">>},
     {<<"cache-control">>, <<"no-cache">>},
     {<<"x-opencode-directory">>, Dir} |
     opencode_http:auth_headers(Auth)].
-spec build_session_create_body(#data{}) -> map().
build_session_create_body(#data{opts = Opts, directory = Dir}) ->
    Base = #{<<"directory">> => Dir},
    case maps:get(model, Opts, undefined) of
        undefined ->
            Base;
        Model when is_map(Model) ->
            Base#{<<"model">> => Model};
        Model when is_binary(Model) ->
            Base#{<<"model">> => Model};
        _ ->
            Base
    end.
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{session_id => Data#data.session_id,
      adapter => opencode,
      backend => opencode,
      directory => Data#data.directory,
      model => Data#data.model,
      provider_id => maps:get(provider_id, Data#data.opts, undefined),
      model_id => maps:get(model_id, Data#data.opts, undefined),
      agent => maps:get(agent, Data#data.opts, undefined),
      host => Data#data.host,
      port => Data#data.port,
      transport => http}.
-spec merge_query_defaults(map(), map()) -> map().
merge_query_defaults(Params, Opts) ->
    Defaults =
        [{provider_id, maps:get(provider_id, Opts, undefined)},
         {model_id, maps:get(model_id, Opts, undefined)},
         {mode, maps:get(mode, Opts, undefined)},
         {agent, maps:get(agent, Opts, undefined)},
         {system,
          maps:get(system, Opts,
                   maps:get(system_prompt, Opts, undefined))},
         {tools, maps:get(tools, Opts, undefined)}],
    lists:foldl(fun({_Key, undefined}, Acc) ->
                       Acc;
                   ({Key, Value}, Acc) ->
                       case maps:is_key(Key, Acc) of
                           true ->
                               Acc;
                           false ->
                               Acc#{Key => Value}
                       end
                end,
                Params, Defaults).
-spec track_message(beam_agent_core:message(), #data{}) -> ok.
track_message(Msg, Data) ->
    SessionId = session_store_id(Data),
    ok =
        beam_agent_session_store_core:register_session(SessionId,
                                                  #{adapter => opencode}),
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
-spec safe_parse_sse(binary(), #data{}) ->
                        {ok,
                         [opencode_sse:sse_event()],
                         opencode_sse:parse_state()} |
                        {error, buffer_overflow}.
safe_parse_sse(Bin, #data{sse_state = SseState, buffer_max = BufferMax}) ->
    CurrentSize = opencode_sse:buffer_size(SseState),
    IncomingSize = byte_size(Bin),
    case CurrentSize + IncomingSize > BufferMax of
        true ->
            beam_agent_telemetry_core:buffer_overflow(CurrentSize
                                                 +
                                                 IncomingSize,
                                                 BufferMax),
            {error, buffer_overflow};
        false ->
            {Events, NewState} = opencode_sse:parse_chunk(Bin, SseState),
            {ok, Events, NewState}
    end.
-spec close_gun(pid() | undefined) -> ok.
close_gun(undefined) ->
    ok;
close_gun(ConnPid) ->
    try
        gun:close(ConnPid)
    catch
        _:_ ->
            ok
    end,
    ok.
-spec build_mcp_registry(map()) ->
                            beam_agent_mcp_core:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    beam_agent_mcp_core:build_registry(maps:get(sdk_mcp_servers, Opts,
                                           undefined)).
-spec build_hook_registry(map()) ->
                             beam_agent_hooks_core:hook_registry() |
                             undefined.
build_hook_registry(Opts) ->
    beam_agent_hooks_core:build_registry(maps:get(sdk_hooks, Opts, undefined)).
-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(opencode, query, StartTime).
-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    beam_agent_telemetry_core:span_exception(opencode, query, Reason).
