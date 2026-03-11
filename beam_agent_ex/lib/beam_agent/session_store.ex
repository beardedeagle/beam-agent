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
  `:beam_agent_session_store` and `:beam_agent` modules. The underlying ETS tables
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
  @spec fork_session(pid(), map()) :: {:ok, session_meta()} | {:error, term()}
  defdelegate fork_session(session_or_id, opts), to: :beam_agent

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
  @spec revert_session(pid(), map()) :: {:ok, session_meta()} | {:error, term()}
  defdelegate revert_session(session_or_id, selector), to: :beam_agent

  @doc """
  Clear revert state and restore the full visible history.

  Removes the `visible_message_count` boundary from the session view, making all
  recorded messages visible again.

  Returns `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec unrevert_session(pid()) :: {:ok, session_meta()} | {:error, term()}
  defdelegate unrevert_session(session_or_id), to: :beam_agent

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
  @spec share_session(pid()) :: {:ok, session_share()} | {:error, term()}
  defdelegate share_session(session_or_id), to: :beam_agent

  @doc """
  Generate a share token for a session with options.

  `opts` may include `:share_id` for an explicit share ID (auto-generated if
  omitted).

  Returns `{:ok, share}` with the active share map, or `{:error, :not_found}`.
  """
  @spec share_session(pid(), map()) :: {:ok, session_share()} | {:error, term()}
  defdelegate share_session(session_or_id, opts), to: :beam_agent

  @doc """
  Revoke the current share for a session.

  Marks the session share as revoked with a `revoked_at` timestamp.

  Returns `:ok` on success or `{:error, :not_found}`.
  """
  @spec unshare_session(pid()) :: :ok | {:error, term()}
  defdelegate unshare_session(session_or_id), to: :beam_agent

  @doc """
  Generate and store a summary for a session.

  Builds a deterministic text summary from the session message history and stores
  it in the session `extra.summary` field. Equivalent to calling
  `summarize_session/2` with an empty opts map.

  Returns `{:ok, summary}` or `{:error, :not_found}`.
  """
  @spec summarize_session(pid()) :: {:ok, session_summary()} | {:error, term()}
  defdelegate summarize_session(session_or_id), to: :beam_agent

  @doc """
  Generate and store a summary for a session with options.

  `opts` may include:
  - `:content` or `:summary` — explicit summary text (auto-derived if omitted)
  - `:generated_by` — identifier for the summary generator

  Returns `{:ok, summary}` or `{:error, :not_found}`.
  """
  @spec summarize_session(pid(), map()) :: {:ok, session_summary()} | {:error, term()}
  defdelegate summarize_session(session_or_id, opts), to: :beam_agent

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
end
