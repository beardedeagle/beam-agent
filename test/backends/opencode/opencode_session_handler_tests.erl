%%%-------------------------------------------------------------------
%%% @doc EUnit tests for opencode_session_handler hardening.
%%%
%%% Pure unit tests for M5 (plaintext HTTP warning predicate).
%%% Integration tests for L14 (event queue depth limit).
%%%
%%% M5 tests exercise the exported is_remote_plaintext_http/1 pure
%%% function directly — no processes, no HTTP.
%%%
%%% L14 tests use the same test_http_client injection pattern as
%%% opencode_session_tests.erl to drive a live session through the
%%% full subscribe_events → event enqueue → receive_event path,
%%% verifying that the event queue is capped at max_event_queue_depth
%%% and that the oldest event is dropped when the cap is exceeded.
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_session_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% M5: is_remote_plaintext_http/1 — pure predicate unit tests
%%====================================================================

http_localhost_not_remote_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            "http://localhost:4096")).

http_127_0_0_1_not_remote_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            "http://127.0.0.1:4096")).

http_ipv6_loopback_not_remote_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            "http://::1:4096")).

http_remote_hostname_is_remote_test() ->
    ?assertEqual(true,
        opencode_session_handler:is_remote_plaintext_http(
            "http://opencode.example.com:4096")).

http_remote_ip_is_remote_test() ->
    ?assertEqual(true,
        opencode_session_handler:is_remote_plaintext_http(
            "http://10.0.0.5:4096")).

https_remote_not_flagged_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            "https://opencode.example.com:4096")).

https_localhost_not_flagged_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            "https://localhost:4096")).

binary_http_remote_test() ->
    ?assertEqual(true,
        opencode_session_handler:is_remote_plaintext_http(
            <<"http://remote.host:4096">>)).

binary_http_localhost_test() ->
    ?assertEqual(false,
        opencode_session_handler:is_remote_plaintext_http(
            <<"http://localhost:4096">>)).

%%====================================================================
%% M5: check_transport_security/3 — reject plaintext HTTP with auth
%%====================================================================

security_no_auth_always_ok_test() ->
    ?assertEqual(ok,
        opencode_session_handler:check_transport_security(
            none, "http://remote.host:4096", #{})).

security_auth_over_https_ok_test() ->
    ?assertEqual(ok,
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "https://opencode.example.com:4096", #{})).

security_auth_over_localhost_ok_test() ->
    ?assertEqual(ok,
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "http://localhost:4096", #{})).

security_auth_over_127_ok_test() ->
    ?assertEqual(ok,
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "http://127.0.0.1:4096", #{})).

security_auth_over_remote_http_rejected_test() ->
    ?assertEqual({error, plaintext_auth},
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "http://opencode.example.com:4096", #{})).

security_auth_over_remote_http_with_override_ok_test() ->
    ?assertEqual(ok,
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "http://opencode.example.com:4096",
            #{allow_insecure_http => true})).

security_auth_over_remote_ip_rejected_test() ->
    ?assertEqual({error, plaintext_auth},
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            "http://10.0.0.5:4096", #{})).

security_binary_url_works_test() ->
    ?assertEqual({error, plaintext_auth},
        opencode_session_handler:check_transport_security(
            {basic, <<"dXNlcjpwYXNz">>},
            <<"http://remote.host:4096">>, #{})).

%%====================================================================
%% L14: event queue depth limit — integration tests
%%====================================================================

event_queue_depth_test_() ->
    {"event queue depth limit with injected transport",
     {setup,
      fun setup/0,
      fun cleanup/1,
      fun(_) -> [
          {"event queue drops oldest when max_event_queue_depth exceeded",
           {timeout, 15, fun test_queue_depth_drops_oldest/0}},
          {"event queue allows events up to max_event_queue_depth",
           {timeout, 15, fun test_queue_depth_at_limit/0}}
      ] end}}.

setup() ->
    _ = application:ensure_all_started(telemetry),
    ok.

cleanup(_) ->
    ok.

%%--------------------------------------------------------------------
%% Test: filling the queue to exactly MaxDepth all arrive correctly
%%--------------------------------------------------------------------

test_queue_depth_at_limit() ->
    MaxDepth = 3,
    {Pid, ConnPid, SseRef} = start_ready_session(#{
        max_event_queue_depth => MaxDepth
    }),

    {ok, EventRef} = opencode_session:subscribe_events(Pid),

    %% Enqueue exactly MaxDepth events (no overflow)
    lists:foreach(fun(N) ->
        Delta = integer_to_binary(N),
        send_sse(Pid, ConnPid, SseRef,
            <<"event: message.part.updated\n",
              "data: {\"part\":{\"type\":\"text\",\"delta\":\"msg",
              Delta/binary, "\"}}\n\n">>),
        timer:sleep(10)
    end, lists:seq(1, MaxDepth)),

    timer:sleep(30),

    %% All MaxDepth events should be receivable
    Events = drain_events(Pid, EventRef, MaxDepth),
    ?assertEqual(MaxDepth, length(Events)),

    _ = opencode_session:unsubscribe_events(Pid, EventRef),
    stop_session(Pid).

%%--------------------------------------------------------------------
%% Test: exceeding MaxDepth causes oldest to be dropped
%%--------------------------------------------------------------------

test_queue_depth_drops_oldest() ->
    MaxDepth = 3,
    TotalEvents = MaxDepth + 2,  %% 5 events, only 3 survive
    {Pid, ConnPid, SseRef} = start_ready_session(#{
        max_event_queue_depth => MaxDepth
    }),

    {ok, EventRef} = opencode_session:subscribe_events(Pid),

    %% Enqueue TotalEvents without consuming any (consumer is not parked)
    lists:foreach(fun(N) ->
        Delta = integer_to_binary(N),
        send_sse(Pid, ConnPid, SseRef,
            <<"event: message.part.updated\n",
              "data: {\"part\":{\"type\":\"text\",\"delta\":\"evt",
              Delta/binary, "\"}}\n\n">>),
        timer:sleep(10)
    end, lists:seq(1, TotalEvents)),

    timer:sleep(30),

    %% Only MaxDepth events survive; oldest (1, 2) were dropped
    Events = drain_events(Pid, EventRef, MaxDepth),
    ?assertEqual(MaxDepth, length(Events)),

    %% The surviving events are the newest ones (evt3, evt4, evt5)
    Contents = [maps:get(content, E) || E <- Events],
    ?assertEqual([<<"evt3">>, <<"evt4">>, <<"evt5">>], Contents),

    _ = opencode_session:unsubscribe_events(Pid, EventRef),
    stop_session(Pid).

%%====================================================================
%% Helpers
%%====================================================================

%% Returns {SessionPid, ConnPid, SseRef} after driving the session
%% through connecting → initializing → ready, using test_http_client.
start_ready_session(ExtraOpts) ->
    flush_http_requests(),
    test_http_client:setup(),
    test_http_client:set_owner(),

    Opts = maps:merge(#{
        client_module => test_http_client,
        directory     => <<"/tmp/test">>,
        base_url      => <<"http://localhost:4096">>
    }, ExtraOpts),

    {ok, Pid} = opencode_session:start_link(Opts),
    ConnPid = test_http_client:conn_pid(),

    Pid ! {transport_up, ConnPid, http},

    SseRef = receive
        {http_request, get, _Path, Ref0} -> Ref0
    after 1000 -> error(no_sse_get)
    end,

    Pid ! {http_response, ConnPid, SseRef, nofin, 200,
           [{<<"content-type">>, <<"text/event-stream">>}]},
    send_sse(Pid, ConnPid, SseRef,
             <<"event: server.connected\ndata: {}\n\n">>),
    timer:sleep(20),

    CreateRef = receive
        {http_request, post, <<"/session">>, _Body, Ref1} -> Ref1
    after 1000 -> error(no_session_post)
    end,
    SessionJson = json:encode(#{<<"id">> => <<"sess-test">>}),
    Pid ! {http_response, ConnPid, CreateRef, nofin, 200, []},
    Pid ! {http_data, ConnPid, CreateRef, fin, SessionJson},
    timer:sleep(20),

    {Pid, ConnPid, SseRef}.

stop_session(Pid) ->
    catch opencode_session:stop(Pid),
    test_http_client:teardown().

send_sse(Pid, ConnPid, SseRef, Data) ->
    Pid ! {http_data, ConnPid, SseRef, nofin, Data},
    ok.

flush_http_requests() ->
    receive
        {http_request, _, _, _}    -> flush_http_requests();
        {http_request, _, _, _, _} -> flush_http_requests()
    after 0 -> ok
    end.

%% Drain up to N events using receive_event with a short timeout.
%% Stops when the queue is empty (timeout) or N events collected.
drain_events(_Pid, _EventRef, 0) ->
    [];
drain_events(Pid, EventRef, N) ->
    case opencode_session:receive_event(Pid, EventRef, 200) of
        {ok, Ev} ->
            [Ev | drain_events(Pid, EventRef, N - 1)];
        {error, _} ->
            []
    end.
