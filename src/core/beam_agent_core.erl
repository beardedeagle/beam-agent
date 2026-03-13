-module(beam_agent_core).
-moduledoc """
Shared canonical Erlang core for BEAM agent backends.

`beam_agent_core` has two responsibilities:

  - provide the normalized wire/message types used across all backends
  - expose the shared runtime-selected API used by `beam_agent`

The transport/protocol adapters remain backend-specific, but callers should
normally use `beam_agent` as the public entrypoint and reach this module only
indirectly.

Wire protocol handling remains cross-referenced against TypeScript Agent SDK
v0.2.66 for protocol fidelity:

  - result messages use `result` field (not `content`)
  - every message carries `uuid` and `session_id`
  - enrichment fields from upstream SDKs are preserved where possible
  - stop reasons are validated to atoms for pattern matching
""".

-export([
    %% Canonical public session API
    start_session/1,
    child_spec/1,
    stop/1,
    query/2,
    query/3,
    session_info/1,
    session_identity/1,
    health/1,
    backend/1,
    list_backends/0,
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    send_control/3,
    %% Shared session and thread capabilities
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
    %% Metadata and capability accessors
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    account_info/1,
    list_tools/1,
    list_skills/1,
    list_plugins/1,
    list_mcp_servers/1,
    list_agents/1,
    get_tool/2,
    get_skill/2,
    get_plugin/2,
    get_agent/2,
    current_provider/1,
    set_provider/2,
    clear_provider/1,
    current_agent/1,
    set_agent/2,
    clear_agent/1,
    capabilities/0,
    capabilities/1,
    supports/2,
    normalize_message/1,
    make_request_id/0,
    parse_stop_reason/1,
    parse_permission_mode/1,
    %% Generic message collection loop
    collect_messages/4,
    collect_messages/5,
    %% Shared routing helpers (used by all public domain modules)
    native_call/3,
    native_or/4,
    with_universal_source/2,
    session_backend/1,
    with_session_backend/2,
    safe_session_health/1,
    opt_value/3
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

%% Internal helpers where the declared spec is intentionally broader
%% than the implementation (e.g., message() vs exact key set).
-dialyzer({no_underspecs, [add_common_fields/2]}).

%%--------------------------------------------------------------------
%% Type Definitions
%%--------------------------------------------------------------------

%% Normalized message types across all four wire protocols.
%% Cross-referenced against TS SDK v0.2.66 SDKMessage union (20+ types).
-type message_type() :: text
                      | assistant
                      | tool_use
                      | tool_result
                      | system
                      | result
                      | error
                      | user
                      | control
                      | control_request
                      | control_response
                      | stream_event
                      | rate_limit_event
                      | tool_progress
                      | tool_use_summary
                      | thinking
                      | auth_status
                      | prompt_suggestion
                      | raw.

%% Stop reasons from the Claude API (TS SDK: stop_reason field).
%% Validated from binary wire format into atoms for pattern matching.
-type stop_reason() :: end_turn
                     | max_tokens
                     | stop_sequence
                     | refusal
                     | tool_use_stop
                     | unknown_stop.

%% Permission modes supported by the Claude Code CLI.
%% Note: dont_ask is TypeScript-only (not available in Python SDK).
-type permission_mode() :: default
                         | accept_edits
                         | bypass_permissions
                         | plan
                         | dont_ask.

-type backend() :: beam_agent_backend:backend().

%% System prompt configuration.
%% Either a plain binary (custom prompt replacing default) or a
%% structured preset config with optional append.
%%
%% Since SDK v0.1.0, the default prompt is minimal. Use the
%% claude_code preset to get the full Claude Code system prompt.
-type system_prompt_config() :: binary()
                              | #{type := preset,
                                  preset := binary(),
                                  append => binary()}.

%% Permission handler callback result.
%% Follows TS SDK PermissionResult pattern:
%%   - {allow, UpdatedInput} — approve with optional input modification
%%   - {deny, Reason} — deny with reason message
%%   - {allow, UpdatedInput, RuleUpdateOrPermissions} — approve with either
%%     rule modification metadata or updated permissions
%%   - {deny, Reason, Interrupt} — deny and request turn interruption
%%   - map() — richer structured result using keys like behavior,
%%     updated_input, updated_permissions, message, and interrupt
-type permission_result() :: {allow, map()}
                           | {deny, binary()}
                           | {deny, binary(), boolean()}
                           | {allow, map(), map() | [map()]}
                           | map().

-type backend_resolution_error() :: backend_not_present
                          | {invalid_session_info, term()}
                          | {session_backend_lookup_failed, term()}
                          | {unknown_backend, term()}.

-type supports_error() :: backend_resolution_error() | {unknown_capability, term()}.

%% Unified message record. Required field: `type`.
%% All other fields are optional and depend on message_type().
%%
%% Common fields (present on all messages when the CLI provides them):
%%   uuid           - Unique message identifier (for correlation, checkpoints)
%%   session_id     - Session this message belongs to
%%
%% Type-specific fields:
%%   text:             content
%%   assistant:        content_blocks, parent_tool_use_id,
%%                     message_id, model, usage, stop_reason_atom, error_info
%%   tool_use:         tool_name, tool_input
%%   tool_result:      tool_name, content
%%   system:           content, subtype, system_info (parsed init metadata)
%%   result:           content (from "result" wire field), duration_ms,
%%                     duration_api_ms, num_turns, session_id, stop_reason,
%%                     stop_reason_atom, usage, model_usage, total_cost_usd,
%%                     is_error, subtype, errors, structured_output,
%%                     permission_denials, fast_mode_state
%%   error:            content
%%   user:             content, parent_tool_use_id, is_replay
%%   control:          raw (legacy)
%%   control_request:  request_id, request
%%   control_response: request_id, response
%%   stream_event:     subtype, content, parent_tool_use_id
%%   thinking:         content
%%   tool_progress:    content, tool_name
%%   tool_use_summary: content
%%   auth_status:      raw
%%   prompt_suggestion: content
%%   rate_limit_event: rate_limit_status, resets_at, rate_limit_type,
%%                     utilization, overage_status, overage_resets_at,
%%                     overage_disabled_reason, is_using_overage,
%%                     surpassed_threshold, raw
%%   raw:              raw (unrecognized, preserved for forward compat)
-type message() :: #{
    type := message_type(),
    content => binary(),
    tool_name => binary(),
    tool_input => map(),
    raw => map(),
    timestamp => integer(),
    %% Common wire fields (on all messages from CLI)
    uuid => binary(),
    session_id => binary(),
    %% Assistant message fields
    content_blocks => [beam_agent_content_core:content_block()],
    parent_tool_use_id => binary() | null,
    tool_use_id => binary(),
    message_id => binary(),
    model => binary(),
    error_info => map(),
    %% System message fields
    system_info => map(),
    %% Result enrichment fields
    duration_ms => non_neg_integer(),
    duration_api_ms => non_neg_integer(),
    num_turns => non_neg_integer(),
    stop_reason => binary(),
    stop_reason_atom => stop_reason(),
    usage => map(),
    model_usage => map(),
    total_cost_usd => number(),
    is_error => boolean(),
    subtype => binary(),
    errors => [binary()],
    structured_output => term(),
    permission_denials => list(),
    fast_mode_state => map(),
    %% User message fields
    is_replay => boolean(),
    %% Control protocol fields
    request_id => binary(),
    request => map(),
    response => map(),
    %% Rate limit event fields (TS SDK SDKRateLimitInfo)
    rate_limit_status => binary(),
    resets_at => number(),
    rate_limit_type => binary(),
    utilization => number(),
    overage_status => binary(),
    overage_resets_at => number(),
    overage_disabled_reason => binary(),
    is_using_overage => boolean(),
    surpassed_threshold => number(),
    %% Realtime/replay fields
    event_type => binary(),
    %% Thread management (added by beam_agent_threads_core)
    thread_id => binary()
}.

%% Options for dispatching a query to an agent.
-type query_opts() :: #{
    model => binary(),
    model_id => binary(),
    system_prompt => system_prompt_config(),
    allowed_tools => [binary()],
    disallowed_tools => [binary()],
    max_tokens => pos_integer(),
    max_turns => pos_integer(),
    permission_mode => binary() | permission_mode(),
    timeout => timeout(),
    %% Structured output (JSON schema)
    output_format => map() | text | json_schema | binary(),
    %% Thinking configuration
    thinking => map(),
    effort => binary(),
    %% Cost control
    max_budget_usd => number(),
    %% Subagent selection
    agent => binary(),
    %% Prompt mode / presentation
    mode => binary(),
    summary => binary(),
    %% Structured attachments
    attachments => [map()],
    %% Provider/runtime selection
    provider_id => binary(),
    provider => map(),
    %% Runtime overrides used by some backends
    approval_policy => binary(),
    sandbox_mode => binary(),
    cwd => binary(),
    %% OpenCode / catalog-oriented overrides
    mode => binary(),
    system => binary() | map(),
    tools => map() | list()
}.

%% Options for establishing an agent session.
-type session_opts() :: #{
    backend => backend(),
    cli_path => file:filename_all(),
    work_dir => file:filename_all(),
    env => [{string(), string()}],
    buffer_max => pos_integer(),
    queue_max => pos_integer(),
    node => node(),
    model => binary(),
    fallback_model => binary(),
    system_prompt => system_prompt_config(),
    tools => [binary()] | map(),
    max_turns => pos_integer(),
    session_id => binary(),
    %% Session lifecycle
    resume => boolean(),
    fork_session => boolean(),
    continue => boolean(),
    persist_session => boolean(),
    %% Permission system
    permission_mode => binary() | permission_mode(),
    permission_prompt_tool_name => binary(),
    permission_handler => fun((binary(), map(), map()) -> permission_result()),
    permission_default => allow | deny,  %% Default: deny (fail-closed)
    %% Tools and agents
    allowed_tools => [binary()],
    disallowed_tools => [binary()],
    agents => map(),
    %% MCP servers
    mcp_servers => map(),
    %% SDK MCP servers (in-process tool handlers)
    sdk_mcp_servers => [beam_agent_tool_registry:sdk_mcp_server()],
    %% MCP handler timeout in milliseconds (default: 30000)
    mcp_handler_timeout => pos_integer(),
    %% SDK-level lifecycle hooks (in-process callbacks)
    sdk_hooks => [beam_agent_hooks_core:hook_def()],
    %% Structured output
    output_format => map() | text | json_schema | binary(),
    %% Thinking
    thinking => map(),
    effort => binary(),
    %% Cost
    max_budget_usd => number(),
    %% File checkpointing
    enable_file_checkpointing => boolean(),
    %% Settings
    settings => binary() | map(),
    add_dirs => [file:filename_all()],
    setting_sources => [binary()],
    %% Plugins
    plugins => [map()],
    %% Hooks
    hooks => map(),
    %% Beta features
    betas => [binary()],
    %% Streaming
    include_partial_messages => boolean(),
    %% Prompt suggestions
    prompt_suggestions => boolean(),
    %% Sandbox
    sandbox => map(),
    %% Debug
    debug => boolean(),
    debug_file => binary(),
    %% Extra CLI arguments (key => value or key => null for flags)
    extra_args => #{binary() => binary() | null},
    %% Client identification (sets CLAUDE_AGENT_SDK_CLIENT_APP env var)
    client_app => binary(),
    client_name => binary(),
    config_dir => file:filename_all(),
    streaming => boolean(),
    %% Codex-specific options
    transport => app_server | exec | realtime,
    approval_handler => fun((binary(), map(), map()) -> atom()),
    thread_id => binary(),
    approval_policy => binary(),
    sandbox_mode => binary(),
    base_instructions => binary(),
    developer_instructions => binary(),
    ephemeral => boolean(),
    personality => binary(),
    service_name => binary(),
    dynamic_tools => [map()],
    persist_extended_history => boolean(),
    %% Gemini CLI-specific options
    approval_mode => binary(),
    settings_file => binary(),
    %% OpenCode-specific options
    base_url => binary(),
    directory => binary(),
    auth => {basic, binary(), binary()} | none,
    provider_id => binary(),
    model_id => binary(),
    agent => binary(),
    mode => binary(),
    %% Copilot-specific options
    protocol_version => pos_integer(),
    tool_handlers => #{binary() => fun()},
    user_input_handler => fun((map(), map()) -> {ok, binary()} | {error, term()}),
    working_directory => file:filename_all(),
    available_tools => [binary()],
    excluded_tools => [binary()],
    skill_directories => [file:filename_all()],
    disabled_skills => [binary()],
    system_message => binary() | map(),
    provider => map(),
    custom_agents => [map()],
    infinite_sessions => map(),
    sdk_tools => [map()],
    disable_resume => boolean(),
    reasoning_effort => binary(),
    github_token => binary(),
    cli_args => [binary()],
    log_level => binary()
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Start a unified session. `Opts.backend` is required.".
-spec start_session(session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) when is_map(Opts) ->
    beam_agent_router:start_session(Opts).

-doc "Build a supervisor child spec for a unified session.".
-spec child_spec(session_opts()) -> supervisor:child_spec().
child_spec(Opts) when is_map(Opts) ->
    beam_agent_router:child_spec(Opts).

-doc "Stop a unified session.".
-spec stop(pid()) -> ok.
stop(Session) when is_pid(Session) ->
    beam_agent_router:stop(Session).

-doc "Send a blocking query with default params.".
-spec query(pid(), binary()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

-doc "Send a blocking query through the canonical router.".
-spec query(pid(), binary(), query_opts()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt, Params)
  when is_pid(Session), is_binary(Prompt), is_map(Params) ->
    beam_agent_router:query(Session, Prompt, Params).

-doc "Query session info for a live unified session.".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) when is_pid(Session) ->
    beam_agent_router:session_info(Session).

-doc """
Derive a stable string identifier for a session.

Extracts the `session_id` from `session_info/1` when available, otherwise
falls back to the pid stringified via `erlang:pid_to_list/1`. This is the
canonical implementation — all modules should delegate here rather than
duplicating the logic.
""".
-spec session_identity(pid()) -> binary().
session_identity(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SessionId}} when is_binary(SessionId),
                                              byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

-doc "Return the current health state for a live unified session.".
-spec health(pid()) -> atom().
health(Session) when is_pid(Session) ->
    beam_agent_router:health(Session).

-doc "Resolve the backend for a live unified session.".
-spec backend(pid()) -> {ok, backend()} | {error, term()}.
backend(Session) when is_pid(Session) ->
    beam_agent_router:backend(Session).

-doc "List the backends supported by the canonical SDK.".
-spec list_backends() -> [backend()].
list_backends() ->
    beam_agent_backend:available_backends().

-doc "Change the model at runtime.".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) when is_pid(Session), is_binary(Model) ->
    beam_agent_router:set_model(Session, Model).

-doc "Change the permission mode at runtime.".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) when is_pid(Session), is_binary(Mode) ->
    beam_agent_router:set_permission_mode(Session, Mode).

-doc "Interrupt active work for a live session.".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) when is_pid(Session) ->
    beam_agent_router:interrupt(Session).

-doc "Abort active work for a live session.".
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) when is_pid(Session) ->
    beam_agent_router:abort(Session).

-doc "Send a control message through the canonical router.".
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params)
  when is_pid(Session), is_binary(Method), is_map(Params) ->
    beam_agent_router:send_control(Session, Method, Params).

-doc "List tracked sessions from the shared session store.".
-spec list_sessions() -> {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions() ->
    beam_agent_router:list_sessions().

-doc "List tracked sessions with filters.".
-spec list_sessions(beam_agent_session_store_core:list_opts()) ->
    {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions(Opts) when is_map(Opts) ->
    beam_agent_router:list_sessions(Opts).

-doc "Get visible messages for a tracked session id.".
-spec get_session_messages(binary()) ->
    {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    beam_agent_router:get_session_messages(SessionId).

-doc "Get visible messages for a tracked session id with options.".
-spec get_session_messages(binary(), beam_agent_session_store_core:message_opts()) ->
    {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) when is_map(Opts) ->
    beam_agent_router:get_session_messages(SessionId, Opts).

-doc "Get tracked session metadata by session id.".
-spec get_session(binary()) ->
    {ok, beam_agent_session_store_core:session_meta()} | {error, not_found}.
get_session(SessionId) ->
    beam_agent_router:get_session(SessionId).

-doc "Delete a tracked session by session id.".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    beam_agent_router:delete_session(SessionId).

-doc "Fork a live session.".
-spec fork_session(pid(), map()) -> {ok, map()} | {error, term()}.
fork_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    beam_agent_router:fork_session(Session, Opts).

-doc "Revert a live session.".
-spec revert_session(pid(), map()) -> {ok, map()} | {error, term()}.
revert_session(Session, Selector) when is_pid(Session), is_map(Selector) ->
    beam_agent_router:revert_session(Session, Selector).

-doc "Clear a live session's revert state.".
-spec unrevert_session(pid()) -> {ok, map()} | {error, term()}.
unrevert_session(Session) when is_pid(Session) ->
    beam_agent_router:unrevert_session(Session).

-doc "Share a live session using default opts.".
-spec share_session(pid()) -> {ok, map()} | {error, term()}.
share_session(Session) when is_pid(Session) ->
    beam_agent_router:share_session(Session).

-doc "Share a live session.".
-spec share_session(pid(), map()) -> {ok, map()} | {error, term()}.
share_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    beam_agent_router:share_session(Session, Opts).

-doc "Revoke sharing for a live session.".
-spec unshare_session(pid()) -> ok | {error, term()}.
unshare_session(Session) when is_pid(Session) ->
    beam_agent_router:unshare_session(Session).

-doc "Summarize a live session using default opts.".
-spec summarize_session(pid()) -> {ok, map()} | {error, term()}.
summarize_session(Session) when is_pid(Session) ->
    beam_agent_router:summarize_session(Session).

-doc "Summarize a live session.".
-spec summarize_session(pid(), map()) -> {ok, map()} | {error, term()}.
summarize_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    beam_agent_router:summarize_session(Session, Opts).

-doc "Start a thread for a live session.".
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) when is_pid(Session), is_map(Opts) ->
    beam_agent_router:thread_start(Session, Opts).

-doc "Resume a thread for a live session.".
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    beam_agent_router:thread_resume(Session, ThreadId).

-doc "List threads for a live session.".
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) when is_pid(Session) ->
    beam_agent_router:thread_list(Session).

-doc "Fork a thread with default opts.".
-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    beam_agent_router:thread_fork(Session, ThreadId).

-doc "Fork a thread.".
-spec thread_fork(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId, Opts)
  when is_pid(Session), is_binary(ThreadId), is_map(Opts) ->
    beam_agent_router:thread_fork(Session, ThreadId, Opts).

-doc "Read a thread with default opts.".
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    beam_agent_router:thread_read(Session, ThreadId).

-doc "Read a thread.".
-spec thread_read(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId, Opts)
  when is_pid(Session), is_binary(ThreadId), is_map(Opts) ->
    beam_agent_router:thread_read(Session, ThreadId, Opts).

-doc "Archive a thread.".
-spec thread_archive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_archive(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    beam_agent_router:thread_archive(Session, ThreadId).

-doc "Unarchive a thread.".
-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    beam_agent_router:thread_unarchive(Session, ThreadId).

-doc "Rollback a thread.".
-spec thread_rollback(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_rollback(Session, ThreadId, Selector)
  when is_pid(Session), is_binary(ThreadId), is_map(Selector) ->
    beam_agent_router:thread_rollback(Session, ThreadId, Selector).

-doc "List supported slash commands from session init data.".
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) when is_pid(Session) ->
    beam_agent_router:supported_commands(Session).

-doc "List supported models from session init data.".
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) when is_pid(Session) ->
    beam_agent_router:supported_models(Session).

-doc "List supported agents from session init data.".
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) when is_pid(Session) ->
    beam_agent_router:supported_agents(Session).

-doc "Read account info from session init data.".
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) when is_pid(Session) ->
    beam_agent_router:account_info(Session).

-doc "List tools from the shared metadata catalog.".
-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Session) when is_pid(Session) ->
    beam_agent_catalog_core:list_tools(Session).

-doc "List skills from the shared metadata catalog.".
-spec list_skills(pid()) -> {ok, [map()]} | {error, term()}.
list_skills(Session) when is_pid(Session) ->
    beam_agent_catalog_core:list_skills(Session).

-doc "List plugins from the shared metadata catalog.".
-spec list_plugins(pid()) -> {ok, [map()]} | {error, term()}.
list_plugins(Session) when is_pid(Session) ->
    beam_agent_catalog_core:list_plugins(Session).

-doc "List MCP servers from the shared metadata catalog.".
-spec list_mcp_servers(pid()) -> {ok, [map()]} | {error, term()}.
list_mcp_servers(Session) when is_pid(Session) ->
    beam_agent_catalog_core:list_mcp_servers(Session).

-doc "List agents from the shared metadata catalog.".
-spec list_agents(pid()) -> {ok, [map()]} | {error, term()}.
list_agents(Session) when is_pid(Session) ->
    beam_agent_catalog_core:list_agents(Session).

-doc "Look up a tool from the shared metadata catalog.".
-spec get_tool(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_tool(Session, ToolId) when is_pid(Session), is_binary(ToolId) ->
    beam_agent_catalog_core:get_tool(Session, ToolId).

-doc "Look up a skill from the shared metadata catalog.".
-spec get_skill(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_skill(Session, SkillId) when is_pid(Session), is_binary(SkillId) ->
    beam_agent_catalog_core:get_skill(Session, SkillId).

-doc "Look up a plugin from the shared metadata catalog.".
-spec get_plugin(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_plugin(Session, PluginId) when is_pid(Session), is_binary(PluginId) ->
    beam_agent_catalog_core:get_plugin(Session, PluginId).

-doc "Look up an agent from the shared metadata catalog.".
-spec get_agent(pid(), binary()) -> {ok, map()} | {error, not_found | term()}.
get_agent(Session, AgentId) when is_pid(Session), is_binary(AgentId) ->
    beam_agent_catalog_core:get_agent(Session, AgentId).

-doc "Return the current default provider selection for a session.".
-spec current_provider(pid()) -> {ok, binary()} | {error, not_set}.
current_provider(Session) when is_pid(Session) ->
    beam_agent_runtime_core:current_provider(Session).

-doc "Set the default provider for future queries on a session.".
-spec set_provider(pid(), binary()) -> ok.
set_provider(Session, ProviderId) when is_pid(Session), is_binary(ProviderId) ->
    beam_agent_runtime_core:set_provider(Session, ProviderId).

-doc "Clear any default provider selection for a session.".
-spec clear_provider(pid()) -> ok.
clear_provider(Session) when is_pid(Session) ->
    beam_agent_runtime_core:clear_provider(Session).

-doc "Return the current default agent selection for a session.".
-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) when is_pid(Session) ->
    beam_agent_catalog_core:current_agent(Session).

-doc "Set the default agent for future queries on a session.".
-spec set_agent(pid(), binary()) -> ok.
set_agent(Session, AgentId) when is_pid(Session), is_binary(AgentId) ->
    beam_agent_catalog_core:set_default_agent(Session, AgentId).

-doc "Clear any default agent selection for a session.".
-spec clear_agent(pid()) -> ok.
clear_agent(Session) when is_pid(Session) ->
    beam_agent_catalog_core:clear_default_agent(Session).

-doc "Return the canonical capability registry.".
-spec capabilities() -> [beam_agent_capabilities:capability_info()].
capabilities() ->
    beam_agent_capabilities:all().

-doc "Return the capability view for a backend or live session.".
-spec capabilities(pid() | backend() | binary() | atom()) ->
    {ok, [map()]} | {error, backend_resolution_error()}.
capabilities(Session) when is_pid(Session) ->
    beam_agent_capabilities:for_session(Session);
capabilities(BackendLike) ->
    beam_agent_capabilities:for_backend(BackendLike).

-doc "Return whether a capability is available for a backend or live session.".
-spec supports(beam_agent_capabilities:capability(),
               pid() | backend() | binary() | atom()) ->
    {ok, true} | {error, supports_error()}.
supports(Capability, Session) when is_pid(Session) ->
    case backend(Session) of
        {ok, Backend} ->
            beam_agent_capabilities:supports(Capability, Backend);
        {error, _} = Error ->
            Error
    end;
supports(Capability, BackendLike) ->
    beam_agent_capabilities:supports(Capability, BackendLike).

-doc """
Normalize a raw decoded JSON map into an `beam_agent_core:message()`.
Adapters call this after decoding their wire-format-specific
JSON to produce the common message type.

Extracts common fields (uuid, session_id) from every message,
then delegates to type-specific field extraction.
""".
%% Spec is intentionally broader than success typing — message() is the
%% API contract for all five adapters, not just the branches here.
-dialyzer({nowarn_function, normalize_message/1}).
-spec normalize_message(map()) -> message().
normalize_message(#{<<"type">> := TypeBin} = Raw) ->
    Type = parse_type(TypeBin),
    Base0 = #{type => Type, timestamp => erlang:system_time(millisecond)},
    Base = add_common_fields(Raw, Base0),
    add_fields(Type, Raw, Base);
normalize_message(Raw) when is_map(Raw) ->
    #{type => raw, raw => Raw, timestamp => erlang:system_time(millisecond)}.

-doc """
Generate a unique request ID for control protocol correlation.
Format: `req_COUNTER_HEX` (e.g., `req_0_a1b2c3d4`) matching the
actual Claude Code CLI protocol.
""".
-spec make_request_id() -> binary().
make_request_id() ->
    Seq = erlang:unique_integer([positive, monotonic]),
    Hex = binary:encode_hex(rand:bytes(4), lowercase),
    iolist_to_binary(io_lib:format("req_~b_~s", [Seq, Hex])).

-doc """
Parse a binary stop reason into a typed atom.
Unknown values map to `unknown_stop` for forward compatibility.
""".
-spec parse_stop_reason(binary() | term()) -> stop_reason().
parse_stop_reason(<<"end_turn">>)      -> end_turn;
parse_stop_reason(<<"max_tokens">>)    -> max_tokens;
parse_stop_reason(<<"stop_sequence">>) -> stop_sequence;
parse_stop_reason(<<"refusal">>)       -> refusal;
parse_stop_reason(<<"tool_use">>)      -> tool_use_stop;
parse_stop_reason(_)                   -> unknown_stop.

-doc """
Parse a binary permission mode into a typed atom.
Note: `dont_ask` is TypeScript-only (not available in Python SDK).
""".
-spec parse_permission_mode(binary() | term()) -> permission_mode().
parse_permission_mode(<<"default">>)           -> default;
parse_permission_mode(<<"acceptEdits">>)       -> accept_edits;
parse_permission_mode(<<"bypassPermissions">>) -> bypass_permissions;
parse_permission_mode(<<"plan">>)              -> plan;
parse_permission_mode(<<"dontAsk">>)           -> dont_ask;
parse_permission_mode(_)                       -> default.

%%--------------------------------------------------------------------
%% Shared Routing Helpers
%%--------------------------------------------------------------------
%% These helpers are used by all public domain modules for native-first
%% routing with universal fallbacks.

-doc "Invoke a native backend function via the raw core transport.".
-spec native_call(pid(), atom(), [term()]) -> {ok, term()} | {error, term()}.
native_call(Session, Function, Args) ->
    beam_agent_raw_core:call(Session, Function, Args).

-doc """
Try a native backend call; on `{error, {unsupported_native_call, _}}`
fall back to the universal implementation supplied by `Fallback`.
""".
-spec native_or(pid(), atom(), [term()], fun(() -> {ok, term()} | {error, term()})) ->
    {ok, term()} | {error, term()}.
native_or(Session, Function, Args, Fallback) ->
    case native_call(Session, Function, Args) of
        {error, {unsupported_native_call, _}} ->
            Fallback();
        Other ->
            Other
    end.

-doc "Annotate a result map with `source => universal` and the session backend.".
-spec with_universal_source(pid(), map()) -> map().
with_universal_source(Session, Result) ->
    Base = Result#{source => universal},
    case backend(Session) of
        {ok, Backend} ->
            Base#{backend => Backend};
        {error, _} ->
            Base
    end.

-doc "Extract the backend atom from a session, or `undefined` if unavailable.".
-spec session_backend(pid()) -> backend() | undefined.
session_backend(Session) ->
    case backend(Session) of
        {ok, Backend} -> Backend;
        _ -> undefined
    end.

-doc "Annotate a params map with the session's backend atom.".
-spec with_session_backend(pid(), map()) -> map().
with_session_backend(Session, Params) when is_map(Params) ->
    case backend(Session) of
        {ok, Backend} ->
            maps:put(backend, Backend, Params);
        _ ->
            Params
    end.

-doc "Wrap `health/1` in a try/catch, returning `unknown` on any failure.".
-spec safe_session_health(pid()) -> atom().
safe_session_health(Session) ->
    try health(Session) of
        Value -> Value
    catch
        _:_ -> unknown
    end.

-doc "Multi-key option lookup with default. Tries each key in order.".
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

%%--------------------------------------------------------------------
%% Internal: Common field extraction
%%--------------------------------------------------------------------

%% Extract common fields (uuid, session_id) present on all messages
%% from the CLI. These are essential for message correlation,
%% session continuity, and file checkpointing.
-spec add_common_fields(map(), message()) -> message().
add_common_fields(Raw, Base) ->
    M0 = maybe_add(<<"uuid">>, uuid, Raw, Base),
    maybe_add(<<"session_id">>, session_id, Raw, M0).

%%--------------------------------------------------------------------
%% Internal: Type parsing
%%--------------------------------------------------------------------

-spec parse_type(binary()) -> message_type().
parse_type(<<"text">>)             -> text;
parse_type(<<"assistant">>)        -> assistant;
parse_type(<<"tool_use">>)         -> tool_use;
parse_type(<<"tool_result">>)      -> tool_result;
parse_type(<<"system">>)           -> system;
parse_type(<<"result">>)           -> result;
parse_type(<<"error">>)            -> error;
parse_type(<<"user">>)             -> user;
parse_type(<<"control">>)          -> control;
parse_type(<<"control_request">>)  -> control_request;
parse_type(<<"control_response">>) -> control_response;
parse_type(<<"stream_event">>)     -> stream_event;
parse_type(<<"rate_limit_event">>) -> rate_limit_event;
parse_type(<<"tool_progress">>)    -> tool_progress;
parse_type(<<"tool_use_summary">>) -> tool_use_summary;
parse_type(<<"thinking">>)         -> thinking;
parse_type(<<"auth_status">>)      -> auth_status;
parse_type(<<"prompt_suggestion">>) -> prompt_suggestion;
parse_type(_Other)                 -> raw.

%%--------------------------------------------------------------------
%% Internal: Type-specific field extraction
%%--------------------------------------------------------------------

-spec add_fields(message_type(), map(), message()) -> message().
add_fields(text, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(assistant, Raw, Base) ->
    %% TS SDK: SDKAssistantMessage wraps content in a `message` object
    %% (BetaMessage). Handle both formats: top-level content array
    %% and nested message.content for protocol compatibility.
    %%
    %% SAFETY: JSON null decodes to atom `null` in OTP 27. Guard against
    %% non-map values to prevent badmap crashes on maps:get/3.
    MessageObj = case maps:get(<<"message">>, Raw, undefined) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    ContentRaw = case maps:get(<<"content">>, Raw, undefined) of
        CL when is_list(CL) -> CL;
        _ ->
            case maps:get(<<"content">>, MessageObj, undefined) of
                ML when is_list(ML) -> ML;
                _ -> []
            end
    end,
    Blocks = beam_agent_content_core:parse_blocks(ContentRaw),
    M0 = Base#{content_blocks => Blocks, raw => Raw},
    M1 = maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M0),
    M2 = maybe_add(<<"error">>, error_info, Raw, M1),
    %% Extract fields from embedded BetaMessage (usage, model, stop_reason, id)
    M3 = maybe_add(<<"usage">>, usage, MessageObj, M2),
    M4 = maybe_add(<<"model">>, model, MessageObj, M3),
    M5 = maybe_add(<<"id">>, message_id, MessageObj, M4),
    case maps:get(<<"stop_reason">>, MessageObj, undefined) of
        undefined -> M5;
        SR ->
            M5#{stop_reason => SR,
                stop_reason_atom => parse_stop_reason(SR)}
    end;

add_fields(tool_use, Raw, Base) ->
    Base#{
        tool_name => maps:get(<<"tool_name">>, Raw,
                        maps:get(<<"name">>, Raw, <<>>)),
        tool_input => maps:get(<<"tool_input">>, Raw,
                         maps:get(<<"input">>, Raw, #{})),
        raw => Raw
    };

add_fields(tool_result, Raw, Base) ->
    Base#{
        tool_name => maps:get(<<"tool_name">>, Raw, <<>>),
        content => maps:get(<<"content">>, Raw, <<>>),
        raw => Raw
    };

add_fields(system, Raw, Base) ->
    %% System messages have subtypes (init, status, compact_boundary, etc.)
    %% The init subtype carries rich metadata about the session capabilities.
    M0 = Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw},
    M1 = maybe_add(<<"subtype">>, subtype, Raw, M0),
    %% Parse system init metadata into structured system_info map
    case maps:get(<<"subtype">>, Raw, undefined) of
        <<"init">> ->
            M1#{system_info => parse_system_init(Raw)};
        Subtype ->
            enrich_system_subtype(Subtype, Raw, M1)
    end;

add_fields(result, Raw, Base) ->
    %% CRITICAL FIX: TS SDK SDKResultSuccess uses "result" field (not "content")
    %% for the answer text. SDKResultError uses "errors" (string[]).
    %% We check "result" first, fall back to "content" for backward compat.
    Content = maps:get(<<"result">>, Raw,
                  maps:get(<<"content">>, Raw, <<>>)),
    M0 = Base#{content => Content, raw => Raw},
    enrich_result(M0, Raw);

add_fields(error, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(user, Raw, Base) ->
    M0 = Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw},
    M1 = maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M0),
    maybe_add_bool(<<"isReplay">>, is_replay, Raw, M1);

add_fields(thinking, Raw, Base) ->
    Base#{
        content => maps:get(<<"thinking">>, Raw,
                      maps:get(<<"content">>, Raw, <<>>)),
        raw => Raw
    };

add_fields(control_request, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"request_id">>, request_id, Raw, M0),
    maybe_add(<<"request">>, request, Raw, M1);

add_fields(control_response, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"request_id">>, request_id, Raw, M0),
    maybe_add(<<"response">>, response, Raw, M1);

add_fields(stream_event, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"subtype">>, subtype, Raw, M0),
    M2 = maybe_add(<<"content">>, content, Raw, M1),
    maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M2);

add_fields(tool_progress, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"content">>, content, Raw, M0),
    maybe_add(<<"tool_name">>, tool_name, Raw, M1);

add_fields(tool_use_summary, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(prompt_suggestion, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(rate_limit_event, Raw, Base) ->
    %% TS SDK SDKRateLimitInfo: status, resetsAt, rateLimitType,
    %% utilization, overageStatus, overageResetsAt, etc.
    M0 = Base#{raw => Raw},
    Fields = [
        {<<"status">>, rate_limit_status},
        {<<"resetsAt">>, resets_at},
        {<<"rateLimitType">>, rate_limit_type},
        {<<"utilization">>, utilization},
        {<<"overageStatus">>, overage_status},
        {<<"overageResetsAt">>, overage_resets_at},
        {<<"overageDisabledReason">>, overage_disabled_reason},
        {<<"isUsingOverage">>, is_using_overage},
        {<<"surpassedThreshold">>, surpassed_threshold}
    ],
    lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, M0, Fields);

add_fields(auth_status, Raw, Base) ->
    M0 = Base#{raw => Raw},
    maybe_add(<<"content">>, content, Raw, M0);

add_fields(_Type, Raw, Base) ->
    Base#{raw => Raw}.

-spec enrich_system_subtype(binary() | undefined, map(), message()) -> message().
enrich_system_subtype(<<"task_started">>, Raw, Base) ->
    add_optional_fields(
      [{<<"task_id">>, task_id},
       {<<"tool_use_id">>, tool_use_id},
       {<<"description">>, description},
       {<<"task_type">>, task_type}],
      Raw, Base);
enrich_system_subtype(<<"task_progress">>, Raw, Base) ->
    add_optional_fields(
      [{<<"task_id">>, task_id},
       {<<"tool_use_id">>, tool_use_id},
       {<<"description">>, description},
       {<<"usage">>, usage},
       {<<"last_tool_name">>, last_tool_name}],
      Raw, Base);
enrich_system_subtype(<<"task_notification">>, Raw, Base) ->
    add_optional_fields(
      [{<<"task_id">>, task_id},
       {<<"tool_use_id">>, tool_use_id},
       {<<"status">>, task_status},
       {<<"output_file">>, output_file},
       {<<"summary">>, summary},
       {<<"usage">>, usage}],
      Raw, Base);
enrich_system_subtype(_, _Raw, Base) ->
    Base.

-spec add_optional_fields([{binary(), atom()}], map(), message()) -> message().
add_optional_fields(Fields, Raw, Base) ->
    lists:foldl(fun({BinKey, AtomKey}, Acc) ->
                        maybe_add(BinKey, AtomKey, Raw, Acc)
                end,
                Base,
                Fields).

%%--------------------------------------------------------------------
%% Internal: Result enrichment
%%--------------------------------------------------------------------

%% Enrich a result message with all protocol fields from the
%% TS SDK v0.2.66 SDKResultSuccess/SDKResultError types.
%% Only includes fields actually present in the raw message.
-spec enrich_result(message(), map()) -> message().
enrich_result(M0, Raw) ->
    Fields = [
        {<<"duration_ms">>, duration_ms},
        {<<"duration_api_ms">>, duration_api_ms},
        {<<"num_turns">>, num_turns},
        {<<"session_id">>, session_id},
        {<<"stop_reason">>, stop_reason},
        {<<"usage">>, usage},
        {<<"total_cost_usd">>, total_cost_usd},
        {<<"is_error">>, is_error},
        {<<"subtype">>, subtype},
        {<<"modelUsage">>, model_usage},
        {<<"permission_denials">>, permission_denials},
        {<<"errors">>, errors},
        {<<"structured_output">>, structured_output},
        {<<"fast_mode_state">>, fast_mode_state}
    ],
    M1 = lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, M0, Fields),
    %% Add parsed stop_reason atom if binary stop_reason is present
    case maps:find(stop_reason, M1) of
        {ok, SR} when is_binary(SR) ->
            M1#{stop_reason_atom => parse_stop_reason(SR)};
        _ ->
            M1
    end.

%%--------------------------------------------------------------------
%% Internal: System init parsing
%%--------------------------------------------------------------------

%% Parse a system init message into a structured map of session
%% capabilities. The TS SDK SDKSystemMessage (subtype: init) includes
%% tools, model, MCP servers, slash commands, skills, plugins, etc.
-spec parse_system_init(map()) -> map().
parse_system_init(Raw) ->
    Fields = [
        {<<"tools">>, tools},
        {<<"model">>, model},
        {<<"mcp_servers">>, mcp_servers},
        {<<"slash_commands">>, slash_commands},
        {<<"skills">>, skills},
        {<<"plugins">>, plugins},
        {<<"agents">>, agents},
        {<<"permissionMode">>, permission_mode},
        {<<"claude_code_version">>, claude_code_version},
        {<<"cwd">>, cwd},
        {<<"apiKeySource">>, api_key_source},
        {<<"betas">>, betas},
        {<<"output_style">>, output_style},
        {<<"fast_mode_state">>, fast_mode_state}
    ],
    lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, #{}, Fields).

%%--------------------------------------------------------------------
%% Internal: Field helpers
%%--------------------------------------------------------------------

%% Conditionally add a field to the message map if present in raw.
-spec maybe_add(binary(), atom(), map(), message()) -> message().
maybe_add(BinKey, AtomKey, Raw, Msg) ->
    case maps:find(BinKey, Raw) of
        {ok, V} -> Msg#{AtomKey => V};
        error   -> Msg
    end.

%% Conditionally add a boolean field, treating JSON null as absent.
-spec maybe_add_bool(binary(), atom(), map(), message()) -> message().
maybe_add_bool(BinKey, AtomKey, Raw, Msg) ->
    case maps:find(BinKey, Raw) of
        {ok, true}  -> Msg#{AtomKey => true};
        {ok, false} -> Msg#{AtomKey => false};
        _           -> Msg
    end.

%%--------------------------------------------------------------------
%% Generic Message Collection
%%--------------------------------------------------------------------

%% Function that pulls the next message from a session.
%% Signature: fun(Session :: pid(), Ref :: reference(), Timeout :: timeout())
%%   -> {ok, message()} | {error, term()}.
-type receive_fun() :: fun((pid(), reference(), timeout()) ->
    {ok, message()} | {error, term()}).

%% Predicate that determines if a message terminates collection.
%% Returns `true' for messages that should halt the loop (included in
%% the result), `false' for messages that should continue collection.
-type terminal_pred() :: fun((message()) -> boolean()).

-doc """
Collect all messages from a session using the default terminal
predicate: `result` and `error` messages halt the loop.

`ReceiveFun` is the adapter-specific function that pulls the next
message (e.g. `gen_statem:call(Session, {receive_message, Ref}, T)`).

Returns `{ok, Messages}` in order, or `{error, Reason}` on
timeout or transport failure.

See also `collect_messages/5`.
""".
-spec collect_messages(pid(), reference(), integer(), receive_fun()) ->
    {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun) ->
    collect_messages(Session, Ref, Deadline, ReceiveFun,
        fun default_terminal/1).

-doc """
Collect all messages with a custom terminal predicate.

The predicate receives each message and returns `true` if
collection should stop (the message is included in the result).
This allows adapters like Copilot -- where only `is_error: true`
errors are terminal -- to customize halt behavior.
""".
-spec collect_messages(pid(), reference(), integer(), receive_fun(),
    terminal_pred()) -> {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun, IsTerminal) ->
    collect_loop(Session, Ref, Deadline, ReceiveFun, IsTerminal, []).

%% Internal recursive collection loop.
-spec collect_loop(pid(), reference(), integer(), receive_fun(),
    terminal_pred(), [message()]) -> {ok, [message()]} | {error, term()}.
collect_loop(Session, Ref, Deadline, ReceiveFun, IsTerminal, Acc) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {error, timeout};
        false ->
            case ReceiveFun(Session, Ref, Remaining) of
                {ok, Msg} ->
                    case IsTerminal(Msg) of
                        true ->
                            {ok, lists:reverse([Msg | Acc])};
                        false ->
                            collect_loop(Session, Ref, Deadline,
                                ReceiveFun, IsTerminal, [Msg | Acc])
                    end;
                {error, complete} ->
                    {ok, lists:reverse(Acc)};
                {error, _} = Err ->
                    Err
            end
    end.

%% Default terminal predicate: `result` and `error` messages halt.
-spec default_terminal(message()) -> boolean().
default_terminal(#{type := result}) -> true;
default_terminal(#{type := error}) -> true;
default_terminal(_) -> false.
