defmodule BeamAgent.Command do
  @moduledoc """
  Shell command execution for the BeamAgent SDK.

  This module provides a unified interface for running operating-system shell
  commands from within any backend session handler or application code. Execution
  is performed via Erlang ports using `spawn_executable` so it is safe,
  timeout-aware, and captures both stdout and stderr.

  ## When to use directly vs through `BeamAgent`

  Use this module directly when your code needs to run OS-level commands — for
  example, in a custom tool handler, a test helper, or a build step executed as
  part of an agentic workflow.

  ## Basic usage

  ```elixir
  {:ok, %{exit_code: 0, output: out}} = BeamAgent.Command.run("ls -la")

  {:ok, %{exit_code: code, output: out}} = BeamAgent.Command.run("make test", %{
    cwd: "/my/project",
    timeout: 60_000
  })
  ```

  ## Argument list form

  Pass a list of binaries or strings to avoid shell quoting issues:

  ```elixir
  {:ok, result} = BeamAgent.Command.run(["git", "log", "--oneline"])
  ```

  Each segment is single-quote-escaped and joined with spaces before being passed
  to `sh -c`.

  ## Error handling

  - `{:error, {:timeout, ms}}` — command did not finish within the timeout
  - `{:error, {:port_exit, reason}}` — the port process exited abnormally
  - `{:error, {:port_failed, reason}}` — the port could not be opened

  A non-zero exit code is **not** returned as `{:error, ...}` — inspect
  `exit_code` in the result map.
  """

  @typedoc """
  Options accepted by `run/2`.

  All fields are optional:
  - `:timeout` — maximum execution time in milliseconds (default: 30_000)
  - `:cwd` — working directory for the spawned process
  - `:env` — extra environment variables as `[{"KEY", "VALUE"}]` string pairs
  - `:max_output` — maximum bytes of output to capture (default: 1_048_576 = 1 MB)
  """
  @type command_opts() :: map()

  @typedoc """
  Map returned on successful command completion.

  Fields:
  - `:exit_code` — OS exit code; `0` conventionally means success
  - `:output` — captured stdout and stderr as a single binary
  """
  @type command_result() :: map()

  @doc """
  Run a shell command with default options.

  Accepts a binary command string, a plain string, or a list of binary/string
  segments (which are individually shell-escaped and joined with spaces).

  Returns `{:ok, command_result()}` on completion (regardless of exit code), or
  `{:error, reason}` if the port could not be started or timed out.

  ## Example

  ```elixir
  {:ok, %{exit_code: 0, output: bin}} = BeamAgent.Command.run("echo hello")
  ```
  """
  @spec run(binary() | String.t() | [binary() | String.t()]) ::
          {:ok, command_result()} | {:error, term()}
  defdelegate run(command), to: :beam_agent_command

  @doc """
  Run a shell command with explicit options.

  Parameters:
  - `command` — binary string, plain string, or list of segments
  - `opts` — a `command_opts()` map controlling timeout, cwd, env, and max output

  ## Example

  ```elixir
  {:ok, result} = BeamAgent.Command.run("npm test", %{
    cwd: "/srv/app",
    timeout: 120_000,
    env: [{"NODE_ENV", "test"}]
  })
  %{exit_code: code, output: out} = result
  ```
  """
  @spec run(binary() | String.t() | [binary() | String.t()], command_opts()) ::
          {:ok, command_result()} | {:error, term()}
  defdelegate run(command, opts), to: :beam_agent_command
end
