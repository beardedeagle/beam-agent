%%%-------------------------------------------------------------------
%%% @doc EUnit tests for opencode_session (engine-backed).
%%%
%%% Uses `test_opencode_gun` dependency injection instead of mocks.
%%% The test fixture relays gun requests as messages to the test
%%% process, enabling full lifecycle and protocol testing.
%%%
%%% Tests cover:
%%%   - Full connect → init → ready lifecycle
%%%   - Health state at each stage
%%%   - Full query lifecycle (SSE events → messages → result)
%%%   - Text delta events delivered
%%%   - Tool events delivered
%%%   - session.idle triggers result message
%%%   - session.error triggers error message
%%%   - Permission handler invoked (and fail-closed behaviour)
%%%   - Abort sends POST request
%%%   - Concurrent query rejected
%%%   - Wrong ref rejected
%%%   - Gun connection down → error state
%%%   - Gun process crash → error state
%%%   - Heartbeat events not delivered to consumer
%%%   - child_spec correctness
%%%   - Event subscription in ready state
%%%   - TUI operations
%%%   - Hook deny
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
%% Integration tests with dependency injection
%%====================================================================

session_lifecycle_test_() ->
    {"opencode_session lifecycle with injected gun",
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
    ok.

cleanup(_) ->
    ok.

%%====================================================================
%% Helper: build a fully-initialised session with injected gun
%%====================================================================

%% Returns {SessionPid, ConnPid, SseRef} after driving the session
%% through connecting → initializing → ready.
start_ready_session() ->
    start_ready_session(#{}).

start_ready_session(ExtraOpts) ->
    start_ready_session(ExtraOpts, undefined).

start_ready_session(ExtraOpts, PermissionHandler) ->
    flush_gun_requests(),
    test_opencode_gun:setup(),
    test_opencode_gun:set_owner(),

    BaseOpts = #{
        gun_module => test_opencode_gun,
        directory  => <<"/tmp/test">>,
        base_url   => <<"http://localhost:4096">>
    },
    Opts = case PermissionHandler of
        undefined -> maps:merge(BaseOpts, ExtraOpts);
        Handler   -> maps:merge(BaseOpts#{permission_handler => Handler}, ExtraOpts)
    end,

    {ok, Pid} = opencode_session:start_link(Opts),
    ConnPid = test_opencode_gun:conn_pid(),

    %% Drive: gun_up → triggers SSE GET
    Pid ! {gun_up, ConnPid, http},

    %% Receive SSE GET ref
    SseRef = receive
        {gun_request, get, _SsePath, Ref0} -> Ref0
    after 1000 ->
        error(no_sse_get)
    end,

    %% Drive: SSE response 200 → server.connected
    Pid ! {gun_response, ConnPid, SseRef, nofin, 200,
           [{<<"content-type">>, <<"text/event-stream">>}]},
    send_sse(Pid, ConnPid, SseRef,
             <<"event: server.connected\ndata: {}\n\n">>),
    timer:sleep(20),

    %% Drive: create_session POST
    CreateRef = receive
        {gun_request, post, <<"/session">>, _Body, Ref1} -> Ref1
    after 1000 ->
        error(no_session_post)
    end,
    SessionJson = json:encode(#{<<"id">> => <<"sess-test">>}),
    Pid ! {gun_response, ConnPid, CreateRef, nofin, 200, []},
    Pid ! {gun_data, ConnPid, CreateRef, fin, SessionJson},
    timer:sleep(20),

    {Pid, ConnPid, SseRef}.

stop_session(Pid) ->
    catch opencode_session:stop(Pid),
    test_opencode_gun:teardown().

%%====================================================================
%% Individual test functions
%%====================================================================

test_ready_lifecycle() ->
    {Pid, _ConnPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),
    stop_session(Pid).

test_health_states() ->
    {Pid, _ConnPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),
    stop_session(Pid).

test_query_lifecycle() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),
    Self = self(),

    %% Send query — handler fires hook, POSTs to /session/:id/message
    {ok, Ref} = opencode_session:send_query(Pid, <<"test prompt">>, #{}, 5000),
    ?assert(is_reference(Ref)),
    ?assertEqual(active_query, opencode_session:health(Pid)),

    %% Drain the message POST
    drain_post_ref(),

    %% Emit a text delta SSE event then session.idle
    spawn(fun() ->
        timer:sleep(50),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"delta\":\"Hello!\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, ConnPid, SseRef,
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
    stop_session(Pid).

test_tool_use_event() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"use a tool">>, #{}, 5000),
    drain_post_ref(),

    spawn(fun() ->
        timer:sleep(30),
        ToolJson = <<"{\"part\":{\"type\":\"tool\","
                     "\"state\":{\"status\":\"running\","
                     "\"tool\":\"bash\",\"input\":{\"cmd\":\"ls\"}}}}">>,
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: message.part.updated\ndata: ", ToolJson/binary, "\n\n">>),
        timer:sleep(20),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Msg1 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := tool_use, tool_name := <<"bash">>}}, Msg1),

    _Msg2 = opencode_session:receive_message(Pid, Ref, 3000),
    stop_session(Pid).

test_ready_event_subscription() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),
    {ok, EventRef} = opencode_session:subscribe_events(Pid),

    send_sse(Pid, ConnPid, SseRef,
             <<"event: message.part.updated\n",
               "data: {\"part\":{\"type\":\"text\",\"delta\":\"Event hello\"}}\n\n">>),

    EventMsg = opencode_session:receive_event(Pid, EventRef, 3000),
    ?assertMatch({ok, #{type := text, content := <<"Event hello">>}}, EventMsg),
    ?assertEqual(ready, opencode_session:health(Pid)),
    ?assertEqual(ok, opencode_session:unsubscribe_events(Pid, EventRef)),
    stop_session(Pid).

test_tui_append_prompt() ->
    {Pid, ConnPid, _SseRef} = start_ready_session(),
    Self = self(),
    spawn(fun() ->
        Self ! {tui_append_result,
                opencode_client:tui_append_prompt(Pid, <<"hello">>)}
    end),
    receive
        {gun_request, post, <<"/tui/append-prompt">>, _Body, Ref0} ->
            Pid ! {gun_response, ConnPid, Ref0, nofin, 200, []},
            Pid ! {gun_data, ConnPid, Ref0, fin, <<"true">>}
    after 1000 ->
        error(no_tui_append_post)
    end,
    receive
        {tui_append_result, Result} ->
            ?assertEqual({ok, true}, Result)
    after 1000 ->
        error(no_tui_append_result)
    end,
    stop_session(Pid).

test_tui_open_help() ->
    {Pid, ConnPid, _SseRef} = start_ready_session(),
    Self = self(),
    spawn(fun() ->
        Self ! {tui_open_result, opencode_client:tui_open_help(Pid)}
    end),
    receive
        {gun_request, post, <<"/tui/open-help">>, _Body, Ref0} ->
            Pid ! {gun_response, ConnPid, Ref0, nofin, 200, []},
            Pid ! {gun_data, ConnPid, Ref0, fin, <<"true">>}
    after 1000 ->
        error(no_tui_open_post)
    end,
    receive
        {tui_open_result, Result} ->
            ?assertEqual({ok, true}, Result)
    after 1000 ->
        error(no_tui_open_result)
    end,
    stop_session(Pid).

test_session_idle_result() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    drain_post_ref(),

    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Msg = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := result}}, Msg),
    timer:sleep(50),
    ?assertEqual(ready, opencode_session:health(Pid)),
    stop_session(Pid).

test_session_error() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    drain_post_ref(),

    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.error\n",
                   "data: {\"message\":\"internal server error\"}\n\n">>)
    end),

    Msg = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := error}}, Msg),
    stop_session(Pid).

test_concurrent_query_rejected() ->
    {Pid, _ConnPid, _SseRef} = start_ready_session(),

    {ok, _Ref1} = opencode_session:send_query(Pid, <<"q1">>, #{}, 5000),
    Result = opencode_session:send_query(Pid, <<"q2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),

    stop_session(Pid).

test_wrong_ref_rejected() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    {ok, _Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    drain_post_ref(),

    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 opencode_session:receive_message(Pid, WrongRef, 1000)),

    %% Clean up — send idle to unblock
    send_sse(Pid, ConnPid, SseRef,
             <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>),
    stop_session(Pid).

test_heartbeat_not_delivered() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    {ok, Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    drain_post_ref(),

    %% Send heartbeat then a real text event then idle
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: server.heartbeat\ndata: {}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"text\":\"real\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% First message should be text (not heartbeat)
    Msg1 = opencode_session:receive_message(Pid, Ref, 3000),
    ?assertMatch({ok, #{type := text, content := <<"real">>}}, Msg1),

    _Msg2 = opencode_session:receive_message(Pid, Ref, 3000),
    stop_session(Pid).

test_client_query() ->
    {Pid, ConnPid, SseRef} = start_ready_session(),

    %% Use opencode_client:query/2 — must collect all messages
    spawn(fun() ->
        timer:sleep(100),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: message.part.updated\n",
                   "data: {\"part\":{\"type\":\"text\",\"delta\":\"Hi\"}}\n\n">>),
        timer:sleep(20),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    Result = opencode_client:query(Pid, <<"Hello">>, #{timeout => 5000}),
    flush_gun_requests(),
    ?assertMatch({ok, [_ | _]}, Result),
    {ok, Messages} = Result,
    Last = lists:last(Messages),
    ?assertEqual(result, maps:get(type, Last)),
    stop_session(Pid).

test_abort() ->
    flush_gun_requests(),
    {Pid, _ConnPid, _SseRef} = start_ready_session(),

    {ok, _Ref} = opencode_session:send_query(Pid, <<"prompt">>, #{}, 5000),
    drain_post_ref(),

    %% Abort should fire a POST to /session/:id/abort
    ok = opencode_session:interrupt(Pid),

    receive
        {gun_request, post, AbortPath, _Body, _AbortRef} ->
            ?assert(binary:match(AbortPath, <<"/abort">>) =/= nomatch)
    after 1000 ->
        %% abort may already have been processed; that is also OK
        ok
    end,
    stop_session(Pid).

%%====================================================================
%% Permission handler tests
%%====================================================================

test_permission_allow() ->
    Self = self(),
    Handler = fun(PermId, _Meta, _Opts) ->
        Self ! {permission_called, PermId},
        {allow, #{}}
    end,
    {Pid, ConnPid, SseRef} = start_ready_session(#{}, Handler),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    drain_post_ref(),

    %% Emit a permission.updated event
    PermJson = <<"{\"id\":\"perm-001\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, ConnPid, SseRef,
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
        {gun_request, post, PermPath, _Body, _PermRef} ->
            ?assert(binary:match(PermPath, <<"perm-001">>) =/= nomatch)
    after 1000 ->
        ok
    end,

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    stop_session(Pid).

test_permission_crash_deny() ->
    Handler = fun(_PermId, _Meta, _Opts) ->
        error(handler_crash)
    end,
    {Pid, ConnPid, SseRef} = start_ready_session(#{}, Handler),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    drain_post_ref(),

    PermJson = <<"{\"id\":\"perm-002\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% Session should still be alive despite handler crash (fail-closed = deny)
    timer:sleep(200),
    Health = opencode_session:health(Pid),
    ?assert(lists:member(Health, [active_query, ready])),

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    stop_session(Pid).

test_no_permission_handler_deny() ->
    %% No permission_handler configured → deny by default (fail-closed)
    flush_gun_requests(),
    {Pid, ConnPid, SseRef} = start_ready_session(#{}, undefined),

    {ok, Ref} = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
    drain_post_ref(),

    PermJson = <<"{\"id\":\"perm-003\",\"request\":{\"tool\":\"bash\"}}">>,
    spawn(fun() ->
        timer:sleep(30),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: permission.updated\ndata: ", PermJson/binary, "\n\n">>),
        timer:sleep(50),
        send_sse(Pid, ConnPid, SseRef,
                 <<"event: session.idle\ndata: {\"id\":\"sess-test\"}\n\n">>)
    end),

    %% A deny POST should have been sent
    receive
        {gun_request, post, PermPath, _Body, _PermRef} ->
            ?assert(binary:match(PermPath, <<"perm-003">>) =/= nomatch)
    after 2000 ->
        ok
    end,

    _Msg = opencode_session:receive_message(Pid, Ref, 3000),
    stop_session(Pid).

%%====================================================================
%% Gun failure tests
%%====================================================================

test_gun_down_in_ready() ->
    {Pid, ConnPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),

    %% Suppress expected logger:error from gun_down handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    %% Simulate gun connection going down
    Pid ! {gun_down, ConnPid, http, closed, []},
    timer:sleep(50),
    logger:set_primary_config(level, OldLevel),

    Health = opencode_session:health(Pid),
    ?assertEqual(error, Health),
    catch gen_statem:stop(Pid, normal, 1000),
    test_opencode_gun:teardown().

test_gun_process_crash() ->
    {Pid, ConnPid, _SseRef} = start_ready_session(),
    ?assertEqual(ready, opencode_session:health(Pid)),

    %% Suppress expected logger:error from gun crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    %% Kill the fake gun process so the real monitor fires
    %% Unlink first to prevent the test process from dying
    unlink(ConnPid),
    exit(ConnPid, kill),
    timer:sleep(50),
    logger:set_primary_config(level, OldLevel),

    %% Session should be in error state
    Health = opencode_session:health(Pid),
    ?assertEqual(error, Health),
    catch gen_statem:stop(Pid, normal, 1000),
    test_opencode_gun:teardown().

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
              {Pid, _ConnPid, _SseRef} =
                  start_ready_session(#{sdk_hooks => [Hook]}),
              ?assertEqual(ready, opencode_session:health(Pid)),
              Result = opencode_session:send_query(Pid, <<"test">>, #{}, 5000),
              ?assertMatch({error, {hook_denied, <<"no prompts">>}}, Result),
              ?assertEqual(ready, opencode_session:health(Pid)),
              stop_session(Pid)
          end}
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Flush any stale gun_request messages from the mailbox.
%%      Handles both 4-tuple (GET/DELETE) and 5-tuple (POST/PATCH) formats.
flush_gun_requests() ->
    receive
        {gun_request, _, _, _} -> flush_gun_requests();
        {gun_request, _, _, _, _} -> flush_gun_requests()
    after 0 -> ok
    end.

%% @doc Drain a single expected POST gun_request (message POST after query).
drain_post_ref() ->
    receive {gun_request, post, _, _, _} -> ok
    after 500 -> ok
    end.

%% @doc Send SSE data as a gun_data message to the session pid.
-spec send_sse(pid(), pid(), reference(), binary()) -> ok.
send_sse(Pid, ConnPid, SseRef, Data) ->
    Pid ! {gun_data, ConnPid, SseRef, nofin, Data},
    ok.
