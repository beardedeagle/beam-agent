-module(gemini_cli_client).
-dialyzer({no_underspecs,
           [{fork_session, 2},
            {revert_session, 2},
            {unrevert_session, 1},
            {share_session, 1},
            {share_session, 2},
            {summarize_session, 1},
            {summarize_session, 2},
            {thread_start, 2},
            {thread_resume, 2},
            {thread_list, 1},
            {thread_fork, 2},
            {thread_fork, 3},
            {thread_read, 2},
            {thread_read, 3},
            {thread_archive, 2},
            {thread_unarchive, 2},
            {thread_rollback, 3},
            {mcp_server_status, 1},
            {set_max_thinking_tokens, 2},
            {rewind_files, 2},
            {server_health, 1},
            {extract_init_field, 4},
            {extract_from_system_info, 3}]}).
-export([start_session/1,
         stop/1,
         child_spec/1,
         query/2,
         query/3,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         interrupt/1,
         abort/1,
         health/1,
         send_control/3,
         mcp_tool/4,
         mcp_server/2,
         sdk_hook/2,
         sdk_hook/3,
         list_sessions/0,
         list_sessions/1,
         get_session_messages/1,
         get_session_messages/2,
         get_session/1,
         delete_session/1,
         fork_session/2,
         revert_session/2,
         unrevert_session/1,
         share_session/1,
         share_session/2,
         unshare_session/1,
         summarize_session/1,
         summarize_session/2,
         thread_start/2,
         thread_resume/2,
         thread_resume/3,
         thread_list/1,
         thread_list/2,
         thread_fork/2,
         thread_fork/3,
         thread_read/2,
         thread_read/3,
         thread_archive/2,
         thread_unsubscribe/2,
         thread_name_set/3,
         thread_metadata_update/3,
         thread_unarchive/2,
         thread_rollback/3,
         thread_loaded_list/1,
         thread_loaded_list/2,
         thread_compact/2,
         thread_realtime_start/2,
         thread_realtime_append_audio/3,
         thread_realtime_append_text/3,
         thread_realtime_stop/2,
         review_start/2,
         collaboration_mode_list/1,
         experimental_feature_list/1,
         experimental_feature_list/2,
         mcp_server_status/1,
         set_mcp_servers/2,
         reconnect_mcp_server/2,
         toggle_mcp_server/3,
         provider_list/1,
         provider_auth_methods/1,
         provider_oauth_authorize/3,
         provider_oauth_callback/3,
         config_read/1,
         config_read/2,
         config_update/2,
         config_providers/1,
         config_value_write/3,
         config_value_write/4,
         config_batch_write/2,
         config_batch_write/3,
         config_requirements_read/1,
         external_agent_config_detect/1,
         external_agent_config_detect/2,
         external_agent_config_import/2,
         supported_commands/1,
         supported_models/1,
         supported_agents/1,
         account_info/1,
         set_max_thinking_tokens/2,
         rewind_files/2,
         stop_task/2,
         command_run/2,
         command_run/3,
         command_write_stdin/3,
         command_write_stdin/4,
         submit_feedback/2,
         turn_respond/3,
         server_health/1]).
-spec start_session(beam_agent_core:session_opts()) ->
                       {ok, pid()} | {error, term()}.
start_session(Opts) ->
    gemini_cli_session:start_link(Opts).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                gemini_cli_session;
            SId when is_binary(SId) ->
                {gemini_cli_session, SId};
            SId ->
                {gemini_cli_session, SId}
        end,
    #{id => Id,
      start => {gemini_cli_session, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [gemini_cli_session]}.
-spec query(pid(), binary()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).
-spec query(pid(), binary(), beam_agent_core:query_opts()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            beam_agent_core:collect_messages(Session, Ref, Deadline,
                                        fun receive_message_from/3);
        {error, _} = Err ->
            Err
    end.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) ->
    gen_statem:call(Session, {set_permission_mode, Mode}, 5000).
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Session, <<"setModel">>, Params) ->
    case maps:get(<<"model">>, Params, maps:get(model, Params, undefined)) of
        Model when is_binary(Model), byte_size(Model) > 0 ->
            set_model(Session, Model);
        _ ->
            {error, {missing_param, model}}
    end;
send_control(Session, <<"setPermissionMode">>, Params) ->
    case maps:get(<<"permissionMode">>, Params,
           maps:get(permission_mode, Params, undefined)) of
        Mode when is_binary(Mode), byte_size(Mode) > 0 ->
            set_permission_mode(Session, Mode);
        _ ->
            {error, {missing_param, permission_mode}}
    end;
send_control(Session, Method, Params) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:dispatch(SessionId, Method, Params).
-spec mcp_tool(binary(), binary(), map(), beam_agent_mcp_core:tool_handler()) ->
                  beam_agent_mcp_core:tool_def().
mcp_tool(Name, Description, InputSchema, Handler) ->
    beam_agent_mcp_core:tool(Name, Description, InputSchema, Handler).
-spec mcp_server(binary(), [beam_agent_mcp_core:tool_def()]) ->
                    beam_agent_mcp_core:sdk_mcp_server().
mcp_server(Name, Tools) ->
    beam_agent_mcp_core:server(Name, Tools).
-spec sdk_hook(beam_agent_hooks_core:hook_event(),
               beam_agent_hooks_core:hook_callback()) ->
                  beam_agent_hooks_core:hook_def().
sdk_hook(Event, Callback) ->
    beam_agent_hooks_core:hook(Event, Callback).
-spec sdk_hook(beam_agent_hooks_core:hook_event(),
               beam_agent_hooks_core:hook_callback(),
               beam_agent_hooks_core:hook_matcher()) ->
                  beam_agent_hooks_core:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    beam_agent_hooks_core:hook(Event, Callback, Matcher).
-spec list_sessions() -> {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions() ->
    beam_agent_session_store_core:list_sessions().
-spec list_sessions(beam_agent_session_store_core:list_opts()) ->
                       {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions(Opts) ->
    beam_agent_session_store_core:list_sessions(Opts).
-spec get_session_messages(binary()) ->
                              {ok, [beam_agent_core:message()]} |
                              {error, not_found}.
get_session_messages(SessionId) ->
    beam_agent_session_store_core:get_session_messages(SessionId).
-spec get_session_messages(binary(),
                           beam_agent_session_store_core:message_opts()) ->
                              {ok, [beam_agent_core:message()]} |
                              {error, not_found}.
get_session_messages(SessionId, Opts) ->
    beam_agent_session_store_core:get_session_messages(SessionId, Opts).
-spec get_session(binary()) ->
                     {ok, beam_agent_session_store_core:session_meta()} |
                     {error, not_found}.
get_session(SessionId) ->
    beam_agent_session_store_core:get_session(SessionId).
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    beam_agent_session_store_core:delete_session(SessionId).
-spec fork_session(pid(), map()) -> {ok, map()} | {error, not_found}.
fork_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:fork_session(SessionId, Opts).
-spec revert_session(pid(), map()) ->
                        {ok, map()} |
                        {error, not_found | invalid_selector}.
revert_session(Session, Selector) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:revert_session(SessionId, Selector).
-spec unrevert_session(pid()) -> {ok, map()} | {error, not_found}.
unrevert_session(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:unrevert_session(SessionId).
-spec share_session(pid()) -> {ok, map()} | {error, not_found}.
share_session(Session) ->
    share_session(Session, #{}).
-spec share_session(pid(), map()) -> {ok, map()} | {error, not_found}.
share_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:share_session(SessionId, Opts).
-spec unshare_session(pid()) -> ok | {error, not_found}.
unshare_session(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:unshare_session(SessionId).
-spec summarize_session(pid()) -> {ok, map()} | {error, not_found}.
summarize_session(Session) ->
    summarize_session(Session, #{}).
-spec summarize_session(pid(), map()) ->
                           {ok, map()} | {error, not_found}.
summarize_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:summarize_session(SessionId, Opts).
-spec thread_start(pid(), map()) -> {ok, map()}.
thread_start(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:start_thread(SessionId, Opts).
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_resume(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:resume_thread(SessionId, ThreadId).
-spec thread_resume(pid(), binary(), map()) -> {ok, map()} | {error, not_found}.
thread_resume(Session, ThreadId, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:resume_thread(SessionId, ThreadId) of
        {ok, Thread} ->
            maybe_include_thread_read(SessionId, ThreadId, Opts, Thread);
        {error, _} = Error ->
            Error
    end.
-spec thread_list(pid()) -> {ok, [map()]}.
thread_list(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:list_threads(SessionId).
-spec thread_list(pid(), map()) -> {ok, [map()]}.
thread_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Threads} = beam_agent_threads_core:list_threads(SessionId),
    {ok, filter_loaded_threads(Threads, Opts)}.
-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_fork(Session, ThreadId) ->
    thread_fork(Session, ThreadId, #{}).
-spec thread_fork(pid(), binary(), map()) ->
                     {ok, map()} | {error, not_found}.
thread_fork(Session, ThreadId, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:fork_thread(SessionId, ThreadId, Opts).
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_read(Session, ThreadId) ->
    thread_read(Session, ThreadId, #{}).
-spec thread_read(pid(), binary(), map()) ->
                     {ok, map()} | {error, not_found}.
thread_read(Session, ThreadId, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts).
-spec thread_archive(pid(), binary()) ->
                        {ok, map()} | {error, not_found}.
thread_archive(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:archive_thread(SessionId, ThreadId).
-spec thread_unsubscribe(pid(), binary()) ->
                            {ok, map()} | {error, not_found}.
thread_unsubscribe(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
        {ok, _Thread} ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} ->
                    ok = beam_agent_threads_core:clear_active_thread(SessionId);
                _ ->
                    ok
            end,
            {ok, with_adapter_source(Session, #{
                thread_id => ThreadId,
                unsubscribed => true,
                active_thread_id => active_thread_id(SessionId)
            })};
        {error, _} = Error ->
            Error
    end.
-spec thread_name_set(pid(), binary(), binary()) ->
                         {ok, map()} | {error, not_found}.
thread_name_set(Session, ThreadId, Name)
    when is_binary(ThreadId), is_binary(Name) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:rename_thread(SessionId, ThreadId, Name) of
        {ok, Thread} ->
            {ok, with_adapter_source(Session, #{
                thread_id => ThreadId,
                name => Name,
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.
-spec thread_metadata_update(pid(), binary(), map()) ->
                                {ok, map()} | {error, not_found}.
thread_metadata_update(Session, ThreadId, MetadataPatch)
    when is_binary(ThreadId), is_map(MetadataPatch) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:update_thread_metadata(SessionId, ThreadId, MetadataPatch) of
        {ok, Thread} ->
            {ok, with_adapter_source(Session, #{
                thread_id => ThreadId,
                metadata => maps:get(metadata, Thread, #{}),
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.
-spec thread_unarchive(pid(), binary()) ->
                          {ok, map()} | {error, not_found}.
thread_unarchive(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:unarchive_thread(SessionId, ThreadId).
-spec thread_rollback(pid(), binary(), map()) ->
                         {ok, map()} |
                         {error, not_found | invalid_selector}.
thread_rollback(Session, ThreadId, Selector) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector).
-spec thread_loaded_list(pid()) -> {ok, map()}.
thread_loaded_list(Session) ->
    thread_loaded_list(Session, #{}).
-spec thread_loaded_list(pid(), map()) -> {ok, map()}.
thread_loaded_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, with_adapter_source(Session, #{
        threads => Threads,
        active_thread_id => active_thread_id(SessionId),
        count => length(Threads)
    })}.
-spec thread_compact(pid(), map()) -> {ok, map()} | {error, term()}.
thread_compact(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    case resolve_thread_id(SessionId, Opts) of
        {ok, ThreadId} ->
            Selector = thread_compact_selector(Opts),
            case beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector) of
                {ok, Thread} ->
                    {ok, with_adapter_source(Session, #{
                        thread_id => ThreadId,
                        compacted => true,
                        selector => Selector,
                        thread => Thread
                    })};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.
-spec thread_realtime_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) when is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:start_realtime(SessionId, with_backend(Params, gemini)).
-spec thread_realtime_append_audio(pid(), binary(), map()) ->
                                      {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:append_realtime_audio(SessionId, ThreadId, Params).
-spec thread_realtime_append_text(pid(), binary(), map()) ->
                                     {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:append_realtime_text(SessionId, ThreadId, Params).
-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) when is_binary(ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:stop_realtime(SessionId, ThreadId).
-spec review_start(pid(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) when is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:start_review(SessionId, with_backend(Params, gemini)).
-spec collaboration_mode_list(pid()) -> {ok, map()}.
collaboration_mode_list(Session) ->
    SessionId = get_session_id(Session),
    {ok, Result} = beam_agent_collaboration:collaboration_modes(SessionId),
    {ok, with_adapter_source(Session, Result)}.
-spec experimental_feature_list(pid()) -> {ok, map()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).
-spec experimental_feature_list(pid(), map()) -> {ok, map()}.
experimental_feature_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Result} = beam_agent_collaboration:experimental_features(SessionId, Opts),
    {ok, with_adapter_source(Session, Result)}.
-spec mcp_server_status(pid()) -> {ok, map()}.
mcp_server_status(Session) ->
    case beam_agent_mcp_core:get_session_registry(Session) of
        {ok, Registry} ->
            beam_agent_mcp_core:server_status(Registry);
        {error, not_found} ->
            {ok, #{}}
    end.
-spec set_mcp_servers(pid(), [beam_agent_mcp_core:sdk_mcp_server()]) ->
                         {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    case
        beam_agent_mcp_core:update_session_registry(Session,
                                               fun(R) ->
                                                      beam_agent_mcp_core:set_servers(Servers,
                                                                                 R)
                                               end)
    of
        ok ->
            {ok, #{<<"status">> => <<"updated">>}};
        {error, _} = Err ->
            Err
    end.
-spec reconnect_mcp_server(pid(), binary()) ->
                              {ok, term()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    case beam_agent_mcp_core:get_session_registry(Session) of
        {ok, Registry} ->
            case
                beam_agent_mcp_core:reconnect_server(ServerName, Registry)
            of
                {ok, Updated} ->
                    beam_agent_mcp_core:register_session_registry(Session,
                                                             Updated),
                    {ok, #{<<"status">> => <<"reconnected">>}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
                           {ok, term()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    case beam_agent_mcp_core:get_session_registry(Session) of
        {ok, Registry} ->
            case
                beam_agent_mcp_core:toggle_server(ServerName, Enabled,
                                             Registry)
            of
                {ok, Updated} ->
                    beam_agent_mcp_core:register_session_registry(Session,
                                                             Updated),
                    {ok, #{<<"status">> => <<"toggled">>}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) ->
    extract_init_field(Session, commands, slash_commands, []).
-spec provider_list(pid()) -> {ok, [map()]} | {error, term()}.
provider_list(Session) ->
    beam_agent_runtime_core:list_providers(Session).
-spec provider_auth_methods(pid()) -> {ok, [map()]} | {error, term()}.
provider_auth_methods(Session) ->
    beam_agent_config:provider_auth_methods(Session).
-spec provider_oauth_authorize(pid(), binary(), map()) ->
                                  {ok, map()} | {error, term()}.
provider_oauth_authorize(Session, ProviderId, Body)
    when is_binary(ProviderId), is_map(Body) ->
    beam_agent_config:provider_oauth_authorize(Session, ProviderId, Body).
-spec provider_oauth_callback(pid(), binary(), map()) ->
                                 {ok, map()} | {error, term()}.
provider_oauth_callback(Session, ProviderId, Body)
    when is_binary(ProviderId), is_map(Body) ->
    beam_agent_config:provider_oauth_callback(Session, ProviderId, Body).
-spec config_read(pid()) -> {ok, map()} | {error, term()}.
config_read(Session) ->
    config_read(Session, #{}).
-spec config_read(pid(), map()) -> {ok, map()} | {error, term()}.
config_read(Session, _Opts) ->
    beam_agent_config:config_read(Session).
-spec config_update(pid(), map()) -> {ok, map()} | {error, term()}.
config_update(Session, Body) when is_map(Body) ->
    beam_agent_config:config_update(Session, Body).
-spec config_providers(pid()) -> {ok, [map()]} | {error, term()}.
config_providers(Session) ->
    provider_list(Session).
-spec config_value_write(pid(), binary(), term()) -> {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value) ->
    config_value_write(Session, KeyPath, Value, #{}).
-spec config_value_write(pid(), binary(), term(), map()) ->
                            {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value, Opts)
    when is_binary(KeyPath), is_map(Opts) ->
    beam_agent_config:config_value_write(Session, KeyPath, Value, Opts).
-spec config_batch_write(pid(), [map()]) -> {ok, map()} | {error, term()}.
config_batch_write(Session, Edits) ->
    config_batch_write(Session, Edits, #{}).
-spec config_batch_write(pid(), [map()], map()) ->
                            {ok, map()} | {error, term()}.
config_batch_write(Session, Edits, Opts) when is_list(Edits), is_map(Opts) ->
    beam_agent_config:config_batch_write(Session, Edits, Opts).
-spec config_requirements_read(pid()) -> {ok, map()} | {error, term()}.
config_requirements_read(Session) ->
    beam_agent_config:config_requirements_read(Session).
-spec external_agent_config_detect(pid()) -> {ok, map()} | {error, term()}.
external_agent_config_detect(Session) ->
    external_agent_config_detect(Session, #{}).
-spec external_agent_config_detect(pid(), map()) ->
                                      {ok, map()} | {error, term()}.
external_agent_config_detect(Session, Opts) when is_map(Opts) ->
    beam_agent_config:external_agent_config_detect(Session, Opts).
-spec external_agent_config_import(pid(), map()) -> {ok, map()} | {error, term()}.
external_agent_config_import(Session, Opts) when is_map(Opts) ->
    beam_agent_config:external_agent_config_import(Session, Opts).
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) ->
    extract_init_field(Session, models, models, []).
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) ->
    extract_init_field(Session, agents, agents, []).
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) ->
    extract_init_field(Session, account, account, #{}).
-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, map()}.
set_max_thinking_tokens(Session, MaxTokens)
    when is_integer(MaxTokens), MaxTokens > 0 ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:set_max_thinking_tokens(SessionId, MaxTokens),
    {ok, #{max_thinking_tokens => MaxTokens}}.
-spec rewind_files(pid(), binary()) -> ok | {error, not_found | term()}.
rewind_files(Session, CheckpointUuid) ->
    SessionId = get_session_id(Session),
    beam_agent_checkpoint_core:rewind(SessionId, CheckpointUuid).
-spec stop_task(pid(), binary()) -> ok | {error, not_found}.
stop_task(Session, TaskId) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:stop_task(SessionId, TaskId).
-spec command_run(pid(), binary()) ->
                     {ok, beam_agent_command_core:command_result()} |
                     {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).
-spec command_run(pid(), binary(), map()) ->
                     {ok, beam_agent_command_core:command_result()} |
                     {error, term()}.
command_run(Session, Command, Opts) ->
    SessionId = get_session_id(Session),
    CmdOpts =
        case beam_agent_session_store_core:get_session(SessionId) of
            {ok, #{cwd := Cwd}} ->
                maps:merge(#{cwd => Cwd}, Opts);
            _ ->
                Opts
        end,
    beam_agent_command_core:run(Command, CmdOpts).
-spec command_write_stdin(pid(), binary(), binary()) -> {ok, map()} | {error, not_found}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).
-spec command_write_stdin(pid(), binary(), binary(), map()) -> {ok, map()} | {error, not_found}.
command_write_stdin(_Session, _ProcessId, _Stdin, _Opts) ->
    {error, not_found}.
-spec submit_feedback(pid(), map()) -> ok.
submit_feedback(Session, Feedback) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:submit_feedback(SessionId, Feedback).
-spec turn_respond(pid(), binary(), map()) ->
                      ok | {error, not_found | already_resolved}.
turn_respond(Session, RequestId, Params) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:resolve_pending_request(SessionId, RequestId,
                                               Params).
-spec server_health(pid()) -> {ok, map()}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => gemini_cli}}.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
                       {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    gen_statem:call(Session, {send_query, Prompt, Params}, Timeout).
-spec receive_message_from(pid(), reference(), timeout()) ->
                              {ok, beam_agent_core:message()} |
                              {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}}
            when is_binary(SId), byte_size(SId) > 0 ->
            SId;
        _ ->
            unicode:characters_to_binary(pid_to_list(Session))
    end.
-spec extract_init_field(pid(), atom(), atom(), term()) ->
                            {ok, term()} | {error, term()}.
extract_init_field(Session, IRKey, SIKey, Default) ->
    case session_info(Session) of
        {ok, Info} ->
            case maps:find(init_response, Info) of
                {ok, IR} when is_map(IR) ->
                    IRKeyBin = atom_to_binary(IRKey),
                    case maps:find(IRKeyBin, IR) of
                        {ok, Val} ->
                            {ok, Val};
                        error ->
                            extract_from_system_info(Info, SIKey,
                                                     Default)
                    end;
                _ ->
                    extract_from_system_info(Info, SIKey, Default)
            end;
        {error, _} = Err ->
            Err
    end.
-spec extract_from_system_info(map(), atom(), term()) -> {ok, term()}.
extract_from_system_info(Info, Key, Default) ->
    case maps:find(system_info, Info) of
        {ok, SI} when is_map(SI) ->
            {ok, maps:get(Key, SI, Default)};
        _ ->
            {ok, Default}
    end.

-spec with_adapter_source(pid(), map()) -> map().
with_adapter_source(_Session, Result) ->
    Result#{source => universal, backend => gemini}.

-spec with_backend(map(), atom()) -> map().
with_backend(Params, Backend) ->
    maps:put(backend, Backend, Params).

-spec active_thread_id(binary()) -> binary() | undefined.
active_thread_id(SessionId) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} -> ThreadId;
        {error, _} -> undefined
    end.

-spec maybe_include_thread_read(binary(), binary(), map(), map()) -> {ok, map()} | {error, not_found}.
maybe_include_thread_read(SessionId, ThreadId, Opts, Thread) ->
    case opt_value([include_messages, <<"include_messages">>, <<"includeMessages">>], Opts, false) of
        true ->
            beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts);
        false ->
            {ok, Thread}
    end.

-spec filter_loaded_threads([map()], map()) -> [map()].
filter_loaded_threads(Threads, Opts) ->
    IncludeArchived = opt_value(
        [include_archived, <<"include_archived">>, <<"includeArchived">>],
        Opts,
        true),
    ThreadIdFilter = opt_value([thread_id, <<"thread_id">>, <<"threadId">>], Opts, undefined),
    StatusFilter = opt_value([status, <<"status">>], Opts, undefined),
    Limit = opt_value([limit, <<"limit">>], Opts, undefined),
    Threads1 = [Thread || Thread <- Threads, include_thread(Thread, IncludeArchived)],
    Threads2 = case ThreadIdFilter of
        undefined -> Threads1;
        ThreadId -> [Thread || Thread <- Threads1, maps:get(thread_id, Thread, undefined) =:= ThreadId]
    end,
    Threads3 = case StatusFilter of
        undefined -> Threads2;
        Status -> [Thread || Thread <- Threads2, maps:get(status, Thread, undefined) =:= Status]
    end,
    case Limit of
        N when is_integer(N), N >= 0 -> lists:sublist(Threads3, N);
        _ -> Threads3
    end.

-spec include_thread(map(), boolean()) -> boolean().
include_thread(Thread, true) ->
    is_map(Thread);
include_thread(Thread, false) ->
    maps:get(archived, Thread, false) =/= true.

-spec resolve_thread_id(binary(), map()) -> {ok, binary()} | {error, not_found}.
resolve_thread_id(SessionId, Opts) ->
    case opt_value([thread_id, <<"thread_id">>, <<"threadId">>], Opts, undefined) of
        ThreadId when is_binary(ThreadId) ->
            {ok, ThreadId};
        _ ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} -> {ok, ThreadId};
                {error, _} -> {error, not_found}
            end
    end.

-spec thread_compact_selector(map()) -> map().
thread_compact_selector(Opts) ->
    case opt_value([selector, <<"selector">>], Opts, undefined) of
        Selector when is_map(Selector) ->
            Selector;
        _ ->
            Selector0 =
                maybe_put_selector(count,
                    opt_value([count, <<"count">>], Opts, undefined),
                    maybe_put_selector(visible_message_count,
                        opt_value([visible_message_count, <<"visible_message_count">>,
                                   <<"visibleMessageCount">>], Opts, undefined),
                        maybe_put_selector(message_id,
                            opt_value([message_id, <<"message_id">>, <<"messageId">>], Opts, undefined),
                            maybe_put_selector(uuid,
                                opt_value([uuid, <<"uuid">>], Opts, undefined),
                                #{})))),
            case map_size(Selector0) of
                0 -> #{visible_message_count => 0};
                _ -> Selector0
            end
    end.

-spec maybe_put_selector(atom(), term(), map()) -> map().
maybe_put_selector(_Key, undefined, Acc) ->
    Acc;
maybe_put_selector(Key, Value, Acc) ->
    maps:put(Key, Value, Acc).

-spec opt_value([term()], map(), term()) -> term().
opt_value([], _Opts, Default) ->
    Default;
opt_value([Key | Rest], Opts, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Value;
        error -> opt_value(Rest, Opts, Default)
    end.
