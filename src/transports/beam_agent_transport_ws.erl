-module(beam_agent_transport_ws).
-moduledoc false.

-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

%%====================================================================
%% beam_agent_transport callbacks
%%====================================================================

-doc "Open a WebSocket connection to the given host and port.".
-spec start(map()) -> {ok, beam_agent_transport:transport_ref()} | {error, term()}.
start(Opts) ->
    ClientMod = maps:get(client_module, Opts, beam_agent_ws_client),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Scheme = maps:get(scheme, Opts, <<"wss">>),
    ClientOpts = case Scheme of
        <<"wss">> -> #{transport => tls, protocols => [http]};
        _         -> #{protocols => [http]}
    end,
    case ClientMod:open(ensure_list(Host), Port, ClientOpts) of
        {ok, ConnPid} ->
            MonRef = erlang:monitor(process, ConnPid),
            {ok, {ConnPid, MonRef, ClientMod}};
        {error, Reason} ->
            {error, {ws_connect_failed, Reason}}
    end.

-doc "Send WebSocket frames as JSON-encoded text messages.".
-spec send(beam_agent_transport:transport_ref(), term()) ->
    ok | {error, invalid_send_format | {ws_send_failed, _}}.
send({ConnPid, _, ClientMod}, {ws_frames, WsRef, Messages})
  when is_list(Messages) ->
    try
        lists:foreach(fun(Msg) ->
            Json = iolist_to_binary(json:encode(Msg)),
            ClientMod:ws_send(ConnPid, WsRef, {text, Json})
        end, Messages),
        ok
    catch
        error:Reason -> {error, {ws_send_failed, Reason}};
        exit:Reason  -> {error, {ws_send_failed, Reason}}
    end;
send(_, _) ->
    {error, invalid_send_format}.

-doc "Close the WebSocket connection and demonitor the client process.".
-spec close(beam_agent_transport:transport_ref()) -> ok.
close({ConnPid, MonRef, ClientMod}) ->
    erlang:demonitor(MonRef, [flush]),
    catch ClientMod:close(ConnPid),
    ok.

-doc "Return true if the WebSocket client process is alive.".
-spec is_ready(beam_agent_transport:transport_ref()) -> boolean().
is_ready({ConnPid, _, _}) ->
    erlang:is_process_alive(ConnPid).

-doc "Return `running` if the WebSocket client is alive, `{exited, 0}` otherwise.".
-spec status(beam_agent_transport:transport_ref()) ->
    running | {exited, 0}.
status({ConnPid, _, _}) ->
    case erlang:is_process_alive(ConnPid) of
        true  -> running;
        false -> {exited, 0}
    end.

-doc "Classify an incoming Erlang message as a transport event.".
-spec classify_message(term(), beam_agent_transport:transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.
classify_message({transport_up, ConnPid, _Protocol}, {ConnPid, _, _}) ->
    connected;
classify_message({ws_upgraded, ConnPid, _WsRef, _Protocols, _Headers},
                 {ConnPid, _, _}) ->
    connected;
classify_message({ws_frame, ConnPid, _WsRef, {text, Payload}},
                 {ConnPid, _, _}) ->
    {data, Payload};
classify_message({ws_frame, ConnPid, _WsRef, {binary, Payload}},
                 {ConnPid, _, _}) ->
    {data, Payload};
classify_message({ws_frame, ConnPid, _WsRef, {close, _Code, _Reason}},
                 {ConnPid, _, _}) ->
    {disconnected, ws_closed};
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
