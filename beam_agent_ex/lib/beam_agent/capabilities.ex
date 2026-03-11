defmodule BeamAgent.Capabilities do
  @moduledoc """
  Capability metadata for the BeamAgent SDK.

  This module is the single source of truth for which features each backend
  supports and how. It answers questions like "can I use checkpointing with
  Gemini?" or "does OpenCode have a direct implementation of thread management?"

  ## When to use directly vs through `BeamAgent`

  Use this module in feature-detection code, capability-discovery UIs,
  documentation generators, or tests that verify backend parity. You do not need
  it for normal session usage.

  ## Capability model

  Every capability/backend pair is described across three orthogonal dimensions:

  - `:support_level` — `:missing | :partial | :baseline | :full`
  - `:implementation` — `:direct_backend | :universal | :direct_backend_and_universal`
  - `:fidelity` — `:exact | :validated_equivalent`

  All 22 capabilities are at `:full` support level across all 5 backends. The
  `:implementation` field records whether the route is a direct backend call, a
  BeamAgent universal path (OTP-layer shim), or a hybrid that exposes both.

  ## The 22 capabilities

  ```
  session_lifecycle       session_info            runtime_model_switch
  interrupt               permission_mode         session_history
  session_mutation        thread_management       metadata_accessors
  in_process_mcp          mcp_management          hooks
  checkpointing           thinking_budget         task_stop
  command_execution       approval_callbacks      user_input_callbacks
  realtime_review         config_management       provider_management
  attachments             event_streaming
  ```

  ## Quick example

  ```elixir
  # Is checkpointing supported for codex?
  {:ok, true} = BeamAgent.Capabilities.supports(:checkpointing, :codex)

  # What implementation does gemini use for permission_mode?
  {:ok, %{implementation: :universal}} =
    BeamAgent.Capabilities.status(:permission_mode, :gemini)

  # Full capability list for a live session:
  {:ok, caps} = BeamAgent.Capabilities.for_session(session_pid)
  [%{id: :session_lifecycle, support_level: :full} | _] = caps
  ```

  ## Architecture deep dive

  `BeamAgent.Capabilities` is the sole capability registry for the project and the
  normative source for the `docs/architecture/*matrix*.md` artifacts. All entries
  are compiled-in static data — there is no ETS or runtime state. This module is a
  thin Elixir facade that delegates to `:beam_agent_capabilities`.
  """

  @typedoc """
  Capability atom identifier.

  One of: `:session_lifecycle`, `:session_info`, `:runtime_model_switch`,
  `:interrupt`, `:permission_mode`, `:session_history`, `:session_mutation`,
  `:thread_management`, `:metadata_accessors`, `:in_process_mcp`,
  `:mcp_management`, `:hooks`, `:checkpointing`, `:thinking_budget`,
  `:task_stop`, `:command_execution`, `:approval_callbacks`,
  `:user_input_callbacks`, `:realtime_review`, `:config_management`,
  `:provider_management`, `:attachments`, `:event_streaming`.
  """
  @type capability() :: atom()

  @typedoc "Support level for a capability/backend pair."
  @type support_level() :: :missing | :partial | :baseline | :full

  @typedoc "Implementation routing strategy for a capability/backend pair."
  @type implementation() :: :direct_backend | :universal | :direct_backend_and_universal

  @typedoc "Fidelity of the implementation relative to the canonical surface."
  @type fidelity() :: :exact | :validated_equivalent

  @typedoc """
  Support info map for a single capability/backend pair.

  Always contains `:support_level`, `:implementation`, and `:fidelity`. May also
  include `:available_paths` (list of implementation atoms) and `:notes` (binary)
  for backend-specific detail.
  """
  @type support_info() :: %{
          required(:support_level) => support_level(),
          required(:implementation) => implementation(),
          required(:fidelity) => fidelity(),
          optional(:available_paths) => [implementation()],
          optional(:notes) => binary()
        }

  @typedoc """
  Full capability info map as returned by `all/0`.

  Contains `:id` (capability atom), `:title` (binary), and `:support`
  (a map from backend atom to `support_info()`).
  """
  @type capability_info() :: %{
          required(:id) => capability(),
          required(:title) => binary(),
          required(:support) => %{
            (:claude | :codex | :gemini | :opencode | :copilot) => support_info()
          }
        }

  @doc """
  Return the full capability matrix as a list of `capability_info()` maps.

  Each entry contains the capability `:id`, a human-readable `:title`, and a
  `:support` map keyed by backend atom. This is the master data source consulted
  by all other functions in this module.

  ## Example

  ```elixir
  all = BeamAgent.Capabilities.all()
  [%{id: :session_lifecycle, title: _, support: s} | _] = all
  ```
  """
  @spec all() :: [capability_info()]
  defdelegate all(), to: :beam_agent_capabilities

  @doc """
  Return the list of all supported backend atoms.

  The five backends are: `:claude`, `:codex`, `:gemini`, `:opencode`, `:copilot`.

  ## Example

  ```elixir
  iex> BeamAgent.Capabilities.backends()
  [:claude, :codex, :gemini, :opencode, :copilot]
  ```
  """
  @spec backends() :: nonempty_list(:claude | :codex | :gemini | :opencode | :copilot)
  defdelegate backends(), to: :beam_agent_capabilities

  @doc """
  Return the flat list of all 22 capability atom identifiers.

  Useful for iterating over capabilities without loading the full matrix. The
  order matches the order of entries in `all/0`.

  ## Example

  ```elixir
  ids = BeamAgent.Capabilities.capability_ids()
  true = :checkpointing in ids
  ```
  """
  @spec capability_ids() :: [capability()]
  defdelegate capability_ids(), to: :beam_agent_capabilities

  @doc """
  Return the projected capability list for a specific backend.

  `backend_like` may be a backend atom (`:claude`), a binary (`"codex"`), or any
  value accepted by `:beam_agent_backend.normalize/1`.

  Each entry in the returned list is a flat map with `:id`, `:title`, `:backend`,
  `:support_level`, `:implementation`, and `:fidelity`, plus optional
  `:available_paths` and `:notes` where present.

  Returns `{:error, {:unknown_backend, backend}}` for unrecognised backend values.

  ## Example

  ```elixir
  {:ok, caps} = BeamAgent.Capabilities.for_backend(:claude)
  [%{id: :session_lifecycle, support_level: :full} | _] = caps
  ```
  """
  @spec for_backend(atom() | binary()) :: {:ok, [map()]} | {:error, {:unknown_backend, term()}}
  defdelegate for_backend(backend), to: :beam_agent_capabilities

  @doc """
  Return the projected capability list for the backend of a live session.

  Resolves the backend from the running session process and delegates to
  `for_backend/1`. This is the most convenient call during an active agent session
  when you do not know — or do not want to hard-code — the backend.

  Returns `{:error, :backend_not_present}` if the session process is not
  registered, or `{:error, {:session_backend_lookup_failed, reason}}` for other
  lookup failures.

  ## Example

  ```elixir
  {:ok, session} = BeamAgent.start_session(%{backend: :gemini})
  {:ok, caps} = BeamAgent.Capabilities.for_session(session)
  ```
  """
  @spec for_session(pid()) ::
          {:ok, [map()]}
          | {:error,
             :backend_not_present
             | {:unknown_backend, term()}
             | {:invalid_session_info, term()}
             | {:session_backend_lookup_failed, term()}}
  defdelegate for_session(session), to: :beam_agent_capabilities

  @doc """
  Return the full `support_info()` map for a specific capability/backend pair.

  The returned map always contains `:support_level`, `:implementation`, and
  `:fidelity`. It may also include `:available_paths` and `:notes` where the
  capability has backend-specific detail.

  Returns `{:error, {:unknown_capability, cap}}` for an unrecognised capability
  atom, or `{:error, {:unknown_backend, backend}}` for an unrecognised backend.

  ## Example

  ```elixir
  {:ok, %{support_level: :full, implementation: :universal}} =
    BeamAgent.Capabilities.status(:permission_mode, :gemini)
  ```
  """
  @spec status(capability(), atom() | binary()) ::
          {:ok, support_info()}
          | {:error, {:unknown_backend, term()} | {:unknown_capability, term()}}
  defdelegate status(capability, backend), to: :beam_agent_capabilities

  @doc """
  Check whether a capability is supported for a given backend.

  A convenience wrapper around `status/2`. Because all 22 capabilities are at
  `:full` support level for all 5 backends, this returns `{:ok, true}` for every
  valid capability/backend combination. It exists to make guard-style checks
  readable and to surface `{:error, ...}` for typos.

  Returns `{:error, {:unknown_capability, cap}}` or
  `{:error, {:unknown_backend, backend}}` for invalid inputs.

  ## Example

  ```elixir
  iex> BeamAgent.Capabilities.supports(:checkpointing, :codex)
  {:ok, true}

  iex> BeamAgent.Capabilities.supports(:in_process_mcp, "gemini")
  {:ok, true}

  iex> BeamAgent.Capabilities.supports(:bogus, :claude)
  {:error, {:unknown_capability, :bogus}}
  ```
  """
  @spec supports(capability(), atom() | binary()) ::
          {:ok, true} | {:error, {:unknown_capability, capability()} | {:unknown_backend, term()}}
  defdelegate supports(capability, backend), to: :beam_agent_capabilities
end
