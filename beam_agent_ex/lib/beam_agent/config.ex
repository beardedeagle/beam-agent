defmodule BeamAgent.Config do
  @moduledoc """
  Unified configuration management for the BeamAgent SDK.

  This module provides both per-session configuration operations (reading,
  updating, writing individual values and batches, querying requirements,
  detecting/importing external agent configurations) and global SDK-wide
  settings (a shared key-value store that applies across all sessions).

  Per-session operations work across all five agentic coder backends
  (Claude, Codex, Gemini, OpenCode, Copilot) via native-first routing with
  universal fallbacks. Global operations use an ETS-backed store.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with configuration through `BeamAgent`. Use this module
  directly when you need focused access to configuration operations -- for
  example, in a settings UI, a configuration migration script, a tool that
  imports `.cursorrules` or `CLAUDE.md` files from other agentic tools, or
  during application startup to set SDK-wide defaults.

  ## Quick example

  ```elixir
  # Read the full session config:
  {:ok, config} = BeamAgent.Config.read(session)

  # Update a setting:
  {:ok, _} = BeamAgent.Config.update(session, %{model: "claude-sonnet-4-20250514"})

  # Write a single value:
  {:ok, _} = BeamAgent.Config.value_write(session, "permissions.mode", "full")

  # Batch write:
  {:ok, _} = BeamAgent.Config.batch_write(session, [
    %{key_path: "model", value: "claude-sonnet-4-20250514"},
    %{key_path: "permissions.mode", value: "full"}
  ])

  # Detect external agent configs:
  {:ok, configs} = BeamAgent.Config.external_agent_detect(session)

  # Global SDK config:
  :ok = BeamAgent.Config.global_set("max_retries", 3)
  {:ok, 3} = BeamAgent.Config.global_get("max_retries")
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_config` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. Session
  config uses native-first routing; global config uses an ETS-backed store.

  See also: `BeamAgent`, `BeamAgent.Provider`, `BeamAgent.Runtime`.
  """

  @doc """
  Read the full configuration for a session.

  Returns the merged configuration map that governs the session's
  behavior. This includes model settings, permission mode, system
  prompt, working directory, and any backend-specific keys.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, config_map}` or `{:error, reason}`.
  """
  @spec read(pid() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate read(session), to: :beam_agent_config

  @doc """
  Read the session configuration with additional options.

  `opts` can filter or transform the returned configuration. The exact
  keys accepted depend on the backend.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter/transform options map.

  ## Returns

  - `{:ok, config_map}` or `{:error, reason}`.
  """
  @spec read(pid() | binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate read(session, opts), to: :beam_agent_config

  @doc """
  Update the session configuration with a partial patch.

  Merges `body` into the existing configuration. Only the keys present
  in `body` are changed; all other keys are preserved.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- map of configuration key-value pairs to update.

  ## Returns

  - `{:ok, updated_config}` or `{:error, reason}`.
  """
  @spec update(pid() | binary(), map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate update(session, body), to: :beam_agent_config

  @doc """
  List the providers available in the session configuration.

  A provider represents an LLM service endpoint (e.g., Anthropic,
  OpenAI, Google).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, providers}` or `{:error, reason}`.
  """
  @spec providers(pid() | binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate providers(session), to: :beam_agent_config

  @doc """
  Write a single configuration value at the given key path.

  Convenience wrapper that calls `value_write/4` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `key_path` -- dot-separated binary identifying the config key
    (e.g., `"model"`, `"permissions.mode"`).
  - `value` -- the new value to store.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec value_write(pid() | binary(), binary(), term()) :: {:ok, map()} | {:error, term()}
  defdelegate value_write(session, key_path, value), to: :beam_agent_config

  @doc """
  Write a single configuration value at the given key path with options.

  `key_path` is a dot-separated binary identifying the configuration key.
  `opts` may include backend-specific write options such as scope or
  persistence level.

  ## Parameters

  - `session` -- pid of a running session.
  - `key_path` -- dot-separated binary config key path.
  - `value` -- the new value to store.
  - `opts` -- backend-specific write options map.

  ## Returns

  - `{:ok, result}` on success.
  - `{:error, reason}` if the key is read-only or the value is invalid.
  """
  @spec value_write(pid() | binary(), binary(), term(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate value_write(session, key_path, value, opts), to: :beam_agent_config

  @doc """
  Write multiple configuration values in a single batch.

  Convenience wrapper that calls `batch_write/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `edits` -- list of maps, each containing a `:key_path` and `:value`.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec batch_write(pid() | binary(), [map()]) :: {:ok, map()} | {:error, term()}
  defdelegate batch_write(session, edits), to: :beam_agent_config

  @doc """
  Write multiple configuration values in a single batch with options.

  All edits are applied atomically when the backend supports it.

  ## Parameters

  - `session` -- pid of a running session.
  - `edits` -- list of maps, each containing a `:key_path` and `:value`.
  - `opts` -- backend-specific write options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}` if any edit fails validation.
  """
  @spec batch_write(pid() | binary(), [map()], map()) :: {:ok, map()} | {:error, term()}
  defdelegate batch_write(session, edits, opts), to: :beam_agent_config

  @doc """
  Read the configuration requirements for a session.

  Returns the set of required configuration keys and their constraints
  (types, allowed values, defaults). Useful for building configuration
  UIs or validating user input before calling `update/2`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, requirements}` or `{:error, reason}`.
  """
  @spec requirements_read(pid() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate requirements_read(session), to: :beam_agent_config

  @doc """
  Detect external agent configuration files in the project.

  Scans the session's working directory for configuration files from
  other agentic tools (e.g., `.cursorrules`, `CLAUDE.md`, `.github/copilot`).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, configs}` or `{:error, reason}`.
  """
  @spec external_agent_detect(pid() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate external_agent_detect(session), to: :beam_agent_config

  @doc """
  Detect external agent configuration files with options.

  `opts` may include filters such as a list of specific config formats
  to detect or directories to scan.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- detection options map.

  ## Returns

  - `{:ok, configs}` or `{:error, reason}`.
  """
  @spec external_agent_detect(pid() | binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate external_agent_detect(session, opts), to: :beam_agent_config

  @doc """
  Import an external agent configuration into the session.

  Takes a previously detected external config (from
  `external_agent_detect/1`) and merges its settings into the
  session configuration.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- import options map (should include the path or identifier
    of the config to import).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec external_agent_import(pid() | binary(), map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate external_agent_import(session, opts), to: :beam_agent_config

  # -------------------------------------------------------------------
  # Global SDK Configuration
  # -------------------------------------------------------------------

  @doc """
  Create the global SDK config ETS table. Idempotent.

  Call this during application startup or before first use of any
  `global_*` function.
  """
  @spec ensure_table() :: :ok
  defdelegate ensure_table(), to: :beam_agent_config

  @doc """
  Set a global SDK config key-value pair.

  Global config is shared across all sessions on the node. Mutations
  notify the reload bus so live sessions react without restart.

  ## Parameters

  - `key` -- binary config key (e.g., `"default_backend"`, `"max_retries"`).
  - `value` -- any term to store.
  """
  @spec global_set(:beam_agent_config.config_key(), :beam_agent_config.config_value()) :: :ok
  defdelegate global_set(key, value), to: :beam_agent_config

  @doc """
  Fetch a global SDK config value by key.

  ## Returns

  - `{:ok, value}` if the key exists.
  - `{:error, :not_found}` if the key has not been set.
  """
  @spec global_get(:beam_agent_config.config_key()) ::
          {:ok, :beam_agent_config.config_value()} | {:error, :not_found}
  defdelegate global_get(key), to: :beam_agent_config

  @doc """
  Fetch a global SDK config value by key, returning a default if not found.

  ## Parameters

  - `key` -- binary config key.
  - `default` -- value returned when the key does not exist.
  """
  @spec global_get(:beam_agent_config.config_key(), :beam_agent_config.config_value()) ::
          :beam_agent_config.config_value()
  defdelegate global_get(key, default), to: :beam_agent_config

  @doc """
  Delete a global SDK config key. Idempotent.
  """
  @spec global_delete(:beam_agent_config.config_key()) :: :ok
  defdelegate global_delete(key), to: :beam_agent_config

  @doc """
  List all global SDK config entries.

  Returns a list of `{key, value}` tuples.
  """
  @spec global_list() :: [:beam_agent_config.config_entry()]
  defdelegate global_list(), to: :beam_agent_config

  @doc """
  Remove all global SDK config entries.
  """
  @spec global_clear() :: :ok
  defdelegate global_clear(), to: :beam_agent_config

  # -------------------------------------------------------------------
  # Universal Fallback API
  # -------------------------------------------------------------------

  @doc """
  Read the universal config/provider view for a live session pid or persisted
  session id.

  This is the universal (non-native) implementation exported so backend facades
  can delegate to it directly.
  """
  @spec config_read(pid() | binary()) :: {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate config_read(session), to: :beam_agent_config

  @doc """
  Apply universal config updates for backends without native config APIs.
  """
  @spec config_update(pid() | binary(), map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate config_update(session, body), to: :beam_agent_config

  @doc """
  Write a single universal config value at a dot-separated key path.
  """
  @spec config_value_write(pid() | binary(), binary(), term(), map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate config_value_write(session, key_path, value, opts), to: :beam_agent_config

  @doc """
  Apply a batch of universal config writes.
  """
  @spec config_batch_write(pid() | binary(), [map()], map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate config_batch_write(session, edits, opts), to: :beam_agent_config

  @doc """
  Describe the universal config keys supported by the canonical fallback.
  """
  @spec config_requirements_read(pid() | binary()) ::
          {:ok,
           %{
             required(:config_sources) => [:control | :runtime | :session, ...],
             required(:control) => %{
               required(:max_thinking_tokens) => :integer,
               required(:permission_mode) => [any(), ...]
             },
             required(:providers) => [map(), ...],
             required(:runtime) => %{
               required(:agent) => :binary,
               required(:mode) => :binary,
               required(:model_id) => :binary,
               required(:provider) => :map,
               required(:provider_id) => :binary,
               required(:system) => [any(), ...],
               required(:tools) => [any(), ...]
             },
             required(:writable_key_paths) => [<<_::64, _::_*8>>, ...]
           }}
  defdelegate config_requirements_read(session), to: :beam_agent_config

  @doc """
  Detect universal config already materialized for a session.
  """
  @spec external_agent_config_detect(pid() | binary(), map()) ::
          {:ok,
           %{
             required(:config) => %{
               required(:control) => map(),
               required(:runtime) => map(),
               required(:session) => map()
             },
             required(:detected) => boolean(),
             required(:source) => :universal
           }}
          | {:error, term()}
  defdelegate external_agent_config_detect(session, opts), to: :beam_agent_config

  @doc """
  Import universal config material from an already-decoded map.
  """
  @spec external_agent_config_import(pid() | binary(), map()) ::
          {:ok, :beam_agent_config.config_view()} | {:error, term()}
  defdelegate external_agent_config_import(session, opts), to: :beam_agent_config

  @doc """
  Describe provider auth methods available through the universal fallback.
  """
  @spec provider_auth_methods(pid() | binary()) :: {:ok, [map()]}
  defdelegate provider_auth_methods(session), to: :beam_agent_config

  @doc """
  Start a universal provider auth flow when native OAuth is unavailable.
  """
  @spec provider_oauth_authorize(pid() | binary(), binary(), map()) ::
          {:ok,
           %{
             required(:auth_method) => <<_::112>>,
             required(:authorize_url) => any(),
             required(:provider) => %{
               required(:auth_methods) => [any(), ...],
               required(:capabilities) => [any(), ...],
               required(:config_keys) => [any()],
               required(:id) => binary(),
               required(:label) => binary(),
               required(:source) => :runtime | :universal_registry
             },
             required(:provider_id) => binary(),
             required(:request_id) => binary(),
             required(:source) => :universal,
             required(:status) => :pending
           }}
  defdelegate provider_oauth_authorize(session, provider_id, body), to: :beam_agent_config

  @doc """
  Complete a universal provider auth flow and persist the callback payload.
  """
  @spec provider_oauth_callback(pid() | binary(), binary(), map()) ::
          {:ok,
           %{
             required(:auth_method) => <<_::112>>,
             required(:provider) => %{
               required(:oauth_callback) => map(),
               required(:provider_id) => binary(),
               required(:source) => :universal
             },
             required(:provider_id) => binary(),
             required(:source) => :universal,
             required(:status) => :configured
           }}
          | {:error, :invalid_api_key | :invalid_provider_config}
  defdelegate provider_oauth_callback(session, provider_id, body), to: :beam_agent_config
end
