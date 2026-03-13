-module(beam_agent).
-moduledoc """
Lifecycle entry point for the BeamAgent SDK.

This module manages session lifecycle: starting, stopping, querying,
and event streaming. Domain-specific operations live in dedicated
public modules:

- beam_agent_account: login, logout, rate limits
- beam_agent_apps: app/project management
- beam_agent_capabilities: feature introspection
- beam_agent_catalog: tools, skills, plugins, agents, models
- beam_agent_checkpoint: checkpoint and rewind
- beam_agent_command: command execution, stdin, shell, async prompts
- beam_agent_config: session configuration read/write
- beam_agent_control: collaboration, review, realtime, server admin
- beam_agent_file: text search, file search, directory listing
- beam_agent_mcp: MCP server management
- beam_agent_provider: provider and agent selection, OAuth
- beam_agent_runtime: model, permissions, status, interrupts
- beam_agent_search: fuzzy file search
- beam_agent_session_store: session history and thread storage
- beam_agent_skills: skill listing and configuration
- beam_agent_threads: thread lifecycle and management

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Messages} = beam_agent:query(Session, <<"What is the BEAM?">>),
[io:format("~s~n", [maps:get(content, M, <<>>)]) || M <- Messages],
ok = beam_agent:stop(Session).
```
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
    beam_agent_core:native_or(Session, event_subscribe, [], fun() ->
        beam_agent_events:subscribe(beam_agent_core:session_identity(Session))
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
    beam_agent_core:native_or(Session, receive_event, [Ref, Timeout], fun() ->
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
    beam_agent_core:native_or(Session, event_unsubscribe, [Ref], fun() ->
        beam_agent_events:unsubscribe(beam_agent_core:session_identity(Session), Ref)
    end).

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
