-module(beam_agent_command_core).
-moduledoc """
Universal command execution for the BEAM Agent SDK.

Provides shell command execution across all adapters via Erlang
ports. Any adapter can run commands regardless of whether the
underlying CLI supports it natively.

Uses `erlang:open_port/2` with `spawn_executable` for safe,
timeout-aware, output-captured command execution.

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
    max_output => pos_integer()    %% max output bytes, default 1MB
}.

%% Result of command execution.
-type command_result() :: #{
    exit_code := integer(),
    output := binary()
}.
-type command_error() ::
    {port_exit, term()} |
    {port_failed, term()} |
    {timeout, infinity | non_neg_integer()}.

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
""".
-spec run(binary() | string() | [binary() | string()], command_opts()) ->
    {ok, command_result()} | {error, command_error()}.
run(Command, Opts) when is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    MaxOutput = maps:get(max_output, Opts, ?DEFAULT_MAX_OUTPUT),
    CmdStr = command_string(Command),
    Cwd = maps:get(cwd, Opts, undefined),
    TeleMeta = #{command => telemetry_command(CmdStr), cwd => Cwd},
    StartTime = beam_agent_telemetry_core:span_start(command, run, TeleMeta),
    Shell = find_shell(),
    {PortName, PortOpts} = build_port_spec(Shell, CmdStr, Opts),
    try
        Port = erlang:open_port(PortName, PortOpts),
        Result = collect_output(Port, Timeout, MaxOutput, <<>>),
        emit_command_telemetry(StartTime, TeleMeta, Result),
        Result
    catch
        error:Reason ->
            beam_agent_telemetry_core:span_exception(command, run,
                {port_failed, Reason}, TeleMeta),
            {error, {port_failed, Reason}}
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
%% Only receives results from collect_output/4 — {port_failed, _} is
%% caught in run/2 and never reaches this function.
-spec emit_command_telemetry(integer(),
    #{'command' := binary(), 'cwd' := term()},
    {ok, #{'exit_code' := integer(), 'output' := binary()}} |
    {error, {port_exit, term()} | {timeout, infinity | non_neg_integer()}}) -> ok.
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
