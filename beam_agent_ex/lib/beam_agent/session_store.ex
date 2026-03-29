defmodule BeamAgent.SessionStore do
  @moduledoc """
  Unified session history store for the BeamAgent SDK.

  This module provides ETS-backed session tracking and message history across all
  five agentic coder backends (Claude, Codex, Gemini, OpenCode, Copilot). Every
  adapter records messages here regardless of whether the underlying CLI has native
  session history support, giving callers a single consistent interface for session
  management.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with sessions through `BeamAgent`. Use this module directly
  when you need fine-grained control over session metadata, message querying,
  forking, sharing, or summarization — for example, in a custom session supervisor
  or an audit trail consumer.

  ## Quick example

  ```elixir
  # List all sessions sorted by most-recently updated:
  {:ok, sessions} = BeamAgent.SessionStore.list_sessions()

  # Filter to recent Claude sessions:
  {:ok, recent} = BeamAgent.SessionStore.list_sessions(%{
    adapter: :claude,
    limit: 10,
    since: System.os_time(:millisecond) - 3_600_000
  })

  # Fetch messages for a specific session:
  {:ok, messages} = BeamAgent.SessionStore.get_session_messages("sess_abc123")

  # Fork a session for safe experimentation:
  {:ok, fork} = BeamAgent.SessionStore.fork_session("sess_abc123", %{})
  IO.inspect(fork.session_id)
  ```

  ## Core concepts

  - **Session metadata**: each session is identified by a binary session ID and
    carries metadata such as the adapter name, model, working directory, timestamps,
    and a message count.

  - **Message recording**: messages are stored with auto-incrementing sequence
    numbers that preserve insertion order and enable efficient per-session queries.

  - **Forking**: `fork_session/2` creates a deep copy of a session (metadata and
    all messages) under a new session ID, recording the parent relationship in the
    `extra.fork` field.

  - **Sharing**: `share_session/1` generates a share ID that marks the session as
    externally visible. `unshare_session/1` revokes access.

  - **Reverting**: `revert_session/2` hides messages beyond a boundary without
    deleting them; `unrevert_session/1` restores the full view.

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the Erlang
  `:beam_agent_session_store` module. The underlying ETS tables
  (`beam_agent_sessions`, `beam_agent_session_messages`, `beam_agent_session_counters`)
  are public and named so any process can read and write without bottlenecking on a
  single owner. Tables are created lazily on first access and persist for the
  lifetime of the BEAM node.

  See also: `BeamAgent.Threads`, `BeamAgent.Checkpoint`, `BeamAgent`.
  """

  @typedoc """
  Session metadata map.

  Contains the session ID, adapter name, model, working directory, creation and
  update timestamps, message count, and an optional `extra` map for fork/share/
  summary/view state.
  """
  @type session_meta() :: %{
          required(:session_id) => binary(),
          optional(:adapter) => atom(),
          optional(:model) => binary(),
          optional(:cwd) => binary(),
          optional(:created_at) => integer(),
          optional(:updated_at) => integer(),
          optional(:message_count) => non_neg_integer(),
          optional(:extra) => map()
        }

  @typedoc """
  Options for filtering session listings.

  Supported keys: `adapter` (atom), `cwd` (binary), `model` (binary),
  `limit` (pos_integer), `since` (unix millisecond timestamp).
  """
  @type list_opts() :: %{
          optional(:adapter) => atom(),
          optional(:cwd) => binary(),
          optional(:model) => binary(),
          optional(:limit) => pos_integer(),
          optional(:since) => integer()
        }

  @typedoc """
  Options for querying session messages.

  Supported keys: `limit` (pos_integer), `offset` (non_neg_integer),
  `types` (list of message type atoms), `include_hidden` (boolean).
  """
  @type message_opts() :: %{
          optional(:limit) => pos_integer(),
          optional(:offset) => non_neg_integer(),
          optional(:types) => [atom()],
          optional(:include_hidden) => boolean()
        }

  @typedoc """
  Versioned session snapshot for export/import.

  Contains `:version` (always `1`), `:session_id`, `:metadata` (session
  metadata), `:messages` (all messages including hidden ones), and
  `:exported_at` (unix millisecond timestamp).
  """
  @type exported_session() :: %{
          required(:version) => 1,
          required(:session_id) => binary(),
          required(:metadata) => session_meta(),
          required(:messages) => [message()],
          required(:exported_at) => integer()
        }

  @typedoc """
  Options for `import_session/2`.

  Supported keys: `:session_id` (override the imported session's ID).
  """
  @type import_opts() :: %{optional(:session_id) => binary()}

  @typedoc "A session message record with a required `:type` key and optional wire fields."
  @type message() :: %{
          required(:type) => atom(),
          optional(:content) => binary(),
          optional(:tool_name) => binary(),
          optional(:tool_input) => map(),
          optional(:raw) => map(),
          optional(:timestamp) => integer(),
          optional(:uuid) => binary(),
          optional(:session_id) => binary(),
          optional(:content_blocks) => [map()],
          optional(:parent_tool_use_id) => binary() | nil,
          optional(:tool_use_id) => binary(),
          optional(:message_id) => binary(),
          optional(:model) => binary(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:duration_api_ms) => non_neg_integer(),
          optional(:error_info) => map()
        }

  @typedoc """
  Share state for a session.

  Contains the share ID, session ID, creation timestamp, status (`:active` or
  `:revoked`), and an optional `revoked_at` timestamp.
  """
  @type session_share() :: %{
          required(:share_id) => binary(),
          required(:session_id) => binary(),
          required(:created_at) => integer(),
          required(:status) => :active | :revoked,
          optional(:revoked_at) => integer()
        }

  @typedoc """
  Active share state returned by `share_session/1` and `share_session/2`.
  """
  @type active_session_share() :: %{
          required(:share_id) => binary(),
          required(:session_id) => binary(),
          required(:created_at) => integer(),
          required(:status) => :active
        }

  @typedoc """
  Summary of a session's conversation history.

  Contains the session ID, generated content, generation timestamp, message count
  at generation time, and the generator identifier.
  """
  @type session_summary() :: %{
          required(:session_id) => binary(),
          required(:content) => binary(),
          required(:generated_at) => integer(),
          required(:message_count) => non_neg_integer(),
          required(:generated_by) => binary()
        }

  # -------------------------------------------------------------------
  # Table Lifecycle
  # -------------------------------------------------------------------

  @doc """
  Ensure all session store tables exist.

  Creates the `beam_agent_sessions`, `beam_agent_session_messages`, and
  `beam_agent_session_counters` tables if they do not already exist. This
  function is idempotent and safe to call from any process at any time.

  Most functions in this module call `ensure_tables/0` internally, so
  explicit calls are only needed when you want to guarantee table existence
  before entering a hot path.

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.ensure_tables()
  ```
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_session_store

  @doc """
  Clear all session data from the store.

  Deletes every entry from the sessions, messages, and counters tables.
  The tables themselves remain in place. This is a destructive operation
  intended for test teardown or full resets.

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.clear()
  ```
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_session_store

  # -------------------------------------------------------------------
  # Session Metadata
  # -------------------------------------------------------------------

  @doc """
  Register a new session with metadata.

  Creates a session entry in the store with the given `session_id` and
  metadata map. If a session with this ID already exists, this is a no-op
  (use `update_session/2` to modify existing sessions).

  The store automatically populates `created_at`, `updated_at`, and
  `message_count` fields. Any values provided in `meta` for these fields
  are used as defaults.

  ## Parameters

  - `session_id` -- binary session identifier (e.g. `"sess_abc123"`)
  - `meta` -- map of initial metadata (`:adapter`, `:model`, `:cwd`, `:extra`, etc.)

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.register_session("sess_001", %{
    adapter: :claude,
    model: "claude-sonnet-4-20250514",
    cwd: "/home/user/project"
  })
  ```
  """
  @spec register_session(binary(), map()) :: :ok | {:error, :session_limit_reached}
  defdelegate register_session(session_id, meta), to: :beam_agent_session_store

  @doc """
  Update an existing session's metadata.

  Merges the provided fields into the existing session metadata and refreshes
  the `updated_at` timestamp. If the session does not exist, it is created
  via `register_session/2`.

  ## Parameters

  - `session_id` -- binary session identifier
  - `patch` -- map of fields to merge into the existing metadata

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.update_session("sess_001", %{
    model: "claude-opus-4-20250514"
  })
  ```
  """
  @spec update_session(binary(), map()) :: :ok
  defdelegate update_session(session_id, patch), to: :beam_agent_session_store

  @doc """
  List all sessions in the store, sorted by most-recently updated.

  Returns `{:ok, sessions}` with all session metadata maps. Equivalent to
  calling `list_sessions(%{})`.

  ## Example

  ```elixir
  iex> {:ok, sessions} = BeamAgent.SessionStore.list_sessions()
  iex> is_list(sessions)
  true
  ```
  """
  @spec list_sessions() :: {:ok, [session_meta()]}
  defdelegate list_sessions(), to: :beam_agent_session_store

  @doc """
  List sessions with optional filters.

  Returns sessions matching all provided filter criteria, sorted by `updated_at`
  descending.

  `opts` is a map with optional keys:
  - `:adapter` — only sessions using this adapter (atom)
  - `:cwd` — only sessions with this working directory (binary)
  - `:model` — only sessions using this model (binary)
  - `:limit` — maximum number of results (pos_integer)
  - `:since` — only sessions updated at or after this timestamp (unix ms)

  ## Example

  ```elixir
  {:ok, recent} = BeamAgent.SessionStore.list_sessions(%{
    adapter: :claude,
    limit: 5
  })
  ```
  """
  @spec list_sessions(list_opts()) :: {:ok, [session_meta()]}
  defdelegate list_sessions(opts), to: :beam_agent_session_store

  @doc """
  Get metadata for a specific session.

  Returns `{:ok, meta}` with the session metadata map, or
  `{:error, :not_found}` if no session with this ID exists.

  ## Example

  ```elixir
  {:ok, meta} = BeamAgent.SessionStore.get_session("sess_001")
  meta.model
  ```
  """
  @spec get_session(binary()) :: {:ok, session_meta()} | {:error, :not_found}
  defdelegate get_session(session_id), to: :beam_agent_session_store

  @doc """
  Delete a session and all its messages.

  Removes the session metadata, message counter, and every recorded message for
  this session from the store. Also fires a completion event via
  `:beam_agent_events`.
  """
  @spec delete_session(binary()) :: :ok
  defdelegate delete_session(session_id), to: :beam_agent_session_store

  @doc """
  Fork (deep copy) an existing session.

  Creates a new session with copies of all metadata and messages from the source
  session. The new session records its lineage in the `extra.fork` field
  (`parent_session_id`, `forked_at`).

  `opts` may include:
  - `:session_id` — explicit ID for the fork (auto-generated if omitted)
  - `:include_hidden` — whether to copy hidden (reverted) messages (default `true`)
  - `:extra` — additional metadata to merge into the fork

  Returns `{:ok, fork_meta}` with the new session metadata, or
  `{:error, :not_found}` if the source session does not exist.

  ## Example

  ```elixir
  {:ok, fork} = BeamAgent.SessionStore.fork_session("sess_001", %{
    session_id: "sess_fork_001"
  })
  fork.session_id  # => "sess_fork_001"
  ```
  """
  @spec fork_session(binary(), map()) ::
          {:ok, session_meta()}
          | {:error, :not_found}
  defdelegate fork_session(session_id, opts), to: :beam_agent_session_store

  @doc """
  Revert the visible conversation to a prior message boundary.

  Hides messages beyond the specified boundary without deleting them. The
  underlying message store remains append-only; revert changes the active view by
  storing a `visible_message_count` in the session `extra.view` field.

  `selector` is a map with one of:
  - `:visible_message_count` — set the boundary to exactly N messages
  - `:message_id` or `:uuid` — set the boundary to a specific message

  Returns `{:ok, updated_meta}`, `{:error, :not_found}`, or
  `{:error, :invalid_selector}`.
  """
  @spec revert_session(binary(), map()) ::
          {:ok, session_meta()} | {:error, :invalid_selector | :not_found}
  defdelegate revert_session(session_id, selector), to: :beam_agent_session_store

  @doc """
  Clear revert state and restore the full visible history.

  Removes the `visible_message_count` boundary from the session view, making all
  recorded messages visible again.

  Returns `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec unrevert_session(binary()) :: {:ok, session_meta()} | {:error, :not_found}
  defdelegate unrevert_session(session_id), to: :beam_agent_session_store

  @doc """
  Generate a share token for a session.

  Creates an active share record with a generated share ID and stores it in the
  session `extra.share` field.

  Returns `{:ok, share}` with the share map, or `{:error, :not_found}`.

  ## Example

  ```elixir
  {:ok, share} = BeamAgent.SessionStore.share_session("sess_001")
  share.share_id
  ```
  """
  @spec share_session(binary()) :: {:ok, active_session_share()} | {:error, :not_found}
  defdelegate share_session(session_id), to: :beam_agent_session_store

  @doc """
  Generate a share token for a session with options.

  `opts` may include `:share_id` for an explicit share ID (auto-generated if
  omitted).

  Returns `{:ok, share}` with the active share map, or `{:error, :not_found}`.
  """
  @spec share_session(binary(), map()) :: {:ok, active_session_share()} | {:error, :not_found}
  defdelegate share_session(session_id, opts), to: :beam_agent_session_store

  @doc """
  Revoke the current share for a session.

  Marks the session share as revoked with a `revoked_at` timestamp.

  Returns `:ok` on success or `{:error, :not_found}`.
  """
  @spec unshare_session(binary()) :: :ok | {:error, :not_found}
  defdelegate unshare_session(session_id), to: :beam_agent_session_store

  @doc """
  Get the current share state for a session.

  Returns `{:ok, share}` with the share map (which may have status `:active`
  or `:revoked`), or `{:error, :not_found}` if the session has no share
  record.

  ## Example

  ```elixir
  {:ok, share} = BeamAgent.SessionStore.get_share("sess_001")
  share.status  # => :active
  ```
  """
  @spec get_share(binary()) :: {:ok, session_share()} | {:error, :not_found}
  defdelegate get_share(session_id), to: :beam_agent_session_store

  @doc """
  Generate and store a summary for a session.

  Builds a deterministic text summary from the session message history and stores
  it in the session `extra.summary` field. Equivalent to calling
  `summarize_session/2` with an empty opts map.

  Returns `{:ok, summary}` or `{:error, :not_found}`.
  """
  @spec summarize_session(binary()) :: {:ok, session_summary()} | {:error, :not_found}
  defdelegate summarize_session(session_id), to: :beam_agent_session_store

  @doc """
  Generate and store a summary for a session with options.

  `opts` may include:
  - `:content` or `:summary` — explicit summary text (auto-derived if omitted)
  - `:generated_by` — identifier for the summary generator

  Returns `{:ok, summary}` or `{:error, :not_found}`.
  """
  @spec summarize_session(binary(), map()) :: {:ok, session_summary()} | {:error, :not_found}
  defdelegate summarize_session(session_id, opts), to: :beam_agent_session_store

  @doc """
  Get the stored summary for a session.

  Returns `{:ok, summary}` with the summary map, or `{:error, :not_found}`
  if the session has no stored summary.

  ## Example

  ```elixir
  {:ok, summary} = BeamAgent.SessionStore.get_summary("sess_001")
  summary.content
  ```
  """
  @spec get_summary(binary()) :: {:ok, session_summary()} | {:error, :not_found}
  defdelegate get_summary(session_id), to: :beam_agent_session_store

  # -------------------------------------------------------------------
  # Message Storage
  # -------------------------------------------------------------------

  @doc """
  Record a single message for a session.

  Stores the message with an auto-incrementing sequence number for ordering
  and updates the session metadata (message count, timestamps, model
  extraction). If the session has not been registered, a minimal session
  entry is auto-created.

  Also publishes the message via `:beam_agent_events` for live subscribers.

  ## Parameters

  - `session_id` -- binary session identifier
  - `message` -- a message map with at least a `:type` key

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.record_message("sess_001", %{
    type: :assistant,
    content: "Hello!"
  })
  ```
  """
  @spec record_message(binary(), message()) :: :ok | {:error, :message_limit_reached}
  defdelegate record_message(session_id, message), to: :beam_agent_session_store

  @doc """
  Record multiple messages for a session in order.

  Convenience function that calls `record_message/2` for each message in the
  list, preserving the given order.

  ## Parameters

  - `session_id` -- binary session identifier
  - `messages` -- list of message maps

  ## Example

  ```elixir
  :ok = BeamAgent.SessionStore.record_messages("sess_001", [
    %{type: :user, content: "Hi"},
    %{type: :assistant, content: "Hello!"}
  ])
  ```
  """
  @spec record_messages(binary(), [message()]) :: :ok | {:error, :message_limit_reached}
  defdelegate record_messages(session_id, messages), to: :beam_agent_session_store

  @doc """
  Get all messages for a session in recording order.

  Returns `{:ok, messages}` or `{:error, :not_found}`.
  """
  @spec get_session_messages(binary()) ::
          {:ok, [message()]} | {:error, :not_found}
  defdelegate get_session_messages(session_id), to: :beam_agent_session_store

  @doc """
  Get messages for a session with filtering options.

  `opts` may include:
  - `:limit` — maximum number of messages (pos_integer)
  - `:offset` — messages to skip from the start (non_neg_integer)
  - `:types` — only include messages of these types (list of atoms)
  - `:include_hidden` — if `true`, include messages hidden by revert (boolean)

  Returns `{:ok, messages}` or `{:error, :not_found}`.
  """
  @spec get_session_messages(binary(), message_opts()) ::
          {:ok, [message()]} | {:error, :not_found}
  defdelegate get_session_messages(session_id, opts), to: :beam_agent_session_store

  @doc """
  List sessions from the backend's native session store.

  Attempts to call the backend's native session listing. Falls back to
  `list_sessions/0` if the backend does not support native session listing.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  @spec list_native_sessions() :: {:ok, [session_meta()]} | {:error, term()}
  defdelegate list_native_sessions(), to: :beam_agent_session_store

  @doc """
  List sessions from the backend's native session store with filters.

  Like `list_native_sessions/0` but passes filter options to the native call.
  Falls back to `list_sessions/1` if native listing is not supported.

  ## Parameters

  - `opts` -- backend-specific filter options map.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
  @spec list_native_sessions(map()) :: {:ok, [session_meta()]} | {:error, term()}
  defdelegate list_native_sessions(opts), to: :beam_agent_session_store

  @doc """
  Get messages from the backend's native session store.

  Falls back to `get_session_messages/1` if native message retrieval is
  not supported by the backend.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  @spec get_native_session_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  defdelegate get_native_session_messages(session_id), to: :beam_agent_session_store

  @doc """
  Get messages from the backend's native session store with options.

  Falls back to `get_session_messages/2` if native retrieval is not supported.

  ## Parameters

  - `session_id` -- binary session identifier.
  - `opts` -- backend-specific message filter options.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  @spec get_native_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, term()}
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent_session_store

  # -------------------------------------------------------------------
  # Convenience
  # -------------------------------------------------------------------

  @doc """
  Get the total number of tracked sessions.

  Returns the count of session entries in the store.

  ## Example

  ```elixir
  count = BeamAgent.SessionStore.session_count()
  ```
  """
  @spec session_count() :: non_neg_integer()
  defdelegate session_count(), to: :beam_agent_session_store

  @doc """
  Get the recorded message count for a specific session.

  Returns the number of messages stored for this session. Returns `0` if the
  session does not exist or has no messages.

  ## Example

  ```elixir
  count = BeamAgent.SessionStore.message_count("sess_001")
  ```
  """
  @spec message_count(binary()) :: non_neg_integer()
  defdelegate message_count(session_id), to: :beam_agent_session_store

  # -------------------------------------------------------------------
  # Export / Import
  # -------------------------------------------------------------------

  @doc """
  Export a session to a versioned, portable snapshot.

  Returns the session metadata and all messages (including hidden) in a
  version-1 map. The result can be serialized with `:erlang.term_to_binary/1`
  or converted to JSON for transport.

  Returns `{:error, :not_found}` if the session does not exist.

  ## Example

  ```elixir
  {:ok, snapshot} = BeamAgent.SessionStore.export_session("sess_001")
  snapshot.version  # => 1
  ```
  """
  @spec export_session(binary()) :: {:ok, exported_session()} | {:error, :not_found}
  defdelegate export_session(session_id), to: :beam_agent_session_store

  @doc """
  Import a session from a previously exported snapshot.

  Equivalent to `import_session(exported, %{})`.

  ## Example

  ```elixir
  {:ok, snapshot} = BeamAgent.SessionStore.export_session("sess_001")
  {:ok, meta} = BeamAgent.SessionStore.import_session(snapshot)
  ```
  """
  @spec import_session(exported_session()) :: {:ok, session_meta()} | {:error, term()}
  defdelegate import_session(exported), to: :beam_agent_session_store

  @doc """
  Import a session from a previously exported snapshot with options.

  ## Options

  - `:session_id` -- override the session ID (default: use the exported ID)

  The session metadata is preserved including the original `created_at`
  timestamp. Messages are re-recorded in order, which assigns fresh sequence
  numbers and updates the message count.

  Returns `{:error, :invalid_export_format}` if the map is not a valid
  version-1 export.

  ## Example

  ```elixir
  {:ok, snapshot} = BeamAgent.SessionStore.export_session("sess_001")
  {:ok, meta} = BeamAgent.SessionStore.import_session(snapshot, %{
    session_id: "sess_copy_001"
  })
  meta.session_id  # => "sess_copy_001"
  ```
  """
  @spec import_session(exported_session(), import_opts()) ::
          {:ok, session_meta()} | {:error, term()}
  defdelegate import_session(exported, opts), to: :beam_agent_session_store
end
