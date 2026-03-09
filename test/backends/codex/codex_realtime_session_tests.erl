-module(codex_realtime_session_tests).

-include_lib("eunit/include/eunit.hrl").

realtime_thread_lifecycle_and_query_test() ->
    Ctx = setup_gun(),
    try
        run_realtime_thread_lifecycle_and_query(Ctx)
    after
        cleanup_gun(Ctx)
    end.

setup_gun() ->
    Parent = self(),
    GunPid = spawn(fun gun_loop/0),
    WsRef = make_ref(),
    meck:new(gun, [non_strict]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, GunPid} end),
    meck:expect(gun, ws_upgrade, fun(_, _, _) -> WsRef end),
    meck:expect(gun, ws_send, fun(_ConnPid, _WsRef, Frame) ->
        Parent ! {ws_send, Frame},
        ok
    end),
    meck:expect(gun, close, fun(_ConnPid) -> ok end),
    #{gun_pid => GunPid, ws_ref => WsRef}.

cleanup_gun(#{gun_pid := GunPid}) ->
    exit(GunPid, kill),
    meck:unload(gun).

run_realtime_thread_lifecycle_and_query(#{gun_pid := GunPid, ws_ref := WsRef}) ->
    {ok, Session} = codex_app_server:start_session(#{
        transport => realtime,
        backend => codex,
        api_key => <<"test-key">>,
        realtime_url => <<"ws://example.test/v1/realtime?model=gpt-4o-realtime-preview">>
    }),
    ?assertEqual(connecting, codex_app_server:health(Session)),
    {ok, #{system_info := #{host := <<"example.test">>}}} =
        codex_app_server:session_info(Session),
    Session ! {gun_up, GunPid, http},
    Session ! {gun_upgrade, GunPid, WsRef, [<<"websocket">>], []},
    timer:sleep(10),
    ?assertEqual(ready, codex_app_server:health(Session)),
    {ok, ThreadInfo} = codex_app_server:thread_realtime_start(Session, #{
        mode => <<"voice">>,
        voice => <<"alloy">>
    }),
    ThreadId = maps:get(thread_id, ThreadInfo),
    ?assertMatch(#{thread_id := _, source := direct_realtime}, ThreadInfo),
    ?assert(received_ws_type(<<"session.update">>)),
    {ok, _} = codex_app_server:thread_realtime_append_text(Session, ThreadId, #{
        text => <<"hello realtime">>
    }),
    ?assert(received_ws_type(<<"conversation.item.create">>)),
    ?assert(received_ws_type(<<"response.create">>)),
    {ok, _} = codex_app_server:thread_realtime_append_audio(Session, ThreadId, #{
        audio => <<1, 2, 3>>,
        commit => true
    }),
    ?assert(received_ws_type(<<"input_audio_buffer.append">>)),
    ?assert(received_ws_type(<<"input_audio_buffer.commit">>)),
    {ok, Ref} = codex_realtime_session:send_query(Session, <<"Ping">>, #{}, 5000),
    Session ! ws_text(GunPid, WsRef, #{
        <<"type">> => <<"conversation.item.created">>,
        <<"item">> => #{
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"Pong">>}
            ]
        }
    }),
    ?assertMatch({ok, #{type := text, content := <<"Pong">>}},
        codex_realtime_session:receive_message(Session, Ref, 5000)),
    Session ! ws_text(GunPid, WsRef, #{
        <<"type">> => <<"response.done">>,
        <<"response">> => #{<<"status">> => <<"completed">>}
    }),
    ?assertMatch({ok, #{type := result, content := <<"Pong">>}},
        codex_realtime_session:receive_message(Session, Ref, 5000)),
    {ok, _} = codex_app_server:thread_realtime_stop(Session, ThreadId),
    ?assert(received_ws_type(<<"response.cancel">>)),
    ok = codex_realtime_session:stop(Session).

gun_loop() ->
    receive
        _ ->
            gun_loop()
    end.

ws_text(GunPid, WsRef, Json) ->
    {gun_ws, GunPid, WsRef, {text, iolist_to_binary(json:encode(Json))}}.

received_ws_type(Type) ->
    receive
        {ws_send, {text, JsonBin}} ->
            Json = json:decode(JsonBin),
            case maps:get(<<"type">>, Json, <<>>) of
                Type ->
                    true;
                _Other ->
                    received_ws_type(Type)
            end
    after 100 ->
        false
    end.
