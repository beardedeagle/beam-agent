-module(beam_agent_command_core).
-moduledoc """
Universal command execution for the BEAM Agent SDK.

Provides shell command execution across all adapters via Erlang
ports. Any adapter can run commands regardless of whether the
underlying CLI supports it natively.

Uses `erlang:open_port/2` with `spawn_executable` for safe,
timeout-aware, output-captured command execution.

## Security

When the security guard (`beam_agent_command_guard`) is running, every
command is evaluated through the security pipeline before execution:

  1. **Parser** (Layer 0) — structural analysis
  2. **Policy** (Layer 1) — static deny/allow rules
  3. **Validator** (Layer 2) — pluggable validation
  4. **Guard** (Layer 3) — rate limits, temporal patterns

If the guard is running, commands use the full stateful security pipeline.
If it is not running, commands still go through the default stateless
deny-policy baseline before execution.

## Process Restrictions

When requested via options, the SDK applies process restrictions on
the calling process during command execution:

  - **max_heap_size** — VM-enforced memory limit; the calling process
    is killed if it exceeds the threshold during command execution.
    Only applied when `max_heap` option is explicitly set.  Restored
    to the previous value after command completion (temporary).

  - **sensitive mode** — `process_flag(sensitive, true)` prevents
    `process_info` from leaking command arguments or output from
    credential-handling commands.

    **WARNING: This flag is PERMANENT and IRREVERSIBLE.**  The BEAM VM
    provides no `process_flag(sensitive, false)`.  Once set, the
    calling process remains sensitive for the rest of its lifetime.
    This means:

      - `process_info(Pid, messages)` returns `[]`
      - `process_info(Pid, backtrace)` returns `<<>>`
      - `process_info(Pid, dictionary)` returns `[]`
      - Crash dumps omit this process's state
      - Debuggers and observers cannot inspect this process

    If your calling process is a long-lived session handler,
    GenServer, or supervision tree member, setting `sensitive => true`
    will make that process opaque to all diagnostic tooling forever.

    **Recommended pattern for sensitive commands:**  Spawn a short-lived
    wrapper process, call `run/2` with `sensitive => true` inside it,
    and let the wrapper die after the command completes.  The sensitivity
    dies with the process:

    ```erlang
    run_sensitive(Command, Opts) ->
        Caller = self(),
        Ref = make_ref(),
        spawn_link(fun() ->
            Result = beam_agent_command_core:run(Command,
                Opts#{sensitive => true}),
            Caller ! {Ref, Result}
        end),
        receive {Ref, Result} -> Result end.
    ```

    This keeps your main process inspectable while ensuring the
    credential-handling command runs in an opaque context.

## Guard Integration

When the security guard is running, each command's port handle is
registered for cooperative lockdown.  On lockdown, the guard sends a
`{beam_agent_lockdown, Port, Reason}` message to the port owner, and
the output collection aborts cleanly.  The calling process is never
killed — it receives an error result.

After execution, the result is recorded in the guard's history for
temporal pattern detection.

## Telemetry

When the `telemetry` library is present, every command execution emits
span events under the `[:beam_agent, command, run, ...]` prefix:

  - `[:beam_agent, command, run, start]` — emitted before port open.
    Metadata: `command` (binary, truncated to 512 bytes), `cwd`.
  - `[:beam_agent, command, run, stop]` — emitted on completion.
    Measurements: `duration`. Metadata: `command`, `cwd`, `exit_code`.
  - `[:beam_agent, command, run, exception]` — emitted on timeout or
    port failure. Metadata: `command`, `cwd`, `reason`.

Usage:
```erlang
{ok, Result} = beam_agent_command_core:run(<<"ls -la">>),
#{exit_code := 0, output := Output} = Result.

{ok, Result} = beam_agent_command_core:run(<<"pwd">>,
    #{cwd => <<"/tmp">>, timeout => 5000}).
```
""".

-export([
    run/1,
    run/2
]).

-export_type([command_opts/0, command_result/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Options for command execution.
-type command_opts() :: #{
    timeout => pos_integer(),      %% ms, default 30000
    cwd => binary() | string(),    %% working directory
    env => [{string(), string()}], %% environment variables
    max_output => pos_integer(),   %% max output bytes, default 1MB
    max_heap => pos_integer(),     %% max caller heap words (temporary, restored)
    sensitive => boolean()         %% PERMANENT — process_flag(sensitive, true)
}.

%% Result of command execution.
-type command_result() :: #{
    exit_code := integer(),
    output := binary()
}.
-type command_error() ::
    {port_exit, term()} |
    {port_failed, term()} |
    {timeout, infinity | non_neg_integer()} |
    {security, security_denial()}.

-type security_denial() ::
    {deny, binary()} |
    {throttle, pos_integer()}.

%% Default values.
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_MAX_OUTPUT, 1048576). %% 1MB

%% Max command string bytes included in telemetry metadata.
-define(TELEMETRY_CMD_MAX_BYTES, 512).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-doc "Run a shell command with default options.".
-spec run(binary() | string() | [binary() | string()]) ->
    {ok, command_result()} | {error, command_error()}.
run(Command) ->
    run(Command, #{}).

-doc """
Run a shell command with options.

Options:
- `timeout`: max execution time in ms (default: 30000)
- `cwd`: working directory for the command
- `env`: environment variables as `[{Key, Value}]` strings
- `max_output`: max bytes to capture (default: 1MB)
- `max_heap`: max heap words for the calling process during execution
  (temporary — restored after command completes)
- `sensitive`: `process_flag(sensitive, true)` on the calling process.
  **PERMANENT and IRREVERSIBLE** — the calling process can never be
  made non-sensitive again.  See "Process Restrictions" in the module
  doc for the recommended wrapper-process pattern
""".
-spec run(binary() | string() | [binary() | string()], command_opts()) ->
    {ok, command_result()} | {error, command_error()}.
run(Command, Opts) when is_map(Opts) ->
    CmdStruct = beam_agent_command_parser:parse(Command),
    EvalOpts = build_eval_opts(Opts),
    case security_check(CmdStruct, EvalOpts) of
        allow ->
            Result = do_run(Command, Opts),
            record_execution(CmdStruct, EvalOpts, Result),
            Result;
        {deny, Reason} ->
            {error, {security, {deny, Reason}}};
        {throttle, RetryMs} ->
            {error, {security, {throttle, RetryMs}}}
    end.

%%--------------------------------------------------------------------
%% Internal: Security Integration
%%--------------------------------------------------------------------

%% Check the security guard if it is running. When not running,
%% fall back to the default stateless deny-policy baseline.
-spec security_check(beam_agent_command_parser:command_struct(),
                     beam_agent_command_guard:evaluate_opts()) ->
    allow | {deny, binary()} | {throttle, pos_integer()}.
security_check(CmdStruct, EvalOpts) ->
    case beam_agent_command_guard:running() of
        true  -> beam_agent_command_guard:evaluate(CmdStruct, EvalOpts);
        false -> beam_agent_command_guard:evaluate_default(CmdStruct, EvalOpts)
    end.

%% Record execution result in the guard's history (fire-and-forget cast).
-spec record_execution(beam_agent_command_parser:command_struct(),
                       beam_agent_command_guard:evaluate_opts(),
                       {ok, command_result()} | {error, command_error()}) -> ok.
record_execution(CmdStruct, EvalOpts, Result) ->
    case beam_agent_command_guard:running() of
        true  -> beam_agent_command_guard:record_execution(CmdStruct, EvalOpts, Result);
        false -> ok
    end.

%% Build evaluate options from command opts for the guard.
-spec build_eval_opts(command_opts()) -> beam_agent_command_guard:evaluate_opts().
build_eval_opts(Opts) ->
    #{
        agent => maps:get(agent, Opts, undefined),
        session_state => maps:get(session_state, Opts, undefined),
        cwd => maps:get(cwd, Opts, undefined),
        env => maps:get(env, Opts, undefined),
        opts => Opts,
        metadata => maps:get(metadata, Opts, #{})
    }.

%%--------------------------------------------------------------------
%% Internal: Command Execution
%%--------------------------------------------------------------------

-spec do_run(binary() | string() | [binary() | string()], command_opts()) ->
    {ok, command_result()} | {error, command_error()}.
do_run(Command, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    MaxOutput = maps:get(max_output, Opts, ?DEFAULT_MAX_OUTPUT),
    CmdStr = display_command(Command),
    Cwd = maps:get(cwd, Opts, undefined),
    TeleMeta = #{command => telemetry_command(CmdStr), cwd => Cwd},
    StartTime = beam_agent_telemetry_core:span_start(command, run, TeleMeta),
    {PortName, PortOpts} = build_port_spec(Command, Opts),
    Prev = apply_restrictions(Opts),
    try
        Result = run_port(PortName, PortOpts, Timeout, MaxOutput, CmdStr),
        emit_command_telemetry(StartTime, TeleMeta, Result),
        Result
    after
        restore_restrictions(Prev)
    end.

%%--------------------------------------------------------------------
%% Internal: Port Execution
%%--------------------------------------------------------------------

%% Open the port, register with guard, collect output, unregister.
-spec run_port({spawn_executable, string()}, [term()],
               pos_integer(), pos_integer(), string()) ->
    {ok, command_result()} | {error, command_error()}.
run_port(PortName, PortOpts, Timeout, MaxOutput, CmdStr) ->
    try
        Port = erlang:open_port(PortName, PortOpts),
        maybe_register_command(Port, CmdStr),
        try
            collect_output(Port, Timeout, MaxOutput, <<>>)
        after
            maybe_unregister_command(Port)
        end
    catch
        error:Reason ->
            {error, {port_failed, Reason}}
    end.

%%--------------------------------------------------------------------
%% Internal: Process Restrictions
%%--------------------------------------------------------------------

%% Apply max_heap_size and sensitive flags on the calling process.
%% Returns previous state for restore_restrictions/1.
-spec apply_restrictions(command_opts()) -> map().
apply_restrictions(Opts) ->
    OldMaxHeap = case maps:find(max_heap, Opts) of
        {ok, MaxHeap} ->
            erlang:process_flag(max_heap_size,
                #{size => MaxHeap, kill => true, error_logger => true});
        error ->
            undefined
    end,
    case maps:get(sensitive, Opts, false) of
        true  -> _ = process_flag(sensitive, true);
        false -> ok
    end,
    #{max_heap => OldMaxHeap}.

%% Restore previous max_heap_size.  Sensitive flag is permanent.
-spec restore_restrictions(#{max_heap :=
    undefined | non_neg_integer() |
    #{size => non_neg_integer(), kill => boolean(),
      error_logger => boolean(),
      include_shared_binaries => boolean()}}) -> ok.
restore_restrictions(#{max_heap := undefined}) ->
    ok;
restore_restrictions(#{max_heap := OldMaxHeap}) ->
    _ = erlang:process_flag(max_heap_size, OldMaxHeap),
    ok.

%%--------------------------------------------------------------------
%% Internal: Guard Command Tracking
%%--------------------------------------------------------------------

%% Register the command's port with the guard for cooperative lockdown.
-spec maybe_register_command(port(), string()) -> ok.
maybe_register_command(Port, CmdStr) ->
    case beam_agent_command_guard:running() of
        true ->
            beam_agent_command_guard:register_command(
                Port, telemetry_command(CmdStr));
        false ->
            ok
    end.

%% Unregister the command and flush any stale lockdown message.
-spec maybe_unregister_command(port()) -> ok.
maybe_unregister_command(Port) ->
    case beam_agent_command_guard:running() of
        true ->
            beam_agent_command_guard:unregister_command(Port),
            %% Flush lockdown message that may have arrived after
            %% the port completed but before unregister.
            receive
                {beam_agent_lockdown, Port, _} -> ok
            after 0 -> ok
            end;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Port Setup
%%--------------------------------------------------------------------

-spec find_shell() -> string().
find_shell() ->
    case os:find_executable("sh") of
        false ->
            case os:find_executable("cmd") of
                false -> error(no_shell_found);
                WinShell -> WinShell
            end;
        Shell ->
            Shell
    end.

-spec shell_kind(string()) -> posix | cmd.
shell_kind(Shell) ->
    Lower = string:lowercase(filename:basename(Shell)),
    case Lower of
        "cmd" -> cmd;
        "cmd.exe" -> cmd;
        _ -> posix
    end.

-spec build_port_spec(binary() | string() | [binary() | string()], command_opts()) ->
    {{spawn_executable, string()}, [term()]}.
build_port_spec([Head | _] = Command, Opts) when not is_integer(Head) ->
    build_exec_port_spec(Command, Opts);
build_port_spec(Command, Opts) ->
    Shell = find_shell(),
    CmdStr = command_string(Command, shell_kind(Shell)),
    build_shell_port_spec(Shell, CmdStr, Opts).

-spec build_shell_port_spec(string(), string(), command_opts()) ->
    {{spawn_executable, string()}, [term()]}.
build_shell_port_spec(Shell, CmdStr, Opts) ->
    Args = case lists:suffix("cmd", Shell) orelse
                lists:suffix("cmd.exe", Shell) of
        true -> ["/c", CmdStr];
        false -> ["-c", CmdStr]
    end,
    BaseOpts = [
        {args, Args},
        binary,
        exit_status,
        use_stdio,
        hide,
        stderr_to_stdout
    ],
    WithCwd = case maps:find(cwd, Opts) of
        {ok, Dir} -> [{cd, command_string(Dir, posix)} | BaseOpts];
        error -> BaseOpts
    end,
    WithEnv = case maps:find(env, Opts) of
        {ok, Env} when is_list(Env) -> [{env, Env} | WithCwd];
        _ -> WithCwd
    end,
    {{spawn_executable, Shell}, WithEnv}.

-spec build_exec_port_spec([binary() | string()], command_opts()) ->
    {{spawn_executable, string()}, [term()]}.
build_exec_port_spec([Program | Args], Opts) ->
    Executable = resolve_executable(Program),
    BaseOpts = [
        {args, [segment_string(Arg) || Arg <- Args]},
        binary,
        exit_status,
        use_stdio,
        hide,
        stderr_to_stdout
    ],
    WithCwd = case maps:find(cwd, Opts) of
        {ok, Dir} -> [{cd, segment_string(Dir)} | BaseOpts];
        error -> BaseOpts
    end,
    WithEnv = case maps:find(env, Opts) of
        {ok, Env} when is_list(Env) -> [{env, Env} | WithCwd];
        _ -> WithCwd
    end,
    {{spawn_executable, Executable}, WithEnv}.

%%--------------------------------------------------------------------
%% Internal: Output Collection
%%--------------------------------------------------------------------

-spec collect_output(port(), pos_integer(), pos_integer(), binary()) ->
    {ok, command_result()} | {error, term()}.
collect_output(Port, Timeout, MaxOutput, Acc) ->
    receive
        {Port, {data, Data}} ->
            NewAcc = append_bounded(Acc, Data, MaxOutput),
            collect_output(Port, Timeout, MaxOutput, NewAcc);
        {Port, {exit_status, ExitCode}} ->
            {ok, #{exit_code => ExitCode, output => Acc}};
        {'EXIT', Port, Reason} ->
            {error, {port_exit, Reason}};
        {beam_agent_lockdown, Port, Reason} ->
            catch erlang:port_close(Port),
            {error, {security, {deny, <<"Lockdown: ", Reason/binary>>}}}
    after Timeout ->
        catch erlang:port_close(Port),
        {error, {timeout, Timeout}}
    end.

-spec append_bounded(binary(), binary(), pos_integer()) -> binary().
append_bounded(Acc, Data, MaxOutput) ->
    Combined = <<Acc/binary, Data/binary>>,
    case byte_size(Combined) > MaxOutput of
        true -> binary:part(Combined, 0, MaxOutput);
        false -> Combined
    end.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec display_command(binary() | string() | [binary() | string()]) -> string().
display_command(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
display_command(Str) when is_list(Str), (Str =:= [] orelse is_integer(hd(Str))) ->
    Str;
display_command(Segments) when is_list(Segments) ->
    string:join([segment_string(Segment) || Segment <- Segments], " ").

-spec command_string(binary() | string() | [binary() | string()], posix | cmd) -> string().
command_string(Bin, _ShellKind) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
command_string(Str, _ShellKind) when is_list(Str), (Str =:= [] orelse is_integer(hd(Str))) ->
    Str;
command_string(Segments, ShellKind) when is_list(Segments) ->
    string:join([shell_escape_segment(Segment, ShellKind) || Segment <- Segments], " ").

-spec segment_string(binary() | string()) -> string().
segment_string(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
segment_string(Str) when is_list(Str) ->
    Str.

-spec resolve_executable(binary() | string()) -> string().
resolve_executable(Program) ->
    ProgramStr = segment_string(Program),
    case os:find_executable(ProgramStr) of
        false ->
            case has_path_separator(ProgramStr) of
                true -> ProgramStr;
                false -> error({executable_not_found, ProgramStr})
            end;
        Executable ->
            Executable
    end.

-spec has_path_separator(string()) -> boolean().
has_path_separator(Path) ->
    lists:any(fun(Char) -> Char =:= $/ orelse Char =:= $\\ end, Path).

-spec shell_escape_segment(binary() | string(), posix | cmd) -> string().
shell_escape_segment(Segment, ShellKind) when is_binary(Segment) ->
    shell_escape_segment(unicode:characters_to_list(Segment), ShellKind);
shell_escape_segment(Segment, posix) when is_list(Segment) ->
    [$', lists:flatten([shell_escape_char(Char) || Char <- Segment]), $'];
shell_escape_segment(Segment, cmd) ->
    [$", lists:flatten([cmd_escape_char(Char) || Char <- Segment]), $"].

-spec shell_escape_char(char()) -> string().
shell_escape_char($') ->
    "'\\''"  ;
shell_escape_char(Char) ->
    [Char].

-spec cmd_escape_char(char()) -> string().
cmd_escape_char($") ->
    "\\\"";
cmd_escape_char($%) ->
    "%%";
cmd_escape_char($^) ->
    "^^";
cmd_escape_char($&) ->
    "^&";
cmd_escape_char($|) ->
    "^|";
cmd_escape_char($<) ->
    "^<";
cmd_escape_char($>) ->
    "^>";
cmd_escape_char($() ->
    "^(";
cmd_escape_char($)) ->
    "^)";
cmd_escape_char(Char) ->
    [Char].

%%--------------------------------------------------------------------
%% Internal: Telemetry
%%--------------------------------------------------------------------

%% Emit stop or exception telemetry based on the command result.
-spec emit_command_telemetry(integer(),
    #{'command' := binary(), 'cwd' := term()},
    {ok, command_result()} | {error, command_error()}) -> ok.
emit_command_telemetry(StartTime, TeleMeta, {ok, #{exit_code := ExitCode}}) ->
    beam_agent_telemetry_core:span_stop(command, run, StartTime,
        TeleMeta#{exit_code => ExitCode});
emit_command_telemetry(_StartTime, TeleMeta, {error, Reason}) ->
    beam_agent_telemetry_core:span_exception(command, run, Reason, TeleMeta).

%% Convert a command string to a binary for telemetry metadata.
%% Truncated to ?TELEMETRY_CMD_MAX_BYTES to prevent telemetry bloat.
-spec telemetry_command(string()) -> binary().
telemetry_command(CmdStr) ->
    case unicode:characters_to_binary(CmdStr) of
        Bin when is_binary(Bin), byte_size(Bin) > ?TELEMETRY_CMD_MAX_BYTES ->
            binary:part(Bin, 0, ?TELEMETRY_CMD_MAX_BYTES);
        Bin when is_binary(Bin) ->
            Bin;
        _ ->
            <<"<encoding-error>">>
    end.
