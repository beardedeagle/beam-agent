defmodule BeamAgent.Hooks do
  @moduledoc """
  SDK lifecycle hooks for the BeamAgent SDK.

  This module provides a hook system that lets callers register in-process
  callback functions at key session lifecycle points. Hooks enable cross-cutting
  concerns — logging, permission gates, tool filtering, telemetry — without
  modifying adapter internals.

  The hook system is modelled after the TypeScript SDK v0.2.66
  `SessionConfig.hooks` and Python SDK hook support.

  ## When to use directly vs through `BeamAgent`

  Most callers pass hooks via the `:sdk_hooks` option when starting a session
  through `BeamAgent.start_session/1`. Use this module directly when you need to
  construct hook definitions programmatically, build registries, or fire hooks
  from a custom adapter.

  ## Quick example

  ```elixir
  # Deny all Bash tool calls:
  deny_bash = BeamAgent.Hooks.hook(:pre_tool_use, fn ctx ->
    case Map.get(ctx, :tool_name) do
      "Bash" -> {:deny, "No shell access allowed"}
      _ -> {:ok, ctx}
    end
  end)

  # Log every tool use:
  log_tool = BeamAgent.Hooks.hook(:post_tool_use, fn ctx ->
    IO.puts("Tool used: \#{Map.get(ctx, :tool_name, "unknown")}")
    {:ok, ctx}
  end)

  # Build a registry and pass it to session start:
  registry = BeamAgent.Hooks.build_registry([deny_bash, log_tool])

  # Or pass the list directly to BeamAgent:
  {:ok, session} = BeamAgent.start_session(%{sdk_hooks: [deny_bash, log_tool]})
  ```

  ## Core concepts

  - **Hook events**: atoms identifying lifecycle points. Two categories:

    *Blocking events* (`:pre_tool_use`, `:user_prompt_submit`,
    `:permission_request`, `:subagent_start`, `:pre_compact`,
    `:config_change`) may return `{:deny, reason}` or `{:ask, reason}` to
    prevent the action or escalate to the caller.

    *Notification-only events* (`:post_tool_use`, `:post_tool_use_failure`,
    `:stop`, `:session_start`, `:session_end`, `:subagent_stop`,
    `:notification`, `:task_completed`, `:teammate_idle`) always proceed
    regardless of callback return values.

  - **Matchers**: optional filters that restrict which tools trigger a hook.
    The `tool_name` field in a matcher can be an exact string or a regex pattern.
    Patterns are pre-compiled at registration time for efficient dispatch.

  - **Hook registry**: a map from event to a list of hook definitions, maintained
    in registration order. Pass the registry to `fire/3` at dispatch time.

  ## Global hooks

  Global hooks (registered via `register_global/1`) apply to every session. They
  are backed by a shared ETS table and fire before per-session hooks in the
  dispatch chain. Changes to the global registry automatically notify the reload
  bus so live sessions pick up updates.

  ## Architecture deep dive

  This module delegates every call to `:beam_agent_hooks`. Per-session hooks are
  entirely in-process — no ETS tables or inter-process communication. The hook
  registry is typically stored in the session handler state and passed to `fire/3`
  when lifecycle events occur. Global hooks use a shared ETS table created during
  `BeamAgent.init/0`.

  See also: `BeamAgent.Checkpoint`, `BeamAgent`.
  """

  # Erlang hook_def() uses optional map keys for matcher/compiled_re which
  @typedoc """
  Hook event atom identifying a lifecycle point.

  Blocking events: `:pre_tool_use`, `:user_prompt_submit`, `:permission_request`,
  `:subagent_start`, `:pre_compact`, `:config_change`.

  Notification-only events: `:post_tool_use`, `:post_tool_use_failure`, `:stop`,
  `:session_start`, `:session_end`, `:subagent_stop`, `:notification`,
  `:task_completed`, `:teammate_idle`.
  """
  @type hook_event() ::
          :pre_tool_use
          | :post_tool_use
          | :post_tool_use_failure
          | :stop
          | :session_start
          | :session_end
          | :subagent_start
          | :subagent_stop
          | :pre_compact
          | :notification
          | :config_change
          | :task_completed
          | :teammate_idle
          | :user_prompt_submit
          | :permission_request

  @typedoc """
  Hook callback function.

  A 1-arity function receiving a `hook_context()` map. Returns a three-way result:
  - `{:ok, context}` — allow, continue chain with (possibly modified) context
  - `{:deny, reason}` — block the action (blocking events only)
  - `{:ask, reason}` — escalate to caller for decision (blocking events only)

  For notification-only events, `{:deny, _}` and `{:ask, _}` are ignored.

  Callbacks are wrapped in try/catch for crash protection. Blocking hook
  crashes return `{:deny, _}` (fail-closed); notification hook crashes pass
  the context through unmodified (fail-open).

  Blocking events: `:pre_tool_use`, `:user_prompt_submit`, `:permission_request`,
  `:subagent_start`, `:pre_compact`, `:config_change`.
  """
  @type hook_callback() :: (hook_context() ->
                              {:ok, hook_context()} | {:deny, binary()} | {:ask, binary()})

  @typedoc """
  Context map passed to hook callbacks.

  Always contains the `:event` key. Other keys depend on the event type:
  `:tool_name`, `:tool_input`, `:tool_use_id` for tool events; `:prompt`,
  `:params` for `:user_prompt_submit`; `:stop_reason`, `:duration_ms` for
  `:stop`; etc.
  """
  @type hook_context() :: %{
          required(:event) => hook_event(),
          optional(:session_id) => binary(),
          optional(:tool_name) => binary(),
          optional(:tool_input) => map(),
          optional(:tool_use_id) => binary(),
          optional(:agent_id) => binary(),
          optional(:agent_type) => binary(),
          optional(:content) => binary(),
          optional(:stop_reason) => binary() | atom(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:stop_hook_active) => boolean(),
          optional(:prompt) => binary(),
          optional(:params) => map(),
          optional(:permission_prompt_tool_name) => binary(),
          optional(:permission_suggestions) => list(),
          optional(:updated_permissions) => map(),
          optional(:interrupt) => boolean(),
          optional(:category) => atom(),
          optional(:permission_id) => binary(),
          optional(:metadata) => map(),
          optional(:agent_transcript_path) => binary(),
          optional(:system_info) => map(),
          optional(:reason) => term(),
          optional(:reload_type) => atom(),
          optional(:status) => atom()
        }

  @typedoc """
  Matcher filter for restricting which tools trigger a hook.

  The `:tool_name` field can be an exact binary string or a regex pattern.
  When a regex pattern is provided it is pre-compiled at `hook/3` registration
  time for O(1) dispatch.
  """
  @type hook_matcher() :: %{optional(:tool_name) => binary()}

  @typedoc """
  A single hook definition as produced by `hook/2` or `hook/3`.

  Contains the event atom, callback function, optional matcher, and an optional
  pre-compiled regex (populated internally by `hook/3`).
  """
  @type hook_def() :: %{
          required(:event) => hook_event(),
          required(:callback) => hook_callback(),
          optional(:matcher) => hook_matcher(),
          optional(:compiled_re) => :re.mp()
        }

  @typedoc """
  Hook registry mapping events to their registered hook definitions.

  A map from `hook_event()` to a list of `hook_def()` maps in registration
  order. Created via `new_registry/0` and populated via `register_hook/2` or
  `build_registry/1`.
  """
  @type hook_registry() :: %{optional(hook_event()) => [hook_def()]}

  @doc """
  Create a hook that fires on all occurrences of an event.

  `event` is the lifecycle event atom (e.g. `:pre_tool_use`, `:session_start`).
  `callback` is a 1-arity function receiving a `hook_context()` map.

  Returns a `hook_def()` map suitable for `register_hook/2` or `build_registry/1`.

  ## Example

  ```elixir
  hook = BeamAgent.Hooks.hook(:session_start, fn ctx ->
    IO.puts("Session started: \#{Map.get(ctx, :session_id, "unknown")}")
    {:ok, ctx}
  end)
  ```
  """
  @spec hook(hook_event(), hook_callback()) ::
          %{required(:event) => hook_event(), required(:callback) => hook_callback()}
  defdelegate hook(event, callback), to: :beam_agent_hooks

  @doc """
  Create a hook with a matcher filter.

  The matcher restricts which tools trigger the hook. Only relevant for
  tool-related events (`:pre_tool_use`, `:post_tool_use`,
  `:post_tool_use_failure`).

  The `:tool_name` field in the matcher can be an exact binary string or a regex
  pattern. Invalid regex patterns raise at registration time (fail-fast).

  ## Example

  ```elixir
  # Only fire for Write and Edit tools:
  hook = BeamAgent.Hooks.hook(
    :pre_tool_use,
    fn ctx ->
      IO.puts("File mutation: \#{Map.get(ctx, :tool_name, "")}")
      :ok
    end,
    %{tool_name: "^(Write|Edit)$"}
  )
  ```
  """
  @spec hook(hook_event(), hook_callback(), hook_matcher()) ::
          %{
            required(:event) => hook_event(),
            required(:callback) => hook_callback(),
            required(:matcher) => hook_matcher(),
            required(:compiled_re) => :re.mp()
          }
  defdelegate hook(event, callback, matcher), to: :beam_agent_hooks

  @doc """
  Create an empty hook registry.

  Returns a new `hook_registry()` map with no registered hooks.
  """
  @spec new_registry() :: %{}
  def new_registry, do: %{}

  @doc """
  Register a single hook in the registry.

  Adds `hook_def` to the registry under its event key. Hooks are prepended
  internally (O(1)) and reversed at fire time to preserve registration order.

  Returns the updated registry.

  ## Example

  ```elixir
  registry =
    BeamAgent.Hooks.new_registry()
    |> then(fn r ->
         BeamAgent.Hooks.register_hook(
           BeamAgent.Hooks.hook(:stop, fn _ -> :ok end),
           r
         )
       end)
  ```
  """
  @spec register_hook(hook_def(), hook_registry()) :: hook_registry()
  defdelegate register_hook(hook, registry), to: :beam_agent_hooks

  @doc """
  Register multiple hooks in the registry.

  Adds all hook definitions to the registry in list order.

  Returns the updated registry.
  """
  @spec register_hooks([hook_def()], hook_registry()) :: hook_registry()
  defdelegate register_hooks(hooks, registry), to: :beam_agent_hooks

  @doc """
  Fire all hooks registered for an event.

  Context is threaded through the hook chain: each hook receives the context as
  modified by the previous hook. The final context flows back to the caller via
  `{:ok, final_ctx}`.

  - **Blocking events** (`:pre_tool_use`, `:user_prompt_submit`,
    `:permission_request`, `:subagent_start`, `:pre_compact`,
    `:config_change`): returns `{:ok, final_ctx}` if all hooks allow,
    `{:deny, reason}` on first deny, or `{:ask, reason}` on first ask.

  - **Notification-only events**: always returns `{:ok, final_ctx}`.
    `{:deny, _}` and `{:ask, _}` from callbacks are ignored.

  Handles `nil`/`undefined` registries (no hooks configured) gracefully. Each
  callback is wrapped in a try/catch for crash protection. Blocking hook
  crashes return `{:deny, "hook crashed (fail-safe deny)"}` (fail-closed).
  Notification hook crashes are logged and the context passes through
  unmodified (fail-open).

  ## Example

  ```elixir
  case BeamAgent.Hooks.fire(:pre_tool_use, %{
    event: :pre_tool_use,
    tool_name: "Bash",
    tool_input: %{"command" => "rm -rf /"}
  }, registry) do
    {:ok, final_ctx} -> proceed_with_tool(final_ctx)
    {:deny, reason} -> reject_tool(reason)
    {:ask, reason} -> escalate_to_caller(reason)
  end
  ```
  """
  @spec fire(hook_event(), hook_context(), hook_registry() | :undefined) ::
          {:ok, hook_context()} | {:deny, binary()} | {:ask, binary()}
  defdelegate fire(event, context, registry), to: :beam_agent_hooks

  @doc """
  Build a hook registry from a list of hook definitions.

  Convenience function that creates a new registry and registers all provided
  hooks. Returns `nil` when the input is an empty list or `nil` (no hooks
  configured).

  Used by all adapter session modules during init to convert the `:sdk_hooks`
  option into a registry.

  ## Example

  ```elixir
  hooks = [
    BeamAgent.Hooks.hook(:pre_tool_use, &deny_bash/1),
    BeamAgent.Hooks.hook(:post_tool_use, &log_tool/1)
  ]
  registry = BeamAgent.Hooks.build_registry(hooks)
  ```
  """
  @spec build_registry([hook_def()] | :undefined) :: hook_registry() | :undefined
  defdelegate build_registry(opts), to: :beam_agent_hooks

  # -------------------------------------------------------------------
  # Global Hooks
  # -------------------------------------------------------------------

  @doc """
  Create the global hooks ETS table. Idempotent.

  The global hook table is an `ordered_set` keyed by `{event, seq}` where `seq`
  is a monotonically increasing integer assigned at registration time. This
  guarantees deterministic firing order across all OTP versions. Called
  automatically by `BeamAgent.init/0`. Safe to call multiple times — subsequent
  calls are no-ops.
  """
  @spec ensure_global_table() :: :ok
  defdelegate ensure_global_table(), to: :beam_agent_hooks

  @doc """
  Register a hook globally (fires for every session).

  Inserts the hook into the global ETS table and notifies the reload bus so live
  sessions pick up the change. The table is created automatically if it does not
  exist yet.

  ## Example

  ```elixir
  hook = BeamAgent.Hooks.hook(:pre_tool_use, fn ctx ->
    case Map.get(ctx, :tool_name) do
      "Bash" -> {:deny, "No Bash globally"}
      _ -> {:ok, ctx}
    end
  end)

  :ok = BeamAgent.Hooks.register_global(hook)
  ```
  """
  @spec register_global(hook_def()) :: :ok
  defdelegate register_global(hook_def), to: :beam_agent_hooks

  @doc """
  Unregister a hook from the global registry.

  Removes the exact hook object. Other hooks for the same event are unaffected.
  Notifies the reload bus after removal.

  Returns `:ok` even if the hook was not found (idempotent).
  """
  @spec unregister_global(hook_def()) :: :ok
  defdelegate unregister_global(hook_def), to: :beam_agent_hooks

  @doc """
  Read the entire global hook registry as a `hook_registry()` map.

  Returns a map from event atoms to lists of hook definitions, mirroring the
  shape of per-session registries. Returns an empty map if no global hooks are
  registered.
  """
  @spec global_registry() :: hook_registry()
  defdelegate global_registry(), to: :beam_agent_hooks
end
