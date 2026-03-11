-module(beam_agent_transport_http).
-moduledoc """
HTTP transport via gun.

Manages a gun HTTP connection for backends that use HTTP (SSE + REST)
rather than WebSocket. The transport ref is a tuple
`{ConnPid, MonRef, GunModule}`.

Only classifies connection-level events:
  - `gun_up`   → `connected`
  - `gun_down` → `{disconnected, Reason}`
  - `DOWN`     → `{exit, 1}`

All HTTP-level messages (`gun_response`, `gun_data`, `gun_trailers`)
are returned as `ignore`. The handler processes them via `handle_info/3`
since it has the context needed to distinguish SSE from REST streams.

The `send/2` callback accepts `noop` as a passthrough — the handler
performs HTTP requests directly using the stored gun connection ref.

## Dependency Injection

Pass `gun_module` in opts to inject a test implementation:

```erlang
beam_agent_transport_http:start(#{
    gun_module => test_opencode_gun,
    host       => <<"localhost">>,
    port       => 4096
}).
```
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, classify_message/2]).

%%====================================================================
%% beam_agent_transport callbacks
%%====================================================================

-spec start(map()) ->
    {ok, beam_agent_transport:transport_ref()} | {error, term()}.
start(Opts) ->
    GunModule = maps:get(gun_module, Opts, gun),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    GunOpts = #{protocols => [http]},
    case GunModule:open(binary_to_list(Host), Port, GunOpts) of
        {ok, ConnPid} ->
            MonRef = erlang:monitor(process, ConnPid),
            {ok, {ConnPid, MonRef, GunModule}};
        {error, Reason} ->
            {error, {http_connect_failed, Reason}}
    end.

-doc """
Send data via the transport.

Accepts `noop` as a passthrough — the handler performs HTTP requests
directly using the stored gun connection ref. The engine's send pathway
is unused for HTTP transports.
""".
-spec send(beam_agent_transport:transport_ref(), term()) ->
    ok | {error, term()}.
send(_, noop) ->
    ok;
send(_, _) ->
    {error, invalid_send_format}.

-spec close(beam_agent_transport:transport_ref()) -> ok.
close({ConnPid, MonRef, GunModule}) ->
    erlang:demonitor(MonRef, [flush]),
    catch GunModule:close(ConnPid),
    ok.

-spec is_ready(beam_agent_transport:transport_ref()) -> boolean().
is_ready({ConnPid, _, _}) ->
    erlang:is_process_alive(ConnPid).

-doc """
Classify an incoming Erlang message as a transport event.

Only connection-level events are classified. All HTTP-level messages
(`gun_response`, `gun_data`, `gun_trailers`) return `ignore` so the
handler can process them with full protocol context in `handle_info/3`.
""".
-spec classify_message(term(), beam_agent_transport:transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({gun_up, ConnPid, _Protocol}, {ConnPid, _, _}) ->
    connected;
classify_message({gun_down, ConnPid, _Protocol, Reason, _Killed},
                 {ConnPid, _, _}) ->
    {disconnected, Reason};
classify_message({'DOWN', MonRef, process, ConnPid, _Reason},
                 {ConnPid, MonRef, _}) ->
    {exit, 1};
classify_message(_, _) ->
    ignore.
