-module(beam_agent_audit_core).
-moduledoc """
Canonical audit accessors and emitters for BeamAgent.

Audit records are stored in the durable journal rather than a second bespoke
store. This keeps replay, scoping, and cursor semantics consistent with the
rest of the BeamAgent substrate.
""".

-export([
    record/4,
    list_events/0,
    list_events/1,
    get_event/1
]).

-export_type([
    category/0,
    action/0,
    audit_event/0,
    audit_filter/0
]).

-type category() :: atom() | binary().
-type action() :: atom() | binary().
-type audit_event() :: beam_agent_journal_core:entry().
-type audit_scope() :: #{
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    profile_id => binary()
}.
-type audit_scope_error() ::
    invalid_audit_scope
  | {unsupported_audit_filter, atom()}
  | {unsupported_audit_scope_key, atom()}.
-type normalize_term_tag() :: invalid_action | invalid_category.
-type audit_operation() :: record | list_events | get_event.
-type audit_allowed_key() ::
    action | category | decision | event_id | limit | profile_id |
    run_id | session_id | since | thread_id.
-type audit_record_error() ::
    {error,
        already_exists
      | invalid_audit_scope
      | session_id_required_for_thread
      | {invalid_action | invalid_category | invalid_event | invalid_event_type |
            invalid_filter | unsupported_audit_filter |
            unsupported_audit_scope_key, term()}}.
-type audit_event_map() :: #{
    action => action(),
    category => category(),
    payload => map(),
    tags => [atom() | binary(), ...],
    profile_id => binary(),
    run_id => binary(),
    session_id => binary(),
    thread_id => binary()
}.

-type audit_filter() :: #{
    event_id => binary(),
    session_id => binary(),
    thread_id => binary(),
    run_id => binary(),
    category => category(),
    action => action(),
    decision => atom() | binary(),
    profile_id => binary(),
    since => integer(),
    limit => pos_integer()
}.

-doc """
Record a normalized audit event in the durable journal.

`Scope` may contain `session_id`, `thread_id`, `run_id`, and/or `profile_id`.
`Details` is merged into the audit payload.
""".
-spec record(category(), action(), map(), map()) ->
    {ok, audit_event()} | {error, term()}.
record(Category, Action, Scope, Details)
  when is_map(Scope), is_map(Details) ->
    TeleMeta = maps:merge(maps:with([session_id, thread_id, run_id, profile_id], Scope),
        #{category => Category, action => Action}),
    StartTime = telemetry_start(record, TeleMeta),
    Result = case {normalize_term(Category, invalid_category),
          normalize_term(Action, invalid_action),
          normalize_scope(Scope)} of
        {{ok, Category1}, {ok, Action1}, {ok, NormalizedScope}} ->
            Payload0 = #{
                category => Category1,
                action => Action1
            },
            Payload1 = maybe_put(profile_id, maps:get(profile_id, NormalizedScope, undefined),
                Payload0),
            Payload = maps:merge(Payload1, Details),
            Event0 = #{
                tags => [audit, Category1],
                payload => Payload
            },
            Event1 = maybe_put(session_id, maps:get(session_id, NormalizedScope, undefined),
                Event0),
            Event2 = maybe_put(thread_id, maps:get(thread_id, NormalizedScope, undefined),
                Event1),
            Event3 = maybe_put(run_id, maps:get(run_id, NormalizedScope, undefined), Event2),
            beam_agent_journal_core:append(<<"audit">>, Event3);
        {{error, _} = Error, _, _} ->
            Error;
        {_, {error, _} = Error, _} ->
            Error;
        {_, _, {error, _} = Error} ->
            Error
    end,
    case Result of
        {ok, AuditEntry} ->
            telemetry_stop(record, StartTime, TeleMeta#{
                event_id => maps:get(event_id, AuditEntry, undefined)
            }),
            Result;
        {error, _} = ErrorResult ->
            telemetry_exception(record, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc "List all audit events, oldest first.".
-spec list_events() -> {ok, [audit_event()]}.
list_events() ->
    list_events(#{}).

-doc "List audit events with exact-match filters.".
-spec list_events(audit_filter()) -> {ok, [audit_event()]} | {error, {unsupported_audit_filter, atom()} | term()}.
list_events(FilterInput) when is_map(FilterInput) ->
    TeleMeta = maps:with([event_id, session_id, thread_id, run_id, category, action,
        decision, profile_id, since, limit], FilterInput),
    StartTime = telemetry_start(list_events, TeleMeta),
    case normalize_filter(FilterInput) of
        {ok, Filter, JournalFilter} ->
            case beam_agent_journal_core:list(JournalFilter#{tag => audit}) of
                {ok, Entries} ->
                    Results = [Entry || Entry <- Entries, matches_filter(Entry, Filter)],
                    telemetry_stop(list_events, StartTime, TeleMeta#{
                        result_count => length(Results)
                    }),
                    {ok, Results};
                {error, _} = ListError ->
                    telemetry_exception(list_events, ListError, TeleMeta),
                    ListError
            end;
        {error, _} = FilterError ->
            telemetry_exception(list_events, FilterError, TeleMeta),
            FilterError
    end.

-doc "Fetch an audit event by event id.".
-spec get_event(binary()) -> {ok, audit_event()} | {error, not_found}.
get_event(EventId) when is_binary(EventId) ->
    StartTime = telemetry_start(get_event, #{event_id => EventId}),
    case beam_agent_journal_core:get(EventId) of
        {ok, Entry} ->
            case is_audit_entry(Entry) of
                true ->
                    telemetry_stop(get_event, StartTime, #{event_id => EventId, found => true}),
                    {ok, Entry};
                false ->
                    telemetry_stop(get_event, StartTime, #{event_id => EventId, found => false}),
                    {error, not_found}
            end;
        {error, not_found} ->
            telemetry_stop(get_event, StartTime, #{event_id => EventId, found => false}),
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec normalize_filter(map()) ->
    {ok, audit_filter(), beam_agent_journal_core:event_filter()} | {error, {unsupported_audit_filter, atom()}}.
normalize_filter(FilterInput) ->
    Allowed = [event_id, session_id, thread_id, run_id, category, action,
        decision, profile_id, since, limit],
    case validate_allowed_keys(FilterInput, Allowed, unsupported_audit_filter) of
        ok ->
            {ok,
             FilterInput,
             maps:with([event_id, session_id, thread_id, run_id, since, limit],
                 FilterInput)};
        {error, _} = Error ->
            Error
    end.

-spec matches_filter(audit_event(), audit_filter()) -> boolean().
matches_filter(Entry, Filter) ->
    Payload = maps:get(payload, Entry, #{}),
    lists:all(fun
        ({event_id, EventId}) ->
            maps:get(event_id, Entry, undefined) =:= EventId;
        ({session_id, SessionId}) ->
            maps:get(session_id, Entry, undefined) =:= SessionId;
        ({thread_id, ThreadId}) ->
            maps:get(thread_id, Entry, undefined) =:= ThreadId;
        ({run_id, RunId}) ->
            maps:get(run_id, Entry, undefined) =:= RunId;
        ({since, Since}) ->
            maps:get(timestamp, Entry, 0) >= Since;
        ({limit, _}) ->
            true;
        ({Key, Value}) ->
            maps:get(Key, Payload, undefined) =:= Value
    end, maps:to_list(Filter)).

-spec normalize_scope(map()) -> {ok, audit_scope()} | {error, audit_scope_error()}.
normalize_scope(Scope) ->
    Allowed = [session_id, thread_id, run_id, profile_id],
    case validate_allowed_keys(Scope, Allowed, unsupported_audit_scope_key) of
        ok ->
            case lists:all(fun(Key) ->
                Value = maps:get(Key, Scope, undefined),
                Value =:= undefined orelse is_binary(Value)
            end, Allowed) of
                true -> {ok, Scope};
                false -> {error, invalid_audit_scope}
            end;
        {error, _} = Error ->
            Error
    end.

-spec is_audit_entry(audit_event()) -> boolean().
is_audit_entry(Entry) ->
    lists:member(audit, maps:get(tags, Entry, [])) andalso
        maps:get(event_type, Entry, undefined) =:= <<"audit">>.

-spec normalize_term(term(), normalize_term_tag()) ->
    {ok, atom() | binary()} | {error, {normalize_term_tag(), term()}}.
normalize_term(Value, _Tag) when is_atom(Value); is_binary(Value) ->
    {ok, Value};
normalize_term(Value, Tag) ->
    {error, {Tag, Value}}.

-spec validate_allowed_keys(map(), [audit_allowed_key(), ...],
    unsupported_audit_filter | unsupported_audit_scope_key) ->
    ok | {error, {unsupported_audit_filter, atom()} | {unsupported_audit_scope_key, atom()}}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case [Key || Key <- maps:keys(Map),
            is_atom(Key),
            not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [Unsupported | _] ->
            {error, {ErrorTag, Unsupported}}
    end.

-spec maybe_put(profile_id | run_id | session_id | thread_id,
    undefined | binary(), audit_event_map()) -> audit_event_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec telemetry_start(audit_operation(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry:span_start(audit, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(audit_operation(), integer(), map()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry:span_stop(audit, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(record | list_events, audit_record_error(), map()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry:span_exception(audit, Operation, Reason,
        compact_telemetry(Metadata)).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).
