%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_threads_core (universal thread management).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_table, clear)
%%%   - Thread creation (start_thread) with auto-generated and explicit IDs
%%%   - Thread resumption (resume_thread) including not_found
%%%   - Thread listing (list_threads) sorted by updated_at descending
%%%   - Thread retrieval (get_thread) found and not_found
%%%   - Thread deletion (delete_thread) including active thread clear
%%%   - Message recording (record_thread_message) with count and updated_at
%%%   - Thread message retrieval (get_thread_messages) found and not_found
%%%   - Thread count (thread_count)
%%%   - Active thread management (active_thread, set_active_thread,
%%%     clear_active_thread)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_threads_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_table_idempotent_test() ->
    ok = beam_agent_threads_core:ensure_table(),
    ok = beam_agent_threads_core:ensure_table(),
    ok = beam_agent_threads_core:ensure_table(),
    beam_agent_threads_core:clear().

clear_removes_all_data_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-clear">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId, #{}),
    {ok, [_]} = beam_agent_threads_core:list_threads(SessionId),
    ok = beam_agent_threads_core:clear(),
    {ok, []} = beam_agent_threads_core:list_threads(SessionId),
    beam_agent_threads_core:clear().

%%====================================================================
%% start_thread tests
%%====================================================================

start_thread_returns_thread_meta_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-start-1">>,
    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{}),
    ?assertEqual(SessionId, maps:get(session_id, Thread)),
    ?assert(is_binary(maps:get(thread_id, Thread))),
    ?assertEqual(0, maps:get(message_count, Thread)),
    ?assertEqual(active, maps:get(status, Thread)),
    ?assert(is_integer(maps:get(created_at, Thread))),
    ?assert(is_integer(maps:get(updated_at, Thread))),
    beam_agent_threads_core:clear().

start_thread_with_name_option_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-start-2">>,
    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId,
        #{name => <<"my-thread">>}),
    ?assertEqual(<<"my-thread">>, maps:get(name, Thread)),
    beam_agent_threads_core:clear().

start_thread_with_explicit_thread_id_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-start-3">>,
    ExplicitId = <<"explicit-thread-id">>,
    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ExplicitId}),
    ?assertEqual(ExplicitId, maps:get(thread_id, Thread)),
    beam_agent_threads_core:clear().

start_thread_auto_generated_id_has_prefix_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-start-4">>,
    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{}),
    ThreadId = maps:get(thread_id, Thread),
    ?assert(binary:match(ThreadId, <<"thread_">>) =/= nomatch),
    beam_agent_threads_core:clear().

start_thread_sets_active_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-start-5">>,
    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{}),
    ThreadId = maps:get(thread_id, Thread),
    ?assertEqual({ok, ThreadId}, beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

%%====================================================================
%% resume_thread tests
%%====================================================================

resume_thread_sets_active_and_status_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-resume-1">>,
    {ok, T1} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-resume-a">>}),
    {ok, _T2} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-resume-b">>}),
    %% t-resume-b is now active; resume t-resume-a
    {ok, Resumed} = beam_agent_threads_core:resume_thread(SessionId,
        maps:get(thread_id, T1)),
    ?assertEqual(active, maps:get(status, Resumed)),
    ?assertEqual({ok, <<"t-resume-a">>},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

resume_thread_not_found_test() ->
    beam_agent_threads_core:ensure_table(),
    Result = beam_agent_threads_core:resume_thread(<<"sess-resume-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    beam_agent_threads_core:clear().

resume_thread_updates_updated_at_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-resume-3">>,
    ThreadId = <<"t-resume-time">>,
    {ok, Original} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    timer:sleep(5),
    {ok, Resumed} = beam_agent_threads_core:resume_thread(SessionId, ThreadId),
    ?assert(maps:get(updated_at, Resumed) >= maps:get(updated_at, Original)),
    beam_agent_threads_core:clear().

%%====================================================================
%% list_threads tests
%%====================================================================

list_threads_empty_test() ->
    beam_agent_threads_core:ensure_table(),
    {ok, List} = beam_agent_threads_core:list_threads(<<"sess-list-empty">>),
    ?assertEqual([], List),
    beam_agent_threads_core:clear().

list_threads_returns_only_own_session_test() ->
    beam_agent_threads_core:ensure_table(),
    {ok, _} = beam_agent_threads_core:start_thread(<<"sess-list-A">>,
        #{thread_id => <<"t-A1">>}),
    {ok, _} = beam_agent_threads_core:start_thread(<<"sess-list-B">>,
        #{thread_id => <<"t-B1">>}),
    {ok, ListA} = beam_agent_threads_core:list_threads(<<"sess-list-A">>),
    {ok, ListB} = beam_agent_threads_core:list_threads(<<"sess-list-B">>),
    ?assertEqual(1, length(ListA)),
    ?assertEqual(1, length(ListB)),
    ?assertEqual(<<"t-A1">>, maps:get(thread_id, hd(ListA))),
    ?assertEqual(<<"t-B1">>, maps:get(thread_id, hd(ListB))),
    beam_agent_threads_core:clear().

list_threads_sorted_newest_first_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-list-order">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-order-1">>}),
    timer:sleep(5),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-order-2">>}),
    timer:sleep(5),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-order-3">>}),
    {ok, List} = beam_agent_threads_core:list_threads(SessionId),
    ?assertEqual(3, length(List)),
    [First, Second, Third] = List,
    ?assert(maps:get(updated_at, First) >= maps:get(updated_at, Second)),
    ?assert(maps:get(updated_at, Second) >= maps:get(updated_at, Third)),
    beam_agent_threads_core:clear().

%%====================================================================
%% get_thread tests
%%====================================================================

get_thread_found_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-get-1">>,
    ThreadId = <<"t-get-1">>,
    {ok, Created} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    {ok, Got} = beam_agent_threads_core:get_thread(SessionId, ThreadId),
    ?assertEqual(Created, Got),
    beam_agent_threads_core:clear().

get_thread_not_found_test() ->
    beam_agent_threads_core:ensure_table(),
    Result = beam_agent_threads_core:get_thread(<<"sess-get-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    beam_agent_threads_core:clear().

%%====================================================================
%% delete_thread tests
%%====================================================================

delete_thread_removes_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-del-1">>,
    ThreadId = <<"t-del-1">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    {ok, _} = beam_agent_threads_core:get_thread(SessionId, ThreadId),
    ok = beam_agent_threads_core:delete_thread(SessionId, ThreadId),
    ?assertEqual({error, not_found},
        beam_agent_threads_core:get_thread(SessionId, ThreadId)),
    beam_agent_threads_core:clear().

delete_thread_clears_active_if_it_was_active_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-del-2">>,
    ThreadId = <<"t-del-active">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    ?assertEqual({ok, ThreadId},
        beam_agent_threads_core:active_thread(SessionId)),
    ok = beam_agent_threads_core:delete_thread(SessionId, ThreadId),
    ?assertEqual({error, none},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

delete_thread_does_not_clear_active_for_other_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-del-3">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-del-other-1">>}),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-del-other-2">>}),
    %% t-del-other-2 is now active
    ok = beam_agent_threads_core:delete_thread(SessionId, <<"t-del-other-1">>),
    ?assertEqual({ok, <<"t-del-other-2">>},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

%%====================================================================
%% record_thread_message tests
%%====================================================================

record_thread_message_increments_count_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-msg-1">>,
    ThreadId = <<"t-msg-1">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    Msg = #{type => result, content => <<"hello">>},
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Thread} = beam_agent_threads_core:get_thread(SessionId, ThreadId),
    ?assertEqual(1, maps:get(message_count, Thread)),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Thread2} = beam_agent_threads_core:get_thread(SessionId, ThreadId),
    ?assertEqual(2, maps:get(message_count, Thread2)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

record_thread_message_updates_updated_at_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-msg-2">>,
    ThreadId = <<"t-msg-2">>,
    {ok, Before} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    timer:sleep(5),
    Msg = #{type => result, content => <<"update">>},
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Msg),
    {ok, After} = beam_agent_threads_core:get_thread(SessionId, ThreadId),
    ?assert(maps:get(updated_at, After) >= maps:get(updated_at, Before)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

record_thread_message_nonexistent_thread_is_noop_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-msg-3">>,
    Msg = #{type => result, content => <<"noop">>},
    %% Should not crash for a non-existent thread
    ok = beam_agent_threads_core:record_thread_message(SessionId,
        <<"no-such-thread">>, Msg),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

%%====================================================================
%% get_thread_messages tests
%%====================================================================

get_thread_messages_found_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-getmsg-1">>,
    ThreadId = <<"t-getmsg-1">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadId}),
    Msg = #{type => result, content => <<"msg content">>},
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Messages} = beam_agent_threads_core:get_thread_messages(SessionId, ThreadId),
    ?assertEqual(1, length(Messages)),
    [Received] = Messages,
    ?assertEqual(ThreadId, maps:get(thread_id, Received)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

get_thread_messages_not_found_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    Result = beam_agent_threads_core:get_thread_messages(<<"sess-getmsg-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

get_thread_messages_filters_by_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-getmsg-3">>,
    ThreadIdA = <<"t-getmsg-A">>,
    ThreadIdB = <<"t-getmsg-B">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadIdA}),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => ThreadIdB}),
    MsgA = #{type => result, content => <<"for A">>},
    MsgB = #{type => result, content => <<"for B">>},
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadIdA, MsgA),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadIdB, MsgB),
    {ok, MessagesA} = beam_agent_threads_core:get_thread_messages(SessionId, ThreadIdA),
    {ok, MessagesB} = beam_agent_threads_core:get_thread_messages(SessionId, ThreadIdB),
    ?assertEqual(1, length(MessagesA)),
    ?assertEqual(1, length(MessagesB)),
    [ReceivedA] = MessagesA,
    [ReceivedB] = MessagesB,
    ?assertEqual(ThreadIdA, maps:get(thread_id, ReceivedA)),
    ?assertEqual(ThreadIdB, maps:get(thread_id, ReceivedB)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Advanced thread state operations
%%====================================================================

fork_thread_copies_visible_messages_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-fork-thread">>,
    SourceThreadId = <<"t-fork-source">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => SourceThreadId}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, SourceThreadId,
        #{type => user, uuid => <<"tf-1">>, content => <<"one">>}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, SourceThreadId,
        #{type => assistant, uuid => <<"tf-2">>, content => <<"two">>}),
    {ok, Forked} = beam_agent_threads_core:fork_thread(SessionId, SourceThreadId,
        #{thread_id => <<"t-fork-target">>}),
    ?assertEqual(SourceThreadId, maps:get(parent_thread_id, Forked)),
    {ok, ForkedMessages} = beam_agent_threads_core:get_thread_messages(SessionId,
        <<"t-fork-target">>),
    ?assertEqual(2, length(ForkedMessages)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

read_thread_with_messages_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-read-thread">>,
    ThreadId = <<"t-read-thread">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId, #{thread_id => ThreadId}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
        #{type => result, content => <<"done">>}),
    {ok, #{thread := Thread, messages := Messages}} =
        beam_agent_threads_core:read_thread(SessionId, ThreadId,
            #{include_messages => true}),
    ?assertEqual(ThreadId, maps:get(thread_id, Thread)),
    ?assertEqual(1, length(Messages)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

archive_and_unarchive_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-archive-thread">>,
    ThreadId = <<"t-archive-thread">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId, #{thread_id => ThreadId}),
    {ok, Archived} = beam_agent_threads_core:archive_thread(SessionId, ThreadId),
    ?assertEqual(archived, maps:get(status, Archived)),
    ?assertEqual(true, maps:get(archived, Archived)),
    {ok, Unarchived} = beam_agent_threads_core:unarchive_thread(SessionId, ThreadId),
    ?assertEqual(active, maps:get(status, Unarchived)),
    ?assertEqual(false, maps:get(archived, Unarchived)),
    beam_agent_threads_core:clear().

rollback_thread_hides_visible_messages_test() ->
    beam_agent_threads_core:ensure_table(),
    beam_agent_session_store_core:ensure_tables(),
    SessionId = <<"sess-rollback-thread">>,
    ThreadId = <<"t-rollback-thread">>,
    {ok, _} = beam_agent_threads_core:start_thread(SessionId, #{thread_id => ThreadId}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
        #{type => user, uuid => <<"tr-1">>, content => <<"one">>}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
        #{type => assistant, uuid => <<"tr-2">>, content => <<"two">>}),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId,
        #{type => result, uuid => <<"tr-3">>, content => <<"three">>}),
    {ok, _} = beam_agent_threads_core:rollback_thread(SessionId, ThreadId,
        #{count => 1}),
    {ok, Visible} = beam_agent_threads_core:get_thread_messages(SessionId, ThreadId),
    ?assertEqual(2, length(Visible)),
    beam_agent_threads_core:clear(),
    beam_agent_session_store_core:clear().

%%====================================================================
%% thread_count tests
%%====================================================================

thread_count_empty_test() ->
    beam_agent_threads_core:ensure_table(),
    ?assertEqual(0, beam_agent_threads_core:thread_count(<<"sess-count-empty">>)),
    beam_agent_threads_core:clear().

thread_count_increments_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-count-1">>,
    ?assertEqual(0, beam_agent_threads_core:thread_count(SessionId)),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-count-1">>}),
    ?assertEqual(1, beam_agent_threads_core:thread_count(SessionId)),
    {ok, _} = beam_agent_threads_core:start_thread(SessionId,
        #{thread_id => <<"t-count-2">>}),
    ?assertEqual(2, beam_agent_threads_core:thread_count(SessionId)),
    beam_agent_threads_core:clear().

thread_count_isolated_per_session_test() ->
    beam_agent_threads_core:ensure_table(),
    {ok, _} = beam_agent_threads_core:start_thread(<<"sess-count-A">>,
        #{thread_id => <<"t-iso-1">>}),
    {ok, _} = beam_agent_threads_core:start_thread(<<"sess-count-A">>,
        #{thread_id => <<"t-iso-2">>}),
    {ok, _} = beam_agent_threads_core:start_thread(<<"sess-count-B">>,
        #{thread_id => <<"t-iso-3">>}),
    ?assertEqual(2, beam_agent_threads_core:thread_count(<<"sess-count-A">>)),
    ?assertEqual(1, beam_agent_threads_core:thread_count(<<"sess-count-B">>)),
    beam_agent_threads_core:clear().

%%====================================================================
%% active_thread / set_active_thread / clear_active_thread tests
%%====================================================================

active_thread_none_initially_test() ->
    beam_agent_threads_core:ensure_table(),
    ?assertEqual({error, none},
        beam_agent_threads_core:active_thread(<<"sess-active-none">>)),
    beam_agent_threads_core:clear().

set_active_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-active-1">>,
    ThreadId = <<"t-active-1">>,
    ok = beam_agent_threads_core:set_active_thread(SessionId, ThreadId),
    ?assertEqual({ok, ThreadId},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

set_active_thread_overrides_previous_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-active-2">>,
    ok = beam_agent_threads_core:set_active_thread(SessionId, <<"t-first">>),
    ok = beam_agent_threads_core:set_active_thread(SessionId, <<"t-second">>),
    ?assertEqual({ok, <<"t-second">>},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

clear_active_thread_test() ->
    beam_agent_threads_core:ensure_table(),
    SessionId = <<"sess-active-3">>,
    ok = beam_agent_threads_core:set_active_thread(SessionId, <<"t-active-3">>),
    ?assertMatch({ok, _}, beam_agent_threads_core:active_thread(SessionId)),
    ok = beam_agent_threads_core:clear_active_thread(SessionId),
    ?assertEqual({error, none},
        beam_agent_threads_core:active_thread(SessionId)),
    beam_agent_threads_core:clear().

clear_active_thread_noop_when_none_test() ->
    beam_agent_threads_core:ensure_table(),
    ok = beam_agent_threads_core:clear_active_thread(<<"sess-active-noop">>),
    ?assertEqual({error, none},
        beam_agent_threads_core:active_thread(<<"sess-active-noop">>)),
    beam_agent_threads_core:clear().

active_thread_isolated_per_session_test() ->
    beam_agent_threads_core:ensure_table(),
    ok = beam_agent_threads_core:set_active_thread(<<"sess-iso-A">>, <<"t-iso-A">>),
    ok = beam_agent_threads_core:set_active_thread(<<"sess-iso-B">>, <<"t-iso-B">>),
    ?assertEqual({ok, <<"t-iso-A">>},
        beam_agent_threads_core:active_thread(<<"sess-iso-A">>)),
    ?assertEqual({ok, <<"t-iso-B">>},
        beam_agent_threads_core:active_thread(<<"sess-iso-B">>)),
    beam_agent_threads_core:clear().
