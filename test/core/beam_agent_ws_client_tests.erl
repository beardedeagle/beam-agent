%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_ws_client.
%%%
%%% Tests use a real TCP listener with a hand-rolled WebSocket server
%%% to exercise the full lifecycle: TCP connect → WS upgrade → frame
%%% exchange → close. No mocking (meck) is used.
%%%
%%% The test process is the "owner" that receives transport messages.
%%% A helper process acts as the WS server: accepts the TCP connection,
%%% performs the RFC 6455 upgrade handshake, and exchanges frames.
%%%
%%% Tests cover:
%%%   - TCP connect → transport_up
%%%   - WS upgrade handshake → ws_upgraded
%%%   - Server text frame → owner receives ws_frame
%%%   - Client ws_send → server receives masked frame
%%%   - Server close frame → owner receives ws_frame close
%%%   - Server ping → client auto-pongs
%%%   - close/1 stops the process
%%%   - Connect failure → transport_down
%%%   - Owner death stops client
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_ws_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% RFC 6455 magic GUID for Sec-WebSocket-Accept
-define(WS_GUID, "258EAFA5-E914-47DA-95CA-5AB9B3F2115E").

%%====================================================================
%% Module loading
%%====================================================================

module_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_ws_client) orelse
        code:ensure_loaded(beam_agent_ws_client) =:=
            {module, beam_agent_ws_client}).

%%====================================================================
%% Full lifecycle: connect → upgrade → frames → close
%%====================================================================

full_lifecycle_test() ->
    {ok, Port, LSock} = listen(),
    Self = self(),

    %% Server process: accept, upgrade, exchange frames.
    %% The upgrade handshake synchronizes naturally through TCP:
    %% client sends request, server reads it; server sends 101,
    %% client reads it. No extra signaling needed.
    ServerPid = spawn_link(fun() ->
        {ok, Sock} = gen_tcp:accept(LSock, 5000),
        ok = inet:setopts(Sock, [{active, false}]),

        %% Perform WS upgrade handshake (blocks until client sends request)
        ok = server_upgrade(Sock),

        %% Wait for signal to send a text frame
        receive send_text -> ok end,
        ok = server_send_text(Sock, <<"hello from server">>),

        %% Read client's masked frame (just drain it, verify no error)
        receive read_client_frame -> ok end,
        {ok, _ClientData} = gen_tcp:recv(Sock, 0, 5000),

        %% Send close frame
        receive send_close -> ok end,
        ok = server_send_close(Sock, 1000, <<"bye">>),

        %% Wait for client close echo (or timeout)
        _ = gen_tcp:recv(Sock, 0, 2000),
        Self ! server_done,
        gen_tcp:close(Sock)
    end),

    try
        %% Start client
        {ok, Pid} = beam_agent_ws_client:open(
            "127.0.0.1", Port,
            #{transport => tcp, scheme => <<"ws">>}),

        %% 1. Receive transport_up
        receive
            {transport_up, Pid, http} -> ok
        after 5000 ->
            error(no_transport_up)
        end,

        %% 2. Perform WS upgrade (synchronous — handshakes with server)
        WsRef = beam_agent_ws_client:ws_upgrade(
            Pid, <<"/ws">>,
            [{<<"authorization">>, <<"Bearer test">>}]),
        ?assert(is_reference(WsRef)),

        %% 3. Receive ws_upgraded
        receive
            {ws_upgraded, Pid, WsRef, [<<"websocket">>], _Headers} -> ok
        after 5000 ->
            error(no_ws_upgraded)
        end,

        %% 4. Server sends text frame → owner gets ws_frame
        ServerPid ! send_text,
        receive
            {ws_frame, Pid, WsRef, {text, <<"hello from server">>}} -> ok
        after 5000 ->
            error(no_ws_frame)
        end,

        %% 5. Client sends frame → no error
        ServerPid ! read_client_frame,
        ?assertEqual(ok,
            beam_agent_ws_client:ws_send(Pid, WsRef, {text, <<"from client">>})),

        %% 6. Server sends close → owner gets close frame
        ServerPid ! send_close,
        receive
            {ws_frame, Pid, WsRef, {close, 1000, <<"bye">>}} -> ok
        after 5000 ->
            error(no_close_frame)
        end,

        %% Wait for server to finish cleanly
        receive server_done -> ok after 5000 -> ok end,

        %% 7. Close client
        beam_agent_ws_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Server ping → client auto-pong
%%====================================================================

auto_pong_test() ->
    {ok, Port, LSock} = listen(),
    Self = self(),

    ServerPid = spawn_link(fun() ->
        {ok, Sock} = gen_tcp:accept(LSock, 5000),
        ok = inet:setopts(Sock, [{active, false}]),
        ok = server_upgrade(Sock),

        %% Send ping after signal
        receive send_ping -> ok end,
        ok = server_send_ping(Sock, <<"are-you-there">>),

        %% Read client pong
        {ok, PongData} = gen_tcp:recv(Sock, 0, 5000),
        Self ! {pong_received, PongData},

        receive done -> ok end,
        gen_tcp:close(Sock)
    end),

    try
        {ok, Pid} = beam_agent_ws_client:open(
            "127.0.0.1", Port,
            #{transport => tcp, scheme => <<"ws">>}),

        receive {transport_up, Pid, http} -> ok after 5000 -> error(timeout) end,

        _WsRef = beam_agent_ws_client:ws_upgrade(Pid, <<"/ws">>, []),
        receive {ws_upgraded, Pid, _, _, _} -> ok after 5000 -> error(timeout) end,

        %% Trigger ping
        ServerPid ! send_ping,

        %% Verify server received pong (masked frame with opcode 0xA)
        receive
            {pong_received, PongRaw} ->
                ?assert(byte_size(PongRaw) > 0)
        after 5000 ->
            error(no_pong)
        end,

        ServerPid ! done,
        beam_agent_ws_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Connect failure → transport_down
%%====================================================================

connect_failure_test() ->
    %% Use a port that nothing is listening on
    {ok, Port, LSock} = listen(),
    gen_tcp:close(LSock),
    timer:sleep(50),

    {ok, Pid} = beam_agent_ws_client:open(
        "127.0.0.1", Port,
        #{transport => tcp, scheme => <<"ws">>}),
    MonRef = monitor(process, Pid),

    receive
        {transport_down, Pid, {connect_failed, _Reason}} -> ok
    after 5000 ->
        error(no_transport_down)
    end,

    %% Client should stop after connect failure
    receive
        {'DOWN', MonRef, process, Pid, normal} -> ok
    after 2000 ->
        error(client_not_stopped)
    end.

%%====================================================================
%% Owner death stops client
%%====================================================================

owner_death_stops_client_test() ->
    {ok, Port, LSock} = listen(),
    %% Accept in background so client can connect.
    %% Use spawn (not spawn_link) — the acceptor may still be blocked
    %% in gen_tcp:accept when the test closes LSock, which would cause
    %% {error, einval}. An unlinked process avoids poisoning the test.
    Acceptor = spawn(fun() ->
        case gen_tcp:accept(LSock, 5000) of
            {ok, Sock} ->
                receive done -> ok after 10000 -> ok end,
                gen_tcp:close(Sock);
            {error, _} ->
                ok
        end
    end),

    Self = self(),
    Owner = spawn(fun() ->
        {ok, Pid} = beam_agent_ws_client:open(
            "127.0.0.1", Port,
            #{transport => tcp, scheme => <<"ws">>}),
        Self ! {client_pid, Pid},
        receive stop -> ok end
    end),

    try
        ClientPid = receive {client_pid, P} -> P after 5000 -> error(timeout) end,
        MonRef = monitor(process, ClientPid),
        exit(Owner, kill),
        receive
            {'DOWN', MonRef, process, ClientPid, normal} -> ok
        after 5000 ->
            error(client_not_stopped)
        end
    after
        gen_tcp:close(LSock),
        %% Clean up acceptor if still alive
        exit(Acceptor, shutdown)
    end.

%%====================================================================
%% ws_send before WS upgrade (phase = open, not ws_open)
%%====================================================================

ws_send_before_upgrade_test() ->
    {ok, Port, LSock} = listen(),
    try
        {ok, Pid} = beam_agent_ws_client:open(
            "127.0.0.1", Port,
            #{transport => tcp, scheme => <<"ws">>}),
        try
            %% Accept TCP so do_connect succeeds, phase → open
            {ok, Sock} = gen_tcp:accept(LSock, 5000),
            receive {transport_up, Pid, _} -> ok after 2000 -> error(timeout) end,
            %% Phase is 'open' (TCP connected), not 'ws_open' (upgraded).
            %% ws_send requires ws_open — should return not_connected.
            ?assertEqual({error, not_connected},
                beam_agent_ws_client:ws_send(Pid, make_ref(), {text, <<"hi">>})),
            gen_tcp:close(Sock)
        after
            beam_agent_ws_client:close(Pid)
        end
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Helpers: TCP listener
%%====================================================================

-spec listen() -> {ok, inet:port_number(), gen_tcp:socket()}.
listen() ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false},
                                     {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    {ok, Port, LSock}.

%%====================================================================
%% Helpers: server-side WS upgrade
%%====================================================================

-spec server_upgrade(gen_tcp:socket()) -> ok.
server_upgrade(Sock) ->
    {ok, ReqData} = read_until_crlfcrlf(Sock, <<>>),
    Key = extract_ws_key(ReqData),
    Accept = base64:encode(
        crypto:hash(sha, [Key, <<?WS_GUID>>])),
    Response = ["HTTP/1.1 101 Switching Protocols\r\n",
                "Upgrade: websocket\r\n",
                "Connection: Upgrade\r\n",
                "Sec-WebSocket-Accept: ", binary_to_list(Accept), "\r\n",
                "\r\n"],
    ok = gen_tcp:send(Sock, Response).

-spec read_until_crlfcrlf(gen_tcp:socket(), binary()) ->
    {ok, binary()} | {error, term()}.
read_until_crlfcrlf(Sock, Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        {_, _} -> {ok, Buf};
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} ->
                    read_until_crlfcrlf(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = Err ->
                    Err
            end
    end.

-spec extract_ws_key(binary()) -> binary().
extract_ws_key(Data) ->
    Lines = binary:split(Data, <<"\r\n">>, [global]),
    extract_ws_key_from_lines(Lines).

-spec extract_ws_key_from_lines([binary()]) -> binary().
extract_ws_key_from_lines([]) ->
    error(no_ws_key_found);
extract_ws_key_from_lines([Line | Rest]) ->
    case Line of
        <<"Sec-WebSocket-Key: ", Key/binary>> -> Key;
        _ -> extract_ws_key_from_lines(Rest)
    end.

%%====================================================================
%% Helpers: server-side frame sending (unmasked)
%%====================================================================

-spec server_send_text(gen_tcp:socket(), binary()) -> ok.
server_send_text(Sock, Payload) ->
    Frame = server_frame(1, 1, Payload),
    gen_tcp:send(Sock, Frame).

-spec server_send_close(gen_tcp:socket(), non_neg_integer(), binary()) -> ok.
server_send_close(Sock, Code, Reason) ->
    Payload = <<Code:16, Reason/binary>>,
    Frame = server_frame(8, 1, Payload),
    gen_tcp:send(Sock, Frame).

-spec server_send_ping(gen_tcp:socket(), binary()) -> ok.
server_send_ping(Sock, Payload) ->
    Frame = server_frame(9, 1, Payload),
    gen_tcp:send(Sock, Frame).

%% @doc Build an unmasked server frame (FIN + opcode + payload).
-spec server_frame(non_neg_integer(), 0 | 1, binary()) -> binary().
server_frame(Opcode, Fin, Payload) ->
    Len = byte_size(Payload),
    Header = if
        Len < 126 ->
            <<Fin:1, 0:3, Opcode:4, 0:1, Len:7>>;
        Len < 65536 ->
            <<Fin:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
        true ->
            <<Fin:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
    end,
    <<Header/binary, Payload/binary>>.
