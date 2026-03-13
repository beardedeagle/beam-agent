defmodule BeamAgent.Threads do
  @moduledoc """
  Conversation thread lifecycle management for the BeamAgent SDK.

  This module provides logical conversation threading within sessions. A thread
  groups related queries into a named conversation branch, enabling parallel
  workstreams, forking, archiving, and rollback within a single session.

  Threads are scoped to a session: each session can have multiple threads, and
  each thread tracks its own query history. Messages recorded against a thread
  are also stored in the parent session for unified history via
  `BeamAgent.SessionStore`.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with threads through `BeamAgent`. Use this module
  directly when you need fine-grained control over thread lifecycle, forking,
  archiving, or rollback operations — for example, in a multi-agent orchestrator
  or a conversation branching UI.

  ## Quick example

  ```elixir
  # Start a new thread within a session:
  {:ok, thread} = BeamAgent.Threads.thread_start("sess_001", %{name: "bug-investigation"})

  # List all threads for the session:
  {:ok, threads} = BeamAgent.Threads.thread_list("sess_001")

  # Fork the thread to explore an alternative approach:
  {:ok, fork} = BeamAgent.Threads.thread_fork("sess_001", thread.thread_id, %{
    name: "alternative-design"
  })

  # Roll back the last 3 messages:
  {:ok, _} = BeamAgent.Threads.thread_rollback("sess_001", thread.thread_id, %{count: 3})
  ```

  ## Core concepts

  - **Thread**: a named conversation branch within a session, identified by a
    binary thread ID. Each thread has its own message history, status
    (`:active`, `:paused`, `:completed`, `:archived`), and a visible message
    count for rollback support.

  - **Active thread**: each session tracks at most one active thread. Starting or
    resuming a thread sets it as the active thread for that session.

  - **Forking**: `thread_fork/3` creates a new thread with a copy of the source
    thread's visible message history. The fork records its `parent_thread_id` for
    lineage tracking.

  - **Rollback**: `thread_rollback/3` hides messages beyond a boundary without
    deleting them. The `visible_message_count` field controls which messages are
    visible when reading the thread.

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_threads` module.
  The underlying implementation lives in `:beam_agent_threads_core`, which owns
  two ETS tables: `beam_agent_threads_core` for thread metadata and
  `beam_agent_active_threads` for active-thread tracking.

  Thread messages are stored in the session-level message store with a
  `thread_id` tag, keeping all messages queryable at both the session and thread
  level.

  See also: `BeamAgent.SessionStore`, `BeamAgent`.
  """

  @doc """
  Start a new conversation thread within a session.

  Creates a thread entry in the store and sets it as the active thread for the
  session. A thread ID is auto-generated if not provided in `opts`.

  `opts` may include:
  - `:name` — human-readable thread name (binary)
  - `:metadata` — arbitrary metadata map
  - `:thread_id` — explicit thread ID (binary, auto-generated if omitted)
  - `:parent_thread_id` — ID of the parent thread for lineage

  Returns `{:ok, thread_meta}`.

  ## Example

  ```elixir
  {:ok, thread} = BeamAgent.Threads.thread_start("sess_001", %{name: "feature-work"})
  thread.thread_id  # => "thread_a1b2c3d4"
  ```
  """
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_start(session, opts), to: :beam_agent_threads

  @doc """
  Resume an existing thread by ID, making it the active thread.

  Sets the thread status to `:active` and marks it as the active thread for the
  session.

  Returns `{:ok, thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_resume(session, thread_id), to: :beam_agent_threads

  @doc """
  List all threads for a session, sorted by most-recently updated.

  Returns `{:ok, threads}` with all thread metadata maps.

  ## Example

  ```elixir
  {:ok, threads} = BeamAgent.Threads.thread_list("sess_001")
  [%{thread_id: latest_id, name: name} | _] = threads
  ```
  """
  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate thread_list(session), to: :beam_agent_threads

  @doc """
  Fork an existing thread.

  Creates a new thread with a copy of the source thread's visible message
  history. Each copied message has its `thread_id` rewritten to the new fork ID.
  The fork records a `parent_thread_id` for lineage.

  `opts` may include:
  - `:thread_id` — explicit ID for the fork (auto-generated if omitted)
  - `:name` — human-readable name for the fork
  - `:parent_thread_id` — defaults to the source `thread_id`

  Returns `{:ok, fork_meta}` or `{:error, :not_found}`.

  ## Example

  ```elixir
  {:ok, fork} = BeamAgent.Threads.thread_fork("sess_001", "thread_abc", %{
    name: "alternative-approach"
  })
  ```
  """
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_fork(session, thread_id), to: :beam_agent_threads

  @doc """
  Fork an existing thread with options.

  Same as `thread_fork/2` but accepts an `opts` map for the fork's name,
  explicit thread ID, and parent thread ID.
  """
  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_fork(session, thread_id, opts), to: :beam_agent_threads

  @doc """
  Read a thread's metadata.

  Returns `{:ok, %{thread: thread_meta}}` on success or `{:error, :not_found}`.
  Equivalent to `thread_read/3` with an empty opts map.
  """
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_read(session, thread_id), to: :beam_agent_threads

  @doc """
  Read a thread with optional message history.

  `opts` may include:
  - `:include_messages` — if `true`, the returned map includes a `:messages` key
    with the thread's visible messages

  Returns `{:ok, result}` where `result` contains at least a `:thread` key, or
  `{:error, :not_found}`.
  """
  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_read(session, thread_id, opts), to: :beam_agent_threads

  @doc """
  Archive a thread.

  Sets the thread status to `:archived` with an `archived_at` timestamp. The
  thread data is preserved but marked as inactive.

  Returns `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_archive(session, thread_id), to: :beam_agent_threads

  @doc """
  Unarchive a thread, restoring it to active status.

  Returns `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_unarchive(session, thread_id), to: :beam_agent_threads

  @doc """
  Roll back the visible thread history.

  Hides messages beyond a specified boundary without deleting them. The
  `visible_message_count` field in thread metadata controls which messages are
  visible when reading the thread.

  `selector` is a map with one of:
  - `:count` — hide the last N visible messages
  - `:visible_message_count` — set the visible boundary directly
  - `:message_id` or `:uuid` — set the boundary to a specific message

  Returns `{:ok, updated_meta}`, `{:error, :not_found}`, or
  `{:error, :invalid_selector}`.

  ## Example

  ```elixir
  # Hide the last 3 messages:
  {:ok, _} = BeamAgent.Threads.thread_rollback("sess_001", "thread_abc", %{count: 3})

  # Set boundary to a specific message:
  {:ok, _} = BeamAgent.Threads.thread_rollback("sess_001", "thread_abc", %{uuid: "msg_xyz"})
  ```
  """
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_rollback(session, thread_id, selector), to: :beam_agent_threads

  @doc """
  Resume an existing thread with backend-specific options.

  Like `thread_resume/2` but passes additional options to the backend's
  native implementation. Falls back to `thread_resume/2` if the backend
  does not support extended resume options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- backend-specific resume options.

  ## Returns

  - `{:ok, thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_resume(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_resume(session, thread_id, opts), to: :beam_agent_threads

  @doc """
  List threads for a session with backend-specific options.

  Falls back to `thread_list/1` if the backend does not support filtered
  thread listing.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific listing options.

  ## Returns

  - `{:ok, threads}` or `{:error, reason}`.
  """
  @spec thread_list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate thread_list(session, opts), to: :beam_agent_threads

  @doc """
  Unsubscribe from a thread and clear it as the active thread if applicable.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, result_map}` with `:thread_id` and `:unsubscribed` fields.
  - `{:error, :not_found}`.
  """
  @spec thread_unsubscribe(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_unsubscribe(session, thread_id), to: :beam_agent_threads

  @doc """
  Rename a thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `name` -- new thread name as a binary.

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  @spec thread_name_set(pid(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_name_set(session, thread_id, name), to: :beam_agent_threads

  @doc """
  Merge a metadata patch into a thread's metadata map.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `metadata_patch` -- map of key-value pairs to merge into the thread's
    existing metadata.

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  @spec thread_metadata_update(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_metadata_update(session, thread_id, metadata_patch), to: :beam_agent_threads

  @doc """
  List loaded (in-memory) threads for a session.

  Returns threads with their active state, optionally filtered by the
  backend's native implementation.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` with `:threads`, `:active_thread_id`, and `:count`.
  - `{:error, reason}`.
  """
  @spec thread_loaded_list(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_loaded_list(session), to: :beam_agent_threads

  @doc """
  List loaded threads for a session with filter options.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Optional keys:
    - `:include_archived` -- include archived threads (default `true`)
    - `:thread_id` -- filter to a specific thread
    - `:status` -- filter by thread status
    - `:limit` -- maximum number of results

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  @spec thread_loaded_list(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_loaded_list(session, opts), to: :beam_agent_threads

  @doc """
  Compact a thread by reducing its visible message history.

  Uses `thread_rollback` internally with a selector derived from the
  options map.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- compaction options map. Optional keys:
    - `:thread_id` -- target thread (defaults to active thread)
    - `:count` -- number of messages to hide from the end
    - `:visible_message_count` -- set boundary directly
    - `:selector` -- explicit rollback selector map

  ## Returns

  - `{:ok, result_map}` or `{:error, :not_found}`.
  """
  @spec thread_compact(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate thread_compact(session, opts), to: :beam_agent_threads
end
