-module(beam_agent_threads_core).
-moduledoc """
Universal thread/conversation management for the BEAM Agent SDK.

Provides logical conversation threading across all adapters.
A thread groups related queries into a named conversation context.

Uses the same ETS-backed approach as beam_agent_session_store_core.
Threads are scoped to a session — each session can have multiple
threads, and each thread tracks its query history.

Usage:
```erlang
%% Start a new thread:
{ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{
    name => <<"feature-discussion">>
}),

%% List threads:
{ok, Threads} = beam_agent_threads_core:list_threads(SessionId),

%% Resume a thread:
{ok, Thread} = beam_agent_threads_core:resume_thread(SessionId, ThreadId)
```
""".

-export([
    %% Table lifecycle
    ensure_table/0,
    clear/0,
    %% Thread operations
    start_thread/2,
    fork_thread/3,
    resume_thread/2,
    list_threads/1,
    get_thread/2,
    read_thread/2,
    read_thread/3,
    delete_thread/2,
    archive_thread/2,
    rename_thread/3,
    update_thread_metadata/3,
    unarchive_thread/2,
    rollback_thread/3,
    %% Thread message tracking
    record_thread_message/3,
    get_thread_messages/2,
    %% Convenience
    thread_count/1,
    active_thread/1,
    set_active_thread/2,
    clear_active_thread/1
]).

-export_type([thread_meta/0, thread_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Thread metadata.
-type thread_meta() :: #{
    thread_id := binary(),
    session_id := binary(),
    name => binary(),
    metadata => map(),
    created_at := integer(),
    updated_at := integer(),
    message_count := non_neg_integer(),
    visible_message_count := non_neg_integer(),
    status := active | paused | completed | archived,
    archived => boolean(),
    archived_at => integer(),
    parent_thread_id => binary(),
    summary => map()
}.

%% Options for start_thread/2.
-type thread_opts() :: #{
    name => binary(),
    metadata => map(),
    thread_id => binary(),
    parent_thread_id => binary()
}.

-type thread_read() :: #{
    thread := thread_meta(),
    messages => [beam_agent_core:message()]
}.

%% ETS table name.
-define(THREADS_TABLE, beam_agent_threads_core).
%% Active thread per session.
-define(ACTIVE_TABLE, beam_agent_active_threads).

-type thread_store_table() ::
    beam_agent_active_threads |
    beam_agent_threads_core.
-type thread_store_table_option() ::
    named_table |
    public |
    set |
    {read_concurrency, true}.

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the threads ETS table exists. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    ensure_ets(?THREADS_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_ets(?ACTIVE_TABLE, [set, public, named_table]),
    ok.

-doc "Clear all thread data.".
-spec clear() -> ok.
clear() ->
    ensure_table(),
    ets:delete_all_objects(?THREADS_TABLE),
    ets:delete_all_objects(?ACTIVE_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Thread Operations
%%--------------------------------------------------------------------

-doc """
Start a new conversation thread within a session.
Generates a thread ID if not provided in opts.
Returns the thread metadata.
""".
-spec start_thread(binary(), thread_opts()) -> {ok, thread_meta()}.
start_thread(SessionId, Opts) when is_binary(SessionId), is_map(Opts) ->
    ensure_table(),
    ThreadId = maps:get(thread_id, Opts,
        generate_thread_id()),
    Now = erlang:system_time(millisecond),
    Thread = #{
        thread_id => ThreadId,
        session_id => SessionId,
        name => maps:get(name, Opts, ThreadId),
        metadata => maps:get(metadata, Opts, #{}),
        created_at => Now,
        updated_at => Now,
        message_count => 0,
        visible_message_count => 0,
        status => active,
        archived => false
    },
    Thread1 = case maps:find(parent_thread_id, Opts) of
        {ok, ParentThreadId} when is_binary(ParentThreadId) ->
            Thread#{parent_thread_id => ParentThreadId};
        _ ->
            Thread
    end,
    Key = {SessionId, ThreadId},
    ets:insert(?THREADS_TABLE, {Key, Thread1}),
    %% Set as active thread for this session
    set_active_thread(SessionId, ThreadId),
    {ok, Thread1}.

-doc """
Fork an existing thread in the universal thread store.

The new thread receives a copy of the source thread's visible message history
with the `thread_id` rewritten to the fork id.
""".
-spec fork_thread(binary(), binary(), thread_opts()) ->
    {ok, thread_meta()} | {error, not_found}.
fork_thread(SessionId, SourceThreadId, Opts)
  when is_binary(SessionId), is_binary(SourceThreadId), is_map(Opts) ->
    case get_thread(SessionId, SourceThreadId) of
        {ok, SourceThread} ->
            {ok, SourceMessages} = get_thread_messages(SessionId, SourceThreadId),
            ParentThreadId = maps:get(parent_thread_id, Opts, SourceThreadId),
            ThreadId = maps:get(thread_id, Opts, generate_thread_id()),
            ThreadOpts = Opts#{
                thread_id => ThreadId,
                parent_thread_id => ParentThreadId,
                name => maps:get(name, Opts,
                    maps:get(name, SourceThread, ThreadId))
            },
            {ok, _Forked} = start_thread(SessionId, ThreadOpts),
            Copied = [Message#{thread_id => ThreadId} || Message <- SourceMessages],
            ok = lists:foreach(fun(Msg) ->
                beam_agent_session_store_core:record_message(SessionId, Msg)
            end, Copied),
            update_thread(SessionId, ThreadId, fun(Thread0) ->
                Thread0#{
                    message_count => length(Copied),
                    visible_message_count => length(Copied),
                    parent_thread_id => ParentThreadId
                }
            end);
        {error, not_found} ->
            {error, not_found}
    end.

-doc """
Resume an existing thread by ID.
Sets it as the active thread for the session.
Returns `{error, not_found}` if the thread doesn't exist.
""".
-spec resume_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
resume_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] ->
            Now = erlang:system_time(millisecond),
            Updated = Thread#{
                status => active,
                updated_at => Now
            },
            ets:insert(?THREADS_TABLE, {Key, Updated}),
            set_active_thread(SessionId, ThreadId),
            {ok, Updated};
        [] ->
            {error, not_found}
    end.

-doc "List all threads for a session, sorted by `updated_at` descending.".
-spec list_threads(binary()) -> {ok, [thread_meta()]}.
list_threads(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    Threads = ets:foldl(fun
        ({{SId, _}, Thread}, Acc) when SId =:= SessionId ->
            [Thread | Acc];
        (_, Acc) ->
            Acc
    end, [], ?THREADS_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0)
    end, Threads),
    {ok, Sorted}.

-doc "Get a specific thread by ID.".
-spec get_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
get_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] -> {ok, Thread};
        [] -> {error, not_found}
    end.

-doc """
Read a thread with optional visible message history.

Options:
- `include_messages` — include the visible thread messages in the response
""".
-spec read_thread(binary(), binary()) ->
    {ok, thread_read()} | {error, not_found}.
read_thread(SessionId, ThreadId) ->
    read_thread(SessionId, ThreadId, #{}).

-spec read_thread(binary(), binary(), map()) ->
    {ok, thread_read()} | {error, not_found}.
read_thread(SessionId, ThreadId, Opts)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Opts) ->
    case get_thread(SessionId, ThreadId) of
        {ok, Thread} ->
            case maps:get(include_messages, Opts, false) of
                true ->
                    {ok, Messages} = get_thread_messages(SessionId, ThreadId),
                    {ok, #{thread => Thread, messages => Messages}};
                false ->
                    {ok, #{thread => Thread}}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Delete a thread.".
-spec delete_thread(binary(), binary()) -> ok.
delete_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    ets:delete(?THREADS_TABLE, Key),
    %% Clear active thread if this was it
    case active_thread(SessionId) of
        {ok, ThreadId} -> clear_active_thread(SessionId);
        _ -> ok
    end,
    ok.

-doc "Archive a thread in the universal thread store.".
-spec archive_thread(binary(), binary()) -> {ok, thread_meta()} | {error, not_found}.
archive_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    update_thread(SessionId, ThreadId, fun(Thread0) ->
        Thread0#{
            status => archived,
            archived => true,
            archived_at => erlang:system_time(millisecond),
            updated_at => erlang:system_time(millisecond)
        }
    end).

-doc "Rename a thread in the universal thread store.".
-spec rename_thread(binary(), binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
rename_thread(SessionId, ThreadId, Name)
  when is_binary(SessionId), is_binary(ThreadId), is_binary(Name) ->
    update_thread(SessionId, ThreadId, fun(Thread0) ->
        Thread0#{
            name => Name,
            updated_at => erlang:system_time(millisecond)
        }
    end).

-doc "Merge metadata into a thread in the universal thread store.".
-spec update_thread_metadata(binary(), binary(), map()) ->
    {ok, thread_meta()} | {error, not_found}.
update_thread_metadata(SessionId, ThreadId, MetadataPatch)
  when is_binary(SessionId), is_binary(ThreadId), is_map(MetadataPatch) ->
    update_thread(SessionId, ThreadId, fun(Thread0) ->
        CurrentMetadata = maps:get(metadata, Thread0, #{}),
        Thread0#{
            metadata => maps:merge(CurrentMetadata, MetadataPatch),
            updated_at => erlang:system_time(millisecond)
        }
    end).

-doc "Unarchive a thread in the universal thread store.".
-spec unarchive_thread(binary(), binary()) -> {ok, thread_meta()} | {error, not_found}.
unarchive_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    update_thread(SessionId, ThreadId, fun(Thread0) ->
        Thread0#{
            status => active,
            archived => false,
            updated_at => erlang:system_time(millisecond)
        }
    end).

-doc """
Rollback the visible thread history by message count or explicit boundary.

`Selector` may be:
- `#{count => N}` — hide the last N visible messages
- `#{visible_message_count => N}` — set the visible boundary directly
- `#{message_id => Id}` / `#{uuid => Id}` — set the boundary to a specific message
""".
-spec rollback_thread(binary(), binary(), map()) ->
    {ok, thread_meta()} | {error, not_found | invalid_selector}.
rollback_thread(SessionId, ThreadId, Selector)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Selector) ->
    case read_thread(SessionId, ThreadId, #{include_messages => true}) of
        {ok, #{thread := Thread, messages := Messages}} ->
            CurrentVisible = maps:get(visible_message_count, Thread,
                length(Messages)),
            case select_thread_visible_count(Messages, CurrentVisible, Selector) of
                {ok, VisibleCount} ->
                    update_thread(SessionId, ThreadId, fun(Thread0) ->
                        Thread0#{
                            visible_message_count => VisibleCount,
                            updated_at => erlang:system_time(millisecond)
                        }
                    end);
                {error, invalid_selector} ->
                    {error, invalid_selector}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Thread Message Tracking
%%--------------------------------------------------------------------

-doc """
Record a message against a thread.
Also records the message in the session store for unified history.
""".
-spec record_thread_message(binary(), binary(), beam_agent_core:message()) -> ok.
record_thread_message(SessionId, ThreadId, Message)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Message) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] ->
            Now = erlang:system_time(millisecond),
            Count = maps:get(message_count, Thread, 0) + 1,
            Updated = Thread#{
                message_count => Count,
                visible_message_count => Count,
                updated_at => Now
            },
            ets:insert(?THREADS_TABLE, {Key, Updated});
        [] ->
            ok
    end,
    %% Also record in the session-level message store
    TaggedMessage = Message#{thread_id => ThreadId},
    beam_agent_session_store_core:record_message(SessionId, TaggedMessage),
    ok.

-doc """
Get all messages for a specific thread.
Filters session messages by `thread_id` tag.
""".
-spec get_thread_messages(binary(), binary()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_thread_messages(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    case get_thread(SessionId, ThreadId) of
        {ok, Thread} ->
            case beam_agent_session_store_core:get_session_messages(SessionId) of
                {ok, AllMessages} ->
                    ThreadMessages0 = [M || #{thread_id := TId} = M
                        <- AllMessages, TId =:= ThreadId],
                    VisibleCount = maps:get(visible_message_count, Thread,
                        length(ThreadMessages0)),
                    ThreadMessages = limit_visible_messages(ThreadMessages0,
                        VisibleCount),
                    {ok, ThreadMessages};
                {error, not_found} ->
                    {ok, []}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc "Count threads for a session.".
-spec thread_count(binary()) -> non_neg_integer().
thread_count(SessionId) when is_binary(SessionId) ->
    {ok, Threads} = list_threads(SessionId),
    length(Threads).

-doc "Get the currently active thread for a session.".
-spec active_thread(binary()) -> {ok, binary()} | {error, none}.
active_thread(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    case ets:lookup(?ACTIVE_TABLE, SessionId) of
        [{_, ThreadId}] -> {ok, ThreadId};
        [] -> {error, none}
    end.

-doc "Set the active thread for a session.".
-spec set_active_thread(binary(), binary()) -> ok.
set_active_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    ets:insert(?ACTIVE_TABLE, {SessionId, ThreadId}),
    ok.

-doc "Clear the active thread for a session.".
-spec clear_active_thread(binary()) -> ok.
clear_active_thread(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    ets:delete(?ACTIVE_TABLE, SessionId),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

generate_thread_id() ->
    Hex = binary:encode_hex(rand:bytes(8), lowercase),
    <<"thread_", Hex/binary>>.

-spec update_thread(binary(), binary(), fun((thread_meta()) -> thread_meta())) ->
    {ok, thread_meta()} | {error, not_found}.
update_thread(SessionId, ThreadId, Fun)
  when is_binary(SessionId), is_binary(ThreadId), is_function(Fun, 1) ->
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] ->
            Updated = Fun(Thread),
            ets:insert(?THREADS_TABLE, {Key, Updated}),
            {ok, Updated};
        [] ->
            {error, not_found}
    end.

-spec select_thread_visible_count([beam_agent_core:message()], non_neg_integer(), map()) ->
    {ok, non_neg_integer()} | {error, invalid_selector}.
select_thread_visible_count(_Messages, CurrentVisible, #{count := Count})
  when is_integer(Count), Count >= 0 ->
    {ok, max(0, CurrentVisible - Count)};
select_thread_visible_count(Messages, _CurrentVisible,
                           #{visible_message_count := Count})
  when is_integer(Count), Count >= 0 ->
    {ok, min(Count, length(Messages))};
select_thread_visible_count(Messages, CurrentVisible, #{message_id := MessageId})
  when is_binary(MessageId) ->
    select_thread_visible_count(Messages, CurrentVisible, #{uuid => MessageId});
select_thread_visible_count(Messages, _CurrentVisible, #{uuid := MessageId})
  when is_binary(MessageId) ->
    find_thread_boundary(Messages, MessageId, 1);
select_thread_visible_count(_Messages, _CurrentVisible, _Selector) ->
    {error, invalid_selector}.

-spec find_thread_boundary([beam_agent_core:message()], binary(), pos_integer()) ->
    {ok, non_neg_integer()} | {error, invalid_selector}.
find_thread_boundary([], _MessageId, _Index) ->
    {error, invalid_selector};
find_thread_boundary([Message | Rest], MessageId, Index) ->
    case message_matches(Message, MessageId) of
        true -> {ok, Index};
        false -> find_thread_boundary(Rest, MessageId, Index + 1)
    end.

-spec message_matches(beam_agent_core:message(), binary()) -> boolean().
message_matches(Message, MessageId) ->
    maps:get(uuid, Message, undefined) =:= MessageId orelse
    maps:get(message_id, Message, undefined) =:= MessageId.

-spec limit_visible_messages([beam_agent_core:message()], non_neg_integer()) ->
    [beam_agent_core:message()].
limit_visible_messages(Messages, VisibleCount) when VisibleCount >= 0 ->
    lists:sublist(Messages, min(VisibleCount, length(Messages))).

-spec ensure_ets(thread_store_table(), [thread_store_table_option(), ...]) -> ok.
ensure_ets(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.
