-module(beam_agent_http_client).
-moduledoc """
HTTP/1.1 client for beam_agent transports.

Wraps OTP `httpc` to provide the DI interface expected by beam_agent
transport modules. Each client instance is a gen_server that translates
httpc async responses into beam_agent transport messages forwarded to
the owner process.

## Why a Process?

The transport behaviour contract requires a monitorable pid for
`is_ready/1` and `classify_message/2`. This gen_server satisfies that
contract while encapsulating httpc details: the session handler never
sees httpc message formats.

## Message Protocol

The owner process receives:

  - `{transport_up, Pid, http}` — client ready for requests
  - `{http_response, Pid, Ref, IsFin, Status, Headers}` — response start
  - `{http_data, Pid, Ref, IsFin, Data}` — response body chunk
  - `{transport_down, Pid, Reason}` — request-level error

## DI Interface

Implements the same function signatures as the transport modules expect:

  - `open/3` — start client (Host, Port, ConnOpts map)
  - `get/3` — async GET request
  - `post/4` — async POST request
  - `patch/4` — async PATCH request
  - `delete/3` — async DELETE request
  - `close/1` — stop client

## Streaming Behaviour

All requests use httpc's `{stream, self}` mode. For 2xx responses,
httpc delivers `stream_start`, `stream`, `stream_end` messages which
are translated to `http_response` (nofin) + `http_data` sequences.
Non-2xx responses are delivered as complete results with exact status
codes.
""".

-behaviour(gen_server).

%% DI-compatible API
-export([open/3, get/3, post/4, patch/4, delete/3, close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

%%====================================================================
%% Types
%%====================================================================

-record(state, {
    owner     :: pid(),
    owner_mon :: reference(),
    base_url  :: string(),
    ssl_opts  :: list(),
    %% httpc RequestId → our StreamRef
    pending   :: #{reference() => reference()}
}).

%%====================================================================
%% DI API
%%====================================================================

-doc "Start a new HTTP client targeting Host:Port.".
-spec open(string(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(Host, Port, Opts) ->
    gen_server:start(?MODULE, {self(), Host, Port, Opts}, []).

-doc "Issue an async GET request. Returns a stream reference immediately.".
-spec get(pid(), iodata(), [{binary(), binary()}]) -> reference().
get(Pid, Path, Headers) ->
    gen_server:call(Pid, {request, get, Path, Headers, <<>>}).

-doc "Issue an async POST request. Returns a stream reference immediately.".
-spec post(pid(), iodata(), [{binary(), binary()}], iodata()) -> reference().
post(Pid, Path, Headers, Body) ->
    gen_server:call(Pid, {request, post, Path, Headers, Body}).

-doc "Issue an async PATCH request. Returns a stream reference immediately.".
-spec patch(pid(), iodata(), [{binary(), binary()}], iodata()) -> reference().
patch(Pid, Path, Headers, Body) ->
    gen_server:call(Pid, {request, patch, Path, Headers, Body}).

-doc "Issue an async DELETE request. Returns a stream reference immediately.".
-spec delete(pid(), iodata(), [{binary(), binary()}]) -> reference().
delete(Pid, Path, Headers) ->
    gen_server:call(Pid, {request, delete, Path, Headers, <<>>}).

-doc "Stop the HTTP client and cancel any pending requests.".
-spec close(pid()) -> ok.
close(Pid) ->
    try gen_server:stop(Pid, normal, 5000)
    catch exit:noproc -> ok
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init({pid(), string(), inet:port_number(), map()}) ->
    {ok, #state{}} | {stop, term()}.
init({Owner, Host, Port, Opts}) ->
    case start_dependencies() of
        ok ->
            Scheme = case maps:get(transport, Opts, tcp) of
                tls -> "https";
                _   -> "http"
            end,
            BaseUrl = lists:flatten(
                io_lib:format("~s://~s:~B", [Scheme, Host, Port])),
            SslOpts = build_ssl_opts(Scheme, maps:get(tls_opts, Opts, [])),
            MonRef = erlang:monitor(process, Owner),
            %% Signal readiness — analogous to TCP connect completing.
            Owner ! {transport_up, self(), http},
            {ok, #state{
                owner     = Owner,
                owner_mon = MonRef,
                base_url  = BaseUrl,
                ssl_opts  = SslOpts,
                pending   = #{}
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, reference() | {error, term()}, #state{}}.
handle_call({request, Method, Path, Headers, Body}, _From, State) ->
    StreamRef = make_ref(),
    Url = State#state.base_url ++
          binary_to_list(iolist_to_binary(Path)),
    HdrList = headers_to_httpc(Headers),
    HttpOpts = case State#state.ssl_opts of
        [] -> [];
        Ssl -> [{ssl, Ssl}]
    end,
    Request = build_request(Method, Url, HdrList, Body),
    AsyncOpts = [{sync, false}, {stream, self}],
    case httpc:request(Method, Request, HttpOpts, AsyncOpts) of
        {ok, RequestId} ->
            Pending1 = maps:put(RequestId, StreamRef,
                                State#state.pending),
            {reply, StreamRef, State#state{pending = Pending1}};
        {error, Reason} ->
            State#state.owner !
                {transport_down, self(), {request_failed, Reason}},
            {reply, {error, Reason}, State}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.
%% --- httpc streaming: 2xx responses ---
handle_info({http, {ReqId, stream_start, RawHeaders}}, State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        StreamRef ->
            Headers = translate_headers(RawHeaders),
            State#state.owner !
                {http_response, self(), StreamRef, nofin, 200, Headers},
            {noreply, State}
    end;
handle_info({http, {ReqId, stream, Data}}, State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        StreamRef ->
            State#state.owner !
                {http_data, self(), StreamRef, nofin, Data},
            {noreply, State}
    end;
handle_info({http, {ReqId, stream_end, _Headers}}, State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        StreamRef ->
            State#state.owner !
                {http_data, self(), StreamRef, fin, <<>>},
            Pending1 = maps:remove(ReqId, State#state.pending),
            {noreply, State#state{pending = Pending1}}
    end;
%% --- httpc full response: non-2xx or non-streaming ---
handle_info({http, {ReqId, {{_, Status, _}, RawHeaders, Body}}},
            State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        StreamRef ->
            Headers = translate_headers(RawHeaders),
            Owner = State#state.owner,
            case Body of
                [] ->
                    Owner !
                        {http_response, self(), StreamRef,
                         fin, Status, Headers};
                _ ->
                    Owner !
                        {http_response, self(), StreamRef,
                         nofin, Status, Headers},
                    Owner !
                        {http_data, self(), StreamRef, fin,
                         iolist_to_binary(Body)}
            end,
            Pending1 = maps:remove(ReqId, State#state.pending),
            {noreply, State#state{pending = Pending1}}
    end;
%% --- httpc request error ---
handle_info({http, {ReqId, {error, Reason}}}, State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        _StreamRef ->
            State#state.owner !
                {transport_down, self(), {request_error, Reason}},
            Pending1 = maps:remove(ReqId, State#state.pending),
            {noreply, State#state{pending = Pending1}}
    end;
%% --- Owner died ---
handle_info({'DOWN', MonRef, process, _Pid, _Reason},
            #state{owner_mon = MonRef} = State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{pending = Pending}) ->
    maps:foreach(fun(ReqId, _) ->
        catch httpc:cancel_request(ReqId)
    end, Pending),
    ok.

%%====================================================================
%% Internal helpers
%%====================================================================

-spec start_dependencies() -> ok | {error, term()}.
start_dependencies() ->
    case ensure_started(inets) of
        ok -> ensure_started(ssl);
        {error, _} = Err -> Err
    end.

-spec ensure_started(atom()) -> ok | {error, term()}.
ensure_started(App) ->
    case application:ensure_all_started(App) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason}               -> {error, {app_start_failed, App, Reason}}
    end.

-spec build_ssl_opts(string(), list()) -> list().
build_ssl_opts("https", []) ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 4}];
build_ssl_opts("https", Custom) ->
    Custom;
build_ssl_opts(_, _) ->
    [].

-spec headers_to_httpc([{binary(), binary()}]) ->
    [{string(), string()}].
headers_to_httpc(Headers) ->
    [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers].

-spec translate_headers([{string(), string()}]) ->
    [{binary(), binary()}].
translate_headers(Headers) when is_list(Headers) ->
    [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers].

-spec build_request(atom(), string(), [{string(), string()}],
                    iodata()) ->
    {string(), [{string(), string()}]} |
    {string(), [{string(), string()}], string(), binary()}.
build_request(get, Url, Headers, _Body) ->
    {Url, Headers};
build_request(delete, Url, Headers, _Body) ->
    {Url, Headers};
build_request(Method, Url, Headers, Body)
  when Method =:= post; Method =:= patch ->
    %% Headers are expected lowercase (binary_to_list converts case-preserving).
    ContentType = proplists:get_value(
        "content-type", Headers, "application/json"),
    {Url, Headers, ContentType, iolist_to_binary(Body)}.
