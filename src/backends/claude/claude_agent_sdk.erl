-module(claude_agent_sdk).
-moduledoc false.
-behaviour(beam_agent_adapter).
-type session_meta() :: beam_agent_adapter_types:session_meta().
-type session_share() :: beam_agent_adapter_types:session_share().
-type session_summary() :: beam_agent_adapter_types:session_summary().
-type thread_meta() :: beam_agent_adapter_types:thread_meta().
-type thread_read_result() :: beam_agent_adapter_types:thread_read_result().
-type init_response_key() :: beam_agent_adapter_types:init_response_key().
-type system_info_key() :: beam_agent_adapter_types:system_info_key().
-type init_default() :: beam_agent_adapter_types:init_default().
-type session_health() :: beam_agent_adapter_types:session_health().
-type adapter_status() :: #{
    backend := claude,
    source  := universal,
    health  => active_query | connecting | error | initializing | ready,
    _       => _
}.
%% beam_agent_adapter callbacks
-export([backend_name/0, backend_type/0, capabilities/0]).

-export([start_session/1,
         stop/1,
         health/1,
         query/2,
         query/3,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         set_max_thinking_tokens/2,
         rewind_files/2,
         stop_task/2,
         interrupt/1,
         abort/1,
         mcp_server_status/1,
         set_mcp_servers/2,
         reconnect_mcp_server/2,
         toggle_mcp_server/3,
         mcp_tool/4,
         mcp_server/2,
         sdk_hook/2,
         sdk_hook/3,
         supported_commands/1,
         supported_models/1,
         supported_agents/1,
         account_info/1,
         child_spec/1,
         send_control/3,
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
         list_native_sessions/0,
         list_native_sessions/1,
         get_native_session_messages/1,
         get_native_session_messages/2,
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
         command_run/2,
         command_run/3,
         submit_feedback/2,
         turn_respond/3,
         server_health/1]).

-export([send_command/3,
         event_subscribe/1,
         receive_event/3,
         event_unsubscribe/2,
         list_commands/1,
         skills_list/1,
         skills_list/2,
         skills_remote_list/1,
         skills_remote_list/2,
         model_list/1,
         model_list/2,
         get_status/1,
         get_last_session_id/1,
         account_rate_limits/1,
         list_server_sessions/1,
         get_server_session/2,
         delete_server_session/2,
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
         mcp_status/1,
         mcp_server_status_list/1]).

-ifdef(TEST).
-export([discover_models_from_claude_config/0,
         discover_models_from_claude_config/1,
         collect_claude_model_ids/1,
         discoverable_claude_model_ids/1,
         expand_claude_model_entries/1,
         normalize_claude_model_id/1,
         claude_config_path/0]).
-endif.

%% Universal core return shape; map() is intentional.
-dialyzer({nowarn_function, [thread_realtime_start/2,
                             thread_realtime_append_audio/3,
                             thread_realtime_append_text/3,
                             thread_realtime_stop/2,
                             review_start/2]}).

-spec start_session(beam_agent_core:session_opts()) ->
                       {ok, pid()} | {error, term()}.
start_session(Opts) ->
    claude_agent_session:start_link(Opts).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).
-spec query(pid(), binary()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).
-spec query(pid(), binary(), beam_agent_core:query_opts()) ->
               {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case
        claude_agent_session:send_query(Session, Prompt, Params,
                                        Timeout)
    of
        {ok, Ref} ->
            beam_agent_core:collect_messages(Session, Ref, Deadline,
                                        fun claude_agent_session:receive_message/3);
        {error, _} = Err ->
            Err
    end.
-spec session_info(pid()) -> {ok, map()} | {error, 'reconnecting' | 'session_error'}.
session_info(Session) ->
    claude_agent_session:session_info(Session).
-spec set_model(pid(), binary()) -> {ok, map()} | {error, 'not_supported' | 'reconnecting' | 'session_error'}.
set_model(Session, Model) ->
    claude_agent_session:set_model(Session, Model).
-spec set_permission_mode(pid(), binary()) ->
                             {ok, map()} | {error, 'not_supported' | 'reconnecting' | 'session_error'}.
set_permission_mode(Session, Mode) ->
    claude_agent_session:set_permission_mode(Session, Mode).
-spec rewind_files(pid(), binary()) -> {ok, map()} | {error, term()}.
rewind_files(Session, CheckpointUuid) ->
    claude_agent_session:rewind_files(Session, CheckpointUuid).
-spec stop_task(pid(), binary()) -> {ok, map()} | {error, term()}.
stop_task(Session, TaskId) ->
    claude_agent_session:stop_task(Session, TaskId).
-spec set_max_thinking_tokens(pid(), pos_integer()) ->
                                 {ok, map()} | {error, term()}.
set_max_thinking_tokens(Session, MaxTokens) ->
    claude_agent_session:set_max_thinking_tokens(Session, MaxTokens).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).
-spec mcp_server_status(pid()) -> {ok, map()} | {error, term()}.
mcp_server_status(Session) ->
    claude_agent_session:mcp_server_status(Session).
-spec set_mcp_servers(pid(), map()) -> {ok, map()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    claude_agent_session:set_mcp_servers(Session, Servers).
-spec reconnect_mcp_server(pid(), binary()) ->
                              {ok, map()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    claude_agent_session:reconnect_mcp_server(Session, ServerName).
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
                           {ok, map()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    claude_agent_session:toggle_mcp_server(Session, ServerName, Enabled).
-spec mcp_tool(binary(), binary(), map(), beam_agent_tool_registry:tool_handler()) ->
                  beam_agent_tool_registry:tool_def().
mcp_tool(Name, Description, InputSchema, Handler) ->
    beam_agent_tool_registry:tool(Name, Description, InputSchema, Handler).
-spec mcp_server(binary(), [beam_agent_tool_registry:tool_def()]) ->
                    beam_agent_tool_registry:sdk_mcp_server().
mcp_server(Name, Tools) ->
    beam_agent_tool_registry:server(Name, Tools).
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
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) ->
    extract_init_field(Session, commands, slash_commands, []).
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) ->
    case extract_init_field(Session, models, models, []) of
        {ok, Models} when is_list(Models), Models =/= [] ->
            {ok, expand_claude_model_entries(Models)};
        {ok, _} ->
            discover_models_from_claude_config();
        {error, _} = Err ->
            case discover_models_from_claude_config() of
                {ok, Models} when Models =/= [] ->
                    {ok, Models};
                _ ->
                    Err
            end
    end.
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) ->
    extract_init_field(Session, agents, agents, []).
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) ->
    extract_init_field(Session, account, account, #{}).
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                claude_agent_session;
            SId when is_binary(SId) ->
                {claude_agent_session, SId};
            SId ->
                {claude_agent_session, SId}
        end,
    #{id => Id,
      start => {claude_agent_session, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [claude_agent_session]}.
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    gen_statem:call(Session, {send_control, Method, Params}, 30000).
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
-spec list_native_sessions() ->
                              {ok,
                               [claude_session_store:session_summary()]}.
list_native_sessions() ->
    claude_session_store:list_sessions().
-spec list_native_sessions(claude_session_store:list_opts()) ->
                              {ok,
                               [claude_session_store:session_summary()]}.
list_native_sessions(Opts) ->
    claude_session_store:list_sessions(Opts).
-spec get_native_session_messages(binary()) ->
                                     {ok, [map()]} | {error, atom()}.
get_native_session_messages(SessionId) ->
    claude_session_store:get_session_messages(SessionId).
-spec get_native_session_messages(binary(),
                                  claude_session_store:message_opts()) ->
                                     {ok, [map()]} | {error, atom()}.
get_native_session_messages(SessionId, Opts) ->
    claude_session_store:get_session_messages(SessionId, Opts).
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
                       {ok, #{health := session_health(),
                              adapter := claude}}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => claude}}.
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Method, Params) ->
    send_control(Session, Method, Params).
-spec event_subscribe(pid()) -> {ok, reference()}.
event_subscribe(Session) ->
    beam_agent_events:subscribe(get_session_id(Session)).
-spec receive_event(pid(), reference(), timeout()) ->
                       {ok, beam_agent_core:message()} | {error, term()}.
receive_event(_Session, Ref, Timeout) ->
    beam_agent_events:receive_event(Ref, Timeout).
-spec event_unsubscribe(pid(), reference()) -> ok | {error, bad_ref}.
event_unsubscribe(Session, Ref) ->
    beam_agent_events:unsubscribe(get_session_id(Session), Ref).
-spec list_commands(pid()) -> {ok, [any()]} | {error, 'reconnecting' | 'session_error'}.
list_commands(Session) ->
    supported_commands(Session).
-spec skills_list(pid()) -> {ok, [map()]} | {error, term()}.
skills_list(Session) ->
    beam_agent_catalog_core:list_skills(Session).
-spec skills_list(pid(), map()) -> {ok, [map()]} | {error, term()}.
skills_list(Session, _Opts) ->
    skills_list(Session).
-spec skills_remote_list(pid()) -> {ok, adapter_status()} | {error, term()}.
skills_remote_list(Session) ->
    skills_remote_list(Session, #{}).
-spec skills_remote_list(pid(), map()) -> {ok, adapter_status()} | {error, term()}.
skills_remote_list(Session, _Opts) ->
    case skills_list(Session) of
        {ok, Skills} ->
            {ok, with_adapter_source(#{skills => Skills, count => length(Skills)})};
        {error, _} = Error ->
            Error
    end.
-spec model_list(pid()) -> {ok, [any()]} | {error, 'reconnecting' | 'session_error'}.
model_list(Session) ->
    supported_models(Session).
-spec model_list(pid(), map()) -> {ok, list()} | {error, term()}.
model_list(Session, _Opts) ->
    model_list(Session).
-spec get_status(pid()) -> {ok, adapter_status()} | {error, 'reconnecting' | 'session_error'}.
get_status(Session) ->
    case session_info(Session) of
        {ok, Info} ->
            {ok, with_adapter_source(Info#{health => safe_session_health(Session)})};
        {error, _} = Error ->
            Error
    end.
-spec get_last_session_id(pid()) -> {ok, binary()}.
get_last_session_id(Session) ->
    {ok, get_session_id(Session)}.
-spec account_rate_limits(pid()) -> {ok, map()} | {error, 'reconnecting' | 'session_error'}.
account_rate_limits(Session) ->
    account_info(Session).
-spec list_server_sessions(pid()) ->
    {ok, [#{session_id := binary(),
            adapter => atom(),
            created_at => integer(),
            cwd => binary(),
            extra => map(),
            message_count => non_neg_integer(),
            model => binary(),
            updated_at => integer()}]}.
list_server_sessions(_Session) ->
    beam_agent_session_store_core:list_sessions(#{adapter => claude}).
-spec get_server_session(pid(), binary()) ->
                            {ok, map()} | {error, not_found | term()}.
get_server_session(_Session, SessionId) ->
    get_session(SessionId).
-spec delete_server_session(pid(), binary()) -> {ok, adapter_status()}.
delete_server_session(_Session, SessionId) ->
    ok = delete_session(SessionId),
    {ok, with_adapter_source(#{session_id => SessionId, deleted => true})}.
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
-spec thread_list(pid(), map()) -> {ok, [thread_meta()]}.
thread_list(Session, _Opts) ->
    thread_list(Session).
-spec thread_unsubscribe(pid(), binary()) -> {ok, adapter_status()} | {error, not_found}.
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
-spec thread_name_set(pid(), binary(), binary()) -> {ok, adapter_status()} | {error, not_found}.
thread_name_set(Session, ThreadId, Name)
    when is_binary(ThreadId), is_binary(Name) ->
    SessionId = get_session_id(Session),
    case beam_agent_threads_core:rename_thread(SessionId, ThreadId, Name) of
        {ok, Thread} ->
            {ok, with_adapter_source(#{thread_id => ThreadId, name => Name, thread => Thread})};
        {error, _} = Error ->
            Error
    end.
-spec thread_metadata_update(pid(), binary(), map()) -> {ok, adapter_status()} | {error, not_found}.
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
-spec thread_loaded_list(pid()) -> {ok, adapter_status()}.
thread_loaded_list(Session) ->
    thread_loaded_list(Session, #{}).
-spec thread_loaded_list(pid(), map()) -> {ok, adapter_status()}.
thread_loaded_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, with_adapter_source(#{
        threads => Threads,
        active_thread_id => active_thread_id(SessionId),
        count => length(Threads)
    })}.
-spec thread_compact(pid(), map()) -> {ok, adapter_status()} | {error, invalid_selector | not_found}.
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
-spec thread_realtime_start(pid(), map()) -> {ok, map()}.
thread_realtime_start(Session, Params) when is_map(Params) ->
    beam_agent_control:start_realtime(get_session_id(Session), with_backend(Params, claude)).
-spec thread_realtime_append_audio(pid(), binary(), map()) -> {ok, map()} | {error, not_found}.
thread_realtime_append_audio(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    beam_agent_control:append_realtime_audio(get_session_id(Session), ThreadId, Params).
-spec thread_realtime_append_text(pid(), binary(), map()) -> {ok, map()} | {error, not_found}.
thread_realtime_append_text(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    beam_agent_control:append_realtime_text(get_session_id(Session), ThreadId, Params).
-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_realtime_stop(Session, ThreadId) when is_binary(ThreadId) ->
    beam_agent_control:stop_realtime(get_session_id(Session), ThreadId).
-spec review_start(pid(), map()) -> {ok, map()}.
review_start(Session, Params) when is_map(Params) ->
    beam_agent_control:start_review(get_session_id(Session), with_backend(Params, claude)).
-spec collaboration_mode_list(pid()) -> {ok, adapter_status()}.
collaboration_mode_list(Session) ->
    {ok, Result} = beam_agent_control:collaboration_modes(get_session_id(Session)),
    {ok, with_adapter_source(Result)}.
-spec experimental_feature_list(pid()) -> {ok, adapter_status()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).
-spec experimental_feature_list(pid(), map()) -> {ok, adapter_status()}.
experimental_feature_list(Session, Opts) when is_map(Opts) ->
    {ok, Result} = beam_agent_control:experimental_features(get_session_id(Session), Opts),
    {ok, with_adapter_source(Result)}.
-spec mcp_status(pid()) -> {ok, map()} | {error, term()}.
mcp_status(Session) ->
    mcp_server_status(Session).
-spec mcp_server_status_list(pid()) -> {ok, map()} | {error, term()}.
mcp_server_status_list(Session) ->
    mcp_server_status(Session).
-spec with_adapter_source(#{health => active_query | connecting | error | initializing | ready | unknown, _ => _}) -> adapter_status().
with_adapter_source(Result) ->
    Result#{source => universal, backend => claude}.
-spec with_backend(map(), claude) -> #{backend := claude, _ => _}.
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
-spec include_thread(thread_meta(), boolean()) -> boolean().
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
-spec maybe_put_selector(count | message_id | uuid | visible_message_count, term(),
                         #{count | message_id | uuid | visible_message_count => _}) ->
    #{count | message_id | uuid | visible_message_count => _}.
maybe_put_selector(_Key, undefined, Acc) ->
    Acc;
maybe_put_selector(Key, Value, Acc) ->
    Acc#{Key => Value}.
-spec opt_value([count | include_archived | limit | message_id | selector | status |
                 thread_id | uuid | visible_message_count | <<_:32, _:_*8>>],
                map(), true | undefined) -> any().
opt_value([], _Opts, Default) ->
    Default;
opt_value([Key | Rest], Opts, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Value;
        error -> opt_value(Rest, Opts, Default)
    end.
-spec safe_session_health(pid()) -> active_query | connecting | error | initializing | ready | unknown.
safe_session_health(Session) ->
    try health(Session) of
        Value -> Value
    catch
        _:_ -> unknown
    end.
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}}
            when is_binary(SId), byte_size(SId) > 0 ->
            SId;
        _ ->
            unicode:characters_to_binary(pid_to_list(Session))
    end.
-spec extract_init_field(pid(),
                         init_response_key(),
                         system_info_key(),
                         init_default()) ->
                            {ok, _} | {error, 'reconnecting' | 'session_error'}.
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
            KeyBin = atom_to_binary(Key),
            Value = maps:get(Key, SI, maps:get(KeyBin, SI, Default)),
            {ok, Value};
        _ ->
            {ok, Default}
    end.

-spec discover_models_from_claude_config() -> {ok, [map()]}.
discover_models_from_claude_config() ->
    case claude_config_path() of
        undefined ->
            {ok, []};
        Path ->
            discover_models_from_claude_config(Path)
    end.

-spec claude_config_path() -> file:filename_all() | undefined.
claude_config_path() ->
    case os:getenv("HOME") of
        false ->
            undefined;
        Home ->
            case string:trim(Home) of
                "" ->
                    undefined;
                TrimmedHome ->
                    filename:join([TrimmedHome, ".claude.json"])
            end
    end.

-spec discover_models_from_claude_config(file:filename_all()) ->
    {ok, [map()]}.
discover_models_from_claude_config(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try json:decode(Bin) of
                Decoded ->
                    ModelIds = ordsets:from_list(collect_claude_model_ids(Decoded)),
                    {ok, expand_claude_model_entries([claude_model_entry(Id) || Id <- ModelIds])}
            catch
                _:_ ->
                    {ok, []}
            end;
        {error, _} ->
            {ok, []}
    end.

-spec collect_claude_model_ids(term()) -> [binary()].
collect_claude_model_ids(#{<<"lastModelUsage">> := Usage} = Map)
  when is_map(Usage) ->
    usage_model_ids(Usage) ++
        lists:flatmap(fun collect_claude_model_ids/1, maps:values(Map));
collect_claude_model_ids(#{<<"model">> := Model} = Map) when is_binary(Model) ->
    MaybeModel =
        case Model of
            <<"claude-", _/binary>> ->
                discoverable_claude_model_ids(Model);
            _ ->
                []
        end,
    MaybeModel ++ lists:flatmap(fun collect_claude_model_ids/1,
                                maps:values(Map));
collect_claude_model_ids(Map) when is_map(Map) ->
    lists:flatmap(fun collect_claude_model_ids/1, maps:values(Map));
collect_claude_model_ids(List) when is_list(List) ->
    lists:flatmap(fun collect_claude_model_ids/1, List);
collect_claude_model_ids(_) ->
    [].

-spec usage_model_ids(map()) -> [binary()].
usage_model_ids(Usage) ->
    [Model
     || ModelId <- maps:keys(Usage),
        is_binary(ModelId),
        Model <- discoverable_claude_model_ids(ModelId),
        case Model of
            <<"claude-", _/binary>> -> true;
            _ -> false
        end].

-spec normalize_claude_model_id(binary()) -> binary().
normalize_claude_model_id(ModelId) when is_binary(ModelId) ->
    hd(binary:split(ModelId, <<"[">>)).

-spec discoverable_claude_model_ids(binary()) -> [binary()].
discoverable_claude_model_ids(ModelId) when is_binary(ModelId) ->
    BaseModelId = normalize_claude_model_id(ModelId),
    case supports_context_variant(BaseModelId) of
        true ->
            ordsets:from_list([BaseModelId, context_variant_model_id(BaseModelId)]);
        false when BaseModelId =:= <<>> ->
            [];
        false ->
            [BaseModelId]
    end.

-spec supports_context_variant(binary()) -> boolean().
supports_context_variant(<<"claude-sonnet-4-6">>) -> true;
supports_context_variant(<<"claude-opus-4-6">>) -> true;
supports_context_variant(_) -> false.

-spec expand_claude_model_entries([map()]) -> [map()].
expand_claude_model_entries(Models) when is_list(Models) ->
    lists:reverse(
      lists:foldl(
        fun expand_claude_model_entry/2,
        [],
        Models)).

-spec expand_claude_model_entry(map(), [map()]) -> [map()].
expand_claude_model_entry(Model, Acc) when is_map(Model) ->
    case claude_model_entry_ids(Model) of
        [] ->
            [Model | Acc];
        ModelIds ->
            lists:foldl(
              fun(ModelId, InnerAcc) ->
                  put_unique_claude_model_entry(clone_claude_model_entry(Model, ModelId), InnerAcc)
              end,
              Acc,
              ModelIds)
    end;
expand_claude_model_entry(Model, Acc) ->
    [Model | Acc].

-spec put_unique_claude_model_entry(map(), [map()]) -> [map()].
put_unique_claude_model_entry(Model, Acc) ->
    case claude_model_entry_id(Model) of
        undefined ->
            [Model | Acc];
        ModelId ->
            case lists:any(
                   fun(Existing) ->
                       claude_model_entry_id(Existing) =:= ModelId
                   end,
                   Acc) of
                true -> Acc;
                false -> [Model | Acc]
            end
    end.

-spec claude_model_entry_ids(map()) -> [binary()].
claude_model_entry_ids(Model) when is_map(Model) ->
    case claude_model_entry_id(Model) of
        undefined -> [];
        ModelId -> discoverable_claude_model_ids(ModelId)
    end.

-spec claude_model_entry_id(map()) -> binary() | undefined.
claude_model_entry_id(#{<<"modelId">> := ModelId}) when is_binary(ModelId) ->
    ModelId;
claude_model_entry_id(#{modelId := ModelId}) when is_binary(ModelId) ->
    ModelId;
claude_model_entry_id(#{model_id := ModelId}) when is_binary(ModelId) ->
    ModelId;
claude_model_entry_id(_) ->
    undefined.

-spec clone_claude_model_entry(map(), binary()) -> map().
clone_claude_model_entry(Model, ModelId) when is_map(Model), is_binary(ModelId) ->
    Model1 =
        case Model of
            #{<<"modelId">> := _} -> Model#{<<"modelId">> => ModelId};
            #{modelId := _} -> Model#{modelId => ModelId};
            #{model_id := _} -> Model#{model_id => ModelId};
            _ -> Model
        end,
    case Model1 of
        #{<<"name">> := _} -> Model1#{<<"name">> => ModelId};
        #{name := _} -> Model1#{name => ModelId};
        _ -> Model1
    end.

-spec context_variant_model_id(binary()) -> binary().
context_variant_model_id(BaseModelId) when is_binary(BaseModelId) ->
    <<BaseModelId/binary, "[1m]">>.

-spec claude_model_entry(binary()) -> map().
claude_model_entry(ModelId) ->
    #{<<"modelId">> => ModelId,
      <<"name">> => ModelId}.

%%====================================================================
%% beam_agent_adapter callbacks
%%====================================================================

-spec backend_name() -> claude.
backend_name() -> claude.

-spec backend_type() -> agentic.
backend_type() -> agentic.

-spec capabilities() -> [beam_agent_adapter:capability()].
capabilities() ->
    [session_lifecycle, session_info, runtime_model_switch, interrupt,
     permission_mode, session_history, session_mutation, thread_management,
     metadata_accessors, in_process_mcp, mcp_management, hooks,
     checkpointing, thinking_budget, task_stop, command_execution,
     approval_callbacks, user_input_callbacks, realtime_review,
     config_management, provider_management, attachments, event_streaming].
