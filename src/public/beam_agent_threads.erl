-module(beam_agent_threads).
-moduledoc """
Public API for conversation thread management.

This module provides logical conversation threading within sessions.
A thread groups related queries into a named conversation branch,
enabling parallel workstreams, forking, archiving, and rollback
within a single session.

Threads are scoped to a session -- each session can have multiple
threads, and each thread tracks its own query history. Messages
recorded against a thread are also stored in the parent session
for unified history (via beam_agent_session_store).

Most callers interact with threads through the main beam_agent
module. Use this module directly when you need fine-grained control
over thread lifecycle, forking, archiving, or rollback operations.

## Getting Started

```erlang
%% Start a new thread within a session:
{ok, Thread} = beam_agent_threads:start_thread(<<"sess_001">>, #{
    name => <<"feature-discussion">>
}),

%% List all threads for a session:
{ok, Threads} = beam_agent_threads:list_threads(<<"sess_001">>),

%% Fork a thread to explore an alternative approach:
{ok, Fork} = beam_agent_threads:fork_thread(
    <<"sess_001">>, maps:get(thread_id, Thread), #{
        name => <<"alternative-approach">>
    }
),

%% Roll back the last 3 messages in a thread:
{ok, _} = beam_agent_threads:rollback_thread(
    <<"sess_001">>, maps:get(thread_id, Thread), #{count => 3}
)
```

## Key Concepts

- Thread: a named conversation branch within a session, identified by a
  binary thread ID (e.g. <<"thread_a1b2c3d4">>). Each thread has its own
  message history, status (active, paused, completed, archived), and a
  visible message count for rollback support.

- Active thread: each session tracks at most one active thread. Starting
  or resuming a thread sets it as the active thread for that session.

- Forking: fork_thread/3 creates a new thread with a copy of the source
  thread's visible message history. The fork records its parent_thread_id
  for lineage tracking.

- Archiving: archive_thread/2 marks a thread as archived without deleting
  its data. unarchive_thread/2 restores it to active status.

- Rollback: rollback_thread/3 hides messages beyond a boundary without
  deleting them. The visible_message_count field controls which messages
  are visible when reading the thread.

## Architecture

This module is a thin public wrapper that delegates every call to
beam_agent_threads_core. The core module owns the ETS tables
(beam_agent_threads_core for thread metadata, beam_agent_active_threads
for active thread tracking) and all implementation logic.

Thread messages are stored in the session-level message store
(beam_agent_session_store_core) with a thread_id tag. This keeps
all messages queryable at both the session and thread level.

## Core concepts

Threads are named conversation branches within a session. Think of them
like tabs in a browser -- each thread has its own conversation history,
but they all live inside the same session.

You can start a thread with start_thread/2, switch to it with
resume_thread/2, and list all threads with list_threads/1. Forking a
thread creates a copy so you can explore a different approach without
losing the original conversation.

Archiving marks a thread as inactive without deleting its data.
Rollback hides recent messages so you can "undo" the last few exchanges.
These operations are non-destructive -- the data is still there, just
hidden from the active view.

## Architecture deep dive

Thread state is managed by beam_agent_threads_core using two ETS tables:
beam_agent_threads_core for thread metadata and beam_agent_active_threads
for tracking the single active thread per session.

Thread messages are stored in the session-level message store
(beam_agent_session_store_core) tagged with a thread_id, making them
queryable at both the session and thread level. Forking duplicates the
visible message history into a new thread entry.

Rollback uses the visible_message_count field to control which messages
appear when reading a thread. Compaction (if supported) summarizes
older messages to reduce context size while preserving key information.
All thread operations are session-scoped.

## See Also

- beam_agent_threads_core: implementation module with full internals
- beam_agent_session_store: session-level history store
- beam_agent: main SDK entry point (delegates to this module)
""".

-export([
    ensure_tables/0,
    clear/0,
    start_thread/2,
    fork_thread/3,
    resume_thread/2,
    list_threads/1,
    get_thread/2,
    read_thread/2,
    read_thread/3,
    delete_thread/2,
    archive_thread/2,
    unarchive_thread/2,
    rollback_thread/3,
    record_thread_message/3,
    get_thread_messages/2,
    thread_count/1,
    active_thread/1,
    set_active_thread/2,
    clear_active_thread/1
]).

%% Session-based thread operations (native-first routing via beam_agent_core)
-export([
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
    thread_unarchive/2,
    thread_rollback/3,
    thread_unsubscribe/2,
    thread_name_set/3,
    thread_metadata_update/3,
    thread_loaded_list/1,
    thread_loaded_list/2,
    thread_compact/2
]).

-dialyzer({no_underspecs, [
    universal_thread_unsubscribe/2,
    universal_thread_name_set/3,
    universal_thread_metadata_update/3,
    universal_thread_loaded_list/2,
    universal_thread_compact/2,
    include_thread/2,
    maybe_put_selector/3
]}).

-export_type([thread_meta/0, thread_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc """
Thread metadata map.

Contains the thread ID, parent session ID, name, custom metadata,
creation and update timestamps, message count, visible message count,
status (active, paused, completed, or archived), and optional fields
for archive state and parent thread lineage.
""".
-type thread_meta() :: beam_agent_threads_core:thread_meta().

-doc """
Options for starting a new thread.

Supported keys: name (binary), metadata (map), thread_id (binary,
auto-generated if omitted), parent_thread_id (binary).
""".
-type thread_opts() :: beam_agent_threads_core:thread_opts().

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the thread store ETS tables exist.

Creates the beam_agent_threads_core and beam_agent_active_threads
tables if they do not already exist. This function is idempotent
and safe to call from any process.
""".
-spec ensure_tables() -> ok.
ensure_tables() -> beam_agent_threads_core:ensure_tables().

-doc """
Clear all thread data from the store.

Deletes every entry from the threads and active-threads tables.
The tables themselves remain in place.
""".
-spec clear() -> ok.
clear() -> beam_agent_threads_core:clear().

%%--------------------------------------------------------------------
%% Thread Operations
%%--------------------------------------------------------------------

-doc """
Start a new conversation thread within a session.

Creates a thread entry in the store and sets it as the active thread
for the session. A thread ID is auto-generated if not provided in
Opts.

SessionId is the binary session identifier.
Opts is a thread_opts() map with optional keys: name, metadata,
thread_id, parent_thread_id.

Returns {ok, ThreadMeta} with the new thread metadata.

```erlang
{ok, Thread} = beam_agent_threads:start_thread(<<"sess_001">>, #{
    name => <<"bug-investigation">>
}),
ThreadId = maps:get(thread_id, Thread)
```
""".
-spec start_thread(binary(), thread_opts()) -> {ok, thread_meta()}.
start_thread(SessionId, Opts) ->
    beam_agent_threads_core:start_thread(SessionId, Opts).

-doc """
Fork an existing thread.

Creates a new thread with a copy of the source thread's visible
message history. Each copied message has its thread_id rewritten
to the new fork ID. The fork records a parent_thread_id for lineage.

SessionId is the binary session identifier.
SourceThreadId is the binary ID of the thread to fork.
Opts is a thread_opts() map with optional keys: thread_id, name,
parent_thread_id (defaults to SourceThreadId).

Returns {ok, ForkMeta} or {error, not_found} if the source thread
does not exist.

```erlang
{ok, Fork} = beam_agent_threads:fork_thread(
    <<"sess_001">>, <<"thread_abc">>, #{
        name => <<"alternative-design">>
    }
)
```
""".
-spec fork_thread(binary(), binary(), thread_opts()) ->
    {ok, thread_meta()} | {error, not_found}.
fork_thread(SessionId, ThreadId, Opts) ->
    beam_agent_threads_core:fork_thread(SessionId, ThreadId, Opts).

-doc """
Resume an existing thread by ID.

Sets the thread status to active and marks it as the active thread
for the session. Returns {error, not_found} if the thread does not
exist.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
""".
-spec resume_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
resume_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:resume_thread(SessionId, ThreadId).

-doc """
List all threads for a session.

Returns {ok, Threads} with all thread metadata maps, sorted by
updated_at descending (most recently updated first).

SessionId is the binary session identifier.

```erlang
{ok, Threads} = beam_agent_threads:list_threads(<<"sess_001">>),
[#{thread_id := LatestId, name := Name} | _] = Threads
```
""".
-spec list_threads(binary()) -> {ok, [thread_meta()]}.
list_threads(SessionId) ->
    beam_agent_threads_core:list_threads(SessionId).

-doc """
Get metadata for a specific thread.

Returns {ok, ThreadMeta} or {error, not_found}.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
""".
-spec get_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
get_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:get_thread(SessionId, ThreadId).

-doc """
Read a thread with its metadata.

Returns {ok, #{thread => ThreadMeta}} on success, or
{error, not_found} if the thread does not exist.
Equivalent to calling read_thread(SessionId, ThreadId, #{}).

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
""".
-spec read_thread(binary(), binary()) ->
    {ok, #{thread := thread_meta(), messages => [beam_agent_core:message()]}} | {error, not_found}.
read_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:read_thread(SessionId, ThreadId).

-doc """
Read a thread with optional message history.

Returns {ok, #{thread => ThreadMeta, messages => Messages}} when
include_messages is true in Opts, or {ok, #{thread => ThreadMeta}}
otherwise.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
Opts is a map with optional keys:
  - include_messages: if true, include the visible thread messages
""".
-spec read_thread(binary(), binary(), map()) ->
    {ok, #{thread := thread_meta(), messages => [beam_agent_core:message()]}} | {error, not_found}.
read_thread(SessionId, ThreadId, Opts) ->
    beam_agent_threads_core:read_thread(SessionId, ThreadId, Opts).

-doc """
Delete a thread.

Removes the thread from the store. If this was the active thread
for the session, the active thread is cleared.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
""".
-spec delete_thread(binary(), binary()) -> ok.
delete_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:delete_thread(SessionId, ThreadId).

-doc """
Archive a thread.

Sets the thread status to archived with an archived_at timestamp.
The thread data is preserved but marked as inactive.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
Returns {ok, UpdatedMeta} or {error, not_found}.
""".
-spec archive_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
archive_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:archive_thread(SessionId, ThreadId).

-doc """
Unarchive a thread.

Restores an archived thread to active status and clears the
archived flag.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
Returns {ok, UpdatedMeta} or {error, not_found}.
""".
-spec unarchive_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
unarchive_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:unarchive_thread(SessionId, ThreadId).

-doc """
Roll back the visible thread history.

Hides messages beyond a specified boundary without deleting them.
The visible_message_count field in thread metadata controls which
messages are visible when reading the thread.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
Selector is a map with one of the following keys:
  - count: hide the last N visible messages
  - visible_message_count: set the visible boundary directly
  - message_id or uuid: set the boundary to a specific message

Returns {ok, UpdatedMeta} on success, {error, not_found} if the
thread does not exist, or {error, invalid_selector} if the
selector is malformed or references a nonexistent message.

```erlang
%% Hide the last 3 messages:
{ok, _} = beam_agent_threads:rollback_thread(
    <<"sess_001">>, <<"thread_abc">>, #{count => 3}
),

%% Set boundary to a specific message:
{ok, _} = beam_agent_threads:rollback_thread(
    <<"sess_001">>, <<"thread_abc">>, #{uuid => <<"msg_xyz">>}
)
```
""".
-spec rollback_thread(binary(), binary(), map()) ->
    {ok, thread_meta()} | {error, not_found | invalid_selector}.
rollback_thread(SessionId, ThreadId, Selector) ->
    beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector).

%%--------------------------------------------------------------------
%% Thread Message Tracking
%%--------------------------------------------------------------------

-doc """
Record a message against a thread.

Tags the message with the thread ID and stores it in both the
thread metadata (incrementing message_count and visible_message_count)
and the session-level message store for unified history.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
Message is a beam_agent_core:message() map.
""".
-spec record_thread_message(binary(), binary(), beam_agent_core:message()) -> ok.
record_thread_message(SessionId, ThreadId, Message) ->
    beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Message).

-doc """
Get all visible messages for a specific thread.

Filters session messages by thread_id tag and applies the thread's
visible_message_count boundary. Returns {ok, Messages} sorted by
recording order, or {error, not_found} if the thread does not exist.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier.
""".
-spec get_thread_messages(binary(), binary()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_thread_messages(SessionId, ThreadId) ->
    beam_agent_threads_core:get_thread_messages(SessionId, ThreadId).

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc """
Count the number of threads for a session.

SessionId is the binary session identifier.
Returns the thread count as a non-negative integer.
""".
-spec thread_count(binary()) -> non_neg_integer().
thread_count(SessionId) ->
    beam_agent_threads_core:thread_count(SessionId).

-doc """
Get the currently active thread for a session.

Returns {ok, ThreadId} with the active thread's binary ID, or
{error, none} if no thread is currently active.

SessionId is the binary session identifier.
""".
-spec active_thread(binary()) -> {ok, binary()} | {error, none}.
active_thread(SessionId) ->
    beam_agent_threads_core:active_thread(SessionId).

-doc """
Set the active thread for a session.

Overwrites any previously active thread for this session.

SessionId is the binary session identifier.
ThreadId is the binary thread identifier to make active.
""".
-spec set_active_thread(binary(), binary()) -> ok.
set_active_thread(SessionId, ThreadId) ->
    beam_agent_threads_core:set_active_thread(SessionId, ThreadId).

-doc """
Clear the active thread for a session.

After this call, the session has no active thread until one is
started or resumed.

SessionId is the binary session identifier.
""".
-spec clear_active_thread(binary()) -> ok.
clear_active_thread(SessionId) ->
    beam_agent_threads_core:clear_active_thread(SessionId).

%%--------------------------------------------------------------------
%% Session-based Thread Operations (native-first routing)
%%--------------------------------------------------------------------

-doc """
Start a new conversation thread within a live session.

Tries the backend's native thread_start implementation first; falls
back to beam_agent_core:thread_start/2 if the backend does not
provide one.

Parameters:
  - Session: pid of a running session.
  - Opts: thread options map. Optional keys:
    - name: human-readable thread name (defaults to the thread_id)
    - thread_id: explicit id (auto-generated if omitted)
    - metadata: arbitrary metadata map
    - parent_thread_id: id of the parent thread (for fork lineage)

Returns {ok, ThreadMeta} or {error, Reason}.

```erlang
{ok, Thread} = beam_agent_threads:thread_start(Session, #{
    name => <<"refactor-discussion">>
}),
ThreadId = maps:get(thread_id, Thread).
```
""".
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) ->
    beam_agent_core:thread_start(Session, Opts).

-doc """
Resume an existing thread by its identifier.

Sets the thread as the active thread for the session and updates its
status to active. Subsequent queries will be associated with this thread.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, ThreadMeta} or {error, not_found}.

```erlang
{ok, Thread} = beam_agent_threads:thread_resume(Session, <<"thread_abc123">>),
io:format("Resumed: ~s~n", [maps:get(name, Thread)]).
```
""".
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) ->
    beam_agent_core:thread_resume(Session, ThreadId).

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
    beam_agent_core:native_or(Session, thread_resume, [ThreadId, Opts],
        fun() -> thread_resume(Session, ThreadId) end).

-doc """
List all threads for a session, sorted by updated_at descending.

Parameters:
  - Session: pid of a running session.

Returns {ok, ThreadList} where each entry is a thread metadata map.
""".
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) ->
    beam_agent_core:thread_list(Session).

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
    beam_agent_core:native_or(Session, thread_list, [Opts],
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
thread_fork(Session, ThreadId) ->
    beam_agent_core:thread_fork(Session, ThreadId).

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
thread_fork(Session, ThreadId, Opts) ->
    beam_agent_core:thread_fork(Session, ThreadId, Opts).

-doc """
Read thread metadata and optionally its message history.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, #{thread => ThreadMeta}} or {error, not_found}.
""".
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) ->
    beam_agent_core:thread_read(Session, ThreadId).

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
thread_read(Session, ThreadId, Opts) ->
    beam_agent_core:thread_read(Session, ThreadId, Opts).

-doc """
Archive a thread, marking it as archived and inactive.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, UpdatedThreadMeta} or {error, not_found}.
""".
-spec thread_archive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_archive(Session, ThreadId) ->
    beam_agent_core:thread_archive(Session, ThreadId).

-doc """
Unarchive a previously archived thread, restoring it to active status.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, UpdatedThreadMeta} or {error, not_found}.
""".
-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) ->
    beam_agent_core:thread_unarchive(Session, ThreadId).

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
Unsubscribe from a thread and clear it as the active thread if applicable.

Parameters:
  - Session: pid of a running session.
  - ThreadId: binary thread identifier.

Returns {ok, ResultMap} with thread_id and unsubscribed fields, or
{error, not_found}.
""".
-spec thread_unsubscribe(pid(), binary()) -> {ok, term()} | {error, term()}.
thread_unsubscribe(Session, ThreadId) ->
    beam_agent_core:native_or(Session, thread_unsubscribe, [ThreadId], fun() ->
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
    beam_agent_core:native_or(Session, thread_name_set, [ThreadId, Name], fun() ->
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
    beam_agent_core:native_or(Session, thread_metadata_update, [ThreadId, MetadataPatch], fun() ->
        universal_thread_metadata_update(Session, ThreadId, MetadataPatch)
    end).

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
    beam_agent_core:native_or(Session, thread_loaded_list, [], fun() ->
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
    beam_agent_core:native_or(Session, thread_loaded_list, [Opts], fun() ->
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
    beam_agent_core:native_or(Session, thread_compact, [Opts], fun() ->
        universal_thread_compact(Session, Opts)
    end).

%%--------------------------------------------------------------------
%% Private Helpers (universal fallbacks)
%%--------------------------------------------------------------------

-spec universal_thread_unsubscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
universal_thread_unsubscribe(Session, ThreadId) ->
    SessionId = beam_agent_core:session_identity(Session),
    case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
        {ok, _Thread} ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} ->
                    ok = beam_agent_threads_core:clear_active_thread(SessionId);
                _ ->
                    ok
            end,
            {ok, beam_agent_core:with_universal_source(Session, #{
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
    SessionId = beam_agent_core:session_identity(Session),
    case beam_agent_threads_core:rename_thread(SessionId, ThreadId, Name) of
        {ok, Thread} ->
            {ok, beam_agent_core:with_universal_source(Session, #{
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
    SessionId = beam_agent_core:session_identity(Session),
    case beam_agent_threads_core:update_thread_metadata(SessionId, ThreadId, MetadataPatch) of
        {ok, Thread} ->
            {ok, beam_agent_core:with_universal_source(Session, #{
                thread_id => ThreadId,
                metadata => maps:get(metadata, Thread, #{}),
                thread => Thread
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_thread_loaded_list(pid(), map()) -> {ok, map()}.
universal_thread_loaded_list(Session, Opts) ->
    SessionId = beam_agent_core:session_identity(Session),
    {ok, Threads0} = beam_agent_threads_core:list_threads(SessionId),
    Threads = filter_loaded_threads(Threads0, Opts),
    {ok, beam_agent_core:with_universal_source(Session, #{
        threads => Threads,
        active_thread_id => active_thread_id(SessionId),
        count => length(Threads)
    })}.

-spec universal_thread_compact(pid(), map()) -> {ok, map()} | {error, term()}.
universal_thread_compact(Session, Opts) ->
    SessionId = beam_agent_core:session_identity(Session),
    case resolve_thread_id(SessionId, Opts) of
        {ok, ThreadId} ->
            Selector = thread_compact_selector(Opts),
            case beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector) of
                {ok, Thread} ->
                    {ok, beam_agent_core:with_universal_source(Session, #{
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
    IncludeArchived = beam_agent_core:opt_value(
        [include_archived, <<"include_archived">>, <<"includeArchived">>],
        Opts,
        true),
    ThreadIdFilter = beam_agent_core:opt_value(
        [thread_id, <<"thread_id">>, <<"threadId">>], Opts, undefined),
    StatusFilter = beam_agent_core:opt_value(
        [status, <<"status">>], Opts, undefined),
    Limit = beam_agent_core:opt_value(
        [limit, <<"limit">>], Opts, undefined),
    Threads1 = [Thread || Thread <- Threads, include_thread(Thread, IncludeArchived)],
    Threads2 = case ThreadIdFilter of
        undefined ->
            Threads1;
        ThreadId ->
            [Thread || Thread <- Threads1,
             maps:get(thread_id, Thread, undefined) =:= ThreadId]
    end,
    Threads3 = case StatusFilter of
        undefined ->
            Threads2;
        Status ->
            [Thread || Thread <- Threads2,
             maps:get(status, Thread, undefined) =:= Status]
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
    case beam_agent_core:opt_value(
             [thread_id, <<"thread_id">>, <<"threadId">>], Opts, undefined) of
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
    case beam_agent_core:opt_value([selector, <<"selector">>], Opts, undefined) of
        Selector when is_map(Selector) ->
            Selector;
        _ ->
            Selector0 =
                maybe_put_selector(count,
                    beam_agent_core:opt_value(
                        [count, <<"count">>], Opts, undefined),
                    maybe_put_selector(visible_message_count,
                        beam_agent_core:opt_value(
                            [visible_message_count,
                             <<"visible_message_count">>,
                             <<"visibleMessageCount">>],
                            Opts,
                            undefined),
                        maybe_put_selector(message_id,
                            beam_agent_core:opt_value(
                                [message_id, <<"message_id">>, <<"messageId">>],
                                Opts,
                                undefined),
                            maybe_put_selector(uuid,
                                beam_agent_core:opt_value(
                                    [uuid, <<"uuid">>], Opts, undefined),
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
