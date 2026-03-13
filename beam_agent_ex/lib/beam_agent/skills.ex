defmodule BeamAgent.Skills do
  @moduledoc """
  Skill management for the BeamAgent SDK.

  This module provides skill lifecycle operations -- listing local and remote
  skills, exporting skills to registries, and enabling/disabling skills --
  across all five agentic coder backends (Claude, Codex, Gemini, OpenCode,
  Copilot).

  Skills are reusable prompt templates or multi-step workflows that extend an
  agent's capabilities. They can be local (installed in the project) or remote
  (available from a shared registry for import).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with skills through `BeamAgent`. Use this module
  directly when you need focused access to skill operations -- for example,
  in a skill management UI, a skill marketplace browser, or a configuration
  tool that bulk-enables/disables skills.

  ## Quick example

  ```elixir
  # List local skills:
  {:ok, skills} = BeamAgent.Skills.list(session)
  for s <- skills, do: IO.puts(s.name)

  # Browse remote registry:
  {:ok, remote} = BeamAgent.Skills.remote_list(session)

  # Enable a skill:
  {:ok, _} = BeamAgent.Skills.config_write(session, "/skills/review.md", true)

  # Disable a skill:
  {:ok, _} = BeamAgent.Skills.config_write(session, "/skills/review.md", false)
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_skills` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying skill data is stored in ETS tables managed by
  `:beam_agent_skills_core`.

  See also: `BeamAgent`, `BeamAgent.Config`, `BeamAgent.Catalog`.
  """

  @doc """
  List skills for the session using native-first routing.

  Equivalent to `list/2` with empty options.
  Attempts the backend's native skill listing first; if the backend does
  not support native skill listing, falls back to `list_skills/1`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, skills}` where `skills` is a list of skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  @spec list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session), to: :beam_agent_skills

  @doc """
  List skills for the session with filter options.

  Returns skills matching the provided filters. Skills are reusable prompt
  templates or multi-step workflows. Use the filter options to narrow
  results by category, enabled state, or name pattern.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:category` -- binary category to filter by
    - `:enabled` -- boolean to filter by enabled/disabled state
    - `:name_pattern` -- binary pattern to match against skill names

  ## Returns

  - `{:ok, skills}` where `skills` is a list of skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  @spec list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session, opts), to: :beam_agent_skills

  @doc """
  List skills available from the remote registry.

  Equivalent to `remote_list/2` with empty options.
  Queries the remote skill registry for skills that can be imported into
  the session. Remote skills are community or organization-shared
  templates not yet installed locally.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, skills}` where `skills` is a list of remote skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  @spec remote_list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate remote_list(session), to: :beam_agent_skills

  @doc """
  List skills from the remote registry with filter options.

  Queries the remote skill registry and filters results. Use this to
  search for specific skills by registry source, category, or name
  before importing them into the session.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:registry` -- binary registry identifier to query
    - `:category` -- binary category to filter by
    - `:name` -- binary name or name pattern to match

  ## Returns

  - `{:ok, skills}` where `skills` is a list of remote skill maps, each
    containing `:name`, `:description`, and `:path`.
  - `{:error, reason}` on failure.
  """
  @spec remote_list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate remote_list(session, opts), to: :beam_agent_skills

  @doc """
  Export a local skill to a remote registry.

  Publishes a skill definition from the session's local skill store to a
  remote registry, making it available for other users or sessions to
  import. The skill must already exist locally.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- export options map. Required keys:
    - `:skill_path` -- binary file path identifying the local skill to export

  ## Returns

  - `{:ok, result_map}` where `result_map` contains export confirmation
    details such as the remote registry URL and export status.
  - `{:error, reason}` on failure.
  """
  @spec remote_export(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate remote_export(session, opts), to: :beam_agent_skills

  @doc """
  Enable or disable a skill by its file path.

  Writes a configuration entry that controls whether a skill is active.
  When disabled, the skill remains in the registry but is not available
  for use in queries. Re-enable by calling with `enabled: true`.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary file path identifying the skill (as returned in the
    `:path` field of skill maps from `list/1`).
  - `enabled` -- boolean: `true` to enable, `false` to disable.

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:path` (the skill
    path) and `:enabled` (the new boolean state).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, _} = BeamAgent.Skills.config_write(session, "/skills/review.md", false)
  """
  @spec config_write(pid(), binary(), boolean()) :: {:ok, map()} | {:error, term()}
  defdelegate config_write(session, path, enabled), to: :beam_agent_skills
end
