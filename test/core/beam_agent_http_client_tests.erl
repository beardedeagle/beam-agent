%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_http_client.
%%%
%%% Tests use real TCP listeners to verify the full request/response
%%% cycle through OTP httpc.  No mocking (meck) is used — the test
%%% spawns a minimal TCP acceptor that speaks raw HTTP/1.1 just
%%% enough for httpc to parse the responses.
%%%
%%% Tests cover:
%%%   - Process lifecycle: start → transport_up → close
%%%   - Owner death terminates client
%%%   - GET request with 200 streaming response
%%%   - POST request with 200 streaming response
%%%   - Non-2xx response via full-response path
%%%   - Module loaded check
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_http_client_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Module loading
%%====================================================================

module_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_http_client) orelse
        code:ensure_loaded(beam_agent_http_client) =:=
            {module, beam_agent_http_client}).

%%====================================================================
%% Process lifecycle
%%====================================================================

start_sends_transport_up_test() ->
    {ok, _Port, LSock} = listen(),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", _Port, #{}),
        receive
            {transport_up, Pid, http} -> ok
        after 2000 ->
            error(no_transport_up)
        end,
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

close_stops_process_test() ->
    {ok, _Port, LSock} = listen(),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", _Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,
        MonRef = monitor(process, Pid),
        beam_agent_http_client:close(Pid),
        receive
            {'DOWN', MonRef, process, Pid, normal} -> ok
        after 2000 ->
            error(process_not_stopped)
        end
    after
        gen_tcp:close(LSock)
    end.

owner_death_stops_client_test() ->
    {ok, _Port, LSock} = listen(),
    try
        Self = self(),
        Owner = spawn(fun() ->
            {ok, Pid} = beam_agent_http_client:open("127.0.0.1", _Port, #{}),
            Self ! {client_pid, Pid},
            receive stop -> ok end
        end),
        ClientPid = receive {client_pid, P} -> P after 2000 -> error(timeout) end,
        MonRef = monitor(process, ClientPid),
        exit(Owner, kill),
        receive
            {'DOWN', MonRef, process, ClientPid, normal} -> ok
        after 2000 ->
            error(client_not_stopped)
        end
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% GET with 200 streaming response
%%====================================================================

get_200_streaming_test() ->
    {ok, Port, LSock} = listen(),
    spawn_responder(LSock, 200, <<"application/json">>, <<"{\"ok\":true}">>),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        _StreamRef = beam_agent_http_client:get(Pid, <<"/test">>,
            [{<<"accept">>, <<"application/json">>}]),

        %% httpc streams 2xx: http_response(nofin, 200) → http_data(fin)
        receive
            {http_response, Pid, _, nofin, 200, _Headers} -> ok
        after 5000 ->
            error(no_http_response)
        end,
        collect_body(Pid),
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% POST with 200 streaming response
%%====================================================================

post_200_streaming_test() ->
    {ok, Port, LSock} = listen(),
    spawn_responder(LSock, 200, <<"application/json">>, <<"{\"created\":true}">>),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        _StreamRef = beam_agent_http_client:post(Pid, <<"/items">>,
            [{<<"content-type">>, <<"application/json">>}],
            <<"{\"name\":\"test\"}">>),

        receive
            {http_response, Pid, _, nofin, 200, _Headers} -> ok
        after 5000 ->
            error(no_http_response)
        end,
        collect_body(Pid),
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Non-2xx uses full-response path
%%====================================================================

get_404_full_response_test() ->
    {ok, Port, LSock} = listen(),
    spawn_responder(LSock, 404, <<"text/plain">>, <<"not found">>),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        _StreamRef = beam_agent_http_client:get(Pid, <<"/missing">>, []),

        %% Non-2xx: httpc delivers full response in one message.
        %% http_client translates to http_response + http_data.
        receive
            {http_response, Pid, _, _, 404, _Headers} -> ok
        after 5000 ->
            error(no_http_response)
        end,
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% PATCH with 200 response
%%====================================================================

patch_200_test() ->
    {ok, Port, LSock} = listen(),
    spawn_responder(LSock, 200, <<"application/json">>, <<"{\"patched\":true}">>),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        _StreamRef = beam_agent_http_client:patch(Pid, <<"/items/1">>,
            [{<<"content-type">>, <<"application/json">>}],
            <<"{\"name\":\"updated\"}">>),

        receive
            {http_response, Pid, _, nofin, 200, _Headers} -> ok
        after 5000 ->
            error(no_http_response)
        end,
        collect_body(Pid),
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% DELETE with 200 response
%%====================================================================

delete_200_test() ->
    {ok, Port, LSock} = listen(),
    spawn_responder(LSock, 200, <<"application/json">>, <<"{\"deleted\":true}">>),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        _StreamRef = beam_agent_http_client:delete(Pid, <<"/items/1">>, []),

        receive
            {http_response, Pid, _, nofin, 200, _Headers} -> ok
        after 5000 ->
            error(no_http_response)
        end,
        collect_body(Pid),
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Request failure — immediate socket close
%%====================================================================

request_failure_test() ->
    {ok, Port, LSock} = listen(),
    try
        {ok, Pid} = beam_agent_http_client:open("127.0.0.1", Port, #{}),
        receive {transport_up, Pid, http} -> ok after 2000 -> error(timeout) end,

        %% Accept and immediately close — httpc should get an error
        spawn_link(fun() ->
            {ok, Sock} = gen_tcp:accept(LSock, 5000),
            gen_tcp:close(Sock)
        end),

        Ref = beam_agent_http_client:get(Pid, <<"/fail">>, []),
        ?assert(is_reference(Ref)),

        %% httpc delivers async error → http_client translates to transport_down
        receive
            {transport_down, Pid, {request_error, _Reason}} -> ok
        after 5000 ->
            error(no_transport_down)
        end,
        beam_agent_http_client:close(Pid)
    after
        gen_tcp:close(LSock)
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Start a TCP listener on a random port.
-spec listen() -> {ok, inet:port_number(), gen_tcp:socket()}.
listen() ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false},
                                     {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    {ok, Port, LSock}.

%% @doc Spawn a process that accepts one connection and sends an HTTP
%%      response with the given status, content-type, and body.
-spec spawn_responder(gen_tcp:socket(), pos_integer(), binary(),
                      binary()) -> pid().
spawn_responder(LSock, Status, ContentType, Body) ->
    spawn_link(fun() ->
        {ok, Sock} = gen_tcp:accept(LSock, 10000),
        %% Drain the HTTP request
        _ = drain_request(Sock),
        %% Send response
        StatusLine = io_lib:format("HTTP/1.1 ~B OK", [Status]),
        BodyLen = integer_to_list(byte_size(Body)),
        Response = [StatusLine, "\r\n",
                    "Content-Type: ", ContentType, "\r\n",
                    "Content-Length: ", BodyLen, "\r\n",
                    "Connection: close\r\n",
                    "\r\n",
                    Body],
        ok = gen_tcp:send(Sock, Response),
        gen_tcp:close(Sock)
    end).

%% @doc Read from socket until we see the end of HTTP headers.
-spec drain_request(gen_tcp:socket()) -> ok.
drain_request(Sock) ->
    drain_request(Sock, <<>>).

-spec drain_request(gen_tcp:socket(), binary()) -> ok.
drain_request(Sock, Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        {_, _} -> ok;
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> drain_request(Sock, <<Buf/binary, Data/binary>>);
                {error, _} -> ok
            end
    end.

%% @doc Collect streaming body chunks until we get a fin marker.
-spec collect_body(pid()) -> binary().
collect_body(Pid) ->
    collect_body(Pid, <<>>).

-spec collect_body(pid(), binary()) -> binary().
collect_body(Pid, Acc) ->
    receive
        {http_data, Pid, _, fin, Chunk} ->
            <<Acc/binary, Chunk/binary>>;
        {http_data, Pid, _, nofin, Chunk} ->
            collect_body(Pid, <<Acc/binary, Chunk/binary>>)
    after 5000 ->
        Acc
    end.
