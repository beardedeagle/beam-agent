-module(beam_agent_journal_store).
-moduledoc """
Internal store-backed persistence for the BeamAgent durable event journal.

The journal is append-only domain event storage. This module owns the raw
persistence tables and ordered replay mechanics; it intentionally does not
normalize inputs or decide which domains should emit which events. Those
concerns live in `beam_agent_journal_core` and the calling domain modules.

The default adapter remains process-free ETS via `beam_agent_store_ets`, so
the same code works in both public and hardened table-access modes.
""".

-export([
    ensure_tables/0,
    clear/0,
    insert_event/1,
    get_event/1,
    list_events/1,
    ack_event/3,
    get_ack/2,
    list_acks/1
]).

-export_type([
    event_type/0,
    tag/0,
    event_record/0,
    event_filter/0
]).

-type event_type() :: atom() | binary().
-type tag() :: atom() | binary().

-type event_record() :: #{
    event_id := binary(),
    event_type := event_type(),
    sequence := pos_integer(),
    timestamp := integer(),
    payload := map(),
    tags := [tag()],
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.

-type event_filter() :: #{
    event_id => binary(),
    event_type => event_type(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    tag => tag(),
    since => integer(),
    limit => pos_integer(),
    after_sequence => non_neg_integer()
}.

-define(EVENTS_TABLE, beam_agent_journal_events).
-define(SEQUENCE_TABLE, beam_agent_journal_sequence).
-define(ACKS_TABLE, beam_agent_journal_acks).
-define(STORE_DOMAIN, journal).

-doc "Ensure the journal ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?EVENTS_TABLE, [set,
        named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?SEQUENCE_TABLE, [ordered_set,
        named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?ACKS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear all journal events and acknowledgements.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?EVENTS_TABLE),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?SEQUENCE_TABLE),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?ACKS_TABLE),
    ok.

-doc "Insert a new journal event. Returns false when the event_id already exists.".
-spec insert_event(event_record()) -> boolean().
insert_event(#{event_id := EventId, sequence := Sequence} = Entry)
  when is_binary(EventId), is_integer(Sequence), Sequence > 0 ->
    ensure_tables(),
    case beam_agent_store:insert_new(?STORE_DOMAIN, ?EVENTS_TABLE,
        {EventId, Entry}) of
        true ->
            true = beam_agent_store:insert_new(?STORE_DOMAIN, ?SEQUENCE_TABLE,
                {Sequence, EventId}),
            true;
        false ->
            false
    end.

-doc "Fetch a journal event by id.".
-spec get_event(binary()) -> {ok, event_record()} | {error, not_found}.
get_event(EventId) when is_binary(EventId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?EVENTS_TABLE, EventId) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-doc "List journal events in ascending sequence order using an already-normalized filter.".
-spec list_events(event_filter()) -> {ok, [event_record()]}.
list_events(Filter) when is_map(Filter) ->
    ensure_tables(),
    Limit = maps:get(limit, Filter, infinity),
    StartKey = start_key(Filter),
    Entries = collect_events(StartKey, Filter, Limit, []),
    {ok, lists:reverse(Entries)}.

-doc "Record a consumer acknowledgement for an existing event. Idempotent.".
-spec ack_event(binary(), binary(), integer()) -> ok | {error, not_found}.
ack_event(ConsumerId, EventId, AcknowledgedAt)
  when is_binary(ConsumerId), is_binary(EventId),
       is_integer(AcknowledgedAt) ->
    ensure_tables(),
    case get_event(EventId) of
        {ok, _Entry} ->
            Ack = #{
                consumer_id => ConsumerId,
                event_id => EventId,
                acknowledged_at => AcknowledgedAt
            },
            _ = beam_agent_store:insert_new(?STORE_DOMAIN, ?ACKS_TABLE,
                {{ConsumerId, EventId}, Ack}),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Fetch a single ack record for a consumer and event.".
-spec get_ack(binary(), binary()) -> {ok, map()} | {error, not_found}.
get_ack(ConsumerId, EventId)
  when is_binary(ConsumerId), is_binary(EventId) ->
    ensure_tables(),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?ACKS_TABLE,
        {ConsumerId, EventId}) of
        [{_, Ack}] -> {ok, Ack};
        [] -> {error, not_found}
    end.

-doc "List all ack records for a consumer, newest first.".
-spec list_acks(binary()) -> {ok, [map()]}.
list_acks(ConsumerId) when is_binary(ConsumerId) ->
    ensure_tables(),
    %% Use match_object for ETS-side prefix filtering instead of a full
    %% Erlang-side foldl scan over the entire acks table.
    Matches = beam_agent_ets:match_object(?ACKS_TABLE,
                                          {{ConsumerId, '_'}, '_'}),
    Acks = [Ack || {_Key, Ack} <- Matches],
    Sorted = lists:sort(fun(A, B) ->
        maps:get(acknowledged_at, A, 0) >= maps:get(acknowledged_at, B, 0)
    end, Acks),
    {ok, Sorted}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec start_key(event_filter()) -> '$end_of_table' | pos_integer().
start_key(Filter) ->
    case maps:get(after_sequence, Filter, undefined) of
        undefined ->
            beam_agent_store:first(?STORE_DOMAIN, ?SEQUENCE_TABLE);
        0 ->
            beam_agent_store:first(?STORE_DOMAIN, ?SEQUENCE_TABLE);
        After when is_integer(After), After >= 0 ->
            beam_agent_store:next(?STORE_DOMAIN, ?SEQUENCE_TABLE, After)
    end.

-spec collect_events('$end_of_table' | pos_integer(), event_filter(),
    infinity | pos_integer(), [event_record()]) -> [event_record()].
collect_events('$end_of_table', _Filter, _Limit, Acc) ->
    Acc;
collect_events(_Key, _Filter, 0, Acc) ->
    Acc;
collect_events(Sequence, Filter, Limit, Acc) when is_integer(Sequence), Sequence > 0 ->
    NextKey = beam_agent_store:next(?STORE_DOMAIN, ?SEQUENCE_TABLE, Sequence),
    {NextAcc, Matched} = case lookup_sequence_event(Sequence) of
        {ok, Entry} ->
            case matches_filters(Entry, Filter) of
                true -> {[Entry | Acc], 1};
                false -> {Acc, 0}
            end;
        {error, not_found} ->
            {Acc, 0}
    end,
    NextLimit = decrement_limit(Limit, Matched),
    collect_events(NextKey, Filter, NextLimit, NextAcc).

-spec lookup_sequence_event(pos_integer()) -> {ok, event_record()} | {error, not_found}.
lookup_sequence_event(Sequence) ->
    case beam_agent_store:lookup(?STORE_DOMAIN, ?SEQUENCE_TABLE, Sequence) of
        [{_, EventId}] ->
            get_event(EventId);
        [] ->
            {error, not_found}
    end.

-spec matches_filters(event_record(), event_filter()) -> boolean().
matches_filters(Entry, Filter) ->
    lists:all(fun
        ({limit, _}) ->
            true;
        ({after_sequence, _}) ->
            true;
        ({since, Since}) ->
            maps:get(timestamp, Entry, 0) >= Since;
        ({tag, Tag}) ->
            lists:member(Tag, maps:get(tags, Entry, []));
        ({Key, Value}) ->
            maps:get(Key, Entry, undefined) =:= Value
    end, maps:to_list(Filter)).

-spec decrement_limit(infinity | pos_integer(), 0 | 1) -> infinity | non_neg_integer().
decrement_limit(infinity, _Matched) ->
    infinity;
decrement_limit(Limit, 0) ->
    Limit;
decrement_limit(Limit, 1) when is_integer(Limit), Limit > 0 ->
    Limit - 1.
