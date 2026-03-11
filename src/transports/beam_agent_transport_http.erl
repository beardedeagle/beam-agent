-module(beam_agent_transport_http).
-moduledoc """
HTTP transport via `beam_agent_http_client`.

Manages an HTTP connection for backends that use HTTP (SSE + REST)
rather than WebSocket. The transport ref is a tuple
`{ConnPid, MonRef, HttpModule}`.

Only classifies connection-level events:
  - `transport_up`   → `connected`
  - `transport_down` → `{disconnected, Reason}`
  - `DOWN`           → `{exit, 1}`

All HTTP-level messages (`http_response`, `http_data`) are returned
as `ignore`. The handler processes them via `handle_info/3` since it
has the context needed to distinguish SSE from REST streams.

The `send/2` callback accepts `noop` as a passthrough — the handler
performs HTTP requests directly using the stored connection ref.

## Dependency Injection

Pass `client_module` in opts to inject a test implementation:

```erlang
beam_agent_transport_http:start(#{
    client_module => test_http_client,
    host       => <<"localhost">>,
    port       => 4096
}).
```
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

%%====================================================================
%% beam_agent_transport callbacks
%%====================================================================

-doc "Open an HTTP connection to the given host and port.".
-spec start(map()) ->
    {ok, beam_agent_transport:transport_ref()} | {error, term()}.
start(Opts) ->
    ClientMod = maps:get(client_module, Opts, beam_agent_http_client),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    ClientOpts = #{protocols => [http]},
    case ClientMod:open(ensure_list(Host), Port, ClientOpts) of
        {ok, ConnPid} ->
            MonRef = erlang:monitor(process, ConnPid),
            {ok, {ConnPid, MonRef, ClientMod}};
        {error, Reason} ->
            {error, {http_connect_failed, Reason}}
    end.

-doc """
Send data via the transport.

Accepts `noop` as a passthrough — the handler performs HTTP requests
directly using the stored connection ref. The engine's send pathway
is unused for HTTP transports.
""".
-spec send(beam_agent_transport:transport_ref(), term()) ->
    ok | {error, term()}.
send(_, noop) ->
    ok;
send(_, _) ->
    {error, invalid_send_format}.

-doc "Close the HTTP connection and demonitor the client process.".
-spec close(beam_agent_transport:transport_ref()) -> ok.
close({ConnPid, MonRef, ClientMod}) ->
    erlang:demonitor(MonRef, [flush]),
    catch ClientMod:close(ConnPid),
    ok.

-doc "Return true if the HTTP client process is alive.".
-spec is_ready(beam_agent_transport:transport_ref()) -> boolean().
is_ready({ConnPid, _, _}) ->
    erlang:is_process_alive(ConnPid).

-doc "Return `running` if the HTTP client is alive, `{exited, 0}` otherwise.".
-spec status(beam_agent_transport:transport_ref()) ->
    running | {exited, non_neg_integer()}.
status({ConnPid, _, _}) ->
    case erlang:is_process_alive(ConnPid) of
        true  -> running;
        false -> {exited, 0}
    end.

-doc """
Classify an incoming Erlang message as a transport event.

Only connection-level events are classified. All HTTP-level messages
(`http_response`, `http_data`) return `ignore` so the
handler can process them with full protocol context in `handle_info/3`.
""".
-spec classify_message(term(), beam_agent_transport:transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({transport_up, ConnPid, _Protocol}, {ConnPid, _, _}) ->
    connected;
classify_message({transport_down, ConnPid, Reason},
                 {ConnPid, _, _}) ->
    {disconnected, Reason};
classify_message({'DOWN', MonRef, process, ConnPid, _Reason},
                 {ConnPid, MonRef, _}) ->
    {exit, 1};
classify_message(_, _) ->
    ignore.

%%====================================================================
%% Internal helpers
%%====================================================================

ensure_list(B) when is_binary(B) -> binary_to_list(B);
ensure_list(L) when is_list(L) -> L.
