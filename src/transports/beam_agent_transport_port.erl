-module(beam_agent_transport_port).
-moduledoc """
Stdio port transport for CLI subprocess communication.

Wraps Erlang `open_port/2` with `spawn_executable` to launch a CLI binary
and communicate via stdin/stdout. Used by Claude, Codex, Copilot, and Gemini
backends.

Supports two data modes via the `mode` option:

  - `line` (default) — opens port with `{line, N}` for line-oriented
    framing. `classify_message/2` re-appends the stripped newline for
    downstream JSONL extraction.
  - `raw` — opens port with `stream` for raw binary framing. Used by
    backends with custom frame protocols (e.g., Copilot's length-prefixed
    frames).

Both modes normalize incoming data into `{data, Binary}` transport events.

## Options

  - `executable` (required) — Path to the CLI binary
  - `args` — CLI arguments (default: `[]`)
  - `env` — Environment variables as `[{string(), string()}]` (default: `[]`)
  - `cd` — Working directory (default: caller's cwd)
  - `mode` — `line | raw` (default: `line`)
  - `line_buffer` — Line buffer size for `{line, N}` mode (default: 1,048,576)
  - `extra_port_opts` — Additional port options to append (default: `[]`)
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

%%--------------------------------------------------------------------
%% beam_agent_transport callbacks
%%--------------------------------------------------------------------

-doc "Start a CLI subprocess via Erlang port.".
-spec start(map()) -> {ok, port()} | {error, term()}.
start(#{executable := Exe} = Opts) ->
    Args       = maps:get(args, Opts, []),
    Env        = maps:get(env, Opts, []),
    Cd         = maps:get(cd, Opts, undefined),
    Mode       = maps:get(mode, Opts, line),
    ExtraOpts  = maps:get(extra_port_opts, Opts, []),
    ModeOpts   = case Mode of
        line ->
            LineBuffer = maps:get(line_buffer, Opts, 1_048_576),
            [{line, LineBuffer}, stderr_to_stdout];
        raw ->
            [stream]
    end,
    PortOpts   = [binary, exit_status, use_stdio | ModeOpts]
                 ++ [{args, Args}, {env, Env}]
                 ++ [{cd, Cd} || Cd =/= undefined]
                 ++ ExtraOpts,
    try
        Port = open_port({spawn_executable, Exe}, PortOpts),
        {ok, Port}
    catch
        error:Reason -> {error, Reason}
    end;
start(_Opts) ->
    {error, {missing_option, executable}}.

-doc "Send data to the CLI subprocess via port_command.".
-spec send(port(), iodata()) -> ok | {error, term()}.
send(Port, Data) ->
    try
        port_command(Port, Data),
        ok
    catch
        error:badarg -> {error, port_closed}
    end.

-doc "Close the port. Idempotent — safe to call multiple times.".
-spec close(port()) -> ok.
close(Port) ->
    catch port_close(Port),
    ok.

-doc "Check if the port is still open.".
-spec is_ready(port()) -> boolean().
is_ready(Port) ->
    erlang:port_info(Port) =/= undefined.

-doc "Return the port status.".
-spec status(port()) -> running | {exited, non_neg_integer()}.
status(Port) ->
    case erlang:port_info(Port) of
        undefined -> {exited, 0};
        _Info     -> running
    end.

-doc """
Classify an incoming Erlang message as a transport event.

Handles three port data formats:
  - `{Port, {data, {eol, Line}}}` — complete line in `{line, N}` mode.
    Newline is re-appended for downstream JSONL extraction.
  - `{Port, {data, {noeol, Chunk}}}` — partial data in `{line, N}` mode
  - `{Port, {data, Data}}` — raw binary in non-line mode
  - `{Port, {exit_status, Status}}` — port process exited
""".
-spec classify_message(term(), port()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({Port, {data, {eol, Line}}}, Port) ->
    {data, <<Line/binary, $\n>>};
classify_message({Port, {data, {noeol, Chunk}}}, Port) ->
    {data, Chunk};
classify_message({Port, {data, Data}}, Port) when is_binary(Data) ->
    {data, Data};
classify_message({Port, {exit_status, Status}}, Port) ->
    {exit, Status};
classify_message(_, _) ->
    ignore.
