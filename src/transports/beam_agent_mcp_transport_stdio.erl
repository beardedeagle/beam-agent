-module(beam_agent_mcp_transport_stdio).
-moduledoc """
MCP stdio transport: newline-delimited JSON-RPC 2.0 over stdin/stdout subprocess.

Wraps Erlang `open_port/2` with `spawn_executable` to launch an MCP server
binary. Communication uses stdin/stdout with newline-delimited JSON framing.

Each outgoing message is a JSON-RPC 2.0 map encoded to JSON and terminated
with a newline. Each received complete line is returned as a raw binary for
the session handler to decode. Partial lines (noeol) return `{error, line_overflow}` —
with a 1 MiB default buffer, noeol only fires on degenerate input.

Messages MUST NOT contain embedded newlines per the MCP 2025-06-18 spec.
stderr from the subprocess is left separate (available for logging).

## Options

  - `executable` (required) — Path to the MCP server binary
  - `args` — CLI arguments (default: `[]`)
  - `env` — Environment variables as `[{string(), string()}]` (default: `[]`)
  - `line_max` — Line buffer size in bytes (default: 1,048,576)

## Patterns

Follows `beam_agent_transport_port` conventions for port lifecycle and
`classify_message/2` structure. Unlike `beam_agent_transport_port`, stderr
is NOT merged into stdout — MCP reserves stderr for server logging.
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

%%--------------------------------------------------------------------
%% beam_agent_transport callbacks
%%--------------------------------------------------------------------

-doc "Start an MCP server subprocess via Erlang port with line-mode JSON framing.".
-spec start(map()) -> {ok, port()} | {error, term()}.
start(#{executable := Exe} = Opts) ->
    Args    = maps:get(args, Opts, []),
    Env     = maps:get(env, Opts, []),
    LineMax = maps:get(line_max, Opts, 1_048_576),
    PortOpts = [binary, exit_status, use_stdio,
                {line, LineMax}, {args, Args}, {env, Env}],
    try
        Port = open_port({spawn_executable, Exe}, PortOpts),
        {ok, Port}
    catch
        error:Reason -> {error, Reason}
    end;
start(_Opts) ->
    {error, {missing_option, executable}}.

-doc """
Encode a JSON-RPC 2.0 message map to JSON and send via port.

Appends the required newline delimiter. Returns `{error, port_closed}` if
the port has already exited.
""".
-spec send(port(), map()) -> ok | {error, term()}.
send(Port, Data) when is_map(Data) ->
    try
        Json = iolist_to_binary(json:encode(Data)),
        port_command(Port, [Json, $\n]),
        ok
    catch
        error:badarg -> {error, port_closed}
    end.

-doc "Close the MCP subprocess port. Safe to call multiple times.".
-spec close(port()) -> ok.
close(Port) ->
    catch port_close(Port),
    ok.

-doc "Return true if the port subprocess is still running.".
-spec is_ready(port()) -> boolean().
is_ready(Port) ->
    erlang:port_info(Port) =/= undefined.

-doc "Return `running` if the subprocess is alive, `{exited, 0}` otherwise.".
-spec status(port()) -> running | {exited, non_neg_integer()}.
status(Port) ->
    case erlang:port_info(Port) of
        undefined -> {exited, 0};
        _Info     -> running
    end.

-doc """
Classify an incoming Erlang message as a transport event.

  - `{Port, {data, {eol, Line}}}` — complete line, returned as raw binary.
    The session handler is responsible for JSON decode and validation.
  - `{Port, {data, {noeol, _}}}` — partial line from buffer overflow.
    Returns `{error, line_overflow}` so the session handler can log it.
    With a 1 MiB default buffer this should not occur with well-behaved
    MCP servers.
  - `{Port, {exit_status, N}}` — subprocess exited with code N.
  - Everything else returns `ignore`.
""".
-spec classify_message(term(), port()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({Port, {data, {eol, Line}}}, Port) ->
    {data, Line};
classify_message({Port, {data, {noeol, _Chunk}}}, Port) ->
    {error, line_overflow};
classify_message({Port, {exit_status, Status}}, Port) ->
    {exit, Status};
classify_message(_, _) ->
    ignore.
