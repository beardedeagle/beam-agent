-module(beam_agent_command).
-moduledoc """
Public wrapper for the consolidated shell command execution layer.

Use this module to run operating-system shell commands from within any backend
session handler or application code. Execution is performed via Erlang ports
using `spawn_executable` so it is safe, timeout-aware, and captures both stdout
and stderr.

## Basic usage

```erlang
{ok, #{exit_code := 0, output := Out}} = beam_agent_command:run(<<"ls -la">>).

{ok, #{exit_code := ExitCode, output := Out}} =
    beam_agent_command:run(<<"make test">>, #{
        cwd     => <<"/my/project">>,
        timeout => 60000
    }).
```

## Argument list form

Pass a list of binaries or strings to avoid shell quoting issues:

```erlang
{ok, Result} = beam_agent_command:run([<<"git">>, <<"log">>, <<"--oneline">>]).
```

Each segment is single-quote-escaped and joined with spaces before being
passed to `sh -c`.

## Error handling

- `{error, {timeout, Ms}}` — command did not finish within the timeout
- `{error, {port_exit, Reason}}` — the port process exited abnormally
- `{error, {port_failed, Reason}}` — the port could not be opened

The exit code of the command is in `exit_code`. A non-zero exit code is NOT
returned as `{error, ...}` -- it is up to the caller to inspect `exit_code`.

== Core concepts ==

This module runs shell commands from your Erlang code. Use run/1 with a
command string to execute it and get back the output and exit code. Use
run/2 to pass options like a working directory, timeout, or environment
variables.

Commands run in a separate OS process via Erlang ports. The SDK captures
both stdout and stderr into a single output binary. A non-zero exit code
is not an error -- you need to check exit_code yourself to see if the
command succeeded.

You can also pass a list of binaries instead of a single command string.
Each segment is shell-escaped automatically, which avoids quoting issues
with spaces or special characters.

== Architecture deep dive ==

Execution uses spawn_executable ports via beam_agent_command_core. The
command is passed to sh -c for shell interpretation. List-form arguments
are individually single-quote-escaped and space-joined before passing
to the shell.

Output capture is bounded by max_output (default 1 MB) to prevent memory
issues with verbose commands. Timeout enforcement kills the port process
and returns {error, {timeout, Ms}}.

When called through beam_agent:command_run/2-3, commands go through the
native_or routing pattern: the backend adapter gets first crack, with
the universal fallback delegating to beam_agent_command_core. Stdin
writing (via beam_agent:command_write_stdin) supports long-running
interactive commands.
""".

-export([run/1, run/2]).
-export_type([command_opts/0, command_result/0]).

-doc """
Type alias for options accepted by `run/2`.

Fields (all optional):
- `timeout` — maximum execution time in milliseconds (default: 30 000)
- `cwd` — working directory for the spawned process
- `env` — extra environment variables as `[{\"KEY\", \"VALUE\"}]` string pairs
- `max_output` — maximum bytes of output to capture (default: 1 048 576 = 1 MB)
""".
-type command_opts() :: beam_agent_command_core:command_opts().

-doc """
Map returned on successful command completion.

Fields:
- `exit_code` — OS exit code; `0` conventionally means success
- `output` — captured stdout and stderr as a single binary
""".
-type command_result() :: beam_agent_command_core:command_result().

-doc """
Run a shell command with default options.

Accepts a binary command string, a plain string, or a list of binary/string
segments (which are individually shell-escaped and joined with spaces).

Returns `{ok, command_result()}` on completion (regardless of exit code), or
`{error, Reason}` if the port could not be started or timed out.

```erlang
{ok, #{exit_code := 0, output := Bin}} = beam_agent_command:run(<<"echo hello">>).
```
""".
-spec run(binary() | string() | [binary() | string()]) ->
    {ok, command_result()} | {error, term()}.
run(Command) -> beam_agent_command_core:run(Command).

-doc """
Run a shell command with explicit options.

Parameters:
- `Command` — binary string, plain string, or list of segments
- `Opts` — a `command_opts()` map controlling timeout, cwd, env, and max output

```erlang
{ok, Result} = beam_agent_command:run(<<"npm test">>, #{
    cwd     => <<"/srv/app">>,
    timeout => 120_000,
    env     => [{\"NODE_ENV\", \"test\"}]
}).
#{exit_code := Code, output := Out} = Result.
```
""".
-spec run(binary() | string() | [binary() | string()], command_opts()) ->
    {ok, command_result()} | {error, term()}.
run(Command, Opts) -> beam_agent_command_core:run(Command, Opts).
