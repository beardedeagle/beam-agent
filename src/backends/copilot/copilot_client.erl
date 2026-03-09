-module(copilot_client).
-type session_meta() :: beam_agent_session_store_core:session_meta().
-type session_share() :: beam_agent_session_store_core:session_share().
-type session_summary() :: beam_agent_session_store_core:session_summary().
-type thread_meta() :: beam_agent_threads_core:thread_meta().
-type thread_read_result() :: #{
    thread := thread_meta(),
    messages => [beam_agent_core:message()]
}.
-type init_response_key() :: account | agents | commands | models.
-type system_info_key() :: account | agents | models | slash_commands.
-type init_default() :: [] | #{}.
-type session_health() ::
          ready | connecting | initializing | active_query | error.
-type checkpoint_restore_error() ::
          {restore_failed, binary(), atom()}.
-export([start_session/1,
         stop/1,
         child_spec/1,
         query/2,
         query/3,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         resume_session/1,
         resume_session/2,
         interrupt/1,
         abort/1,
         health/1,
         send_command/3,
         send_control/3,
         mcp_tool/4,
         mcp_server/2,
         sdk_hook/2,
         sdk_hook/3,
         get_status/1,
         get_auth_status/1,
         model_list/1,
         get_last_session_id/1,
         list_server_sessions/1,
         list_server_sessions/2,
         get_server_session/2,
         delete_server_session/2,
         session_get_messages/1,
         session_get_messages/2,
         session_destroy/1,
         session_destroy/2,
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
         thread_list/1,
         thread_fork/2,
         thread_fork/3,
         thread_read/2,
         thread_read/3,
         thread_archive/2,
         thread_unarchive/2,
         thread_rollback/3,
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
         command_run/2,
         command_run/3,
         submit_feedback/2,
         turn_respond/3,
         server_health/1]).

-export([event_subscribe/1,
         receive_event/3,
         event_unsubscribe/2,
         model_list/2,
         list_server_agents/1,
         session_messages/1,
         session_messages/2,
         thread_resume/3,
         thread_list/2,
         thread_unsubscribe/2,
         thread_name_set/3,
         thread_metadata_update/3,
         thread_loaded_list/1,
         thread_loaded_list/2,
         thread_compact/2,
         turn_interrupt/3,
         thread_realtime_start/2,
         thread_realtime_append_audio/3,
         thread_realtime_append_text/3,
         thread_realtime_stop/2,
         review_start/2,
         collaboration_mode_list/1,
         experimental_feature_list/1,
         experimental_feature_list/2,
         list_commands/1,
         skills_list/1,
         skills_list/2,
         skills_remote_list/1,
         skills_remote_list/2,
         mcp_status/1,
         mcp_server_status_list/1,
         account_rate_limits/1]).
-spec start_session(beam_agent_core:session_opts()) ->
                       {ok, pid()} | {error, term()}.
start_session(Opts) ->
    copilot_session:start_link(Opts).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                copilot_session;
            SId when is_binary(SId) ->
                {copilot_session, SId};
            SId ->
                {copilot_session, SId}
        end,
    #{id => Id,
      start => {copilot_session, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [copilot_session]}.
-spec query(pid(), binary()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).
-spec query(pid(), binary(), map()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            collect_messages(Session, Ref, Deadline, []);
        {error, _} = Err ->
            Err
    end.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    copilot_session:session_info(Session).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    copilot_session:set_model(Session, Model).
-spec resume_session(binary()) -> {ok, pid()} | {error, term()}.
resume_session(SessionId) when is_binary(SessionId) ->
    resume_session(SessionId, #{}).
-spec resume_session(binary(), map()) -> {ok, pid()} | {error, term()}.
resume_session(SessionId, Opts) when is_binary(SessionId), is_map(Opts) ->
    start_session(Opts#{session_id => SessionId, resume => true}).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    copilot_session:interrupt(Session).
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).
-spec health(pid()) -> session_health().
health(Session) ->
    copilot_session:health(Session).
-spec set_permission_mode(pid(), binary()) -> {ok, map()}.
set_permission_mode(Session, Mode) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:set_permission_mode(SessionId, Mode),
    {ok, #{permission_mode => Mode}}.
-spec send_command(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_command(Session, Method, Params) ->
    copilot_session:send_control(Session, Method, Params).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    send_command(Session, Method, Params).
-spec get_status(pid()) -> {ok, term()} | {error, term()}.
get_status(Session) ->
    send_command(Session, <<"status.get">>, #{}).
-spec get_auth_status(pid()) -> {ok, term()} | {error, term()}.
get_auth_status(Session) ->
    send_command(Session, <<"auth.getStatus">>, #{}).
-spec model_list(pid()) -> {ok, term()} | {error, term()}.
model_list(Session) ->
    send_command(Session, <<"models.list">>, #{}).
-spec get_last_session_id(pid()) ->
                             {ok, binary() | undefined} |
                             {error, term()}.
get_last_session_id(Session) ->
    case send_command(Session, <<"session.getLastId">>, #{}) of
        {ok, #{<<"sessionId">> := SessionId}} ->
            {ok, SessionId};
        {ok, #{sessionId := SessionId}} ->
            {ok, SessionId};
        {ok, Result} when is_map(Result) ->
            {ok, maps:get(<<"sessionId">>, Result, undefined)};
        {error, _} = Err ->
            Err
    end.
-spec list_server_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    list_server_sessions(Session, #{}).
-spec list_server_sessions(pid(), map()) ->
                              {ok, [map()]} | {error, term()}.
list_server_sessions(Session, Filter) when is_map(Filter) ->
    case
        send_command(Session,
                     <<"session.list">>,
                     #{<<"filter">> => normalize_rpc_map(Filter)})
    of
        {ok, #{<<"sessions">> := Sessions}} when is_list(Sessions) ->
            {ok, Sessions};
        {ok, #{sessions := Sessions}} when is_list(Sessions) ->
            {ok, Sessions};
        {ok, Sessions} when is_list(Sessions) ->
            {ok, Sessions};
        {ok, _} = Ok ->
            Ok;
        {error, _} = Err ->
            Err
    end.
-spec get_server_session(pid(), binary()) ->
                            {ok, map()} | {error, term()}.
get_server_session(Session, SessionId) when is_binary(SessionId) ->
    case list_server_sessions(Session) of
        {ok, Sessions} ->
            case find_native_session(SessionId, Sessions) of
                {ok, NativeSession} ->
                    {ok, NativeSession};
                error ->
                    {error, not_found}
            end;
        {error, _} = Err ->
            Err
    end.
-spec delete_server_session(pid(), binary()) ->
                               {ok, term()} | {error, term()}.
delete_server_session(Session, SessionId) when is_binary(SessionId) ->
    send_command(Session,
                 <<"session.delete">>,
                 #{<<"sessionId">> => SessionId}).
-spec session_get_messages(pid()) -> {ok, term()} | {error, term()}.
session_get_messages(Session) ->
    SessionId = get_session_id(Session),
    session_get_messages(Session, SessionId).
-spec session_get_messages(pid(), binary()) ->
                              {ok, term()} | {error, term()}.
session_get_messages(Session, SessionId) when is_binary(SessionId) ->
    send_command(Session,
                 <<"session.getMessages">>,
                 #{<<"sessionId">> => SessionId}).
-spec session_destroy(pid()) -> {ok, term()} | {error, term()}.
session_destroy(Session) ->
    SessionId = get_session_id(Session),
    session_destroy(Session, SessionId).
-spec session_destroy(pid(), binary()) -> {ok, term()} | {error, term()}.
session_destroy(Session, SessionId) when is_binary(SessionId) ->
    send_command(Session,
                 <<"session.destroy">>,
                 #{<<"sessionId">> => SessionId}).
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
-spec fork_session(pid(), map()) ->
                       {ok, session_meta()} | {error, not_found}.
fork_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:fork_session(SessionId, Opts).
-spec revert_session(pid(), map()) ->
                        {ok, session_meta()} |
                        {error, not_found | invalid_selector}.
revert_session(Session, Selector) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:revert_session(SessionId, Selector).
-spec unrevert_session(pid()) ->
                          {ok, session_meta()} | {error, not_found}.
unrevert_session(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:unrevert_session(SessionId).
-spec share_session(pid()) -> {ok, session_share()} | {error, not_found}.
share_session(Session) ->
    share_session(Session, #{}).
-spec share_session(pid(), map()) ->
                       {ok, session_share()} | {error, not_found}.
share_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:share_session(SessionId, Opts).
-spec unshare_session(pid()) -> ok | {error, not_found}.
unshare_session(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:unshare_session(SessionId).
-spec summarize_session(pid()) ->
                           {ok, session_summary()} | {error, not_found}.
summarize_session(Session) ->
    summarize_session(Session, #{}).
-spec summarize_session(pid(), map()) ->
                           {ok, session_summary()} | {error, not_found}.
summarize_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_session_store_core:summarize_session(SessionId, Opts).
-spec thread_start(pid(), beam_agent_threads_core:thread_opts()) ->
                      {ok, thread_meta()}.
thread_start(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:start_thread(SessionId, Opts).
-spec thread_resume(pid(), binary()) ->
                       {ok, thread_meta()} | {error, not_found}.
thread_resume(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:resume_thread(SessionId, ThreadId).
-spec thread_list(pid()) -> {ok, [thread_meta()]}.
thread_list(Session) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:list_threads(SessionId).
-spec thread_fork(pid(), binary()) ->
                     {ok, thread_meta()} | {error, not_found}.
thread_fork(Session, ThreadId) ->
    thread_fork(Session, ThreadId, #{}).
-spec thread_fork(pid(), binary(), beam_agent_threads_core:thread_opts()) ->
                     {ok, thread_meta()} | {error, not_found}.
thread_fork(Session, ThreadId, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:fork_thread(SessionId, ThreadId, Opts).
-spec thread_read(pid(), binary()) ->
                     {ok, thread_read_result()} | {error, not_found}.
thread_read(Session, ThreadId) ->
    thread_read(Session, ThreadId, #{}).
-spec thread_read(pid(), binary(), map()) ->
                     {ok, thread_read_result()} | {error, not_found}.
thread_read(Session, ThreadId, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts).
-spec thread_archive(pid(), binary()) ->
                        {ok, thread_meta()} | {error, not_found}.
thread_archive(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:archive_thread(SessionId, ThreadId).
-spec thread_unarchive(pid(), binary()) ->
                          {ok, thread_meta()} | {error, not_found}.
thread_unarchive(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:unarchive_thread(SessionId, ThreadId).
-spec thread_rollback(pid(), binary(), map()) ->
                         {ok, thread_meta()} |
                         {error, not_found | invalid_selector}.
thread_rollback(Session, ThreadId, Selector) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector).
-spec mcp_server_status(pid()) -> {ok, #{binary() => map()}}.
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
-spec set_max_thinking_tokens(pid(), pos_integer()) ->
                                 {ok, #{max_thinking_tokens := pos_integer()}}.
set_max_thinking_tokens(Session, MaxTokens)
    when is_integer(MaxTokens), MaxTokens > 0 ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:set_max_thinking_tokens(SessionId, MaxTokens),
    {ok, #{max_thinking_tokens => MaxTokens}}.
-spec rewind_files(pid(), binary()) ->
                      ok | {error, not_found | checkpoint_restore_error()}.
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
-spec server_health(pid()) ->
                       {ok, #{adapter := copilot,
                              health := session_health()}}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => copilot}}.
-spec event_subscribe(pid()) -> {ok, reference()} | {error, term()}.
event_subscribe(Session) ->
    beam_agent_events:subscribe(get_session_id(Session)).
-spec receive_event(pid(), reference(), timeout()) ->
                       {ok, beam_agent_core:message()} | {error, term()}.
receive_event(_Session, Ref, Timeout) ->
    beam_agent_events:receive_event(Ref, Timeout).
-spec event_unsubscribe(pid(), reference()) -> ok | {error, term()}.
event_unsubscribe(Session, Ref) ->
    beam_agent_events:unsubscribe(get_session_id(Session), Ref).
-spec model_list(pid(), map()) -> {ok, term()} | {error, term()}.
model_list(Session, _Opts) ->
    model_list(Session).
-spec list_server_agents(pid()) -> {ok, [map()]} | {error, term()}.
list_server_agents(Session) ->
    beam_agent_catalog_core:list_agents(Session).
-spec session_messages(pid()) -> {ok, [beam_agent_core:message()]} | {error, term()}.
session_messages(Session) ->
    session_messages(Session, #{}).
-spec session_messages(pid(), map()) -> {ok, [beam_agent_core:message()]} | {error, term()}.
session_messages(Session, Opts) when is_map(Opts) ->
    beam_agent_session_store_core:get_session_messages(get_session_id(Session), Opts).
-spec thread_resume(pid(), binary(), map()) -> {ok, thread_meta()} | {error, term()}.
thread_resume(Session, ThreadId, _Opts) ->
    thread_resume(Session, ThreadId).
-spec thread_list(pid(), map()) -> {ok, [thread_meta()]} | {error, term()}.
thread_list(Session, _Opts) ->
    thread_list(Session).
-spec thread_unsubscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
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
            {ok, with_adapter_source(#{
                thread_id => ThreadId,
                unsubscribed => true,
                active_thread_id => active_thread_id(SessionId)
            })};
        {error, _} = Error ->
            Error
    end.
-spec thread_name_set(pid(), binary(), binary()) -> {ok, map()} | {error, term()}.
thread_name_set(Session, ThreadId, Name)
    when is_binary(ThreadId), is_binary(Name) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:rename_thread(SessionId, ThreadId, Name) of
        {ok, Thread} ->
            {ok, with_adapter_source(#{thread_id => ThreadId, name => Name, thread => Thread})};
        {error, _} = Error ->
            Error
    end.
-spec thread_metadata_update(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_metadata_update(Session, ThreadId, MetadataPatch)
    when is_binary(ThreadId), is_map(MetadataPatch) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:update_thread_metadata(SessionId, ThreadId, MetadataPatch) of
        {ok, Thread} ->
            {ok, with_adapter_source(#{
                thread_id => ThreadId,
                metadata => maps:get(metadata, Thread, #{}),
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.
-spec thread_loaded_list(pid()) -> {ok, map()}.
thread_loaded_list(Session) ->
    thread_loaded_list(Session, #{}).
-spec thread_loaded_list(pid(), map()) -> {ok, map()}.
thread_loaded_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, with_adapter_source(#{
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
                    {ok, with_adapter_source(#{
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
-spec turn_interrupt(pid(), binary(), binary()) -> {ok, map()} | {error, term()}.
turn_interrupt(Session, ThreadId, TurnId) ->
    case interrupt(Session) of
        ok ->
            {ok, with_adapter_source(#{thread_id => ThreadId, turn_id => TurnId, status => interrupted})};
        {error, _} = Error ->
            Error
    end.
-spec thread_realtime_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) when is_map(Params) ->
    beam_agent_collaboration:start_realtime(get_session_id(Session), with_backend(Params, copilot)).
-spec thread_realtime_append_audio(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    beam_agent_collaboration:append_realtime_audio(get_session_id(Session), ThreadId, Params).
-spec thread_realtime_append_text(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    beam_agent_collaboration:append_realtime_text(get_session_id(Session), ThreadId, Params).
-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) when is_binary(ThreadId) ->
    beam_agent_collaboration:stop_realtime(get_session_id(Session), ThreadId).
-spec review_start(pid(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) when is_map(Params) ->
    beam_agent_collaboration:start_review(get_session_id(Session), with_backend(Params, copilot)).
-spec collaboration_mode_list(pid()) -> {ok, map()}.
collaboration_mode_list(Session) ->
    {ok, Result} = beam_agent_collaboration:collaboration_modes(get_session_id(Session)),
    {ok, with_adapter_source(Result)}.
-spec experimental_feature_list(pid()) -> {ok, map()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).
-spec experimental_feature_list(pid(), map()) -> {ok, map()}.
experimental_feature_list(Session, Opts) when is_map(Opts) ->
    {ok, Result} = beam_agent_collaboration:experimental_features(get_session_id(Session), Opts),
    {ok, with_adapter_source(Result)}.
-spec list_commands(pid()) -> {ok, list()} | {error, term()}.
list_commands(Session) ->
    supported_commands(Session).
-spec skills_list(pid()) -> {ok, [map()]} | {error, term()}.
skills_list(Session) ->
    beam_agent_catalog_core:list_skills(Session).
-spec skills_list(pid(), map()) -> {ok, [map()]} | {error, term()}.
skills_list(Session, _Opts) ->
    skills_list(Session).
-spec skills_remote_list(pid()) -> {ok, map()} | {error, term()}.
skills_remote_list(Session) ->
    skills_remote_list(Session, #{}).
-spec skills_remote_list(pid(), map()) -> {ok, map()} | {error, term()}.
skills_remote_list(Session, _Opts) ->
    case skills_list(Session) of
        {ok, Skills} ->
            {ok, with_adapter_source(#{skills => Skills, count => length(Skills)})};
        {error, _} = Error ->
            Error
    end.
-spec mcp_status(pid()) -> {ok, term()} | {error, term()}.
mcp_status(Session) ->
    mcp_server_status(Session).
-spec mcp_server_status_list(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status_list(Session) ->
    mcp_server_status(Session).
-spec account_rate_limits(pid()) -> {ok, map()} | {error, term()}.
account_rate_limits(Session) ->
    account_info(Session).
-spec with_adapter_source(map()) -> map().
with_adapter_source(Result) ->
    Result#{source => universal, backend => copilot}.
-spec with_backend(map(), atom()) -> map().
with_backend(Params, Backend) ->
    maps:put(backend, Backend, Params).
-spec active_thread_id(binary()) -> binary() | undefined.
active_thread_id(SessionId) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} -> ThreadId;
        {error, _} -> undefined
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
                        opt_value([visible_message_count,
                                   <<"visible_message_count">>,
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
    Acc#{Key => Value}.
-spec opt_value([term()], map(), term()) -> term().
opt_value([], _Opts, Default) ->
    Default;
opt_value([Key | Rest], Opts, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Value;
        error -> opt_value(Rest, Opts, Default)
    end.
-spec send_query_to(pid(), binary(), map(), non_neg_integer()) ->
                       {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    copilot_session:send_query(Session, Prompt, Params, Timeout).
-spec collect_messages(pid(),
                       reference(),
                       timeout(),
                       [beam_agent_core:message()]) ->
                          {ok, [beam_agent_core:message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, Acc) ->
    collect_loop(Session, Ref, Deadline, Acc).
-spec collect_loop(pid(),
                   reference(),
                   integer(),
                   [beam_agent_core:message()]) ->
                      {ok, [beam_agent_core:message()]} | {error, term()}.
collect_loop(Session, Ref, Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, Deadline - Now),
    case receive_message_from(Session, Ref, Remaining) of
        {ok, #{type := result} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, #{type := error, is_error := true} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, Msg} ->
            collect_loop(Session, Ref, Deadline, [Msg | Acc]);
        {error, timeout} ->
            {error, {timeout, lists:reverse(Acc)}};
        {error, _} = Err ->
            Err
    end.
-spec receive_message_from(pid(), reference(), timeout()) ->
                              {ok, beam_agent_core:message()} |
                              {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    copilot_session:receive_message(Session, Ref, Timeout).
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}}
            when is_binary(SId), byte_size(SId) > 0 ->
            SId;
        {ok, #{copilot_session_id := SId}}
            when is_binary(SId), byte_size(SId) > 0 ->
            SId;
        _ ->
            unicode:characters_to_binary(pid_to_list(Session))
    end.
-spec normalize_rpc_map(map()) -> map().
normalize_rpc_map(Map) when is_map(Map) ->
    maps:fold(fun(Key, Value, Acc) when is_atom(Key) ->
                     Acc#{atom_to_binary(Key, utf8) =>
                              normalize_rpc_value(Value)};
                 (Key, Value, Acc) when is_binary(Key) ->
                     Acc#{Key => normalize_rpc_value(Value)};
                 (Key, Value, Acc) ->
                     Acc#{unicode:characters_to_binary(io_lib:format("~p",
                                                                     [Key])) =>
                              normalize_rpc_value(Value)}
              end,
              #{},
              Map).
-spec normalize_rpc_value(term()) -> term().
normalize_rpc_value(Value) when is_map(Value) ->
    normalize_rpc_map(Value);
normalize_rpc_value(Value) when is_list(Value) ->
    [ 
     normalize_rpc_value(Item) ||
         Item <- Value
    ];
normalize_rpc_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
normalize_rpc_value(Value) ->
    Value.
-spec find_native_session(binary(), [map()]) -> {ok, map()} | error.
find_native_session(_SessionId, []) ->
    error;
find_native_session(SessionId, [Session | Rest]) ->
    case session_matches_id(SessionId, Session) of
        true ->
            {ok, Session};
        false ->
            find_native_session(SessionId, Rest)
    end.
-spec session_matches_id(binary(), map()) -> boolean().
session_matches_id(SessionId, Session) when is_map(Session) ->
    lists:any(fun({<<"sessionId">>, Value}) when Value =:= SessionId ->
                     true;
                 ({sessionId, Value}) when Value =:= SessionId ->
                     true;
                 ({<<"id">>, Value}) when Value =:= SessionId ->
                     true;
                 ({id, Value}) when Value =:= SessionId ->
                     true;
                 (_) ->
                     false
              end,
              maps:to_list(Session)).
-spec extract_init_field(pid(),
                         init_response_key(),
                         system_info_key(),
                         init_default()) ->
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
-spec extract_from_system_info(map(),
                               system_info_key(),
                               init_default()) ->
                                  {ok, term()}.
extract_from_system_info(Info, Key, Default) ->
    case maps:find(system_info, Info) of
        {ok, SI} when is_map(SI) ->
            {ok, maps:get(Key, SI, Default)};
        _ ->
            {ok, Default}
    end.
