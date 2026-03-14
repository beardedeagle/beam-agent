-module(beam_agent_command).
-moduledoc """
Public wrapper for command execution, session lifecycle, and interactive
control operations.

This module consolidates two layers of command functionality:

1. **Direct shell execution** — `run/1,2` execute OS commands via Erlang ports
   through `beam_agent_command_core`. These are backend-agnostic and work
   without a session.

2. **Session-routed commands** — all other functions operate through a backend
   session using `beam_agent_core:native_or/4` for native-first routing with
   universal fallbacks. These include session initialization, prompt dispatch,
   command execution through the backend's facility, stdin writing, feedback
   submission, turn-based responses, and session teardown.

## Direct shell execution

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

## Session-routed commands

```erlang
{ok, _} = beam_agent_command:session_init(Session, #{}).
{ok, _} = beam_agent_command:command_run(Session, <<"ls">>, #{}).
{ok, _} = beam_agent_command:submit_feedback(Session, #{rating => thumbs_up}).
{ok, _} = beam_agent_command:session_destroy(Session).
```

## Error handling

- `{error, {timeout, Ms}}` — command did not finish within the timeout
- `{error, {port_exit, Reason}}` — the port process exited abnormally
- `{error, {port_failed, Reason}}` — the port could not be opened

The exit code of the command is in `exit_code`. A non-zero exit code is NOT
returned as `{error, ...}` -- it is up to the caller to inspect `exit_code`.

## Core concepts

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

## Architecture deep dive

Execution uses spawn_executable ports via beam_agent_command_core. The
command is passed to sh -c for shell interpretation. List-form arguments
are individually single-quote-escaped and space-joined before passing
to the shell.

Output capture is bounded by max_output (default 1 MB) to prevent memory
issues with verbose commands. Timeout enforcement kills the port process
and returns {error, {timeout, Ms}}.

Session-routed commands use `beam_agent_core:native_or/4` for native-first
routing: the backend adapter gets first crack, with universal fallbacks
handling the common case. Interactive commands support stdin writing via
`command_write_stdin/3,4`.
""".

%% Direct shell execution (no session required)
-export([run/1, run/2]).

%% Session-routed command operations
-export([
    session_init/2,
    session_messages/1, session_messages/2,
    prompt_async/2, prompt_async/3,
    shell_command/2, shell_command/3,
    tui_append_prompt/2,
    tui_open_help/1,
    session_destroy/1, session_destroy/2,
    command_run/2, command_run/3,
    command_write_stdin/3, command_write_stdin/4,
    submit_feedback/2,
    turn_respond/3,
    send_command/3
]).

-export_type([command_opts/0, command_result/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

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

%%--------------------------------------------------------------------
%% Direct shell execution (no session required)
%%--------------------------------------------------------------------

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

%%--------------------------------------------------------------------
%% Session-routed command operations
%%--------------------------------------------------------------------

-doc """
Perform backend-specific session initialization.

Called after start_session/1 to complete any additional setup that
requires an active transport connection. Opts may include
backend-specific initialization parameters. The universal fallback
registers the session with the runtime core.
""".
-spec session_init(pid(), map()) -> {ok, term()} | {error, term()}.
session_init(Session, Opts) ->
    beam_agent_core:native_or(Session, session_init, [Opts], fun() ->
        beam_agent_runtime_core:register_session(Session, Opts),
        {ok, beam_agent_core:with_universal_source(Session, #{status => initialized})}
    end).

-doc """
Get all messages for the current session.

Returns the complete message history for the session's active
conversation. Each message is a normalized map with type, role, and
content keys.
""".
-spec session_messages(pid()) -> {ok, term()} | {error, term()}.
session_messages(Session) ->
    beam_agent_core:native_or(Session, session_messages, [], fun() ->
        beam_agent_core:get_session_messages(beam_agent_core:session_identity(Session))
    end).

-doc """
Get messages for the current session with filtering options.

Opts may include pagination keys (limit, offset) or filters
(role, type) to narrow the returned message list. The universal
fallback delegates to get_session_messages/2.
""".
-spec session_messages(pid(), map()) -> {ok, term()} | {error, term()}.
session_messages(Session, Opts) ->
    beam_agent_core:native_or(Session, session_messages, [Opts], fun() ->
        beam_agent_core:get_session_messages(beam_agent_core:session_identity(Session), Opts)
    end).

-doc """
Send a prompt asynchronously without blocking for the full response.

Convenience wrapper that calls prompt_async/3 with empty options.
See prompt_async/3 for details.
""".
-spec prompt_async(pid(), binary()) -> {ok, map()} | {error, _}.
prompt_async(Session, Prompt) ->
    prompt_async(Session, Prompt, #{}).

-doc """
Send a prompt asynchronously with options.

Submits Prompt to the backend and returns immediately with a result
map containing a request_id. The caller should use event_subscribe/1
and receive_event/2 to collect the streamed response. Opts may
include query parameters such as system_prompt or model.

Unlike query/2, this function does not block until completion. It is
the preferred approach for UIs and concurrent workflows.
""".
-spec prompt_async(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
prompt_async(Session, Prompt, Opts) ->
    case beam_agent_core:native_call(Session, prompt_async, [Prompt, Opts]) of
        {ok, Result} ->
            {ok, normalize_prompt_async_result(Session, Result)};
        {error, {unsupported_native_call, _}} ->
            universal_prompt_async(Session, Prompt, Opts);
        {error, _} = Error ->
            Error
    end.

-doc """
Execute a shell command in the session's working directory.

Convenience wrapper that calls shell_command/3 with empty options.
See shell_command/3 for details.
""".
-spec shell_command(pid(), binary()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command) ->
    shell_command(Session, Command, #{}).

-doc """
Execute a shell command with options.

Runs Command as a subprocess in the session's working directory.
Returns a result map containing stdout, stderr, and exit_code. Opts
may include timeout (milliseconds) and env (environment variable
overrides). The universal fallback uses os:cmd/1 or open_port/2.
""".
-spec shell_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
shell_command(Session, Command, Opts) ->
    beam_agent_core:native_or(Session, shell_command, [Command, Opts], fun() ->
        universal_shell_command(Session, Command, Opts)
    end).

-doc """
Append text to the TUI prompt input buffer.

Injects Text into the terminal UI's prompt field as if the user had
typed it. Only meaningful for backends with a native terminal
interface. The universal fallback returns status => not_applicable.
""".
-spec tui_append_prompt(pid(), binary()) -> {ok, term()} | {error, term()}.
tui_append_prompt(Session, Text) ->
    beam_agent_core:native_or(Session, tui_append_prompt, [Text], fun() ->
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>,
            text => Text})}
    end).

-doc """
Open the TUI help panel.

This operation requires a native terminal backend. The universal
fallback returns a not_applicable status.

Parameters:
  - Session: pid of a running session.

Returns {ok, Result} or {error, Reason}.
""".
-spec tui_open_help(pid()) -> {ok, term()} | {error, term()}.
tui_open_help(Session) ->
    beam_agent_core:native_or(Session, tui_open_help, [], fun() ->
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"TUI operations require a native terminal backend">>})}
    end).

-doc """
Destroy the current session and clean up all associated state.

Removes the session from the session store, runtime registry,
config store, feedback store, callback registry, and tool registry.
Also unregisters the session from the backend. This is a more
thorough cleanup than stop/1, which only terminates the process.
""".
-spec session_destroy(pid()) -> {ok, term()} | {error, term()}.
session_destroy(Session) ->
    SessionId = beam_agent_core:session_identity(Session),
    beam_agent_core:native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-doc """
Destroy a specific session by its identifier.

Same as session_destroy/1 but targets a specific SessionId, which
may differ from the calling session's own identifier. Useful for
cleaning up persisted sessions that are no longer needed.
""".
-spec session_destroy(pid(), binary()) -> {ok, term()} | {error, term()}.
session_destroy(Session, SessionId) ->
    beam_agent_core:native_or(Session, session_destroy, [SessionId], fun() ->
        universal_session_destroy(Session, SessionId)
    end).

-doc """
Run a command through the backend's command execution facility.

Convenience wrapper that calls command_run/3 with empty options.
Command may be a single binary or a list of binaries (command + args).
See command_run/3 for details.
""".
-spec command_run(pid(), binary() | [binary()]) ->
    {ok, #{'source' := 'universal', _ => _}} |
    {error, {port_exit, term()} | {port_failed, term()} |
            {timeout, infinity | non_neg_integer()}}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

-doc """
Run a command through the backend's command execution facility with options.

Executes Command via the backend's native command runner (which may
apply sandboxing, permission checks, or audit logging). Falls back
to a universal shell executor when the backend does not support
native command execution. Opts may include timeout, env, and cwd
overrides.
""".
-spec command_run(pid(), binary() | [binary()], map()) ->
    {ok, #{'source' := 'universal', _ => _}} |
    {error, {port_exit, term()} | {port_failed, term()} |
            {timeout, infinity | non_neg_integer()}}.
command_run(Session, Command, Opts) ->
    case beam_agent_core:native_call(Session, command_run, [Command, Opts]) of
        {ok, Result} when is_map(Result) ->
            {ok, beam_agent_core:with_universal_source(Session, Result)};
        {ok, Result} ->
            {ok, beam_agent_core:with_universal_source(Session, #{result => Result})};
        {error, {unsupported_native_call, _}} ->
            universal_command_run(Session, Command, Opts);
        {error, _} ->
            universal_command_run(Session, Command, Opts)
    end.

-doc """
Write data to the stdin of a running command.

Convenience wrapper that calls command_write_stdin/4 with empty options.
See command_write_stdin/4 for details.
""".
-spec command_write_stdin(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin) ->
    command_write_stdin(Session, ProcessId, Stdin, #{}).

-doc """
Write data to the stdin of a running command with options.

Sends Stdin bytes to the process identified by ProcessId (returned
by a previous command_run/3 call). This requires the backend to
maintain an active process handle. The universal fallback returns
status => not_supported since it cannot write to arbitrary process
handles without native backend cooperation.
""".
-spec command_write_stdin(pid(), binary(), binary(), map()) ->
    {ok, term()} | {error, term()}.
command_write_stdin(Session, ProcessId, Stdin, Opts) ->
    beam_agent_core:native_or(Session, command_write_stdin, [ProcessId, Stdin, Opts], fun() ->
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => not_supported,
            reason => <<"Stdin write requires an active native process handle">>,
            process_id => ProcessId})}
    end).

-doc """
Submit user feedback about the session or a specific response.

Feedback is a map that may contain rating (thumbs_up/thumbs_down),
comment (freeform text), and message_id (to associate feedback with
a specific response). The universal fallback stores the feedback in
the control core for later retrieval.
""".
-spec submit_feedback(pid(), map()) -> {ok, term()} | {error, term()}.
submit_feedback(Session, Feedback) ->
    beam_agent_core:native_or(Session, submit_feedback, [Feedback], fun() ->
        universal_submit_feedback(Session, Feedback)
    end).

-doc """
Respond to a turn-based request from the backend.

Some backends issue permission_request or tool_use_request messages
that require explicit user approval. RequestId identifies the pending
request (from the message's request_id field). Params contains the
response payload (e.g., #{approved => true} for permissions).
""".
-spec turn_respond(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
turn_respond(Session, RequestId, Params) ->
    beam_agent_core:native_or(Session, turn_respond, [RequestId, Params], fun() ->
        universal_turn_respond(Session, RequestId, Params)
    end).

-doc """
Send a named command to the backend.

This is a general-purpose dispatch mechanism for backend-specific
commands that do not have dedicated API functions. Command is a
binary name and Params is a map of command arguments. Delegates to
send_control/3 in the universal fallback.
""".
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    beam_agent_core:native_or(Session, send_command, [Command, Params],
        fun() -> beam_agent_core:send_control(Session, Command, Params) end).

%%--------------------------------------------------------------------
%% Private helpers
%%--------------------------------------------------------------------

-spec universal_session_destroy(pid(), binary()) ->
    {ok, #{'source' := 'universal', _ => _}}.
universal_session_destroy(Session, SessionId) ->
    ok = beam_agent_core:delete_session(SessionId),
    ok = beam_agent_runtime_core:clear_session(SessionId),
    ok = beam_agent_control_core:clear_config(SessionId),
    ok = beam_agent_control_core:clear_feedback(SessionId),
    ok = beam_agent_control_core:clear_session_callbacks(SessionId),
    ok = beam_agent_tool_registry:unregister_session_registry(Session),
    case beam_agent_core:session_identity(Session) =:= SessionId of
        true ->
            ok = beam_agent_backend:unregister_session(Session);
        false ->
            ok
    end,
    {ok, beam_agent_core:with_universal_source(Session, #{
        session_id => SessionId,
        destroyed => true
    })}.

-spec normalize_prompt_async_result(pid(), term()) -> map().
normalize_prompt_async_result(Session, Result) when is_map(Result) ->
    beam_agent_core:with_session_backend(Session, maps:merge(#{accepted => true}, Result));
normalize_prompt_async_result(Session, accepted) ->
    beam_agent_core:with_session_backend(Session, #{accepted => true});
normalize_prompt_async_result(Session, true) ->
    beam_agent_core:with_session_backend(Session, #{accepted => true});
normalize_prompt_async_result(Session, Result) ->
    beam_agent_core:with_session_backend(Session, #{
        accepted => true,
        result => Result
    }).

-spec universal_command_run(pid(), binary() | [binary()],
    #{'cwd' => binary() | string(), 'env' => [{[any()], [any()]}],
      'max_output' => pos_integer(), 'timeout' => pos_integer()}) ->
    {ok, #{'backend' := 'claude' | 'codex' | 'copilot' | 'gemini' | 'opencode' | 'undefined',
           'exit_code' := integer(), 'output' := binary(), 'source' := 'universal'}} |
    {error, {port_exit, term()} | {port_failed, term()} |
            {timeout, infinity | non_neg_integer()}}.
universal_command_run(Session, Command, Opts) ->
    case beam_agent_command_core:run(command_to_shell(Command), Opts) of
        {ok, Result} ->
            {ok, Result#{
                source => universal,
                backend => beam_agent_core:session_backend(Session)
            }};
        Error ->
            Error
    end.

-spec universal_prompt_async(pid(), binary(), #{
    'agent' => binary(), 'allowed_tools' => [binary()],
    'approval_policy' => binary(), 'attachments' => [map()],
    'cwd' => binary(), 'disallowed_tools' => [binary()],
    'effort' => binary(), 'max_budget_usd' => number(),
    'max_tokens' => pos_integer(), 'max_turns' => pos_integer(),
    'mode' => binary(), 'model' => binary(), 'model_id' => binary(),
    'output_format' => 'json_schema' | 'text' | binary() | map(),
    'permission_mode' => 'accept_edits' | 'bypass_permissions' | 'default'
                       | 'dont_ask' | 'plan' | binary(),
    'provider' => map(), 'provider_id' => binary(),
    'sandbox_mode' => binary(), 'summary' => binary(),
    'system' => binary() | map(),
    'system_prompt' => binary() | #{'preset' := binary(), 'type' := 'preset',
                                     'append' => binary()},
    'thinking' => map(), 'timeout' => 'infinity' | non_neg_integer(),
    'tools' => [any()] | map()
}) ->
    {ok, #{'source' := 'universal', _ => _}} | {error, _}.
universal_prompt_async(Session, Prompt, Opts) when is_binary(Prompt), is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, 120000),
    case beam_agent_router:send_query(Session, Prompt, Opts, Timeout) of
        {ok, QueryRef} ->
            {ok, beam_agent_core:with_universal_source(Session, #{
                accepted => true,
                query_ref => QueryRef
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_shell_command(pid(), binary(), map()) ->
    {ok, #{source := universal, _ => _}} |
    {error, {port_exit, _} | {port_failed, _} | {timeout, infinity | non_neg_integer()}}.
universal_shell_command(Session, Command, Opts) when is_binary(Command), is_map(Opts) ->
    case command_run(Session, Command, Opts) of
        {ok, Result} when is_map(Result) ->
            {ok, beam_agent_core:with_universal_source(Session, Result)};
        {error, _} = Error ->
            Error
    end.

-spec universal_submit_feedback(pid(), map()) ->
    {ok, #{'backend' := 'claude' | 'codex' | 'copilot' | 'gemini' | 'opencode' | 'undefined',
           'feedback' := map(), 'session_id' := binary(),
           'source' := 'universal', 'stored' := 'true'}}.
universal_submit_feedback(Session, Feedback) when is_map(Feedback) ->
    SessionId = beam_agent_core:session_identity(Session),
    ok = beam_agent_control:submit_feedback(SessionId, Feedback),
    {ok, #{
        session_id => SessionId,
        stored => true,
        source => universal,
        backend => beam_agent_core:session_backend(Session),
        feedback => Feedback
    }}.

-spec universal_turn_respond(pid(), binary(), map()) ->
    {ok, #{'backend' := 'claude' | 'codex' | 'copilot' | 'gemini' | 'opencode' | 'undefined',
           'request_id' := binary(), 'resolved' := 'true',
           'response' := #{'source' := 'universal', _ => _},
           'source' := 'universal'}} |
    {error, 'already_resolved' | 'not_found'}.
universal_turn_respond(Session, RequestId, Params) when is_binary(RequestId), is_map(Params) ->
    SessionId = beam_agent_core:session_identity(Session),
    Response0 = case maps:is_key(response, Params) of
        true -> Params;
        false -> #{response => Params}
    end,
    Response = maps:put(source, universal, Response0),
    case beam_agent_control:resolve_pending_request(SessionId, RequestId, Response) of
        ok ->
            {ok, #{
                request_id => RequestId,
                resolved => true,
                source => universal,
                backend => beam_agent_core:session_backend(Session),
                response => Response
            }};
        Error ->
            Error
    end.

-spec command_to_shell(binary() | [binary()]) -> binary() | string().
command_to_shell(Command) when is_binary(Command) ->
    Command;
command_to_shell(Command) when is_list(Command), Command =:= [] ->
    Command;
command_to_shell(Command) when is_list(Command) ->
    Joined = string:join([shell_escape_segment(Segment) || Segment <- Command], " "),
    unicode:characters_to_binary(Joined).

-spec shell_escape_segment(binary() | string()) -> string().
shell_escape_segment(Segment) ->
    Raw = unicode:characters_to_list(Segment),
    [$' | escape_single_quotes(Raw)] ++ [$'].

-spec escape_single_quotes(string()) -> string().
escape_single_quotes([]) ->
    [];
escape_single_quotes([$' | Rest]) ->
    [$', $\\, $', $' | escape_single_quotes(Rest)];
escape_single_quotes([Char | Rest]) ->
    [Char | escape_single_quotes(Rest)].
