-module(beam_agent_transport_ws).
-moduledoc """
WebSocket transport via gun.

Manages a gun HTTP→WebSocket connection. The transport ref is a tuple
`{ConnPid, MonRef, GunModule}`. Since the WebSocket stream ref is only
available after the async upgrade completes, the handler must store it
(received from `gun:ws_upgrade/3` return value) and include it in send
actions as `{ws_frames, StreamRef, [map()]}`.

## Connection Lifecycle

    start/1 → gun:open → {ok, {ConnPid, MonRef, GunModule}}

    {gun_up, ConnPid, _}       → classify → connected      (TCP ready)
    handler calls gun:ws_upgrade(ConnPid, Path, Headers) → WsRef
    {gun_upgrade, ConnPid, ...} → classify → connected      (WS ready)

    {gun_ws, ConnPid, _, {text, Payload}} → classify → {data, Payload}
    send({ws_frames, WsRef, [Msg, ...]}) → gun:ws_send for each frame

## Dependency Injection

Pass `gun_module` in opts to inject a test implementation:

```erlang
beam_agent_transport_ws:start(#{
    gun_module => test_gun,  %% test fixture, no mocking needed
    host       => <<"localhost">>,
    port       => 8080,
    scheme     => <<"ws">>
}).
```
""".

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, classify_message/2]).

%%====================================================================
%% beam_agent_transport callbacks
%%====================================================================

-spec start(map()) -> {ok, beam_agent_transport:transport_ref()} | {error, term()}.
start(Opts) ->
    GunModule = maps:get(gun_module, Opts, gun),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Scheme = maps:get(scheme, Opts, <<"wss">>),
    GunOpts = case Scheme of
        <<"wss">> -> #{transport => tls, protocols => [http]};
        _         -> #{protocols => [http]}
    end,
    case GunModule:open(binary_to_list(Host), Port, GunOpts) of
        {ok, ConnPid} ->
            MonRef = erlang:monitor(process, ConnPid),
            {ok, {ConnPid, MonRef, GunModule}};
        {error, Reason} ->
            {error, {ws_connect_failed, Reason}}
    end.

-spec send(beam_agent_transport:transport_ref(), term()) -> ok | {error, term()}.
send({ConnPid, _, GunModule}, {ws_frames, WsRef, Messages})
  when is_list(Messages) ->
    try
        lists:foreach(fun(Msg) ->
            Json = iolist_to_binary(json:encode(Msg)),
            GunModule:ws_send(ConnPid, WsRef, {text, Json})
        end, Messages),
        ok
    catch
        error:Reason -> {error, {ws_send_failed, Reason}}
    end;
send(_, _) ->
    {error, invalid_send_format}.

-spec close(beam_agent_transport:transport_ref()) -> ok.
close({ConnPid, _MonRef, GunModule}) ->
    catch GunModule:close(ConnPid),
    ok.

-spec is_ready(beam_agent_transport:transport_ref()) -> boolean().
is_ready({ConnPid, _, _}) ->
    erlang:is_process_alive(ConnPid).

-spec classify_message(term(), beam_agent_transport:transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({gun_up, ConnPid, _Protocol}, {ConnPid, _, _}) ->
    connected;
classify_message({gun_upgrade, ConnPid, _WsRef, _Protocols, _Headers},
                 {ConnPid, _, _}) ->
    connected;
classify_message({gun_ws, ConnPid, _WsRef, {text, Payload}},
                 {ConnPid, _, _}) ->
    {data, Payload};
classify_message({gun_ws, ConnPid, _WsRef, {close, _Code, _Reason}},
                 {ConnPid, _, _}) ->
    {disconnected, ws_closed};
classify_message({gun_down, ConnPid, _Protocol, Reason, _Killed},
                 {ConnPid, _, _}) ->
    {disconnected, Reason};
classify_message({'DOWN', MonRef, process, ConnPid, _Reason},
                 {ConnPid, MonRef, _}) ->
    {exit, 1};
classify_message(_, _) ->
    ignore.
