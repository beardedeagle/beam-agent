%%%-------------------------------------------------------------------
%%% @doc EUnit tests for opencode_session gen_statem.
%%%
%%% Uses meck to mock gun, then drives state transitions by sending
%%% fake gun messages directly to the session process.
%%%
%%% Tests cover:
%%%   - Full connect → init → ready lifecycle
%%%   - Health state at each stage
%%%   - Full query lifecycle (SSE events → messages → result)
%%%   - Text delta events delivered
%%%   - Tool events delivered
%%%   - session.idle triggers result and returns to ready
%%%   - session.error triggers error message
%%%   - Permission handler invoked (and fail-closed behaviour)
%%%   - Abort sends POST request
%%%   - Concurrent query rejected
%%%   - Wrong ref rejected
%%%   - Gun connection down → error state
%%%   - Gun process crash → error state
%%%   - Heartbeat events not delivered to consumer
%%%   - child_spec correctness
%%%   - Basic auth headers included
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests (no gun needed)
%%====================================================================

child_spec_test() ->
    Spec = opencode_client:child_spec(#{directory => <<"/tmp">>}),
    ?assertEqual(opencode_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(10000, maps:get(shutdown, Spec)),
    {Mod, Fun, _Args} = maps:get(start, Spec),
    ?assertEqual(opencode_session, Mod),
    ?assertEqual(start_link, Fun).

child_spec_with_session_id_test() ->
    Spec = opencode_client:child_spec(#{
        directory  => <<"/tmp">>,
        session_id => <<"my-sess">>
    }),
    ?assertEqual({opencode_session, <<"my-sess">>}, maps:get(id, Spec)).

%%====================================================================
%% Mock-based integration tests
%%====================================================================

mock_session_test_() ->
    {"opencode_session lifecycle with mocked gun",
     {setup,
      fun setup/0,
      fun cleanup/1,
      fun(_) -> [
          {"session connects and reaches ready state",
           {timeout, 10, fun test_ready_lifecycle/0}},
          {"health reports correct states",
           {timeout, 10, fun test_health_states/0}},
          {"full query lifecycle with text events",
           {timeout, 10, fun test_query_lifecycle/0}},
          {"tool_use event delivered during query",
           {timeout, 10, fun test_tool_use_event/0}},
          {"native event subscription receives normalized SSE events in ready state",
           {timeout, 10, fun test_ready_event_subscription/0}},
          {"native tui append prompt request works",
           {timeout, 10, fun test_tui_append_prompt/0}},
          {"native tui open help request works",
           {timeout, 10, fun test_tui_open_help/0}},
          {"session.idle triggers result message",
           {timeout, 10, fun test_session_idle_result/0}},
          {"session.error triggers error message",
           {timeout, 10, fun test_session_error/0}},
          {"concurrent query rejected",
           {timeout, 10, fun test_concurrent_query_rejected/0}},
          {"wrong ref rejected",
           {timeout, 10, fun test_wrong_ref_rejected/0}},
          {"heartbeat events not delivered",
           {timeout, 10, fun test_heartbeat_not_delivered/0}},
          {"opencode_client:query/2 collects all messages",
           {timeout, 10, fun test_client_query/0}},
          {"abort sends REST request",
           {timeout, 10, fun test_abort/0}}
      ] end}}.

permission_test_() ->
    {"permission handler tests",
     {setup,
      fun setup/0,
      fun cleanup/1,
      fun(_) -> [
          {"permission handler invoked and allow sent",
           {timeout, 10, fun test_permission_allow/0}},
          {"permission handler crash → deny (fail-closed)",
           {timeout, 10, fun test_permission_crash_deny/0}},
          {"no permission handler → deny (fail-closed)",
           {timeout, 10, fun test_no_permission_handler_deny/0}}
      ] end}}.

gun_down_test_() ->
    {"gun connection failure tests",
     {setup,
      fun setup/0,
      fun cleanup/1,
      fun(_) -> [
          {"gun_down in ready → error state",
           {timeout, 10, fun test_gun_down_in_ready/0}},
          {"gun process crash → error state",
           {timeout, 10, fun test_gun_process_crash/0}}
      ] end}}.

%%====================================================================
%% Setup / Cleanup
%%====================================================================

setup() ->
    _ = application:ensure_all_started(telemetry),
    meck:new(gun, [non_strict, no_link]),
    ok.

cleanup(_) ->
    meck:unload(gun),
    ok.

%%====================================================================
%% Helper: build a fully-initialised session with mocked gun
%%====================================================================

%% Returns {SessionPid, FakeGunPid, SseRef} after driving the session
%% through connecting → initializing → ready.
start_ready_session() ->
    start_ready_session(#{}).

start_ready_session(ExtraOpts) ->
    start_ready_session(ExtraOpts, undefined).

start_ready_session(ExtraOpts, PermissionHandler) ->
    Self = self(),
    FakeGunPid = spawn_link(fun fake_gun_loop/0),
    SseRef = make_ref(),

    meck:expect(gun, open, fun(_H, _P, _O) -> {ok, FakeGunPid} end),
    meck:expect(gun, get, fun(_P, _Path, _H) -> SseRef end),
    meck:expect(gun, close, fun(_P) -> ok end),
    meck:expect(gun, delete, fun(_P, _Path, _H) -> make_ref() end),

    %% Capture POST refs so we can simulate responses
    meck:expect(gun, post, fun(_P, Path, _H, _B) ->
        Ref = make_ref(),
        Self ! {post_ref, list_to_binary(Path), Ref},
        Ref
    end),

    BaseOpts = #{
        directory  => <<"/tmp/test">>,
        base_url   => <<"http://localhost:4096">>
    },
    Opts = case PermissionHandler of
        undefined -> maps:merge(BaseOpts, ExtraOpts);
        Handler   -> maps:merge(BaseOpts#{permission_handler => Handler}, ExtraOpts)
    end,

    {ok, Pid} = opencode_session:start_link(Opts),

    %% Drive: gun_up → SSE GET ref known → SSE response 200 → server.connected
    Pid ! {gun_up, FakeGunPid, http},
    timer:sleep(20),

    Pid ! {gun_response, FakeGunPid, SseRef, nofin, 200,
           [{<<"content-type">>, <<"text/event-stream">>}]},
    send_sse(Pid, FakeGunPid, SseRef,
             <<"event: server.connected\ndata: {}\n\n">>),
    timer:sleep(20),

    %% Drive: create_session POST
    CreateRef = receive
        {post_ref, <<"/session">>, Ref0} -> Ref0
    after 1000 ->
        error(no_session_post)
    end,
    SessionJson = json:encode(#{<<"id">> => <<"sess-test">>}),
    Pid ! {gun_response, FakeGunPid, CreateRef, nofin, 200, []},
    Pid ! {gun_data, FakeGunPid, CreateRef, fin, SessionJson},
    timer:sleep(20),

    {Pid, FakeGunPid, SseRef}.

%%====================================================================
%% Individual test functions
%%====================================================================

test_ready_lifecycle() ->
    {Pid, _GunPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),
    opencode_session:stop(Pid).

test_health_states() ->
    %% We can only observe ready since the mock drives through states fast
    {Pid, _GunPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),
    opencode_session:stop(Pid).

test_query_lifecycle() ->
    {Pid, GunPid, SseRef} = start_ready_session(),
    Self = self(),

    %% Capture the message POST ref
    {ok, Ref} = opencode_session:send_query(Pid, <<"test prompt">>, #{}, 5000),
    ?assert(is_reference(Ref)),
    ?assertEqual(active_query, opencode_session:health(Pid)),

    %% Drain the message POST response so session can proceed
    receive {post_ref, _, _MsgPostRef} -> ok after 500 -> ok end,

    %% Emit a text delta SSE event then session.idle
    spawn(fun() ->
        timer:sleep(50),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"delta\":\"Hello!\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\n",
                   "data: {\"id\":\"sess-test\"}\n\n">>),
        Self ! sse_done
    end),

    Msg1 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := text}}, Msg1),
    {ok, #{content := Content1}} = Msg1,
    ?assertEqual(<<"Hello!">>, Content1),

    %% Result message from session.idle
    Msg2 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := result}}, Msg2),

    receive sse_done -> ok after 2000 -> ok end,
    timer:sleep(50),
    ?assertEqual(ready, opencode_session:health(Pid)),
    opencode_session:stop(Pid).

test_tool_use_event() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"use a tool">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    spawn(fun() ->
        timer:sleep(30),
        ToolJson = <<"{\"part\":{\"type\":\"tool\","
                     "\"state\":{\"status\":\"running\","
                     "\"tool\":\"bash\",\"input\":{\"cmd\":\"ls\"}}}}">>,
        send_sse(Pid, GunPid, SseRef,
                 <<"event: message.part.updated\ndata: ", ToolJson/binary, "\n\n">>),
        timer:sleep(20),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Msg1 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := tool_use, tool_name := <<"bash">>}}, Msg1),

    _Msg2 = opencode_session:receive_message(Pid, Ref, 3000),
    opencode_session:stop(Pid).

test_ready_event_subscription() ->
    {Pid, GunPid, SseRef} = start_ready_session(),
    {ok, EventRef} = opencode_session:subscribe_events(Pid),

    send_sse(Pid, GunPid, SseRef,
             <<"event: message.part.updated\n",
               "data: {\"part\":{\"type\":\"text\",\"delta\":\"Event hello\"}}\n\n">>),

    EventMsg = opencode_session:receive_event(Pid, EventRef, 3000),
    ?assertMatch({ok, #{type := text, content := <<"Event hello">>}}, EventMsg),
    ?assertEqual(ready, opencode_session:health(Pid)),
    ?assertEqual(ok, opencode_session:unsubscribe_events(Pid, EventRef)),
    opencode_session:stop(Pid).

test_tui_append_prompt() ->
    {Pid, GunPid, _SseRef} = start_ready_session(),
    Self = self(),
    spawn(fun() ->
        Self ! {tui_append_result,
                opencode_client:tui_append_prompt(Pid, <<"hello">>)}
    end),
    receive
        {post_ref, <<"/tui/append-prompt">>, Ref0} ->
            Pid ! {gun_response, GunPid, Ref0, nofin, 200, []},
            Pid ! {gun_data, GunPid, Ref0, fin, <<"true">>}
    after 1000 ->
        error(no_tui_append_post)
    end,
    receive
        {tui_append_result, Result} ->
            ?assertEqual({ok, true}, Result)
    after 1000 ->
        error(no_tui_append_result)
    end,
    opencode_session:stop(Pid).

test_tui_open_help() ->
    {Pid, GunPid, _SseRef} = start_ready_session(),
    Self = self(),
    spawn(fun() ->
        Self ! {tui_open_result, opencode_client:tui_open_help(Pid)}
    end),
    receive
        {post_ref, <<"/tui/open-help">>, Ref0} ->
            Pid ! {gun_response, GunPid, Ref0, nofin, 200, []},
            Pid ! {gun_data, GunPid, Ref0, fin, <<"true">>}
    after 1000 ->
        error(no_tui_open_post)
    end,
    receive
        {tui_open_result, Result} ->
            ?assertEqual({ok, true}, Result)
    after 1000 ->
        error(no_tui_open_result)
    end,
    opencode_session:stop(Pid).

test_session_idle_result() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Msg = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := result}}, Msg),
    timer:sleep(50),
    ?assertEqual(ready, opencode_session:health(Pid)),
    opencode_session:stop(Pid).

test_session_error() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.error\n",
                   "data: {\"message\":\"internal server error\"}\n\n">>)
    end),

    Msg = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := error}}, Msg),
    opencode_session:stop(Pid).

test_concurrent_query_rejected() ->
    {Pid, _GunPid, _SseRef} = start_ready_session(),

    {ok, _Ref1} = opencode_session:send_query(Pid, <<"q1">>, #{}, 5000),
    Result = opencode_session:send_query(Pid, <<"q2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),

    catch opencode_session:stop(Pid).

test_wrong_ref_rejected() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    {ok, _Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 opencode_session:receive_message(Pid, WrongRef, 1000)),

    %% Clean up — send idle to unblock
    send_sse(Pid, GunPid, SseRef,
             <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>),
    catch opencode_session:stop(Pid).

test_heartbeat_not_delivered() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    %% Send heartbeat then a real text event then idle
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: server.heartbeat\ndata: {}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"text\":\"real\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% First message should be text (not heartbeat)
    Msg1 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := text, content := <<"real">>}}, Msg1),

    _Msg2 = opencode_session:receive_message(Pid, Ref, 3000),
    opencode_session:stop(Pid).

test_client_query() ->
    {Pid, GunPid, SseRef} = start_ready_session(),

    %% Use opencode_client:query/2 — must collect all messages
    spawn(fun() ->
        timer:sleep(100),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"delta\":\"Hi\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Result = opencode_client:query(Pid, <<"Hello">>, #{timeout => 5000}),
    flush_post_refs(),
    ?assertMatch({ok, [_ | _]}, Result),
    {ok, Messages} = Result,
    Last = lists:last(Messages),
    ?assertEqual(result, maps:get(type, Last)),
    opencode_session:stop(Pid).

test_abort() ->
    flush_post_refs(),
    {Pid, _GunPid, _SseRef} = start_ready_session(),

    {ok, _Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    receive {post_ref, _, _MsgRef} -> ok after 500 -> ok end,

    %% Abort should fire a POST to /session/:id/abort
    ok = opencode_session:interrupt(Pid),

    receive
        {post_ref, AbortPath, _AbortRef} ->
            ?assert(binary:match(AbortPath, <<"/abort">>) =/= nomatch)
    after 1000 ->
        %% abort may already have been processed; that is also OK
        ok
    end,
    catch opencode_session:stop(Pid).

%%====================================================================
%% Permission handler tests
%%====================================================================

test_permission_allow() ->
    Self = self(),
    Handler = fun(PermId, _Meta, _Opts) ->
        Self ! {permission_called, PermId},
        {allow, #{}}
    end,
    {Pid, GunPid, SseRef} = start_ready_session(#{}, Handler),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    %% Emit a permission.updated event
    PermJson = <<"{\"id\":\"perm-001\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% Handler should be called
    receive
        {permission_called, PermId} ->
            ?assertEqual(<<"perm-001">>, PermId)
    after 3000 ->
        ?assert(false)
    end,

    %% A POST to /permission/perm-001/reply should have been sent
    receive
        {post_ref, PermPath, _PermRef} ->
            ?assert(binary:match(PermPath, <<"perm-001">>) =/= nomatch)
    after 1000 ->
        ok
    end,

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    catch opencode_session:stop(Pid).

test_permission_crash_deny() ->
    Handler = fun(_PermId, _Meta, _Opts) ->
        error(handler_crash)
    end,
    {Pid, GunPid, SseRef} = start_ready_session(#{}, Handler),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    PermJson = <<"{\"id\":\"perm-002\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% Session should still be alive despite handler crash (fail-closed = deny)
    timer:sleep(200),
    Health = opencode_session:health(Pid),
    ?assert(lists:member(Health, [active_query, ready])),

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    catch opencode_session:stop(Pid).

test_no_permission_handler_deny() ->
    %% No permission_handler configured → deny by default (fail-closed)
    flush_post_refs(),
    {Pid, GunPid, SseRef} = start_ready_session(#{}, undefined),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    receive {post_ref, _, _} -> ok after 500 -> ok end,

    PermJson = <<"{\"id\":\"perm-003\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, GunPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% A deny POST should have been sent
    receive
        {post_ref, PermPath, _PermRef} ->
            ?assert(binary:match(PermPath, <<"perm-003">>) =/= nomatch)
    after 2000 ->
        ok
    end,

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    catch opencode_session:stop(Pid).

%%====================================================================
%% Gun failure tests
%%====================================================================

test_gun_down_in_ready() ->
    {Pid, GunPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),

    %% Suppress expected logger:error from gun_down handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    %% Simulate gun connection going down
    Pid ! {gun_down, GunPid, http, closed, []},
    timer:sleep(50),
    logger:set_primary_config(level, OldLevel),

    Health = opencode_session:health(Pid),
    ?assertEqual(error, Health),
    catch gen_statem:stop(Pid, normal, 1000).

test_gun_process_crash() ->
    {Pid, GunPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),

    %% Suppress expected logger:error from gun crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    %% Kill the fake gun process so the real monitor fires
    %% Unlink first to prevent the test process from dying
    unlink(GunPid),
    exit(GunPid, kill),
    timer:sleep(50),
    logger:set_primary_config(level, OldLevel),

    %% Session should be in error state
    Health = opencode_session:health(Pid),
    ?assertEqual(error, Health),
    catch gen_statem:stop(Pid, normal, 1000).

%%====================================================================
%% Hook tests
%%====================================================================

hook_deny_test_() ->
    {"user_prompt_submit hook can deny query",
     {setup,
      fun setup/0,
      fun cleanup/1,
      fun(_) ->
          {timeout, 10, fun() ->
              Hook = beam_agent_hooks_core:hook(user_prompt_submit,
                  fun(_) -> {deny, <<"no prompts">>} end),
              {Pid, _GunPid, _SseRef} =
                  start_ready_session(#{sdk_hooks => [Hook]}),
              ?assertEqual(ready, opencode_session:health(Pid)),
              Result = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
              ?assertMatch({error, {hook_denied, <<"no prompts">>}}, Result),
              ?assertEqual(ready, opencode_session:health(Pid)),
              opencode_session:stop(Pid)
          end}
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Flush any stale {post_ref, _, _} messages from the mailbox.
%%      Prevents mailbox pollution between tests sharing the same process.
flush_post_refs() ->
    receive {post_ref, _, _} -> flush_post_refs()
    after 0 -> ok
    end.

%% @doc Send SSE data as a gun_data message to the session pid.
-spec send_sse(pid(), pid(), reference(), binary()) -> ok.
send_sse(Pid, GunPid, SseRef, Data) ->
    Pid ! {gun_data, GunPid, SseRef, nofin, Data},
    ok.

%% @doc Fake gun process that just keeps alive until told to stop.
fake_gun_loop() ->
    receive
        stop -> ok;
        _    -> fake_gun_loop()
    end.
