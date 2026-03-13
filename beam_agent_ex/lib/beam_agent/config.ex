defmodule BeamAgent.Config do
  @moduledoc """
  Configuration management for the BeamAgent SDK.

  This module provides configuration operations -- reading, updating, writing
  individual values and batches, querying requirements, and detecting/importing
  external agent configurations -- across all five agentic coder backends
  (Claude, Codex, Gemini, OpenCode, Copilot).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with configuration through `BeamAgent`. Use this module
  directly when you need focused access to configuration operations -- for
  example, in a settings UI, a configuration migration script, or a tool that
  imports `.cursorrules` or `CLAUDE.md` files from other agentic tools.

  ## Quick example

  ```elixir
  # Read the full config:
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
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_config` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation.

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
  @spec read(pid()) :: {:ok, map()} | {:error, term()}
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
  @spec read(pid(), map()) :: {:ok, map()} | {:error, term()}
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
  @spec update(pid(), map()) :: {:ok, map()} | {:error, term()}
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
  @spec providers(pid()) :: {:ok, term()} | {:error, term()}
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
  @spec value_write(pid(), binary(), term()) :: {:ok, term()} | {:error, term()}
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
  @spec value_write(pid(), binary(), term(), map()) :: {:ok, term()} | {:error, term()}
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
  @spec batch_write(pid(), [map()]) :: {:ok, term()} | {:error, term()}
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
  @spec batch_write(pid(), [map()], map()) :: {:ok, term()} | {:error, term()}
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
  @spec requirements_read(pid()) :: {:ok, term()} | {:error, term()}
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
  @spec external_agent_detect(pid()) :: {:ok, term()} | {:error, term()}
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
  @spec external_agent_detect(pid(), map()) :: {:ok, term()} | {:error, term()}
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
  @spec external_agent_import(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate external_agent_import(session, opts), to: :beam_agent_config
end
