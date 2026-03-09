-module(codex_app_server).
-export([start_session/1,
         start_exec/1,
         stop/1,
         child_spec/1,
         exec_child_spec/1,
         query/2,
         query/3,
         thread_start/2,
         thread_resume/2,
         thread_resume/3,
         thread_list/1,
         thread_list/2,
         thread_loaded_list/1,
         thread_loaded_list/2,
         thread_fork/2,
         thread_fork/3,
         thread_read/2,
         thread_read/3,
         thread_archive/2,
         thread_unsubscribe/2,
         thread_name_set/3,
         thread_metadata_update/3,
         thread_unarchive/2,
         thread_compact/2,
         thread_rollback/3,
         turn_steer/4,
         turn_steer/5,
         turn_interrupt/3,
         thread_realtime_start/2,
         thread_realtime_append_audio/3,
         thread_realtime_append_text/3,
         thread_realtime_stop/2,
         review_start/2,
         collaboration_mode_list/1,
         experimental_feature_list/1,
         experimental_feature_list/2,
         skills_list/1,
         skills_list/2,
         skills_remote_list/1,
         skills_remote_list/2,
         skills_remote_export/2,
         skills_config_write/3,
         apps_list/1,
         apps_list/2,
         model_list/1,
         model_list/2,
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
         provider_list/1,
         provider_auth_methods/1,
         provider_oauth_authorize/3,
         provider_oauth_callback/3,
         mcp_server_oauth_login/2,
         mcp_server_reload/1,
         mcp_server_status_list/1,
         account_login/2,
         account_login_cancel/2,
         account_logout/1,
         account_rate_limits/1,
         fuzzy_file_search/2,
         fuzzy_file_search/3,
         fuzzy_file_search_session_start/3,
         fuzzy_file_search_session_update/3,
         fuzzy_file_search_session_stop/2,
         windows_sandbox_setup_start/2,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         interrupt/1,
         abort/1,
         send_control/3,
         health/1,
         mcp_tool/4,
         mcp_server/2,
         sdk_hook/2,
         sdk_hook/3,
         command_run/2,
         command_run/3,
         command_write_stdin/3,
         command_write_stdin/4,
         submit_feedback/2,
         turn_respond/3,
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
         mcp_server_status/1,
         set_mcp_servers/2,
         reconnect_mcp_server/2,
         toggle_mcp_server/3,
         supported_commands/1,
         supported_models/1,
         supported_agents/1,
         account_info/1,
         set_max_thinking_tokens/2,
         rewind_files/2,
         stop_task/2,
         server_health/1]).

-dialyzer({no_underspecs,
           [{turn_steer, 4},
            {fork_session, 2},
            {revert_session, 2},
            {unrevert_session, 1},
            {share_session, 1},
            {share_session, 2},
            {summarize_session, 1},
            {summarize_session, 2},
            {mcp_server_status, 1},
            {set_max_thinking_tokens, 2},
            {rewind_files, 2},
            {server_health, 1},
            {extract_init_field, 4},
            {transport_module, 1},
            {extract_from_system_info, 3}]}).
-spec start_session(beam_agent_core:session_opts()) ->
                       {ok, pid()} | {error, term()}.
start_session(Opts) ->
    case maps:get(transport, Opts, app_server) of
        exec ->
            codex_exec:start_link(Opts);
        realtime ->
            codex_realtime_session:start_link(Opts);
        _ ->
            codex_session:start_link(Opts)
    end.
-spec start_exec(beam_agent_core:session_opts()) ->
                    {ok, pid()} | {error, term()}.
start_exec(Opts) ->
    codex_exec:start_link(Opts).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Module = transport_module(Opts),
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                Module;
            SId when is_binary(SId) ->
                {Module, SId};
            SId ->
                {Module, SId}
        end,
    #{id => Id,
      start => {Module, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [Module]}.
-spec exec_child_spec(beam_agent_core:session_opts()) ->
                         supervisor:child_spec().
exec_child_spec(Opts) ->
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                codex_exec;
            SId when is_binary(SId) ->
                {codex_exec, SId};
            SId ->
                {codex_exec, SId}
        end,
    #{id => Id,
      start => {codex_exec, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [codex_exec]}.
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
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) ->
    send_control_to(Session,
                    <<"thread/start">>,
                    codex_protocol:thread_start_params(Opts)).
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) ->
    thread_resume(Session, ThreadId, #{}).
-spec thread_resume(pid(), binary(), map()) ->
                       {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"thread/resume">>,
                    codex_protocol:thread_resume_params(ThreadId, Opts)).
-spec thread_list(pid()) -> {ok, map()} | {error, term()}.
thread_list(Session) ->
    thread_list(Session, #{}).
-spec thread_list(pid(), map()) -> {ok, map()} | {error, term()}.
thread_list(Session, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"thread/list">>,
                    codex_protocol:thread_list_params(Opts)).
-spec thread_loaded_list(pid()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session) ->
    thread_loaded_list(Session, #{}).
-spec thread_loaded_list(pid(), map()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"thread/loaded/list">>, Params).
-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId) ->
    thread_fork(Session, ThreadId, #{}).
-spec thread_fork(pid(), binary(), map()) ->
                     {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"thread/fork">>,
                    codex_protocol:thread_fork_params(ThreadId, Opts)).
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) ->
    thread_read(Session, ThreadId, #{}).
-spec thread_read(pid(), binary(), map()) ->
                     {ok, map()} | {error, term()}.
thread_read(Session, ThreadId, Opts) ->
    Params = Opts#{<<"threadId">> => ThreadId},
    send_control_to(Session, <<"thread/read">>, Params).
-spec thread_archive(pid(), binary()) -> {ok, term()} | {error, term()}.
thread_archive(Session, ThreadId) ->
    send_control_to(Session,
                    <<"thread/archive">>,
                    #{<<"threadId">> => ThreadId}).
-spec thread_unsubscribe(pid(), binary()) ->
                            {ok, map()} | {error, term()}.
thread_unsubscribe(Session, ThreadId) ->
    send_control_to(Session,
                    <<"thread/unsubscribe">>,
                    #{<<"threadId">> => ThreadId}).
-spec thread_name_set(pid(), binary(), binary()) ->
                         {ok, map()} | {error, term()}.
thread_name_set(Session, ThreadId, Name)
    when is_binary(ThreadId), is_binary(Name) ->
    send_control_to(Session,
                    <<"thread/name/set">>,
                    #{<<"threadId">> => ThreadId, <<"name">> => Name}).
-spec thread_metadata_update(pid(), binary(), map()) ->
                                {ok, map()} | {error, term()}.
thread_metadata_update(Session, ThreadId, MetadataPatch)
    when is_map(MetadataPatch) ->
    send_control_to(Session,
                    <<"thread/metadata/update">>,
                    #{<<"threadId">> => ThreadId,
                      <<"thread">> => MetadataPatch}).
-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) ->
    send_control_to(Session,
                    <<"thread/unarchive">>,
                    #{<<"threadId">> => ThreadId}).
-spec thread_compact(pid(), binary()) -> {ok, term()} | {error, term()}.
thread_compact(Session, ThreadId) ->
    send_control_to(Session,
                    <<"thread/compact/start">>,
                    #{<<"threadId">> => ThreadId}).
-spec thread_rollback(pid(), binary(), map()) ->
                         {ok, map()} | {error, term()}.
thread_rollback(Session, ThreadId, Opts) ->
    Params = Opts#{<<"threadId">> => ThreadId},
    send_control_to(Session, <<"thread/rollback">>, Params).
-spec turn_steer(pid(), binary(), binary(), binary() | [map()]) ->
                    {ok, map()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input) ->
    turn_steer(Session, ThreadId, TurnId, Input, #{}).
-spec turn_steer(pid(), binary(), binary(), binary() | [map()], map()) ->
                    {ok, map()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"turn/steer">>,
                    codex_protocol:turn_steer_params(ThreadId, TurnId,
                                                     Input, Opts)).
-spec turn_interrupt(pid(), binary(), binary()) ->
                        {ok, map()} | {error, term()}.
turn_interrupt(Session, ThreadId, TurnId) ->
    send_control_to(Session,
                    <<"turn/interrupt">>,
                    #{<<"threadId">> => ThreadId,
                      <<"turnId">> => TurnId}).
-spec thread_realtime_start(pid(), map()) ->
                               {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) when is_map(Params) ->
    case session_transport(Session) of
        realtime ->
            codex_realtime_session:thread_realtime_start(Session, Params);
        _ ->
            send_control_to(Session, <<"thread/realtime/start">>, Params)
    end.
-spec thread_realtime_append_audio(pid(), binary(), map()) ->
                                      {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params)
    when is_map(Params) ->
    case session_transport(Session) of
        realtime ->
            codex_realtime_session:thread_realtime_append_audio(Session, ThreadId, Params);
        _ ->
            send_control_to(Session,
                            <<"thread/realtime/appendAudio">>,
                            Params#{<<"threadId">> => ThreadId})
    end.
-spec thread_realtime_append_text(pid(), binary(), map()) ->
                                     {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params)
    when is_map(Params) ->
    case session_transport(Session) of
        realtime ->
            codex_realtime_session:thread_realtime_append_text(Session, ThreadId, Params);
        _ ->
            send_control_to(Session,
                            <<"thread/realtime/appendText">>,
                            Params#{<<"threadId">> => ThreadId})
    end.
-spec thread_realtime_stop(pid(), binary()) ->
                              {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) ->
    case session_transport(Session) of
        realtime ->
            codex_realtime_session:thread_realtime_stop(Session, ThreadId);
        _ ->
            send_control_to(Session,
                            <<"thread/realtime/stop">>,
                            #{<<"threadId">> => ThreadId})
    end.
-spec review_start(pid(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) when is_map(Params) ->
    case session_transport(Session) of
        realtime ->
            beam_agent_collaboration:start_review(
                get_session_id(Session),
                with_backend_transport(Params, Session));
        _ ->
            send_control_to(Session, <<"review/start">>, Params)
    end.
-spec collaboration_mode_list(pid()) -> {ok, map()} | {error, term()}.
collaboration_mode_list(Session) ->
    case session_transport(Session) of
        realtime ->
            {ok, Result} = beam_agent_collaboration:collaboration_modes(get_session_id(Session)),
            {ok, with_adapter_source(Session, Result)};
        _ ->
            send_control_to(Session, <<"collaborationMode/list">>, #{})
    end.
-spec experimental_feature_list(pid()) -> {ok, map()} | {error, term()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).
-spec experimental_feature_list(pid(), map()) ->
                                   {ok, map()} | {error, term()}.
experimental_feature_list(Session, Params) when is_map(Params) ->
    case session_transport(Session) of
        realtime ->
            {ok, Result} = beam_agent_collaboration:experimental_features(get_session_id(Session), Params),
            {ok, with_adapter_source(Session, Result)};
        _ ->
            send_control_to(Session, <<"experimentalFeature/list">>, Params)
    end.
-spec skills_list(pid()) -> {ok, map()} | {error, term()}.
skills_list(Session) ->
    skills_list(Session, #{}).
-spec skills_list(pid(), map()) -> {ok, map()} | {error, term()}.
skills_list(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"skills/list">>, Params).
-spec skills_remote_list(pid()) -> {ok, map()} | {error, term()}.
skills_remote_list(Session) ->
    skills_remote_list(Session, #{}).
-spec skills_remote_list(pid(), map()) -> {ok, map()} | {error, term()}.
skills_remote_list(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"skills/remote/list">>, Params).
-spec skills_remote_export(pid(), map()) ->
                              {ok, map()} | {error, term()}.
skills_remote_export(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"skills/remote/export">>, Params).
-spec skills_config_write(pid(), binary(), boolean()) ->
                             {ok, map()} | {error, term()}.
skills_config_write(Session, Path, Enabled)
    when is_binary(Path), is_boolean(Enabled) ->
    send_control_to(Session,
                    <<"skills/config/write">>,
                    #{<<"path">> => Path, <<"enabled">> => Enabled}).
-spec apps_list(pid()) -> {ok, map()} | {error, term()}.
apps_list(Session) ->
    apps_list(Session, #{}).
-spec apps_list(pid(), map()) -> {ok, map()} | {error, term()}.
apps_list(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"app/list">>, Params).
-spec model_list(pid()) -> {ok, map()} | {error, term()}.
model_list(Session) ->
    model_list(Session, #{}).
-spec model_list(pid(), map()) -> {ok, map()} | {error, term()}.
model_list(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"model/list">>, Params).
-spec config_read(pid()) -> {ok, map()} | {error, term()}.
config_read(Session) ->
    config_read(Session, #{}).
-spec config_read(pid(), map()) -> {ok, map()} | {error, term()}.
config_read(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"config/read">>, Params).
-spec config_update(pid(), map()) -> {ok, map()} | {error, term()}.
config_update(Session, Body) when is_map(Body) ->
    beam_agent_config:config_update(Session, Body).
-spec config_providers(pid()) -> {ok, [map()]} | {error, term()}.
config_providers(Session) ->
    provider_list(Session).
-spec config_value_write(pid(), binary(), term()) ->
                            {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value) ->
    config_value_write(Session, KeyPath, Value, #{}).
-spec config_value_write(pid(), binary(), term(), map()) ->
                            {ok, map()} | {error, term()}.
config_value_write(Session, KeyPath, Value, Opts)
    when is_binary(KeyPath), is_map(Opts) ->
    send_control_to(Session,
                    <<"config/value/write">>,
                    Opts#{<<"keyPath">> => KeyPath,
                          <<"value">> => Value}).
-spec config_batch_write(pid(), [map()]) ->
                            {ok, map()} | {error, term()}.
config_batch_write(Session, Edits) ->
    config_batch_write(Session, Edits, #{}).
-spec config_batch_write(pid(), [map()], map()) ->
                            {ok, map()} | {error, term()}.
config_batch_write(Session, Edits, Opts)
    when is_list(Edits), is_map(Opts) ->
    send_control_to(Session,
                    <<"config/batchWrite">>,
                    Opts#{<<"edits">> => Edits}).
-spec config_requirements_read(pid()) -> {ok, map()} | {error, term()}.
config_requirements_read(Session) ->
    send_control_to(Session, <<"configRequirements/read">>, #{}).
-spec external_agent_config_detect(pid()) ->
                                      {ok, map()} | {error, term()}.
external_agent_config_detect(Session) ->
    external_agent_config_detect(Session, #{}).
-spec external_agent_config_detect(pid(), map()) ->
                                      {ok, map()} | {error, term()}.
external_agent_config_detect(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"externalAgentConfig/detect">>, Params).
-spec external_agent_config_import(pid(), map()) ->
                                      {ok, map()} | {error, term()}.
external_agent_config_import(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"externalAgentConfig/import">>, Params).
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
-spec mcp_server_oauth_login(pid(), map()) ->
                                {ok, map()} | {error, term()}.
mcp_server_oauth_login(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"mcpServer/oauth/login">>, Params).
-spec mcp_server_reload(pid()) -> {ok, map()} | {error, term()}.
mcp_server_reload(Session) ->
    send_control_to(Session, <<"config/mcpServer/reload">>, #{}).
-spec mcp_server_status_list(pid()) -> {ok, map()} | {error, term()}.
mcp_server_status_list(Session) ->
    send_control_to(Session, <<"mcpServerStatus/list">>, #{}).
-spec account_login(pid(), map()) -> {ok, map()} | {error, term()}.
account_login(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"account/login/start">>, Params).
-spec account_login_cancel(pid(), map()) ->
                              {ok, map()} | {error, term()}.
account_login_cancel(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"account/login/cancel">>, Params).
-spec account_logout(pid()) -> {ok, map()} | {error, term()}.
account_logout(Session) ->
    send_control_to(Session, <<"account/logout">>, #{}).
-spec account_rate_limits(pid()) -> {ok, map()} | {error, term()}.
account_rate_limits(Session) ->
    send_control_to(Session, <<"account/rateLimits/read">>, #{}).
-spec fuzzy_file_search(pid(), binary()) ->
                           {ok, map()} | {error, term()}.
fuzzy_file_search(Session, Query) ->
    fuzzy_file_search(Session, Query, #{}).
-spec fuzzy_file_search(pid(), binary(), map()) ->
                           {ok, map()} | {error, term()}.
fuzzy_file_search(Session, Query, Opts)
    when is_binary(Query), is_map(Opts) ->
    send_control_to(Session,
                    <<"fuzzyFileSearch">>,
                    Opts#{<<"query">> => Query}).

-spec fuzzy_file_search_session_start(pid(), binary(), [term()]) ->
    {ok, map()} | {error, term()}.
fuzzy_file_search_session_start(Session, SearchSessionId, Roots)
    when is_binary(SearchSessionId), is_list(Roots) ->
    send_control_to(Session,
                    <<"fuzzyFileSearch/sessionStart">>,
                    codex_protocol:fuzzy_file_search_session_start_params(
                        SearchSessionId, Roots)).

-spec fuzzy_file_search_session_update(pid(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
fuzzy_file_search_session_update(Session, SearchSessionId, Query)
    when is_binary(SearchSessionId), is_binary(Query) ->
    send_control_to(Session,
                    <<"fuzzyFileSearch/sessionUpdate">>,
                    codex_protocol:fuzzy_file_search_session_update_params(
                        SearchSessionId, Query)).

-spec fuzzy_file_search_session_stop(pid(), binary()) ->
    {ok, map()} | {error, term()}.
fuzzy_file_search_session_stop(Session, SearchSessionId)
    when is_binary(SearchSessionId) ->
    send_control_to(Session,
                    <<"fuzzyFileSearch/sessionStop">>,
                    codex_protocol:fuzzy_file_search_session_stop_params(
                        SearchSessionId)).

-spec windows_sandbox_setup_start(pid(), map()) ->
                                     {ok, map()} | {error, term()}.
windows_sandbox_setup_start(Session, Params) when is_map(Params) ->
    send_control_to(Session, <<"windowsSandbox/setupStart">>, Params).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) ->
    gen_statem:call(Session, {set_permission_mode, Mode}, 5000).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    send_control_to(Session, Method, Params).
-spec health(pid()) ->
                ready | connecting | initializing | active_turn |
                active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).
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
-spec command_run(pid(), binary() | [binary()]) ->
                     {ok, term()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).
-spec command_run(pid(), binary() | [binary()], map()) ->
                     {ok, term()} | {error, term()}.
command_run(Session, Command, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"command/exec">>,
                    codex_protocol:command_exec_params(Command, Opts)).
-spec command_write_stdin(pid(), binary(), binary()) ->
                             {ok, map()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).
-spec command_write_stdin(pid(), binary(), binary(), map()) ->
                             {ok, map()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin, Opts) when is_map(Opts) ->
    send_control_to(Session,
                    <<"command/writeStdin">>,
                    codex_protocol:command_write_stdin_params(ProcessId,
                                                              Stdin,
                                                              Opts)).
-spec submit_feedback(pid(), map()) -> {ok, term()} | {error, term()}.
submit_feedback(Session, Feedback) when is_map(Feedback) ->
    send_control_to(Session, <<"feedback/upload">>, Feedback).
-spec turn_respond(pid(), binary() | integer(), map()) ->
                      {ok, term()} | {error, term()}.
turn_respond(Session, RequestId, Params) ->
    gen_statem:call(Session,
                    {respond_request, RequestId, Params},
                    30000).
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
-spec server_health(pid()) -> {ok, map()}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => codex}}.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
                       {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    gen_statem:call(Session, {send_query, Prompt, Params}, Timeout).
-spec send_control_to(pid(), binary(), map()) ->
                         {ok, term()} | {error, term()}.
send_control_to(Session, Method, Params) ->
    gen_statem:call(Session, {send_control, Method, Params}, 30000).
-spec receive_message_from(pid(), reference(), timeout()) ->
                              {ok, beam_agent_core:message()} |
                              {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).
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
                            case maps:find(IRKey, IR) of
                                {ok, Val} ->
                                    {ok, Val};
                                error ->
                                    extract_from_system_info(Info,
                                                             SIKey,
                                                             Default)
                            end
                    end;
                _ ->
                    extract_from_system_info(Info, SIKey, Default)
            end;
        {error, _} = Err ->
            Err
    end.
-spec transport_module(map()) -> module().
transport_module(Opts) ->
    case maps:get(transport, Opts, app_server) of
        exec ->
            codex_exec;
        realtime ->
            codex_realtime_session;
        _ ->
            codex_session
    end.

-spec session_transport(pid()) -> app_server | exec | realtime | atom().
session_transport(Session) ->
    case session_info(Session) of
        {ok, #{transport := Transport}} ->
            Transport;
        _ ->
            app_server
    end.
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}}
            when is_binary(SId), byte_size(SId) > 0 ->
            SId;
        {ok, #{thread_id := ThreadId}}
            when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
            ThreadId;
        _ ->
            unicode:characters_to_binary(pid_to_list(Session))
    end.
-spec with_adapter_source(pid(), map()) -> map().
with_adapter_source(Session, Result) when is_map(Result) ->
    Result#{
        source => universal,
        backend => codex,
        transport => session_transport(Session)
    }.
-spec with_backend_transport(map(), pid()) -> map().
with_backend_transport(Params, Session) when is_map(Params) ->
    Params#{
        backend => codex,
        transport => session_transport(Session)
    }.
-spec extract_from_system_info(map(), atom(), term()) -> {ok, term()}.
extract_from_system_info(Info, Key, Default) ->
    case maps:find(system_info, Info) of
        {ok, SI} when is_map(SI) ->
            KeyBin = atom_to_binary(Key),
            Value = maps:get(Key, SI, maps:get(KeyBin, SI, Default)),
            {ok, Value};
        _ ->
            {ok, Default}
    end.
