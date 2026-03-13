-module(beam_agent_session_store_core).
-moduledoc """
Universal session history store for the BEAM Agent SDK.

Provides session tracking and message history across all adapters.
This is beam_agent_core's own implementation — every adapter records
messages here, regardless of whether the underlying CLI has native
session history support.

Uses ETS for fast in-process storage. Sessions persist for the
lifetime of the BEAM node (or until explicitly deleted/cleared).

Two ETS tables:
  - `beam_agent_sessions` — session metadata (id, model, cwd, etc.)
  - `beam_agent_session_messages` — messages keyed by {session_id, seq}

Tables are created lazily on first access via `beam_agent_ets` which
resolves access mode automatically. Named tables allow any process to
read/write without bottlenecking on a single owner.

Usage:
```erlang
%% Record messages as they arrive:
beam_agent_session_store_core:record_message(SessionId, Message),

%% Query history:
{ok, Sessions} = beam_agent_session_store_core:list_sessions(),
{ok, Messages} = beam_agent_session_store_core:get_session_messages(SessionId)
```
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Session metadata
    register_session/2,
    update_session/2,
    get_session/1,
    delete_session/1,
    list_sessions/0,
    list_sessions/1,
    fork_session/2,
    revert_session/2,
    unrevert_session/1,
    share_session/1,
    share_session/2,
    unshare_session/1,
    get_share/1,
    summarize_session/1,
    summarize_session/2,
    get_summary/1,
    %% Message storage
    record_message/2,
    record_messages/2,
    get_session_messages/1,
    get_session_messages/2,
    %% Convenience
    session_count/0,
    message_count/1
]).

-export_type([
    session_meta/0,
    list_opts/0,
    message_opts/0,
    session_share/0,
    session_summary/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Session metadata stored in the sessions table.
-type session_meta() :: #{
    session_id := binary(),
    adapter => atom(),
    model => binary(),
    cwd => binary(),
    created_at => integer(),
    updated_at => integer(),
    message_count => non_neg_integer(),
    extra => map()
}.

-type session_share() :: #{
    share_id := binary(),
    session_id := binary(),
    created_at := integer(),
    status := active | revoked,
    revoked_at => integer()
}.

-type active_session_share() :: #{
    share_id := binary(),
    session_id := binary(),
    created_at := integer(),
    status := active
}.

-type session_summary() :: #{
    session_id := binary(),
    content := binary(),
    generated_at := integer(),
    message_count := non_neg_integer(),
    generated_by := binary()
}.

%% Options for list_sessions/1.
-type list_opts() :: #{
    adapter => atom(),
    cwd => binary(),
    model => binary(),
    limit => pos_integer(),
    since => integer()
}.

%% Options for get_session_messages/2.
-type message_opts() :: #{
    limit => pos_integer(),
    offset => non_neg_integer(),
    types => [beam_agent_core:message_type()],
    include_hidden => boolean()
}.

%% ETS table names.
-define(SESSIONS_TABLE, beam_agent_sessions).
-define(MESSAGES_TABLE, beam_agent_session_messages).
%% Counter table for message sequence numbers per session.
-define(COUNTERS_TABLE, beam_agent_session_counters).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure ETS tables exist. Idempotent -- safe to call multiple times.
Tables are named so any process can access them. Access mode is
resolved automatically by `beam_agent_ets`.
""".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SESSIONS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?MESSAGES_TABLE, [ordered_set, named_table,
        {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?COUNTERS_TABLE, [set, named_table]),
    ok.

-doc "Clear all session data. Deletes all entries from both tables.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?SESSIONS_TABLE),
    beam_agent_ets:delete_all_objects(?MESSAGES_TABLE),
    beam_agent_ets:delete_all_objects(?COUNTERS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Session Metadata
%%--------------------------------------------------------------------

-doc """
Register a new session with metadata.
If the session already exists, this is a no-op (use `update_session/2`
to modify existing sessions).
""".
-spec register_session(binary(), map()) -> ok.
register_session(SessionId, Meta) when is_binary(SessionId), is_map(Meta) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Entry = Meta#{
        session_id => SessionId,
        created_at => maps:get(created_at, Meta, Now),
        updated_at => Now,
        message_count => 0
    },
    %% insert_new: only insert if not already present
    beam_agent_ets:insert_new(?SESSIONS_TABLE, {SessionId, Entry}),
    ok.

-doc """
Update an existing session's metadata.
Merges the provided fields into the existing metadata.
Creates the session if it doesn't exist.
""".
-spec update_session(binary(), map()) -> ok.
update_session(SessionId, Updates) when is_binary(SessionId), is_map(Updates) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Existing}] ->
            Updated = maps:merge(Existing, Updates#{updated_at => Now}),
            beam_agent_ets:insert(?SESSIONS_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            register_session(SessionId, Updates)
    end.

-doc "Get metadata for a specific session.".
-spec get_session(binary()) -> {ok, session_meta()} | {error, not_found}.
get_session(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Meta}] -> {ok, Meta};
        [] -> {error, not_found}
    end.

-doc "Delete a session and all its messages.".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    beam_agent_ets:delete(?SESSIONS_TABLE, SessionId),
    beam_agent_ets:delete(?COUNTERS_TABLE, SessionId),
    %% Delete all messages for this session.
    %% Messages are keyed as {SessionId, Seq} in an ordered_set,
    %% so we can efficiently match on the prefix.
    delete_session_messages(SessionId),
    beam_agent_events:complete(SessionId),
    ok.

-doc "List all sessions. Equivalent to `list_sessions(#{})`.".
-spec list_sessions() -> {ok, [session_meta()]}.
list_sessions() ->
    list_sessions(#{}).

-doc """
List sessions with optional filters.
Filters: `adapter`, `cwd`, `model`, `limit`, `since` (unix ms timestamp).
Results are sorted by `updated_at` descending.
""".
-spec list_sessions(list_opts()) -> {ok, [session_meta()]}.
list_sessions(Opts) when is_map(Opts) ->
    ensure_tables(),
    All = ets:foldl(fun({_, Meta}, Acc) ->
        case matches_filters(Meta, Opts) of
            true -> [Meta | Acc];
            false -> Acc
        end
    end, [], ?SESSIONS_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0)
    end, All),
    Limited = case maps:get(limit, Opts, infinity) of
        infinity -> Sorted;
        N when is_integer(N), N > 0 -> lists:sublist(Sorted, N)
    end,
    {ok, Limited}.

-doc """
Create a fork of an existing session in the universal store.

Copies the tracked session metadata and all stored messages into a new
session id, preserving the source session in `extra.fork.parent_session_id`.
""".
-spec fork_session(binary(), map()) ->
    {ok, session_meta()} | {error, not_found}.
fork_session(SourceSessionId, Opts)
  when is_binary(SourceSessionId), is_map(Opts) ->
    case get_session(SourceSessionId) of
        {ok, Meta} ->
            IncludeHidden = maps:get(include_hidden, Opts, true),
            MessageOpts = case IncludeHidden of
                true -> #{include_hidden => true};
                false -> #{}
            end,
            {ok, Messages} = get_session_messages(SourceSessionId, MessageOpts),
            SessionId = maps:get(session_id, Opts, generate_session_id()),
            Now = erlang:system_time(millisecond),
            Extra0 = maps:get(extra, Meta, #{}),
            Extra1 = maps:merge(Extra0, maps:get(extra, Opts, #{})),
            ForkMeta = maps:without(
                [session_id, created_at, updated_at, message_count],
                Meta
            ),
            ForkExtra = Extra1#{
                fork => #{
                    parent_session_id => SourceSessionId,
                    forked_at => Now
                }
            },
            ok = register_session(SessionId, ForkMeta#{extra => ForkExtra}),
            ok = record_messages(SessionId, Messages),
            get_session(SessionId);
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Message Storage
%%--------------------------------------------------------------------

-doc """
Record a single message for a session.
The message is stored with an auto-incrementing sequence number
for ordering. Session metadata is auto-created if not present.
""".
-spec record_message(binary(), beam_agent_core:message()) -> ok.
record_message(SessionId, Message) when is_binary(SessionId), is_map(Message) ->
    ensure_tables(),
    Seq = beam_agent_ets:update_counter(?COUNTERS_TABLE, SessionId, {2, 1},
        {SessionId, 0}),
    beam_agent_ets:insert(?MESSAGES_TABLE, {{SessionId, Seq}, Message}),
    %% Update session metadata
    update_message_count(SessionId, Message),
    ok = publish_session_event(SessionId, Message),
    ok.

-doc "Record multiple messages for a session.".
-spec record_messages(binary(), [beam_agent_core:message()]) -> ok.
record_messages(SessionId, Messages)
  when is_binary(SessionId), is_list(Messages) ->
    lists:foreach(fun(Msg) ->
        record_message(SessionId, Msg)
    end, Messages),
    ok.

-doc "Get all messages for a session, in order. Equivalent to `get_session_messages(SessionId, #{})`.".
-spec get_session_messages(binary()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    get_session_messages(SessionId, #{}).

-doc """
Get messages for a session with options.

Options:
- `limit`: maximum number of messages
- `offset`: skip this many messages from the start
- `types`: only include messages of these types
""".
-spec get_session_messages(binary(), message_opts()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts)
  when is_binary(SessionId), is_map(Opts) ->
    ensure_tables(),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [] ->
            {error, not_found};
        _ ->
            Messages0 = collect_session_messages(SessionId),
            Messages = apply_session_view(SessionId, Messages0, Opts),
            Filtered = apply_message_filters(Messages, Opts),
            {ok, Filtered}
    end.

-doc """
Revert the visible conversation state to a prior message boundary.

Accepted selectors:
  - `#{visible_message_count => N}`
  - `#{message_id => Id}`
  - `#{uuid => Id}`

The underlying message store remains append-only. Revert changes the active
view by storing `extra.view.visible_message_count`.
""".
-spec revert_session(binary(), map()) ->
    {ok, session_meta()} | {error, not_found | invalid_selector}.
revert_session(SessionId, Selector)
  when is_binary(SessionId), is_map(Selector) ->
    case get_session_messages(SessionId, #{include_hidden => true}) of
        {ok, Messages} ->
            case select_visible_message_count(Messages, Selector) of
                {ok, VisibleCount} ->
                    update_session_extra(SessionId, fun(Extra0) ->
                        View0 = maps:get(view, Extra0, #{}),
                        Extra0#{view => View0#{
                            visible_message_count => VisibleCount,
                            reverted_at => erlang:system_time(millisecond),
                            selector => Selector
                        }}
                    end);
                {error, invalid_selector} ->
                    {error, invalid_selector}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc """
Clear any stored session revert state and restore the full visible history.
""".
-spec unrevert_session(binary()) ->
    {ok, session_meta()} | {error, not_found}.
unrevert_session(SessionId) when is_binary(SessionId) ->
    update_session_extra(SessionId, fun(Extra0) ->
        case maps:get(view, Extra0, undefined) of
            undefined ->
                Extra0;
            View0 when is_map(View0) ->
                View1 = maps:remove(visible_message_count,
                    maps:remove(selector, maps:remove(reverted_at, View0))),
                case map_size(View1) of
                    0 -> maps:remove(view, Extra0);
                    _ -> Extra0#{view => View1}
                end
        end
    end).

-doc "Generate or replace the share state for a session.".
-spec share_session(binary()) ->
    {ok, active_session_share()} | {error, not_found}.
share_session(SessionId) ->
    share_session(SessionId, #{}).

-spec share_session(binary(), map()) ->
    {ok, active_session_share()} | {error, not_found}.
share_session(SessionId, Opts) when is_binary(SessionId), is_map(Opts) ->
    case get_session(SessionId) of
        {ok, _Meta} ->
            Share = #{
                share_id => maps:get(share_id, Opts, generate_share_id()),
                session_id => SessionId,
                created_at => erlang:system_time(millisecond),
                status => active
            },
            case update_session_extra(SessionId, fun(Extra0) ->
                Extra0#{share => Share}
            end) of
                {ok, _} -> {ok, Share};
                {error, not_found} = Err -> Err
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Revoke the current share state for a session.".
-spec unshare_session(binary()) -> ok | {error, not_found}.
unshare_session(SessionId) when is_binary(SessionId) ->
    case get_share(SessionId) of
        {ok, Share} ->
            Revoked = Share#{
                status => revoked,
                revoked_at => erlang:system_time(millisecond)
            },
            case update_session_extra(SessionId, fun(Extra0) ->
                Extra0#{share => Revoked}
            end) of
                {ok, _} -> ok;
                {error, not_found} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

-doc "Get share state for a session.".
-spec get_share(binary()) -> {ok, session_share()} | {error, not_found}.
get_share(SessionId) when is_binary(SessionId) ->
    case get_session(SessionId) of
        {ok, Meta} ->
            Extra = maps:get(extra, Meta, #{}),
            case map_fetch(share, Extra) of
                {ok, Share} -> {ok, Share};
                error -> {error, not_found}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Generate and store a deterministic summary for a session.".
-spec summarize_session(binary()) ->
    {ok, session_summary()} | {error, not_found}.
summarize_session(SessionId) ->
    summarize_session(SessionId, #{}).

-spec summarize_session(binary(), map()) ->
    {ok, session_summary()} | {error, not_found}.
summarize_session(SessionId, Opts)
  when is_binary(SessionId), is_map(Opts) ->
    case get_session_messages(SessionId) of
        {ok, Messages} ->
            Summary = build_session_summary(SessionId, Messages, Opts),
            case update_session_extra(SessionId, fun(Extra0) ->
                Extra0#{summary => Summary}
            end) of
                {ok, _} -> {ok, Summary};
                {error, not_found} = Err -> Err
            end;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Get the stored session summary.".
-spec get_summary(binary()) -> {ok, session_summary()} | {error, not_found}.
get_summary(SessionId) when is_binary(SessionId) ->
    case get_session(SessionId) of
        {ok, Meta} ->
            Extra = maps:get(extra, Meta, #{}),
            case map_fetch(summary, Extra) of
                {ok, Summary} -> {ok, Summary};
                error -> {error, not_found}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc "Get the total number of tracked sessions.".
-spec session_count() -> non_neg_integer().
session_count() ->
    ensure_tables(),
    ets:info(?SESSIONS_TABLE, size).

-doc "Get the message count for a specific session.".
-spec message_count(binary()) -> non_neg_integer().
message_count(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    case ets:lookup(?COUNTERS_TABLE, SessionId) of
        [{_, Count}] -> Count;
        [] -> 0
    end.

%%--------------------------------------------------------------------
%% Internal: Filter Matching
%%--------------------------------------------------------------------

-spec matches_filters(session_meta(), list_opts()) -> boolean().
matches_filters(Meta, Opts) ->
    match_field(adapter, Meta, Opts) andalso
    match_field(cwd, Meta, Opts) andalso
    match_field(model, Meta, Opts) andalso
    match_since(Meta, Opts).

-spec match_field(atom(), session_meta(), list_opts()) -> boolean().
match_field(Key, Meta, Opts) ->
    case maps:find(Key, Opts) of
        {ok, Expected} ->
            maps:get(Key, Meta, undefined) =:= Expected;
        error ->
            true
    end.

-spec match_since(session_meta(), list_opts()) -> boolean().
match_since(Meta, Opts) ->
    case maps:find(since, Opts) of
        {ok, Since} ->
            maps:get(updated_at, Meta, 0) >= Since;
        error ->
            true
    end.

%%--------------------------------------------------------------------
%% Internal: Message Collection
%%--------------------------------------------------------------------

-spec collect_session_messages(binary()) -> [beam_agent_core:message()].
collect_session_messages(SessionId) ->
    %% ordered_set with {SessionId, Seq} keys gives us sorted order
    %% for free within a session prefix.
    StartKey = {SessionId, 0},
    collect_from(StartKey, SessionId, []).

-spec publish_session_event(binary(), beam_agent_core:message()) -> ok.
publish_session_event(SessionId, Message) ->
    beam_agent_events:publish(SessionId, Message),
    case is_terminal_event(Message) of
        true ->
            beam_agent_events:complete(SessionId);
        false ->
            ok
    end.

-spec is_terminal_event(beam_agent_core:message()) -> boolean().
is_terminal_event(#{type := result}) ->
    true;
is_terminal_event(#{type := error, is_error := false}) ->
    false;
is_terminal_event(#{type := error}) ->
    true;
is_terminal_event(_) ->
    false.

-spec collect_from(term(), binary(), [beam_agent_core:message()]) ->
    [beam_agent_core:message()].
collect_from(Key, SessionId, Acc) ->
    case ets:next(?MESSAGES_TABLE, Key) of
        '$end_of_table' ->
            lists:reverse(Acc);
        {SessionId, _Seq} = NextKey ->
            case ets:lookup(?MESSAGES_TABLE, NextKey) of
                [{_, Msg}] ->
                    collect_from(NextKey, SessionId, [Msg | Acc]);
                [] ->
                    collect_from(NextKey, SessionId, Acc)
            end;
        _OtherSession ->
            %% Moved past our session's prefix
            lists:reverse(Acc)
    end.

-spec apply_message_filters([beam_agent_core:message()], message_opts()) ->
    [beam_agent_core:message()].
apply_message_filters(Messages, Opts) ->
    M1 = case maps:find(types, Opts) of
        {ok, Types} when is_list(Types) ->
            [M || #{type := T} = M <- Messages, lists:member(T, Types)];
        _ ->
            Messages
    end,
    M2 = case maps:find(offset, Opts) of
        {ok, Offset} when is_integer(Offset), Offset > 0 ->
            lists:nthtail(min(Offset, length(M1)), M1);
        _ ->
            M1
    end,
    case maps:find(limit, Opts) of
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            lists:sublist(M2, Limit);
        _ ->
            M2
    end.

-spec apply_session_view(binary(), [beam_agent_core:message()], message_opts()) ->
    [beam_agent_core:message()].
apply_session_view(SessionId, Messages, Opts) ->
    case maps:get(include_hidden, Opts, false) of
        true ->
            Messages;
        false ->
            case current_visible_count(SessionId) of
                undefined -> Messages;
                VisibleCount when is_integer(VisibleCount), VisibleCount >= 0 ->
                    lists:sublist(Messages, VisibleCount)
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Session Metadata Updates
%%--------------------------------------------------------------------

-spec update_message_count(binary(), beam_agent_core:message()) -> ok.
update_message_count(SessionId, Message) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Existing}] ->
            Count = maps:get(message_count, Existing, 0) + 1,
            Updates = #{message_count => Count, updated_at => Now},
            %% Extract model from system init or result messages
            Updates2 = maybe_extract_model(Message, Updates),
            Updated = maps:merge(Existing, Updates2),
            beam_agent_ets:insert(?SESSIONS_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            %% Auto-create session entry if not registered
            Meta = maybe_extract_model(Message,
                #{message_count => 1, updated_at => Now}),
            register_session(SessionId, Meta)
    end.

-spec maybe_extract_model(beam_agent_core:message(), map()) -> map().
maybe_extract_model(#{type := system, system_info := #{model := Model}}, Acc)
  when is_binary(Model) ->
    Acc#{model => Model};
maybe_extract_model(#{model := Model}, Acc) when is_binary(Model) ->
    Acc#{model => Model};
maybe_extract_model(_, Acc) ->
    Acc.

-spec current_visible_count(binary()) -> non_neg_integer() | undefined.
current_visible_count(SessionId) ->
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Meta}] ->
            Extra = maps:get(extra, Meta, #{}),
            View = maps:get(view, Extra, #{}),
            maps:get(visible_message_count, View, undefined);
        [] ->
            undefined
    end.

-spec update_session_extra(binary(), fun((map()) -> map())) ->
    {ok, session_meta()} | {error, not_found}.
update_session_extra(SessionId, Fun)
  when is_binary(SessionId), is_function(Fun, 1) ->
    case get_session(SessionId) of
        {ok, Meta} ->
            Extra0 = maps:get(extra, Meta, #{}),
            Extra1 = Fun(Extra0),
            ok = update_session(SessionId, #{extra => Extra1}),
            get_session(SessionId);
        {error, not_found} ->
            {error, not_found}
    end.

-spec select_visible_message_count([beam_agent_core:message()], map()) ->
    {ok, non_neg_integer()} | {error, invalid_selector}.
select_visible_message_count(Messages, #{visible_message_count := Count})
  when is_integer(Count), Count >= 0 ->
    {ok, min(Count, length(Messages))};
select_visible_message_count(Messages, #{message_id := MessageId})
  when is_binary(MessageId) ->
    select_visible_message_count(Messages, #{uuid => MessageId});
select_visible_message_count(Messages, #{uuid := MessageId})
  when is_binary(MessageId) ->
    find_message_boundary(Messages, MessageId, 1);
select_visible_message_count(_Messages, _Selector) ->
    {error, invalid_selector}.

-spec find_message_boundary([beam_agent_core:message()], binary(), pos_integer()) ->
    {ok, non_neg_integer()} | {error, invalid_selector}.
find_message_boundary([], _MessageId, _Index) ->
    {error, invalid_selector};
find_message_boundary([Message | Rest], MessageId, Index) ->
    case message_matches(Message, MessageId) of
        true -> {ok, Index};
        false -> find_message_boundary(Rest, MessageId, Index + 1)
    end.

-spec message_matches(beam_agent_core:message(), binary()) -> boolean().
message_matches(Message, MessageId) ->
    maps:get(uuid, Message, undefined) =:= MessageId orelse
    maps:get(message_id, Message, undefined) =:= MessageId.

-spec build_session_summary(binary(), [beam_agent_core:message()], map()) ->
    session_summary().
build_session_summary(SessionId, Messages, Opts) ->
    Now = erlang:system_time(millisecond),
    Content = case maps:get(content, Opts, maps:get(summary, Opts, undefined)) of
        Summary when is_binary(Summary), Summary =/= <<>> ->
            Summary;
        _ ->
            derive_summary_content(Messages)
    end,
    #{
        content => Content,
        generated_at => Now,
        message_count => length(Messages),
        generated_by => maps:get(generated_by, Opts, <<"beam_agent_core">>),
        session_id => SessionId
    }.

-spec derive_summary_content([beam_agent_core:message()]) -> binary().
derive_summary_content(Messages) ->
    UserPreview = first_message_content(Messages, user),
    AssistantPreview = last_message_content(Messages, result, assistant),
    iolist_to_binary([
        <<"Conversation summary\n">>,
        <<"Messages: ">>, integer_to_binary(length(Messages)), <<"\n">>,
        <<"First user message: ">>, truncate_binary(UserPreview, 240), <<"\n">>,
        <<"Latest agent output: ">>, truncate_binary(AssistantPreview, 240)
    ]).

-spec first_message_content([beam_agent_core:message()], beam_agent_core:message_type()) -> binary().
first_message_content(Messages, Type) ->
    case lists:dropwhile(fun(M) -> maps:get(type, M, raw) =/= Type end, Messages) of
        [Message | _] -> to_binary_content(Message);
        [] -> <<>>
    end.

-spec last_message_content([beam_agent_core:message()], beam_agent_core:message_type(),
                           beam_agent_core:message_type()) -> binary().
last_message_content(Messages, PrimaryType, FallbackType) ->
    case lists:reverse(Messages) of
        Reversed ->
            case lists:dropwhile(fun(M) ->
                Type = maps:get(type, M, raw),
                Type =/= PrimaryType andalso Type =/= FallbackType
            end, Reversed) of
                [Message | _] -> to_binary_content(Message);
                [] -> <<>>
            end
    end.

-spec to_binary_content(beam_agent_core:message()) -> binary().
to_binary_content(Message) ->
    case maps:get(content, Message, undefined) of
        Content when is_binary(Content) ->
            Content;
        Content when is_list(Content) ->
            unicode:characters_to_binary(Content);
        undefined ->
            <<>>;
        Other ->
            unicode:characters_to_binary(io_lib:format("~p", [Other]))
    end.

truncate_binary(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncate_binary(Bin, Max) when is_binary(Bin), Max > 3 ->
    PrefixSize = Max - 3,
    <<Prefix:PrefixSize/binary, _/binary>> = Bin,
    <<Prefix/binary, "...">>;
truncate_binary(_Bin, _Max) ->
    <<>>.

-spec map_fetch(share | summary, map()) -> {ok, term()} | error.
map_fetch(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {ok, Value};
        error -> error
    end.

generate_session_id() ->
    Hex = binary:encode_hex(rand:bytes(8), lowercase),
    <<"sess_", Hex/binary>>.

generate_share_id() ->
    Hex = binary:encode_hex(rand:bytes(8), lowercase),
    <<"share_", Hex/binary>>.

%%--------------------------------------------------------------------
%% Internal: Message Deletion
%%--------------------------------------------------------------------

-spec delete_session_messages(binary()) -> ok.
delete_session_messages(SessionId) ->
    StartKey = {SessionId, 0},
    delete_from(StartKey, SessionId).

-spec delete_from({binary(), 0}, binary()) -> ok.
delete_from(Key, SessionId) ->
    case ets:next(?MESSAGES_TABLE, Key) of
        '$end_of_table' ->
            ok;
        {SessionId, _Seq} = NextKey ->
            beam_agent_ets:delete(?MESSAGES_TABLE, NextKey),
            delete_from(Key, SessionId);
        _OtherSession ->
            ok
    end.
