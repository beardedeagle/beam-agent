defmodule BeamAgent.Checkpoint do
  @moduledoc """
  File checkpointing and rewind for the BeamAgent SDK.

  This module provides file snapshot and restore capabilities across all five
  agentic coder backends. Before a tool mutates files, callers snapshot the target
  paths. If the mutation needs to be undone, `rewind/2` restores the files to
  their checkpointed state.

  Checkpoints are identified by a session ID and a UUID. Each checkpoint records
  the content, permissions, and existence of a set of files at the time of the
  snapshot. Rewind restores all files in a checkpoint to their recorded state,
  including deleting files that did not exist at checkpoint time.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with checkpoints through the hook system
  (`BeamAgent.Hooks`) rather than calling this module directly. The
  `:pre_tool_use` hook fires before file mutations, and `extract_file_paths/2`
  identifies which files a tool will modify.

  ## Quick example

  ```elixir
  # Snapshot files before a mutation:
  {:ok, cp} = BeamAgent.Checkpoint.snapshot(
    "sess_001",
    "uuid_abc123",
    ["/tmp/foo.txt", "/tmp/bar.txt"]
  )

  # Later, rewind to that checkpoint:
  :ok = BeamAgent.Checkpoint.rewind("sess_001", "uuid_abc123")

  # List all checkpoints for a session:
  {:ok, checkpoints} = BeamAgent.Checkpoint.list_checkpoints("sess_001")
  ```

  ## Core concepts

  - **Snapshot**: a frozen record of file state at a point in time. Each file
    records its path, content (or `nil` if it did not exist), existence flag, and
    POSIX permissions.

  - **Checkpoint UUID**: a binary identifier (e.g. a `tool_use_id`) that uniquely
    names a snapshot within a session. Callers choose the UUID so it can be
    correlated with the tool invocation that triggered the checkpoint.

  - **Rewind**: restores every file in a checkpoint to its recorded state. Files
    that existed are written back with their original content and POSIX
    permissions. Files that did not exist are deleted if they were created after
    the checkpoint.

  ## Architecture deep dive

  This module delegates every call to `:beam_agent_checkpoint`. The underlying
  implementation lives in `:beam_agent_checkpoint_core`, which owns the
  `beam_agent_checkpoints` ETS table. The table uses `{session_id, uuid}`
  composite keys in a `set` table with public access, so any process can create
  and query checkpoints without bottlenecking.

  See also: `BeamAgent.Hooks`, `BeamAgent.SessionStore`, `BeamAgent`.
  """

  @typedoc """
  Checkpoint metadata map.

  Contains the `:uuid`, `:session_id`, `:created_at` (unix milliseconds), and a
  `:files` list of `file_snapshot()` records captured at checkpoint time.
  """
  @type checkpoint() :: %{
          required(:uuid) => binary(),
          required(:session_id) => binary(),
          required(:created_at) => integer(),
          required(:files) => [file_snapshot()]
        }

  @typedoc """
  A single file's snapshot within a checkpoint.

  Fields: `:path` (binary), `:content` (binary or `nil` if the file did not
  exist), `:existed` (boolean), `:permissions` (non_neg_integer or `nil`).
  """
  @type file_snapshot() :: %{
          required(:path) => binary(),
          required(:content) => binary() | :undefined,
          required(:existed) => boolean(),
          required(:permissions) => non_neg_integer() | :undefined
        }

  @doc """
  Snapshot a list of file paths for later rewind.

  Reads each file's content and POSIX permissions at the current moment. Files
  that do not exist are recorded as non-existent so that `rewind/2` can delete
  them if they are created after the checkpoint.

  `paths` is a list of binary or string file paths.

  Returns `{:ok, checkpoint}` with the checkpoint metadata map.

  ## Example

  ```elixir
  {:ok, cp} = BeamAgent.Checkpoint.snapshot(
    "sess_001",
    "tool_use_xyz",
    ["/home/user/project/src/main.ex"]
  )
  [%{path: "/home/user/project/src/main.ex", existed: true}] = cp.files
  ```
  """
  @spec snapshot(binary(), binary(), [binary() | String.t()]) :: {:ok, checkpoint()}
  defdelegate snapshot(session_id, uuid, file_paths), to: :beam_agent_checkpoint

  @doc """
  Rewind files to a checkpoint state.

  Restores each file in the checkpoint to its recorded content and permissions.
  Files that did not exist at checkpoint time are deleted if they exist now.

  Returns `:ok` on success, `{:error, :not_found}` if the checkpoint does not
  exist, or `{:error, {:restore_failed, path, reason}}` if a file restore fails.

  ## Example

  ```elixir
  :ok = BeamAgent.Checkpoint.rewind("sess_001", "tool_use_xyz")
  ```
  """
  @spec rewind(binary(), binary()) ::
          :ok | {:error, :not_found | {:restore_failed, binary(), atom()}}
  defdelegate rewind(session_id, uuid), to: :beam_agent_checkpoint

  @doc """
  List all checkpoints for a session, sorted newest first.

  Returns `{:ok, checkpoints}` with checkpoint metadata maps sorted by
  `created_at` descending.

  ## Example

  ```elixir
  {:ok, [%{uuid: latest_uuid} | _]} = BeamAgent.Checkpoint.list_checkpoints("sess_001")
  ```
  """
  @spec list_checkpoints(binary()) :: {:ok, [checkpoint()]}
  defdelegate list_checkpoints(session_id), to: :beam_agent_checkpoint

  @doc """
  Get a specific checkpoint by session ID and UUID.

  Returns `{:ok, checkpoint}` or `{:error, :not_found}`.
  """
  @spec get_checkpoint(binary(), binary()) :: {:ok, checkpoint()} | {:error, :not_found}
  defdelegate get_checkpoint(session_id, uuid), to: :beam_agent_checkpoint

  @doc """
  Delete a checkpoint.

  Removes the checkpoint from the store. This does not affect any files on
  disk — it only removes the stored snapshot data.
  """
  @spec delete_checkpoint(binary(), binary()) :: :ok
  defdelegate delete_checkpoint(session_id, uuid), to: :beam_agent_checkpoint

  @doc """
  Extract file paths from a tool use message for checkpointing.

  Inspects the tool name and input map to determine which files the tool will
  modify. Recognises `Write` and `Edit` tools (and lowercase variants) and
  extracts the `file_path` field.

  Returns a list of binary file paths, or an empty list if the tool is not a
  recognised file-mutating tool.

  ## Example

  ```elixir
  paths = BeamAgent.Checkpoint.extract_file_paths("Write", %{"file_path" => "/tmp/out.ex"})
  # => ["/tmp/out.ex"]
  ```
  """
  @spec extract_file_paths(binary(), map()) :: [binary()]
  defdelegate extract_file_paths(tool_name, tool_input), to: :beam_agent_checkpoint

  @doc """
  Rewind files to a previous checkpoint via a live session.

  Session-scoped variant of `rewind/2`. Takes a running session pid and
  delegates to the backend's native checkpoint rewind if available, falling
  back to the universal checkpoint store.

  ## Parameters

  - `session` -- pid of a running session.
  - `checkpoint_uuid` -- binary checkpoint identifier.

  ## Returns

  - `{:ok, result}` or `{:error, :not_found}`.
  """
  @spec rewind_files(pid(), binary()) :: {:ok, term()} | {:error, :not_found | term()}
  defdelegate rewind_files(session, checkpoint_uuid), to: :beam_agent_checkpoint
end
