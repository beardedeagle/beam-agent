-module(beam_agent_control).
-moduledoc """
Control plane for session configuration, permissions, tasks, and feedback.

This module is the public API for the BeamAgent control layer. It manages
per-session configuration state, permission and approval workflows, task
lifecycle tracking, user feedback collection, and pending request/response
handling for turn-based agent interactions.

All state is ETS-backed, keyed by session ID, and persists for the node
lifetime or until explicitly cleared. The control layer works identically
across all five backends (Claude, Codex, Gemini, OpenCode, Copilot).

## Getting Started

```erlang
%% 1. Ensure ETS tables exist (idempotent, called automatically by most functions)
beam_agent_control:ensure_tables(),

%% 2. Configure session settings
beam_agent_control:set_permission_mode(SessionId, <<"acceptEdits">>),
beam_agent_control:set_max_thinking_tokens(SessionId, 8192),

%% 3. Dispatch a named control method
{ok, _} = beam_agent_control:dispatch(SessionId, <<"setModel">>,
    #{<<"model">> => <<"claude-sonnet-4-6">>}),

%% 4. Track background tasks
beam_agent_control:register_task(SessionId, TaskId, WorkerPid),
beam_agent_control:stop_task(SessionId, TaskId).
```

## Key Concepts

  - Session Config: An ETS-backed key-value store scoped to a session ID.
    Arbitrary atom keys map to arbitrary term values. Convenience accessors
    exist for common keys (permission_mode, max_thinking_tokens).

  - Permission Modes: Control how the agent handles tool execution approvals.
    Modes are backend-agnostic strings or atoms stored in session config.

  - Task Registration: Long-running background tasks can be registered with
    a session so that they can be listed, monitored, and stopped via the
    control dispatch protocol.

  - Callback Broker: Sessions can register callback functions for permission
    handling, approval decisions, and user input prompts. The broker invokes
    these callbacks safely (catching exceptions) and falls back to configured
    defaults when no handler is registered.

  - Pending Requests: Turn-based interaction protocol where the agent stores
    a pending request (e.g., asking for user input) and the consumer resolves
    it later with a response.

## Architecture

```
beam_agent_control (public API)
        |
        v
beam_agent_control_core (ETS state, dispatch logic, callback broker)
        |
        v
  ETS tables: config, tasks, feedback, callbacks, pending
```

## Core concepts

The control plane lets you manage a session without sending queries.
You can change settings (like permission mode or thinking token budget),
register callbacks for approval decisions and user input prompts,
submit feedback, and track background tasks.

Approval callbacks are functions the SDK calls when the agent wants to
do something that needs permission (like editing a file). User input
callbacks are called when the agent needs information from the user
mid-conversation.

Pending requests represent a turn-based interaction: the agent stores
a question, and your code resolves it later with an answer. This is
how interactive approval workflows work under the hood.

## Architecture deep dive

All control state is ETS-backed via beam_agent_control_core, keyed by
session ID. Five separate ETS tables back config, tasks, feedback,
callbacks, and pending requests. State is session-scoped with no
cross-session sharing.

The dispatch/3 function routes named control methods (e.g., setModel,
setPermissionMode) to the appropriate state mutation. The callback
broker invokes registered functions safely via try/catch and falls
back to configured defaults when no handler is registered.

Control operations are independent of the transport layer -- they
modify ETS state that the session engine reads on its next tick.

## See Also

  - `beam_agent` -- Main SDK entry point
  - `beam_agent_runtime` -- Provider and agent state management
  - `beam_agent_catalog` -- Tool, skill, and agent catalog accessors
  - `beam_agent_control_core` -- Core implementation (internal)
""".

-export([
    ensure_tables/0,
    clear/0,
    dispatch/3,
    get_config/2,
    set_config/3,
    get_all_config/1,
    clear_config/1,
    set_permission_mode/2,
    get_permission_mode/1,
    set_max_thinking_tokens/2,
    get_max_thinking_tokens/1,
    register_task/3,
    unregister_task/2,
    stop_task/2,
    list_tasks/1,
    submit_feedback/2,
    get_feedback/1,
    clear_feedback/1,
    register_session_callbacks/2,
    clear_session_callbacks/1,
    request_permission/4,
    request_approval/4,
    request_user_input/3,
    store_pending_request/3,
    resolve_pending_request/3,
    get_pending_response/2,
    list_pending_requests/1
]).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure all control ETS tables exist.

Creates the config, tasks, feedback, callbacks, and pending tables
if they do not already exist. This function is idempotent and is
called automatically by most other functions in this module.
""".
-spec ensure_tables() -> ok.
ensure_tables() -> beam_agent_control_core:ensure_tables().

-doc """
Clear all control state across every session.

Deletes all objects from every control ETS table. Use this for
test cleanup or node-wide reset. Individual session cleanup should
use clear_config/1, clear_feedback/1, and clear_session_callbacks/1
instead.
""".
-spec clear() -> ok.
clear() -> beam_agent_control_core:clear().

%%--------------------------------------------------------------------
%% Control Dispatch
%%--------------------------------------------------------------------

-doc """
Dispatch a named control method to the appropriate handler.

Routes well-known method names to their corresponding functions and
returns the result. Unknown methods produce an error tuple.

Supported methods:

  - <<"setModel">> -- Set the model for the session.
    Requires a <<"model">> key in Params.

  - <<"setPermissionMode">> -- Set the permission mode.
    Requires a <<"permissionMode">> key in Params.

  - <<"setMaxThinkingTokens">> -- Set the thinking token budget.
    Requires a <<"maxThinkingTokens">> key (positive integer) in Params.

  - <<"stopTask">> -- Stop a running background task.
    Requires a <<"taskId">> key in Params.

Examples:

```erlang
{ok, #{model := <<"claude-sonnet-4-6">>}} =
    beam_agent_control:dispatch(SessionId, <<"setModel">>,
        #{<<"model">> => <<"claude-sonnet-4-6">>}),

{ok, #{permission_mode := <<"acceptEdits">>}} =
    beam_agent_control:dispatch(SessionId, <<"setPermissionMode">>,
        #{<<"permissionMode">> => <<"acceptEdits">>}),

{error, {unknown_method, <<"noSuchMethod">>}} =
    beam_agent_control:dispatch(SessionId, <<"noSuchMethod">>, #{}).
```
""".
-spec dispatch(binary(), binary(), map()) ->
    {ok, #{model => term(),
           permission_mode => binary() | atom(),
           max_thinking_tokens => pos_integer()}}
  | {error, not_found
           | {invalid_param, max_thinking_tokens}
           | {missing_param, max_thinking_tokens | model | permission_mode | task_id}
           | {unknown_method, binary()}}.
dispatch(SessionId, Method, Params) -> beam_agent_control_core:dispatch(SessionId, Method, Params).

%%--------------------------------------------------------------------
%% Session Config
%%--------------------------------------------------------------------

-doc """
Get a configuration value for a session.

Looks up a single key from the session's config store. Returns
{error, not_set} when the key has not been written.
""".
-spec get_config(binary(), atom()) -> {ok, term()} | {error, not_set}.
get_config(SessionId, Key) -> beam_agent_control_core:get_config(SessionId, Key).

-doc """
Set a configuration value for a session.

Stores an arbitrary term under the given atom key, scoped to the
session ID. Overwrites any previous value for the same key.
""".
-spec set_config(binary(), atom(), term()) -> ok.
set_config(SessionId, Key, Value) -> beam_agent_control_core:set_config(SessionId, Key, Value).

-doc """
Get all configuration for a session as a map.

Returns every key-value pair stored for the given session ID.
The result is always {ok, Map} -- an empty map when nothing is set.
""".
-spec get_all_config(binary()) -> {ok, map()}.
get_all_config(SessionId) -> beam_agent_control_core:get_all_config(SessionId).

-doc """
Clear all configuration for a session.

Removes every key-value pair associated with the given session ID
from the config table.
""".
-spec clear_config(binary()) -> ok.
clear_config(SessionId) -> beam_agent_control_core:clear_config(SessionId).

%%--------------------------------------------------------------------
%% Permission Mode
%%--------------------------------------------------------------------

-doc """
Set the permission mode for a session.

The permission mode controls how the agent handles tool execution
approvals. Common values include <<"acceptEdits">>, <<"auto">>,
and <<"manual">>. The exact interpretation depends on the backend.

Example:

```erlang
ok = beam_agent_control:set_permission_mode(SessionId, <<"acceptEdits">>).
```
""".
-spec set_permission_mode(binary(), binary() | atom()) -> ok.
set_permission_mode(SessionId, Mode) -> beam_agent_control_core:set_permission_mode(SessionId, Mode).

-doc """
Get the permission mode for a session.

Returns {error, not_set} when no mode has been configured.
""".
-spec get_permission_mode(binary()) ->
    {ok, binary() | atom()} | {error, not_set}.
get_permission_mode(SessionId) -> beam_agent_control_core:get_permission_mode(SessionId).

%%--------------------------------------------------------------------
%% Thinking Tokens
%%--------------------------------------------------------------------

-doc """
Set the maximum thinking token budget for a session.

Tokens must be a positive integer. This value is used by backends
that support extended thinking (e.g., Claude) to cap the number of
tokens the model may use for internal reasoning.
""".
-spec set_max_thinking_tokens(binary(), pos_integer()) -> ok.
set_max_thinking_tokens(SessionId, Tokens) ->
    beam_agent_control_core:set_max_thinking_tokens(SessionId, Tokens).

-doc """
Get the maximum thinking token budget for a session.

Returns {error, not_set} when no budget has been configured.
""".
-spec get_max_thinking_tokens(binary()) ->
    {ok, pos_integer()} | {error, not_set}.
get_max_thinking_tokens(SessionId) -> beam_agent_control_core:get_max_thinking_tokens(SessionId).

%%--------------------------------------------------------------------
%% Task Tracking
%%--------------------------------------------------------------------

-doc """
Register an active task for a session.

Associates a task ID and owning process with the session. The task
is initially marked as running. Use stop_task/2 to signal the task
to stop, and unregister_task/2 to remove it after completion.

Example:

```erlang
TaskId = <<"task-abc-123">>,
ok = beam_agent_control:register_task(SessionId, TaskId, self()),
{ok, Tasks} = beam_agent_control:list_tasks(SessionId),
[#{task_id := <<"task-abc-123">>, status := running}] = Tasks.
```
""".
-spec register_task(binary(), binary(), pid()) -> ok.
register_task(SessionId, TaskId, Pid) -> beam_agent_control_core:register_task(SessionId, TaskId, Pid).

-doc """
Unregister a task, removing it from the session's task list.

Use this after a task has completed or been cleaned up. The task
entry is deleted entirely from the tracking table.
""".
-spec unregister_task(binary(), binary()) -> ok.
unregister_task(SessionId, TaskId) -> beam_agent_control_core:unregister_task(SessionId, TaskId).

-doc """
Stop a running task by sending an interrupt to its process.

Attempts a gen_statem interrupt call first, falling back to
exit(Pid, shutdown) if the call fails. Returns ok if the task was
found and signaled, or {error, not_found} if no such task exists.
Already-stopped tasks return ok without sending a signal.
""".
-spec stop_task(binary(), binary()) -> ok | {error, not_found}.
stop_task(SessionId, TaskId) -> beam_agent_control_core:stop_task(SessionId, TaskId).

-doc """
List all tasks registered for a session.

Returns a list of task metadata maps, each containing task_id,
session_id, pid, started_at (millisecond timestamp), and status
(running or stopped).
""".
-spec list_tasks(binary()) -> {ok, [beam_agent_control_core:task_meta()]}.
list_tasks(SessionId) -> beam_agent_control_core:list_tasks(SessionId).

%%--------------------------------------------------------------------
%% Feedback
%%--------------------------------------------------------------------

-doc """
Submit feedback for a session.

Feedback entries are accumulated in submission order. Each entry is
augmented with a submitted_at timestamp, session_id, and sequence
number. A feedback_submitted event is published on the session's
event bus.
""".
-spec submit_feedback(binary(), map()) -> ok.
submit_feedback(SessionId, Feedback) -> beam_agent_control_core:submit_feedback(SessionId, Feedback).

-doc """
Get all feedback entries for a session, in submission order.

Returns a list of feedback maps sorted by sequence number.
""".
-spec get_feedback(binary()) -> {ok, [map()]}.
get_feedback(SessionId) -> beam_agent_control_core:get_feedback(SessionId).

-doc """
Clear all feedback entries for a session.

Removes every feedback entry stored for SessionId. Subsequent calls
to get_feedback/1 will return an empty list.

Parameters:

  - SessionId -- binary session identifier

Returns ok.
""".
-spec clear_feedback(binary()) -> ok.
clear_feedback(SessionId) -> beam_agent_control_core:clear_feedback(SessionId).

%%--------------------------------------------------------------------
%% Session Callback Broker
%%--------------------------------------------------------------------

-doc """
Register callback handlers for a session.

The Opts map may contain:

  - permission_handler -- A fun(Method, Params, Context) returning
    a permission_result() tuple.

  - permission_default -- The atom allow or deny, used when a handler
    crashes or returns an unrecognized value. Defaults to deny.

  - approval_handler -- A fun(Method, Params, Context) returning
    accept, accept_for_session, decline, or cancel.

  - user_input_handler -- A fun(Request, Context) returning
    {ok, Response} or any term (wrapped in {ok, ...}).

Undefined values are filtered out. Passing an empty map clears
the session's callbacks.
""".
-spec register_session_callbacks(binary(), map()) -> ok.
register_session_callbacks(SessionId, Opts) ->
    beam_agent_control_core:register_session_callbacks(SessionId, Opts).

-doc """
Clear all callback handlers for a session.

Removes every registered callback handler (permission_handler,
approval_handler, user_input_handler, etc.) stored for SessionId.
After this call the session operates as if no callbacks were ever
registered; the permission_default reverts to deny.

Parameters:

  - SessionId -- binary session identifier

Returns ok.
""".
-spec clear_session_callbacks(binary()) -> ok.
clear_session_callbacks(SessionId) -> beam_agent_control_core:clear_session_callbacks(SessionId).

-doc """
Request permission through the session's callback broker.

Invokes the registered permission_handler (or falls back to approval_handler
adapted to permission semantics, or the permission_default). The handler is
called safely -- exceptions are caught and the default is returned.

Returns a permission_result() tuple:
  - {allow, Params} -- permission granted
  - {allow, Params, OverrideDefault} -- granted, with updated session default
  - {deny, Reason} -- permission denied
  - {deny, Reason, Cancelled} -- denied, with cancellation flag

Example:

```erlang
ok = beam_agent_control:register_session_callbacks(SessionId, #{
    permission_handler => fun(_Method, Params, _Ctx) -> {allow, Params} end
}),
{allow, _} = beam_agent_control:request_permission(
    SessionId, <<"file_write">>, #{path => <<"/tmp/out">>}, #{}).
```
""".
-spec request_permission(binary(), binary(), map(), map()) ->
    beam_agent_core:permission_result().
request_permission(SessionId, Method, Params, Context) ->
    beam_agent_control_core:request_permission(SessionId, Method, Params, Context).

-doc """
Request an approval decision through the session's callback broker.

Invokes the registered approval_handler (or adapts the permission_handler
to approval semantics). Returns one of: accept, accept_for_session,
decline, or cancel.
""".
-spec request_approval(binary(), binary(), map(), map()) ->
    accept | accept_for_session | decline | cancel.
request_approval(SessionId, Method, Params, Context) ->
    beam_agent_control_core:request_approval(SessionId, Method, Params, Context).

-doc """
Request user input through the session's callback broker.

Stores a pending request, then invokes the registered user_input_handler
if one exists. If the handler responds, the pending request is resolved
immediately. If no handler is registered or the handler fails, the request
remains pending for external resolution via resolve_pending_request/3.

Returns {ok, Response} when the handler responds, or {ok, PendingInfo}
when the request is awaiting external resolution.

Example:

```erlang
ok = beam_agent_control:register_session_callbacks(SessionId, #{
    user_input_handler => fun(Req, _Ctx) ->
        {ok, #{answer => maps:get(prompt, Req, <<"default">>)}}
    end
}),
{ok, #{answer := _}} = beam_agent_control:request_user_input(
    SessionId, #{prompt => <<"Continue?">>}, #{}).
```
""".
-spec request_user_input(binary(), map(), map()) ->
    {ok, term()}.
request_user_input(SessionId, Request, Context) ->
    beam_agent_control_core:request_user_input(SessionId, Request, Context).

%%--------------------------------------------------------------------
%% Turn Response (Pending Request/Response)
%%--------------------------------------------------------------------

-doc """
Store a pending request from the agent.

Called when the agent asks for user input or needs a response before
it can continue. The request is normalized and stored in the pending
table. A pending_request_stored event is published on the session's
event bus.
""".
-spec store_pending_request(binary(), binary(), map()) -> ok.
store_pending_request(SessionId, RequestId, Request) ->
    beam_agent_control_core:store_pending_request(SessionId, RequestId, Request).

-doc """
Resolve a pending request with a response.

Marks the pending request as resolved and publishes a
pending_request_resolved event. Returns {error, not_found} if no
such request exists, or {error, already_resolved} if it was
already resolved.
""".
-spec resolve_pending_request(binary(), binary(), map()) ->
    ok | {error, not_found | already_resolved}.
resolve_pending_request(SessionId, RequestId, Response) ->
    beam_agent_control_core:resolve_pending_request(SessionId, RequestId, Response).

-doc """
Get the response for a pending request.

Returns {ok, ResponseMap} if resolved, {error, pending} if still
awaiting a response, or {error, not_found} if no such request exists.
""".
-spec get_pending_response(binary(), binary()) ->
    {ok, map()} | {error, pending | not_found}.
get_pending_response(SessionId, RequestId) ->
    beam_agent_control_core:get_pending_response(SessionId, RequestId).

-doc """
List all pending requests for a session.

Returns requests sorted by creation time (oldest first).
Each entry is a pending_request() map with request_id, session_id,
request, status, created_at, and optionally response and resolved_at.
""".
-spec list_pending_requests(binary()) -> {ok, [beam_agent_control_core:pending_request()]}.
list_pending_requests(SessionId) -> beam_agent_control_core:list_pending_requests(SessionId).
