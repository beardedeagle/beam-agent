defmodule BeamAgent.Apps do
  @moduledoc """
  App and project management for the BeamAgent SDK.

  This module provides app lifecycle operations -- listing projects, initializing
  project context, logging, and querying app modes -- across all five agentic
  coder backends (Claude, Codex, Gemini, OpenCode, Copilot).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with apps through `BeamAgent`. Use this module directly
  when you need focused access to app operations -- for example, in a project
  switcher UI, a project initialization script, or a log viewer that tails
  app events independently.

  ## Quick example

  ```elixir
  # List all projects:
  {:ok, apps} = BeamAgent.Apps.list(session)
  for app <- apps, do: IO.puts(app.name)

  # Initialize the project context:
  {:ok, ctx} = BeamAgent.Apps.init(session)

  # Get current app info:
  {:ok, info} = BeamAgent.Apps.info(session)
  IO.puts("Project: \#{info.name}, Language: \#{info.language}")

  # Append a log entry:
  {:ok, _} = BeamAgent.Apps.log(session, %{message: "Build started", level: :info})

  # List available modes:
  {:ok, modes} = BeamAgent.Apps.modes(session)
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_apps` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying app data is stored in ETS tables managed by
  `:beam_agent_app_core`.

  See also: `BeamAgent`, `BeamAgent.Config`, `BeamAgent.Runtime`.
  """

  @doc """
  List apps and projects registered for the session.

  Convenience wrapper that calls `list/2` with empty options. Returns
  all known apps/projects associated with the session, both active and
  archived.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, apps}` where `apps` is a list of app maps, each containing
    `:id` (binary), `:name` (binary), `:path` (binary project root),
    and `:status` (atom such as `:active` or `:archived`).
  - `{:error, reason}` on failure.
  """
  @spec list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session), to: :beam_agent_apps

  @doc """
  List apps and projects for the session with filter options.

  Returns a filtered list of apps/projects. Use the options to narrow
  results by status or name, for example to show only active projects
  in a selection UI.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map. Supported keys:
    - `:status` -- atom to filter by (`:active` or `:archived`)
    - `:name` -- binary name or name pattern to match

  ## Returns

  - `{:ok, apps}` where `apps` is a list of app maps, each containing
    `:id` (binary), `:name` (binary), `:path` (binary project root),
    and `:status` (atom).
  - `{:error, reason}` on failure.
  """
  @spec list(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session, opts), to: :beam_agent_apps

  @doc """
  Get information about the current app or project context for a session.

  Returns metadata about the project the session is operating in, including
  the project name, root directory, detected language, and configuration.
  This is populated by `init/1` or automatically when the session starts.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, app_info}` where `app_info` is a map containing `:name` (binary
    project name), `:root_path` (binary absolute path to the project root),
    `:language` (binary detected primary language, e.g., `"elixir"`),
    and `:config` (map of project-level configuration).
  - `{:error, reason}` on failure.
  """
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate info(session), to: :beam_agent_apps

  @doc """
  Initialize the app/project context by scanning the working directory.

  Detects the project type, primary language, build system, and other
  project metadata by inspecting files in the session's working directory
  (e.g., `mix.exs` for Elixir, `rebar.config` for Erlang, `package.json`
  for Node.js). The detected context is stored and returned by subsequent
  `info/1` calls.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result_map}` with the initialized project context.
  - `{:error, reason}` on failure.
  """
  @spec init(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate init(session), to: :beam_agent_apps

  @doc """
  Append a log entry to the session's app log.

  Records a structured log message associated with the current app/project.
  Useful for tracking significant events, warnings, or debugging information
  during an agent session. Log entries are stored in the session's ETS-backed
  app log.

  ## Parameters

  - `session` -- pid of a running session.
  - `body` -- log entry map. Supported keys:
    - `:message` -- (required) binary log message text
    - `:level` -- (optional) atom log level (e.g., `:info`, `:warn`, `:error`)
    - `:category` -- (optional) binary category for grouping log entries
    - `:metadata` -- (optional) map of additional key-value pairs

  ## Returns

  - `{:ok, %{status: :logged}}` on success.
  - `{:error, reason}` on failure.
  """
  @spec log(pid(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate log(session, body), to: :beam_agent_apps

  @doc """
  List available app modes for the session.

  App modes are configuration presets that change the agent's behavior for
  the current project. Common modes include `:default` (standard operation),
  `:debug` (verbose output with additional diagnostics), and `:verbose`
  (extra logging). Each mode is a named preset that sets multiple
  configuration keys at once.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, modes}` where `modes` is a list of mode maps, each describing
    a named configuration preset with its settings.
  - `{:error, reason}` on failure.
  """
  @spec modes(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate modes(session), to: :beam_agent_apps
end
