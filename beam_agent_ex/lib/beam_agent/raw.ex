defmodule BeamAgent.Raw do
  @moduledoc """
  Minimal escape-hatch namespace for transport-level and debug access only.

  All user-visible features — threads, turns, skills, apps, files, MCP, accounts,
  fuzzy search, and so on — are available through the canonical `BeamAgent` module
  with universal fallbacks across all five backends. **You almost certainly want
  `BeamAgent`, not this module.**

  ## When to use directly vs through `BeamAgent`

  Use `BeamAgent.Raw` only when you need to:

  - Inspect transport-level identity (`backend/1`, `adapter_module/1`)
  - Call a backend-native function that does not yet have a canonical wrapper
    (`call/3`, `call_backend/3`)
  - Access Claude-native session listing or message inspection
    (`list_native_sessions/0,1`, `get_native_session_messages/1,2`)
  - Probe transport-level health, status, and auth without the canonical layer
    (`server_health/1`, `get_status/1`, `get_auth_status/1`,
    `get_last_session_id/1`)

  ## `call/3` vs `call_backend/3`

  `call/3` takes a live session `pid()` and routes the function call to the
  correct backend adapter for that session, prepending the session pid to the
  argument list:

  ```elixir
  # Calls claude_agent_session:thread_realtime_start(session_pid, opts)
  {:ok, _} = BeamAgent.Raw.call(session_pid, :thread_realtime_start, [%{mode: "voice"}])
  ```

  `call_backend/3` routes to a backend adapter by name (no session pid
  prepended), which is useful for backend-scoped helpers that are not tied to an
  active session:

  ```elixir
  {:ok, sessions} = BeamAgent.Raw.call_backend(:claude, :list_native_sessions, [])
  ```

  ## Native session access is Claude-only

  `list_native_sessions/0,1` and `get_native_session_messages/1,2` are
  Claude-native operations that go directly to the Claude SDK session store. They
  are not available on other backends.

  ## Session destruction

  `session_destroy/1` accepts a live session `pid()` and resolves the session ID
  automatically. `session_destroy/2` accepts a session `pid()` and an explicit
  `session_id` binary for cases where the session process is no longer alive but
  you still have a known ID.
  """

  @doc """
  Resolve the backend atom for a live session pid.

  Returns `{:ok, backend}` where `backend` is one of
  `:claude | :codex | :gemini | :opencode | :copilot`, or `{:error, reason}` if
  the session is not registered.
  """
  @spec backend(pid()) ::
          {:ok, :claude | :codex | :gemini | :opencode | :copilot}
          | {:error,
             :backend_not_present
             | {:invalid_session_info, term()}
             | {:session_backend_lookup_failed, term()}
             | {:unknown_backend, term()}}
  defdelegate backend(session), to: :beam_agent_raw

  @doc """
  Resolve the adapter facade module for a live session pid.

  Returns `{:ok, module}` where `module` is the backend adapter module
  (e.g. `:claude_agent_session`), or `{:error, reason}`.
  """
  @spec adapter_module(pid()) ::
          {:ok,
           :claude_agent_sdk
           | :codex_app_server
           | :copilot_client
           | :gemini_cli_client
           | :opencode_client}
          | {:error,
             :backend_not_present
             | {:invalid_session_info, term()}
             | {:session_backend_lookup_failed, term()}
             | {:unknown_backend, term()}}
  defdelegate adapter_module(session), to: :beam_agent_raw

  @doc """
  Call a backend-native function for a live session, routing by session pid.

  The session pid is prepended to `args` before the call, so the effective call
  is `AdapterModule.function(session, args...)`. The return value is normalised:
  bare terms are wrapped in `{:ok, term}`, existing `{:ok, _}` and `{:error, _}`
  tuples pass through unchanged.

  Returns `{:error, {:unsupported_native_call, function}}` if the backend adapter
  does not export `function/arity`.

  ## Example

  ```elixir
  {:ok, _} = BeamAgent.Raw.call(pid, :thread_realtime_start, [%{mode: "voice"}])
  ```
  """
  @spec call(pid(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defdelegate call(session, function, args), to: :beam_agent_raw

  @doc """
  Call a backend facade function directly, without prepending a session pid.

  `backend_like` may be a backend atom, a binary such as `"claude"`, or any
  value accepted by `:beam_agent_backend.normalize/1`. The call is dispatched as
  `AdapterModule.function(args...)`.

  Use this for backend-scoped helpers not bound to an active session (e.g.
  listing all native Claude sessions). For session-bound calls, prefer `call/3`.

  ## Example

  ```elixir
  {:ok, sessions} = BeamAgent.Raw.call_backend(:claude, :list_native_sessions, [])
  ```
  """
  @spec call_backend(atom() | binary(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defdelegate call_backend(backend, function, args), to: :beam_agent_raw

  @doc """
  List all native Claude SDK sessions (no options).

  Calls the Claude adapter directly and returns the raw session list from the
  Claude SDK session store. Not available on other backends.
  """
  @spec list_native_sessions() :: {:ok, term()} | {:error, term()}
  defdelegate list_native_sessions(), to: :beam_agent_raw

  @doc """
  List all native Claude SDK sessions with options.

  `opts` is a map passed directly to the Claude adapter's `list_native_sessions/1`
  function.
  """
  @spec list_native_sessions(map()) :: {:ok, term()} | {:error, term()}
  defdelegate list_native_sessions(opts), to: :beam_agent_raw

  @doc """
  Fetch all messages for a native Claude session by session ID binary.

  Returns the raw message list from the Claude SDK session store.
  """
  @spec get_native_session_messages(binary()) :: {:ok, term()} | {:error, term()}
  defdelegate get_native_session_messages(session_id), to: :beam_agent_raw

  @doc """
  Fetch messages for a native Claude session with options.

  `opts` is a map passed directly to the Claude adapter. Use this variant when
  you need pagination or filtering supported by the underlying Claude adapter.
  """
  @spec get_native_session_messages(binary(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate get_native_session_messages(session_id, opts), to: :beam_agent_raw

  @doc """
  Destroy the session associated with a live session pid.

  Resolves the session ID from the running session process via
  `BeamAgent.session_info/1` and calls the backend's `session_destroy` function.

  Use `session_destroy/2` if the session process is no longer alive.
  """
  @spec session_destroy(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate session_destroy(session), to: :beam_agent_raw

  @doc """
  Destroy a session by providing an explicit session ID.

  Use this variant when you have a known `session_id` binary but the session
  process may or may not still be running. The pid is still required to route to
  the correct backend adapter.
  """
  @spec session_destroy(pid(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate session_destroy(session, session_id), to: :beam_agent_raw

  @doc """
  Probe the transport-level health of the backend server for a session.

  Delegates to the backend adapter's `server_health/1`. The return value format
  is adapter-specific.
  """
  @spec server_health(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate server_health(session), to: :beam_agent_raw

  @doc """
  Fetch the raw status map from the backend server for a session.

  Delegates to the backend adapter's `get_status/1`. The return value format is
  adapter-specific.
  """
  @spec get_status(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate get_status(session), to: :beam_agent_raw

  @doc """
  Fetch the raw authentication status from the backend server for a session.

  Delegates to the backend adapter's `get_auth_status/1`. The return value format
  is adapter-specific.
  """
  @spec get_auth_status(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate get_auth_status(session), to: :beam_agent_raw

  @doc """
  Fetch the last known session ID reported by the backend for a session.

  Delegates to the backend adapter's `get_last_session_id/1`. Useful for
  correlating a BEAM session pid with the backend's own session identifier
  without going through `BeamAgent.session_info/1`.
  """
  @spec get_last_session_id(pid()) :: {:ok, binary()} | {:error, term()}
  defdelegate get_last_session_id(session), to: :beam_agent_raw
end
