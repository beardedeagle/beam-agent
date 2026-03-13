-module(beam_agent).
-moduledoc """
Unified public API for the BeamAgent SDK -- a BEAM/OTP wrapper around five
agentic coder backends: Claude, Codex, Gemini, OpenCode, and Copilot.

This module is the single stable entry point for all callers. Every
user-visible feature works identically across all five backends thanks to
native-first routing with universal fallbacks.

## Getting Started

Start a session, send a query, and process the response:

```erlang
%% 1. Start a session (backend is required)
{ok, Session} = beam_agent:start_session(#{backend => claude}),

%% 2. Send a synchronous query
{ok, Messages} = beam_agent:query(Session, <<"What is the BEAM?">>),

%% 3. Process the response messages
[io:format("~s~n", [maps:get(content, M, <<>>)]) || M <- Messages],

%% 4. Stop the session when done
ok = beam_agent:stop(Session).
```

For streaming, subscribe to events before sending a query:

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Ref} = beam_agent:event_subscribe(Session),
{ok, _} = beam_agent:query(Session, <<"Explain OTP">>),
loop(Session, Ref).

loop(Session, Ref) ->
    case beam_agent:receive_event(Session, Ref, 10000) of
        {ok, #{type := result}} ->
            io:format("Done.~n");
        {ok, #{type := text, content := Content}} ->
            io:format("~s", [Content]),
            loop(Session, Ref);
        {ok, _Other} ->
            loop(Session, Ref);
        {error, complete} ->
            io:format("Stream complete.~n");
        {error, timeout} ->
            io:format("Timed out.~n")
    end.
```

## Key Concepts

### Sessions

A session is a supervised gen_statem process that owns a single transport
connection to a backend CLI. Sessions are started with start_session/1
and stopped with stop/1. Each session has a unique binary session_id,
tracks message history, and can host multiple conversation threads.

### Events

Events provide a streaming view of session activity. Call
event_subscribe/1 to register the calling process as a subscriber,
then receive_event/2 to pull events one at a time. Events are
delivered as normalized message() maps. The stream ends with an
{error, complete} sentinel after a result or error message.

### Threads

Threads group related queries into named conversation contexts within
a session. Use thread_start/2 to create a thread, thread_resume/2 to
switch to it, and thread_list/1 to enumerate threads. Each thread
tracks its own message history as a subset of the session history.

### Hooks

SDK-level lifecycle hooks fire at well-defined points (session start,
query start, tool use, etc.). Pass hook definitions in session_opts()
via the sdk_hooks key. Hooks run in-process and cannot block the
engine state machine.

### MCP (Model Context Protocol)

MCP lets you define custom tools as Erlang functions that the backend
can invoke in-process. Use add_mcp_server/2 to register a server with
its tools, mcp_status/1 to inspect registered servers, and
toggle_mcp_server/3 to enable/disable servers at runtime.

### Providers

Providers represent authentication/API endpoints for a backend. Use
current_provider/1 and set_provider/2 to manage which provider is
active. Provider management is most relevant for backends that support
multiple API endpoints (e.g., OpenCode with different LLM providers).

## Architecture

Every public function in this module follows the native_or routing
pattern: it first attempts the backend's native implementation via
beam_agent_raw_core:call/3, and if the backend returns
{error, {unsupported_native_call, _}}, it falls back to a universal
implementation in one of the core modules (beam_agent_file_core,
beam_agent_app_core, beam_agent_account_core, etc.).

The call chain is: beam_agent -> beam_agent_core -> beam_agent_router
-> beam_agent_session_engine -> backend handler. This thin wrapper
design means beam_agent contains zero business logic -- it is purely
a delegation layer.

## Core concepts

A session is a live connection to one of the five backends (Claude, Codex,
Gemini, OpenCode, Copilot). The typical lifecycle is: start a session with
start_session/1, send queries with query/2, read the response messages,
and stop the session with stop/1. The session pid returned by start_session
is a process identifier you pass to every other function in this module.

Native-or routing means every function tries the backend first. If the
backend does not support that operation, a universal OTP-based fallback
kicks in automatically. You do not need to know which path runs -- the
result is the same either way.

Events let you stream responses in real time instead of waiting for the
full answer. Subscribe with event_subscribe/1 and pull events one at a
time with receive_event/2.

## Architecture deep dive

beam_agent is a pure delegation layer with zero business logic. The call
chain is: beam_agent -> beam_agent_core -> beam_agent_router ->
beam_agent_session_engine (gen_statem) -> backend handler module.

Every public function uses the native_or macro pattern: call the backend
via beam_agent_raw_core:call/3 and, on {error, {unsupported_native_call, _}},
fall back to a universal core module (beam_agent_file_core,
beam_agent_app_core, beam_agent_account_core, beam_agent_search_core,
beam_agent_skills_core). The universal modules are ETS-backed and
process-independent.

The session engine is a gen_statem that owns the transport connection.
Session state includes the MCP registry, hook registry, message history,
and thread tracking. All mutable state lives in the engine -- this module
holds none.

## Backend Integration

If you are implementing a new backend, this module is your primary
integration surface. Functions use a native_or routing pattern: each
call tries the backend-native implementation first, and falls back to
a universal OTP-layer shim if the backend does not provide one.

When adding a new backend, you need to:

1. Implement beam_agent_session_handler callbacks (the handler drives
   your protocol).
2. Register the backend atom in beam_agent_backend.
3. Declare capabilities in beam_agent_capabilities.
4. Wire universal fallbacks -- most functions in this module already
   have them.

For the full step-by-step process, see the Backend Integration Guide
in docs/guides/backend_integration_guide.md.

## See Also

  - beam_agent_raw: escape-hatch functions for backend-native calls
  - beam_agent_capabilities: introspection of per-backend feature support
  - beam_agent_mcp: MCP server/tool definitions and dispatch
  - beam_agent_session_store: session history storage and retrieval
  - beam_agent_session_handler: callback behaviour for backend handlers
""".

-export([
    init/0,
    init/1,
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

-doc """
A normalized message map flowing through the SDK.

Every message carries a required `type` field (see message_type/0) and
optional fields that vary by type. Common fields present on most messages:
`uuid` (unique identifier), `session_id`, `content`, and `timestamp`.

Result messages additionally carry `duration_ms`, `num_turns`,
`stop_reason_atom`, `usage`, and `total_cost_usd`. Tool-use messages
carry `tool_name` and `tool_input`. See beam_agent_core for the full
field reference per message type.
""".
-type message() :: beam_agent_core:message().

-doc """
The normalized message type tag.

Values: text, assistant, tool_use, tool_result, system, result, error,
user, control, control_request, control_response, stream_event,
rate_limit_event, tool_progress, tool_use_summary, thinking,
auth_status, prompt_suggestion, raw.

The `result` type signals query completion. The `error` type signals
a backend error. The `raw` type preserves unrecognized wire messages
for forward compatibility.
""".
-type message_type() :: beam_agent_core:message_type().

-doc """
Options map for dispatching a query via query/3.

Key fields:
  - model: override the session model for this query
  - system_prompt: custom or preset system prompt configuration
  - allowed_tools / disallowed_tools: tool allowlists/denylists
  - max_tokens: maximum response tokens
  - max_turns: maximum agentic turns (tool-use rounds)
  - permission_mode: permission level for this query
  - timeout: query timeout in milliseconds
  - output_format: structured output format (text, json_schema, or map)
  - thinking: thinking/chain-of-thought configuration
  - max_budget_usd: cost cap for this query
  - agent: select a specific sub-agent
  - attachments: structured file or data attachments
""".
-type query_opts() :: beam_agent_core:query_opts().

-doc """
Options map for establishing a session via start_session/1.

Required:
  - backend: one of claude, codex, gemini, opencode, or copilot

Common options:
  - cli_path: path to the backend CLI executable
  - work_dir: working directory for the session
  - model: default model identifier
  - system_prompt: system prompt configuration
  - permission_mode: default permission level
  - session_id: explicit session identifier (auto-generated if omitted)
  - sdk_mcp_servers: list of in-process MCP tool servers
  - sdk_hooks: list of SDK-level lifecycle hook definitions
  - tools / allowed_tools / disallowed_tools: tool configuration
  - mcp_servers: external MCP server configuration map

See beam_agent_core for the full set of backend-specific options
(Codex transport modes, Copilot protocol versions, OpenCode providers,
Gemini approval modes, etc.).
""".
-type session_opts() :: beam_agent_core:session_opts().

-doc """
Backend identifier atom.

One of: claude, codex, gemini, opencode, copilot. Used throughout the
SDK to select which backend adapter handles a session.
""".
-type backend() :: beam_agent_core:backend().

-doc """
Normalized stop reason from the backend.

Values: end_turn (normal completion), max_tokens (output truncated),
stop_sequence (custom stop sequence hit), refusal (model declined),
tool_use_stop (stopped for tool use), unknown_stop (unrecognized).
Parsed from the binary wire format into atoms for pattern matching.
""".
-type stop_reason() :: beam_agent_core:stop_reason().

-doc """
Permission mode controlling tool and edit approval.

Values: default (normal approval flow), accept_edits (auto-approve
file edits), bypass_permissions (approve everything),
plan (read-only planning mode), dont_ask (TypeScript SDK only,
auto-approve without prompting).
""".
-type permission_mode() :: beam_agent_core:permission_mode().

-doc """
System prompt configuration for a session or query.

Either a plain binary (replaces the default prompt entirely) or a
structured map with `type => preset`, `preset => PresetName`, and
an optional `append => ExtraInstructions` to extend a preset prompt.
Use the `<<"claude_code">>` preset for the full Claude Code system prompt.
""".
-type system_prompt_config() :: beam_agent_core:system_prompt_config().

-doc """
Result from a permission handler callback.

Variants:
  - {allow, UpdatedInput}: approve with optional input modifications
  - {deny, Reason}: deny with a human-readable reason
  - {deny, Reason, Interrupt}: deny and request turn interruption
  - {allow, UpdatedInput, RuleUpdate}: approve with rule/permission updates
  - map(): richer structured result with keys like behavior,
    updated_input, updated_permissions, message, and interrupt
""".
-type permission_result() :: beam_agent_core:permission_result().

-doc """
Function that pulls the next message from a session event stream.

Signature: fun(Session, Ref, Timeout) -> {ok, message()} | {error, term()}.
Used by collect_messages/4 and collect_messages/5 to abstract the
message retrieval mechanism.
""".
-type receive_fun() :: beam_agent_core:receive_fun().

-doc """
Predicate that determines if a message terminates collection.

Returns true for messages that should halt the collect_messages loop
(the halting message is included in the result list). Returns false
for messages that should continue collection. The default predicate
checks for type => result.
""".
-type terminal_pred() :: beam_agent_core:terminal_pred().
-type backend_resolution_error() :: backend_not_present
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
%% Dialyzer: the options map for universal_prompt_async/3 is
%% deliberately open; encoding every possible key adds no safety.
-dialyzer({nowarn_function, [universal_prompt_async/3]}).

-doc """
Initialize ETS tables with default settings (public access).

Equivalent to `init(#{})`. Must be called before any SDK functions that
touch ETS. This is idempotent — calling it again after initialization is
a no-op.

```erlang
ok = beam_agent:init().
```
""".
-spec init() -> ok.
init() -> beam_agent_table_owner:init().

-doc """
Initialize ETS tables with the given options.

Options:
  - `table_access` — `public` (default) or `hardened`

In `public` mode, all tables use public access. Any process can read and
write. In `hardened` mode, a linked helper process is spawned to own
protected tables and proxy writes, while reads remain zero-cost from any
process.

This function is idempotent. Calling it again after initialization is a
no-op that returns `ok`. Should be called early in the consumer's `init/1`
callback, before any SDK functions that touch ETS.

```erlang
ok = beam_agent:init(#{table_access => hardened}).
```
""".
-spec init(beam_agent_table_owner:init_opts()) -> ok.
init(Opts) -> beam_agent_table_owner:init(Opts).

-doc """
Start a new agent session connected to a backend.

Launches a supervised gen_statem process that owns a transport connection
to the specified backend CLI. The session is ready to accept queries once
this call returns successfully.

Parameters:
  - Opts: session configuration map. The `backend` key is required and
    must be one of claude, codex, gemini, opencode, or copilot. See
    session_opts/0 for the full set of options.

Returns {ok, Pid} on success where Pid is the session process, or
{error, Reason} if the session could not be started.

```erlang
{ok, Session} = beam_agent:start_session(#{
    backend => claude,
    model => <<"claude-sonnet-4-20250514">>,
    system_prompt => <<"You are a helpful assistant.">>,
    permission_mode => default
}).
```
""".
-spec start_session(session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) -> beam_agent_core:start_session(Opts).

-doc """
Build a supervisor child spec for embedding a session in a supervision tree.

Returns an OTP child_spec map suitable for passing to supervisor:start_child/2
or including in a supervisor init/1 return value.

Parameters:
  - Opts: session configuration map (same as start_session/1).

```erlang
ChildSpec = beam_agent:child_spec(#{backend => claude}),
{ok, _Pid} = supervisor:start_child(MySup, ChildSpec).
```
""".
-spec child_spec(session_opts()) -> supervisor:child_spec().
child_spec(Opts) -> beam_agent_core:child_spec(Opts).

-doc """
Stop a running session and close its transport connection.

Gracefully shuts down the session gen_statem, closes the underlying
transport (port, HTTP, or WebSocket), and cleans up session state.

Parameters:
  - Session: pid of a running session process.

Returns ok.
""".
-spec stop(pid()) -> ok.
stop(Session) -> beam_agent_core:stop(Session).

-doc """
Send a synchronous query to the session with default parameters.

Blocks until the backend produces a complete response (a result-type
message). All intermediate messages (text chunks, tool use, thinking,
etc.) are collected and returned as a list.

Parameters:
  - Session: pid of a running session.
  - Prompt: the user prompt as a binary string.

Returns {ok, Messages} where Messages is a list of normalized message()
maps in chronological order, or {error, Reason} on failure.

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Messages} = beam_agent:query(Session, <<"What is Erlang?">>),
[ResultMsg | _] = lists:reverse(Messages),
io:format("~s~n", [maps:get(content, ResultMsg, <<>>)]).
```
""".
-spec query(pid(), binary()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt) -> beam_agent_core:query(Session, Prompt).

-doc """
Send a synchronous query with explicit parameters.

Like query/2 but accepts a query_opts() map to control model selection,
tool permissions, timeout, output format, and other query-level settings.

Parameters:
  - Session: pid of a running session.
  - Prompt: the user prompt as a binary string.
  - Params: query options map. See query_opts/0 for available keys.

Returns {ok, Messages} or {error, Reason}.

```erlang
{ok, Messages} = beam_agent:query(Session, <<"Refactor this module">>, #{
    model => <<"claude-sonnet-4-20250514">>,
    max_turns => 5,
    permission_mode => accept_edits,
    timeout => 120000
}).
```
""".
-spec query(pid(), binary(), query_opts()) -> {ok, [message()]} | {error, term()}.
query(Session, Prompt, Params) -> beam_agent_core:query(Session, Prompt, Params).

-doc """
Retrieve metadata about a running session.

Returns a map containing session_id, backend, model, current state,
working directory, and handler-specific metadata merged from the
backend's build_session_info callback.

Parameters:
  - Session: pid of a running session.

Returns {ok, InfoMap} or {error, Reason}.
""".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) -> beam_agent_core:session_info(Session).

-doc """
Subscribe the calling process to streaming events from a session.

After subscribing, the caller receives events via receive_event/2 or
receive_event/3. Events are normalized message() maps delivered in
real time as the backend produces them. The stream ends with an
{error, complete} sentinel after a result or error message.

Tries the backend's native event subscription first, falling back to
the universal ETS-backed event layer.

Parameters:
  - Session: pid of a running session.

Returns {ok, Ref} where Ref is a unique subscription reference, or
{error, Reason} on failure.

```erlang
{ok, Ref} = beam_agent:event_subscribe(Session),
{ok, _} = beam_agent:query(Session, <<"Hello">>),
{ok, Event} = beam_agent:receive_event(Session, Ref, 5000).
```
""".
-spec event_subscribe(pid()) -> {ok, reference()} | {error, term()}.
event_subscribe(Session) ->
    native_or(Session, event_subscribe, [], fun() ->
        beam_agent_events:subscribe(session_identity(Session))
    end).

-doc """
Receive the next event from a subscription with a 5-second default timeout.

Equivalent to receive_event(Session, Ref, 5000).

Parameters:
  - Session: pid of a running session.
  - Ref: subscription reference from event_subscribe/1.

Returns {ok, Event} where Event is a message() map, {error, complete}
when the stream has ended, {error, timeout} if no event arrives within
5 seconds, or {error, bad_ref} if the subscription is invalid.

```erlang
{ok, Ref} = beam_agent:event_subscribe(Session),
{ok, _} = beam_agent:query(Session, <<"Hello">>),
case beam_agent:receive_event(Session, Ref) of
    {ok, #{type := text, content := C}} -> io:format("~s", [C]);
    {ok, #{type := result}} -> io:format("Done~n");
    {error, complete} -> io:format("Stream ended~n")
end.
```
""".
-spec receive_event(pid(), reference()) -> {ok, message()} | {error, term()}.
receive_event(Session, Ref) ->
    receive_event(Session, Ref, 5000).

-doc """
Receive the next event from a subscription with an explicit timeout.

Blocks the calling process until an event arrives, the stream completes,
or the timeout expires.

Parameters:
  - Session: pid of a running session.
  - Ref: subscription reference from event_subscribe/1.
  - Timeout: maximum wait time in milliseconds.

Returns {ok, Event}, {error, complete}, {error, timeout}, or
{error, bad_ref}.
""".
-spec receive_event(pid(), reference(), timeout()) ->
    {ok, message()} | {error, term()}.
receive_event(Session, Ref, Timeout) ->
    native_or(Session, receive_event, [Ref, Timeout], fun() ->
        beam_agent_events:receive_event(Ref, Timeout)
    end).

-doc """
Remove an event subscription and flush any pending events from the mailbox.

Parameters:
  - Session: pid of a running session.
  - Ref: subscription reference from event_subscribe/1.

Returns {ok, ok} on success or {error, bad_ref} if the reference is invalid.
""".
-spec event_unsubscribe(pid(), reference()) -> {ok, term()} | {error, term()}.
event_unsubscribe(Session, Ref) ->
    native_or(Session, event_unsubscribe, [Ref], fun() ->
        beam_agent_events:unsubscribe(session_identity(Session), Ref)
    end).

-doc """
Return the current health state of a session as an atom.

Possible values depend on the session engine state: connecting,
initializing, ready, active_query, error, or unknown.

Parameters:
  - Session: pid of a running session.
""".
-spec health(pid()) -> atom().
health(Session) -> beam_agent_core:health(Session).

-doc """
Resolve the backend identifier for a running session.

Parameters:
  - Session: pid of a running session.

Returns {ok, Backend} where Backend is an atom like claude, codex,
gemini, opencode, or copilot, or {error, Reason} if the backend
cannot be determined.
""".
-spec backend(pid()) -> {ok, backend()} | {error, term()}.
backend(Session) -> beam_agent_core:backend(Session).

-doc """
List all registered backend identifiers.

Returns a list of atoms representing the backends available in this
build of the SDK (e.g., [claude, codex, gemini, opencode, copilot]).
""".
-spec list_backends() -> [backend()].
list_backends() -> beam_agent_core:list_backends().

-doc """
Change the model for a running session.

Sends a set_model control message to the session engine. The backend
handler may process this natively (e.g., sending a protocol message)
or the engine stores it in its own state.

Parameters:
  - Session: pid of a running session.
  - Model: binary model identifier (e.g., <<"claude-sonnet-4-20250514">>).

Returns {ok, Model} on success or {error, Reason}.
""".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) -> beam_agent_core:set_model(Session, Model).

-doc """
Change the permission mode for a running session.

Controls how the backend handles tool execution and file edit approval.
See permission_mode/0 for valid values.

Parameters:
  - Session: pid of a running session.
  - Mode: binary permission mode (e.g., <<"default">>, <<"accept_edits">>).

Returns {ok, Mode} on success or {error, Reason}.
""".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) -> beam_agent_core:set_permission_mode(Session, Mode).

-doc """
Interrupt the currently active query on a session.

Sends an interrupt signal to the backend. If the backend supports
native interrupts (e.g., sending a protocol-level cancel), it uses
that; otherwise falls back to an OS-level signal for port-based
transports.

Parameters:
  - Session: pid of a running session.

Returns ok if the interrupt was sent, or {error, not_supported} if the
backend does not support interrupts, or {error, Reason} on failure.
""".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) -> beam_agent_core:interrupt(Session).

-doc """
Abort the currently active query and reset the session to ready state.

Stronger than interrupt/1: forcibly cancels the query and transitions
the session engine back to the ready state.

Parameters:
  - Session: pid of a running session.

Returns ok or {error, Reason}.
""".
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) -> beam_agent_core:abort(Session).

-doc """
Send a backend-specific control message to a session.

Control messages provide a generic extension point for features not
covered by the typed API. The Method string identifies the operation
and Params carries its arguments. The backend handler processes the
message via its handle_control/4 callback.

Parameters:
  - Session: pid of a running session.
  - Method: binary method name (e.g., <<"mcp_message">>, <<"set_config">>).
  - Params: map of method-specific parameters.

Returns {ok, Result} on success or {error, not_supported} if the
backend does not handle this method, or {error, Reason} on failure.

```erlang
%% Send a custom control message to a Claude session
{ok, Result} = beam_agent:send_control(Session,
    <<"mcp_message">>,
    #{server => <<"my-tools">>, method => <<"tools/list">>}).
```
""".
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    beam_agent_core:send_control(Session, Method, Params).

-doc """
List all tracked sessions from the universal session store.

Returns session metadata maps sorted by updated_at descending.
Sessions are tracked automatically when messages are recorded.

Returns {ok, SessionList} where each entry is a session_meta() map
with session_id, adapter, model, cwd, created_at, updated_at, and
message_count fields.

```erlang
{ok, Sessions} = beam_agent:list_sessions(),
lists:foreach(fun(S) ->
    io:format("~s (~s)~n", [
        maps:get(session_id, S),
        maps:get(model, S, <<"unknown">>)
    ])
end, Sessions).
```
""".
-spec list_sessions() -> {ok, [beam_agent_session_store:session_meta()]}.
list_sessions() -> beam_agent_core:list_sessions().

-doc """
List tracked sessions with optional filters.

Parameters:
  - Opts: filter map with optional keys:
    - adapter: filter by backend atom
    - cwd: filter by working directory
    - model: filter by model name
    - limit: maximum number of results
    - since: unix millisecond timestamp lower bound on updated_at

Returns {ok, SessionList} sorted by updated_at descending.
""".
-spec list_sessions(beam_agent_session_store:list_opts()) ->
    {ok, [beam_agent_session_store:session_meta()]}.
list_sessions(Opts) -> beam_agent_core:list_sessions(Opts).

-doc """
List sessions from the backend's native session store (Claude-specific).

Attempts to call the Claude backend's native session listing. Falls back
to list_sessions/0 if the backend does not support native session listing.

Returns {ok, SessionList} or {error, Reason}.
""".
-spec list_native_sessions() -> {ok, list()} | {error, term()}.
list_native_sessions() ->
    case beam_agent_raw_core:call_backend(claude, list_native_sessions, []) of
        {error, {unsupported_native_call, _}} -> list_sessions();
        Other -> Other
    end.

-doc """
List sessions from the backend's native session store with filters.

Like list_native_sessions/0 but passes filter options to the native call.
Falls back to list_sessions/1 if native listing is not supported.

Parameters:
  - Opts: backend-specific filter options map.

Returns {ok, SessionList} or {error, Reason}.
""".
-spec list_native_sessions(map()) -> {ok, list()} | {error, term()}.
list_native_sessions(Opts) ->
    case beam_agent_raw_core:call_backend(claude, list_native_sessions, [Opts]) of
        {error, {unsupported_native_call, _}} -> list_sessions(Opts);
        Other -> Other
    end.

-doc """
Get all messages for a session from the universal store.

Returns the full message history in chronological order.

Parameters:
  - SessionId: binary session identifier.

Returns {ok, Messages} or {error, not_found} if no session exists
with that identifier.

```erlang
{ok, Messages} = beam_agent:get_session_messages(<<"sess_abc123">>),
io:format("Total messages: ~p~n", [length(Messages)]).
```
""".
-spec get_session_messages(binary()) -> {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId) -> beam_agent_core:get_session_messages(SessionId).

-doc """
Get messages for a session with filtering options.

Parameters:
  - SessionId: binary session identifier.
  - Opts: filter map with optional keys:
    - limit: maximum number of messages to return
    - offset: skip this many messages from the start
    - types: list of message_type() atoms to include
    - include_hidden: if true, include reverted/hidden messages

Returns {ok, Messages} or {error, not_found}.
""".
-spec get_session_messages(binary(), beam_agent_session_store:message_opts()) ->
    {ok, [message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) ->
    beam_agent_core:get_session_messages(SessionId, Opts).

-doc """
Get messages from the backend's native session store (Claude-specific).

Falls back to get_session_messages/1 if native message retrieval is
not supported by the backend.

Parameters:
  - SessionId: binary session identifier.

Returns {ok, Messages} or {error, Reason}.
""".
-spec get_native_session_messages(binary()) -> {ok, list()} | {error, term()}.
get_native_session_messages(SessionId) ->
    case beam_agent_raw_core:call_backend(claude, get_native_session_messages, [SessionId]) of
        {error, {unsupported_native_call, _}} -> get_session_messages(SessionId);
        Other -> Other
    end.

-doc """
Get messages from the backend's native session store with options.

Falls back to get_session_messages/2 if native retrieval is not supported.

Parameters:
  - SessionId: binary session identifier.
  - Opts: backend-specific message filter options.

Returns {ok, Messages} or {error, Reason}.
""".
-spec get_native_session_messages(binary(), map()) -> {ok, list()} | {error, term()}.
get_native_session_messages(SessionId, Opts) ->
    case beam_agent_raw_core:call_backend(claude, get_native_session_messages, [SessionId, Opts]) of
        {error, {unsupported_native_call, _}} -> get_session_messages(SessionId, Opts);
        Other -> Other
    end.

-doc """
Get metadata for a specific session by identifier.

Parameters:
  - SessionId: binary session identifier.

Returns {ok, SessionMeta} or {error, not_found}.
""".
-spec get_session(binary()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, not_found}.
get_session(SessionId) -> beam_agent_core:get_session(SessionId).

-doc """
Delete a session and all its messages from the universal store.

Also signals completion to any active event subscribers for that session.

Parameters:
  - SessionId: binary session identifier.

Returns ok (idempotent -- deleting a nonexistent session is a no-op).
""".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) -> beam_agent_core:delete_session(SessionId).

-doc """
Create a fork (copy) of a session's metadata and message history.

The new session receives a copy of all messages and metadata from the
source session. The fork's metadata records the parent session_id in
extra.fork.parent_session_id.

Parameters:
  - Session: pid of the source session.
  - Opts: fork options map. Optional keys:
    - session_id: explicit id for the fork (auto-generated if omitted)
    - include_hidden: include reverted messages (default true)
    - extra: additional metadata to merge into the fork

Returns {ok, ForkMeta} or {error, not_found} if the source session
does not exist.
""".
-spec fork_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
fork_session(Session, Opts) -> beam_agent_core:fork_session(Session, Opts).

-doc """
Revert a session's visible conversation state to a prior boundary.

The underlying message store remains append-only. Revert changes the
active view by storing a visible_message_count in the session metadata.

Parameters:
  - Session: pid of a running session.
  - Selector: boundary selector map. Accepts one of:
    - #{visible_message_count => N}: set boundary to N messages
    - #{message_id => Id}: set boundary to the message with this id
    - #{uuid => Id}: set boundary to the message with this uuid

Returns {ok, UpdatedMeta} or {error, not_found | invalid_selector}.
""".
-spec revert_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
revert_session(Session, Selector) -> beam_agent_core:revert_session(Session, Selector).

-doc """
Clear any revert state and restore the full visible message history.

Undoes a previous revert_session/2 call so all messages are visible again.

Parameters:
  - Session: pid of a running session.

Returns {ok, UpdatedMeta} or {error, not_found}.
""".
-spec unrevert_session(pid()) ->
    {ok, beam_agent_session_store:session_meta()} | {error, term()}.
unrevert_session(Session) -> beam_agent_core:unrevert_session(Session).

-doc """
Generate a shareable link/state for a session.

Creates or replaces the active share state with a generated share_id.

Parameters:
  - Session: pid of a running session.

Returns {ok, ShareInfo} with share_id, session_id, created_at, and
status fields, or {error, not_found}.
""".
-spec share_session(pid()) ->
    {ok, beam_agent_session_store:session_share()} | {error, term()}.
share_session(Session) -> beam_agent_core:share_session(Session).

-doc """
Generate a shareable link/state for a session with options.

Parameters:
  - Session: pid of a running session.
  - Opts: options map. Optional keys:
    - share_id: explicit share identifier (auto-generated if omitted)

Returns {ok, ShareInfo} or {error, not_found}.
""".
-spec share_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_share()} | {error, term()}.
share_session(Session, Opts) -> beam_agent_core:share_session(Session, Opts).

-doc """
Revoke the current share state for a session.

Marks the share as revoked. The share_id remains in metadata but its
status changes to revoked.

Parameters:
  - Session: pid of a running session.

Returns ok or {error, not_found}.
""".
-spec unshare_session(pid()) -> ok | {error, term()}.
unshare_session(Session) -> beam_agent_core:unshare_session(Session).

-doc """
Generate and store a summary for a session's conversation history.

Produces a deterministic summary from the session's messages including
the first user message and latest agent output.

Parameters:
  - Session: pid of a running session.

Returns {ok, SummaryMap} with content, generated_at, message_count,
and generated_by fields, or {error, not_found}.
""".
-spec summarize_session(pid()) ->
    {ok, beam_agent_session_store:session_summary()} | {error, term()}.
summarize_session(Session) -> beam_agent_core:summarize_session(Session).

-doc """
Generate and store a session summary with options.

Parameters:
  - Session: pid of a running session.
  - Opts: options map. Optional keys:
    - content / summary: explicit summary text (skips auto-generation)
    - generated_by: attribution string (default <<"beam_agent_core">>)

Returns {ok, SummaryMap} or {error, not_found}.
""".
-spec summarize_session(pid(), map()) ->
    {ok, beam_agent_session_store:session_summary()} | {error, term()}.
summarize_session(Session, Opts) -> beam_agent_core:summarize_session(Session, Opts).

-doc """
Start a new conversation thread within a session.

Creates a named thread that groups related queries. The new thread
becomes the active thread for the session. Thread messages are stored
as a subset of the session's message history, tagged with thread_id.

Parameters:
  - Session: pid of a running session.
  - Opts: thread options map. Optional keys:
    - name: human-readable thread name (defaults to the thread_id)
    - thread_id: explicit id (auto-generated if omitted)
    - metadata: arbitrary metadata map
    - parent_thread_id: id of the parent thread (for fork lineage)

Returns {ok, ThreadMeta} with thread_id, session_id, name, status,
and other metadata fields, or {error, Reason}.

```erlang
{ok, Thread} = beam_agent:thread_start(Session, #{
    name => <<"refactor-discussion">>
}),
ThreadId = maps:get(thread_id, Thread),
{ok, _} = beam_agent:query(Session, <<"Let's refactor the router">>).
```
""".
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) -> beam_agent_core:thread_start(Session, Opts).

-doc """
Resume an existing thread by its identifier.

Sets the thread as the active thread for the session and updates its
status to active. Subsequent queries will be associated with this thread.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, ThreadMeta} or {error, not_found}.

```erlang
{ok, Thread} = beam_agent:thread_resume(Session, <<"thread_abc123">>),
io:format("Resumed: ~s~n", [maps:get(name, Thread)]).
```
""".
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) -> beam_agent_core:thread_resume(Session, ThreadId).

-doc """
Resume an existing thread with backend-specific options.

Like thread_resume/2 but passes additional options to the backend's
native implementation. Falls back to thread_resume/2 if the backend
does not support extended resume options.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - Opts: backend-specific resume options.

Returns {ok, ThreadMeta} or {error, not_found}.
""".
-spec thread_resume(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId, Opts) ->
    native_or(Session, thread_resume, [ThreadId, Opts],
        fun() -> thread_resume(Session, ThreadId) end).

-doc """
List all threads for a session, sorted by updated_at descending.

Parameters:
  - Session: pid of a running session.

Returns {ok, ThreadList} where each entry is a thread metadata map.
""".
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) -> beam_agent_core:thread_list(Session).

-doc """
List threads for a session with backend-specific options.

Falls back to thread_list/1 if the backend does not support filtered
thread listing.

Parameters:
  - Session: pid of a running session.
  - Opts: backend-specific listing options.

Returns {ok, ThreadList} or {error, Reason}.
""".
-spec thread_list(pid(), map()) -> {ok, term()} | {error, term()}.
thread_list(Session, Opts) ->
    native_or(Session, thread_list, [Opts],
        fun() -> thread_list(Session) end).

-doc """
Fork an existing thread, copying its visible message history.

Creates a new thread with a copy of all visible messages from the source
thread. Message thread_id fields are rewritten to the new thread id.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary identifier of the source thread.

Returns {ok, ForkedThreadMeta} or {error, not_found}.
""".
-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId) -> beam_agent_core:thread_fork(Session, ThreadId).

-doc """
Fork an existing thread with options.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary identifier of the source thread.
  - Opts: fork options map. Optional keys:
    - thread_id: explicit id for the fork
    - name: name for the forked thread
    - parent_thread_id: override the parent reference

Returns {ok, ForkedThreadMeta} or {error, not_found}.
""".
-spec thread_fork(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId, Opts) -> beam_agent_core:thread_fork(Session, ThreadId, Opts).

-doc """
Read thread metadata and optionally its message history.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, #{thread => ThreadMeta}} or {error, not_found}.
""".
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) -> beam_agent_core:thread_read(Session, ThreadId).

-doc """
Read thread metadata with options.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - Opts: options map. Optional keys:
    - include_messages: if true, includes the messages key in the result

Returns {ok, #{thread => ThreadMeta, messages => [message()]}} or
{error, not_found}.
""".
-spec thread_read(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId, Opts) -> beam_agent_core:thread_read(Session, ThreadId, Opts).

-doc """
Archive a thread, marking it as archived and inactive.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, UpdatedThreadMeta} or {error, not_found}.
""".
-spec thread_archive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_archive(Session, ThreadId) -> beam_agent_core:thread_archive(Session, ThreadId).

-doc """
Unsubscribe from a thread and clear it as the active thread if applicable.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, ResultMap} with thread_id and unsubscribed fields, or
{error, not_found}.
""".
-spec thread_unsubscribe(pid(), binary()) -> {ok, term()} | {error, term()}.
thread_unsubscribe(Session, ThreadId) ->
    native_or(Session, thread_unsubscribe, [ThreadId], fun() ->
        universal_thread_unsubscribe(Session, ThreadId)
    end).

-doc """
Rename a thread.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - Name: new thread name as a binary.

Returns {ok, ResultMap} or {error, not_found}.
""".
-spec thread_name_set(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
thread_name_set(Session, ThreadId, Name) ->
    native_or(Session, thread_name_set, [ThreadId, Name], fun() ->
        universal_thread_name_set(Session, ThreadId, Name)
    end).

-doc """
Merge a metadata patch into a thread's metadata map.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - MetadataPatch: map of key-value pairs to merge into the thread's
    existing metadata.

Returns {ok, ResultMap} or {error, not_found}.
""".
-spec thread_metadata_update(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
thread_metadata_update(Session, ThreadId, MetadataPatch) ->
    native_or(Session, thread_metadata_update, [ThreadId, MetadataPatch], fun() ->
        universal_thread_metadata_update(Session, ThreadId, MetadataPatch)
    end).

-doc """
Unarchive a previously archived thread, restoring it to active status.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, UpdatedThreadMeta} or {error, not_found}.
""".
-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) -> beam_agent_core:thread_unarchive(Session, ThreadId).

-doc """
Rollback a thread's visible message history to a prior boundary.

The underlying messages are preserved; only the visible window changes.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - Selector: boundary selector map. Accepts one of:
    - #{count => N}: hide the last N visible messages
    - #{visible_message_count => N}: set boundary directly
    - #{message_id => Id} or #{uuid => Id}: set boundary to a message

Returns {ok, UpdatedThreadMeta} or {error, not_found | invalid_selector}.
""".
-spec thread_rollback(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_rollback(Session, ThreadId, Selector) ->
    beam_agent_core:thread_rollback(Session, ThreadId, Selector).

-doc """
List loaded (in-memory) threads for a session.

Returns threads with their active state, optionally filtered by the
backend's native implementation.

Parameters:
  - Session: pid of a running session.

Returns {ok, ResultMap} with threads, active_thread_id, and count fields.
""".
-spec thread_loaded_list(pid()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session) ->
    native_or(Session, thread_loaded_list, [], fun() ->
        universal_thread_loaded_list(Session, #{})
    end).

-doc """
List loaded threads for a session with filter options.

Parameters:
  - Session: pid of a running session.
  - Opts: filter options map. Optional keys:
    - include_archived: include archived threads (default true)
    - thread_id: filter to a specific thread
    - status: filter by thread status
    - limit: maximum number of results

Returns {ok, ResultMap} or {error, Reason}.
""".
-spec thread_loaded_list(pid(), map()) -> {ok, map()} | {error, term()}.
thread_loaded_list(Session, Opts) ->
    native_or(Session, thread_loaded_list, [Opts], fun() ->
        universal_thread_loaded_list(Session, Opts)
    end).

-doc """
Compact a thread by reducing its visible message history.

Uses thread_rollback internally with a selector derived from the
options map. If no selector is provided, compacts to zero visible
messages.

Parameters:
  - Session: pid of a running session.
  - Opts: compaction options map. Optional keys:
    - thread_id: target thread (defaults to active thread)
    - count: number of messages to hide from the end
    - visible_message_count: set boundary directly
    - selector: explicit rollback selector map

Returns {ok, ResultMap} or {error, not_found}.
""".
-spec thread_compact(pid(), map()) -> {ok, map()} | {error, term()}.
thread_compact(Session, Opts) ->
    native_or(Session, thread_compact, [Opts], fun() ->
        universal_thread_compact(Session, Opts)
    end).

-doc """
Steer an active turn by injecting additional input mid-conversation.

Allows you to redirect or refine the agent's current turn within a
thread. The backend processes the steer natively if supported; the
universal fallback records the steer intent as a system message.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - TurnId: binary identifier of the active turn.
  - Input: steering input, either a binary prompt or a list of
    structured content block maps.

Returns {ok, ResultMap} or {error, Reason}.
""".
-spec turn_steer(pid(), binary(), binary(), binary() | [map()]) ->
    {ok, term()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input) ->
    turn_steer(Session, ThreadId, TurnId, Input, #{}).

-doc """
Steer an active turn with additional options.

Like turn_steer/4 but accepts an options map for backend-specific
steering parameters.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - TurnId: binary identifier of the active turn.
  - Input: steering input (binary or structured content blocks).
  - Opts: backend-specific options map.

Returns {ok, ResultMap} or {error, Reason}.
""".
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

-doc """
Interrupt a specific turn within a thread.

Cancels the identified turn. The universal fallback delegates to
interrupt/1 on the session.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.
  - TurnId: binary turn identifier.

Returns {ok, ResultMap} with status => interrupted, or {error, Reason}.
""".
-spec turn_interrupt(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
turn_interrupt(Session, ThreadId, TurnId) ->
    native_or(Session, turn_interrupt, [ThreadId, TurnId], fun() ->
        universal_turn_interrupt(Session, ThreadId, TurnId)
    end).

-doc """
Start a realtime collaboration thread for voice or audio streaming.

Opens a persistent bidirectional channel between the caller and the
backend, suitable for streaming audio or text in real time. Use this
when building interactive voice assistants or live pair-programming
sessions that require continuous input rather than request/response
turns.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:start_realtime/2) if the
backend does not provide one.

Session is the pid of a running beam_agent session. Params is a map
that configures the channel:

  mode   - binary, the channel type (e.g., <<"voice">>, <<"text">>).
  model  - binary, optional model override for the realtime session.

Backend-specific keys in Params are forwarded unchanged.

Returns {ok, Map} on success, where Map contains at minimum
thread_id (the binary identifier for the new channel) and status.
Returns {error, Reason} if the channel cannot be opened.

Example:

  Params = #{mode => <<"voice">>, model => <<"claude-sonnet">>},
  {ok, #{thread_id := Tid}} = beam_agent:thread_realtime_start(Session, Params).
""".
-spec thread_realtime_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) ->
    native_or(Session, thread_realtime_start, [Params], fun() ->
        beam_agent_collaboration:start_realtime(
            session_identity(Session),
            with_session_backend(Session, Params))
    end).

-doc """
Append audio data to an active realtime thread.

Sends an audio chunk to a previously started realtime collaboration
channel. Call this repeatedly to stream audio frames into the session.
The backend processes each chunk and may emit intermediate responses
depending on the realtime mode.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:append_realtime_audio/3)
if the backend does not provide one.

Session is the pid of a running beam_agent session. ThreadId is the
binary identifier returned by thread_realtime_start/2. Params is a
map containing the audio payload:

  audio    - binary, the encoded audio data.
  encoding - binary, optional encoding format (e.g., <<"pcm16">>,
             <<"opus">>). Defaults to the format negotiated at
             channel start.

Returns {ok, Map} with an acknowledgment on success, or
{error, Reason} if the thread is not active or the data is invalid.
""".
-spec thread_realtime_append_audio(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params) ->
    native_or(Session, thread_realtime_append_audio, [ThreadId, Params], fun() ->
        beam_agent_collaboration:append_realtime_audio(session_identity(Session), ThreadId, Params)
    end).

-doc """
Append text data to an active realtime thread.

Injects a text message into a previously started realtime collaboration
channel. Use this to send typed input alongside or instead of audio in
a realtime session, for example to provide corrections or commands
while voice streaming is active.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:append_realtime_text/3)
if the backend does not provide one.

Session is the pid of a running beam_agent session. ThreadId is the
binary identifier returned by thread_realtime_start/2. Params is a
map containing the text payload:

  text - binary, the text content to inject into the realtime stream.

Returns {ok, Map} on success, or {error, Reason} if the thread is
not active or the payload is invalid.
""".
-spec thread_realtime_append_text(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params) ->
    native_or(Session, thread_realtime_append_text, [ThreadId, Params], fun() ->
        beam_agent_collaboration:append_realtime_text(session_identity(Session), ThreadId, Params)
    end).

-doc """
Stop and tear down an active realtime collaboration thread.

Closes the bidirectional channel identified by ThreadId, releasing
any backend resources associated with it. After this call the
ThreadId is no longer valid and further append calls will return
an error.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:stop_realtime/2) if the
backend does not provide one.

Session is the pid of a running beam_agent session. ThreadId is the
binary identifier returned by thread_realtime_start/2.

Returns {ok, Map} with the final channel status on success, or
{error, Reason} if the thread was already stopped or never existed.
""".
-spec thread_realtime_stop(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) ->
    native_or(Session, thread_realtime_stop, [ThreadId], fun() ->
        beam_agent_collaboration:stop_realtime(session_identity(Session), ThreadId)
    end).

-doc """
Start a code review collaboration session.

Opens a review context where the backend analyzes code changes and
provides structured feedback. Use this when you want the agent to
review a diff, a set of files, or a pull request and return comments,
suggestions, and severity ratings.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:start_review/2) if the
backend does not provide one.

Session is the pid of a running beam_agent session. Params is a map
configuring the review scope:

  files       - list of binary file paths to include in the review.
  diff        - binary, a unified diff to review instead of files.
  review_type - binary, optional review flavour (e.g., <<"security">>,
                <<"style">>, <<"correctness">>).

Returns {ok, Map} on success, where Map includes a review_id and
initial review metadata. Returns {error, Reason} if the review
cannot be started.

Example:

  Params = #{files => [<<"src/app.erl">>], review_type => <<"correctness">>},
  {ok, #{review_id := Rid}} = beam_agent:review_start(Session, Params).
""".
-spec review_start(pid(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) ->
    native_or(Session, review_start, [Params], fun() ->
        beam_agent_collaboration:start_review(
            session_identity(Session),
            with_session_backend(Session, Params))
    end).

-doc """
List the collaboration modes supported by the session's backend.

Returns a map describing each mode the backend can operate in for
collaborative workflows. Common modes include review (structured code
review) and realtime (streaming audio/text). Use this to discover
what collaboration features are available before starting a session.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:collaboration_modes/1)
if the backend does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, Map} keyed by mode name, where each value describes the
mode's capabilities, or {error, Reason} on failure.
""".
-spec collaboration_mode_list(pid()) -> {ok, map()} | {error, term()}.
collaboration_mode_list(Session) ->
    native_or(Session, collaboration_mode_list, [], fun() ->
        beam_agent_collaboration:collaboration_modes(session_identity(Session))
    end).

-doc """
List experimental or beta features available for a session.

Convenience wrapper that calls experimental_feature_list/2 with an
empty options map. See experimental_feature_list/2 for full details.

Session is the pid of a running beam_agent session.

Returns {ok, List} of feature maps, or {error, Reason} on failure.
""".
-spec experimental_feature_list(pid()) -> {ok, term()} | {error, term()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).

-doc """
List experimental or beta features available for a session, with
optional filters.

Queries the backend for features that are experimental, in preview,
or otherwise not yet part of the stable API surface. Use this to
discover and inspect opt-in capabilities before enabling them.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_collaboration:experimental_features/2)
if the backend does not provide one.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters:

  category - binary, restrict results to a feature category.
  name     - binary, match features by name pattern.

Returns {ok, List} of feature maps on success. Each map contains
at minimum id, name, description, and enabled (boolean). Returns
{error, Reason} on failure.
""".
-spec experimental_feature_list(pid(), map()) -> {ok, term()} | {error, term()}.
experimental_feature_list(Session, Opts) ->
    native_or(Session, experimental_feature_list, [Opts], fun() ->
        beam_agent_collaboration:experimental_features(session_identity(Session), Opts)
    end).

-doc """
Return the list of CLI commands the backend supports.

Returns a static list of commands declared by the backend adapter
(e.g., query, edit, review). The list does not change during the
lifetime of a session because it reflects the adapter's compiled
capability table rather than runtime state.

Session is the pid of a running beam_agent session.

Returns {ok, List} of command maps, each containing at minimum a
name and description, or {error, Reason} on failure.
""".
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) -> beam_agent_core:supported_commands(Session).

-doc """
Return the list of LLM models the backend can use.

Queries the backend adapter for its declared model catalog. The
available models depend on the backend: Claude backends list models
such as claude-sonnet and claude-opus, while OpenAI-based backends
list GPT variants.

Session is the pid of a running beam_agent session.

Returns {ok, List} of model maps, each containing at minimum a model
name and its capabilities, or {error, Reason} on failure.
""".
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) -> beam_agent_core:supported_models(Session).

-doc """
Return the list of sub-agents the backend exposes.

Sub-agents are specialized assistants (e.g., code reviewer, test
writer) that the primary agent can delegate tasks to. This function
returns the static list declared by the backend adapter rather than
any runtime-registered agents.

Session is the pid of a running beam_agent session.

Returns {ok, List} of agent maps, each containing at minimum a name
and description, or {error, Reason} on failure.
""".
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) -> beam_agent_core:supported_agents(Session).

-doc """
Return account and authentication information for the session's
backend provider.

Queries the backend for the account context associated with the
current session. Useful for verifying credentials, checking usage
quotas, or displaying account details in a dashboard.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map may include account_id,
email, plan, usage quotas, and authentication method. Returns
{error, Reason} if the information cannot be retrieved.
""".
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) -> beam_agent_core:account_info(Session).

-doc """
List commands available for a session.

Tries the backend-native command listing first; falls back to the
static supported_commands/1 catalog if the backend does not provide
a native implementation. Prefer this over supported_commands/1 when
you want the most accurate view of what is currently available at
runtime.

Session is the pid of a running beam_agent session.

Returns {ok, List} of command maps, each containing at minimum a
name and description, or {error, Reason} on failure.
""".
-spec list_commands(pid()) -> {ok, list()} | {error, term()}.
list_commands(Session) ->
    native_or(Session, list_commands, [], fun() -> supported_commands(Session) end).

-doc """
List all tools registered with a session.

Returns every tool (function/capability) the session currently
exposes. Tools include built-in capabilities such as file editing,
search, and bash execution, as well as any tools provided by MCP
servers or plugins.

Session is the pid of a running beam_agent session.

Returns {ok, List} of tool maps on success. Each map includes name,
description, and input_schema. Returns {error, Reason} on failure.
""".
-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Session) -> beam_agent_core:list_tools(Session).

-doc """
List skills registered with a session.

Skills are reusable prompt templates or workflows that can be
invoked by name. Each skill encapsulates a specific task pattern
(e.g., code review checklist, migration assistant) and can be
shared across sessions.

Session is the pid of a running beam_agent session.

Returns {ok, List} of skill maps on success. Each map includes
name, description, and path. Returns {error, Reason} on failure.
""".
-spec list_skills(pid()) -> {ok, [map()]} | {error, term()}.
list_skills(Session) -> beam_agent_core:list_skills(Session).

-doc """
List plugins registered with a session.

Plugins extend the agent with additional tools, skills, and hooks.
Each plugin is a self-contained extension package that can be enabled
or disabled independently.

Session is the pid of a running beam_agent session.

Returns {ok, List} of plugin maps on success. Each map includes
name, description, enabled status, and the list of tools the plugin
provides. Returns {error, Reason} on failure.
""".
-spec list_plugins(pid()) -> {ok, [map()]} | {error, term()}.
list_plugins(Session) -> beam_agent_core:list_plugins(Session).

-doc """
List MCP (Model Context Protocol) servers registered with a session.

MCP servers provide external tool integrations over a standardized
protocol. Each registered server exposes its own set of tools that
the agent can invoke during a conversation.

Session is the pid of a running beam_agent session.

Returns {ok, List} of server maps on success. Each map includes the
server name, connection status, and the tools the server provides.
Returns {error, Reason} on failure.
""".
-spec list_mcp_servers(pid()) -> {ok, [map()]} | {error, term()}.
list_mcp_servers(Session) -> beam_agent_core:list_mcp_servers(Session).

-doc """
List sub-agents registered with a session.

Sub-agents are specialized assistants that the primary agent can
delegate tasks to. Examples include a code reviewer agent, a test
writer agent, or a documentation agent. This returns the runtime
set of agents, which may differ from the static catalog returned
by supported_agents/1 if agents have been dynamically registered.

Session is the pid of a running beam_agent session.

Returns {ok, List} of agent definition maps on success. Each map
includes at minimum the agent name and description. Returns
{error, Reason} on failure.
""".
-spec list_agents(pid()) -> {ok, [map()]} | {error, term()}.
list_agents(Session) -> beam_agent_core:list_agents(Session).

-doc """
List skills for a session using native-or routing.

Convenience wrapper that calls skills_list/2 with an empty options
map. See skills_list/2 for full details.

Tries the backend-native skill listing first; falls back to
list_skills/1 if the backend does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of skill maps, or {error, Reason} on failure.
""".
-spec skills_list(pid()) -> {ok, term()} | {error, term()}.
skills_list(Session) ->
    native_or(Session, skills_list, [], fun() -> list_skills(Session) end).

-doc """
List skills for a session with optional filter criteria.

Tries the backend-native skill listing first; falls back to
list_skills/1 if the backend does not provide one. When the
fallback is used, filtering is applied client-side.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters:

  category - binary, restrict results to a skill category.
  enabled  - boolean, filter by enabled/disabled status.
  name     - binary, match skills whose name contains this string.

Returns {ok, List} of skill maps on success, or {error, Reason}
on failure.
""".
-spec skills_list(pid(), map()) -> {ok, term()} | {error, term()}.
skills_list(Session, Opts) ->
    native_or(Session, skills_list, [Opts], fun() -> list_skills(Session) end).

-doc """
List skills available in remote registries for a session.

Convenience wrapper that calls skills_remote_list/2 with an empty
options map. See skills_remote_list/2 for full details.

Session is the pid of a running beam_agent session.

Returns {ok, List} of remote skill maps, or {error, Reason} on
failure.
""".
-spec skills_remote_list(pid()) -> {ok, term()} | {error, term()}.
skills_remote_list(Session) ->
    native_or(Session, skills_remote_list, [], fun() ->
        universal_skills_remote_list(Session, #{})
    end).

-doc """
List skills available in remote registries, with optional filters.

Remote skills are published to shared registries and can be imported
into a local session. Use this to browse what is available before
importing or exporting skills.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_skills_core) if the backend does not
provide one.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters:

  registry - binary, restrict results to a specific registry.
  category - binary, filter by skill category.
  name     - binary, match skills whose name contains this string.

Returns {ok, List} of remote skill maps on success, or
{error, Reason} on failure.
""".
-spec skills_remote_list(pid(), map()) -> {ok, term()} | {error, term()}.
skills_remote_list(Session, Opts) ->
    native_or(Session, skills_remote_list, [Opts], fun() ->
        universal_skills_remote_list(Session, Opts)
    end).

-doc """
Export a local skill to a remote registry.

Publishes a skill from the current session to a shared registry so
that other sessions or users can discover and import it. The skill
must already exist locally.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_skills_core:skills_remote_export/2)
if the backend does not provide one.

Session is the pid of a running beam_agent session. Opts is a map
that must include at minimum:

  skill_path - binary, the local file path of the skill to export.

Additional keys (e.g., registry, description) are forwarded to the
registry.

Returns {ok, Map} with export confirmation on success, or
{error, Reason} on failure.

Example:

  Opts = #{skill_path => <<"/skills/review_checklist.md">>},
  {ok, _} = beam_agent:skills_remote_export(Session, Opts).
""".
-spec skills_remote_export(pid(), map()) -> {ok, term()} | {error, term()}.
skills_remote_export(Session, Opts) ->
    native_or(Session, skills_remote_export, [Opts], fun() ->
        beam_agent_skills_core:skills_remote_export(Session, Opts)
    end).

-doc """
Enable or disable a skill by its file path.

Writes a configuration entry that controls whether the given skill
is active for the session. Disabled skills remain registered but
are not offered to the agent during conversations.

Tries the backend-native implementation first; falls back to
beam_agent_skills_core:skills_config_write/3 if the backend does
not provide one.

Session is the pid of a running beam_agent session. Path is a
binary file path identifying the skill. Enabled is a boolean
indicating whether the skill should be active.

Returns {ok, Map} on success, where Map contains the path and
enabled status. Returns {error, Reason} on failure.
""".
-spec skills_config_write(pid(), binary(), boolean()) -> {ok, term()} | {error, term()}.
skills_config_write(Session, Path, Enabled) ->
    native_or(Session, skills_config_write, [Path, Enabled], fun() ->
        beam_agent_skills_core:skills_config_write(Session, Path, Enabled),
        {ok, with_universal_source(Session, #{path => Path, enabled => Enabled})}
    end).

-doc """
List apps and projects registered for a session.

Convenience wrapper that calls apps_list/2 with an empty options
map. See apps_list/2 for full details.

Session is the pid of a running beam_agent session.

Returns {ok, List} of app maps, or {error, Reason} on failure.
""".
-spec apps_list(pid()) -> {ok, term()} | {error, term()}.
apps_list(Session) ->
    native_or(Session, apps_list, [], fun() ->
        beam_agent_app_core:apps_list(Session)
    end).

-doc """
List apps and projects registered for a session, with optional
filter criteria.

Queries the app registry for projects associated with the session.
Use this to enumerate workspaces, check project status, or find a
specific project by name.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_app_core:apps_list/2) if the backend
does not provide one.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters:

  status - binary, restrict results by project status (e.g.,
           <<"active">>, <<"archived">>).
  name   - binary, match projects whose name contains this string.

Returns {ok, List} of app maps on success. Each map includes id,
name, path, and status. Returns {error, Reason} on failure.

Example:

  {ok, Apps} = beam_agent:apps_list(Session, #{status => <<"active">>}).
""".
-spec apps_list(pid(), map()) -> {ok, term()} | {error, term()}.
apps_list(Session, Opts) ->
    native_or(Session, apps_list, [Opts], fun() ->
        beam_agent_app_core:apps_list(Session, Opts)
    end).

-doc """
Return information about the current app or project context for a
session.

Retrieves metadata about the project the session is currently
operating in. Useful for displaying project details or for logic
that depends on the project type.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_app_core:app_info/1) if the backend
does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map includes the project name,
root path, detected language, and configuration. Returns
{error, Reason} if no project context is set.
""".
-spec app_info(pid()) -> {ok, term()} | {error, term()}.
app_info(Session) ->
    native_or(Session, app_info, [], fun() ->
        beam_agent_app_core:app_info(Session)
    end).

-doc """
Initialize the app and project context for a session.

Scans the working directory, detects the project type and primary
language, and sets up project-specific settings such as build
commands and test runners. Call this after starting a session if
you need project-aware features like app_info/1 or app_modes/1.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_app_core:app_init/1) if the backend
does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, Map} with the initialized project metadata on success,
or {error, Reason} if the working directory cannot be scanned.
""".
-spec app_init(pid()) -> {ok, term()} | {error, term()}.
app_init(Session) ->
    native_or(Session, app_init, [], fun() ->
        beam_agent_app_core:app_init(Session)
    end).

-doc """
Append a log entry to the session's app log.

Writes a structured log message into the session's application log.
Use this for auditing, debugging, or tracking agent actions within
a project context.

Tries the backend-native implementation first; falls back to
beam_agent_app_core:app_log/2 if the backend does not provide one.

Session is the pid of a running beam_agent session. Body is a map
with at minimum:

  message - binary, the log message text.

Optional keys include level (e.g., <<"info">>, <<"error">>),
category (e.g., <<"tool_use">>, <<"query">>), and metadata (a map
of additional context).

Returns {ok, Map} with status set to logged on success, or
{error, Reason} on failure.
""".
-spec app_log(pid(), map()) -> {ok, term()} | {error, term()}.
app_log(Session, Body) ->
    native_or(Session, app_log, [Body], fun() ->
        _ = beam_agent_app_core:app_log(Session, Body),
        {ok, with_universal_source(Session, #{status => logged})}
    end).

-doc """
List available app modes for a session.

App modes are configuration presets that adjust agent behavior.
Common modes include default, debug, and verbose. Each mode defines
settings such as log verbosity, tool restrictions, and model
preferences.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_app_core:app_modes/1) if the backend
does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of mode maps on success, each describing a mode
and its configuration. Returns {error, Reason} on failure.
""".
-spec app_modes(pid()) -> {ok, term()} | {error, term()}.
app_modes(Session) ->
    native_or(Session, app_modes, [], fun() ->
        beam_agent_app_core:app_modes(Session)
    end).

-doc """
List models available for a session using native-or routing.

Convenience wrapper that calls model_list/2 with an empty options
map. See model_list/2 for full details.

Tries the backend-native model listing first; falls back to the
static supported_models/1 catalog if the backend does not provide
one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of model maps, or {error, Reason} on failure.
""".
-spec model_list(pid()) -> {ok, term()} | {error, term()}.
model_list(Session) ->
    native_or(Session, model_list, [], fun() -> supported_models(Session) end).

-doc """
List models available for a session with optional filter criteria.

Tries the backend-native model listing first; falls back to the
static supported_models/1 catalog if the backend does not provide
one. When the fallback is used, filtering is applied client-side.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters that are backend-specific (e.g., capability
requirements, model family).

Returns {ok, List} of model maps on success, or {error, Reason}
on failure.
""".
-spec model_list(pid(), map()) -> {ok, term()} | {error, term()}.
model_list(Session, Opts) ->
    native_or(Session, model_list, [Opts], fun() -> supported_models(Session) end).

-doc """
Return the overall status of a running session.

Assembles a composite status view including session health, connection
state, active backend, and session metadata. Use this for dashboards,
health checks, or debugging connectivity issues.

Tries the backend-native implementation first; falls back to the
universal layer, which assembles a status map from session_info/1
and health/1.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map includes keys such as
status, backend, health, and session_id. Returns {error, Reason}
if the session is unreachable.

Example:

  {ok, #{status := <<"ok">>, backend := Backend}} =
      beam_agent:get_status(Session).
""".
-spec get_status(pid()) -> {ok, term()} | {error, term()}.
get_status(Session) ->
    native_or(Session, get_status, [], fun() ->
        universal_get_status(Session)
    end).

-doc """
Return the authentication status for a session's provider.

Checks whether the session holds valid credentials for its backend
provider. Use this to verify that API keys or OAuth tokens are still
valid before issuing queries.

Tries the backend-native implementation first; falls back to the
universal layer, which assembles status from account_info/1.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map includes whether the session
is authenticated, the authentication method, and token expiration if
applicable. Returns {error, Reason} on failure.
""".
-spec get_auth_status(pid()) -> {ok, term()} | {error, term()}.
get_auth_status(Session) ->
    native_or(Session, get_auth_status, [], fun() ->
        universal_get_auth_status(Session)
    end).

-doc """
Return the backend's own session identifier for a running session.

Retrieves the session ID assigned by the backend service, which is
distinct from the Erlang pid. Use this when you need to correlate
BEAM-side state with backend logs, API calls, or external tooling.

Tries the backend-native implementation first; falls back to the
universal layer, which derives the identifier from session_identity/1.

Session is the pid of a running beam_agent session.

Returns {ok, SessionId} where SessionId is typically a binary string,
or {error, Reason} if the identifier cannot be determined.
""".
-spec get_last_session_id(pid()) -> {ok, term()} | {error, term()}.
get_last_session_id(Session) ->
    native_or(Session, get_last_session_id, [], fun() ->
        {ok, session_identity(Session)}
    end).

-doc """
Retrieve a specific tool definition by its identifier.

Looks up a single tool from the session's tool registry. Use this
when you need the full schema for a known tool rather than scanning
the entire list returned by list_tools/1.

Session is the pid of a running beam_agent session. ToolId is a
binary string identifying the tool (e.g., <<"Bash">>, <<"Read">>,
<<"Edit">>).

Returns {ok, Map} on success, where Map includes name, description,
and input_schema. Returns {error, not_found} if no tool with the
given identifier is registered.
""".
-spec get_tool(pid(), binary()) -> {ok, map()} | {error, term()}.
get_tool(Session, ToolId) -> beam_agent_core:get_tool(Session, ToolId).

-doc """
Retrieve a specific skill definition by its identifier.

Looks up a single skill from the session's skill registry. Use this
when you need the full definition for a known skill rather than
scanning the entire list returned by list_skills/1.

Session is the pid of a running beam_agent session. SkillId is a
binary string identifying the skill.

Returns {ok, Map} on success, where Map includes name, description,
and path. Returns {error, not_found} if no skill with the given
identifier is registered.
""".
-spec get_skill(pid(), binary()) -> {ok, map()} | {error, term()}.
get_skill(Session, SkillId) -> beam_agent_core:get_skill(Session, SkillId).

-doc """
Retrieve a specific plugin definition by its identifier.

Looks up a single plugin from the session's plugin registry. Use
this when you need the full definition for a known plugin rather
than scanning the entire list returned by list_plugins/1.

Session is the pid of a running beam_agent session. PluginId is a
binary string identifying the plugin.

Returns {ok, Map} on success, where Map includes name, description,
enabled status, and the list of tools the plugin provides. Returns
{error, not_found} if no plugin with the given identifier is
registered.
""".
-spec get_plugin(pid(), binary()) -> {ok, map()} | {error, term()}.
get_plugin(Session, PluginId) -> beam_agent_core:get_plugin(Session, PluginId).

-doc """
Retrieve a specific sub-agent definition by its identifier.

Looks up a single sub-agent from the session's agent registry. Use
this when you need the full definition for a known agent rather than
scanning the entire list returned by list_agents/1.

Session is the pid of a running beam_agent session. AgentId is a
binary string identifying the sub-agent.

Returns {ok, Map} on success, where Map includes name, description,
and the agent's capabilities. Returns {error, not_found} if no agent
with the given identifier is registered.
""".
-spec get_agent(pid(), binary()) -> {ok, map()} | {error, term()}.
get_agent(Session, AgentId) -> beam_agent_core:get_agent(Session, AgentId).

-doc """
Return the currently active LLM provider for a session.

Providers represent service endpoints such as Anthropic, OpenAI, or
Google. The active provider determines which service subsequent
queries are routed through.

Session is the pid of a running beam_agent session.

Returns {ok, ProviderId} where ProviderId is a binary (e.g.,
<<"anthropic">>), or {error, not_set} if no provider has been
explicitly selected.
""".
-spec current_provider(pid()) -> {ok, binary()} | {error, not_set}.
current_provider(Session) -> beam_agent_core:current_provider(Session).

-doc """
Set the active LLM provider for a session.

Changes the service endpoint that subsequent queries are routed
through. The provider must be one of the providers returned by
provider_list/1.

Session is the pid of a running beam_agent session. ProviderId is
a binary identifying the provider (e.g., <<"anthropic">>,
<<"openai">>).

Returns ok unconditionally. Use get_auth_status/1 after switching
to verify that credentials are valid for the new provider.
""".
-spec set_provider(pid(), binary()) -> ok.
set_provider(Session, ProviderId) -> beam_agent_core:set_provider(Session, ProviderId).

-doc """
Clear the active provider for a session.

Removes the explicit provider selection, reverting to the session's
default provider as determined by the backend adapter configuration.

Session is the pid of a running beam_agent session.

Returns ok unconditionally.
""".
-spec clear_provider(pid()) -> ok.
clear_provider(Session) -> beam_agent_core:clear_provider(Session).

-doc """
List all available providers for a session.

Returns every LLM provider the session can route queries through.
Use this to discover which providers are configured before calling
set_provider/2.

Tries the backend-native implementation first; falls back to
beam_agent_runtime:list_providers/1 if the backend does not provide
one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of provider maps on success. Each map includes
id, name, and status. Returns {error, Reason} on failure.
""".
-spec provider_list(pid()) -> {ok, [map()]} | {error, term()}.
provider_list(Session) ->
    native_or(Session, provider_list, [], fun() -> beam_agent_runtime:list_providers(Session) end).

-doc """
List authentication methods available for the session's providers.

Returns the set of auth mechanisms each provider supports. Common
methods include API key, OAuth, and SSO. Use this to determine how
to authenticate before calling provider_oauth_authorize/3 or
setting credentials directly.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_config:provider_auth_methods/1) if the
backend does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, List} of auth method maps on success, or
{error, Reason} on failure.
""".
-spec provider_auth_methods(pid()) -> {ok, term()} | {error, term()}.
provider_auth_methods(Session) ->
    native_or(Session, provider_auth_methods, [], fun() ->
        beam_agent_config:provider_auth_methods(Session)
    end).

-doc """
Initiate an OAuth authorization flow for a specific provider.

Begins the OAuth handshake by generating an authorization URL that
the end user should visit to grant access. After the user authorizes,
the provider redirects to the callback URI with an authorization
code, which you then pass to provider_oauth_callback/3.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_config:provider_oauth_authorize/3) if
the backend does not provide one.

Session is the pid of a running beam_agent session. ProviderId is
a binary identifying the target provider (e.g., <<"anthropic">>).
Body is a map of OAuth parameters:

  redirect_uri - binary, the URI to redirect to after authorization.
  scope        - binary, optional scope string.

Additional provider-specific keys are forwarded unchanged.

Returns {ok, Map} on success, where Map includes authorization_url.
Returns {error, Reason} on failure.

Example:

  Body = #{redirect_uri => MyCallbackUri, scope => <<"read write">>},
  {ok, #{authorization_url := Url}} =
      beam_agent:provider_oauth_authorize(Session, <<"anthropic">>, Body).
""".
-spec provider_oauth_authorize(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
provider_oauth_authorize(Session, ProviderId, Body) ->
    native_or(Session, provider_oauth_authorize, [ProviderId, Body], fun() ->
        beam_agent_config:provider_oauth_authorize(Session, ProviderId, Body)
    end).

-doc """
Handle an OAuth callback after user authorization.

Completes the OAuth handshake by exchanging the authorization code
received at the callback URI for access and refresh tokens. Call
this after the user has authorized via the URL returned by
provider_oauth_authorize/3.

Tries the backend-native implementation first; falls back to the
universal layer (beam_agent_config:provider_oauth_callback/3) if
the backend does not provide one.

Session is the pid of a running beam_agent session. ProviderId is
a binary identifying the provider. Body is a map of callback
parameters:

  code  - binary, the authorization code from the callback.
  state - binary, the state parameter for CSRF verification.

Returns {ok, Map} on success, where Map includes token information
such as access_token and expires_in. Returns {error, Reason} if
the exchange fails.
""".
-spec provider_oauth_callback(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
provider_oauth_callback(Session, ProviderId, Body) ->
    native_or(Session, provider_oauth_callback, [ProviderId, Body], fun() ->
        beam_agent_config:provider_oauth_callback(Session, ProviderId, Body)
    end).

-doc """
Return the currently active sub-agent for a session.

Sub-agents specialize in specific tasks such as code review, test
generation, or documentation. When a sub-agent is active, queries
are routed through that agent's prompt and tool configuration
instead of the primary agent.

Session is the pid of a running beam_agent session.

Returns {ok, AgentId} where AgentId is a binary identifying the
active sub-agent, or {error, not_set} if the session is using the
primary agent.
""".
-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) -> beam_agent_core:current_agent(Session).

-doc """
Set the active sub-agent for a session.

Switches the session to use a specialized sub-agent for subsequent
queries. The agent must be one of the agents returned by
list_agents/1.

Session is the pid of a running beam_agent session. AgentId is a
binary identifying the sub-agent to activate.

Returns ok unconditionally. Use current_agent/1 to verify the
change took effect.
""".
-spec set_agent(pid(), binary()) -> ok.
set_agent(Session, AgentId) -> beam_agent_core:set_agent(Session, AgentId).

-doc """
Clear the active sub-agent for a session.

Removes the sub-agent selection, reverting the session to use the
primary agent for all subsequent queries.

Session is the pid of a running beam_agent session.

Returns ok unconditionally.
""".
-spec clear_agent(pid()) -> ok.
clear_agent(Session) -> beam_agent_core:clear_agent(Session).

-doc """
List all persisted sessions known to the backend server.

Queries the session store for every session associated with the current
backend. Each entry in the returned list is a map containing at minimum
a session_id key. Backends that support server-side session persistence
return richer metadata (creation time, model, message count).

The universal fallback delegates to beam_agent_session_store_core.
""".
-spec list_server_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    native_or(Session, list_server_sessions, [], fun() ->
        case backend(Session) of
            {ok, Backend} -> beam_agent_session_store_core:list_sessions(#{adapter => Backend});
            {error, _} = Error -> Error
        end
    end).

-doc """
Retrieve a single persisted session by its identifier.

Returns the full session map for SessionId, including message history
when the backend supports it. Returns {error, not_found} if the
session does not exist in the store.
""".
-spec get_server_session(pid(), binary()) -> {ok, map()} | {error, term()}.
get_server_session(Session, SessionId) ->
    native_or(Session, get_server_session, [SessionId], fun() -> get_session(SessionId) end).

-doc """
Delete a persisted session from the backend server.

Removes the session identified by SessionId from the session store.
Returns a confirmation map with the session_id and deleted flag on
success. Does not affect the currently running in-memory session.
""".
-spec delete_server_session(pid(), binary()) -> {ok, term()} | {error, term()}.
delete_server_session(Session, SessionId) ->
    native_or(Session, delete_server_session, [SessionId], fun() ->
        ok = delete_session(SessionId),
        {ok, #{session_id => SessionId, deleted => true}}
    end).

-doc """
List all sub-agents registered on the backend server.

Returns the set of sub-agents the backend exposes. Sub-agents are
specialized assistants (e.g., a code reviewer or test writer) that the
primary agent can delegate to. The universal fallback queries the
in-memory agent registry.
""".
-spec list_server_agents(pid()) -> {ok, term()} | {error, term()}.
list_server_agents(Session) ->
    native_or(Session, list_server_agents, [], fun() -> list_agents(Session) end).

-doc """
Read the full configuration for a session.

Returns the merged configuration map that governs the session's
behavior. This includes model settings, permission mode, system
prompt, working directory, and any backend-specific keys. The
universal fallback delegates to beam_agent_config.
""".
-spec config_read(pid()) -> {ok, map()} | {error, term()}.
config_read(Session) ->
    native_or(Session, config_read, [], fun() -> beam_agent_config:config_read(Session) end).

-doc """
Read the session configuration with additional options.

Opts can filter or transform the returned configuration. The exact
keys accepted depend on the backend. The universal fallback ignores
Opts and returns the full configuration.
""".
-spec config_read(pid(), map()) -> {ok, map()} | {error, term()}.
config_read(Session, Opts) ->
    native_or(Session, config_read, [Opts], fun() -> beam_agent_config:config_read(Session) end).

-doc """
Update the session configuration with a partial patch.

Merges Body into the existing configuration. Only the keys present
in Body are changed; all other keys are preserved. Returns the
updated configuration or an error if the update is rejected by the
backend (e.g., read-only keys).
""".
-spec config_update(pid(), map()) -> {ok, term()} | {error, term()}.
config_update(Session, Body) ->
    native_or(Session, config_update, [Body], fun() ->
        beam_agent_config:config_update(Session, Body)
    end).

-doc """
List the providers available in the session configuration.

A provider represents an LLM service endpoint (e.g., Anthropic,
OpenAI, Google). This is a convenience wrapper that delegates to
provider_list/1 in the universal fallback path.
""".
-spec config_providers(pid()) -> {ok, term()} | {error, term()}.
config_providers(Session) ->
    native_or(Session, config_providers, [], fun() -> provider_list(Session) end).

-doc """
Search for text matching Pattern in the session's working directory.

Performs a grep-like search across files under the session's configured
working directory. Pattern is a binary string (not a regex). Returns a
list of match maps, each containing the file path, line number, and
matching line content.

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Matches} = beam_agent:find_text(Session, <<"TODO">>),
[io:format("~s:~p: ~s~n", [
    maps:get(path, M),
    maps:get(line, M),
    maps:get(content, M)
]) || M <- Matches].
```

The universal fallback delegates to beam_agent_file_core:find_text/2,
which shells out to grep or uses file:read_file/1 scanning.
""".
-spec find_text(pid(), binary()) -> {ok, term()} | {error, term()}.
find_text(Session, Pattern) ->
    native_or(Session, find_text, [Pattern], fun() ->
        beam_agent_file_core:find_text(Pattern, session_file_opts(Session))
    end).

-doc """
Find files matching a pattern in the session's working directory.

Opts controls the search behavior. Common keys:

  pattern -- A glob or name substring to match (e.g., <<"*.erl">>).
  max_results -- Maximum number of files to return.
  include_hidden -- Whether to include dot-files (default false).

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Files} = beam_agent:find_files(Session, #{pattern => <<"*.erl">>}),
[io:format("~s~n", [maps:get(path, F)]) || F <- Files].
```

The universal fallback merges session file options (working directory)
with the caller-supplied Opts and delegates to beam_agent_file_core.
""".
-spec find_files(pid(), map()) -> {ok, term()} | {error, term()}.
find_files(Session, Opts) ->
    native_or(Session, find_files, [Opts], fun() ->
        beam_agent_file_core:find_files(maps:merge(session_file_opts(Session), Opts))
    end).

-doc """
Search for code symbols matching Query in the session's project.

Searches for function, module, type, and record definitions whose
names match Query. Returns a list of symbol maps with keys such as
name, kind, path, and line. The universal fallback delegates to
beam_agent_file_core:find_symbols/2.
""".
-spec find_symbols(pid(), binary()) -> {ok, term()} | {error, term()}.
find_symbols(Session, Query) ->
    native_or(Session, find_symbols, [Query], fun() ->
        beam_agent_file_core:find_symbols(Query, session_file_opts(Session))
    end).

-doc """
List files and directories at the given Path.

Returns directory entries as a list of maps. Each entry includes
the name, type (file or directory), and size where available. Path
is resolved relative to the session's working directory when it is
not absolute. The universal fallback uses beam_agent_file_core.
""".
-spec file_list(pid(), binary()) -> {ok, term()} | {error, term()}.
file_list(Session, Path) ->
    native_or(Session, file_list, [Path], fun() ->
        beam_agent_file_core:file_list(Path)
    end).

-doc """
Read the contents of a file at the given Path.

Returns the file content as a binary. Path is resolved relative to
the session's working directory when it is not absolute. Returns
{error, enoent} if the file does not exist. The universal fallback
delegates to beam_agent_file_core:file_read/1.
""".
-spec file_read(pid(), binary()) -> {ok, term()} | {error, term()}.
file_read(Session, Path) ->
    native_or(Session, file_read, [Path], fun() ->
        beam_agent_file_core:file_read(Path)
    end).

-doc """
Get the version-control status of files in the session's project.

Returns a summary of file modifications, additions, and deletions
relative to the project's version control baseline (typically git).
The universal fallback delegates to beam_agent_file_core:file_status/1
using the session's working directory.
""".
-spec file_status(pid()) -> {ok, term()} | {error, term()}.
file_status(Session) ->
    native_or(Session, file_status, [], fun() ->
        beam_agent_file_core:file_status(session_file_opts(Session))
    end).

-doc """
Write a single configuration value at the given key path.

Convenience wrapper that calls config_value_write/4 with empty options.
See config_value_write/4 for details.
""".
-spec config_value_write(pid(), binary(), term()) -> {ok, term()} | {error, term()}.
config_value_write(Session, KeyPath, Value) ->
    config_value_write(Session, KeyPath, Value, #{}).

-doc """
Write a single configuration value at the given key path with options.

KeyPath is a dot-separated binary identifying the configuration key
(e.g., <<"model">>, <<"permissions.mode">>). Value is the new value
to store. Opts may include backend-specific write options such as
scope or persistence level.

Returns {ok, Result} on success where Result contains the written
key and value, or {error, Reason} if the key is read-only or the
value is invalid.
""".
-spec config_value_write(pid(), binary(), term(), map()) -> {ok, term()} | {error, term()}.
config_value_write(Session, KeyPath, Value, Opts) ->
    native_or(Session, config_value_write, [KeyPath, Value, Opts], fun() ->
        beam_agent_config:config_value_write(Session, KeyPath, Value, Opts)
    end).

-doc """
Write multiple configuration values in a single batch.

Convenience wrapper that calls config_batch_write/3 with empty options.
See config_batch_write/3 for details.
""".
-spec config_batch_write(pid(), [map()]) -> {ok, term()} | {error, term()}.
config_batch_write(Session, Edits) ->
    config_batch_write(Session, Edits, #{}).

-doc """
Write multiple configuration values in a single batch with options.

Edits is a list of maps, each containing a key_path and value to write.
All edits are applied atomically when the backend supports it. Opts may
include backend-specific write options. Returns {ok, Result} on success
or {error, Reason} if any edit fails validation.
""".
-spec config_batch_write(pid(), [map()], map()) -> {ok, term()} | {error, term()}.
config_batch_write(Session, Edits, Opts) ->
    native_or(Session, config_batch_write, [Edits, Opts], fun() ->
        beam_agent_config:config_batch_write(Session, Edits, Opts)
    end).

-doc """
Read the configuration requirements for a session.

Returns the set of required configuration keys and their constraints
(types, allowed values, defaults). Useful for building configuration
UIs or validating user input before calling config_update/2.
""".
-spec config_requirements_read(pid()) -> {ok, term()} | {error, term()}.
config_requirements_read(Session) ->
    native_or(Session, config_requirements_read, [], fun() ->
        beam_agent_config:config_requirements_read(Session)
    end).

-doc """
Detect external agent configuration files in the project.

Scans the session's working directory for configuration files from
other agentic tools (e.g., .cursorrules, CLAUDE.md, .github/copilot).
Convenience wrapper that calls external_agent_config_detect/2 with
empty options.
""".
-spec external_agent_config_detect(pid()) -> {ok, term()} | {error, term()}.
external_agent_config_detect(Session) ->
    external_agent_config_detect(Session, #{}).

-doc """
Detect external agent configuration files with options.

Opts may include filters such as a list of specific config formats
to detect or directories to scan. Returns a list of detected config
files with their format, path, and a summary of their contents.
""".
-spec external_agent_config_detect(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_config_detect(Session, Opts) ->
    native_or(Session, external_agent_config_detect, [Opts], fun() ->
        beam_agent_config:external_agent_config_detect(Session, Opts)
    end).

-doc """
Import an external agent configuration into the session.

Takes a previously detected external config (from
external_agent_config_detect/1) and merges its settings into the
session configuration. Opts should include the path or identifier
of the config to import.
""".
-spec external_agent_config_import(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_config_import(Session, Opts) ->
    native_or(Session, external_agent_config_import, [Opts], fun() ->
        beam_agent_config:external_agent_config_import(Session, Opts)
    end).

-doc """
Get the status of all MCP (Model Context Protocol) servers.

Returns a map of server names to their current status (connected,
disconnected, error). This is a convenience alias for
mcp_server_status/1.

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Status} = beam_agent:mcp_status(Session),
maps:foreach(fun(Name, Info) ->
    io:format("~s: ~s~n", [Name, maps:get(status, Info, unknown)])
end, Status).
```
""".
-spec mcp_status(pid()) -> {ok, term()} | {error, term()}.
mcp_status(Session) ->
    native_or(Session, mcp_status, [], fun() -> mcp_server_status(Session) end).

-doc """
Register a new MCP tool server with the session.

Body describes the server to add. It must contain a name (binary) and
a tools list (list of tool definition maps). Each tool map should have
at minimum a name and description key.

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
Server = #{
    <<"name">> => <<"my-tools">>,
    <<"tools">> => [
        #{<<"name">> => <<"greet">>,
          <<"description">> => <<"Say hello">>,
          <<"parameters">> => #{}}
    ]
},
{ok, Result} = beam_agent:add_mcp_server(Session, Server),
io:format("Added: ~s~n", [maps:get(server_name, Result)]).
```

The universal fallback creates an in-process tool registry via
beam_agent_tool_registry and registers the server there.
""".
-spec add_mcp_server(pid(), map()) -> {ok, term()} | {error, term()}.
add_mcp_server(Session, Body) ->
    native_or(Session, add_mcp_server, [Body], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            Server = beam_agent_tool_registry:server(
                maps:get(<<"name">>, Body, maps:get(name, Body, <<"unnamed">>)),
                maps:get(<<"tools">>, Body, maps:get(tools, Body, []))),
            NewRegistry = beam_agent_tool_registry:register_server(Server, Registry),
            {{ok, with_universal_source(Session, #{status => added,
                server_name => maps:get(name, Server)})}, NewRegistry}
        end)
    end).

-doc """
Get the status of all registered MCP servers for a session.

Returns a map keyed by server name. Each value contains the server's
connection state and tool count. Returns an empty map when no servers
are registered. The universal fallback reads from the in-process
beam_agent_tool_registry.
""".
-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Session) ->
    native_or(Session, mcp_server_status, [], fun() ->
        case beam_agent_tool_registry:get_session_registry(Session) of
            {ok, Registry} -> beam_agent_tool_registry:server_status(Registry);
            {error, not_found} -> {ok, #{}}
        end
    end).

-doc """
Replace all MCP servers with the given list.

Overwrites the entire server registry for this session. Servers is a
list of server definition maps (same format as add_mcp_server/2 Body).
Any previously registered servers not in the new list are removed.
""".
-spec set_mcp_servers(pid(), term()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    native_or(Session, set_mcp_servers, [Servers], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            NewRegistry = beam_agent_tool_registry:set_servers(Servers, Registry),
            {{ok, with_universal_source(Session, #{status => updated})}, NewRegistry}
        end)
    end).

-doc """
Reconnect a disconnected MCP server by name.

Attempts to re-establish the connection to the named server. Returns
{error, {server_not_found, ServerName}} if no server with that name
is registered. The universal fallback resets the server state in the
in-process tool registry.
""".
-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    native_or(Session, reconnect_mcp_server, [ServerName], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            case beam_agent_tool_registry:reconnect_server(ServerName, Registry) of
                {ok, NewRegistry} ->
                    {{ok, with_universal_source(Session, #{status => reconnected,
                        server_name => ServerName})}, NewRegistry};
                {error, not_found} ->
                    {{error, {server_not_found, ServerName}}, Registry}
            end
        end)
    end).

-doc """
Enable or disable an MCP server by name.

When Enabled is false, the server's tools are hidden from the backend
but the server definition is preserved. Setting Enabled back to true
restores the tools. Returns {error, {server_not_found, ServerName}}
if no server with that name exists.
""".
-spec toggle_mcp_server(pid(), binary(), boolean()) -> {ok, term()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    native_or(Session, toggle_mcp_server, [ServerName, Enabled], fun() ->
        universal_mcp_registry_op(Session, fun(Registry) ->
            case beam_agent_tool_registry:toggle_server(ServerName, Enabled, Registry) of
                {ok, NewRegistry} ->
                    {{ok, with_universal_source(Session, #{status => toggled,
                        server_name => ServerName, enabled => Enabled})}, NewRegistry};
                {error, not_found} ->
                    {{error, {server_not_found, ServerName}}, Registry}
            end
        end)
    end).

-doc """
Initiate an OAuth login flow for an MCP server.

Params should identify the server and include any required OAuth
parameters (client_id, redirect_uri, scopes). This operation requires
native backend support; the universal fallback returns a
status => not_supported result.
""".
-spec mcp_server_oauth_login(pid(), map()) -> {ok, term()} | {error, term()}.
mcp_server_oauth_login(Session, Params) ->
    native_or(Session, mcp_server_oauth_login, [Params], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_supported,
            reason => <<"OAuth login requires native backend support">>,
            params => Params})}
    end).

-doc """
Reload all MCP server configurations.

Forces a refresh of tool definitions from all registered servers.
Useful after a server has been updated externally. The universal
fallback confirms the reload against the in-process registry without
performing external I/O.
""".
-spec mcp_server_reload(pid()) -> {ok, term()} | {error, term()}.
mcp_server_reload(Session) ->
    native_or(Session, mcp_server_reload, [], fun() ->
        case beam_agent_tool_registry:get_session_registry(Session) of
            {ok, _Registry} ->
                {ok, with_universal_source(Session, #{status => reloaded})};
            {error, not_found} ->
                {ok, with_universal_source(Session, #{status => no_registry})}
        end
    end).

-doc """
Initiate an account login flow.

Params contains credentials or OAuth tokens required by the backend's
authentication provider. The exact keys depend on the provider (e.g.,
api_key, access_token, email). The universal fallback delegates to
beam_agent_account_core which stores credentials in ETS.
""".
-spec account_login(pid(), map()) -> {ok, term()} | {error, term()}.
account_login(Session, Params) ->
    native_or(Session, account_login, [Params], fun() ->
        beam_agent_account_core:account_login(Session, Params)
    end).

-doc """
Cancel an in-progress account login flow.

Aborts a login that was started with account_login/2 but has not yet
completed (e.g., waiting for OAuth redirect). Params should match the
original login parameters so the backend can identify which flow to
cancel.
""".
-spec account_login_cancel(pid(), map()) -> {ok, term()} | {error, term()}.
account_login_cancel(Session, Params) ->
    native_or(Session, account_login_cancel, [Params], fun() ->
        beam_agent_account_core:account_login_cancel(Session, Params)
    end).

-doc """
Log out of the current account.

Parameters:
  - Session: pid of a running session.

Returns {ok, Result} or {error, Reason}.
""".
-spec account_logout(pid()) -> {ok, term()} | {error, term()}.
account_logout(Session) ->
    native_or(Session, account_logout, [], fun() ->
        beam_agent_account_core:account_logout(Session)
    end).

-doc """
Get rate limit information for the current account.

Falls back to account_info/1 for backends without native
rate limit reporting.

Parameters:
  - Session: pid of a running session.

Returns {ok, RateLimitInfo} or {error, Reason}.
""".
-spec account_rate_limits(pid()) -> {ok, term()} | {error, term()}.
account_rate_limits(Session) ->
    native_or(Session, account_rate_limits, [], fun() -> account_info(Session) end).

-doc """
Fuzzy-search for files by name in the session's project.

Convenience wrapper that calls fuzzy_file_search/3 with empty options.
See fuzzy_file_search/3 for details.
""".
-spec fuzzy_file_search(pid(), binary()) -> {ok, term()} | {error, term()}.
fuzzy_file_search(Session, Query) ->
    fuzzy_file_search(Session, Query, #{}).

-doc """
Fuzzy-search for files by name with options.

Query is a partial file name to match (e.g., <<"sess_eng">> matches
beam_agent_session_engine.erl). Opts may include:

  cwd -- Base directory to search under.
  max_results -- Maximum matches to return (default 50).
  roots -- List of root directories to search.

Returns up to max_results matches sorted by score descending. Each
match is a map with path, score, and name keys. The universal
fallback delegates to beam_agent_search_core which walks the
filesystem and applies a fuzzy scoring algorithm that rewards
consecutive matches and word-boundary hits.
""".
-spec fuzzy_file_search(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
fuzzy_file_search(Session, Query, Opts) ->
    native_or(Session, fuzzy_file_search, [Query, Opts], fun() ->
        beam_agent_search_core:fuzzy_file_search(Query, Opts)
    end).

-doc """
Start a stateful fuzzy file search session.

Creates a search session identified by SearchSessionId that caches
file listings from Roots. Subsequent calls to
fuzzy_file_search_session_update/3 reuse this cache for faster
incremental searches (useful for typeahead UIs). The session persists
in ETS until explicitly stopped with fuzzy_file_search_session_stop/2.
""".
-spec fuzzy_file_search_session_start(pid(), binary(), [term()]) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_start(Session, SearchSessionId, Roots) ->
    native_or(Session, fuzzy_file_search_session_start,
              [SearchSessionId, Roots], fun() ->
        beam_agent_search_core:session_start(Session, SearchSessionId, Roots)
    end).

-doc """
Update a search session with a new query string.

Runs the fuzzy scoring algorithm against the roots cached in the
session identified by SearchSessionId. Returns the new set of matches.
The session caches the latest results so callers can page or filter
without re-scanning. Returns {error, not_found} if the session does
not exist.
""".
-spec fuzzy_file_search_session_update(pid(), binary(), binary()) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_update(Session, SearchSessionId, Query) ->
    native_or(Session, fuzzy_file_search_session_update,
              [SearchSessionId, Query], fun() ->
        beam_agent_search_core:session_update(Session, SearchSessionId, Query)
    end).

-doc """
Stop and clean up a fuzzy file search session.

Removes the session identified by SearchSessionId from ETS, freeing
its cached file listing and results. Safe to call even if the session
has already been stopped.
""".
-spec fuzzy_file_search_session_stop(pid(), binary()) ->
    {ok, term()} | {error, term()}.
fuzzy_file_search_session_stop(Session, SearchSessionId) ->
    native_or(Session, fuzzy_file_search_session_stop,
              [SearchSessionId], fun() ->
        beam_agent_search_core:session_stop(Session, SearchSessionId),
        {ok, with_universal_source(Session, #{status => stopped,
            search_session_id => SearchSessionId})}
    end).

-doc """
Start the Windows sandbox setup process.

Initiates sandbox configuration for backends that run in a Windows
environment. On non-Windows platforms the universal fallback returns
status => not_applicable with the current platform architecture.
""".
-spec windows_sandbox_setup_start(pid(), map()) -> {ok, term()} | {error, term()}.
windows_sandbox_setup_start(Session, Opts) ->
    native_or(Session, windows_sandbox_setup_start, [Opts], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"Windows sandbox not applicable on this platform">>,
            platform => list_to_binary(erlang:system_info(system_architecture))})}
    end).

-doc """
Set the maximum number of thinking tokens for the session.

Controls how many tokens the backend's reasoning model may use for
internal chain-of-thought before producing a visible response. Higher
values allow deeper reasoning at the cost of latency and token usage.
The universal fallback persists this as a configuration value.
""".
-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, term()} | {error, term()}.
set_max_thinking_tokens(Session, MaxTokens) ->
    native_or(Session, set_max_thinking_tokens, [MaxTokens], fun() ->
        _ = beam_agent_config:config_value_write(
            Session, <<"max_thinking_tokens">>, MaxTokens, #{}),
        {ok, with_universal_source(Session, #{
            max_thinking_tokens => MaxTokens})}
    end).

-doc """
Rewind files to a previous checkpoint.

Restores the file state captured at CheckpointUuid. This undoes all
file modifications made after the checkpoint was created, effectively
rolling back the working tree. The session's message history is not
affected. Returns {error, not_found} if the checkpoint does not exist.
""".
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

-doc """
Stop a running task by its identifier.

Sends an interrupt to the session and marks the task as stopped.
TaskId identifies the specific task (query or sub-agent invocation)
to cancel. The universal fallback calls interrupt/1 on the session
process.
""".
-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Session, TaskId) ->
    native_or(Session, stop_task, [TaskId], fun() ->
        _ = interrupt(Session),
        {ok, with_universal_source(Session, #{
            status => stopped, task_id => TaskId})}
    end).

-doc """
Perform backend-specific session initialization.

Called after start_session/1 to complete any additional setup that
requires an active transport connection. Opts may include
backend-specific initialization parameters. The universal fallback
registers the session with the runtime core.
""".
-spec session_init(pid(), map()) -> {ok, term()} | {error, term()}.
session_init(Session, Opts) ->
    native_or(Session, session_init, [Opts], fun() ->
        beam_agent_runtime_core:register_session(Session, Opts),
        {ok, with_universal_source(Session, #{status => initialized})}
    end).

-doc """
Get all messages for the current session.

Returns the complete message history for the session's active
conversation. Each message is a normalized map with type, role, and
content keys. See get_session_messages/1 for more details.
""".
-spec session_messages(pid()) -> {ok, term()} | {error, term()}.
session_messages(Session) ->
    native_or(Session, session_messages, [], fun() ->
        get_session_messages(session_identity(Session))
    end).

-doc """
Get messages for the current session with filtering options.

Opts may include pagination keys (limit, offset) or filters
(role, type) to narrow the returned message list. The universal
fallback delegates to get_session_messages/2.
""".
-spec session_messages(pid(), map()) -> {ok, term()} | {error, term()}.
session_messages(Session, Opts) ->
    native_or(Session, session_messages, [Opts], fun() ->
        get_session_messages(session_identity(Session), Opts)
    end).

-doc """
Send a prompt asynchronously without blocking for the full response.

Convenience wrapper that calls prompt_async/3 with empty options.
See prompt_async/3 for details.
""".
-spec prompt_async(pid(), binary()) -> {ok, map()} | {error, _}.
prompt_async(Session, Prompt) ->
    prompt_async(Session, Prompt, #{}).

-doc """
Send a prompt asynchronously with options.

Submits Prompt to the backend and returns immediately with a result
map containing a request_id. The caller should use event_subscribe/1
and receive_event/2 to collect the streamed response. Opts may
include query parameters such as system_prompt or model.

Unlike query/2, this function does not block until completion. It is
the preferred approach for UIs and concurrent workflows.
""".
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

-doc """
Execute a shell command in the session's working directory.

Convenience wrapper that calls shell_command/3 with empty options.
See shell_command/3 for details.
""".
-spec shell_command(pid(), binary()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command) ->
    shell_command(Session, Command, #{}).

-doc """
Execute a shell command with options.

Runs Command as a subprocess in the session's working directory.
Returns a result map containing stdout, stderr, and exit_code. Opts
may include timeout (milliseconds) and env (environment variable
overrides). The universal fallback uses os:cmd/1 or open_port/2.
""".
-spec shell_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command, Opts) ->
    native_or(Session, shell_command, [Command, Opts], fun() ->
        universal_shell_command(Session, Command, Opts)
    end).

-doc """
Append text to the TUI prompt input buffer.

Injects Text into the terminal UI's prompt field as if the user had
typed it. Only meaningful for backends with a native terminal
interface. The universal fallback returns status => not_applicable.
""".
-spec tui_append_prompt(pid(), binary()) -> {ok, term()} | {error, term()}.
tui_append_prompt(Session, Text) ->
    native_or(Session, tui_append_prompt, [Text], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>,
            text => Text})}
    end).

-doc """
Open the TUI help panel.

This operation requires a native terminal backend. The universal
fallback returns a not_applicable status.

Parameters:
  - Session: pid of a running session.

Returns {ok, Result} or {error, Reason}.
""".
-spec tui_open_help(pid()) -> {ok, term()} | {error, term()}.
tui_open_help(Session) ->
    native_or(Session, tui_open_help, [], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>})}
    end).

-doc """
Destroy the current session and clean up all associated state.

Removes the session from the session store, runtime registry,
config store, feedback store, callback registry, and tool registry.
Also unregisters the session from the backend. This is a more
thorough cleanup than stop/1, which only terminates the process.
""".
-spec session_destroy(pid()) -> {ok, term()} | {error, term()}.
session_destroy(Session) ->
    SessionId = session_identity(Session),
    native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-doc """
Destroy a specific session by its identifier.

Same as session_destroy/1 but targets a specific SessionId, which
may differ from the calling session's own identifier. Useful for
cleaning up persisted sessions that are no longer needed.
""".
-spec session_destroy(pid(), binary()) -> {ok, term()} | {error, term()}.
session_destroy(Session, SessionId) ->
    native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-doc """
Run a command through the backend's command execution facility.

Convenience wrapper that calls command_run/3 with empty options.
Command may be a single binary or a list of binaries (command + args).
See command_run/3 for details.
""".
-spec command_run(pid(), binary() | [binary()]) -> {ok, term()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

-doc """
Run a command through the backend's command execution facility with options.

Executes Command via the backend's native command runner (which may
apply sandboxing, permission checks, or audit logging). Falls back
to a universal shell executor when the backend does not support
native command execution. Opts may include timeout, env, and cwd
overrides.
""".
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

-doc """
Write data to the stdin of a running command.

Convenience wrapper that calls command_write_stdin/4 with empty options.
See command_write_stdin/4 for details.
""".
-spec command_write_stdin(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).

-doc """
Write data to the stdin of a running command with options.

Sends Stdin bytes to the process identified by ProcessId (returned
by a previous command_run/3 call). This requires the backend to
maintain an active process handle. The universal fallback returns
status => not_supported since it cannot write to arbitrary process
handles without native backend cooperation.
""".
-spec command_write_stdin(pid(), binary(), binary(), map()) ->
    {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin, Opts) ->
    native_or(Session, command_write_stdin, [ProcessId, Stdin, Opts], fun() ->
        {ok, with_universal_source(Session, #{
            status => not_supported,
            reason => <<"Stdin write requires an active native process handle">>,
            process_id => ProcessId})}
    end).

-doc """
Submit user feedback about the session or a specific response.

Feedback is a map that may contain rating (thumbs_up/thumbs_down),
comment (freeform text), and message_id (to associate feedback with
a specific response). The universal fallback stores the feedback in
the control core for later retrieval.
""".
-spec submit_feedback(pid(), map()) -> {ok, term()} | {error, term()}.
submit_feedback(Session, Feedback) ->
    native_or(Session, submit_feedback, [Feedback], fun() ->
        universal_submit_feedback(Session, Feedback)
    end).

-doc """
Respond to a turn-based request from the backend.

Some backends issue permission_request or tool_use_request messages
that require explicit user approval. RequestId identifies the pending
request (from the message's request_id field). Params contains the
response payload (e.g., #{approved => true} for permissions).
""".
-spec turn_respond(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
turn_respond(Session, RequestId, Params) ->
    native_or(Session, turn_respond, [RequestId, Params], fun() ->
        universal_turn_respond(Session, RequestId, Params)
    end).

-doc """
Send a named command to the backend.

This is a general-purpose dispatch mechanism for backend-specific
commands that do not have dedicated API functions. Command is a
binary name and Params is a map of command arguments. Delegates to
send_control/3 in the universal fallback.
""".
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    native_or(Session, send_command, [Command, Params],
        fun() -> send_control(Session, Command, Params) end).

-doc """
Check the health of the backend server.

Returns a status map with health indicators including the backend
name, session identifier, and uptime in milliseconds. The universal
fallback derives health from session_info/1. Returns
status => unknown when session info is unavailable.
""".
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

-doc """
List all known capabilities across all backends.

Returns the full capability matrix as a list of capability_info maps.
Each entry describes one capability (e.g., query, threads, mcp) with
its support level across all five backends.

```erlang
AllCaps = beam_agent:capabilities(),
[io:format("~s: ~s~n", [
    maps:get(name, C),
    maps:get(description, C, <<>>)
]) || C <- AllCaps].
```
""".
-spec capabilities() -> [beam_agent_capabilities:capability_info()].
capabilities() -> beam_agent_capabilities:all().

-doc """
List capabilities for a specific session or backend.

When given a pid, queries the live session for its backend and returns
that backend's capability set. When given a backend atom or binary,
returns the static capability set for that backend without requiring
a running session.
""".
-spec capabilities(pid() | backend() | binary() | atom()) ->
    {ok, [map()]} |
    {error, backend_resolution_error()}.
capabilities(Session) when is_pid(Session) ->
    beam_agent_capabilities:for_session(Session);
capabilities(BackendLike) ->
    beam_agent_capabilities:for_backend(BackendLike).

-doc """
Check whether a backend supports a specific capability.

Returns {ok, true} when the capability is supported by the given
backend. Returns {error, {unsupported_capability, Name}} when it is
not, or {error, {unknown_backend, Backend}} for unrecognized backends.

```erlang
case beam_agent:supports(threads, claude) of
    {ok, true} ->
        io:format("Claude supports threads~n");
    {error, _} ->
        io:format("Threads not supported~n")
end.
```
""".
-spec supports(beam_agent_capabilities:capability(),
               backend() | binary() | atom()) ->
    {ok, true} | {error, supports_error()}.
supports(Capability, BackendLike) ->
    beam_agent_capabilities:supports(Capability, BackendLike).

-doc """
Normalize a raw wire-format message into the SDK message format.

Converts a backend-specific message map into the canonical message()
format used throughout the SDK. Applies type detection from the
message content, normalizes field names, and adds any missing
required keys with default values.
""".
-spec normalize_message(map()) -> message().
normalize_message(Message) -> beam_agent_core:normalize_message(Message).

-doc """
Generate a unique request identifier.

Produces a binary UUID suitable for use as a control message
request_id or query correlation identifier.
""".
-spec make_request_id() -> binary().
make_request_id() -> beam_agent_core:make_request_id().

-doc """
Parse a raw stop reason value into a stop_reason() atom.

Accepts binaries (<<"end_turn">>), strings ("end_turn"), or atoms
and returns the corresponding stop_reason() atom for use in pattern
matching. Unrecognized values are mapped to unknown.
""".
-spec parse_stop_reason(term()) -> stop_reason().
parse_stop_reason(Value) -> beam_agent_core:parse_stop_reason(Value).

-doc """
Parse a raw permission mode value into a permission_mode() atom.

Accepts binaries (<<"auto">>), strings ("auto"), or atoms and returns
the corresponding permission_mode() atom. Unrecognized values are
mapped to default.
""".
-spec parse_permission_mode(term()) -> permission_mode().
parse_permission_mode(Value) -> beam_agent_core:parse_permission_mode(Value).

-doc """
Collect messages from a subscription until a result message or deadline.

Loops calling ReceiveFun to pull messages from the subscription
identified by Ref. Accumulates messages until either a message with
type => result arrives or the wall-clock Deadline (erlang:system_time
millisecond) is reached. Returns all collected messages in order.

This is the building block behind query/2 synchronous semantics.
See collect_messages/5 for a variant with a custom terminal predicate.
""".
-spec collect_messages(pid(), reference(), integer(), receive_fun()) ->
    {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun) ->
    beam_agent_core:collect_messages(Session, Ref, Deadline, ReceiveFun).

-doc """
Collect messages with a custom terminal predicate.

Same as collect_messages/4 but stops when TerminalPred returns true
for a message instead of checking for type => result. This allows
callers to define their own completion condition (e.g., stop on the
first tool_use message, or after N text chunks).
""".
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
    fun((beam_agent_tool_registry:mcp_registry()) ->
        {{ok, term()} | {error, term()}, beam_agent_tool_registry:mcp_registry()})) ->
    {ok, term()} | {error, term()}.
universal_mcp_registry_op(Session, Fun) ->
    case beam_agent_tool_registry:get_session_registry(Session) of
        {ok, Registry} ->
            {Result, NewRegistry} = Fun(Registry),
            _ = beam_agent_tool_registry:update_session_registry(Session,
                fun(_) -> NewRegistry end),
            Result;
        {error, not_found} ->
            %% No registry exists; create one, apply the op
            EmptyRegistry = beam_agent_tool_registry:new_registry(),
            {Result, NewRegistry} = Fun(EmptyRegistry),
            beam_agent_tool_registry:register_session_registry(Session, NewRegistry),
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
    ok = beam_agent_tool_registry:unregister_session_registry(Session),
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
    beam_agent_core:session_identity(Session).

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

-spec universal_prompt_async(pid(), binary(), map()) -> {ok, #{source := universal, _ => _}} | {error, _}.
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

-spec universal_shell_command(pid(), binary(), map()) ->
    {ok, #{source := universal, _ => _}} | {error, {port_exit, _} | {port_failed, _} | {timeout, infinity | non_neg_integer()}}.
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
