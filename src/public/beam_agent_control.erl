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

Operations backed entirely by shared control, collaboration, or session-store
state accept either a live session pid or a persisted session id binary.

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
    control dispatch protocol. Each task registration also creates a linked
    canonical run so task history survives after the live control entry is
    removed.

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
submit feedback, and track background tasks. Task registrations are
also mirrored into beam_agent_runs so the control table can stay
ephemeral without losing history.

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
    list_pending_requests/1,
    %% Turn steering and interrupts
    turn_steer/4,
    turn_steer/5,
    turn_interrupt/3,
    %% Realtime collaboration
    thread_realtime_start/2,
    thread_realtime_append_audio/3,
    thread_realtime_append_text/3,
    thread_realtime_stop/2,
    %% Collaboration and experimental features
    clear_collaboration/0,
    start_realtime/2,
    append_realtime_text/3,
    append_realtime_audio/3,
    stop_realtime/2,
    collaboration_modes/1,
    experimental_features/2,
    start_review/2,
    review_start/2,
    collaboration_mode_list/1,
    experimental_feature_list/1,
    experimental_feature_list/2,
    %% Server management
    server_health/1,
    list_server_sessions/1,
    get_server_session/2,
    delete_server_session/2,
    list_server_agents/1
]).

-dialyzer({no_underspecs, [turn_steer/4, turn_steer/5, turn_interrupt/3,
    experimental_feature_list/1, experimental_feature_list/2, server_health/1,
    delete_server_session/2, list_server_agents/1,
    start_review/2, collaboration_modes/1, start_realtime/2,
    append_realtime_text/3, append_realtime_audio/3, stop_realtime/2,
    record_thread_event/4, event_content/2, ensure_thread/3,
    request_id/2, value/3, normalize_participants/2, normalize_participant/2,
    normalize_review_items/3, normalize_review_item/3,
    append_output_event/2, stage_event/3, review_metrics/4,
    increment_input_summary/2]}).

-define(TABLE, beam_agent_runtime).

-type review_session() :: #{
    review_id := binary(),
    session_id := binary(),
    thread_id := binary(),
    backend => term(),
    mode := term(),
    source := term(),
    target := term(),
    stage := term(),
    status := active,
    participants := [map()],
    comments := [map()],
    issues := [map()],
    resolutions := [map()],
    stage_history := [map()],
    review_metrics := map(),
    created_at := integer(),
    updated_at := integer(),
    params := map()
}.
-type audio_meta() :: #{
    mime := term(),
    path := term(),
    size := term()
}.
-type realtime_session() :: #{
    realtime_id := binary(),
    session_id := binary(),
    thread_id := binary(),
    backend => term(),
    transport := term(),
    mode := term(),
    status := active | stopped,
    source := universal,
    started_at := integer(),
    params := map(),
    transport_metadata := map(),
    inputs := [map()],
    event_count := non_neg_integer(),
    output_events := [map()],
    input_summary := map(),
    voice_enabled := boolean(),
    last_text => binary(),
    last_audio => audio_meta(),
    updated_at => integer(),
    stopped_at => integer()
}.

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

Each registered task also creates a linked run in beam_agent_runs.
list_tasks/1 exposes that linkage through an optional run_id field.

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
Already-stopped tasks return ok without sending a signal. Stopping a
task also cancels its linked run in beam_agent_runs.
""".
-spec stop_task(binary(), binary()) -> ok | {error, not_found}.
stop_task(SessionId, TaskId) -> beam_agent_control_core:stop_task(SessionId, TaskId).

-doc """
List all tasks registered for a session.

Returns a list of task metadata maps, each containing task_id,
session_id, pid, started_at (millisecond timestamp), status
(running or stopped), and an optional run_id. Stopped tasks also
include stopped_at.
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
Request and response payloads are redacted for display-safe reads.
""".
-spec list_pending_requests(binary()) -> {ok, [beam_agent_control_core:pending_request()]}.
list_pending_requests(SessionId) -> beam_agent_control_core:list_pending_requests(SessionId).

%%--------------------------------------------------------------------
%% Turn Steering and Interrupts
%%--------------------------------------------------------------------

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
    {ok, map()} | {error, term()}.
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
    {ok, map()} | {error, term()}.
turn_steer(Session, ThreadId, TurnId, Input, Opts) ->
    beam_agent_core:native_or(Session, turn_steer, [ThreadId, TurnId, Input, Opts], fun() ->
        %% Universal: record steer intent as a thread message
        SessionId = beam_agent_core:session_identity(Session),
        SteerMsg = #{type => system,
                     content => <<"steer">>,
                     raw => #{role => <<"system">>, turn_id => TurnId,
                              input => Input, opts => Opts}},
        beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
            SteerMsg),
        {ok, beam_agent_core:with_universal_source(Session, #{
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
-spec turn_interrupt(pid() | binary(), binary(), binary()) -> {ok, map()} | {error, term()}.
turn_interrupt(Session, ThreadId, TurnId) ->
    beam_agent_core:native_or(Session, turn_interrupt, [ThreadId, TurnId], fun() ->
        universal_turn_interrupt(Session, ThreadId, TurnId)
    end).

%%--------------------------------------------------------------------
%% Realtime Collaboration
%%--------------------------------------------------------------------

-doc """
Start a realtime collaboration thread for voice or audio streaming.

Opens a persistent bidirectional channel between the caller and the
backend, suitable for streaming audio or text in real time. Use this
when building interactive voice assistants or live pair-programming
sessions that require continuous input rather than request/response
turns.

Tries the backend-native implementation first; falls back to the
universal layer (start_realtime/2 below) if the
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
  {ok, #{thread_id := Tid}} = beam_agent_control:thread_realtime_start(Session, Params).
""".
-spec thread_realtime_start(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
thread_realtime_start(Session, Params) ->
    beam_agent_core:native_or(Session, thread_realtime_start, [Params], fun() ->
        start_realtime(
            beam_agent_core:session_identity(Session),
            beam_agent_core:with_session_backend(Session, Params))
    end).

-doc """
Append audio data to an active realtime thread.

Sends an audio chunk to a previously started realtime collaboration
channel. Call this repeatedly to stream audio frames into the session.
The backend processes each chunk and may emit intermediate responses
depending on the realtime mode.

Tries the backend-native implementation first; falls back to the
universal layer (append_realtime_audio/3 below)
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
-spec thread_realtime_append_audio(pid() | binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_audio(Session, ThreadId, Params) ->
    beam_agent_core:native_or(Session, thread_realtime_append_audio, [ThreadId, Params], fun() ->
        append_realtime_audio(
            beam_agent_core:session_identity(Session), ThreadId, Params)
    end).

-doc """
Append text data to an active realtime thread.

Injects a text message into a previously started realtime collaboration
channel. Use this to send typed input alongside or instead of audio in
a realtime session, for example to provide corrections or commands
while voice streaming is active.

Tries the backend-native implementation first; falls back to the
universal layer (append_realtime_text/3 below)
if the backend does not provide one.

Session is the pid of a running beam_agent session. ThreadId is the
binary identifier returned by thread_realtime_start/2. Params is a
map containing the text payload:

  text - binary, the text content to inject into the realtime stream.

Returns {ok, Map} on success, or {error, Reason} if the thread is
not active or the payload is invalid.
""".
-spec thread_realtime_append_text(pid() | binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_text(Session, ThreadId, Params) ->
    beam_agent_core:native_or(Session, thread_realtime_append_text, [ThreadId, Params], fun() ->
        append_realtime_text(
            beam_agent_core:session_identity(Session), ThreadId, Params)
    end).

-doc """
Stop and tear down an active realtime collaboration thread.

Closes the bidirectional channel identified by ThreadId, releasing
any backend resources associated with it. After this call the
ThreadId is no longer valid and further append calls will return
an error.

Tries the backend-native implementation first; falls back to the
universal layer (stop_realtime/2 below) if the
backend does not provide one.

Session is the pid of a running beam_agent session. ThreadId is the
binary identifier returned by thread_realtime_start/2.

Returns {ok, Map} with the final channel status on success, or
{error, Reason} if the thread was already stopped or never existed.
""".
-spec thread_realtime_stop(pid() | binary(), binary()) -> {ok, map()} | {error, term()}.
thread_realtime_stop(Session, ThreadId) ->
    beam_agent_core:native_or(Session, thread_realtime_stop, [ThreadId], fun() ->
        stop_realtime(
            beam_agent_core:session_identity(Session), ThreadId)
    end).

%%--------------------------------------------------------------------
%% Collaboration and Experimental Features
%%--------------------------------------------------------------------

-doc """
Start a code review collaboration session.

Opens a review context where the backend analyzes code changes and
provides structured feedback. Use this when you want the agent to
review a diff, a set of files, or a pull request and return comments,
suggestions, and severity ratings.

Tries the backend-native implementation first; falls back to the
universal layer (start_review/2 below) if the
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
  {ok, #{review_id := Rid}} = beam_agent_control:review_start(Session, Params).
""".
-spec review_start(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
review_start(Session, Params) ->
    beam_agent_core:native_or(Session, review_start, [Params], fun() ->
        start_review(
            beam_agent_core:session_identity(Session),
            beam_agent_core:with_session_backend(Session, Params))
    end).

-doc """
List the collaboration modes supported by the session's backend.

Returns a map describing each mode the backend can operate in for
collaborative workflows. Common modes include review (structured code
review) and realtime (streaming audio/text). Use this to discover
what collaboration features are available before starting a session.

Tries the backend-native implementation first; falls back to the
universal layer (collaboration_modes/1 below)
if the backend does not provide one.

Session is the pid of a running beam_agent session.

Returns {ok, Map} keyed by mode name, where each value describes the
mode's capabilities, or {error, Reason} on failure.
""".
-spec collaboration_mode_list(pid() | binary()) -> {ok, map()} | {error, term()}.
collaboration_mode_list(Session) ->
    beam_agent_core:native_or(Session, collaboration_mode_list, [], fun() ->
        collaboration_modes(
            beam_agent_core:session_identity(Session))
    end).

-doc """
List experimental or beta features available for a session.

Convenience wrapper that calls experimental_feature_list/2 with an
empty options map. See experimental_feature_list/2 for full details.

Session is the pid of a running beam_agent session.

Returns {ok, List} of feature maps, or {error, Reason} on failure.
""".
-spec experimental_feature_list(pid() | binary()) -> {ok, [map()]} | {error, term()}.
experimental_feature_list(Session) ->
    experimental_feature_list(Session, #{}).

-doc """
List experimental or beta features available for a session, with
optional filters.

Queries the backend for features that are experimental, in preview,
or otherwise not yet part of the stable API surface. Use this to
discover and inspect opt-in capabilities before enabling them.

Tries the backend-native implementation first; falls back to the
universal layer (experimental_features/2 below)
if the backend does not provide one.

Session is the pid of a running beam_agent session. Opts is a map
of optional filters:

  category - binary, restrict results to a feature category.
  name     - binary, match features by name pattern.

Returns {ok, List} of feature maps on success. Each map contains
at minimum id, name, description, and enabled (boolean). Returns
{error, Reason} on failure.
""".
-spec experimental_feature_list(pid() | binary(), map()) -> {ok, [map()]} | {error, term()}.
experimental_feature_list(Session, Opts) ->
    beam_agent_core:native_or(Session, experimental_feature_list, [Opts], fun() ->
        experimental_features(
            beam_agent_core:session_identity(Session), Opts)
    end).

%%--------------------------------------------------------------------
%% Server Management
%%--------------------------------------------------------------------

-doc """
Check the health of the backend server.

Returns a status map with health indicators including the backend
name, session identifier, and uptime in milliseconds. The universal
fallback derives health from session_info/1. Returns
status => unknown when session info is unavailable.
""".
-spec server_health(pid() | binary()) -> {ok, map()} | {error, term()}.
server_health(Session) ->
    beam_agent_core:native_or(Session, server_health, [], fun() ->
        case beam_agent_core:session_info(Session) of
            {ok, Info} ->
                {ok, beam_agent_core:with_universal_source(Session, #{
                    status => healthy,
                    backend => maps:get(backend, Info, unknown),
                    session_id => maps:get(session_id, Info, undefined),
                    uptime_ms => erlang:system_time(millisecond)
                        - maps:get(started_at, Info, erlang:system_time(millisecond))})};
            {error, _} ->
                {ok, beam_agent_core:with_universal_source(Session, #{
                    status => unknown,
                    reason => <<"Session info unavailable">>})}
        end
    end).

-doc """
List all persisted sessions known to the backend server.

Queries the session store for every session associated with the current
backend. Each entry in the returned list is a map containing at minimum
a session_id key. Backends that support server-side session persistence
return richer metadata (creation time, model, message count).

The universal fallback delegates to beam_agent_session_store_core.
""".
-spec list_server_sessions(pid() | binary()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    beam_agent_core:native_or(Session, list_server_sessions, [], fun() ->
        case beam_agent_core:backend(Session) of
            {ok, Backend} ->
                beam_agent_session_store_core:list_sessions(#{adapter => Backend});
            {error, _} = Error ->
                Error
        end
    end).

-doc """
Retrieve a single persisted session by its identifier.

Returns the full session map for SessionId, including message history
when the backend supports it. Returns {error, not_found} if the
session does not exist in the store.
""".
-spec get_server_session(pid() | binary(), binary()) -> {ok, map()} | {error, term()}.
get_server_session(Session, SessionId) ->
    beam_agent_core:native_or(Session, get_server_session, [SessionId], fun() ->
        beam_agent_core:get_session(SessionId)
    end).

-doc """
Delete a persisted session from the backend server.

Removes the session identified by SessionId from the session store.
Returns a confirmation map with the session_id and deleted flag on
success. Does not affect the currently running in-memory session.
""".
-spec delete_server_session(pid() | binary(), binary()) -> {ok, map()} | {error, term()}.
delete_server_session(Session, SessionId) ->
    beam_agent_core:native_or(Session, delete_server_session, [SessionId], fun() ->
        ok = beam_agent_core:delete_session(SessionId),
        {ok, #{session_id => SessionId, deleted => true}}
    end).

-doc """
List all sub-agents registered on the backend server.

Returns the set of sub-agents the backend exposes. Sub-agents are
specialized assistants (e.g., a code reviewer or test writer) that the
primary agent can delegate to. The universal fallback queries the
in-memory agent registry.
""".
-spec list_server_agents(pid() | binary()) -> {ok, [map()]} | {error, term()}.
list_server_agents(Session) ->
    beam_agent_core:native_or(Session, list_server_agents, [], fun() ->
        beam_agent_core:list_agents(Session)
    end).

%%==== Collaboration ====

-doc "Ensure collaboration ETS tables exist.".
-spec ensure_collab_tables() -> ok.
ensure_collab_tables() ->
    beam_agent_runtime:app_ensure_tables().

-doc "Clear all universal collaboration state.".
-spec clear_collaboration() -> ok.
clear_collaboration() ->
    ensure_collab_tables(),
    beam_agent_ets:match_delete(?TABLE, {{review, '_'}, '_'}),
    beam_agent_ets:match_delete(?TABLE, {{realtime, '_'}, '_'}),
    ok.

-doc "Start a universal review session for the canonical API.".
-spec start_review(binary(), map()) -> {ok, review_session()}.
start_review(SessionId, Params)
  when is_binary(SessionId), is_map(Params) ->
    ensure_collab_tables(),
    ThreadId = ensure_thread(SessionId, Params, <<"review">>),
    ReviewId = request_id(Params, [review_id, <<"review_id">>]),
    Mode = value(Params, [mode, <<"mode">>], <<"review">>),
    Backend = value(Params, [backend, <<"backend">>], undefined),
    Source = value(Params, [source, <<"source">>], universal),
    Target = value(Params, [target, <<"target">>], <<"canonical">>),
    Stage = value(Params, [stage, <<"stage">>, review_stage, <<"review_stage">>], <<"requested">>),
    Now = now_ms(),
    Participants = normalize_participants(value(Params, [participants, <<"participants">>], []), Now),
    Comments = normalize_review_items(comment, value(Params, [comments, <<"comments">>], []), Now),
    Issues = normalize_review_items(issue, value(Params, [issues, <<"issues">>], []), Now),
    Resolutions = normalize_review_items(resolution,
        value(Params, [resolutions, <<"resolutions">>], []), Now),
    StageHistory = [stage_event(Stage, Source, Now)],
    Review = #{
        review_id => ReviewId,
        session_id => SessionId,
        thread_id => ThreadId,
        backend => Backend,
        mode => Mode,
        source => Source,
        target => Target,
        stage => Stage,
        status => active,
        participants => Participants,
        comments => Comments,
        issues => Issues,
        resolutions => Resolutions,
        stage_history => StageHistory,
        review_metrics => review_metrics(Participants, Comments, Issues, Resolutions),
        created_at => Now,
        updated_at => Now,
        params => Params
    },
    beam_agent_ets:insert(?TABLE, {{review, {SessionId, ReviewId}}, Review}),
    ok = record_thread_event(SessionId, ThreadId, <<"review_started">>, #{
        review_id => ReviewId,
        backend => Backend,
        mode => Mode,
        stage => Stage,
        review => review_projection(Review)
    }),
    {ok, Review}.

-doc "List canonical collaboration modes available through the universal layer.".
-spec collaboration_modes(binary()) ->
    {ok,
     #{session_id := binary(),
       source := universal,
       modes := [map(), ...]}}.
collaboration_modes(SessionId) when is_binary(SessionId) ->
    {ok, #{
        session_id => SessionId,
        source => universal,
        modes => [
            #{id => <<"solo">>,
              label => <<"Solo">>,
              source => universal,
              capabilities => [thread_management]},
            #{id => <<"review">>,
              label => <<"Review">>,
              source => universal,
              stages => [<<"requested">>, <<"active">>, <<"resolved">>],
              capabilities => [review_start, collaboration_mode_list]},
            #{id => <<"realtime">>,
              label => <<"Realtime">>,
              source => universal,
              transports => [universal, mediated],
              capabilities => [thread_realtime_start, thread_realtime_append_text,
                               thread_realtime_append_audio, thread_realtime_stop]}
        ]
    }}.

-doc "List universal experimental features visible through the canonical API.".
-spec experimental_features(binary(), map()) -> {ok, map()}.
experimental_features(SessionId, _Opts) when is_binary(SessionId) ->
    {ok, #{
        session_id => SessionId,
        source => universal,
        features => [
            #{id => <<"universal_review">>, status => enabled},
            #{id => <<"universal_realtime_text">>, status => enabled},
            #{id => <<"universal_realtime_audio_bridge">>, status => enabled}
        ]
    }}.

-doc "Start a universal realtime session for a thread.".
-spec start_realtime(binary(), map()) -> {ok, realtime_session()}.
start_realtime(SessionId, Params)
  when is_binary(SessionId), is_map(Params) ->
    ensure_collab_tables(),
    ThreadId = ensure_thread(SessionId, Params, <<"realtime">>),
    RealtimeId = request_id(Params, [realtime_id, <<"realtime_id">>]),
    Mode = value(Params, [mode, <<"mode">>], <<"text">>),
    Backend = value(Params, [backend, <<"backend">>], undefined),
    Transport = value(Params, [transport, <<"transport">>], universal),
    Now = now_ms(),
    TransportMetadata = transport_metadata(Params),
    Session = #{
        realtime_id => RealtimeId,
        session_id => SessionId,
        thread_id => ThreadId,
        backend => Backend,
        transport => Transport,
        mode => Mode,
        status => active,
        source => universal,
        started_at => Now,
        updated_at => Now,
        params => Params,
        transport_metadata => TransportMetadata,
        inputs => [],
        event_count => 1,
        input_summary => #{text_chunks => 0, audio_chunks => 0},
        voice_enabled => voice_enabled(Mode),
        output_events => [
            #{type => <<"realtime_started">>,
              timestamp => Now,
              transport => Transport,
              sequence => 1,
              metadata => TransportMetadata}
        ]
    },
    beam_agent_ets:insert(?TABLE, {{realtime, {SessionId, ThreadId}}, Session}),
    ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_started">>, #{
        realtime_id => RealtimeId,
        backend => Backend,
        transport => Transport,
        mode => Mode
    }),
    {ok, Session}.

-doc "Append canonical realtime text to a universal realtime thread.".
-spec append_realtime_text(binary(), binary(), map()) ->
    {ok, realtime_session()} | {error, not_found}.
append_realtime_text(SessionId, ThreadId, Params)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Params) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            Text = value(Params, [text, <<"text">>, content, <<"content">>], <<>>),
            Now = now_ms(),
            Input = #{
                type => text,
                payload => #{text => Text},
                sequence => next_sequence(Session),
                timestamp => Now
            },
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_text_appended">>, #{
                content => Text
            }),
            EventCount = next_event_count(Session),
            Updated = Session#{
                last_text => Text,
                updated_at => Now,
                inputs => append_item(maps:get(inputs, Session, []), Input),
                event_count => EventCount,
                input_summary => increment_input_summary(text, maps:get(input_summary, Session, #{})),
                output_events => append_output_event(Session, #{
                    type => <<"realtime_text_appended">>,
                    payload => #{text => Text},
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            beam_agent_ets:insert(?TABLE, {{realtime, {SessionId, ThreadId}}, Updated}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Append canonical realtime audio metadata to a universal realtime thread.".
-spec append_realtime_audio(binary(), binary(), map()) ->
    {ok, realtime_session()} | {error, not_found}.
append_realtime_audio(SessionId, ThreadId, Params)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Params) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            AudioMeta = #{
                mime => value(Params, [mime, <<"mime">>], undefined),
                path => value(Params, [path, <<"path">>], undefined),
                size => value(Params, [size, <<"size">>], undefined)
            },
            Now = now_ms(),
            Input = #{
                type => audio,
                payload => AudioMeta,
                sequence => next_sequence(Session),
                timestamp => Now
            },
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_audio_appended">>, #{
                audio => AudioMeta
            }),
            EventCount = next_event_count(Session),
            Updated = Session#{
                last_audio => AudioMeta,
                updated_at => Now,
                inputs => append_item(maps:get(inputs, Session, []), Input),
                event_count => EventCount,
                input_summary => increment_input_summary(audio, maps:get(input_summary, Session, #{})),
                output_events => append_output_event(Session, #{
                    type => <<"realtime_audio_appended">>,
                    payload => AudioMeta,
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            beam_agent_ets:insert(?TABLE, {{realtime, {SessionId, ThreadId}}, Updated}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Stop a universal realtime thread.".
-spec stop_realtime(binary(), binary()) ->
    {ok, realtime_session()} | {error, not_found}.
stop_realtime(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            Now = now_ms(),
            EventCount = next_event_count(Session),
            Updated = Session#{
                status => stopped,
                stopped_at => Now,
                updated_at => Now,
                event_count => EventCount,
                output_events => append_output_event(Session, #{
                    type => <<"realtime_stopped">>,
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            beam_agent_ets:insert(?TABLE, {{realtime, {SessionId, ThreadId}}, Updated}),
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_stopped">>, #{}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Collaboration Internal Helpers
%%--------------------------------------------------------------------

-spec ensure_thread(binary(), map(), binary()) -> binary().
ensure_thread(SessionId, Params, DefaultName) ->
    case value(Params, [thread_id, <<"thread_id">>, <<"threadId">>], undefined) of
        ThreadId when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
            ThreadId;
        _ ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} ->
                    ThreadId;
                {error, none} ->
                    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{
                        name => DefaultName
                    }),
                    maps:get(thread_id, Thread)
            end
    end.

-spec lookup_realtime(binary(), binary()) -> {ok, map()} | {error, not_found}.
lookup_realtime(SessionId, ThreadId) ->
    ensure_collab_tables(),
    case ets:lookup(?TABLE, {realtime, {SessionId, ThreadId}}) of
        [{_, Session}] ->
            {ok, Session};
        [] ->
            {error, not_found}
    end.

-spec record_thread_event(binary(), binary(), binary(), map()) -> ok.
record_thread_event(SessionId, ThreadId, Subtype, Extra) ->
    Message = #{
        type => system,
        content => event_content(Subtype, Extra),
        session_id => SessionId,
        thread_id => ThreadId,
        subtype => Subtype,
        system_info => maps:merge(Extra, #{source => universal}),
        timestamp => now_ms()
    },
    beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Message).

-spec event_content(binary(), map()) -> binary().
event_content(_Subtype, #{content := Content}) when is_binary(Content) ->
    Content;
event_content(Subtype, _Extra) ->
    Subtype.

-spec request_id(map(), [term()]) -> binary().
request_id(Params, Keys) ->
    case value(Params, Keys, undefined) of
        Existing when is_binary(Existing), byte_size(Existing) > 0 ->
            Existing;
        _ ->
            beam_agent_core:make_request_id()
    end.

-spec value(map(), [term()], term()) -> term().
value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            value(Map, Rest, Default)
    end;
value(_Map, [], Default) ->
    Default.

-spec normalize_items(term()) -> [map()].
normalize_items(Items) when is_list(Items) ->
    [normalize_item(Item) || Item <- Items];
normalize_items(_) ->
    [].

-spec normalize_participants(term(), integer()) -> [map()].
normalize_participants(Items, Now) ->
    [normalize_participant(Item, Now) || Item <- normalize_items(Items)].

-spec normalize_participant(map(), integer()) -> map().
normalize_participant(Item, Now) ->
    Item#{
        joined_at => maps:get(joined_at, Item, Now),
        presence => maps:get(presence, Item, online)
    }.

-spec normalize_review_items(atom(), term(), integer()) -> [map()].
normalize_review_items(Kind, Items, Now) ->
    [normalize_review_item(Kind, Item, Now) || Item <- normalize_items(Items)].

-spec normalize_review_item(atom(), map(), integer()) -> map().
normalize_review_item(Kind, Item, Now) ->
    Item#{
        kind => maps:get(kind, Item, Kind),
        created_at => maps:get(created_at, Item, Now)
    }.

-spec normalize_item(term()) -> map().
normalize_item(Item) when is_map(Item) ->
    Item;
normalize_item(Item) ->
    #{value => Item}.

review_projection(Review) ->
    maps:with([review_id, backend, source, target, stage, participants,
               stage_history, review_metrics], Review).

-spec append_item([map()], map()) -> [map()].
append_item(Items, Item) when is_list(Items), is_map(Item) ->
    Items ++ [Item].

-spec next_sequence(realtime_session()) -> pos_integer().
next_sequence(Session) ->
    length(maps:get(inputs, Session, [])) + 1.

-spec next_event_count(realtime_session()) -> pos_integer().
next_event_count(Session) ->
    maps:get(event_count, Session, length(maps:get(output_events, Session, []))) + 1.

-spec append_output_event(realtime_session(), map()) -> [map()].
append_output_event(Session, Event) ->
    append_item(maps:get(output_events, Session, []), Event).

-spec stage_event(term(), term(), integer()) -> map().
stage_event(Stage, Source, Timestamp) ->
    #{stage => Stage, source => Source, timestamp => Timestamp}.

-spec review_metrics([map()], [map()], [map()], [map()]) -> map().
review_metrics(Participants, Comments, Issues, Resolutions) ->
    #{
        participant_count => length(Participants),
        comment_count => length(Comments),
        issue_count => length(Issues),
        resolution_count => length(Resolutions)
    }.

-spec transport_metadata(map()) -> map().
transport_metadata(Params) ->
    maps:merge(
        maps:with([codec, sample_rate, sample_rate_hz, channels, language], Params),
        normalize_map(value(Params, [transport_metadata, <<"transport_metadata">>], #{}))).

-spec voice_enabled(term()) -> boolean().
voice_enabled(<<"voice">>) ->
    true;
voice_enabled(voice) ->
    true;
voice_enabled(_) ->
    false.

-spec increment_input_summary(text | audio, map()) -> map().
increment_input_summary(text, Summary) ->
    Summary#{
        text_chunks => maps:get(text_chunks, Summary, 0) + 1,
        audio_chunks => maps:get(audio_chunks, Summary, 0)
    };
increment_input_summary(audio, Summary) ->
    Summary#{
        text_chunks => maps:get(text_chunks, Summary, 0),
        audio_chunks => maps:get(audio_chunks, Summary, 0) + 1
    }.

-spec normalize_map(term()) -> map().
normalize_map(Map) when is_map(Map) ->
    Map;
normalize_map(_) ->
    #{}.

-spec now_ms() -> integer().
now_ms() ->
    erlang:system_time(millisecond).

%%--------------------------------------------------------------------
%% Internal Helpers
%%--------------------------------------------------------------------

-spec universal_turn_interrupt(pid() | binary(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
universal_turn_interrupt(SessionId, ThreadId, TurnId)
  when is_binary(SessionId) ->
    {ok, beam_agent_core:with_universal_source(SessionId, #{
        thread_id => ThreadId,
        turn_id => TurnId,
        status => interrupted
    })};
universal_turn_interrupt(Session, ThreadId, TurnId) ->
    case beam_agent_core:interrupt(Session) of
        ok ->
            {ok, beam_agent_core:with_universal_source(Session, #{
                thread_id => ThreadId,
                turn_id => TurnId,
                status => interrupted
            })};
        {error, _} = Error ->
            Error
    end.
