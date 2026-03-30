-module(beam_agent_journal_core).
-moduledoc """
Canonical durable event journal for BeamAgent.

The journal persists normalized BeamAgent domain events for replay, audit, and
cross-cutting orchestration. It complements the live event bus:

- `beam_agent_events` delivers transient subscriber messages in real time
- `beam_agent_journal_core` stores append-only domain events for later replay

This module is intentionally process-free. It validates and normalizes journal
entries, assigns durable ids and monotonic replay cursors, and delegates raw
persistence to `beam_agent_journal_store`.
""".

-export([
    ensure_tables/0,
    clear/0,
    append/2,
    list/0,
    list/1,
    stream_from/1,
    stream_from/2,
    get/1,
    ack/2,
    get_ack/2,
    list_acks/1
]).

-export_type([
    event_type/0,
    tag/0,
    event_input/0,
    event_filter/0,
    entry/0
]).

-type event_type() :: beam_agent_journal_store:event_type().
-type tag() :: beam_agent_journal_store:tag().
-type entry() :: beam_agent_journal_store:event_record().

-type event_input() :: #{
    event_id => binary(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    timestamp => integer(),
    tags => [tag()],
    payload => map()
}.

-type event_filter() :: #{
    event_id => binary(),
    event_type => event_type(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    tag => tag(),
    since => integer(),
    limit => pos_integer()
}.

-type normalized_input() :: #{
    payload := map(),
    tags := [tag()],
    timestamp => integer(),
    event_id => binary(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary()
}.
-type journal_optional_key() ::
    event_id | event_type | limit | run_id | session_id | since | tag | thread_id |
    timestamp.
-type journal_put_map() ::
    event_filter()
  | normalized_input()
  | entry()
  | #{
        payload := map(),
        sequence => integer(),
        tags := [tag()]
    }.

-doc "Ensure the journal ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_journal_store:ensure_tables().

-doc "Clear all journal state. Intended for tests and full in-memory resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_journal_store:clear().

-doc """
Append a normalized BeamAgent domain event to the durable journal.

`EventType` identifies the kind of event, while `Event` carries envelope data:
`session_id`, `thread_id`, `run_id`, `tags`, `timestamp`, and a `payload` map.
""".
-spec append(event_type(), event_input()) ->
    {ok, entry()} |
    {error, already_exists | session_id_required_for_thread |
        {invalid_event_type, term()} | {unsupported_event_key, atom()} |
        {invalid_event, atom()}}.
append(EventType, Event) when is_map(Event) ->
    ensure_tables(),
    TeleMeta = telemetry_event_meta(EventType, Event),
    StartTime = telemetry_start(append, TeleMeta),
    Result = case normalize_event_type(EventType) of
        ok ->
            case normalize_event(Event) of
                {ok, Normalized} ->
                    Timestamp = maps:get(timestamp, Normalized,
                        erlang:system_time(millisecond)),
                    Sequence = erlang:unique_integer([monotonic, positive]),
                    EventId = maps:get(event_id, Normalized, generate_event_id()),
                    Entry0 = #{
                        event_id => EventId,
                        event_type => EventType,
                        sequence => Sequence,
                        timestamp => Timestamp,
                        payload => maps:get(payload, Normalized),
                        tags => maps:get(tags, Normalized)
                    },
                    Entry1 = maybe_put(session_id,
                        maps:get(session_id, Normalized, undefined), Entry0),
                    Entry2 = maybe_put(thread_id,
                        maps:get(thread_id, Normalized, undefined), Entry1),
                    Entry3 = maybe_put(run_id,
                        maps:get(run_id, Normalized, undefined), Entry2),
                    case beam_agent_journal_store:insert_event(Entry3) of
                        true -> {ok, Entry3};
                        false -> {error, already_exists}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end,
    case Result of
        {ok, JournalEntry} ->
            telemetry_stop(append, StartTime, telemetry_entry_meta(JournalEntry)),
            {ok, JournalEntry};
        {error, _} = ErrorResult ->
            telemetry_exception(append, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc "List all journal entries, oldest first.".
-spec list() -> {ok, [entry()]}.
list() ->
    list(#{}).

-doc """
List journal entries with exact-match scope and type filters.

Supported filters:
  - `event_id`
  - `event_type`
  - `session_id`
  - `thread_id`
  - `run_id`
  - `tag`
  - `since`
  - `limit`
""".
-spec list(event_filter()) ->
    {ok, [entry()]} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
list(Filter) when is_map(Filter) ->
    TeleMeta = telemetry_filter_meta(Filter),
    StartTime = telemetry_start(list, TeleMeta),
    case normalize_filter(Filter) of
        {ok, Normalized} ->
            {ok, Entries} = Result = beam_agent_journal_store:list_events(Normalized),
            telemetry_stop(list, StartTime, TeleMeta#{result_count => length(Entries)}),
            Result;
        {error, _} = Error ->
            telemetry_exception(list, Error, TeleMeta),
            Error
    end.

-doc "Replay journal entries after the given cursor, oldest first.".
-spec stream_from(non_neg_integer()) ->
    {ok, [entry()]} | {error, {invalid_cursor, term()}}.
stream_from(Cursor) ->
    stream_from(Cursor, #{}).

-doc """
Replay journal entries after the given cursor with additional exact-match
filters.

The cursor is the `sequence` field from the last seen journal entry. Passing
`0` replays from the beginning.
""".
-spec stream_from(non_neg_integer(), event_filter()) ->
    {ok, [entry()]} |
    {error, {invalid_cursor, term()} | {unsupported_filter, atom()} |
        {invalid_filter, atom()}}.
stream_from(Cursor, Filter) when is_integer(Cursor), Cursor >= 0, is_map(Filter) ->
    TeleMeta = (telemetry_filter_meta(Filter))#{cursor => Cursor},
    StartTime = telemetry_start(stream_from, TeleMeta),
    case normalize_filter(Filter) of
        {ok, Normalized} ->
            {ok, Entries} = Result =
                beam_agent_journal_store:list_events(Normalized#{after_sequence => Cursor}),
            telemetry_stop(stream_from, StartTime, TeleMeta#{result_count => length(Entries)}),
            Result;
        {error, _} = Error ->
            telemetry_exception(stream_from, Error, TeleMeta),
            Error
    end;
stream_from(Cursor, _Filter) ->
    {error, {invalid_cursor, Cursor}}.

-doc "Fetch a journal entry by id.".
-spec get(binary()) -> {ok, entry()} | {error, not_found}.
get(EventId) when is_binary(EventId) ->
    StartTime = telemetry_start(get, #{event_id => EventId}),
    case beam_agent_journal_store:get_event(EventId) of
        {ok, Entry} = Result ->
            telemetry_stop(get, StartTime, (telemetry_entry_meta(Entry))#{found => true}),
            Result;
        {error, not_found} = Error ->
            telemetry_stop(get, StartTime, #{event_id => EventId, found => false}),
            Error
    end.

-doc "Acknowledge a journal entry for a consumer id. Idempotent.".
-spec ack(binary(), binary()) -> ok | {error, not_found}.
ack(ConsumerId, EventId) when is_binary(ConsumerId), is_binary(EventId) ->
    StartTime = telemetry_start(ack, #{consumer_id => ConsumerId, event_id => EventId}),
    case beam_agent_journal_store:ack_event(
        ConsumerId,
        EventId,
        erlang:system_time(millisecond)
    ) of
        ok = Result ->
            telemetry_stop(ack, StartTime, #{consumer_id => ConsumerId, event_id => EventId}),
            Result;
        {error, not_found} = Error ->
            telemetry_stop(ack, StartTime,
                #{consumer_id => ConsumerId, event_id => EventId, found => false}),
            Error
    end.

-doc "Fetch an ack record for a consumer and event.".
-spec get_ack(binary(), binary()) -> {ok, map()} | {error, not_found}.
get_ack(ConsumerId, EventId)
  when is_binary(ConsumerId), is_binary(EventId) ->
    beam_agent_journal_store:get_ack(ConsumerId, EventId).

-doc "List all ack records for a consumer, newest first.".
-spec list_acks(binary()) -> {ok, [map()]}.
list_acks(ConsumerId) when is_binary(ConsumerId) ->
    beam_agent_journal_store:list_acks(ConsumerId).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec normalize_event_type(atom() | binary()) -> ok | {error, {invalid_event_type, binary()}}.
normalize_event_type(EventType) when is_atom(EventType) ->
    ok;
normalize_event_type(EventType) when is_binary(EventType), byte_size(EventType) > 0 ->
    ok;
normalize_event_type(EventType) ->
    {error, {invalid_event_type, EventType}}.

-spec normalize_event(map()) ->
    {ok, normalized_input()} |
    {error, session_id_required_for_thread | {unsupported_event_key, atom()} |
        {invalid_event, atom()}}.
normalize_event(Event) when is_map(Event) ->
    Allowed = [event_id, session_id, thread_id, run_id, timestamp, tags, payload],
    case validate_allowed_keys(Event, Allowed) of
        ok ->
            case normalize_optional_binary(event_id, Event) of
                {ok, EventId} ->
                    case normalize_optional_binary(session_id, Event) of
                        {ok, SessionId} ->
                            case normalize_optional_binary(thread_id, Event) of
                                {ok, ThreadId} ->
                                    case normalize_optional_binary(run_id, Event) of
                                        {ok, RunId} ->
                                            case normalize_timestamp(Event) of
                                                {ok, Timestamp} ->
                                                    case normalize_tags(Event) of
                                                        {ok, Tags} ->
                                                            case normalize_payload(Event) of
                                                                {ok, Payload} ->
                                                                    case require_session_for_thread(
                                                                        SessionId, ThreadId) of
                                                                        ok ->
                                                                            Normalized0 = #{
                                                                                payload => Payload,
                                                                                tags => Tags
                                                                            },
                                                                            Normalized1 = maybe_put(
                                                                                event_id,
                                                                                EventId,
                                                                                Normalized0),
                                                                            Normalized2 = maybe_put(
                                                                                session_id,
                                                                                SessionId,
                                                                                Normalized1),
                                                                            Normalized3 = maybe_put(
                                                                                thread_id,
                                                                                ThreadId,
                                                                                Normalized2),
                                                                            Normalized4 = maybe_put(
                                                                                run_id,
                                                                                RunId,
                                                                                Normalized3),
                                                                            {ok, maybe_put(
                                                                                timestamp,
                                                                                Timestamp,
                                                                                Normalized4)};
                                                                        Error ->
                                                                            Error
                                                                    end;
                                                                Error ->
                                                                    Error
                                                            end;
                                                        Error ->
                                                            Error
                                                    end;
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

-spec normalize_filter(map()) ->
    {ok, event_filter()} |
    {error, {unsupported_filter, atom()} | {invalid_filter, atom()}}.
normalize_filter(Filter) when is_map(Filter) ->
    Allowed = [event_id, event_type, session_id, thread_id, run_id, tag, since, limit],
    case validate_allowed_filter_keys(Filter, Allowed) of
        ok ->
            case normalize_optional_filter_binary(event_id, Filter) of
                {ok, EventId} ->
                    case normalize_optional_filter_event_type(Filter) of
                        {ok, EventType} ->
                            case normalize_optional_filter_binary(session_id, Filter) of
                                {ok, SessionId} ->
                                    case normalize_optional_filter_binary(thread_id, Filter) of
                                        {ok, ThreadId} ->
                                            case normalize_optional_filter_binary(run_id, Filter) of
                                                {ok, RunId} ->
                                                    case normalize_optional_filter_tag(Filter) of
                                                        {ok, Tag} ->
                                                            case normalize_limit(Filter) of
                                                                {ok, Limit} ->
                                                                    case normalize_since(Filter) of
                                                                        {ok, Since} ->
                                                                            case require_session_for_thread(
                                                                                SessionId, ThreadId) of
                                                                                ok ->
                                                                                    Normalized0 = #{},
                                                                                    Normalized1 =
                                                                                        maybe_put(
                                                                                            event_id,
                                                                                            EventId,
                                                                                            Normalized0),
                                                                                    Normalized2 =
                                                                                        maybe_put(
                                                                                            event_type,
                                                                                            EventType,
                                                                                            Normalized1),
                                                                                    Normalized3 =
                                                                                        maybe_put(
                                                                                            session_id,
                                                                                            SessionId,
                                                                                            Normalized2),
                                                                                    Normalized4 =
                                                                                        maybe_put(
                                                                                            thread_id,
                                                                                            ThreadId,
                                                                                            Normalized3),
                                                                                    Normalized5 =
                                                                                        maybe_put(
                                                                                            run_id,
                                                                                            RunId,
                                                                                            Normalized4),
                                                                                    Normalized6 =
                                                                                        maybe_put(
                                                                                            tag,
                                                                                            Tag,
                                                                                            Normalized5),
                                                                                    Normalized7 =
                                                                                        maybe_put(
                                                                                            since,
                                                                                            Since,
                                                                                            Normalized6),
                                                                                    {ok, maybe_put(
                                                                                        limit,
                                                                                        Limit,
                                                                                        Normalized7)};
                                                                                Error ->
                                                                                    Error
                                                                            end;
                                                                        Error ->
                                                                            Error
                                                                    end;
                                                                Error ->
                                                                    Error
                                                            end;
                                                        Error ->
                                                            Error
                                                    end;
                                                Error ->
                                                    Error
                                            end;
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

-spec normalize_optional_binary(event_id | run_id | session_id | thread_id, map()) ->
    {ok, binary() | undefined} |
    {error, {invalid_event, event_id | run_id | session_id | thread_id}}.
normalize_optional_binary(Key, Map) ->
    case maps:find(Key, Map) of
        error ->
            {ok, undefined};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_event, Key}}
    end.

-spec normalize_timestamp(map()) ->
    {ok, integer() | undefined} | {error, {invalid_event, timestamp}}.
normalize_timestamp(Map) ->
    case maps:find(timestamp, Map) of
        error ->
            {ok, undefined};
        {ok, Timestamp} when is_integer(Timestamp) ->
            {ok, Timestamp};
        {ok, _Other} ->
            {error, {invalid_event, timestamp}}
    end.

-spec normalize_tags(map()) -> {ok, [tag()]} | {error, {invalid_event, tags}}.
normalize_tags(Map) ->
    case maps:find(tags, Map) of
        error ->
            {ok, []};
        {ok, Tags} when is_list(Tags) ->
            case lists:all(fun(Tag) -> is_atom(Tag) orelse is_binary(Tag) end, Tags) of
                true -> {ok, Tags};
                false -> {error, {invalid_event, tags}}
            end;
        {ok, _Other} ->
            {error, {invalid_event, tags}}
    end.

-spec normalize_payload(map()) -> {ok, map()} | {error, {invalid_event, payload}}.
normalize_payload(Map) ->
    case maps:find(payload, Map) of
        error ->
            {ok, #{}};
        {ok, Payload} when is_map(Payload) ->
            {ok, Payload};
        {ok, _Other} ->
            {error, {invalid_event, payload}}
    end.

-spec require_session_for_thread(binary() | undefined, binary() | undefined) ->
    ok | {error, session_id_required_for_thread}.
require_session_for_thread(undefined, ThreadId) when is_binary(ThreadId) ->
    {error, session_id_required_for_thread};
require_session_for_thread(_SessionId, _ThreadId) ->
    ok.

-spec validate_allowed_keys(map(), [atom()]) ->
    ok | {error, {unsupported_event_key, atom()}}.
validate_allowed_keys(Map, Allowed) ->
    Keys = maps:keys(Map),
    case [Key || Key <- Keys, not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [BadKey | _] ->
            {error, {unsupported_event_key, BadKey}}
    end.

-spec validate_allowed_filter_keys(map(), [atom()]) ->
    ok | {error, {unsupported_filter, atom()}}.
validate_allowed_filter_keys(Map, Allowed) ->
    Keys = maps:keys(Map),
    case [Key || Key <- Keys, not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [BadKey | _] ->
            {error, {unsupported_filter, BadKey}}
    end.

-spec normalize_optional_filter_binary(event_id | run_id | session_id | thread_id, map()) ->
    {ok, binary() | undefined} |
    {error, {invalid_filter, event_id | run_id | session_id | thread_id}}.
normalize_optional_filter_binary(Key, Filter) ->
    case maps:find(Key, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_filter, Key}}
    end.

-spec normalize_optional_filter_event_type(map()) ->
    {ok, event_type() | undefined} | {error, {invalid_filter, event_type}}.
normalize_optional_filter_event_type(Filter) ->
    case maps:find(event_type, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} when is_atom(Value) ->
            {ok, Value};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_filter, event_type}}
    end.

-spec normalize_optional_filter_tag(map()) ->
    {ok, tag() | undefined} | {error, {invalid_filter, tag}}.
normalize_optional_filter_tag(Filter) ->
    case maps:find(tag, Filter) of
        error ->
            {ok, undefined};
        {ok, Value} when is_atom(Value); is_binary(Value) ->
            {ok, Value};
        {ok, _Other} ->
            {error, {invalid_filter, tag}}
    end.

-spec normalize_limit(map()) ->
    {ok, pos_integer() | undefined} | {error, {invalid_filter, limit}}.
normalize_limit(Filter) ->
    case maps:find(limit, Filter) of
        error ->
            {ok, undefined};
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            {ok, Limit};
        {ok, _Other} ->
            {error, {invalid_filter, limit}}
    end.

-spec normalize_since(map()) ->
    {ok, integer() | undefined} | {error, {invalid_filter, since}}.
normalize_since(Filter) ->
    case maps:find(since, Filter) of
        error ->
            {ok, undefined};
        {ok, Since} when is_integer(Since) ->
            {ok, Since};
        {ok, _Other} ->
            {error, {invalid_filter, since}}
    end.

-spec maybe_put(journal_optional_key(), term(), journal_put_map()) -> journal_put_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec telemetry_start(ack | append | get | list | stream_from, map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry:span_start(journal, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(ack | append | get | list | stream_from, integer(), map()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry:span_stop(journal, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(append | list | stream_from,
    {error,
        already_exists
      | session_id_required_for_thread
      | {invalid_event, event_id | payload | run_id | session_id | tags | thread_id | timestamp}
      | {invalid_event_type, binary()}
      | {invalid_filter, event_id | event_type | limit | run_id | session_id | since |
            tag | thread_id}}, map()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry:span_exception(journal, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_event_meta(event_type(), map()) -> map().
telemetry_event_meta(EventType, Event) ->
    maps:merge(#{event_type => EventType},
        maps:with([event_id, session_id, thread_id, run_id], Event)).

-spec telemetry_filter_meta(map()) -> map().
telemetry_filter_meta(Filter) ->
    maps:with([event_id, event_type, session_id, thread_id, run_id, since, limit], Filter).

-spec telemetry_entry_meta(entry()) -> map().
telemetry_entry_meta(Entry) ->
    maps:with([event_id, event_type, sequence, session_id, thread_id, run_id], Entry).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).

-spec generate_event_id() -> <<_:48, _:_*8>>.
generate_event_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<"event_", Hex/binary>>.
