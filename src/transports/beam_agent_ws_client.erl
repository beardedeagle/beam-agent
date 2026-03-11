-module(beam_agent_ws_client).
-moduledoc false.

-behaviour(gen_server).

%% DI-compatible API
-export([open/3, ws_upgrade/3, ws_send/3, close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

%% Dialyzer: transport_send/3 uses gen_tcp:socket()/ssl:sslsocket()/iodata()
%% which are the idiomatic Erlang types, broader than what dialyzer infers
%% from the two concrete call-sites.
-dialyzer({nowarn_function, [transport_send/3]}).

%%====================================================================
%% Types
%%====================================================================

-record(state, {
    owner      :: pid(),
    owner_mon  :: reference(),
    socket     :: gen_tcp:socket() | ssl:sslsocket() | undefined,
    transport  :: gen_tcp | ssl,
    host       :: string(),
    port       :: inet:port_number(),
    ws_ref     :: reference() | undefined,
    ws_key     :: binary() | undefined,
    buffer     = <<>> :: binary(),
    frag_state :: beam_agent_ws_frame:frag_state(),
    phase      :: connecting | upgrading | open | ws_open | closing,
    max_frame  :: pos_integer()
}).

%% RFC 6455 Section 4.2.2 magic GUID
-define(WS_GUID, "258EAFA5-E914-47DA-95CA-5AB9B3F2115E").

%% Default max frame payload: 64 MB
-define(DEFAULT_MAX_FRAME, 67108864).

%% Connect timeout: 30 seconds
-define(CONNECT_TIMEOUT, 30000).

%% Handshake read timeout: 15 seconds
-define(HANDSHAKE_TIMEOUT, 15000).

%% Max handshake buffer size: 64 KB
-define(MAX_HANDSHAKE_SIZE, 65536).

%%====================================================================
%% DI API
%%====================================================================

-doc "Open a TCP/TLS connection to Host:Port.".
-spec open(string(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(Host, Port, Opts) ->
    gen_server:start(?MODULE, {self(), Host, Port, Opts}, []).

-doc "Initiate the WebSocket upgrade handshake. Returns a stream ref.".
-spec ws_upgrade(pid(), iodata(), [{binary(), binary()}]) -> reference().
ws_upgrade(Pid, Path, Headers) ->
    gen_server:call(Pid, {ws_upgrade, Path, Headers}, 60000).

-doc "Send a WebSocket frame (text or binary).".
-spec ws_send(pid(), reference(), {text | binary, binary()}) ->
    ok | {error, term()}.
ws_send(Pid, _WsRef, Frame) ->
    gen_server:call(Pid, {ws_send, Frame}).

-doc "Close the WebSocket connection.".
-spec close(pid()) -> ok.
close(Pid) ->
    try gen_server:stop(Pid, normal, 5000)
    catch exit:noproc -> ok
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init({pid(), string(), inet:port_number(), map()}) ->
    {ok, #state{}}.
init({Owner, Host, Port, Opts}) ->
    MonRef = erlang:monitor(process, Owner),
    UseTls = maps:get(transport, Opts, tcp) =:= tls orelse
             maps:get(scheme, Opts, <<"wss">>) =:= <<"wss">>,
    Transport = case UseTls of true -> ssl; false -> gen_tcp end,
    MaxFrame = maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME),
    TlsOpts = maps:get(tls_opts, Opts, []),
    State = #state{
        owner      = Owner,
        owner_mon  = MonRef,
        transport  = Transport,
        host       = Host,
        port       = Port,
        frag_state = undefined,
        phase      = connecting,
        max_frame  = MaxFrame
    },
    %% Connect asynchronously via self-message
    self() ! {do_connect, UseTls, TlsOpts},
    {ok, State}.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}} | {stop, normal, term(), #state{}}.
handle_call({ws_upgrade, Path, ExtraHeaders}, _From,
            #state{phase = open, socket = Socket,
                   transport = Transport} = State) ->
    WsRef = make_ref(),
    WsKey = base64:encode(crypto:strong_rand_bytes(16)),
    PathStr = binary_to_list(iolist_to_binary(Path)),
    HostHeader = build_host_header(State#state.host, State#state.port,
                                   Transport),
    Request = build_upgrade_request(PathStr, HostHeader,
                                    WsKey, ExtraHeaders),
    case transport_send(Transport, Socket, Request) of
        ok ->
            case read_upgrade_response(Transport, Socket) of
                {ok, Headers} ->
                    case validate_accept(WsKey, Headers) of
                        ok ->
                            activate_once(Transport, Socket),
                            State1 = State#state{
                                ws_ref = WsRef,
                                ws_key = WsKey,
                                phase  = ws_open
                            },
                            State#state.owner !
                                {ws_upgraded, self(), WsRef,
                                 [<<"websocket">>], Headers},
                            {reply, WsRef, State1};
                        {error, Reason} ->
                            State#state.owner !
                                {transport_down, self(),
                                 {upgrade_failed, Reason}},
                            {stop, normal, WsRef, State}
                    end;
                {error, Reason} ->
                    State#state.owner !
                        {transport_down, self(),
                         {upgrade_failed, Reason}},
                    {stop, normal, WsRef, State}
            end;
        {error, Reason} ->
            State#state.owner !
                {transport_down, self(), {send_failed, Reason}},
            {stop, normal, WsRef, State}
    end;
handle_call({ws_send, {Type, Payload}}, _From,
            #state{phase = ws_open, socket = Socket,
                   transport = Transport} = State)
  when Type =:= text; Type =:= binary ->
    Encoded = beam_agent_ws_frame:encode(Type, Payload),
    case transport_send(Transport, Socket, Encoded) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            State#state.owner !
                {transport_down, self(), {send_failed, Reason}},
            {stop, normal, ok, State}
    end;
handle_call({ws_upgrade, _, _}, _From, State) ->
    {reply, {error, not_connected}, State};
handle_call({ws_send, _}, _From, State) ->
    {reply, {error, not_connected}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
%% --- Async connect ---
handle_info({do_connect, UseTls, TlsOpts},
            #state{phase = connecting, host = Host,
                   port = Port} = State) ->
    SockOpts = [binary, {active, false}, {packet, raw},
                {nodelay, true}],
    case connect(UseTls, Host, Port, SockOpts, TlsOpts) of
        {ok, Socket, Transport} ->
            State#state.owner ! {transport_up, self(), http},
            {noreply, State#state{
                socket    = Socket,
                transport = Transport,
                phase     = open
            }};
        {error, Reason} ->
            State#state.owner !
                {transport_down, self(), {connect_failed, Reason}},
            {stop, normal, State}
    end;
%% --- Socket data (gen_tcp) ---
handle_info({tcp, Socket, Data},
            #state{socket = Socket} = State) ->
    handle_socket_data(Data, State);
%% --- Socket data (ssl) ---
handle_info({ssl, Socket, Data},
            #state{socket = Socket} = State) ->
    handle_socket_data(Data, State);
%% --- Socket closed ---
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    State#state.owner !
        {transport_down, self(), tcp_closed},
    {stop, normal, State};
handle_info({ssl_closed, Socket}, #state{socket = Socket} = State) ->
    State#state.owner !
        {transport_down, self(), ssl_closed},
    {stop, normal, State};
%% --- Socket error ---
handle_info({tcp_error, Socket, Reason},
            #state{socket = Socket} = State) ->
    State#state.owner !
        {transport_down, self(), {tcp_error, Reason}},
    {stop, normal, State};
handle_info({ssl_error, Socket, Reason},
            #state{socket = Socket} = State) ->
    State#state.owner !
        {transport_down, self(), {ssl_error, Reason}},
    {stop, normal, State};
%% --- Owner died ---
handle_info({'DOWN', MonRef, process, _Pid, _Reason},
            #state{owner_mon = MonRef} = State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{socket = undefined}) ->
    ok;
terminate(_Reason, #state{socket = Socket, transport = Transport,
                          phase = ws_open}) ->
    %% Send close frame before shutting down
    CloseFrame = beam_agent_ws_frame:encode_close(1000, <<>>),
    catch transport_send(Transport, Socket, CloseFrame),
    catch transport_close(Transport, Socket),
    ok;
terminate(_Reason, #state{socket = Socket, transport = Transport}) ->
    catch transport_close(Transport, Socket),
    ok.

%%====================================================================
%% Internal: socket data handling
%%====================================================================

-spec handle_socket_data(binary(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
handle_socket_data(Data, #state{buffer = Buffer,
                                max_frame = MaxFrame,
                                frag_state = FragState,
                                transport = Transport,
                                socket = Socket} = State) ->
    Combined = <<Buffer/binary, Data/binary>>,
    case beam_agent_ws_frame:decode(Combined, MaxFrame, FragState) of
        {ok, Frames, Remaining, NewFrag} ->
            State1 = dispatch_frames(Frames,
                         State#state{buffer     = Remaining,
                                     frag_state = NewFrag}),
            activate_once(Transport, Socket),
            {noreply, State1};
        {error, Reason} ->
            State#state.owner !
                {transport_down, self(), {frame_error, Reason}},
            {stop, normal, State}
    end.

-spec dispatch_frames([beam_agent_ws_frame:frame()], #state{}) ->
    #state{}.
dispatch_frames([], State) ->
    State;
dispatch_frames([Frame | Rest], State) ->
    State1 = dispatch_one(Frame, State),
    dispatch_frames(Rest, State1).

-spec dispatch_one(beam_agent_ws_frame:frame(), #state{}) -> #state{}.
%% Auto-pong for ping frames (RFC 6455 Section 5.5.2)
dispatch_one({ping, Payload}, #state{socket = Socket,
                                     transport = Transport} = State) ->
    Pong = beam_agent_ws_frame:encode(pong, Payload),
    catch transport_send(Transport, Socket, Pong),
    State;
%% Ignore unsolicited pong
dispatch_one({pong, _}, State) ->
    State;
%% Close frame — echo back and notify owner
dispatch_one({close, Code, Reason}, #state{socket = Socket,
                                           transport = Transport,
                                           ws_ref = WsRef} = State) ->
    CloseReply = beam_agent_ws_frame:encode_close(Code, <<>>),
    catch transport_send(Transport, Socket, CloseReply),
    State#state.owner !
        {ws_frame, self(), WsRef, {close, Code, Reason}},
    State#state{phase = closing};
%% Data frames — forward to owner
dispatch_one({Type, Payload}, #state{ws_ref = WsRef} = State)
  when Type =:= text; Type =:= binary ->
    State#state.owner !
        {ws_frame, self(), WsRef, {Type, Payload}},
    State.

%%====================================================================
%% Internal: TCP/TLS connection
%%====================================================================

-spec connect(boolean(), string(), inet:port_number(),
              list(), list()) ->
    {ok, gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl} |
    {error, term()}.
connect(false, Host, Port, SockOpts, _TlsOpts) ->
    case gen_tcp:connect(Host, Port, SockOpts, ?CONNECT_TIMEOUT) of
        {ok, Socket} -> {ok, Socket, gen_tcp};
        {error, _} = Err -> Err
    end;
connect(true, Host, Port, SockOpts, TlsOpts) ->
    DefaultTls = [{verify, verify_peer},
                  {cacerts, public_key:cacerts_get()},
                  {depth, 4},
                  {server_name_indication, Host}],
    MergedTls = merge_tls_opts(DefaultTls, TlsOpts),
    AllOpts = SockOpts ++ MergedTls,
    case ssl:connect(Host, Port, AllOpts, ?CONNECT_TIMEOUT) of
        {ok, Socket} -> {ok, Socket, ssl};
        {error, _} = Err -> Err
    end.

-spec merge_tls_opts(list(), list()) -> list().
merge_tls_opts(Defaults, []) ->
    Defaults;
merge_tls_opts(_Defaults, Custom) ->
    %% Custom opts take full precedence (no partial merge).
    Custom.

%%====================================================================
%% Internal: WebSocket upgrade handshake
%%====================================================================

-spec build_upgrade_request(string(), string(), binary(),
                            [{binary(), binary()}]) -> [[[any(), ...] | char()], ...].
build_upgrade_request(Path, HostHeader, WsKey, ExtraHeaders) ->
    ExtraLines = [[binary_to_list(K), ": ", binary_to_list(V), "\r\n"]
                  || {K, V} <- ExtraHeaders],
    ["GET ", Path, " HTTP/1.1\r\n",
     "Host: ", HostHeader, "\r\n",
     "Upgrade: websocket\r\n",
     "Connection: Upgrade\r\n",
     "Sec-WebSocket-Key: ", binary_to_list(WsKey), "\r\n",
     "Sec-WebSocket-Version: 13\r\n",
     ExtraLines,
     "\r\n"].

-spec build_host_header(string(), inet:port_number(),
                        gen_tcp | ssl) -> string().
build_host_header(Host, 443, ssl) -> Host;
build_host_header(Host, 80, gen_tcp) -> Host;
build_host_header(Host, Port, _) ->
    lists:flatten(io_lib:format("~s:~B", [Host, Port])).

-spec read_upgrade_response(gen_tcp | ssl,
                            gen_tcp:socket() | ssl:sslsocket()) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
read_upgrade_response(Transport, Socket) ->
    read_response_lines(Transport, Socket, <<>>, ?HANDSHAKE_TIMEOUT).

-spec read_response_lines(gen_tcp | ssl,
                          gen_tcp:socket() | ssl:sslsocket(),
                          binary(), timeout()) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
read_response_lines(Transport, Socket, Buffer, Timeout) ->
    case transport_recv(Transport, Socket, 0, Timeout) of
        {ok, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            case byte_size(NewBuffer) > ?MAX_HANDSHAKE_SIZE of
                true ->
                    {error, handshake_too_large};
                false ->
                    case binary:match(NewBuffer, <<"\r\n\r\n">>) of
                        {Pos, 4} ->
                            HeaderBlock = binary:part(NewBuffer, 0, Pos),
                            parse_response(HeaderBlock);
                        nomatch ->
                            read_response_lines(Transport, Socket,
                                                NewBuffer, Timeout)
                    end
            end;
        {error, _} = Err ->
            Err
    end.

-spec parse_response(binary()) ->
    {ok, [{binary(), binary()}]} | {error, {unexpected_status, binary()}}.
parse_response(Block) ->
    [StatusLine | HeaderLines] = binary:split(Block, <<"\r\n">>,
                                              [global]),
    case StatusLine of
        <<"HTTP/1.1 101", _/binary>> ->
            Headers = parse_headers(HeaderLines),
            {ok, Headers};
        _ ->
            {error, {unexpected_status, StatusLine}}
    end.

-spec parse_headers([binary()]) -> [{binary(), binary()}].
parse_headers(Lines) ->
    lists:filtermap(fun(Line) ->
        case binary:split(Line, <<": ">>) of
            [Key, Value] ->
                {true, {string:lowercase(Key), Value}};
            _ ->
                false
        end
    end, Lines).

-spec validate_accept(binary(), [{binary(), binary()}]) ->
    ok | {error, {invalid_accept, binary() | undefined}}.
validate_accept(WsKey, Headers) ->
    Expected = base64:encode(
        crypto:hash(sha, [WsKey, <<?WS_GUID>>])),
    case proplists:get_value(<<"sec-websocket-accept">>, Headers) of
        Expected -> ok;
        Other    -> {error, {invalid_accept, Other}}
    end.

%%====================================================================
%% Internal: transport wrappers
%%====================================================================

-spec transport_send(gen_tcp | ssl,
                     gen_tcp:socket() | ssl:sslsocket(),
                     iodata()) -> ok | {error, _}.
transport_send(gen_tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
transport_send(ssl, Socket, Data)     -> ssl:send(Socket, Data).

-spec transport_recv(gen_tcp | ssl,
                     gen_tcp:socket() | ssl:sslsocket(),
                     non_neg_integer(), timeout()) ->
    {ok, binary()} | {error, term()}.
transport_recv(gen_tcp, Socket, Len, Timeout) ->
    gen_tcp:recv(Socket, Len, Timeout);
transport_recv(ssl, Socket, Len, Timeout) ->
    ssl:recv(Socket, Len, Timeout).

-spec transport_close(gen_tcp | ssl,
                      gen_tcp:socket() | ssl:sslsocket()) -> ok.
transport_close(gen_tcp, Socket) -> gen_tcp:close(Socket);
transport_close(ssl, Socket)     -> ssl:close(Socket).

-spec activate_once(gen_tcp | ssl,
                    gen_tcp:socket() | ssl:sslsocket()) -> ok.
activate_once(gen_tcp, Socket) ->
    ok = inet:setopts(Socket, [{active, once}]);
activate_once(ssl, Socket) ->
    ok = ssl:setopts(Socket, [{active, once}]).
