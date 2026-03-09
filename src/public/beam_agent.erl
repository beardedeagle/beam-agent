-module(beam_agent).
-moduledoc """
Canonical public Erlang SDK for the consolidated BEAM agent package.

`beam_agent` is the stable package-level boundary for callers. It exposes the
shared BEAM agent runtime through a single canonical package-level interface.
Use `beam_agent_raw` when you need the explicit backend-native namespace.
""".

-export([
    start_session/1,
    child_spec/1,
    stop/1,
    query/2,
    query/3,
    event_subscribe/1,
    receive_event/2,
    receive_event/3,
    event_unsubscribe/2,
    session_info/1,
    health/1,
    backend/1,
    list_backends/0,
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    send_control/3,
    list_sessions/0,
    list_sessions/1,
    list_native_sessions/0,
    list_native_sessions/1,
    get_session_messages/1,
    get_session_messages/2,
    get_native_session_messages/1,
    get_native_session_messages/2,
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
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    account_info/1,
    list_commands/1,
    list_tools/1,
    list_skills/1,
    list_plugins/1,
    list_mcp_servers/1,
    list_agents/1,
    skills_list/1,
    skills_list/2,
    skills_remote_list/1,
    skills_remote_list/2,
    skills_remote_export/2,
    skills_config_write/3,
    apps_list/1,
    apps_list/2,
    app_info/1,
    app_init/1,
    app_log/2,
    app_modes/1,
    model_list/1,
    model_list/2,
    get_status/1,
    get_auth_status/1,
    get_last_session_id/1,
    get_tool/2,
    get_skill/2,
    get_plugin/2,
    get_agent/2,
    current_provider/1,
    set_provider/2,
    clear_provider/1,
    provider_list/1,
    provider_auth_methods/1,
    provider_oauth_authorize/3,
    provider_oauth_callback/3,
    current_agent/1,
    set_agent/2,
    clear_agent/1,
    list_server_sessions/1,
    get_server_session/2,
    delete_server_session/2,
    list_server_agents/1,
    config_read/1,
    config_read/2,
    config_update/2,
    config_providers/1,
    find_text/2,
    find_files/2,
    find_symbols/2,
    file_list/2,
    file_read/2,
    file_status/1,
    config_value_write/3,
    config_value_write/4,
    config_batch_write/2,
    config_batch_write/3,
    config_requirements_read/1,
    external_agent_config_detect/1,
    external_agent_config_detect/2,
    external_agent_config_import/2,
    mcp_status/1,
    add_mcp_server/2,
    mcp_server_status/1,
    set_mcp_servers/2,
    reconnect_mcp_server/2,
    toggle_mcp_server/3,
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
    set_max_thinking_tokens/2,
    rewind_files/2,
    stop_task/2,
    session_init/2,
    session_messages/1,
    session_messages/2,
    prompt_async/2,
    prompt_async/3,
    shell_command/2,
    shell_command/3,
    tui_append_prompt/2,
    tui_open_help/1,
    session_destroy/1,
    session_destroy/2,
    command_run/2,
    command_run/3,
    command_write_stdin/3,
    command_write_stdin/4,
    submit_feedback/2,
    turn_respond/3,
    send_command/3,
    server_health/1,
    capabilities/0,
    capabilities/1,
    supports/2,
    normalize_message/1,
    make_request_id/0,
    parse_stop_reason/1,
    parse_permission_mode/1,
    collect_messages/4,
    collect_messages/5
]).

-export_type([
    message/0,
    message_type/0,
    query_opts/0,
    session_opts/0,
    backend/0,
    stop_reason/0,
    permission_mode/0,
    system_prompt_config/0,
    permission_result/0,
    receive_fun/0,
    terminal_pred/0
]).

-type message() :: beam_agent_core:message().
-type message_type() :: beam_agent_core:message_type().
-type query_opts() :: beam_agent_core:query_opts().
-type session_opts() :: beam_agent_core:session_opts().
-type backend() :: beam_agent_core:backend().
-type stop_reason() :: beam_agent_core:stop_reason().
-type permission_mode() :: beam_agent_core:permission_mode().
-type system_prompt_config() :: beam_agent_core:system_prompt_config().
-type permission_result() :: beam_agent_core:permission_result().
-type receive_fun() :: beam_agent_core:receive_fun().
-type terminal_pred() :: beam_agent_core:terminal_pred().
-type capability_error() :: backend_not_present
                          | {invalid_session_info, term()}
                          | {session_backend_lookup_failed, term()}
                          | {unknown_backend, term()}.
-type supports_error() ::
    {unknown_backend, term()} | {unknown_capability, beam_agent_capabilities:capability()}.

-dialyzer({no_underspecs, [
    command_run/2,
    universal_thread_unsubscribe/2,
    universal_thread_name_set/3,
    universal_thread_metadata_update/3,
    universal_thread_loaded_list/2,
    universal_thread_compact/2,
    universal_get_status/1,
    universal_get_auth_status/1,
    universal_session_destroy/2,
    with_universal_source/2,
    include_thread/2,
    maybe_put_selector/3,
    universal_command_run/3,
    universal_submit_feedback/2,
    universal_turn_respond/3
]}).

-spec start_session(session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) -> beam_agent_core:start_session(Opts).

-spec child_spec(session_opts()) -> supervisor:child_spec().
child_spec(Opts) -> beam_agent_core:child_spec(Opts).

-spec stop(pid()) -> ok.
stop(Session) -> beam_agent_core:stop(Session).

-spec query(pid(), binary()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt) -> beam_agent_core:query(Session, Prompt).

-spec query(pid(), binary(), query_opts()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt, Params) -> beam_agent_core:query(Session, Prompt, Params).

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) -> beam_agent_core:session_info(Session).

-spec event_subscribe(pid()) -> {ok, reference()} | {error, term()}.
event_subscribe(Session) ->
    native_or(Session, event_subscribe, [], fun() ->
        beam_agent_events:subscribe(session_identity(Session))
    end).

-spec receive_event(pid(), reference()) -> {ok, message()} | {error, term()}.
receive_event(Session, Ref) ->
    receive_event(Session, Ref, 5000).

-spec receive_event(pid(), reference(), timeout()) ->
    {ok, message()} | {error, term()}.
receive_event(Session, Ref, Timeout) ->
    native_or(Session, receive_event, [Ref, Timeout], fun() ->
        beam_agent_events:receive_event(Ref, Timeout)
    end).

-spec event_unsubscribe(pid(), reference()) -> {ok, term()} | {error, term()}.
event_unsubscribe(Session, Ref) ->
    native_or(Session, event_unsubscribe, [Ref], fun() ->
        beam_agent_events:unsubscribe(session_identity(Session), Ref)
    end).

-spec health(pid()) -> atom().
health(Session) -> beam_agent_core:health(Session).

-spec backend(pid()) -> {ok, backend()} | {error, term()}.
backend(Session) -> beam_agent_core:backend(Session).

-spec list_backends() -> [backend()].
list_backends() -> beam_agent_core:list_backends().

-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) -> beam_agent_core:set_model(Session, Model).

-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) -> beam_agent_core:set_permission_mode(Session, Mode).

-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) -> beam_agent_core:interrupt(Session).

-spec abort(pid()) -> ok | {error, term()}.
abort(Session) -> beam_agent_core:abort(Session).

-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    beam_agent_core:send_control(Session, Method, Params).

-spec list_sessions() -> {ok, [beam_agent_session_store:session_meta()]}.
list_sessions() -> beam_agent_core:list_sessions().

-spec list_sessions(beam_agent_session_store:list_opts()) ->
    {ok, [beam_agent_session_store:session_meta()]}.
list_sessions(Opts) -> beam_agent_core:list_sessions(Opts).

-spec list_native_sessions() -> {ok, list()} | {error, term()}.
list_native_sessions() ->
    case beam_agent_raw_core:call_backend(claude, list_native_sessions, []) of
        {error, {unsupported_native_call, _}} -> list_sessions();
        Other -> Other
    end.

-spec list_native_sessions(map()) -> {ok, list()} | {error, term()}.
list_native_sessions(Opts) ->
    case beam_agent_raw_core:call_backend(claude, list_native_sessions, [Opts]) of
        {error, {unsupported_native_call, _}} -> list_sessions(Opts);
        Other -> Other
    end.

-spec get_session_messages(binary()) -> {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId) -> beam_agent_core:get_session_messages(SessionId).

-spec get_session_messages(binary(), beam_agent_session_store:message_opts()) ->
    {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) ->
    beam_agent_core:get_session_messages(SessionId, Opts).

-spec get_native_session_messages(binary()) -> {ok, list()} | {error, term()}.
get_native_session_messages(SessionId) ->
    case beam_agent_raw_core:call_backend(claude, get_native_session_messages, [SessionId]) of
        {error, {unsupported_native_call, _}} -> get_session_messages(SessionId);
        Other -> Other
    end.

-spec get_native_session_messages(binary(), map()) -> {ok, list()} | {error, term()}.
get_native_session_messages(SessionId, Opts) ->
    case beam_agent_raw_core:call_backend(claude, get_native_session_messages, [SessionId, Opts]) of
        {error, {unsupported_native_call, _}} -> get_session_messages(SessionId, Opts);
        Other -> Other
    end.

-spec get_session(binary()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, not_found}.
get_session(SessionId) -> beam_agent_core:get_session(SessionId).

-spec delete_session(binary()) -> ok.
delete_session(SessionId) -> beam_agent_core:delete_session(SessionId).

-spec fork_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
fork_session(Session, Opts) -> beam_agent_core:fork_session(Session, Opts).

-spec revert_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
revert_session(Session, Selector) -> beam_agent_core:revert_session(Session, Selector).

-spec unrevert_session(pid()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
unrevert_session(Session) -> beam_agent_core:unrevert_session(Session).

-spec share_session(pid()) ->
    {ok, beam_agent_session_store:session_share()} | {error, term()}.
share_session(Session) -> beam_agent_core:share_session(Session).

-spec share_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_share()} | {error, term()}.
share_session(Session, Opts) -> beam_agent_core:share_session(Session, Opts).

-spec unshare_session(pid()) -> ok | {error, term()}.
unshare_session(Session) -> beam_agent_core:unshare_session(Session).

-spec summarize_session(pid()) ->
    {ok, beam_agent_session_store:session_summary()} | {error, term()}.
summarize_session(Session) -> beam_agent_core:summarize_session(Session).

-spec summarize_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_summary()} | {error, term()}.
summarize_session(Session, Opts) -> beam_agent_core:summarize_session(Session, Opts).

-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) -> beam_agent_core:thread_start(Session, Opts).

-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) -> beam_agent_core:thread_resume(Session, ThreadId).

-spec thread_resume(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId, Opts) ->
    native_or(Session, thread_resume, [ThreadId, Opts],
        fun() -> thread_resume(Session, ThreadId) end).

-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) -> beam_agent_core:thread_list(Session).

-spec thread_list(pid(), map()) -> {ok, term()} | {error, term()}.
thread_list(Session, Opts) ->
    native_or(Session, thread_list, [Opts],
        fun() -> thread_list(Session) end).

-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId) -> beam_agent_core:thread_fork(Session, ThreadId).

-spec thread_fork(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId, Opts) -> beam_agent_core:thread_fork(Session, ThreadId, Opts).

-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) -> beam_agent_core:thread_read(Session, ThreadId).

-spec thread_read(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId, Opts) -> beam_agent_core:thread_read(Session, ThreadId, Opts).

-spec thread_archive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_archive(Session, ThreadId) -> beam_agent_core:thread_archive(Session, ThreadId).

-spec thread_unsubscribe(pid(), binary()) -> {ok, term()} | {error, term()}.
thread_unsubscribe(Session, ThreadId) ->
    native_or(Session, thread_unsubscribe, [ThreadId], fun() ->
        universal_thread_unsubscribe(Session, ThreadId)
    end).

-spec thread_name_set(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
thread_name_set(Session, ThreadId, Name) ->
    native_or(Session, thread_name_set, [ThreadId, Name], fun() ->
        universal_thread_name_set(Session, ThreadId, Name)
    end).

-spec thread_metadata_update(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
thread_metadata_update(Session, ThreadId, MetadataPatch) ->
    native_or(Session, thread_metadata_update, [ThreadId, MetadataPatch], fun() ->
        universal_thread_metadata_update(Session, ThreadId, MetadataPatch)
    end).

-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) -> beam_agent_core:thread_unarchive(Session, ThreadId).

-spec thread_rollback(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_rollback(Session, ThreadId, Selector) ->
    beam_agent_core:thread_rollback(Session, ThreadId, Selector).

-spec thread_loaded_list(pid()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session) ->
    native_or(Session, thread_loaded_list, [], fun() ->
        universal_thread_loaded_list(Session, #{})
    end).

-spec thread_loaded_list(pid(), map()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session, Opts) ->
    native_or(Session, thread_loaded_list, [Opts], fun() ->
        universal_thread_loaded_list(Session, Opts)
    end).

-spec thread_compact(pid(), map()) -> {ok, map()} | {error, term()}.
thread_compact(Session, Opts) ->
    native_or(Session, thread_compact, [Opts], fun() ->
        universal_thread_compact(Session, Opts)
    end).

-spec turn_steer(pid(), binary(), binary(), binary() | [map()]) ->
    {ok, term()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input) ->
    turn_steer(Session, ThreadId, TurnId, Input, #{}).

-spec turn_steer(pid(), binary(), binary(), binary() | [map()], map()) ->
    {ok, term()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input, Opts) ->
    native_or(Session, turn_steer, [ThreadId, TurnId, Input, Opts], fun() ->
        %% Universal: record steer intent as a thread message
        SessionId = session_identity(Session),
        SteerMsg = #{type => system,
                     content => <<"steer">>,
                     raw => #{role => <<"system">>, turn_id => TurnId,
                              input => Input, opts => Opts}},
        beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
            SteerMsg),
        {ok, with_universal_source(Session, #{
            status => steered, thread_id => ThreadId,
            turn_id => TurnId})}
    end).

-spec turn_interrupt(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
turn_interrupt(Session, ThreadId, TurnId) ->
    native_or(Session, turn_interrupt, [ThreadId, TurnId], fun() ->
        universal_turn_interrupt(Session, ThreadId, TurnId)
    end).

-spec thread_realtime_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) ->
    native_or(Session, thread_realtime_start, [Params], fun() ->
        beam_agent_collaboration:start_realtime(
            session_identity(Session),
            with_session_backend(Session, Params))
    end).

-spec thread_realtime_append_audio(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params) ->
    native_or(Session, thread_realtime_append_audio, [ThreadId, Params], fun() ->
        beam_agent_collaboration:append_realtime_audio(session_identity(Session), ThreadId, Params)
    end).

-spec thread_realtime_append_text(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params) ->
    native_or(Session, thread_realtime_append_text, [ThreadId, Params], fun() ->
        beam_agent_collaboration:append_realtime_text(session_identity(Session), ThreadId, Params)
    end).

-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) ->
    native_or(Session, thread_realtime_stop, [ThreadId], fun() ->
        beam_agent_collaboration:stop_realtime(session_identity(Session), ThreadId)
    end).

-spec review_start(pid(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) ->
    native_or(Session, review_start, [Params], fun() ->
        beam_agent_collaboration:start_review(
            session_identity(Session),
            with_session_backend(Session, Params))
    end).

-spec collaboration_mode_list(pid()) -> {ok, map()} | {error, term()}.
collaboration_mode_list(Session) ->
    native_or(Session, collaboration_mode_list, [], fun() ->
        beam_agent_collaboration:collaboration_modes(session_identity(Session))
    end).

-spec experimental_feature_list(pid()) -> {ok, term()} | {error, term()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).

-spec experimental_feature_list(pid(), map()) -> {ok, term()} | {error, term()}.
experimental_feature_list(Session, Opts) ->
    native_or(Session, experimental_feature_list, [Opts], fun() ->
        beam_agent_collaboration:experimental_features(session_identity(Session), Opts)
    end).

-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) -> beam_agent_core:supported_commands(Session).

-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) -> beam_agent_core:supported_models(Session).

-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) -> beam_agent_core:supported_agents(Session).

-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) -> beam_agent_core:account_info(Session).

-spec list_commands(pid()) -> {ok, list()} | {error, term()}.
list_commands(Session) ->
    native_or(Session, list_commands, [], fun() -> supported_commands(Session) end).

-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Session) -> beam_agent_core:list_tools(Session).

-spec list_skills(pid()) -> {ok, [map()]} | {error, term()}.
list_skills(Session) -> beam_agent_core:list_skills(Session).

-spec list_plugins(pid()) -> {ok, [map()]} | {error, term()}.
list_plugins(Session) -> beam_agent_core:list_plugins(Session).

-spec list_mcp_servers(pid()) -> {ok, [map()]} | {error, term()}.
list_mcp_servers(Session) -> beam_agent_core:list_mcp_servers(Session).

-spec list_agents(pid()) -> {ok, [map()]} | {error, term()}.
list_agents(Session) -> beam_agent_core:list_agents(Session).

-spec skills_list(pid()) -> {ok, term()} | {error, term()}.
skills_list(Session) ->
    native_or(Session, skills_list, [], fun() -> list_skills(Session) end).

-spec skills_list(pid(), map()) -> {ok, term()} | {error, term()}.
skills_list(Session, Opts) ->
    native_or(Session, skills_list, [Opts], fun() -> list_skills(Session) end).

-spec skills_remote_list(pid()) -> {ok, term()} | {error, term()}.
skills_remote_list(Session) ->
    native_or(Session, skills_remote_list, [], fun() ->
        universal_skills_remote_list(Session, #{})
    end).

-spec skills_remote_list(pid(), map()) -> {ok, term()} | {error, term()}.
skills_remote_list(Session, Opts) ->
    native_or(Session, skills_remote_list, [Opts], fun() ->
        universal_skills_remote_list(Session, Opts)
    end).

-spec skills_remote_export(pid(), map()) -> {ok, term()} | {error, term()}.
skills_remote_export(Session, Opts) ->
    native_or(Session, skills_remote_export, [Opts], fun() ->
        beam_agent_skills_core:skills_remote_export(Session, Opts)
    end).

-spec skills_config_write(pid(), binary(), boolean()) -> {ok, term()} | {error, term()}.
skills_config_write(Session, Path, Enabled) ->
    native_or(Session, skills_config_write, [Path, Enabled], fun() ->
        beam_agent_skills_core:skills_config_write(Session, Path, Enabled),
        {ok, with_universal_source(Session, #{path => Path, enabled => Enabled})}
    end).

-spec apps_list(pid()) -> {ok, term()} | {error, term()}.
apps_list(Session) ->
    native_or(Session, apps_list, [], fun() ->
        beam_agent_app_core:apps_list(Session)
    end).

-spec apps_list(pid(), map()) -> {ok, term()} | {error, term()}.
apps_list(Session, Opts) ->
    native_or(Session, apps_list, [Opts], fun() ->
        beam_agent_app_core:apps_list(Session, Opts)
    end).

-spec app_info(pid()) -> {ok, term()} | {error, term()}.
app_info(Session) ->
    native_or(Session, app_info, [], fun() ->
        beam_agent_app_core:app_info(Session)
    end).

-spec app_init(pid()) -> {ok, term()} | {error, term()}.
app_init(Session) ->
    native_or(Session, app_init, [], fun() ->
        beam_agent_app_core:app_init(Session)
    end).

-spec app_log(pid(), map()) -> {ok, term()} | {error, term()}.
app_log(Session, Body) ->
    native_or(Session, app_log, [Body], fun() ->
        _ = beam_agent_app_core:app_log(Session, Body),
        {ok, with_universal_source(Session, #{status => logged})}
    end).

-spec app_modes(pid()) -> {ok, term()} | {error, term()}.
app_modes(Session) ->
    native_or(Session, app_modes, [], fun() ->
        beam_agent_app_core:app_modes(Session)
    end).

-spec model_list(pid()) -> {ok, term()} | {error, term()}.
model_list(Session) ->
    native_or(Session, model_list, [], fun() -> supported_models(Session) end).

-spec model_list(pid(), map()) -> {ok, term()} | {error, term()}.
model_list(Session, Opts) ->
    native_or(Session, model_list, [Opts], fun() -> supported_models(Session) end).

-spec get_status(pid()) -> {ok, term()} | {error, term()}.
get_status(Session) ->
    native_or(Session, get_status, [], fun() ->
        universal_get_status(Session)
    end).

-spec get_auth_status(pid()) -> {ok, term()} | {error, term()}.
get_auth_status(Session) ->
    native_or(Session, get_auth_status, [], fun() ->
        universal_get_auth_status(Session)
    end).

-spec get_last_session_id(pid()) -> {ok, term()} | {error, term()}.
get_last_session_id(Session) ->
    native_or(Session, get_last_session_id, [], fun() ->
        {ok, session_identity(Session)}
    end).

-spec get_tool(pid(), binary()) -> {ok, map()} | {error, term()}.
get_tool(Session, ToolId) -> beam_agent_core:get_tool(Session, ToolId).

-spec get_skill(pid(), binary()) -> {ok, map()} | {error, term()}.
get_skill(Session, SkillId) -> beam_agent_core:get_skill(Session, SkillId).

-spec get_plugin(pid(), binary()) -> {ok, map()} | {error, term()}.
get_plugin(Session, PluginId) -> beam_agent_core:get_plugin(Session, PluginId).

-spec get_agent(pid(), binary()) -> {ok, map()} | {error, term()}.
get_agent(Session, AgentId) -> beam_agent_core:get_agent(Session, AgentId).

-spec current_provider(pid()) -> {ok, binary()} | {error, not_set}.
current_provider(Session) -> beam_agent_core:current_provider(Session).

-spec set_provider(pid(), binary()) -> ok.
set_provider(Session, ProviderId) -> beam_agent_core:set_provider(Session, ProviderId).

-spec clear_provider(pid()) -> ok.
clear_provider(Session) -> beam_agent_core:clear_provider(Session).

-spec provider_list(pid()) -> {ok, [map()]} | {error, term()}.
provider_list(Session) ->
    native_or(Session, provider_list, [], fun() -> beam_agent_runtime:list_providers(Session) end).

-spec provider_auth_methods(pid()) -> {ok, term()} | {error, term()}.
provider_auth_methods(Session) ->
    native_or(Session, provider_auth_methods, [], fun() ->
        beam_agent_config:provider_auth_methods(Session)
    end).

-spec provider_oauth_authorize(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
provider_oauth_authorize(Session, ProviderId, Body) ->
    native_or(Session, provider_oauth_authorize, [ProviderId, Body], fun() ->
        beam_agent_config:provider_oauth_authorize(Session, ProviderId, Body)
    end).

-spec provider_oauth_callback(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
provider_oauth_callback(Session, ProviderId, Body) ->
    native_or(Session, provider_oauth_callback, [ProviderId, Body], fun() ->
        beam_agent_config:provider_oauth_callback(Session, ProviderId, Body)
    end).

-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) -> beam_agent_core:current_agent(Session).

-spec set_agent(pid(), binary()) -> ok.
set_agent(Session, AgentId) -> beam_agent_core:set_agent(Session, AgentId).

-spec clear_agent(pid()) -> ok.
clear_agent(Session) -> beam_agent_core:clear_agent(Session).

-spec list_server_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    native_or(Session, list_server_sessions, [], fun() ->
        case backend(Session) of
            {ok, Backend} -> beam_agent_session_store_core:list_sessions(#{adapter => Backend});
            {error, _} = Error -> Error
        end
    end).

-spec get_server_session(pid(), binary()) -> {ok, map()} | {error, term()}.
get_server_session(Session, SessionId) ->
    native_or(Session, get_server_session, [SessionId], fun() -> get_session(SessionId) end).

-spec delete_server_session(pid(), binary()) -> {ok, term()} | {error, term()}.
delete_server_session(Session, SessionId) ->
    native_or(Session, delete_server_session, [SessionId], fun() ->
        ok = delete_session(SessionId),
        {ok, #{session_id => SessionId, deleted => true}}
    end).

-spec list_server_agents(pid()) -> {ok, term()} | {error, term()}.
list_server_agents(Session) ->
    native_or(Session, list_server_agents, [], fun() -> list_agents(Session) end).

-spec config_read(pid()) -> {ok, map()} | {error, term()}.
config_read(Session) ->
    native_or(Session, config_read, [], fun() -> beam_agent_config:config_read(Session) end).

-spec config_read(pid(), map()) -> {ok, map()} | {error, term()}.
config_read(Session, Opts) ->
    native_or(Session, config_read, [Opts], fun() -> beam_agent_config:config_read(Session) end).

-spec config_update(pid(), map()) -> {ok, term()} | {error, term()}.
config_update(Session, Body) ->
    native_or(Session, config_update, [Body], fun() ->
        beam_agent_config:config_update(Session, Body)
    end).

-spec config_providers(pid()) -> {ok, term()} | {error, term()}.
config_providers(Session) ->
    native_or(Session, config_providers, [], fun() -> provider_list(Session) end).

-spec find_text(pid(), binary()) -> {ok, term()} | {error, term()}.
find_text(Session, Pattern) ->
    native_or(Session, find_text, [Pattern], fun() ->
        beam_agent_file_core:find_text(Pattern, session_file_opts(Session))
    end).

-spec find_files(pid(), map()) -> {ok, term()} | {error, term()}.
find_files(Session, Opts) ->
    native_or(Session, find_files, [Opts], fun() ->
        beam_agent_file_core:find_files(maps:merge(session_file_opts(Session), Opts))
    end).

-spec find_symbols(pid(), binary()) -> {ok, term()} | {error, term()}.
find_symbols(Session, Query) ->
    native_or(Session, find_symbols, [Query], fun() ->
        beam_agent_file_core:find_symbols(Query, session_file_opts(Session))
    end).

-spec file_list(pid(), binary()) -> {ok, term()} | {error, term()}.
file_list(Session, Path) ->
    native_or(Session, file_list, [Path], fun() ->
        beam_agent_file_core:file_list(Path)
    end).

-spec file_read(pid(), binary()) -> {ok, term()} | {error, term()}.
file_read(Session, Path) ->
    native_or(Session, file_read, [Path], fun() ->
        beam_agent_file_core:file_read(Path)
    end).

-spec file_status(pid()) -> {ok, term()} | {error, term()}.
file_status(Session) ->
    native_or(Session, file_status, [], fun() ->
        beam_agent_file_core:file_status(session_file_opts(Session))
    end).

-spec config_value_write(pid(), binary(), term()) -> {ok, term()} | {error, term()}.
config_value_write(Session, KeyPath, Value) ->
    config_value_write(Session, KeyPath, Value, #{}).

-spec config_value_write(pid(), binary(), term(), map()) -> {ok, term()} | {error, term()}.
config_value_write(Session, KeyPath, Value, Opts) ->
    native_or(Session, config_value_write, [KeyPath, Value, Opts], fun() ->
        beam_agent_config:config_value_write(Session, KeyPath, Value, Opts)
    end).

-spec config_batch_write(pid(), [map()]) -> {ok, term()} | {error, term()}.
config_batch_write(Session, Edits) ->
    config_batch_write(Session, Edits, #{}).

-spec config_batch_write(pid(), [map()], map()) -> {ok, term()} | {error, term()}.
config_batch_write(Session, Edits, Opts) ->
    native_or(Session, config_batch_write, [Edits, Opts], fun() ->
        beam_agent_config:config_batch_write(Session, Edits, Opts)
    end).

-spec config_requirements_read(pid()) -> {ok, term()} | {error, term()}.
config_requirements_read(Session) ->
    native_or(Session, config_requirements_read, [], fun() ->
        beam_agent_config:config_requirements_read(Session)
    end).

-spec external_agent_config_detect(pid()) -> {ok, term()} | {error, term()}.
external_agent_config_detect(Session) ->
    external_agent_config_detect(Session, #{}).

-spec external_agent_config_detect(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_config_detect(Session, Opts) ->
    native_or(Session, external_agent_config_detect, [Opts], fun() ->
        beam_agent_config:external_agent_config_detect(Session, Opts)
    end).

-spec external_agent_config_import(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_config_import(Session, Opts) ->
    native_or(Session, external_agent_config_import, [Opts], fun() ->
        beam_agent_config:external_agent_config_import(Session, Opts)
    end).

-spec mcp_status(pid()) -> {ok, term()} | {error, term()}.
mcp_status(Session) ->
    native_or(Session, mcp_status, [], fun() -> mcp_server_status(Session) end).

-spec add_mcp_server(pid(), map()) -> {ok, term()} | {error, term()}.
add_mcp_server(Session, Body) ->
    native_or(Session, add_mcp_server, [Body], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            Server = beam_agent_mcp_core:server(
                maps:get(<<"name">>, Body, maps:get(name, Body, <<"unnamed">>)),
                maps:get(<<"tools">>, Body, maps:get(tools, Body, []))),
            NewRegistry = beam_agent_mcp_core:register_server(Server, Registry),
            {{ok, with_universal_source(Session, #{status => added,
                server_name => maps:get(name, Server)})}, NewRegistry}
        end)
    end).

-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Session) ->
    native_or(Session, mcp_server_status, [], fun() ->
        case beam_agent_mcp_core:get_session_registry(Session) of
            {ok, Registry} -> beam_agent_mcp_core:server_status(Registry);
            {error, not_found} -> {ok, #{}}
        end
    end).

-spec set_mcp_servers(pid(), term()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    native_or(Session, set_mcp_servers, [Servers], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            NewRegistry = beam_agent_mcp_core:set_servers(Servers, Registry),
            {{ok, with_universal_source(Session, #{status => updated})}, NewRegistry}
        end)
    end).

-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    native_or(Session, reconnect_mcp_server, [ServerName], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            case beam_agent_mcp_core:reconnect_server(ServerName, Registry) of
                {ok, NewRegistry} ->
                    {{ok, with_universal_source(Session, #{status => reconnected,
                        server_name => ServerName})}, NewRegistry};
                {error, not_found} ->
                    {{error, {server_not_found, ServerName}}, Registry}
            end
        end)
    end).

-spec toggle_mcp_server(pid(), binary(), boolean()) -> {ok, term()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    native_or(Session, toggle_mcp_server, [ServerName, Enabled], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            case beam_agent_mcp_core:toggle_server(ServerName, Enabled, Registry) of
                {ok, NewRegistry} ->
                    {{ok, with_universal_source(Session, #{status => toggled,
                        server_name => ServerName, enabled => Enabled})}, NewRegistry};
                {error, not_found} ->
                    {{error, {server_not_found, ServerName}}, Registry}
            end
        end)
    end).

-spec mcp_server_oauth_login(pid(), map()) -> {ok, term()} | {error, term()}.
mcp_server_oauth_login(Session, Params) ->
    native_or(Session, mcp_server_oauth_login, [Params], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_supported,
            reason => <<"OAuth login requires native backend support">>,
            params => Params})}
    end).

-spec mcp_server_reload(pid()) -> {ok, term()} | {error, term()}.
mcp_server_reload(Session) ->
    native_or(Session, mcp_server_reload, [], fun() ->
        case beam_agent_mcp_core:get_session_registry(Session) of
            {ok, _Registry} ->
                {ok, with_universal_source(Session, #{status => reloaded})};
            {error, not_found} ->
                {ok, with_universal_source(Session, #{status => no_registry})}
        end
    end).

-spec mcp_server_status_list(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status_list(Session) ->
    native_or(Session, mcp_server_status_list, [], fun() -> mcp_server_status(Session) end).

-spec account_login(pid(), map()) -> {ok, term()} | {error, term()}.
account_login(Session, Params) ->
    native_or(Session, account_login, [Params], fun() ->
        beam_agent_account_core:account_login(Session, Params)
    end).

-spec account_login_cancel(pid(), map()) -> {ok, term()} | {error, term()}.
account_login_cancel(Session, Params) ->
    native_or(Session, account_login_cancel, [Params], fun() ->
        beam_agent_account_core:account_login_cancel(Session, Params)
    end).

-spec account_logout(pid()) -> {ok, term()} | {error, term()}.
account_logout(Session) ->
    native_or(Session, account_logout, [], fun() ->
        beam_agent_account_core:account_logout(Session)
    end).

-spec account_rate_limits(pid()) -> {ok, term()} | {error, term()}.
account_rate_limits(Session) ->
    native_or(Session, account_rate_limits, [], fun() -> account_info(Session) end).

-spec fuzzy_file_search(pid(), binary()) -> {ok, term()} | {error, term()}.
fuzzy_file_search(Session, Query) ->
    fuzzy_file_search(Session, Query, #{}).

-spec fuzzy_file_search(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
fuzzy_file_search(Session, Query, Opts) ->
    native_or(Session, fuzzy_file_search, [Query, Opts], fun() ->
        beam_agent_search_core:fuzzy_file_search(Query, Opts)
    end).

-spec fuzzy_file_search_session_start(pid(), binary(), [term()]) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_start(Session, SearchSessionId, Roots) ->
    native_or(Session, fuzzy_file_search_session_start,
              [SearchSessionId, Roots], fun() ->
        beam_agent_search_core:session_start(Session, SearchSessionId, Roots)
    end).

-spec fuzzy_file_search_session_update(pid(), binary(), binary()) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_update(Session, SearchSessionId, Query) ->
    native_or(Session, fuzzy_file_search_session_update,
              [SearchSessionId, Query], fun() ->
        beam_agent_search_core:session_update(Session, SearchSessionId, Query)
    end).

-spec fuzzy_file_search_session_stop(pid(), binary()) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_stop(Session, SearchSessionId) ->
    native_or(Session, fuzzy_file_search_session_stop,
              [SearchSessionId], fun() ->
        beam_agent_search_core:session_stop(Session, SearchSessionId),
        {ok, with_universal_source(Session, #{status => stopped,
            search_session_id => SearchSessionId})}
    end).

-spec windows_sandbox_setup_start(pid(), map()) -> {ok, term()} | {error, term()}.
windows_sandbox_setup_start(Session, Opts) ->
    native_or(Session, windows_sandbox_setup_start, [Opts], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"Windows sandbox not applicable on this platform">>,
            platform => list_to_binary(erlang:system_info(system_architecture))})}
    end).

-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, term()} | {error, term()}.
set_max_thinking_tokens(Session, MaxTokens) ->
    native_or(Session, set_max_thinking_tokens, [MaxTokens], fun() ->
        _ = beam_agent_config:config_value_write(
            Session, <<"max_thinking_tokens">>, MaxTokens, #{}),
        {ok, with_universal_source(Session, #{
            max_thinking_tokens => MaxTokens})}
    end).

-spec rewind_files(pid(), binary()) -> {ok, term()} | {error, term()}.
rewind_files(Session, CheckpointUuid) ->
    native_or(Session, rewind_files, [CheckpointUuid], fun() ->
        SessionId = session_identity(Session),
        case beam_agent_checkpoint_core:rewind(SessionId, CheckpointUuid) of
            ok ->
                {ok, with_universal_source(Session, #{
                    status => rewound, checkpoint_uuid => CheckpointUuid})};
            {error, _} = Error ->
                Error
        end
    end).

-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Session, TaskId) ->
    native_or(Session, stop_task, [TaskId], fun() ->
        _ = interrupt(Session),
        {ok, with_universal_source(Session, #{
            status => stopped, task_id => TaskId})}
    end).

-spec session_init(pid(), map()) -> {ok, term()} | {error, term()}.
session_init(Session, Opts) ->
    native_or(Session, session_init, [Opts], fun() ->
        beam_agent_runtime_core:register_session(Session, Opts),
        {ok, with_universal_source(Session, #{status => initialized})}
    end).

-spec session_messages(pid()) -> {ok, term()} | {error, term()}.
session_messages(Session) ->
    native_or(Session, session_messages, [], fun() ->
        get_session_messages(session_identity(Session))
    end).

-spec session_messages(pid(), map()) -> {ok, term()} | {error, term()}.
session_messages(Session, Opts) ->
    native_or(Session, session_messages, [Opts], fun() ->
        get_session_messages(session_identity(Session), Opts)
    end).

-spec prompt_async(pid(), binary()) -> {ok, term()} | {error, term()}.
prompt_async(Session, Prompt) ->
    prompt_async(Session, Prompt, #{}).

-spec prompt_async(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
prompt_async(Session, Prompt, Opts) ->
    case native_call(Session, prompt_async, [Prompt, Opts]) of
        {ok, Result} ->
            {ok, normalize_prompt_async_result(Session, Result)};
        {error, {unsupported_native_call, _}} ->
            universal_prompt_async(Session, Prompt, Opts);
        {error, _} = Error ->
            Error
    end.

-spec shell_command(pid(), binary()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command) ->
    shell_command(Session, Command, #{}).

-spec shell_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command, Opts) ->
    native_or(Session, shell_command, [Command, Opts], fun() ->
        universal_shell_command(Session, Command, Opts)
    end).

-spec tui_append_prompt(pid(), binary()) -> {ok, term()} | {error, term()}.
tui_append_prompt(Session, Text) ->
    native_or(Session, tui_append_prompt, [Text], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>,
            text => Text})}
    end).

-spec tui_open_help(pid()) -> {ok, term()} | {error, term()}.
tui_open_help(Session) ->
    native_or(Session, tui_open_help, [], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>})}
    end).

-spec session_destroy(pid()) -> {ok, term()} | {error, term()}.
session_destroy(Session) ->
    SessionId = session_identity(Session),
    native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-spec session_destroy(pid(), binary()) -> {ok, term()} | {error, term()}.
session_destroy(Session, SessionId) ->
    native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-spec command_run(pid(), binary() | [binary()]) -> {ok, term()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

-spec command_run(pid(), binary() | [binary()], map()) -> {ok, term()} | {error, term()}.
command_run(Session, Command, Opts) ->
    case native_call(Session, command_run, [Command, Opts]) of
        {ok, Result} when is_map(Result) ->
            {ok, with_universal_source(Session, Result)};
        {ok, Result} ->
            {ok, with_universal_source(Session, #{result => Result})};
        {error, {unsupported_native_call, _}} ->
            universal_command_run(Session, Command, Opts);
        {error, _} ->
            universal_command_run(Session, Command, Opts)
    end.

-spec command_write_stdin(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).

-spec command_write_stdin(pid(), binary(), binary(), map()) ->
    {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin, Opts) ->
    native_or(Session, command_write_stdin, [ProcessId, Stdin, Opts], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_supported,
            reason => <<"Stdin write requires an active native process handle">>,
            process_id => ProcessId})}
    end).

-spec submit_feedback(pid(), map()) -> {ok, term()} | {error, term()}.
submit_feedback(Session, Feedback) ->
    native_or(Session, submit_feedback, [Feedback], fun() ->
        universal_submit_feedback(Session, Feedback)
    end).

-spec turn_respond(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
turn_respond(Session, RequestId, Params) ->
    native_or(Session, turn_respond, [RequestId, Params], fun() ->
        universal_turn_respond(Session, RequestId, Params)
    end).

-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    native_or(Session, send_command, [Command, Params],
        fun() -> send_control(Session, Command, Params) end).

-spec server_health(pid()) -> {ok, term()} | {error, term()}.
server_health(Session) ->
    native_or(Session, server_health, [], fun() ->
        case session_info(Session) of
            {ok, Info} ->
                {ok, with_universal_source(Session, #{
                    status => healthy,
                    backend => maps:get(backend, Info, unknown),
                    session_id => maps:get(session_id, Info, undefined),
                    uptime_ms => erlang:system_time(millisecond)
                        - maps:get(started_at, Info, erlang:system_time(millisecond))})};
            {error, _} ->
                {ok, with_universal_source(Session, #{
                    status => unknown,
                    reason => <<"Session info unavailable">>})}
        end
    end).

-spec capabilities() -> [beam_agent_capabilities:capability_info()].
capabilities() -> beam_agent_capabilities:all().

-spec capabilities(pid() | backend() | binary() | atom()) ->
    {ok, [map()]} |
    {error, capability_error()}.
capabilities(Session) when is_pid(Session) ->
    beam_agent_capabilities:for_session(Session);
capabilities(BackendLike) ->
    beam_agent_capabilities:for_backend(BackendLike).

-spec supports(beam_agent_capabilities:capability(),
               backend() | binary() | atom()) ->
    {ok, true} | {error, supports_error()}.
supports(Capability, BackendLike) ->
    beam_agent_capabilities:supports(Capability, BackendLike).

-spec normalize_message(map()) -> message().
normalize_message(Message) -> beam_agent_core:normalize_message(Message).

-spec make_request_id() -> binary().
make_request_id() -> beam_agent_core:make_request_id().

-spec parse_stop_reason(term()) -> stop_reason().
parse_stop_reason(Value) -> beam_agent_core:parse_stop_reason(Value).

-spec parse_permission_mode(term()) -> permission_mode().
parse_permission_mode(Value) -> beam_agent_core:parse_permission_mode(Value).

-spec collect_messages(pid(), reference(), integer(), receive_fun()) ->
    {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun) ->
    beam_agent_core:collect_messages(Session, Ref, Deadline, ReceiveFun).

-spec collect_messages(pid(), reference(), integer(), receive_fun(), terminal_pred()) ->
    {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun, TerminalPred) ->
    beam_agent_core:collect_messages(Session, Ref, Deadline, ReceiveFun, TerminalPred).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec native_call(pid(), atom(), [term()]) -> {ok, term()} | {error, term()}.
native_call(Session, Function, Args) ->
    beam_agent_raw_core:call(Session, Function, Args).

-spec native_or(pid(), atom(), [term()], fun(() -> {ok, term()} | {error, term()})) ->
    {ok, term()} | {error, term()}.
native_or(Session, Function, Args, Fallback) ->
    case native_call(Session, Function, Args) of
        {error, {unsupported_native_call, _}} ->
            Fallback();
        Other ->
            Other
    end.

-spec session_file_opts(pid()) -> beam_agent_file_core:search_opts().
session_file_opts(Session) ->
    case session_info(Session) of
        {ok, Info} ->
            Cwd = maps:get(cwd, Info,
                    maps:get(working_directory, Info,
                    maps:get(project_path, Info, undefined))),
            case Cwd of
                CwdBin when is_binary(CwdBin), byte_size(CwdBin) > 0 ->
                    #{cwd => CwdBin};
                _ ->
                    #{}
            end;
        {error, _} ->
            #{}
    end.

-spec universal_mcp_registry_op(pid(),
    fun((beam_agent_mcp_core:mcp_registry()) ->
        {{ok, term()} | {error, term()}, beam_agent_mcp_core:mcp_registry()})) ->
    {ok, term()} | {error, term()}.
universal_mcp_registry_op(Session, Fun) ->
    case beam_agent_mcp_core:get_session_registry(Session) of
        {ok, Registry} ->
            {Result, NewRegistry} = Fun(Registry),
            _ = beam_agent_mcp_core:update_session_registry(Session,
                fun(_) -> NewRegistry end),
            Result;
        {error, not_found} ->
            %% No registry exists; create one, apply the op
            EmptyRegistry = beam_agent_mcp_core:new_registry(),
            {Result, NewRegistry} = Fun(EmptyRegistry),
            beam_agent_mcp_core:register_session_registry(Session, NewRegistry),
            Result
    end.

-spec universal_thread_unsubscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
universal_thread_unsubscribe(Session, ThreadId) ->
    SessionId = session_identity(Session),
    case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
        {ok, _Thread} ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} ->
                    ok = beam_agent_threads_core:clear_active_thread(SessionId);
                _ ->
                    ok
            end,
            {ok, with_universal_source(Session, #{
                thread_id => ThreadId,
                unsubscribed => true,
                active_thread_id => active_thread_id(SessionId)
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_thread_name_set(pid(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
universal_thread_name_set(Session, ThreadId, Name) ->
    SessionId = session_identity(Session),
    case beam_agent_threads_core:rename_thread(SessionId, ThreadId, Name) of
        {ok, Thread} ->
            {ok, with_universal_source(Session, #{
                thread_id => ThreadId,
                name => Name,
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_thread_metadata_update(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
universal_thread_metadata_update(Session, ThreadId, MetadataPatch) ->
    SessionId = session_identity(Session),
    case beam_agent_threads_core:update_thread_metadata(SessionId, ThreadId, MetadataPatch) of
        {ok, Thread} ->
            {ok, with_universal_source(Session, #{
                thread_id => ThreadId,
                metadata => maps:get(metadata, Thread, #{}),
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_thread_loaded_list(pid(), map()) -> {ok, map()}.
universal_thread_loaded_list(Session, Opts) ->
    SessionId = session_identity(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, with_universal_source(Session, #{
        threads => Threads,
        active_thread_id => active_thread_id(SessionId),
        count => length(Threads)
    })}.

-spec universal_thread_compact(pid(), map()) -> {ok, map()} | {error, term()}.
universal_thread_compact(Session, Opts) ->
    SessionId = session_identity(Session),
    case resolve_thread_id(SessionId, Opts) of
        {ok, ThreadId} ->
            Selector = thread_compact_selector(Opts),
            case beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector) of
                {ok, Thread} ->
                    {ok, with_universal_source(Session, #{
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

-spec universal_turn_interrupt(pid(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
universal_turn_interrupt(Session, ThreadId, TurnId) ->
    case beam_agent_core:interrupt(Session) of
        ok ->
            {ok, with_universal_source(Session, #{
                thread_id => ThreadId,
                turn_id => TurnId,
                status => interrupted
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_skills_remote_list(pid(), map()) -> {ok, map()} | {error, term()}.
universal_skills_remote_list(Session, _Opts) ->
    case list_skills(Session) of
        {ok, Skills} ->
            {ok, with_universal_source(Session, #{
                skills => Skills,
                count => length(Skills)
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_get_status(pid()) -> {ok, map()} | {error, term()}.
universal_get_status(Session) ->
    case session_info(Session) of
        {ok, Info} ->
            {ok, with_universal_source(Session, Info#{
                health => safe_session_health(Session)
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_get_auth_status(pid()) -> {ok, map()}.
universal_get_auth_status(Session) ->
    {ok, Status} = beam_agent_runtime_core:provider_status(Session),
    {ok, with_universal_source(Session, Status)}.

-spec universal_session_destroy(pid(), binary()) -> {ok, map()}.
universal_session_destroy(Session, SessionId) ->
    ok = delete_session(SessionId),
    ok = beam_agent_runtime_core:clear_session(SessionId),
    ok = beam_agent_control_core:clear_config(SessionId),
    ok = beam_agent_control_core:clear_feedback(SessionId),
    ok = beam_agent_control_core:clear_session_callbacks(SessionId),
    ok = beam_agent_mcp_core:unregister_session_registry(Session),
    case session_identity(Session) =:= SessionId of
        true ->
            ok = beam_agent_backend:unregister_session(Session);
        false ->
            ok
    end,
    {ok, with_universal_source(Session, #{
        session_id => SessionId,
        destroyed => true
    })}.

-spec with_universal_source(pid(), map()) -> map().
with_universal_source(Session, Result) ->
    Base = Result#{source => universal},
    case backend(Session) of
        {ok, Backend} ->
            Base#{backend => Backend};
        {error, _} ->
            Base
    end.

-spec active_thread_id(binary()) -> binary() | undefined.
active_thread_id(SessionId) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            ThreadId;
        {error, _} ->
            undefined
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
        undefined ->
            Threads1;
        ThreadId ->
            [Thread || Thread <- Threads1, maps:get(thread_id, Thread, undefined) =:= ThreadId]
    end,
    Threads3 = case StatusFilter of
        undefined ->
            Threads2;
        Status ->
            [Thread || Thread <- Threads2, maps:get(status, Thread, undefined) =:= Status]
    end,
    case Limit of
        N when is_integer(N), N >= 0 ->
            lists:sublist(Threads3, N);
        _ ->
            Threads3
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
                {ok, ThreadId} ->
                    {ok, ThreadId};
                {error, _} ->
                    {error, not_found}
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
                        opt_value(
                            [visible_message_count,
                             <<"visible_message_count">>,
                             <<"visibleMessageCount">>],
                            Opts,
                            undefined),
                        maybe_put_selector(message_id,
                            opt_value([message_id, <<"message_id">>, <<"messageId">>],
                                Opts,
                                undefined),
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
        {ok, Value} ->
            Value;
        error ->
            opt_value(Rest, Opts, Default)
    end.

-spec safe_session_health(pid()) -> atom().
safe_session_health(Session) ->
    try health(Session) of
        Value -> Value
    catch
        _:_ -> unknown
    end.

-spec session_identity(pid()) -> binary().
session_identity(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SessionId}} when is_binary(SessionId),
                                              byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

-spec with_session_backend(pid(), map()) -> map().
with_session_backend(Session, Params) when is_map(Params) ->
    case backend(Session) of
        {ok, Backend} ->
            maps:put(backend, Backend, Params);
        _ ->
            Params
    end.

-spec normalize_prompt_async_result(pid(), term()) -> map().
normalize_prompt_async_result(Session, Result) when is_map(Result) ->
    with_session_backend(Session, maps:merge(#{accepted => true}, Result));
normalize_prompt_async_result(Session, accepted) ->
    with_session_backend(Session, #{accepted => true});
normalize_prompt_async_result(Session, true) ->
    with_session_backend(Session, #{accepted => true});
normalize_prompt_async_result(Session, Result) ->
    with_session_backend(Session, #{
        accepted => true,
        result => Result
    }).

-spec universal_command_run(pid(), binary() | [binary()], map()) ->
    {ok, map()} | {error, term()}.
universal_command_run(Session, Command, Opts) ->
    case beam_agent_command_core:run(command_to_shell(Command), Opts) of
        {ok, Result} ->
            {ok, Result#{
                source => universal,
                backend => session_backend(Session)
            }};
        Error ->
            Error
    end.

-spec universal_prompt_async(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
universal_prompt_async(Session, Prompt, Opts) when is_binary(Prompt), is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, 120000),
    case beam_agent_router:send_query(Session, Prompt, Opts, Timeout) of
        {ok, QueryRef} ->
            {ok, with_universal_source(Session, #{
                accepted => true,
                query_ref => QueryRef
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_shell_command(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
universal_shell_command(Session, Command, Opts) when is_binary(Command), is_map(Opts) ->
    case command_run(Session, Command, Opts) of
        {ok, Result} when is_map(Result) ->
            {ok, with_universal_source(Session, Result)};
        {error, _} = Error ->
            Error
    end.

-spec universal_submit_feedback(pid(), map()) -> {ok, map()}.
universal_submit_feedback(Session, Feedback) when is_map(Feedback) ->
    SessionId = session_identity(Session),
    ok = beam_agent_control:submit_feedback(SessionId, Feedback),
    {ok, #{
        session_id => SessionId,
        stored => true,
        source => universal,
        backend => session_backend(Session),
        feedback => Feedback
    }}.

-spec universal_turn_respond(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
universal_turn_respond(Session, RequestId, Params) when is_binary(RequestId), is_map(Params) ->
    SessionId = session_identity(Session),
    Response0 = case maps:is_key(response, Params) of
        true -> Params;
        false -> #{response => Params}
    end,
    Response = maps:put(source, universal, Response0),
    case beam_agent_control:resolve_pending_request(SessionId, RequestId, Response) of
        ok ->
            {ok, #{
                request_id => RequestId,
                resolved => true,
                source => universal,
                backend => session_backend(Session),
                response => Response
            }};
        Error ->
            Error
    end.

-spec command_to_shell(binary() | [binary()]) -> binary() | string().
command_to_shell(Command) when is_binary(Command) ->
    Command;
command_to_shell(Command) when is_list(Command), Command =:= [] ->
    Command;
command_to_shell(Command) when is_list(Command) ->
    Joined = string:join([shell_escape_segment(Segment) || Segment <- Command], " "),
    unicode:characters_to_binary(Joined).

-spec shell_escape_segment(binary() | string()) -> string().
shell_escape_segment(Segment) ->
    Raw = unicode:characters_to_list(Segment),
    [$' | escape_single_quotes(Raw)] ++ [$'].

-spec escape_single_quotes(string()) -> string().
escape_single_quotes([]) ->
    [];
escape_single_quotes([$' | Rest]) ->
    [$', $\\, $', $' | escape_single_quotes(Rest)];
escape_single_quotes([Char | Rest]) ->
    [Char | escape_single_quotes(Rest)].

-spec session_backend(pid()) -> backend() | undefined.
session_backend(Session) ->
    case backend(Session) of
        {ok, Backend} -> Backend;
        _ -> undefined
    end.
