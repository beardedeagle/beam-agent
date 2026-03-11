%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_mcp_transport_http.
%%%
%%% Tests cover classify_message/2 for connection-level gun events,
%%% send/2 header construction, and close/1 DELETE logic.
%%%
%%% The `test_mcp_gun` fixture is used for all tests that require an
%%% actual gun connection (start/1, send/2, close/1).  For pure
%%% classify_message/2 tests, `self()` serves as ConnPid so the
%%% pattern-match succeeds without any network activity.
%%%
%%% HTTP-level messages (gun_response, gun_data) are verified to
%%% return `ignore` — the session handler processes them directly.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_mcp_transport_http_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

%% Build a minimal transport ref using self() as ConnPid.
%% This lets classify_message/2 patterns match without gun.
make_ref_self() ->
    ConnPid  = self(),
    MonRef   = make_ref(),
    SessState = #{path => <<"/mcp">>,
                  session_id => undefined,
                  protocol_version => undefined},
    {ConnPid, MonRef, test_mcp_gun, SessState}.

%%====================================================================
%% Module loading
%%====================================================================

module_loaded_test() ->
    ?assert(erlang:module_loaded(beam_agent_mcp_transport_http) orelse
        code:ensure_loaded(beam_agent_mcp_transport_http) =:=
            {module, beam_agent_mcp_transport_http}).

%%====================================================================
%% start/1
%%====================================================================

start_creates_proper_ref_test() ->
    test_mcp_gun:setup(),
    try
        {ok, Ref} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096,
            path       => <<"/mcp">>
        }),
        ?assertMatch({_ConnPid, _MonRef, test_mcp_gun,
                      #{path := <<"/mcp">>,
                        session_id := undefined,
                        protocol_version := undefined}},
                     Ref)
    after
        test_mcp_gun:teardown()
    end.

start_defaults_path_to_mcp_test() ->
    test_mcp_gun:setup(),
    try
        {ok, {_, _, _, SessState}} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096
        }),
        ?assertEqual(<<"/mcp">>, maps:get(path, SessState))
    after
        test_mcp_gun:teardown()
    end.

%%====================================================================
%% classify_message/2 — connection events
%%====================================================================

classify_gun_up_returns_connected_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    ?assertEqual(connected,
        beam_agent_mcp_transport_http:classify_message(
            {gun_up, ConnPid, http}, Ref)).

classify_gun_down_returns_disconnected_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    ?assertEqual({disconnected, closed},
        beam_agent_mcp_transport_http:classify_message(
            {gun_down, ConnPid, http, closed, []}, Ref)).

classify_down_returns_exit_test() ->
    {ConnPid, MonRef, _, _} = Ref = make_ref_self(),
    ?assertEqual({exit, 1},
        beam_agent_mcp_transport_http:classify_message(
            {'DOWN', MonRef, process, ConnPid, killed}, Ref)).

%%====================================================================
%% classify_message/2 — HTTP messages return ignore
%%====================================================================

classify_gun_response_returns_ignore_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    StreamRef = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {gun_response, ConnPid, StreamRef, nofin, 200,
             [{<<"content-type">>, <<"application/json">>}]}, Ref)).

classify_gun_data_returns_ignore_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    StreamRef = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {gun_data, ConnPid, StreamRef, fin,
             <<"{\"jsonrpc\":\"2.0\"}">>}, Ref)).

classify_gun_response_202_returns_ignore_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    StreamRef = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {gun_response, ConnPid, StreamRef, fin, 202, []}, Ref)).

classify_gun_response_404_returns_ignore_test() ->
    {ConnPid, _, _, _} = Ref = make_ref_self(),
    StreamRef = make_ref(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {gun_response, ConnPid, StreamRef, nofin, 404, []}, Ref)).

%%====================================================================
%% classify_message/2 — unknown messages
%%====================================================================

classify_unknown_message_returns_ignore_test() ->
    Ref = make_ref_self(),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {some, random, message}, Ref)).

classify_wrong_conn_pid_returns_ignore_test() ->
    {_ConnPid, _, _, _} = Ref = make_ref_self(),
    OtherPid  = spawn(fun() -> ok end),
    ?assertEqual(ignore,
        beam_agent_mcp_transport_http:classify_message(
            {gun_up, OtherPid, http}, Ref)).

%%====================================================================
%% send/2 — header construction and routing
%%====================================================================

send_posts_to_mcp_endpoint_test() ->
    test_mcp_gun:setup(),
    try
        {ok, Ref} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096,
            path       => <<"/mcp">>
        }),
        Msg = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                <<"method">> => <<"initialize">>},
        ok = beam_agent_mcp_transport_http:send(Ref, Msg),
        receive
            {gun_request, post, <<"/mcp">>, _Headers, _Body, _StreamRef} ->
                ok
        after 200 ->
            error(no_post_received)
        end
    after
        test_mcp_gun:teardown()
    end.

send_includes_content_type_header_test() ->
    test_mcp_gun:setup(),
    try
        {ok, Ref} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096,
            path       => <<"/mcp">>
        }),
        ok = beam_agent_mcp_transport_http:send(Ref, #{<<"method">> => <<"ping">>}),
        receive
            {gun_request, post, _, Headers, _, _} ->
                ?assert(lists:member(
                    {<<"content-type">>, <<"application/json">>}, Headers))
        after 200 ->
            error(no_post_received)
        end
    after
        test_mcp_gun:teardown()
    end.

send_includes_session_id_when_set_test() ->
    test_mcp_gun:setup(),
    try
        {ok, {ConnPid, MonRef, GunMod, SessState}} =
            beam_agent_mcp_transport_http:start(#{
                gun_module => test_mcp_gun,
                host       => <<"localhost">>,
                port       => 4096,
                path       => <<"/mcp">>
            }),
        RefWithSid = {ConnPid, MonRef, GunMod,
                      SessState#{session_id => <<"sess-999">>}},
        ok = beam_agent_mcp_transport_http:send(RefWithSid,
                                                #{<<"method">> => <<"ping">>}),
        receive
            {gun_request, post, _, Headers, _, _} ->
                ?assert(lists:member(
                    {<<"mcp-session-id">>, <<"sess-999">>}, Headers))
        after 200 ->
            error(no_post_received)
        end
    after
        test_mcp_gun:teardown()
    end.

send_omits_session_id_when_unset_test() ->
    test_mcp_gun:setup(),
    try
        {ok, Ref} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096,
            path       => <<"/mcp">>
        }),
        ok = beam_agent_mcp_transport_http:send(Ref, #{<<"method">> => <<"ping">>}),
        receive
            {gun_request, post, _, Headers, _, _} ->
                ?assertNot(lists:keymember(<<"mcp-session-id">>, 1, Headers))
        after 200 ->
            error(no_post_received)
        end
    after
        test_mcp_gun:teardown()
    end.

send_includes_protocol_version_when_set_test() ->
    test_mcp_gun:setup(),
    try
        {ok, {ConnPid, MonRef, GunMod, SessState}} =
            beam_agent_mcp_transport_http:start(#{
                gun_module => test_mcp_gun,
                host       => <<"localhost">>,
                port       => 4096,
                path       => <<"/mcp">>
            }),
        RefWithVer = {ConnPid, MonRef, GunMod,
                      SessState#{protocol_version => <<"2025-06-18">>}},
        ok = beam_agent_mcp_transport_http:send(RefWithVer,
                                                #{<<"method">> => <<"ping">>}),
        receive
            {gun_request, post, _, Headers, _, _} ->
                ?assert(lists:member(
                    {<<"mcp-protocol-version">>, <<"2025-06-18">>}, Headers))
        after 200 ->
            error(no_post_received)
        end
    after
        test_mcp_gun:teardown()
    end.

%%====================================================================
%% close/1 — DELETE on active session
%%====================================================================

close_sends_delete_when_session_active_test() ->
    test_mcp_gun:setup(),
    try
        {ok, {ConnPid, MonRef, GunMod, SessState}} =
            beam_agent_mcp_transport_http:start(#{
                gun_module => test_mcp_gun,
                host       => <<"localhost">>,
                port       => 4096,
                path       => <<"/mcp">>
            }),
        RefWithSid = {ConnPid, MonRef, GunMod,
                      SessState#{session_id => <<"sess-del-me">>}},
        ok = beam_agent_mcp_transport_http:close(RefWithSid),
        receive
            {gun_request, delete, <<"/mcp">>, Headers, _StreamRef} ->
                ?assert(lists:member(
                    {<<"mcp-session-id">>, <<"sess-del-me">>}, Headers))
        after 200 ->
            error(no_delete_sent)
        end
    after
        test_mcp_gun:teardown()
    end.

is_ready_test() ->
    test_mcp_gun:setup(),
    {ok, Ref} = beam_agent_mcp_transport_http:start(#{
        gun_module => test_mcp_gun, host => <<"localhost">>,
        port => 4096, path => <<"/mcp">>}),
    ?assert(beam_agent_mcp_transport_http:is_ready(Ref)),
    beam_agent_mcp_transport_http:close(Ref),
    test_mcp_gun:teardown().

status_running_test() ->
    test_mcp_gun:setup(),
    {ok, Ref} = beam_agent_mcp_transport_http:start(#{
        gun_module => test_mcp_gun, host => <<"localhost">>,
        port => 4096, path => <<"/mcp">>}),
    ?assertEqual(running, beam_agent_mcp_transport_http:status(Ref)),
    beam_agent_mcp_transport_http:close(Ref),
    test_mcp_gun:teardown().

close_skips_delete_when_no_session_test() ->
    test_mcp_gun:setup(),
    try
        {ok, Ref} = beam_agent_mcp_transport_http:start(#{
            gun_module => test_mcp_gun,
            host       => <<"localhost">>,
            port       => 4096,
            path       => <<"/mcp">>
        }),
        ok = beam_agent_mcp_transport_http:close(Ref),
        receive
            {gun_request, delete, _, _, _} ->
                error(unexpected_delete_sent)
        after 100 ->
            ok  %% Expected: no DELETE
        end
    after
        test_mcp_gun:teardown()
    end.
