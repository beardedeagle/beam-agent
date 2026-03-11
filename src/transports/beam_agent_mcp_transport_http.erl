-module(beam_agent_mcp_transport_http).
-moduledoc """
MCP Streamable HTTP transport per MCP spec 2025-06-18.

Manages an HTTP connection for MCP servers using the Streamable HTTP
transport. The transport ref is a 4-tuple:

    {ConnPid, MonRef, HttpModule, SessionState}

where `SessionState` is a map tracking the MCP session ID, negotiated
protocol version, and the endpoint path.

## Request Semantics

Each `send/2` call issues a new HTTP POST to the MCP endpoint. The server
responds with `application/json` (single JSON-RPC response) or
`text/event-stream` (SSE stream for server-initiated messages).
Notification-only requests return 202 Accepted with no body.

## Transport vs Protocol Boundary

This module handles connection-level events only: `transport_up`,
`transport_down`, and process `DOWN`. All HTTP-level messages
(`http_response`, `http_data`) are returned as `ignore` — the MCP
session handler processes them via `handle_info/3` since it owns session
state, stream mode tracking, and protocol decode logic.

This follows the same pattern as `beam_agent_transport_http`.

## Session Lifecycle

The `SessionState` in the transport ref contains the current `session_id`
and `protocol_version`. These are managed by the session handler, which
reconstructs the ref tuple when session state changes (e.g., after the
server assigns a session via `Mcp-Session-Id` response header).

Session termination sends HTTP DELETE before closing the connection.

## Dependency Injection

Pass `client_module` in opts for testing:

```erlang
beam_agent_mcp_transport_http:start(#{
    client_module => test_mcp_http_client,
    host       => <<"localhost">>,
    port       => 4096,
    path       => <<"/mcp">>
}).
```
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

%% Dialyzer: send/2 intentionally uses the behaviour type
%% beam_agent_transport:transport_ref() which is broader than the
%% concrete 4-tuple this module constructs.
-dialyzer({nowarn_function, [send/2]}).

%%====================================================================
%% beam_agent_transport callbacks
%%====================================================================

-doc "Open an HTTP connection to the MCP server endpoint.".
-spec start(map()) ->
    {ok, beam_agent_transport:transport_ref()} | {error, term()}.
start(Opts) ->
    ClientMod  = maps:get(client_module, Opts, beam_agent_http_client),
    Host    = maps:get(host, Opts),
    Port    = maps:get(port, Opts),
    Path    = maps:get(path, Opts, <<"/mcp">>),
    TlsOpts = maps:get(tls_opts, Opts, []),
    ClientOpts = build_client_opts(TlsOpts),
    case ClientMod:open(ensure_list(Host), Port, ClientOpts) of
        {ok, ConnPid} ->
            MonRef       = erlang:monitor(process, ConnPid),
            SessionState = #{
                path             => Path,
                session_id       => undefined,
                protocol_version => undefined
            },
            {ok, {ConnPid, MonRef, ClientMod, SessionState}};
        {error, Reason} ->
            {error, {mcp_http_connect_failed, Reason}}
    end.

-doc """
POST a JSON-RPC 2.0 message to the MCP endpoint.

Builds request headers including `Content-Type: application/json`,
`Accept: application/json, text/event-stream`, and optionally
`Mcp-Session-Id` and `MCP-Protocol-Version` if set in the session state.
The response is handled asynchronously via the session handler's
`handle_info/3`.
""".
-spec send(beam_agent_transport:transport_ref(), map()) ->
    ok | {error, {send_failed, _}}.
send({ConnPid, _MonRef, ClientMod, SessionState}, Data) when is_map(Data) ->
    Path     = maps:get(path, SessionState, <<"/mcp">>),
    SessId   = maps:get(session_id, SessionState, undefined),
    ProtoVer = maps:get(protocol_version, SessionState, undefined),
    Json     = iolist_to_binary(json:encode(Data)),
    Headers  = build_post_headers(SessId, ProtoVer),
    try
        %% StreamRef intentionally discarded — JSON-RPC request/response
        %% matching uses the wire-level `id` field, not HTTP stream refs.
        _ = ClientMod:post(ConnPid, Path, Headers, Json),
        ok
    catch
        error:Reason -> {error, {send_failed, Reason}};
        exit:Reason  -> {error, {send_failed, Reason}}
    end.

-doc """
Terminate the MCP session and close the HTTP connection.

Sends HTTP DELETE to the endpoint with `Mcp-Session-Id` header if a
session is active. Always closes the connection afterwards.
""".
-spec close(beam_agent_transport:transport_ref()) -> ok.
close({ConnPid, MonRef, ClientMod, SessionState}) ->
    erlang:demonitor(MonRef, [flush]),
    Path   = maps:get(path, SessionState, <<"/mcp">>),
    SessId = maps:get(session_id, SessionState, undefined),
    case SessId of
        undefined ->
            ok;
        SId ->
            Headers = [{<<"mcp-session-id">>, SId}],
            catch ClientMod:delete(ConnPid, Path, Headers)
    end,
    catch ClientMod:close(ConnPid),
    ok.

-doc "Return true if the HTTP client process is alive.".
-spec is_ready(beam_agent_transport:transport_ref()) -> boolean().
is_ready({ConnPid, _, _, _}) ->
    erlang:is_process_alive(ConnPid).

-doc "Return `running` if the HTTP client is alive, `{exited, 0}` otherwise.".
-spec status(beam_agent_transport:transport_ref()) ->
    running | {exited, 0}.
status({ConnPid, _, _, _}) ->
    case erlang:is_process_alive(ConnPid) of
        true  -> running;
        false -> {exited, 0}
    end.

-doc """
Classify an incoming message as a transport event.

Only connection-level events are classified. All HTTP-level messages
(`http_response`, `http_data`) return `ignore` so the session handler
can process them with full protocol context in `handle_info/3`.

Connection events:
  - `transport_up`   → `connected`
  - `transport_down` → `{disconnected, Reason}`
  - `DOWN`           → `{exit, 1}`
""".
-spec classify_message(term(), beam_agent_transport:transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({transport_up, ConnPid, _Protocol}, {ConnPid, _, _, _}) ->
    connected;
classify_message({transport_down, ConnPid, Reason},
                 {ConnPid, _, _, _}) ->
    {disconnected, Reason};
classify_message({'DOWN', MonRef, process, ConnPid, _Reason},
                 {ConnPid, MonRef, _, _}) ->
    {exit, 1};
classify_message(_, _) ->
    ignore.

%%====================================================================
%% Internal helpers
%%====================================================================

ensure_list(B) when is_binary(B) -> binary_to_list(B);
ensure_list(L) when is_list(L) -> L.

build_client_opts([]) ->
    #{protocols => [http]};
build_client_opts(TlsOpts) ->
    #{transport => tls, tls_opts => TlsOpts, protocols => [http]}.

build_post_headers(SessId, ProtoVer) ->
    Base = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>,       <<"application/json, text/event-stream">>}
    ],
    WithSid = case SessId of
        undefined -> Base;
        SId       -> [{<<"mcp-session-id">>, SId} | Base]
    end,
    case ProtoVer of
        undefined -> WithSid;
        Ver       -> [{<<"mcp-protocol-version">>, Ver} | WithSid]
    end.
