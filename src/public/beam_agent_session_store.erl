-module(beam_agent_session_store).
-moduledoc """
Public API for the unified session history store.

This module provides ETS-backed session tracking and message history
across all agentic coder backends (Claude, Codex, Gemini, OpenCode,
Copilot). Every adapter records messages here regardless of whether
the underlying CLI has native session history support, giving callers
a single consistent interface for session management.

Most callers interact with sessions through the main beam_agent
module. Use this module directly when you need fine-grained control
over session metadata, message querying, forking, sharing, or
summarization.

## Getting Started

```erlang
%% Ensure ETS tables exist (idempotent, safe to call repeatedly):
ok = beam_agent_session_store:ensure_tables(),

%% Register a new session:
ok = beam_agent_session_store:register_session(<<"sess_abc123">>, #{
    adapter => claude,
    model => <<"claude-sonnet-4-20250514">>,
    cwd => <<"/home/user/project">>
}),

%% Record messages as they arrive:
ok = beam_agent_session_store:record_message(<<"sess_abc123">>, #{
    type => assistant, content => <<"Hello!">>
}),

%% Query session history:
{ok, Messages} = beam_agent_session_store:get_session_messages(<<"sess_abc123">>)
```

## Key Concepts

- Session metadata: each session is identified by a binary session ID and
  carries metadata such as the adapter name, model, working directory,
  timestamps, and a message count. Metadata is stored in the
  beam_agent_sessions ETS table.

- Message recording: messages are stored with auto-incrementing sequence
  numbers in the beam_agent_session_messages ordered-set ETS table. This
  preserves insertion order and enables efficient prefix scans per session.

- Forking: fork_session/2 creates a deep copy of a session (metadata and
  all messages) under a new session ID, recording the parent relationship
  in the extra.fork field.

- Sharing: share_session/1 generates a share ID that marks the session as
  externally visible. unshare_session/1 revokes access.

- Summarization: summarize_session/1 generates a deterministic text summary
  from the session message history and stores it in session metadata.

- Reverting: revert_session/2 hides messages beyond a boundary without
  deleting them. unrevert_session/1 restores the full view.

## Architecture

This module is a thin public wrapper that delegates every call to
beam_agent_session_store_core. The core module owns the ETS tables
(beam_agent_sessions, beam_agent_session_messages,
beam_agent_session_counters) and all implementation logic. Types are
re-exported from the core for caller convenience.

Tables are public and named so any process can read and write without
bottlenecking on a single owner. They are created lazily on first
access and persist for the lifetime of the BEAM node.

## Core concepts

The session store is like version control for conversations. It saves
every message exchanged during a session so you can look back at the
full history, fork a conversation to explore alternatives, or revert
to an earlier point.

Key operations: register_session/2 creates a new session entry,
record_message/2 saves individual messages as they arrive,
get_session_messages/1 retrieves the full history. fork_session/2
creates a complete copy under a new session ID. revert_session/2
rolls back to an earlier message boundary.

Sharing lets you make a session visible externally (e.g., for
collaboration), and summarization generates a text summary of the
conversation history.

## Architecture deep dive

The store is backed by three ETS tables: beam_agent_sessions (metadata),
beam_agent_session_messages (ordered-set with auto-incrementing sequence
numbers), and beam_agent_session_counters (atomic message counters).
All tables are public and named so any process can read/write without
bottlenecking on a single owner.

Session forking performs a deep copy of metadata and all messages under
a new session ID, recording the parent relationship in extra.fork.
Revert uses the visible_message_count field to hide messages beyond a
boundary without deleting them -- unrevert restores the full view.

The store is process-independent. Messages are recorded by the session
engine during handle_data, but any process can query the store for
session history at any time.

## See Also

- beam_agent_session_store_core: implementation module with full internals
- beam_agent_threads: conversation threading within sessions
- beam_agent_checkpoint: file snapshot and rewind support
- beam_agent: main SDK entry point (delegates to this module)
""".

-export([
    ensure_tables/0,
    clear/0,
    register_session/2,
    update_session/2,
    get_session/1,
    delete_session/1,
    list_sessions/0,
    list_sessions/1,
    list_native_sessions/0,
    list_native_sessions/1,
    fork_session/2,
    revert_session/2,
    unrevert_session/1,
    share_session/1,
    share_session/2,
    unshare_session/1,
    get_share/1,
    summarize_session/1,
    summarize_session/2,
    get_summary/1,
    record_message/2,
    record_messages/2,
    get_session_messages/1,
    get_session_messages/2,
    get_native_session_messages/1,
    get_native_session_messages/2,
    session_count/0,
    message_count/1
]).

-export_type([
    session_meta/0,
    list_opts/0,
    message_opts/0,
    session_share/0,
    session_summary/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc """
Session metadata map.

Contains the session ID, adapter name, model, working directory,
creation and update timestamps, message count, and an optional
extra map for fork/share/summary/view state.
""".
-type session_meta() :: beam_agent_session_store_core:session_meta().

-doc """
Options for filtering session listings.

Supported keys: adapter (atom), cwd (binary), model (binary),
limit (pos_integer), since (unix millisecond timestamp).
""".
-type list_opts() :: beam_agent_session_store_core:list_opts().

-doc """
Options for querying session messages.

Supported keys: limit (pos_integer), offset (non_neg_integer),
types (list of message types), include_hidden (boolean).
""".
-type message_opts() :: beam_agent_session_store_core:message_opts().

-doc """
Share state for a session.

Contains the share ID, session ID, creation timestamp, status
(active or revoked), and an optional revoked_at timestamp.
""".
-type session_share() :: beam_agent_session_store_core:session_share().

-doc """
Summary of a session's conversation history.

Contains the session ID, generated content, generation timestamp,
message count at generation time, and the generator identifier.
""".
-type session_summary() :: beam_agent_session_store_core:session_summary().

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure all session store ETS tables exist.

Creates the beam_agent_sessions, beam_agent_session_messages, and
beam_agent_session_counters tables if they do not already exist. This
function is idempotent and safe to call from any process at any time.

Most functions in this module call ensure_tables/0 internally, so
explicit calls are only needed when you want to guarantee table
existence before entering a hot path.

```erlang
ok = beam_agent_session_store:ensure_tables()
```
""".
-spec ensure_tables() -> ok.
ensure_tables() -> beam_agent_session_store_core:ensure_tables().

-doc """
Clear all session data from the store.

Deletes every entry from the sessions, messages, and counters tables.
The tables themselves remain in place. This is a destructive operation
intended for test teardown or full resets.
""".
-spec clear() -> ok.
clear() -> beam_agent_session_store_core:clear().

%%--------------------------------------------------------------------
%% Session Metadata
%%--------------------------------------------------------------------

-doc """
Register a new session with metadata.

Creates a session entry in the store with the given SessionId and
metadata map. If a session with this ID already exists, this is a
no-op (use update_session/2 to modify existing sessions).

The store automatically populates created_at, updated_at, and
message_count fields. Any values provided in Meta for these fields
are used as defaults.

SessionId is a binary session identifier (e.g. <<"sess_abc123">>).
Meta is a map of initial metadata (adapter, model, cwd, extra, etc.).

```erlang
ok = beam_agent_session_store:register_session(<<"sess_001">>, #{
    adapter => claude,
    model => <<"claude-sonnet-4-20250514">>,
    cwd => <<"/home/user/project">>
})
```
""".
-spec register_session(binary(), map()) -> ok.
register_session(SessionId, Meta) ->
    beam_agent_session_store_core:register_session(SessionId, Meta).

-doc """
Update an existing session's metadata.

Merges the provided fields into the existing session metadata and
refreshes the updated_at timestamp. If the session does not exist,
it is created via register_session/2.

SessionId is the binary session identifier.
Patch is a map of fields to merge into the existing metadata.
""".
-spec update_session(binary(), map()) -> ok.
update_session(SessionId, Patch) ->
    beam_agent_session_store_core:update_session(SessionId, Patch).

-doc """
Get metadata for a specific session.

Returns {ok, Meta} with the session metadata map, or
{error, not_found} if no session with this ID exists.

SessionId is the binary session identifier.

```erlang
{ok, Meta} = beam_agent_session_store:get_session(<<"sess_001">>),
Model = maps:get(model, Meta)
```
""".
-spec get_session(binary()) -> {ok, session_meta()} | {error, not_found}.
get_session(SessionId) ->
    beam_agent_session_store_core:get_session(SessionId).

-doc """
Delete a session and all its messages.

Removes the session metadata, message counter, and every recorded
message for this session from the store. Also fires a completion
event via beam_agent_events.

SessionId is the binary session identifier.
""".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    beam_agent_session_store_core:delete_session(SessionId).

-doc """
List all sessions in the store.

Returns {ok, Sessions} with all session metadata maps, sorted by
updated_at descending (most recently updated first). Equivalent to
calling list_sessions(#{}).

```erlang
{ok, Sessions} = beam_agent_session_store:list_sessions(),
[#{session_id := Id, model := Model} | _] = Sessions
```
""".
-spec list_sessions() -> {ok, [session_meta()]}.
list_sessions() -> beam_agent_session_store_core:list_sessions().

-doc """
List sessions with optional filters.

Returns sessions matching all provided filter criteria, sorted by
updated_at descending.

Opts is a map with optional filter keys:
  - adapter: only sessions using this adapter (atom)
  - cwd: only sessions with this working directory (binary)
  - model: only sessions using this model (binary)
  - limit: maximum number of results (pos_integer)
  - since: only sessions updated at or after this timestamp (unix ms)

```erlang
{ok, RecentClaude} = beam_agent_session_store:list_sessions(#{
    adapter => claude,
    limit => 10,
    since => erlang:system_time(millisecond) - 3600000
})
```
""".
-spec list_sessions(list_opts()) -> {ok, [session_meta()]}.
list_sessions(Opts) -> beam_agent_session_store_core:list_sessions(Opts).

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
Fork (deep copy) an existing session.

Creates a new session with copies of all metadata and messages from
the source session. The new session records its lineage in the
extra.fork field (parent_session_id, forked_at).

SourceSessionId is the binary ID of the session to fork.
Opts is a map with optional keys:
  - session_id: explicit ID for the fork (auto-generated if omitted)
  - include_hidden: whether to copy hidden (reverted) messages (default true)
  - extra: additional extra metadata to merge into the fork

Returns {ok, ForkMeta} with the new session metadata, or
{error, not_found} if the source session does not exist.

```erlang
{ok, Fork} = beam_agent_session_store:fork_session(<<"sess_001">>, #{
    session_id => <<"sess_fork_001">>
}),
<<"sess_fork_001">> = maps:get(session_id, Fork)
```
""".
-spec fork_session(binary(), map()) ->
    {ok, session_meta()} | {error, not_found}.
fork_session(SessionId, Opts) ->
    beam_agent_session_store_core:fork_session(SessionId, Opts).

-doc """
Revert the visible conversation to a prior message boundary.

Hides messages beyond the specified boundary without deleting them.
The underlying message store remains append-only; revert changes
the active view by storing a visible_message_count in the session
extra.view field.

SessionId is the binary session identifier.
Selector is a map with one of the following keys:
  - visible_message_count: set the boundary to exactly N messages
  - message_id or uuid: set the boundary to a specific message

Returns {ok, UpdatedMeta} on success, {error, not_found} if the
session does not exist, or {error, invalid_selector} if the
selector map is malformed or references a nonexistent message.
""".
-spec revert_session(binary(), map()) ->
    {ok, session_meta()} | {error, not_found | invalid_selector}.
revert_session(SessionId, Selector) ->
    beam_agent_session_store_core:revert_session(SessionId, Selector).

-doc """
Clear revert state and restore the full visible history.

Removes the visible_message_count boundary from the session view,
making all recorded messages visible again.

SessionId is the binary session identifier.
Returns {ok, UpdatedMeta} on success or {error, not_found}.
""".
-spec unrevert_session(binary()) ->
    {ok, session_meta()} | {error, not_found}.
unrevert_session(SessionId) ->
    beam_agent_session_store_core:unrevert_session(SessionId).

-doc """
Generate a share token for a session.

Creates an active share record with a generated share ID and stores
it in the session extra.share field. Equivalent to calling
share_session(SessionId, #{}).

SessionId is the binary session identifier.
Returns {ok, Share} with the share map, or {error, not_found}.

```erlang
{ok, Share} = beam_agent_session_store:share_session(<<"sess_001">>),
ShareId = maps:get(share_id, Share)
```
""".
-spec share_session(binary()) ->
    {ok, session_share()} | {error, not_found}.
share_session(SessionId) ->
    beam_agent_session_store_core:share_session(SessionId).

-doc """
Generate a share token for a session with options.

SessionId is the binary session identifier.
Opts is a map with optional keys:
  - share_id: explicit share ID (auto-generated if omitted)

Returns {ok, Share} with the active share map, or {error, not_found}.
""".
-spec share_session(binary(), map()) ->
    {ok, session_share()} | {error, not_found}.
share_session(SessionId, Opts) ->
    beam_agent_session_store_core:share_session(SessionId, Opts).

-doc """
Revoke the current share for a session.

Marks the session share as revoked with a revoked_at timestamp.
Returns ok on success, or {error, not_found} if the session or
share does not exist.

SessionId is the binary session identifier.
""".
-spec unshare_session(binary()) -> ok | {error, not_found}.
unshare_session(SessionId) ->
    beam_agent_session_store_core:unshare_session(SessionId).

-doc """
Get the current share state for a session.

Returns {ok, Share} with the share map (which may have status
active or revoked), or {error, not_found} if the session has no
share record.

SessionId is the binary session identifier.
""".
-spec get_share(binary()) -> {ok, session_share()} | {error, not_found}.
get_share(SessionId) ->
    beam_agent_session_store_core:get_share(SessionId).

-doc """
Generate and store a summary for a session.

Builds a deterministic text summary from the session message history
and stores it in the session extra.summary field. Equivalent to
calling summarize_session(SessionId, #{}).

SessionId is the binary session identifier.
Returns {ok, Summary} or {error, not_found}.
""".
-spec summarize_session(binary()) ->
    {ok, session_summary()} | {error, not_found}.
summarize_session(SessionId) ->
    beam_agent_session_store_core:summarize_session(SessionId).

-doc """
Generate and store a summary for a session with options.

SessionId is the binary session identifier.
Opts is a map with optional keys:
  - content or summary: explicit summary text (auto-derived if omitted)
  - generated_by: identifier for the summary generator (default <<"beam_agent_core">>)

Returns {ok, Summary} or {error, not_found}.
""".
-spec summarize_session(binary(), map()) ->
    {ok, session_summary()} | {error, not_found}.
summarize_session(SessionId, Opts) ->
    beam_agent_session_store_core:summarize_session(SessionId, Opts).

-doc """
Get the stored summary for a session.

Returns {ok, Summary} with the summary map, or {error, not_found}
if the session has no stored summary.

SessionId is the binary session identifier.
""".
-spec get_summary(binary()) -> {ok, session_summary()} | {error, not_found}.
get_summary(SessionId) ->
    beam_agent_session_store_core:get_summary(SessionId).

%%--------------------------------------------------------------------
%% Message Storage
%%--------------------------------------------------------------------

-doc """
Record a single message for a session.

Stores the message with an auto-incrementing sequence number for
ordering and updates the session metadata (message count, timestamps,
model extraction). If the session has not been registered, a minimal
session entry is auto-created.

Also publishes the message via beam_agent_events for live subscribers.

SessionId is the binary session identifier.
Message is a beam_agent_core:message() map.
""".
-spec record_message(binary(), beam_agent_core:message()) -> ok.
record_message(SessionId, Message) ->
    beam_agent_session_store_core:record_message(SessionId, Message).

-doc """
Record multiple messages for a session in order.

Convenience function that calls record_message/2 for each message
in the list, preserving the given order.

SessionId is the binary session identifier.
Messages is a list of beam_agent_core:message() maps.
""".
-spec record_messages(binary(), [beam_agent_core:message()]) -> ok.
record_messages(SessionId, Messages) ->
    beam_agent_session_store_core:record_messages(SessionId, Messages).

-doc """
Get all messages for a session in order.

Returns {ok, Messages} with the full message list sorted by
recording order, or {error, not_found} if the session does not
exist. Equivalent to calling get_session_messages(SessionId, #{}).

SessionId is the binary session identifier.
""".
-spec get_session_messages(binary()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    beam_agent_session_store_core:get_session_messages(SessionId).

-doc """
Get messages for a session with filtering options.

Returns {ok, Messages} with the filtered and paginated message list,
or {error, not_found} if the session does not exist.

SessionId is the binary session identifier.
Opts is a map with optional keys:
  - limit: maximum number of messages to return (pos_integer)
  - offset: number of messages to skip from the start (non_neg_integer)
  - types: only include messages of these types (list of atoms)
  - include_hidden: if true, include messages hidden by revert (boolean)
""".
-spec get_session_messages(binary(), message_opts()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) ->
    beam_agent_session_store_core:get_session_messages(SessionId, Opts).

-doc """
Get messages from the backend's native session store (Claude-specific).

Attempts to call the Claude backend's native message retrieval. Falls back
to get_session_messages/1 if the backend does not support native message
retrieval.

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

Like get_native_session_messages/1 but passes filter options to the native
call. Falls back to get_session_messages/2 if native retrieval is not
supported.

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

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc """
Get the total number of tracked sessions.

Returns the count of session entries in the store.
""".
-spec session_count() -> non_neg_integer().
session_count() -> beam_agent_session_store_core:session_count().

-doc """
Get the recorded message count for a specific session.

Returns the number of messages stored for this session. Returns 0
if the session does not exist or has no messages.

SessionId is the binary session identifier.
""".
-spec message_count(binary()) -> non_neg_integer().
message_count(SessionId) ->
    beam_agent_session_store_core:message_count(SessionId).
