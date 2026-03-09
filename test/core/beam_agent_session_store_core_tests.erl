%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_session_store_core (session history store).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Session metadata (register_session, update_session, get_session,
%%%     delete_session, list_sessions/0, list_sessions/1 with filters)
%%%   - Message storage (record_message, record_messages,
%%%     get_session_messages/1, get_session_messages/2 with opts)
%%%   - Convenience (session_count, message_count)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_session_store_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = beam_agent_session_store_core:ensure_tables(),
    ok = beam_agent_session_store_core:ensure_tables(),
    ok = beam_agent_session_store_core:ensure_tables(),
    beam_agent_session_store_core:clear().

clear_empties_all_tables_test() ->
    SId = <<"clear-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"hi">>}),
    ok = beam_agent_session_store_core:clear(),
    ?assertEqual({error, not_found}, beam_agent_session_store_core:get_session(SId)),
    ?assertEqual(0, beam_agent_session_store_core:session_count()),
    ?assertEqual(0, beam_agent_session_store_core:message_count(SId)).

%%====================================================================
%% register_session
%%====================================================================

register_session_test() ->
    SId = <<"reg-basic-session">>,
    ok = beam_agent_session_store_core:register_session(SId,
        #{adapter => claude, model => <<"claude-sonnet-4-6">>}),
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(SId, maps:get(session_id, Meta)),
    ?assertEqual(claude, maps:get(adapter, Meta)),
    ?assertEqual(<<"claude-sonnet-4-6">>, maps:get(model, Meta)),
    ?assert(is_integer(maps:get(created_at, Meta))),
    ?assert(is_integer(maps:get(updated_at, Meta))),
    beam_agent_session_store_core:clear().

register_session_idempotent_test() ->
    SId = <<"reg-idem-session">>,
    ok = beam_agent_session_store_core:register_session(SId, #{model => <<"v1">>}),
    ok = beam_agent_session_store_core:register_session(SId, #{model => <<"v2">>}),
    %% Second call is a no-op; original data preserved
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(<<"v1">>, maps:get(model, Meta)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% update_session
%%====================================================================

update_session_merges_fields_test() ->
    SId = <<"upd-merge-session">>,
    beam_agent_session_store_core:register_session(SId,
        #{adapter => gemini, model => <<"gemini-1.5">>}),
    ok = beam_agent_session_store_core:update_session(SId, #{model => <<"gemini-2.0">>}),
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(gemini, maps:get(adapter, Meta)),
    ?assertEqual(<<"gemini-2.0">>, maps:get(model, Meta)),
    beam_agent_session_store_core:clear().

update_session_auto_creates_test() ->
    SId = <<"upd-autocreate-session">>,
    beam_agent_session_store_core:ensure_tables(),
    %% Session does not exist yet
    ?assertEqual({error, not_found}, beam_agent_session_store_core:get_session(SId)),
    ok = beam_agent_session_store_core:update_session(SId, #{adapter => codex}),
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(SId, maps:get(session_id, Meta)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% get_session
%%====================================================================

get_session_not_found_test() ->
    beam_agent_session_store_core:ensure_tables(),
    ?assertEqual({error, not_found},
        beam_agent_session_store_core:get_session(<<"no-such-session">>)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% delete_session
%%====================================================================

delete_session_removes_metadata_test() ->
    SId = <<"del-meta-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    ok = beam_agent_session_store_core:delete_session(SId),
    ?assertEqual({error, not_found}, beam_agent_session_store_core:get_session(SId)),
    beam_agent_session_store_core:clear().

delete_session_removes_messages_test() ->
    SId = <<"del-msgs-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"a">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"b">>}),
    ok = beam_agent_session_store_core:delete_session(SId),
    %% Session gone, message_count falls back to counter (which is also deleted)
    ?assertEqual(0, beam_agent_session_store_core:message_count(SId)),
    beam_agent_session_store_core:clear().

delete_session_nonexistent_test() ->
    beam_agent_session_store_core:ensure_tables(),
    %% Deleting a non-existent session is a no-op
    ok = beam_agent_session_store_core:delete_session(<<"ghost-session">>),
    beam_agent_session_store_core:clear().

%%====================================================================
%% list_sessions/0 and list_sessions/1
%%====================================================================

list_sessions_empty_test() ->
    beam_agent_session_store_core:ensure_tables(),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(),
    ?assertEqual([], Sessions),
    beam_agent_session_store_core:clear().

list_sessions_all_test() ->
    beam_agent_session_store_core:register_session(<<"ls-a">>, #{adapter => claude}),
    beam_agent_session_store_core:register_session(<<"ls-b">>, #{adapter => gemini}),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(),
    Ids = lists:sort([maps:get(session_id, S) || S <- Sessions]),
    ?assertEqual([<<"ls-a">>, <<"ls-b">>], Ids),
    beam_agent_session_store_core:clear().

list_sessions_filter_adapter_test() ->
    beam_agent_session_store_core:register_session(<<"fa-c">>, #{adapter => claude}),
    beam_agent_session_store_core:register_session(<<"fa-g">>, #{adapter => gemini}),
    beam_agent_session_store_core:register_session(<<"fa-g2">>, #{adapter => gemini}),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(#{adapter => gemini}),
    Ids = lists:sort([maps:get(session_id, S) || S <- Sessions]),
    ?assertEqual([<<"fa-g">>, <<"fa-g2">>], Ids),
    beam_agent_session_store_core:clear().

list_sessions_filter_model_test() ->
    beam_agent_session_store_core:register_session(<<"fm-s">>,
        #{model => <<"claude-sonnet-4-6">>}),
    beam_agent_session_store_core:register_session(<<"fm-h">>,
        #{model => <<"claude-haiku">>}),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(
        #{model => <<"claude-sonnet-4-6">>}),
    ?assertEqual(1, length(Sessions)),
    [S] = Sessions,
    ?assertEqual(<<"fm-s">>, maps:get(session_id, S)),
    beam_agent_session_store_core:clear().

list_sessions_filter_limit_test() ->
    beam_agent_session_store_core:register_session(<<"lim-1">>, #{adapter => claude}),
    timer:sleep(1),
    beam_agent_session_store_core:register_session(<<"lim-2">>, #{adapter => claude}),
    timer:sleep(1),
    beam_agent_session_store_core:register_session(<<"lim-3">>, #{adapter => claude}),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(#{limit => 2}),
    ?assertEqual(2, length(Sessions)),
    beam_agent_session_store_core:clear().

list_sessions_filter_since_test() ->
    Before = erlang:system_time(millisecond),
    timer:sleep(5),
    beam_agent_session_store_core:register_session(<<"since-new">>, #{adapter => claude}),
    {ok, Sessions} = beam_agent_session_store_core:list_sessions(#{since => Before}),
    Ids = [maps:get(session_id, S) || S <- Sessions],
    ?assert(lists:member(<<"since-new">>, Ids)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% record_message and record_messages
%%====================================================================

record_message_auto_creates_session_test() ->
    SId = <<"msg-autocreate-session">>,
    beam_agent_session_store_core:ensure_tables(),
    ok = beam_agent_session_store_core:record_message(SId,
        #{type => text, text => <<"hello">>}),
    %% Session should now exist
    {ok, _} = beam_agent_session_store_core:get_session(SId),
    beam_agent_session_store_core:clear().

record_message_increments_count_test() ->
    SId = <<"msg-count-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"a">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"b">>}),
    ?assertEqual(2, beam_agent_session_store_core:message_count(SId)),
    beam_agent_session_store_core:clear().

record_messages_batch_test() ->
    SId = <<"msg-batch-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    Msgs = [
        #{type => text, text => <<"one">>},
        #{type => text, text => <<"two">>},
        #{type => text, text => <<"three">>}
    ],
    ok = beam_agent_session_store_core:record_messages(SId, Msgs),
    ?assertEqual(3, beam_agent_session_store_core:message_count(SId)),
    beam_agent_session_store_core:clear().

record_message_extracts_model_from_system_test() ->
    SId = <<"msg-model-sys-session">>,
    beam_agent_session_store_core:ensure_tables(),
    beam_agent_session_store_core:record_message(SId,
        #{type => system, system_info => #{model => <<"claude-opus-4-6">>}}),
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(<<"claude-opus-4-6">>, maps:get(model, Meta)),
    beam_agent_session_store_core:clear().

record_message_extracts_model_from_result_test() ->
    SId = <<"msg-model-res-session">>,
    beam_agent_session_store_core:ensure_tables(),
    beam_agent_session_store_core:record_message(SId,
        #{type => result, model => <<"claude-haiku">>}),
    {ok, Meta} = beam_agent_session_store_core:get_session(SId),
    ?assertEqual(<<"claude-haiku">>, maps:get(model, Meta)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% get_session_messages/1
%%====================================================================

get_session_messages_in_order_test() ->
    SId = <<"msgs-order-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"first">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"second">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"third">>}),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId),
    ?assertEqual(3, length(Msgs)),
    [M1, M2, M3] = Msgs,
    ?assertEqual(<<"first">>, maps:get(text, M1)),
    ?assertEqual(<<"second">>, maps:get(text, M2)),
    ?assertEqual(<<"third">>, maps:get(text, M3)),
    beam_agent_session_store_core:clear().

get_session_messages_not_found_test() ->
    beam_agent_session_store_core:ensure_tables(),
    ?assertEqual({error, not_found},
        beam_agent_session_store_core:get_session_messages(<<"ghost-msg-session">>)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% get_session_messages/2 with opts
%%====================================================================

get_session_messages_limit_test() ->
    SId = <<"msgs-limit-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        beam_agent_session_store_core:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 5)),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId, #{limit => 3}),
    ?assertEqual(3, length(Msgs)),
    beam_agent_session_store_core:clear().

get_session_messages_offset_test() ->
    SId = <<"msgs-offset-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        beam_agent_session_store_core:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 5)),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId, #{offset => 2}),
    ?assertEqual(3, length(Msgs)),
    [First | _] = Msgs,
    ?assertEqual(<<"3">>, maps:get(text, First)),
    beam_agent_session_store_core:clear().

get_session_messages_limit_and_offset_test() ->
    SId = <<"msgs-lo-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        beam_agent_session_store_core:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 10)),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId,
        #{offset => 3, limit => 2}),
    ?assertEqual(2, length(Msgs)),
    [M1, M2] = Msgs,
    ?assertEqual(<<"4">>, maps:get(text, M1)),
    ?assertEqual(<<"5">>, maps:get(text, M2)),
    beam_agent_session_store_core:clear().

get_session_messages_types_filter_test() ->
    SId = <<"msgs-types-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"t">>}),
    beam_agent_session_store_core:record_message(SId, #{type => result, text => <<"r">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"t2">>}),
    beam_agent_session_store_core:record_message(SId, #{type => system, text => <<"s">>}),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId,
        #{types => [text]}),
    ?assertEqual(2, length(Msgs)),
    Types = [maps:get(type, M) || M <- Msgs],
    ?assert(lists:all(fun(T) -> T =:= text end, Types)),
    beam_agent_session_store_core:clear().

get_session_messages_multiple_types_filter_test() ->
    SId = <<"msgs-mtypes-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"t">>}),
    beam_agent_session_store_core:record_message(SId, #{type => result, text => <<"r">>}),
    beam_agent_session_store_core:record_message(SId, #{type => system, text => <<"s">>}),
    {ok, Msgs} = beam_agent_session_store_core:get_session_messages(SId,
        #{types => [text, result]}),
    ?assertEqual(2, length(Msgs)),
    Types = lists:sort([maps:get(type, M) || M <- Msgs]),
    ?assertEqual([result, text], Types),
    beam_agent_session_store_core:clear().

%%====================================================================
%% Advanced session state operations
%%====================================================================

fork_session_copies_visible_history_test() ->
    SId = <<"fork-source-session">>,
    beam_agent_session_store_core:register_session(SId,
        #{adapter => claude, extra => #{origin => <<"source">>}}),
    beam_agent_session_store_core:record_message(SId,
        #{type => user, uuid => <<"m-1">>, content => <<"one">>}),
    beam_agent_session_store_core:record_message(SId,
        #{type => assistant, uuid => <<"m-2">>, content => <<"two">>}),
    {ok, Forked} = beam_agent_session_store_core:fork_session(SId,
        #{session_id => <<"fork-target-session">>}),
    ?assertEqual(<<"fork-target-session">>, maps:get(session_id, Forked)),
    {ok, ForkedMsgs} = beam_agent_session_store_core:get_session_messages(
        <<"fork-target-session">>),
    ?assertEqual(2, length(ForkedMsgs)),
    {ok, ForkedMeta} = beam_agent_session_store_core:get_session(
        <<"fork-target-session">>),
    Extra = maps:get(extra, ForkedMeta, #{}),
    ForkInfo = maps:get(fork, Extra, #{}),
    ?assertEqual(SId, maps:get(parent_session_id, ForkInfo)),
    beam_agent_session_store_core:clear().

revert_and_unrevert_session_view_test() ->
    SId = <<"revert-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => copilot}),
    beam_agent_session_store_core:record_message(SId,
        #{type => user, uuid => <<"r-1">>, content => <<"one">>}),
    beam_agent_session_store_core:record_message(SId,
        #{type => assistant, uuid => <<"r-2">>, content => <<"two">>}),
    beam_agent_session_store_core:record_message(SId,
        #{type => result, uuid => <<"r-3">>, content => <<"three">>}),
    {ok, _} = beam_agent_session_store_core:revert_session(SId,
        #{uuid => <<"r-2">>}),
    {ok, Visible} = beam_agent_session_store_core:get_session_messages(SId),
    ?assertEqual(2, length(Visible)),
    {ok, Hidden} = beam_agent_session_store_core:get_session_messages(SId,
        #{include_hidden => true}),
    ?assertEqual(3, length(Hidden)),
    {ok, _} = beam_agent_session_store_core:unrevert_session(SId),
    {ok, Restored} = beam_agent_session_store_core:get_session_messages(SId),
    ?assertEqual(3, length(Restored)),
    beam_agent_session_store_core:clear().

share_and_unshare_session_test() ->
    SId = <<"share-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => gemini}),
    {ok, Share} = beam_agent_session_store_core:share_session(SId),
    ?assertEqual(active, maps:get(status, Share)),
    {ok, StoredShare} = beam_agent_session_store_core:get_share(SId),
    ?assertEqual(maps:get(share_id, Share), maps:get(share_id, StoredShare)),
    ok = beam_agent_session_store_core:unshare_session(SId),
    {ok, RevokedShare} = beam_agent_session_store_core:get_share(SId),
    ?assertEqual(revoked, maps:get(status, RevokedShare)),
    beam_agent_session_store_core:clear().

summarize_session_stores_summary_test() ->
    SId = <<"summary-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => opencode}),
    beam_agent_session_store_core:record_message(SId,
        #{type => user, content => <<"Review the patch">>}),
    beam_agent_session_store_core:record_message(SId,
        #{type => result, content => <<"Patch looks good">>}),
    {ok, Summary} = beam_agent_session_store_core:summarize_session(SId, #{}),
    ?assertEqual(2, maps:get(message_count, Summary)),
    {ok, StoredSummary} = beam_agent_session_store_core:get_summary(SId),
    ?assertEqual(maps:get(content, Summary), maps:get(content, StoredSummary)),
    beam_agent_session_store_core:clear().

%%====================================================================
%% session_count and message_count
%%====================================================================

session_count_empty_test() ->
    beam_agent_session_store_core:ensure_tables(),
    ?assertEqual(0, beam_agent_session_store_core:session_count()),
    beam_agent_session_store_core:clear().

session_count_test() ->
    beam_agent_session_store_core:register_session(<<"sc-1">>, #{adapter => claude}),
    beam_agent_session_store_core:register_session(<<"sc-2">>, #{adapter => gemini}),
    beam_agent_session_store_core:register_session(<<"sc-3">>, #{adapter => codex}),
    ?assertEqual(3, beam_agent_session_store_core:session_count()),
    beam_agent_session_store_core:clear().

message_count_no_messages_test() ->
    beam_agent_session_store_core:ensure_tables(),
    ?assertEqual(0, beam_agent_session_store_core:message_count(<<"no-msgs-session">>)),
    beam_agent_session_store_core:clear().

message_count_test() ->
    SId = <<"mc-session">>,
    beam_agent_session_store_core:register_session(SId, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"a">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"b">>}),
    beam_agent_session_store_core:record_message(SId, #{type => text, text => <<"c">>}),
    ?assertEqual(3, beam_agent_session_store_core:message_count(SId)),
    beam_agent_session_store_core:clear().

message_count_isolated_per_session_test() ->
    SId1 = <<"mc-iso-1">>,
    SId2 = <<"mc-iso-2">>,
    beam_agent_session_store_core:register_session(SId1, #{adapter => claude}),
    beam_agent_session_store_core:register_session(SId2, #{adapter => claude}),
    beam_agent_session_store_core:record_message(SId1, #{type => text, text => <<"x">>}),
    beam_agent_session_store_core:record_message(SId1, #{type => text, text => <<"y">>}),
    beam_agent_session_store_core:record_message(SId2, #{type => text, text => <<"z">>}),
    ?assertEqual(2, beam_agent_session_store_core:message_count(SId1)),
    ?assertEqual(1, beam_agent_session_store_core:message_count(SId2)),
    beam_agent_session_store_core:clear().
