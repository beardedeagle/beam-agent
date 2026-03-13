defmodule BeamAgent do
  @moduledoc """
  Unified public API for the BeamAgent SDK -- an Elixir/OTP wrapper around five
  agentic coder backends: Claude, Codex, Gemini, OpenCode, and Copilot.

  `BeamAgent` is the primary entry point for session lifecycle, queries,
  streaming, threads, and session history. Domain-specific features --
  skills, apps, files, MCP, accounts, search, configuration, and more --
  live in focused submodules (see Submodules below) and work identically
  across all five backends thanks to native-first routing with universal
  fallbacks.

  ## Quick Start

  Start a session, send a query, and process the response:

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, messages} = BeamAgent.query(session, "What is the BEAM?")

      for %{content: content} <- messages do
        IO.puts(content)
      end

      :ok = BeamAgent.stop(session)

  ## Streaming with Events

  Subscribe to events before sending a query for real-time streaming:

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, ref} = BeamAgent.event_subscribe(session)
      {:ok, _messages} = BeamAgent.query(session, "Explain OTP")

      defp loop(session, ref) do
        case BeamAgent.receive_event(session, ref, 10_000) do
          {:ok, %{type: :result}} ->
            IO.puts("Done.")

          {:ok, %{type: :text, content: content}} ->
            IO.write(content)
            loop(session, ref)

          {:ok, _other} ->
            loop(session, ref)

          {:error, :complete} ->
            IO.puts("Stream complete.")

          {:error, :timeout} ->
            IO.puts("Timed out.")
        end
      end

  Or use the convenience `stream!/3` function for an `Enumerable`:

      session
      |> BeamAgent.stream!("Explain GenServer")
      |> Enum.each(fn msg -> IO.write(msg[:content] || "") end)

  ## Key Concepts

  ### Sessions

  A session is a supervised `gen_statem` process that owns a single transport
  connection to a backend CLI. Sessions are started with `start_session/1`
  and stopped with `stop/1`. Each session has a unique binary `session_id`,
  tracks message history, and can host multiple conversation threads.

  ### Events

  Events provide a streaming view of session activity. Call
  `event_subscribe/1` to register the calling process as a subscriber,
  then `receive_event/2` to pull events one at a time. Events are
  delivered as normalized `t:message/0` maps. The stream ends with an
  `{:error, :complete}` sentinel after a result or error message.

  ### Threads

  Threads group related queries into named conversation contexts within
  a session. Use `thread_start/2` to create a thread, `thread_resume/2` to
  switch to it, and `thread_list/1` to enumerate threads. Each thread
  tracks its own message history as a subset of the session history.

  ### Hooks

  SDK-level lifecycle hooks fire at well-defined points (session start,
  query start, tool use, etc.). Pass hook definitions in session opts
  via the `:sdk_hooks` key. Hooks run in-process and cannot block the
  engine state machine.

  ### MCP (Model Context Protocol)

  MCP lets you define custom tools as Erlang/Elixir functions that the
  backend can invoke in-process. See `BeamAgent.MCP` for server
  registration, status inspection, and runtime toggling.

  ### Providers

  Providers represent authentication/API endpoints for a backend. See
  `BeamAgent.Provider` for provider selection and OAuth flows. Provider
  management is most relevant for backends that support multiple API
  endpoints (e.g., OpenCode with different LLM providers).

  ## Architecture

  Every public function in this module follows the `native_or` routing
  pattern: it first attempts the backend's native implementation, and if
  the backend returns `{:error, {:unsupported_native_call, _}}`, it falls
  back to a universal implementation in one of the core modules.

  The call chain is: `BeamAgent` -> `:beam_agent` -> `:beam_agent_core` ->
  `:beam_agent_router` -> `:beam_agent_session_engine` -> backend handler.
  This thin wrapper design means `BeamAgent` contains zero business logic --
  it is purely a delegation layer.

  ## Submodules

  Domain-specific functions are organized into focused submodules.
  `BeamAgent` retains session lifecycle, streaming, and convenience wrappers.

  - `BeamAgent.Account` -- authentication, login/logout, rate limits
  - `BeamAgent.Apps` -- project/app management and modes
  - `BeamAgent.Capabilities` -- backend capability matrix and checks
  - `BeamAgent.Catalog` -- tools, skills, plugins, agents, models, commands
  - `BeamAgent.Checkpoint` -- file checkpoint and rewind operations
  - `BeamAgent.Command` -- shell commands, session messages, async prompts
  - `BeamAgent.Config` -- session configuration read/write
  - `BeamAgent.Control` -- turn steering, realtime, reviews, server management
  - `BeamAgent.File` -- file search, read, list, and status
  - `BeamAgent.Hooks` -- SDK lifecycle hook definitions and dispatch
  - `BeamAgent.MCP` -- MCP server/tool registration and management
  - `BeamAgent.Provider` -- LLM provider selection, OAuth flows
  - `BeamAgent.Raw` -- escape-hatch functions for backend-native calls
  - `BeamAgent.Runtime` -- runtime state, model/mode switching, interrupts
  - `BeamAgent.Search` -- fuzzy file search sessions
  - `BeamAgent.SessionStore` -- session history storage and retrieval
  - `BeamAgent.Skills` -- skill listing, remote export, configuration
  - `BeamAgent.Threads` -- thread management within sessions

  ## Core concepts

  - **Sessions**: A session is a connection to one AI backend. You start one,
    send queries, and stop it when done. Think of it like a phone call to an AI.
  - **The five backends**: BeamAgent wraps Claude, Codex, Gemini, OpenCode, and
    Copilot. You pick one when starting a session, but the API is the same for
    all of them.
  - **Queries**: `query/2` sends a prompt and waits for the complete response.
    `event_subscribe/1` + `receive_event/2` gives you streaming responses piece
    by piece.
  - **Session pid**: Every session is an Erlang process. The `pid` you get from
    `start_session/1` is how you talk to it. Pass it as the first argument to
    every function.
  - **Native-first routing**: Most functions try the backend's own implementation
    first. If the backend doesn't support a feature natively, BeamAgent uses a
    universal OTP-based fallback. You don't need to think about this — it just
    works.

  ## Architecture deep dive

  - **Delegation chain**: `BeamAgent` delegates to `:beam_agent` (Erlang), which
    delegates to `:beam_agent_core`, which routes through
    `:beam_agent_session_engine` (a `gen_statem`) to the backend handler. Zero
    business logic lives in `BeamAgent` or `:beam_agent`.
  - **Session engine**: Each session is a single `gen_statem` process that owns
    the transport (Erlang port, HTTP client, or WebSocket). No additional
    processes are spawned per session.
  - **native_or pattern**: The Erlang `native_or/4` macro tries
    `AdapterModule:Function(Session, Args...)` and falls back to a closure if
    the adapter doesn't export the function. Universal fallbacks use ETS-backed
    core modules (`beam_agent_*_core`).
  - **Transport architecture**: Three transport types --
    `beam_agent_transport_port` (stdio), `beam_agent_transport_http`
    (HTTP), and `beam_agent_transport_ws` (WebSocket). The handler's
    `init_handler/1` callback selects the transport.
  - **Thick framework, thin adapters**: The session engine handles lifecycle,
    queuing, telemetry, buffering, and consumer management. Backend handlers
    only implement protocol encoding/decoding and message normalization.
  """

  @typedoc """
  Backend identifier atom.

  One of `:claude`, `:codex`, `:gemini`, `:opencode`, or `:copilot`.
  Used throughout the SDK to select which backend adapter handles a session.
  """
  @type backend :: :beam_agent.backend()

  @typedoc """
  The normalized message type tag.

  Values: `:text`, `:assistant`, `:tool_use`, `:tool_result`, `:system`,
  `:result`, `:error`, `:user`, `:control`, `:control_request`,
  `:control_response`, `:stream_event`, `:rate_limit_event`,
  `:tool_progress`, `:tool_use_summary`, `:thinking`, `:auth_status`,
  `:prompt_suggestion`, `:raw`.

  The `:result` type signals query completion. The `:error` type signals
  a backend error. The `:raw` type preserves unrecognized wire messages
  for forward compatibility.
  """
  @type message_type :: :beam_agent.message_type()

  @typedoc """
  Normalized stop reason from the backend.

  Values: `:end_turn` (normal completion), `:max_tokens` (output truncated),
  `:stop_sequence` (custom stop sequence hit), `:refusal` (model declined),
  `:tool_use_stop` (stopped for tool use), `:unknown_stop` (unrecognized).
  Parsed from the binary wire format into atoms for pattern matching.
  """
  @type stop_reason :: :beam_agent.stop_reason()

  @typedoc """
  Permission mode controlling tool and edit approval.

  Values: `:default` (normal approval flow), `:accept_edits` (auto-approve
  file edits), `:bypass_permissions` (approve everything),
  `:plan` (read-only planning mode), `:dont_ask` (TypeScript SDK only,
  auto-approve without prompting).
  """
  @type permission_mode :: :beam_agent.permission_mode()

  @typedoc """
  A normalized message map flowing through the SDK.

  Every message carries a required `:type` field (see `t:message_type/0`) and
  optional fields that vary by type. Common fields present on most messages:
  `:uuid` (unique identifier), `:session_id`, `:content`, and `:timestamp`.

  Result messages additionally carry `:duration_ms`, `:num_turns`,
  `:stop_reason_atom`, `:usage`, and `:total_cost_usd`. Tool-use messages
  carry `:tool_name` and `:tool_input`.
  """
  @type message :: :beam_agent.message()

  @typedoc """
  Result from a permission handler callback.

  Variants:
  - `{:allow, updated_input}` -- approve with optional input modifications
  - `{:deny, reason}` -- deny with a human-readable reason
  - `{:deny, reason, interrupt}` -- deny and request turn interruption
  - `{:allow, updated_input, rule_update}` -- approve with rule/permission updates
  - `map()` -- richer structured result with keys like `:behavior`,
    `:updated_input`, `:updated_permissions`, `:message`, and `:interrupt`
  """
  @type permission_result :: :beam_agent.permission_result()

  @typedoc """
  Function that pulls the next message from a session event stream.

  Signature: `fun(session, ref, timeout) -> {:ok, message()} | {:error, term()}`.
  Used by `collect_messages/4` and `collect_messages/5` to abstract the
  message retrieval mechanism.
  """
  @type receive_fun :: :beam_agent.receive_fun()

  @typedoc """
  Predicate that determines if a message terminates collection.

  Returns `true` for messages that should halt the `collect_messages` loop
  (the halting message is included in the result list). Returns `false`
  for messages that should continue collection. The default predicate
  checks for `type: :result`.
  """
  @type terminal_pred :: :beam_agent.terminal_pred()

  @typedoc """
  Session metadata map returned by `list_sessions/0` and related functions.

  Contains `:session_id`, `:adapter`, `:created_at`, `:cwd`, `:extra`,
  `:message_count`, `:model`, and `:updated_at` fields.
  """
  @type session_info_map :: %{
          :session_id => binary(),
          :adapter => atom(),
          :created_at => integer(),
          :cwd => binary(),
          :extra => map(),
          :message_count => non_neg_integer(),
          :model => binary(),
          :updated_at => integer()
        }

  @typedoc """
  Share metadata map returned by `share_session/1` and `share_session/2`.

  Contains `:created_at`, `:session_id`, `:share_id`, `:status`, and
  `:revoked_at` fields.
  """
  @type share_info_map :: %{
          :created_at => integer(),
          :session_id => binary(),
          :share_id => binary(),
          :status => :active | :revoked,
          :revoked_at => integer()
        }

  @typedoc """
  Summary metadata map returned by `summarize_session/1` and `summarize_session/2`.

  Contains `:content`, `:generated_at`, `:generated_by`, `:message_count`,
  and `:session_id` fields.
  """
  @type summary_info_map :: %{
          :content => binary(),
          :generated_at => integer(),
          :generated_by => binary(),
          :message_count => non_neg_integer(),
          :session_id => binary()
        }

  # ---------------------------------------------------------------------------
  # Session Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Initialize ETS tables with default settings (public access).

  Equivalent to `init(%{})`. Must be called before any SDK functions that
  touch ETS. This is idempotent -- calling it again after initialization is
  a no-op.

  ## Examples

      :ok = BeamAgent.init()
  """
  defdelegate init(), to: :beam_agent

  @doc """
  Initialize ETS tables with the given options.

  ## Options

  - `:table_access` -- `:public` (default) or `:hardened`

  In `:public` mode, all tables use public access. Any process can read and
  write. In `:hardened` mode, a linked helper process is spawned to own
  protected tables and proxy writes, while reads remain zero-cost from any
  process.

  This function is idempotent. Calling it again after initialization is a
  no-op that returns `:ok`. Should be called early in the consumer's `init/1`
  callback, before any SDK functions that touch ETS.

  ## Examples

      :ok = BeamAgent.init(%{table_access: :hardened})
  """
  defdelegate init(opts), to: :beam_agent

  @doc """
  Start a new agent session connected to a backend.

  Launches a supervised `gen_statem` process that owns a transport connection
  to the specified backend CLI. The session is ready to accept queries once
  this call returns successfully.

  ## Parameters

  - `opts` -- session configuration map. The `:backend` key is required and
    must be one of `:claude`, `:codex`, `:gemini`, `:opencode`, or `:copilot`.

  ## Returns

  - `{:ok, pid}` on success where `pid` is the session process.
  - `{:error, reason}` if the session could not be started.

  ## Examples

      {:ok, session} = BeamAgent.start_session(%{
        backend: :claude,
        model: "claude-sonnet-4-20250514",
        system_prompt: "You are a helpful assistant.",
        permission_mode: :default
      })
  """
  defdelegate start_session(opts), to: :beam_agent

  @doc """
  Build a supervisor child spec for embedding a session in a supervision tree.

  Returns an OTP child_spec map suitable for passing to
  `Supervisor.start_child/2` or including in a supervisor `init/1` return value.

  ## Parameters

  - `opts` -- session configuration map (same as `start_session/1`).

  ## Examples

      child_spec = BeamAgent.child_spec(%{backend: :claude})
      {:ok, _pid} = Supervisor.start_child(MySupervisor, child_spec)
  """
  defdelegate child_spec(opts), to: :beam_agent

  @doc """
  Stop a running session and close its transport connection.

  Gracefully shuts down the session `gen_statem`, closes the underlying
  transport (port, HTTP, or WebSocket), and cleans up session state.

  ## Parameters

  - `session` -- pid of a running session process.

  ## Returns

  `:ok`
  """
  defdelegate stop(session), to: :beam_agent

  @doc """
  Send a synchronous query to the session with default parameters.

  Blocks until the backend produces a complete response (a result-type
  message). All intermediate messages (text chunks, tool use, thinking,
  etc.) are collected and returned as a list.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.

  ## Returns

  - `{:ok, messages}` where `messages` is a list of normalized `t:message/0`
    maps in chronological order.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, session} = BeamAgent.start_session(%{backend: :claude})
      {:ok, messages} = BeamAgent.query(session, "What is Erlang?")
      result = List.last(messages)
      IO.puts(result[:content])
  """
  defdelegate query(session, prompt), to: :beam_agent

  @doc """
  Send a synchronous query with explicit parameters.

  Like `query/2` but accepts a query options map to control model selection,
  tool permissions, timeout, output format, and other query-level settings.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- query options map. Keys include `:model`, `:max_turns`,
    `:permission_mode`, `:timeout`, `:max_tokens`, `:system_prompt`,
    `:allowed_tools`, `:disallowed_tools`, `:output_format`, `:thinking`,
    `:max_budget_usd`, `:agent`, and `:attachments`.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.

  ## Examples

      {:ok, messages} = BeamAgent.query(session, "Refactor this module", %{
        model: "claude-sonnet-4-20250514",
        max_turns: 5,
        permission_mode: :accept_edits,
        timeout: 120_000
      })
  """
  defdelegate query(session, prompt, params), to: :beam_agent

  @doc """
  Subscribe the calling process to streaming events from a session.

  After subscribing, the caller receives events via `receive_event/2` or
  `receive_event/3`. Events are normalized `t:message/0` maps delivered in
  real time as the backend produces them. The stream ends with an
  `{:error, :complete}` sentinel after a result or error message.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, ref}` where `ref` is a unique subscription reference.
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, ref} = BeamAgent.event_subscribe(session)
      {:ok, _messages} = BeamAgent.query(session, "Hello")
      {:ok, event} = BeamAgent.receive_event(session, ref, 5_000)
  """
  defdelegate event_subscribe(session), to: :beam_agent

  @doc """
  Receive the next event from a subscription with a 5-second default timeout.

  Equivalent to `receive_event(session, ref, 5000)`.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.

  ## Returns

  - `{:ok, event}` where `event` is a `t:message/0` map.
  - `{:error, :complete}` when the stream has ended.
  - `{:error, :timeout}` if no event arrives within 5 seconds.
  - `{:error, :bad_ref}` if the subscription is invalid.
  """
  defdelegate receive_event(session, ref), to: :beam_agent

  @doc """
  Receive the next event from a subscription with an explicit timeout.

  Blocks the calling process until an event arrives, the stream completes,
  or the timeout expires.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.
  - `timeout` -- maximum wait time in milliseconds.

  ## Returns

  - `{:ok, event}` -- a `t:message/0` map.
  - `{:error, :complete}` -- stream has ended.
  - `{:error, :timeout}` -- no event within the timeout.
  - `{:error, :bad_ref}` -- invalid subscription reference.
  """
  defdelegate receive_event(session, ref, timeout), to: :beam_agent

  @doc """
  Remove an event subscription and flush any pending events from the mailbox.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference from `event_subscribe/1`.

  ## Returns

  - `{:ok, :ok}` on success.
  - `{:error, :bad_ref}` if the reference is invalid.
  """
  defdelegate event_unsubscribe(session, ref), to: :beam_agent

  @doc """
  Retrieve metadata about a running session.

  Returns a map containing `:session_id`, `:backend`, `:model`, current state,
  working directory, and handler-specific metadata merged from the backend's
  `build_session_info` callback.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, info_map}` or `{:error, reason}`.
  """
  defdelegate session_info(session), to: :beam_agent

  @doc """
  Return the current health state of a session as an atom.

  Possible values depend on the session engine state: `:connecting`,
  `:initializing`, `:ready`, `:active_query`, `:error`, or `:unknown`.

  ## Parameters

  - `session` -- pid of a running session.
  """
  defdelegate health(session), to: :beam_agent

  @doc """
  Resolve the backend identifier for a running session.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, backend}` where `backend` is an atom like `:claude`, `:codex`,
    `:gemini`, `:opencode`, or `:copilot`.
  - `{:error, reason}` if the backend cannot be determined.
  """
  defdelegate backend(session), to: :beam_agent

  @doc """
  List all registered backend identifiers.

  Returns a list of atoms representing the backends available in this
  build of the SDK (e.g., `[:claude, :codex, :gemini, :opencode, :copilot]`).

  ## Examples

      iex> backends = BeamAgent.list_backends()
      iex> :claude in backends
      true
  """
  defdelegate list_backends(), to: :beam_agent

  @doc """
  Normalize a raw wire-format message into the SDK message format.

  Converts a backend-specific message map into the canonical `t:message/0`
  format used throughout the SDK. Applies type detection from the message
  content, normalizes field names, and adds any missing required keys with
  default values.

  ## Parameters

  - `raw` -- a raw message map from the backend wire format.

  ## Returns

  A normalized `t:message/0` map.
  """
  defdelegate normalize_message(raw), to: :beam_agent

  @doc """
  Generate a unique request identifier.

  Produces a binary UUID suitable for use as a control message `request_id`
  or query correlation identifier.

  ## Returns

  A binary UUID string.
  """
  defdelegate make_request_id(), to: :beam_agent

  @doc """
  Parse a raw stop reason value into a `t:stop_reason/0` atom.

  Accepts binaries (`"end_turn"`), strings, or atoms and returns the
  corresponding `t:stop_reason/0` atom for pattern matching. Unrecognized
  values are mapped to `:unknown`.

  ## Parameters

  - `reason` -- the raw stop reason value.

  ## Returns

  A `t:stop_reason/0` atom.
  """
  defdelegate parse_stop_reason(reason), to: :beam_agent

  @doc """
  Parse a raw permission mode value into a `t:permission_mode/0` atom.

  Accepts binaries (`"auto"`), strings, or atoms and returns the
  corresponding `t:permission_mode/0` atom. Unrecognized values are
  mapped to `:default`.

  ## Parameters

  - `mode` -- the raw permission mode value.

  ## Returns

  A `t:permission_mode/0` atom.
  """
  defdelegate parse_permission_mode(mode), to: :beam_agent

  @doc """
  Collect messages from a subscription until a result message or deadline.

  Loops calling `receive_fun` to pull messages from the subscription
  identified by `ref`. Accumulates messages until either a message with
  `type: :result` arrives or the wall-clock `deadline` is reached.
  Returns all collected messages in order.

  This is the building block behind `query/2` synchronous semantics.

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference.
  - `deadline` -- monotonic time deadline in milliseconds.
  - `receive_fun` -- a `t:receive_fun/0` that pulls the next message.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate collect_messages(session, ref, deadline, receive_fun), to: :beam_agent

  @doc """
  Collect messages with a custom terminal predicate.

  Same as `collect_messages/4` but stops when `terminal_pred` returns `true`
  for a message instead of checking for `type: :result`. This allows callers
  to define their own completion condition (e.g., stop on the first
  `:tool_use` message, or after N text chunks).

  ## Parameters

  - `session` -- pid of a running session.
  - `ref` -- subscription reference.
  - `deadline` -- monotonic time deadline in milliseconds.
  - `receive_fun` -- a `t:receive_fun/0` that pulls the next message.
  - `terminal_pred` -- a `t:terminal_pred/0` function.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  defdelegate collect_messages(session, ref, deadline, receive_fun, terminal_pred),
    to: :beam_agent

  # ---------------------------------------------------------------------------
  # Streaming (Elixir-only convenience functions)
  # ---------------------------------------------------------------------------

  @doc """
  Stream query responses as an `Enumerable` (raises on errors).

  Sends a query and returns a lazy `Stream` that yields each response
  message as it arrives. Raises on query failure or timeout.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- optional query parameters (keyword list or map).

  ## Returns

  An `Enumerable.t()` of `t:message/0` maps.

  ## Examples

      session
      |> BeamAgent.stream!("Explain GenServer")
      |> Enum.each(fn msg ->
        IO.write(msg[:content] || "")
      end)
  """
  @spec stream!(pid(), binary(), keyword() | map()) :: Enumerable.t()
  def stream!(session, prompt, params \\ %{}) when is_pid(session) and is_binary(prompt) do
    query_params = opts_to_map(params)
    timeout = Map.get(query_params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :beam_agent_router.send_query(session, prompt, query_params, timeout) do
          {:ok, ref} -> {session, ref, deadline, false}
          {:error, reason} -> raise "Query failed: #{inspect(reason)}"
        end
      end,
      fn
        {:done, _, _, _} = done ->
          {:halt, done}

        {sess, ref, dl, received_message?} ->
          remaining = dl - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            raise "Stream error: timeout"
          else
            case :beam_agent_router.receive_message(sess, ref, remaining) do
              {:ok, msg} ->
                {[msg], {sess, ref, dl, true}}

              {:error, :complete} ->
                {:halt, {sess, ref, dl, received_message?}}

              {:error, :no_active_query} when received_message? ->
                {:halt, {sess, ref, dl, received_message?}}

              {:error, reason} ->
                raise "Stream error: #{inspect(reason)}"
            end
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Stream query responses as an `Enumerable` (returns tagged tuples).

  Like `stream!/3` but wraps each message in `{:ok, msg}` and errors in
  `{:error, reason}` instead of raising. Suitable for pipelines that need
  to handle errors gracefully.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `params` -- optional query parameters (keyword list or map).

  ## Returns

  An `Enumerable.t()` of `{:ok, message()}` or `{:error, reason}` tuples.

  ## Examples

      session
      |> BeamAgent.stream("Explain OTP")
      |> Enum.each(fn
        {:ok, msg} -> IO.write(msg[:content] || "")
        {:error, reason} -> IO.puts("Error: \#{inspect(reason)}")
      end)
  """
  @spec stream(pid(), binary(), keyword() | map()) :: Enumerable.t()
  def stream(session, prompt, params \\ %{}) when is_pid(session) and is_binary(prompt) do
    query_params = opts_to_map(params)
    timeout = Map.get(query_params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :beam_agent_router.send_query(session, prompt, query_params, timeout) do
          {:ok, ref} -> {session, ref, deadline, false}
          {:error, _} = err -> {:error_init, err}
        end
      end,
      fn
        {:error_init, err} ->
          {[err], :halt_state}

        :halt_state ->
          {:halt, :halt_state}

        {sess, ref, dl, received_message?} ->
          remaining = dl - System.monotonic_time(:millisecond)

          cond do
            remaining <= 0 ->
              {[{:error, :timeout}], :halt_state}

            true ->
              case :beam_agent_router.receive_message(sess, ref, remaining) do
                {:ok, msg} ->
                  {[{:ok, msg}], {sess, ref, dl, true}}

                {:error, :complete} ->
                  {:halt, {sess, ref, dl, received_message?}}

                {:error, :no_active_query} when received_message? ->
                  {:halt, {sess, ref, dl, received_message?}}

                {:error, reason} ->
                  {[{:error, reason}], :halt_state}
              end
          end
      end,
      fn _ -> :ok end
    )
  end

  # ---------------------------------------------------------------------------
  # Session Store Operations
  # ---------------------------------------------------------------------------

  @doc """
  List all tracked sessions from the universal session store.

  Returns session metadata maps sorted by `updated_at` descending.
  Sessions are tracked automatically when messages are recorded.

  ## Returns

  - `{:ok, sessions}` where each entry is a `t:session_info_map/0`.

  ## Examples

      {:ok, sessions} = BeamAgent.list_sessions()
      for s <- sessions do
        IO.puts("\#{s.session_id} (\#{s.model})")
      end
  """
  @spec list_sessions() :: {:ok, [session_info_map()]}
  def list_sessions, do: BeamAgent.SessionStore.list_sessions()

  @doc """
  List tracked sessions with optional filters.

  ## Parameters

  - `opts` -- filter map with optional keys:
    - `:adapter` -- filter by backend atom
    - `:cwd` -- filter by working directory
    - `:model` -- filter by model name
    - `:limit` -- maximum number of results
    - `:since` -- unix millisecond timestamp lower bound on `updated_at`

  ## Returns

  - `{:ok, sessions}` sorted by `updated_at` descending.
  """
  @spec list_sessions(map()) :: {:ok, [session_info_map()]}
  def list_sessions(opts) when is_map(opts), do: BeamAgent.SessionStore.list_sessions(opts)

  @doc """
  List sessions from the backend's native session store.

  Attempts to call the Claude backend's native session listing. Falls back
  to `list_sessions/0` if the backend does not support native session listing.

  ## Returns

  - `{:ok, sessions}` or `{:error, reason}`.
  """
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
  defdelegate list_native_sessions(opts), to: :beam_agent_session_store

  @doc """
  Get all messages for a session from the universal store.

  Returns the full message history in chronological order.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, messages}` or `{:error, :not_found}` if no session exists
    with that identifier.

  ## Examples

      {:ok, messages} = BeamAgent.get_session_messages("sess_abc123")
      IO.puts("Total messages: \#{length(messages)}")
  """
  @spec get_session_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id),
    do: BeamAgent.SessionStore.get_session_messages(session_id)

  @doc """
  Get messages for a session with filtering options.

  ## Parameters

  - `session_id` -- binary session identifier.
  - `opts` -- filter map with optional keys:
    - `:limit` -- maximum number of messages to return
    - `:offset` -- skip this many messages from the start
    - `:types` -- list of `t:message_type/0` atoms to include
    - `:include_hidden` -- if `true`, include reverted/hidden messages

  ## Returns

  - `{:ok, messages}` or `{:error, :not_found}`.
  """
  @spec get_session_messages(binary(), map()) :: {:ok, [message()]} | {:error, term()}
  def get_session_messages(session_id, opts) when is_map(opts) do
    BeamAgent.SessionStore.get_session_messages(session_id, opts)
  end

  @doc """
  Get messages from the backend's native session store.

  Falls back to `get_session_messages/1` if native message retrieval is
  not supported by the backend.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
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
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent_session_store

  @doc """
  Get metadata for a specific session by identifier.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  - `{:ok, session_meta}` or `{:error, :not_found}`.
  """
  @spec get_session(binary()) :: {:ok, session_info_map()} | {:error, :not_found}
  def get_session(session_id), do: BeamAgent.SessionStore.get_session(session_id)

  @doc """
  Delete a session and all its messages from the universal store.

  Also signals completion to any active event subscribers for that session.
  Idempotent -- deleting a nonexistent session is a no-op.

  ## Parameters

  - `session_id` -- binary session identifier.

  ## Returns

  `:ok`
  """
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: BeamAgent.SessionStore.delete_session(session_id)

  @doc """
  Create a fork (copy) of a session's metadata and message history.

  The new session receives a copy of all messages and metadata from the
  source session.

  ## Parameters

  - `session_or_id` -- pid of the source session.
  - `opts` -- fork options map. Optional keys:
    - `:session_id` -- explicit id for the fork (auto-generated if omitted)
    - `:include_hidden` -- include reverted messages (default `true`)
    - `:extra` -- additional metadata to merge into the fork

  ## Returns

  - `{:ok, fork_meta}` or `{:error, :not_found}`.
  """
  @spec fork_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def fork_session(session_or_id, opts),
    do: BeamAgent.SessionStore.fork_session(session_or_id, opts)

  @doc """
  Revert a session's visible conversation state to a prior boundary.

  The underlying message store remains append-only. Revert changes the
  active view by storing a `visible_message_count` in the session metadata.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `selector` -- boundary selector map. Accepts one of:
    - `%{visible_message_count: n}` -- set boundary to N messages
    - `%{message_id: id}` -- set boundary to the message with this id
    - `%{uuid: id}` -- set boundary to the message with this uuid

  ## Returns

  - `{:ok, updated_meta}` or `{:error, :not_found | :invalid_selector}`.
  """
  @spec revert_session(pid(), map()) :: {:ok, session_info_map()} | {:error, term()}
  def revert_session(session_or_id, selector),
    do: BeamAgent.SessionStore.revert_session(session_or_id, selector)

  @doc """
  Clear any revert state and restore the full visible message history.

  Undoes a previous `revert_session/2` call so all messages are visible again.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, updated_meta}` or `{:error, :not_found}`.
  """
  @spec unrevert_session(pid()) :: {:ok, session_info_map()} | {:error, term()}
  def unrevert_session(session_or_id), do: BeamAgent.SessionStore.unrevert_session(session_or_id)

  @doc """
  Generate a shareable link/state for a session.

  Creates or replaces the active share state with a generated `share_id`.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, share_info}` with `:share_id`, `:session_id`, `:created_at`, and
    `:status` fields.
  - `{:error, :not_found}`.
  """
  @spec share_session(pid()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id), do: BeamAgent.SessionStore.share_session(session_or_id)

  @doc """
  Generate a shareable link/state for a session with options.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `opts` -- options map. Optional keys:
    - `:share_id` -- explicit share identifier (auto-generated if omitted)

  ## Returns

  - `{:ok, share_info}` or `{:error, :not_found}`.
  """
  @spec share_session(pid(), map()) :: {:ok, share_info_map()} | {:error, term()}
  def share_session(session_or_id, opts),
    do: BeamAgent.SessionStore.share_session(session_or_id, opts)

  @doc """
  Revoke the current share state for a session.

  Marks the share as revoked. The `share_id` remains in metadata but its
  status changes to `:revoked`.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `:ok` or `{:error, :not_found}`.
  """
  @spec unshare_session(pid()) :: :ok | {:error, term()}
  def unshare_session(session_or_id), do: BeamAgent.SessionStore.unshare_session(session_or_id)

  @doc """
  Generate and store a summary for a session's conversation history.

  Produces a deterministic summary from the session's messages including
  the first user message and latest agent output.

  ## Parameters

  - `session_or_id` -- pid of a running session.

  ## Returns

  - `{:ok, summary_map}` with `:content`, `:generated_at`, `:message_count`,
    and `:generated_by` fields.
  - `{:error, :not_found}`.
  """
  @spec summarize_session(pid()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id),
    do: BeamAgent.SessionStore.summarize_session(session_or_id)

  @doc """
  Generate and store a session summary with options.

  ## Parameters

  - `session_or_id` -- pid of a running session.
  - `opts` -- options map. Optional keys:
    - `:content` / `:summary` -- explicit summary text (skips auto-generation)
    - `:generated_by` -- attribution string (default `"beam_agent_core"`)

  ## Returns

  - `{:ok, summary_map}` or `{:error, :not_found}`.
  """
  @spec summarize_session(pid(), map()) :: {:ok, summary_info_map()} | {:error, term()}
  def summarize_session(session_or_id, opts),
    do: BeamAgent.SessionStore.summarize_session(session_or_id, opts)

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc """
  Start a new conversation thread within a session.

  Creates a named thread that groups related queries. The new thread
  becomes the active thread for the session. Thread messages are stored
  as a subset of the session's message history, tagged with `thread_id`.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- thread options map. Optional keys:
    - `:name` -- human-readable thread name (defaults to the `thread_id`)
    - `:thread_id` -- explicit id (auto-generated if omitted)
    - `:metadata` -- arbitrary metadata map
    - `:parent_thread_id` -- id of the parent thread (for fork lineage)

  ## Returns

  - `{:ok, thread_meta}` with `:thread_id`, `:session_id`, `:name`, `:status`,
    and other metadata fields.
  - `{:error, reason}`.

  ## Examples

      {:ok, thread} = BeamAgent.thread_start(session, %{
        name: "refactor-discussion"
      })
      thread_id = thread.thread_id
      {:ok, _messages} = BeamAgent.query(session, "Let's refactor the router")
  """
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_start(session, opts), do: BeamAgent.Threads.thread_start(session, opts)

  @doc """
  Resume an existing thread by its identifier.

  Sets the thread as the active thread for the session and updates its
  status to active. Subsequent queries will be associated with this thread.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, thread_meta}` or `{:error, :not_found}`.

  ## Examples

      {:ok, thread} = BeamAgent.thread_resume(session, "thread_abc123")
      IO.puts("Resumed: \#{thread.name}")
  """
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id), do: BeamAgent.Threads.thread_resume(session, thread_id)

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
  defdelegate thread_resume(session, thread_id, opts), to: :beam_agent_threads

  @doc """
  List all threads for a session, sorted by `updated_at` descending.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, thread_list}` where each entry is a thread metadata map.
  - `{:error, reason}`.
  """
  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, term()}
  def thread_list(session), do: BeamAgent.Threads.thread_list(session)

  @doc """
  List threads for a session with backend-specific options.

  Falls back to `thread_list/1` if the backend does not support filtered
  thread listing.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific listing options.

  ## Returns

  - `{:ok, thread_list}` or `{:error, reason}`.
  """
  defdelegate thread_list(session, opts), to: :beam_agent_threads

  @doc """
  Fork an existing thread, copying its visible message history.

  Creates a new thread with a copy of all visible messages from the source
  thread. Message `thread_id` fields are rewritten to the new thread id.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary identifier of the source thread.

  ## Returns

  - `{:ok, forked_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_fork(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id), do: BeamAgent.Threads.thread_fork(session, thread_id)

  @doc """
  Fork an existing thread with options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary identifier of the source thread.
  - `opts` -- fork options map. Optional keys:
    - `:thread_id` -- explicit id for the fork
    - `:name` -- name for the forked thread
    - `:parent_thread_id` -- override the parent reference

  ## Returns

  - `{:ok, forked_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_fork(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_fork(session, thread_id, opts),
    do: BeamAgent.Threads.thread_fork(session, thread_id, opts)

  @doc """
  Read thread metadata and optionally its message history.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, %{thread: thread_meta}}` or `{:error, :not_found}`.
  """
  @spec thread_read(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id), do: BeamAgent.Threads.thread_read(session, thread_id)

  @doc """
  Read thread metadata with options.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `opts` -- options map. Optional keys:
    - `:include_messages` -- if `true`, includes the `:messages` key in the result

  ## Returns

  - `{:ok, %{thread: thread_meta, messages: [message()]}}` or `{:error, :not_found}`.
  """
  @spec thread_read(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_read(session, thread_id, opts),
    do: BeamAgent.Threads.thread_read(session, thread_id, opts)

  @doc """
  Archive a thread, marking it as archived and inactive.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_archive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_archive(session, thread_id), do: BeamAgent.Threads.thread_archive(session, thread_id)

  @doc """
  Unsubscribe from a thread and clear it as the active thread if applicable.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, result_map}` with `:thread_id` and `:unsubscribed` fields.
  - `{:error, :not_found}`.
  """
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
  defdelegate thread_metadata_update(session, thread_id, metadata_patch), to: :beam_agent_threads

  @doc """
  Unarchive a previously archived thread, restoring it to active status.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found}`.
  """
  @spec thread_unarchive(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_unarchive(session, thread_id),
    do: BeamAgent.Threads.thread_unarchive(session, thread_id)

  @doc """
  Rollback a thread's visible message history to a prior boundary.

  The underlying messages are preserved; only the visible window changes.

  ## Parameters

  - `session` -- pid of a running session.
  - `thread_id` -- binary thread identifier.
  - `selector` -- boundary selector map. Accepts one of:
    - `%{count: n}` -- hide the last N visible messages
    - `%{visible_message_count: n}` -- set boundary directly
    - `%{message_id: id}` or `%{uuid: id}` -- set boundary to a message

  ## Returns

  - `{:ok, updated_thread_meta}` or `{:error, :not_found | :invalid_selector}`.
  """
  @spec thread_rollback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def thread_rollback(session, thread_id, selector),
    do: BeamAgent.Threads.thread_rollback(session, thread_id, selector)

  @doc """
  List loaded (in-memory) threads for a session.

  Returns threads with their active state, optionally filtered by the
  backend's native implementation.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` with `:threads`, `:active_thread_id`, and `:count` fields.
  - `{:error, reason}`.
  """
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
  defdelegate thread_loaded_list(session, opts), to: :beam_agent_threads

  @doc """
  Compact a thread by reducing its visible message history.

  Uses `thread_rollback` internally with a selector derived from the
  options map. If no selector is provided, compacts to zero visible messages.

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
  defdelegate thread_compact(session, opts), to: :beam_agent_threads

  # ---------------------------------------------------------------------------
  # Event Streaming (Elixir-only convenience functions)
  # ---------------------------------------------------------------------------

  @doc """
  Stream session events as an `Enumerable` (raises on errors).

  Subscribes to session events and returns a lazy `Stream` that yields
  each event as it arrives. Automatically unsubscribes on stream
  completion. Raises on subscription failure or stream errors.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- optional keyword list or map. Optional keys:
    - `:timeout` -- event receive timeout in milliseconds (default 30,000).

  ## Returns

  An `Enumerable.t()` of `t:message/0` maps.

  ## Examples

      session
      |> BeamAgent.event_stream!()
      |> Enum.take(10)
      |> Enum.each(&IO.inspect/1)
  """
  @spec event_stream!(pid(), keyword() | map()) :: Enumerable.t()
  def event_stream!(session, opts \\ %{}) when is_pid(session) do
    params = opts_to_map(opts)
    timeout = Map.get(params, :timeout, 30_000)

    Stream.resource(
      fn ->
        case event_subscribe(session) do
          {:ok, ref} -> {session, ref, timeout}
          {:error, reason} -> raise "Event subscribe failed: #{inspect(reason)}"
        end
      end,
      fn
        {:done, sess, ref, _timeout} = done ->
          _ = event_unsubscribe(sess, ref)
          {:halt, done}

        {sess, ref, timeout} ->
          case receive_event(sess, ref, timeout) do
            {:ok, msg} ->
              {[msg], {sess, ref, timeout}}

            {:error, :complete} ->
              _ = event_unsubscribe(sess, ref)
              {:halt, {:done, sess, ref, timeout}}

            {:error, reason} ->
              _ = event_unsubscribe(sess, ref)
              raise "Event stream error: #{inspect(reason)}"
          end
      end,
      fn
        {:done, _, _, _} ->
          :ok

        {sess, ref, _timeout} ->
          _ = event_unsubscribe(sess, ref)
          :ok
      end
    )
  end

  @doc """
  Stream session events as an `Enumerable` (returns tagged tuples).

  Like `event_stream!/2` but wraps each event in `{:ok, event}` and errors
  in `{:error, reason}` instead of raising. Suitable for pipelines that
  need to handle errors gracefully.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- optional keyword list or map. Optional keys:
    - `:timeout` -- event receive timeout in milliseconds (default 30,000).

  ## Returns

  An `Enumerable.t()` of `{:ok, message()}` or `{:error, reason}` tuples.
  """
  @spec event_stream(pid(), keyword() | map()) :: Enumerable.t()
  def event_stream(session, opts \\ %{}) when is_pid(session) do
    params = opts_to_map(opts)
    timeout = Map.get(params, :timeout, 30_000)

    Stream.resource(
      fn ->
        case event_subscribe(session) do
          {:ok, ref} -> {session, ref, timeout}
          {:error, reason} -> {:error_init, reason}
        end
      end,
      fn
        {:error_init, reason} ->
          {[{:error, reason}], :halt_state}

        :halt_state ->
          {:halt, :halt_state}

        {sess, ref, timeout} ->
          case receive_event(sess, ref, timeout) do
            {:ok, msg} ->
              {[{:ok, msg}], {sess, ref, timeout}}

            {:error, :complete} ->
              _ = event_unsubscribe(sess, ref)
              {:halt, {sess, ref, timeout}}

            {:error, reason} ->
              _ = event_unsubscribe(sess, ref)
              {[{:error, reason}], :halt_state}
          end
      end,
      fn
        :halt_state ->
          :ok

        {sess, ref, _timeout} ->
          _ = event_unsubscribe(sess, ref)
          :ok
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts
end
