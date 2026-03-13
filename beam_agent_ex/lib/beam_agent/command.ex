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

  # ---------------------------------------------------------------------------
  # Session-scoped command operations
  # ---------------------------------------------------------------------------

  @doc """
  Perform backend-specific session initialization.

  Called after `BeamAgent.start_session/1` to complete any additional setup
  that requires an active transport connection.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- backend-specific initialization parameters map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec session_init(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate session_init(session, opts), to: :beam_agent_command

  @doc """
  Get all messages for the current session.

  Returns the complete message history for the session's active conversation.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  @spec session_messages(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate session_messages(session), to: :beam_agent_command

  @doc """
  Get messages for the current session with filtering options.

  `opts` may include pagination keys (`:limit`, `:offset`) or filters
  (`:role`, `:type`) to narrow the returned message list.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- filter options map.

  ## Returns

  - `{:ok, messages}` or `{:error, reason}`.
  """
  @spec session_messages(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate session_messages(session, opts), to: :beam_agent_command

  @doc """
  Send a prompt asynchronously without blocking for the full response.

  Convenience wrapper that calls `prompt_async/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.

  ## Returns

  - `{:ok, result_map}` with a `:request_id` key.
  - `{:error, reason}` on failure.
  """
  @spec prompt_async(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate prompt_async(session, prompt), to: :beam_agent_command

  @doc """
  Send a prompt asynchronously with options.

  Submits `prompt` to the backend and returns immediately with a result
  map containing a `:request_id`. Use `BeamAgent.event_subscribe/1` and
  `BeamAgent.receive_event/2` to collect the streamed response.

  ## Parameters

  - `session` -- pid of a running session.
  - `prompt` -- the user prompt as a binary string.
  - `opts` -- query parameters map (`:system_prompt`, `:model`, etc.).

  ## Returns

  - `{:ok, result_map}` or `{:error, reason}`.
  """
  @spec prompt_async(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate prompt_async(session, prompt, opts), to: :beam_agent_command

  @doc """
  Execute a shell command in the session's working directory.

  Convenience wrapper that calls `shell_command/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary shell command string.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec shell_command(pid(), binary()) :: {:ok, map()} | {:error, term()}
  defdelegate shell_command(session, command), to: :beam_agent_command

  @doc """
  Execute a shell command with options.

  Runs `command` as a subprocess in the session's working directory.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary shell command string.
  - `opts` -- options map (`:timeout`, `:env`).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec shell_command(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate shell_command(session, command, opts), to: :beam_agent_command

  @doc """
  Append text to the TUI prompt input buffer.

  Injects `text` into the terminal UI's prompt field as if the user typed it.
  Only meaningful for backends with a native terminal interface.

  ## Parameters

  - `session` -- pid of a running session.
  - `text` -- binary text to append.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec tui_append_prompt(pid(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate tui_append_prompt(session, text), to: :beam_agent_command

  @doc """
  Open the TUI help panel.

  This operation requires a native terminal backend. The universal fallback
  returns a `status: :not_applicable` result.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec tui_open_help(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate tui_open_help(session), to: :beam_agent_command

  @doc """
  Destroy the current session and clean up all associated state.

  Removes the session from the session store, runtime registry, config store,
  feedback store, callback registry, and tool registry. More thorough than
  `BeamAgent.stop/1`, which only terminates the process.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec session_destroy(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate session_destroy(session), to: :beam_agent_command

  @doc """
  Destroy a specific session by its identifier.

  Same as `session_destroy/1` but targets a specific `session_id`, which
  may differ from the calling session's own identifier.

  ## Parameters

  - `session` -- pid of a running session.
  - `session_id` -- binary session identifier to destroy.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec session_destroy(pid(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate session_destroy(session, session_id), to: :beam_agent_command

  @doc """
  Run a command through the backend's command execution facility.

  Convenience wrapper that calls `command_run/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command string or list of binary args.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec command_run(pid(), binary() | [binary()]) :: {:ok, map()} | {:error, term()}
  defdelegate command_run(session, command), to: :beam_agent_command

  @doc """
  Run a command through the backend's command execution facility with options.

  Executes `command` via the backend's native command runner (which may
  apply sandboxing, permission checks, or audit logging).

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command string or list of binary args.
  - `opts` -- options map (`:timeout`, `:env`, `:cwd`).

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec command_run(pid(), binary() | [binary()], map()) :: {:ok, map()} | {:error, term()}
  defdelegate command_run(session, command, opts), to: :beam_agent_command

  @doc """
  Write data to the stdin of a running command.

  Convenience wrapper that calls `command_write_stdin/4` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `process_id` -- binary process identifier from a previous `command_run` call.
  - `stdin` -- binary data to write to stdin.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec command_write_stdin(pid(), binary(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate command_write_stdin(session, process_id, stdin), to: :beam_agent_command

  @doc """
  Write data to the stdin of a running command with options.

  ## Parameters

  - `session` -- pid of a running session.
  - `process_id` -- binary process identifier.
  - `stdin` -- binary data to write.
  - `opts` -- backend-specific options map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec command_write_stdin(pid(), binary(), binary(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate command_write_stdin(session, process_id, stdin, opts), to: :beam_agent_command

  @doc """
  Submit user feedback about the session or a specific response.

  `feedback` may contain `:rating`, `:comment`, and `:message_id`.

  ## Parameters

  - `session` -- pid of a running session.
  - `feedback` -- feedback map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec submit_feedback(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate submit_feedback(session, feedback), to: :beam_agent_command

  @doc """
  Respond to a turn-based request from the backend.

  Some backends issue permission or tool-use requests that require explicit
  approval. `request_id` identifies the pending request; `params` contains
  the response payload (e.g., `%{approved: true}`).

  ## Parameters

  - `session` -- pid of a running session.
  - `request_id` -- binary request identifier.
  - `params` -- response payload map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec turn_respond(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate turn_respond(session, request_id, params), to: :beam_agent_command

  @doc """
  Send a named command to the backend.

  A general-purpose dispatch mechanism for backend-specific commands that
  do not have dedicated API functions.

  ## Parameters

  - `session` -- pid of a running session.
  - `command` -- binary command name.
  - `params` -- map of command arguments.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec send_command(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate send_command(session, command, params), to: :beam_agent_command
end
