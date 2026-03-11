-module(beam_agent_checkpoint).
-moduledoc """
Public API for file checkpointing and rewind.

This module provides file snapshot and restore capabilities across
all agentic coder backends. Before a tool mutates files, callers
snapshot the target paths. If the mutation needs to be undone, rewind
restores the files to their checkpointed state.

Checkpoints are identified by a session ID and a UUID. Each
checkpoint records the content, permissions, and existence of a set
of files at the time of the snapshot. Rewind restores all files in
a checkpoint to their recorded state, including deleting files that
did not exist at checkpoint time.

Most callers interact with checkpoints through the hook system
(beam_agent_hooks) rather than calling this module directly. The
pre_tool_use hook fires before file mutations, and the
extract_file_paths/2 helper identifies which files a tool will modify.

## Getting Started

```erlang
%% Snapshot files before a mutation:
{ok, CP} = beam_agent_checkpoint:snapshot(
    <<"sess_001">>, <<"uuid_abc123">>,
    [<<"/tmp/foo.txt">>, <<"/tmp/bar.txt">>]
),

%% Later, rewind to that checkpoint:
ok = beam_agent_checkpoint:rewind(<<"sess_001">>, <<"uuid_abc123">>),

%% List all checkpoints for a session:
{ok, Checkpoints} = beam_agent_checkpoint:list_checkpoints(<<"sess_001">>)
```

## Key Concepts

- Snapshot: a frozen record of file state at a point in time. Each file
  in the snapshot records its path, content (or undefined if the file did
  not exist), existence flag, and POSIX permissions.

- Checkpoint UUID: a binary identifier (e.g. a tool_use_id) that uniquely
  names a snapshot within a session. Callers choose the UUID so it can be
  correlated with the tool invocation that triggered the checkpoint.

- Rewind: restores every file in a checkpoint to its recorded state.
  Files that existed at checkpoint time have their content and permissions
  restored. Files that did not exist are deleted if they were created
  after the checkpoint.

## Architecture

This module is a thin public wrapper that delegates every call to
beam_agent_checkpoint_core. The core module owns the ETS table
(beam_agent_checkpoints) and all implementation logic including
file I/O for snapshot and restore operations.

The ETS table uses {SessionId, UUID} composite keys in a set table
with public access, so any process can create and query checkpoints
without bottlenecking.

== Core concepts ==

Checkpointing is like saving your game before a boss fight. Before the
agent modifies files, the SDK snapshots their current state. If something
goes wrong, you can rewind to restore the files exactly as they were.

The workflow is: snapshot (save the current file state) -> do work ->
rewind if needed (restore the saved state). Each checkpoint has a UUID
that ties it to the specific tool invocation that triggered it.

list_checkpoints/1 shows all save points for a session. get_checkpoint/2
retrieves one by UUID. rewind/2 restores files to their checkpointed
state, including deleting files that were created after the checkpoint.

== Architecture deep dive ==

Checkpoints are managed by beam_agent_checkpoint_core, the universal
layer. All state lives in the beam_agent_checkpoints ETS table using
{SessionId, UUID} composite keys in a public set table, so any process
can create and query checkpoints without serialization bottlenecks.

Each checkpoint captures file content, POSIX permissions, and an
existence flag. Rewind performs the inverse: writes content, restores
permissions, and deletes files that did not exist at checkpoint time.

The checkpoint system is entirely backend-agnostic. Backend handlers
do not implement checkpoint logic -- the universal layer handles it
via the hook system (pre_tool_use fires before file mutations).

## See Also

- beam_agent_checkpoint_core: implementation module with full internals
- beam_agent_hooks: hook system for automatic pre-tool checkpointing
- beam_agent_session_store: session-level history store
- beam_agent: main SDK entry point

## Backend Integration

Checkpointing is handled by the universal layer (beam_agent_checkpoint_core).
Backend authors do not need to implement checkpoint support. See
docs/guides/backend_integration_guide.md for details on the universal
fallback system.
""".

-export([
    ensure_table/0,
    clear/0,
    snapshot/3,
    rewind/2,
    list_checkpoints/1,
    get_checkpoint/2,
    delete_checkpoint/2,
    extract_file_paths/2
]).

-export_type([checkpoint/0, file_snapshot/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc """
Checkpoint metadata map.

Contains the UUID, session ID, creation timestamp (unix milliseconds),
and a list of file_snapshot() records captured at checkpoint time.
""".
-type checkpoint() :: beam_agent_checkpoint_core:checkpoint().

-doc """
A single file's snapshot within a checkpoint.

Records the file path (binary), content (binary or undefined if the
file did not exist), whether the file existed (boolean), and POSIX
permissions (non_neg_integer or undefined).
""".
-type file_snapshot() :: beam_agent_checkpoint_core:file_snapshot().

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the checkpoint ETS table exists.

Creates the beam_agent_checkpoints table if it does not already
exist. This function is idempotent and safe to call from any process.
""".
-spec ensure_table() -> ok.
ensure_table() -> beam_agent_checkpoint_core:ensure_table().

-doc """
Clear all checkpoint data from the store.

Deletes every entry from the checkpoints table. The table itself
remains in place. This is a destructive operation intended for test
teardown or full resets.
""".
-spec clear() -> ok.
clear() -> beam_agent_checkpoint_core:clear().

%%--------------------------------------------------------------------
%% Checkpoint Operations
%%--------------------------------------------------------------------

-doc """
Snapshot a list of file paths for later rewind.

Reads each file's content and POSIX permissions at the current moment.
Files that do not exist are recorded as non-existent so that rewind
can delete them if they are created after the checkpoint.

SessionId is the binary session identifier.
UUID is a binary checkpoint identifier (e.g. a tool_use_id).
Paths is a list of file paths (binaries or strings).

Returns {ok, Checkpoint} with the checkpoint metadata map.

```erlang
{ok, CP} = beam_agent_checkpoint:snapshot(
    <<"sess_001">>, <<"tool_use_xyz">>,
    [<<"/home/user/project/src/main.erl">>]
),
[#{path := <<"/home/user/project/src/main.erl">>,
   existed := true}] = maps:get(files, CP)
```
""".
-spec snapshot(binary(), binary(), [binary() | string()]) ->
    {ok, checkpoint()}.
snapshot(SessionId, UUID, Paths) ->
    beam_agent_checkpoint_core:snapshot(SessionId, UUID, Paths).

-doc """
Rewind files to a checkpoint state.

Restores each file in the checkpoint to its recorded content and
permissions. Files that did not exist at checkpoint time are deleted
if they exist now. Files that existed are written back with their
original content and POSIX permissions.

SessionId is the binary session identifier.
UUID is the binary checkpoint identifier.

Returns ok on success, {error, not_found} if the checkpoint does
not exist, or {error, {restore_failed, Path, Reason}} if a file
restore operation fails.

```erlang
ok = beam_agent_checkpoint:rewind(<<"sess_001">>, <<"tool_use_xyz">>)
```
""".
-spec rewind(binary(), binary()) ->
    ok | {error, not_found | {restore_failed, binary(), file:posix()}}.
rewind(SessionId, UUID) ->
    beam_agent_checkpoint_core:rewind(SessionId, UUID).

-doc """
List all checkpoints for a session.

Returns {ok, Checkpoints} with checkpoint metadata maps sorted by
created_at descending (newest first).

SessionId is the binary session identifier.

```erlang
{ok, Checkpoints} = beam_agent_checkpoint:list_checkpoints(<<"sess_001">>),
[#{uuid := LatestUUID} | _] = Checkpoints
```
""".
-spec list_checkpoints(binary()) -> {ok, [checkpoint()]}.
list_checkpoints(SessionId) ->
    beam_agent_checkpoint_core:list_checkpoints(SessionId).

-doc """
Get a specific checkpoint by session ID and UUID.

Returns {ok, Checkpoint} with the checkpoint metadata map, or
{error, not_found} if no checkpoint with this UUID exists in the
session.

SessionId is the binary session identifier.
UUID is the binary checkpoint identifier.
""".
-spec get_checkpoint(binary(), binary()) ->
    {ok, checkpoint()} | {error, not_found}.
get_checkpoint(SessionId, UUID) ->
    beam_agent_checkpoint_core:get_checkpoint(SessionId, UUID).

-doc """
Delete a checkpoint.

Removes the checkpoint from the store. This does not affect any
files on disk -- it only removes the stored snapshot data.

SessionId is the binary session identifier.
UUID is the binary checkpoint identifier.
""".
-spec delete_checkpoint(binary(), binary()) -> ok.
delete_checkpoint(SessionId, UUID) ->
    beam_agent_checkpoint_core:delete_checkpoint(SessionId, UUID).

%%--------------------------------------------------------------------
%% Hook Helpers
%%--------------------------------------------------------------------

-doc """
Extract file paths from a tool use message for checkpointing.

Inspects the tool name and input map to determine which files the
tool will modify. Currently recognizes Write and Edit tools (both
capitalized and lowercase variants) and extracts the file_path field.

ToolName is a binary tool name (e.g. <<"Write">>, <<"Edit">>).
ToolInput is the tool's input map (containing file_path).

Returns a list of binary file paths, or an empty list if the tool
is not a recognized file-mutating tool.
""".
-spec extract_file_paths(binary(), map()) -> [binary()].
extract_file_paths(ToolName, ToolInput) ->
    beam_agent_checkpoint_core:extract_file_paths(ToolName, ToolInput).
