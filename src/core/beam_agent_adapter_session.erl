-module(beam_agent_adapter_session).
-moduledoc """
Sub-behaviour for session-based agentic coder backends.

Backends that manage persistent sessions via the session engine
(`beam_agent_session_engine`) implement this sub-behaviour in addition to
`beam_agent_adapter`. This covers all agentic coder backends: Claude, Codex,
Gemini, OpenCode, Copilot, and future additions (Cursor, Aider, Windsurf).

## Required vs Optional Callbacks

5 of 11 callbacks are **required** — they form the minimal session
lifecycle every backend must support:

| Callback            | Purpose                          |
|---------------------|----------------------------------|
| `start_link/1`      | Launch a session process         |
| `send_query/4`      | Submit a prompt to the backend   |
| `receive_message/3` | Collect the next response chunk  |
| `health/1`          | Report session readiness         |
| `stop/1`            | Tear down the session            |

6 callbacks are **optional** — they cover capabilities that not every
backend exposes natively:

| Callback                   | Capability              | Example backends  |
|----------------------------|-------------------------|-------------------|
| `send_control/3`           | Control protocol        | Claude            |
| `interrupt/1`              | Cancel in-flight query  | Claude, OpenCode  |
| `handle_control_request/2` | Inbound control request | Claude            |
| `session_info/1`           | Session metadata        | Claude, Copilot   |
| `set_model/2`              | Runtime model switch    | Claude, OpenCode  |
| `set_permission_mode/2`    | Permission mode change  | Claude            |

This split follows the Interface Segregation Principle: backends are
not forced to stub out capabilities they lack. The session engine
checks `erlang:function_exported/3` before dispatching optional
callbacks and returns `{error, not_supported}` when absent.

Formerly `beam_agent_behaviour` — renamed during the Phase 0
sub-behaviour contract refactor.

See also: `beam_agent_adapter`, `beam_agent_session_handler`.
""".

%% Required callbacks — every adapter must implement these.

-callback start_link(Opts :: beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.

-callback send_query(Pid :: pid(), Prompt :: binary(),
                     Params :: beam_agent_core:query_opts(),
                     Timeout :: timeout()) ->
    {ok, reference()} | {error, term()}.

-callback receive_message(Pid :: pid(), Ref :: reference(),
                          Timeout :: timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.

-callback health(Pid :: pid()) ->
    ready | connecting | initializing | active_query | error.

-callback stop(Pid :: pid()) -> ok.

%% Optional callbacks — adapters with control protocols implement these.

-callback send_control(Pid :: pid(), Method :: binary(),
                       Params :: map()) ->
    {ok, term()} | {error, term()}.

-callback interrupt(Pid :: pid()) -> ok | {error, term()}.

-doc """
Handle an inbound control request from the CLI.

The CLI sends control_request messages (e.g., can_use_tool,
hook_callback, mcp_message) that require a control_response.

Return values follow the TS SDK PermissionResult pattern:
  `{allow, UpdatedInput}` — approve, optionally modifying tool input
  `{deny, Reason}` — deny with a reason message
  `{allow, UpdatedInput, RuleUpdate}` — approve with rule modification

The default in claude_agent_session auto-approves all requests.
""".
-callback handle_control_request(Subtype :: binary(), Request :: map()) ->
    beam_agent_core:permission_result().

-doc "Query session capabilities and initialization data.

Returns a map containing information from the system init message
and the initialize control response (available tools, model,
MCP servers, account info, etc.).
".
-callback session_info(Pid :: pid()) ->
    {ok, map()} | {error, term()}.

-doc "Change the model at runtime during a session.".
-callback set_model(Pid :: pid(), Model :: binary()) ->
    {ok, term()} | {error, term()}.

-doc "Change the permission mode at runtime.".
-callback set_permission_mode(Pid :: pid(), Mode :: binary()) ->
    {ok, term()} | {error, term()}.

-optional_callbacks([
    send_control/3,
    interrupt/1,
    handle_control_request/2,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).
