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

If the guard is not running, commands execute directly — security is
opt-in and does not break existing callers.

## Restricted Execution (Layer 4)

Every command runs in a dedicated BEAM process with hard resource limits:

  - **max_heap_size** — VM-enforced memory limit; the executor is killed
    instantly if it exceeds the threshold (default: ~50MB).
  - **sensitive mode** — `process_flag(sensitive, true)` prevents
    `process_info` from leaking command arguments or output from
    credential-handling commands.
  - **Guard integration** — when the guard enters lockdown, all active
    executor processes are force-killed immediately.

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
    max_heap => pos_integer(),     %% max executor heap words, default ~50MB
    sensitive => boolean()         %% hide process state from process_info
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
    {security, security_denial()} |
    {resource_limit, term()} |
    {executor_crash, term()}.

-type security_denial() ::
    {deny, binary()} |
    {throttle, pos_integer()}.

%% Default values.
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_MAX_OUTPUT, 1048576). %% 1MB
-define(DEFAULT_MAX_HEAP, 6553600).  %% ~50MB in words on 64-bit

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
- `max_heap`: max executor heap in words (default: ~50MB)
- `sensitive`: hide process state from `process_info` (default: false)
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
%% commands execute directly — security is opt-in.
-spec security_check(beam_agent_command_parser:command_struct(),
                     beam_agent_command_guard:evaluate_opts()) ->
    allow | {deny, binary()} | {throttle, pos_integer()}.
security_check(CmdStruct, EvalOpts) ->
    case beam_agent_command_guard:running() of
        true  -> beam_agent_command_guard:evaluate(CmdStruct, EvalOpts);
        false -> allow
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
    CmdStr = command_string(Command),
    Cwd = maps:get(cwd, Opts, undefined),
    TeleMeta = #{command => telemetry_command(CmdStr), cwd => Cwd},
    StartTime = beam_agent_telemetry_core:span_start(command, run, TeleMeta),
    Shell = find_shell(),
    {PortName, PortOpts} = build_port_spec(Shell, CmdStr, Opts),
    Result = run_in_executor(PortName, PortOpts, Timeout, MaxOutput, CmdStr, Opts),
    emit_command_telemetry(StartTime, TeleMeta, Result),
    Result.

%%--------------------------------------------------------------------
%% Internal: Restricted Executor (Layer 4)
%%--------------------------------------------------------------------

%% Spawn a restricted executor process to run the port command.
%% The executor runs with max_heap_size and optional sensitive-mode
%% restrictions.  If the guard is running, the executor is registered
%% for force-kill on lockdown.
-spec run_in_executor({spawn_executable, string()}, [term()],
                      pos_integer(), pos_integer(), string(),
                      command_opts()) ->
    {ok, command_result()} | {error, command_error()}.
run_in_executor(PortName, PortOpts, Timeout, MaxOutput, CmdStr, Opts) ->
    CallerRef = make_ref(),
    Caller = self(),
    SpawnOpts = executor_spawn_opts(Opts),
    ExecPid = spawn_opt(fun() ->
        apply_executor_restrictions(Opts),
        try
            Port = erlang:open_port(PortName, PortOpts),
            Res = collect_output(Port, Timeout, MaxOutput, <<>>),
            Caller ! {CallerRef, Res}
        catch
            error:Reason ->
                Caller ! {CallerRef, {error, {port_failed, Reason}}}
        end
    end, SpawnOpts),
    MonRef = monitor(process, ExecPid),
    maybe_register_executor(ExecPid, CmdStr),
    try
        await_executor(CallerRef, MonRef, ExecPid, Timeout)
    after
        maybe_unregister_executor(ExecPid)
    end.

%% Wait for the executor result or detect abnormal termination.
-spec await_executor(reference(), reference(), pid(), pos_integer()) ->
    {ok, command_result()} | {error, command_error()}.
await_executor(CallerRef, MonRef, ExecPid, Timeout) ->
    %% Grace period beyond the port's internal timeout.
    %% The executor's collect_output handles the port timeout;
    %% this backstop catches executor hangs.
    GraceMs = Timeout + 5000,
    receive
        {CallerRef, Result} ->
            demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, ExecPid, killed} ->
            %% max_heap_size exceeded or guard lockdown
            {error, {resource_limit, killed}};
        {'DOWN', MonRef, process, ExecPid, Reason} ->
            {error, {executor_crash, Reason}}
    after GraceMs ->
        exit(ExecPid, kill),
        demonitor(MonRef, [flush]),
        {error, {timeout, Timeout}}
    end.

%% Build spawn options for the executor process.
-spec executor_spawn_opts(command_opts()) -> [term()].
executor_spawn_opts(Opts) ->
    MaxHeap = maps:get(max_heap, Opts, ?DEFAULT_MAX_HEAP),
    [{max_heap_size, #{size => MaxHeap, kill => true,
                       error_logger => true}}].

%% Apply process-level restrictions inside the executor.
-spec apply_executor_restrictions(command_opts()) -> ok.
apply_executor_restrictions(Opts) ->
    case maps:get(sensitive, Opts, false) of
        true  -> _ = process_flag(sensitive, true), ok;
        false -> ok
    end.

%% Register the executor with the guard for lockdown-kill tracking.
-spec maybe_register_executor(pid(), string()) -> ok.
maybe_register_executor(Pid, CmdStr) ->
    case beam_agent_command_guard:running() of
        true ->
            beam_agent_command_guard:register_executor(
                Pid, telemetry_command(CmdStr));
        false ->
            ok
    end.

%% Unregister the executor from the guard.
-spec maybe_unregister_executor(pid()) -> ok.
maybe_unregister_executor(Pid) ->
    case beam_agent_command_guard:running() of
        true  -> beam_agent_command_guard:unregister_executor(Pid);
        false -> ok
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

-spec build_port_spec(string(), string(), command_opts()) ->
    {{spawn_executable, string()}, [term()]}.
build_port_spec(Shell, CmdStr, Opts) ->
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
        {ok, Dir} -> [{cd, command_string(Dir)} | BaseOpts];
        error -> BaseOpts
    end,
    WithEnv = case maps:find(env, Opts) of
        {ok, Env} when is_list(Env) -> [{env, Env} | WithCwd];
        _ -> WithCwd
    end,
    {{spawn_executable, Shell}, WithEnv}.

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
            {error, {port_exit, Reason}}
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

-spec command_string(binary() | string() | [binary() | string()]) -> string().
command_string(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
command_string(Str) when is_list(Str), (Str =:= [] orelse is_integer(hd(Str))) ->
    Str;
command_string(Segments) when is_list(Segments) ->
    string:join([shell_escape_segment(Segment) || Segment <- Segments], " ").

-spec shell_escape_segment(binary() | string()) -> string().
shell_escape_segment(Segment) when is_binary(Segment) ->
    shell_escape_segment(unicode:characters_to_list(Segment));
shell_escape_segment(Segment) when is_list(Segment) ->
    [$', lists:flatten([shell_escape_char(Char) || Char <- Segment]), $'].

-spec shell_escape_char(char()) -> string().
shell_escape_char($') ->
    "'\\''";
shell_escape_char(Char) ->
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
