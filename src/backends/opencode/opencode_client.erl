-module(opencode_client).

%% Thread record as stored in thread_core (matches dialyzer-inferred shape)
-type thread_record() ::
    #{'created_at' := integer(),
      'message_count' := non_neg_integer(),
      'session_id' := binary(),
      'status' := 'active' | 'archived' | 'completed' | 'paused',
      'thread_id' := binary(),
      'updated_at' := integer(),
      'visible_message_count' := non_neg_integer(),
      'archived' => boolean(),
      'archived_at' => integer(),
      'metadata' => map(),
      'name' => binary(),
      'parent_thread_id' => binary(),
      'summary' => map()}.

%% Session view returned by with_adapter_source/2
-type session_view() ::
    #{'backend' := 'opencode',
      'source' := 'universal',
      'active_thread_id' => 'undefined' | binary(),
      'compacted' => 'true',
      'count' => non_neg_integer(),
      'features' => [map(), ...],
      'metadata' => _,
      'modes' => [map(), ...],
      'name' => binary(),
      'selector' => map(),
      'session_id' => binary(),
      'thread' => thread_record(),
      'thread_id' => binary(),
      'threads' => [map()],
      'unsubscribed' => 'true'}.

%% Thread resume result (thread_read shape)
-type thread_resume_result() ::
    #{'archived' => boolean(),
      'archived_at' => integer(),
      'created_at' => integer(),
      'message_count' => non_neg_integer(),
      'messages' => [map()],
      'metadata' => map(),
      'name' => binary(),
      'parent_thread_id' => binary(),
      'session_id' => binary(),
      'status' => 'active',
      'summary' => map(),
      'thread' => thread_record(),
      'thread_id' => binary(),
      'updated_at' => integer(),
      'visible_message_count' => non_neg_integer()}.

-export([start_session/1,
         stop/1,
         child_spec/1,
         query/2,
         query/3,
         event_subscribe/1,
         receive_event/3,
         event_unsubscribe/2,
         abort/1,
         interrupt/1,
         session_info/1,
         set_model/2,
         set_permission_mode/2,
         health/1,
         send_control/3,
         mcp_tool/4,
         mcp_server/2,
         sdk_hook/2,
         sdk_hook/3,
         app_info/1,
         app_init/1,
         app_log/2,
         app_modes/1,
         list_server_sessions/1,
         get_server_session/2,
         delete_server_session/2,
         config_read/1,
         config_update/2,
         config_providers/1,
         find_text/2,
         find_files/2,
         find_symbols/2,
         file_list/2,
         file_read/2,
         file_status/1,
         provider_list/1,
         provider_auth_methods/1,
         provider_oauth_authorize/3,
         provider_oauth_callback/3,
         list_commands/1,
         mcp_status/1,
         add_mcp_server/2,
         list_server_agents/1,
         session_init/2,
         session_messages/1,
         session_messages/2,
         prompt_async/2,
         prompt_async/3,
         shell_command/2,
         shell_command/3,
         tui_append_prompt/2,
         tui_open_help/1,
         send_command/3,
         server_health/1,
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
         supported_commands/1,
         supported_models/1,
         supported_agents/1,
         account_info/1,
         set_max_thinking_tokens/2,
         rewind_files/2,
         stop_task/2,
         command_write_stdin/3,
         command_write_stdin/4,
         config_value_write/3,
         config_value_write/4,
         config_batch_write/2,
         config_batch_write/3,
         config_requirements_read/1,
         external_agent_config_detect/1,
         external_agent_config_detect/2,
         external_agent_config_import/2,
         command_run/2,
         command_run/3,
         submit_feedback/2,
         turn_respond/3]).

%% Return shape is from universal core; map() is intentional.
-dialyzer({nowarn_function,
           [{config_value_write, 3},
            {config_value_write, 4},
            {config_batch_write, 2},
            {config_batch_write, 3},
            {config_requirements_read, 1},
            {external_agent_config_detect, 1},
            {external_agent_config_detect, 2},
            {external_agent_config_import, 2},
            {thread_realtime_start, 2},
            {thread_realtime_append_audio, 3},
            {thread_realtime_append_text, 3},
            {thread_realtime_stop, 2},
            {review_start, 2},
            {with_adapter_source, 2},
            {maybe_include_thread_read, 4}]}).
-dialyzer({no_underspecs,
           [{send_control, 3},
            {fork_session, 2},
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
            {extract_init_field, 4},
            {extract_from_system_info, 3}]}).
-spec start_session(beam_agent_core:session_opts()) ->
                       {ok, pid()} | {error, term()}.
start_session(Opts) ->
    opencode_session:start_link(Opts).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id =
        case maps:get(session_id, Opts, undefined) of
            undefined ->
                opencode_session;
            SId when is_binary(SId) ->
                {opencode_session, SId};
            SId ->
                {opencode_session, SId}
        end,
    #{id => Id,
      start => {opencode_session, start_link, [Opts]},
      restart => transient,
      shutdown => 10000,
      type => worker,
      modules => [opencode_session]}.
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
        gen_statem:call(Session, {send_query, Prompt, Params}, Timeout)
    of
        {ok, Ref} ->
            ReceiveFun =
                fun(S, R, T) ->
                       gen_statem:call(S, {receive_message, R}, T)
                end,
            beam_agent_core:collect_messages(Session, Ref, Deadline,
                                        ReceiveFun);
        {error, _} = Err ->
            Err
    end.

-spec event_subscribe(pid()) -> {ok, reference()}.
event_subscribe(Session) ->
    opencode_session:subscribe_events(Session).

-spec receive_event(pid(), reference(), timeout()) ->
                       {ok, beam_agent_core:message()} | {error, term()}.
receive_event(Session, Ref, Timeout) ->
    opencode_session:receive_event(Session, Ref, Timeout).

-spec event_unsubscribe(pid(), reference()) -> ok | {error, term()}.
event_unsubscribe(Session, Ref) ->
    opencode_session:unsubscribe_events(Session, Ref).

-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    gen_statem:call(Session, abort, 10000).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    abort(Session).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).
-spec set_permission_mode(pid(), binary()) -> {ok, map()}.
set_permission_mode(Session, Mode) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:set_permission_mode(SessionId, Mode),
    {ok, #{permission_mode => Mode}}.
-spec health(pid()) ->
                ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).
-spec send_control(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    SessionId = get_session_id(Session),
    beam_agent_control_core:dispatch(SessionId, Method, Params).
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
-spec app_info(pid()) -> {ok, map()} | {error, term()}.
app_info(Session) ->
    gen_statem:call(Session, app_info, 10000).
-spec app_init(pid()) -> {ok, term()} | {error, term()}.
app_init(Session) ->
    gen_statem:call(Session, app_init, 10000).
-spec app_log(pid(), map()) -> {ok, term()} | {error, term()}.
app_log(Session, Body) when is_map(Body) ->
    gen_statem:call(Session, {app_log, Body}, 10000).
-spec list_server_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    gen_statem:call(Session, list_sessions, 10000).
-spec get_server_session(pid(), binary()) ->
                            {ok, map()} | {error, term()}.
get_server_session(Session, Id) ->
    gen_statem:call(Session, {get_session, Id}, 10000).
-spec delete_server_session(pid(), binary()) ->
                               {ok, term()} | {error, term()}.
delete_server_session(Session, Id) ->
    gen_statem:call(Session, {delete_session, Id}, 10000).
-spec app_modes(pid()) -> {ok, term()} | {error, term()}.
app_modes(Session) ->
    gen_statem:call(Session, app_modes, 10000).
-spec config_read(pid()) -> {ok, map()} | {error, term()}.
config_read(Session) ->
    gen_statem:call(Session, config_read, 10000).
-spec config_update(pid(), map()) -> {ok, map()} | {error, term()}.
config_update(Session, Body) when is_map(Body) ->
    gen_statem:call(Session, {config_update, Body}, 10000).
-spec config_providers(pid()) -> {ok, map()} | {error, term()}.
config_providers(Session) ->
    gen_statem:call(Session, config_providers, 10000).
-spec find_text(pid(), binary()) -> {ok, term()} | {error, term()}.
find_text(Session, Pattern) when is_binary(Pattern) ->
    gen_statem:call(Session, {find_text, Pattern}, 10000).
-spec find_files(pid(), map()) -> {ok, term()} | {error, term()}.
find_files(Session, Opts) when is_map(Opts) ->
    gen_statem:call(Session, {find_files, Opts}, 10000).
-spec find_symbols(pid(), binary()) -> {ok, term()} | {error, term()}.
find_symbols(Session, Query) when is_binary(Query) ->
    gen_statem:call(Session, {find_symbols, Query}, 10000).
-spec file_list(pid(), binary()) -> {ok, term()} | {error, term()}.
file_list(Session, Path) when is_binary(Path) ->
    gen_statem:call(Session, {file_list, Path}, 10000).
-spec file_read(pid(), binary()) -> {ok, term()} | {error, term()}.
file_read(Session, Path) when is_binary(Path) ->
    gen_statem:call(Session, {file_read, Path}, 10000).
-spec file_status(pid()) -> {ok, term()} | {error, term()}.
file_status(Session) ->
    gen_statem:call(Session, file_status, 10000).
-spec provider_list(pid()) -> {ok, map()} | {error, term()}.
provider_list(Session) ->
    gen_statem:call(Session, provider_list, 10000).
-spec provider_auth_methods(pid()) -> {ok, map()} | {error, term()}.
provider_auth_methods(Session) ->
    gen_statem:call(Session, provider_auth_methods, 10000).
-spec provider_oauth_authorize(pid(), binary(), map()) ->
                                  {ok, map()} | {error, term()}.
provider_oauth_authorize(Session, ProviderId, Body)
    when is_binary(ProviderId), is_map(Body) ->
    gen_statem:call(Session,
                    {provider_oauth_authorize, ProviderId, Body},
                    10000).
-spec provider_oauth_callback(pid(), binary(), map()) ->
                                 {ok, map()} | {error, term()}.
provider_oauth_callback(Session, ProviderId, Body)
    when is_binary(ProviderId), is_map(Body) ->
    gen_statem:call(Session,
                    {provider_oauth_callback, ProviderId, Body},
                    10000).
-spec config_value_write(pid(), binary(), _) -> {ok, map()} | {error, _}.
config_value_write(Session, KeyPath, Value) ->
    config_value_write(Session, KeyPath, Value, #{}).
-spec config_value_write(pid(), binary(), _, map()) ->
                            {ok, map()} | {error, _}.
config_value_write(Session, KeyPath, Value, Opts)
    when is_binary(KeyPath), is_map(Opts) ->
    beam_agent_config:config_value_write(Session, KeyPath, Value, Opts).
-spec config_batch_write(pid(), [map()]) -> {ok, map()} | {error, _}.
config_batch_write(Session, Edits) ->
    config_batch_write(Session, Edits, #{}).
-spec config_batch_write(pid(), [map()], map()) ->
                            {ok, map()} | {error, _}.
config_batch_write(Session, Edits, Opts)
    when is_list(Edits), is_map(Opts) ->
    beam_agent_config:config_batch_write(Session, Edits, Opts).
-spec config_requirements_read(pid()) -> {ok, map()}.
config_requirements_read(Session) ->
    beam_agent_config:config_requirements_read(Session).
-spec external_agent_config_detect(pid()) -> {ok, map()} | {error, _}.
external_agent_config_detect(Session) ->
    external_agent_config_detect(Session, #{}).
-spec external_agent_config_detect(pid(), map()) -> {ok, map()} | {error, _}.
external_agent_config_detect(Session, Opts) when is_map(Opts) ->
    beam_agent_config:external_agent_config_detect(Session, Opts).
-spec external_agent_config_import(pid(), map()) -> {ok, map()} | {error, _}.
external_agent_config_import(Session, Opts) when is_map(Opts) ->
    beam_agent_config:external_agent_config_import(Session, Opts).
-spec list_commands(pid()) -> {ok, map()} | {error, term()}.
list_commands(Session) ->
    gen_statem:call(Session, list_commands, 10000).
-spec mcp_status(pid()) -> {ok, map()} | {error, term()}.
mcp_status(Session) ->
    gen_statem:call(Session, mcp_status, 10000).
-spec add_mcp_server(pid(), map()) -> {ok, map()} | {error, term()}.
add_mcp_server(Session, Body) when is_map(Body) ->
    gen_statem:call(Session, {add_mcp_server, Body}, 10000).
-spec list_server_agents(pid()) -> {ok, map()} | {error, term()}.
list_server_agents(Session) ->
    gen_statem:call(Session, list_agents, 10000).
-spec session_init(pid(), map()) -> {ok, term()} | {error, term()}.
session_init(Session, Opts) when is_map(Opts) ->
    gen_statem:call(Session, {session_init, Opts}, 10000).
-spec session_messages(pid()) -> {ok, term()} | {error, term()}.
session_messages(Session) ->
    gen_statem:call(Session, session_messages, 10000).
-spec session_messages(pid(), map()) -> {ok, term()} | {error, term()}.
session_messages(Session, Opts) when is_map(Opts) ->
    gen_statem:call(Session, {session_messages, Opts}, 10000).
-spec prompt_async(pid(), binary()) -> {ok, term()} | {error, term()}.
prompt_async(Session, Prompt) when is_binary(Prompt) ->
    prompt_async(Session, Prompt, #{}).
-spec prompt_async(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
prompt_async(Session, Prompt, Params)
    when is_binary(Prompt), is_map(Params) ->
    gen_statem:call(Session, {prompt_async, Prompt, Params}, 10000).
-spec shell_command(pid(), binary()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command) when is_binary(Command) ->
    shell_command(Session, Command, #{}).
-spec shell_command(pid(), binary(), map()) ->
                       {ok, term()} | {error, term()}.
shell_command(Session, Command, Opts)
    when is_binary(Command), is_map(Opts) ->
    gen_statem:call(Session, {shell_command, Command, Opts}, 10000).

-spec tui_append_prompt(pid(), binary()) ->
                           {ok, term()} | {error, term()}.
tui_append_prompt(Session, Text) when is_binary(Text) ->
    gen_statem:call(Session, {tui_append_prompt, Text}, 10000).

-spec tui_open_help(pid()) -> {ok, term()} | {error, term()}.
tui_open_help(Session) ->
    gen_statem:call(Session, tui_open_help, 10000).

-spec send_command(pid(), binary(), map()) ->
                      {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    gen_statem:call(Session, {send_command, Command, Params}, 30000).
-spec server_health(pid()) -> {ok, map()} | {error, term()}.
server_health(Session) ->
    gen_statem:call(Session, server_health, 5000).
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
                        {error, not_found | invalid_selector | term()}.
revert_session(Session, Selector) ->
    SessionId = get_session_id(Session),
    case gen_statem:call(Session, {revert_session, Selector}, 30000) of
        {ok, Result} ->
            _ = beam_agent_session_store_core:revert_session(SessionId,
                                                        Selector),
            {ok, Result};
        {error, not_supported} ->
            beam_agent_session_store_core:revert_session(SessionId, Selector);
        {error, _} = Err ->
            Err
    end.
-spec unrevert_session(pid()) ->
                          {ok, map()} | {error, not_found | term()}.
unrevert_session(Session) ->
    SessionId = get_session_id(Session),
    case gen_statem:call(Session, unrevert_session, 30000) of
        {ok, Result} ->
            _ = beam_agent_session_store_core:unrevert_session(SessionId),
            {ok, Result};
        {error, not_supported} ->
            beam_agent_session_store_core:unrevert_session(SessionId);
        {error, _} = Err ->
            Err
    end.
-spec share_session(pid()) -> {ok, map()} | {error, not_found | term()}.
share_session(Session) ->
    share_session(Session, #{}).
-spec share_session(pid(), map()) ->
                       {ok, map()} | {error, not_found | term()}.
share_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    case gen_statem:call(Session, share_session, 10000) of
        {ok, Result} ->
            _ = beam_agent_session_store_core:share_session(SessionId, Opts),
            {ok, Result};
        {error, not_supported} ->
            beam_agent_session_store_core:share_session(SessionId, Opts);
        {error, _} = Err ->
            Err
    end.
-spec unshare_session(pid()) -> ok | {error, not_found | term()}.
unshare_session(Session) ->
    SessionId = get_session_id(Session),
    case gen_statem:call(Session, unshare_session, 10000) of
        {ok, _Result} ->
            beam_agent_session_store_core:unshare_session(SessionId);
        {error, not_supported} ->
            beam_agent_session_store_core:unshare_session(SessionId);
        {error, _} = Err ->
            Err
    end.
-spec summarize_session(pid()) ->
                           {ok, map()} | {error, not_found | term()}.
summarize_session(Session) ->
    summarize_session(Session, #{}).
-spec summarize_session(pid(), map()) ->
                           {ok, map()} | {error, not_found | term()}.
summarize_session(Session, Opts) ->
    SessionId = get_session_id(Session),
    case gen_statem:call(Session, {summarize_session, Opts}, 30000) of
        {ok, Result} ->
            _ = beam_agent_session_store_core:summarize_session(SessionId,
                                                           Opts),
            {ok, Result};
        {error, invalid_summary_opts} ->
            beam_agent_session_store_core:summarize_session(SessionId, Opts);
        {error, not_supported} ->
            beam_agent_session_store_core:summarize_session(SessionId, Opts);
        {error, _} = Err ->
            Err
    end.
-spec thread_start(pid(), map()) -> {ok, map()}.
thread_start(Session, Opts) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:start_thread(SessionId, Opts).
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_resume(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_threads_core:resume_thread(SessionId, ThreadId).
-spec thread_resume(pid(), binary(), map()) -> {ok, thread_resume_result()} | {error, not_found}.
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
                            {ok, session_view()} | {error, not_found}.
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
                         {ok, session_view()} | {error, not_found}.
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
                                {ok, session_view()} | {error, not_found}.
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
-spec thread_loaded_list(pid()) -> {ok, session_view()}.
thread_loaded_list(Session) ->
    thread_loaded_list(Session, #{}).
-spec thread_loaded_list(pid(), map()) -> {ok, session_view()}.
thread_loaded_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, with_adapter_source(Session, #{
        threads => Threads,
        active_thread_id => active_thread_id(SessionId),
        count => length(Threads)
    })}.
-spec thread_compact(pid(), map()) -> {ok, session_view()} | {error, invalid_selector | not_found}.
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
-spec thread_realtime_start(pid(), map()) -> {ok, map()}.
thread_realtime_start(Session, Params) when is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:start_realtime(SessionId, with_backend(Params, opencode)).
-spec thread_realtime_append_audio(pid(), binary(), map()) ->
                                      {ok, map()} | {error, not_found}.
thread_realtime_append_audio(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:append_realtime_audio(SessionId, ThreadId, Params).
-spec thread_realtime_append_text(pid(), binary(), map()) ->
                                     {ok, map()} | {error, not_found}.
thread_realtime_append_text(Session, ThreadId, Params)
    when is_binary(ThreadId), is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:append_realtime_text(SessionId, ThreadId, Params).
-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_realtime_stop(Session, ThreadId) when is_binary(ThreadId) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:stop_realtime(SessionId, ThreadId).
-spec review_start(pid(), map()) -> {ok, map()}.
review_start(Session, Params) when is_map(Params) ->
    SessionId = get_session_id(Session),
    beam_agent_collaboration:start_review(SessionId, with_backend(Params, opencode)).
-spec collaboration_mode_list(pid()) -> {ok, session_view()}.
collaboration_mode_list(Session) ->
    SessionId = get_session_id(Session),
    {ok, Result} = beam_agent_collaboration:collaboration_modes(SessionId),
    {ok, with_adapter_source(Session, Result)}.
-spec experimental_feature_list(pid()) -> {ok, session_view()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).
-spec experimental_feature_list(pid(), map()) -> {ok, session_view()}.
experimental_feature_list(Session, Opts) when is_map(Opts) ->
    SessionId = get_session_id(Session),
    {ok, Result} = beam_agent_collaboration:experimental_features(SessionId, Opts),
    {ok, with_adapter_source(Session, Result)}.
-spec mcp_server_status(pid()) -> {ok, map()}.
mcp_server_status(Session) ->
    case beam_agent_tool_registry:get_session_registry(Session) of
        {ok, Registry} ->
            beam_agent_tool_registry:server_status(Registry);
        {error, not_found} ->
            {ok, #{}}
    end.
-spec set_mcp_servers(pid(), [beam_agent_tool_registry:sdk_mcp_server()]) ->
                         {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    case
        beam_agent_tool_registry:update_session_registry(Session,
                                               fun(R) ->
                                                      beam_agent_tool_registry:set_servers(Servers,
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
    case beam_agent_tool_registry:get_session_registry(Session) of
        {ok, Registry} ->
            case
                beam_agent_tool_registry:reconnect_server(ServerName, Registry)
            of
                {ok, Updated} ->
                    beam_agent_tool_registry:register_session_registry(Session,
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
    case beam_agent_tool_registry:get_session_registry(Session) of
        {ok, Registry} ->
            case
                beam_agent_tool_registry:toggle_server(ServerName, Enabled,
                                             Registry)
            of
                {ok, Updated} ->
                    beam_agent_tool_registry:register_session_registry(Session,
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
-spec command_write_stdin(pid(), binary(), binary()) -> {error, not_found}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).
-spec command_write_stdin(pid(), binary(), binary(), map()) -> {error, not_found}.
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

-spec with_adapter_source(pid(), map()) -> session_view().
with_adapter_source(_Session, Result) ->
    Result#{source => universal, backend => opencode}.

-spec with_backend(map(), opencode) -> #{backend := opencode, _ => _}.
with_backend(Params, Backend) ->
    maps:put(backend, Backend, Params).

-spec active_thread_id(binary()) -> binary() | undefined.
active_thread_id(SessionId) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} -> ThreadId;
        {error, _} -> undefined
    end.

-spec maybe_include_thread_read(binary(), binary(), map(), thread_record()) -> {ok, thread_resume_result()} | {error, not_found}.
maybe_include_thread_read(SessionId, ThreadId, Opts, Thread) ->
    case opt_value([include_messages, <<"include_messages">>, <<"includeMessages">>], Opts, false) of
        true -> beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts);
        false -> {ok, Thread}
    end.

-spec filter_loaded_threads([map()], map()) -> [map()].
filter_loaded_threads(Threads, Opts) ->
    IncludeArchived = opt_value(
        [include_archived, <<"include_archived">>, <<"includeArchived">>], Opts, true),
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

-spec include_thread(thread_record(), boolean()) -> boolean().
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

-spec maybe_put_selector(count | message_id | uuid | visible_message_count, _, #{count | message_id | uuid | visible_message_count => _}) -> #{count | message_id | uuid | visible_message_count => _}.
maybe_put_selector(_Key, undefined, Acc) ->
    Acc;
maybe_put_selector(Key, Value, Acc) ->
    maps:put(Key, Value, Acc).

-spec opt_value([count | include_archived | include_messages | limit | message_id | selector | status | thread_id | uuid | visible_message_count | <<_:32, _:_*8>>], map(), false | true | undefined) -> any().
opt_value([], _Opts, Default) ->
    Default;
opt_value([Key | Rest], Opts, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Value;
        error -> opt_value(Rest, Opts, Default)
    end.
