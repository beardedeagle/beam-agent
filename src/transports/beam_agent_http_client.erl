-module(beam_agent_http_client).
-moduledoc false.

-behaviour(gen_server).

%% DI-compatible API
-export([open/3, get/3, post/4, patch/4, delete/3, close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, format_status/1]).

%%====================================================================
%% Types
%%====================================================================

-record(state, {
    owner         :: pid(),
    owner_mon     :: reference(),
    base_url      :: string(),
    ssl_opts      :: list(),
    timeout       :: pos_integer(),
    connect_timeout :: pos_integer(),
    max_body_size :: pos_integer(),
    %% httpc RequestId → our StreamRef
    pending       :: #{reference() => reference()},
    %% httpc RequestId → accumulated body byte count
    body_sizes    :: #{reference() => non_neg_integer()}
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
            case build_ssl_opts(Scheme, Host, Opts) of
                {ok, SslOpts} ->
                    MonRef = erlang:monitor(process, Owner),
                    Timeout = maps:get(timeout, Opts, 30000),
                    ConnectTimeout = maps:get(connect_timeout, Opts, 10000),
                    MaxBodySize = maps:get(max_body_size, Opts, 104_857_600),
                    %% Signal readiness — analogous to TCP connect completing.
                    Owner ! {transport_up, self(), http},
                    {ok, #state{
                        owner           = Owner,
                        owner_mon       = MonRef,
                        base_url        = BaseUrl,
                        ssl_opts        = SslOpts,
                        timeout         = Timeout,
                        connect_timeout = ConnectTimeout,
                        max_body_size   = MaxBodySize,
                        pending         = #{},
                        body_sizes      = #{}
                    }};
                {error, unsafe_tls_opts} ->
                    {stop, unsafe_tls_opts}
            end;
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
    HttpOpts0 = [{timeout, State#state.timeout},
                 {connect_timeout, State#state.connect_timeout}],
    HttpOpts = case State#state.ssl_opts of
        [] -> HttpOpts0;
        Ssl -> [{ssl, Ssl} | HttpOpts0]
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
            Prev = maps:get(ReqId, State#state.body_sizes, 0),
            Size = Prev + byte_size(Data),
            case Size > State#state.max_body_size of
                true ->
                    catch httpc:cancel_request(ReqId),
                    State#state.owner !
                        {transport_down, self(), {body_too_large, Size}},
                    Pending1 = maps:remove(ReqId, State#state.pending),
                    BodySizes1 = maps:remove(ReqId, State#state.body_sizes),
                    {noreply, State#state{pending = Pending1,
                                         body_sizes = BodySizes1}};
                false ->
                    State#state.owner !
                        {http_data, self(), StreamRef, nofin, Data},
                    BodySizes1 = maps:put(ReqId, Size, State#state.body_sizes),
                    {noreply, State#state{body_sizes = BodySizes1}}
            end
    end;
handle_info({http, {ReqId, stream_end, _Headers}}, State) ->
    case maps:get(ReqId, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        StreamRef ->
            State#state.owner !
                {http_data, self(), StreamRef, fin, <<>>},
            Pending1 = maps:remove(ReqId, State#state.pending),
            BodySizes1 = maps:remove(ReqId, State#state.body_sizes),
            {noreply, State#state{pending = Pending1,
                                  body_sizes = BodySizes1}}
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
            _ = case Body of
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
            BodySizes1 = maps:remove(ReqId, State#state.body_sizes),
            {noreply, State#state{pending = Pending1,
                                  body_sizes = BodySizes1}}
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
            BodySizes1 = maps:remove(ReqId, State#state.body_sizes),
            {noreply, State#state{pending = Pending1,
                                  body_sizes = BodySizes1}}
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

-doc "Redact sensitive fields from crash logs and sys:get_status output.".
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    State = maps:get(state, Status, undefined),
    Status#{state => redact_state(State)}.

-spec redact_state(#state{} | term()) -> #state{} | term().
redact_state(#state{} = State) ->
    %% ssl_opts may contain private key material; redact it.
    State#state{ssl_opts = [redacted]};
redact_state(Other) ->
    Other.

%%====================================================================
%% Internal helpers
%%====================================================================

-spec start_dependencies() -> ok | {error, {app_start_failed, inets | ssl, {atom(), _}}}.
start_dependencies() ->
    case ensure_started(inets) of
        ok -> ensure_started(ssl);
        {error, _} = Err -> Err
    end.

-spec ensure_started(inets | ssl) -> ok | {error, {app_start_failed, inets | ssl, {atom(), _}}}.
ensure_started(App) ->
    case application:ensure_all_started(App) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason}               -> {error, {app_start_failed, App, Reason}}
    end.

-spec build_ssl_opts(string(), string(), map()) -> {ok, list()} | {error, unsafe_tls_opts}.
build_ssl_opts("https", Host, Opts) ->
    beam_agent_transport_utils:tls_client_opts(
        Host,
        maps:get(tls_opts, Opts, []),
        maps:get(allow_insecure_tls, Opts, false));
build_ssl_opts(_, _Host, _Opts) ->
    {ok, []}.

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
