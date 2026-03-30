-module(beam_agent_journal).
-moduledoc """
Public API for the BeamAgent durable event journal.

The journal stores normalized BeamAgent domain events for replay, audit, and
orchestration. It is intentionally distinct from `beam_agent_events`:

- `beam_agent_events` is the live subscriber bus for session activity
- `beam_agent_journal` is the durable append-only journal for canonical domain
  events such as run lifecycle, artifact changes, and control mutations

The implementation is ETS-backed through `beam_agent_journal_core` and
`beam_agent_journal_store`, so it stays process-free and works uniformly across
all BeamAgent backends.

== Architecture

This module is the stable public API facade for the event journal and audit
subsystem. It delegates journal operations to `beam_agent_journal_core` and
audit convenience functions to `beam_agent_audit_core`. The two-layer split
decouples the public API contract from internal implementation, allowing core
modules to be refactored freely without breaking callers. Type aliases
re-exported here let callers depend on `beam_agent_journal:entry()` rather
than the internal module name.
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
    list_acks/1,
    %% Audit convenience API
    list_events/0,
    list_events/1,
    get_event/1
]).

-export_type([
    event_type/0,
    tag/0,
    event_input/0,
    event_filter/0,
    entry/0,
    %% Audit types
    category/0,
    action/0,
    audit_event/0,
    audit_filter/0
]).

-doc "Journal event type identifier.".
-type event_type() :: beam_agent_journal_core:event_type().

-doc "Journal tag value.".
-type tag() :: beam_agent_journal_core:tag().

-doc "Envelope passed to `append/2`.".
-type event_input() :: beam_agent_journal_core:event_input().

-doc "Filter map accepted by `list/1` and `stream_from/2`.".
-type event_filter() :: beam_agent_journal_core:event_filter().

-doc "Journal entry record returned by the public API.".
-type entry() :: beam_agent_journal_core:entry().

-doc "Audit event category (e.g., `command`, `policy`, `orchestrator`).".
-type category() :: beam_agent_audit_core:category().

-doc "Audit event action (e.g., `run`, `delegated`, `allow`).".
-type action() :: beam_agent_audit_core:action().

-doc "Audit event record returned by the audit API.".
-type audit_event() :: beam_agent_audit_core:audit_event().

-doc "Filter map accepted by `list_events/1`.".
-type audit_filter() :: beam_agent_audit_core:audit_filter().

-doc """
Ensure the journal ETS tables exist.

This call is idempotent and safe from any process.
""".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_journal_core:ensure_tables().

-doc """
Clear all journal events and acknowledgements.

This is a destructive in-memory reset intended for tests and explicit local
state resets.
""".
-spec clear() -> ok.
clear() ->
    beam_agent_journal_core:clear().

-doc """
Append a normalized BeamAgent domain event to the durable journal.

The envelope may include `session_id`, `thread_id`, `run_id`, `tags`,
`timestamp`, and `payload`.
""".
-spec append(event_type(), event_input()) -> {ok, entry()} | {error, term()}.
append(EventType, Event) ->
    beam_agent_journal_core:append(EventType, Event).

-doc "List all journal entries, oldest first.".
-spec list() -> {ok, [entry()]}.
list() ->
    beam_agent_journal_core:list().

-doc """
List journal entries with exact-match filters.

Supported filters are `event_id`, `event_type`, `session_id`, `thread_id`,
`run_id`, `tag`, `since`, and `limit`.
""".
-spec list(event_filter()) -> {ok, [entry()]} | {error, term()}.
list(Filter) ->
    beam_agent_journal_core:list(Filter).

-doc """
Replay journal entries after the given cursor.

Use the `sequence` field from the last seen entry as the next cursor. Passing
`0` replays from the start of the journal.
""".
-spec stream_from(non_neg_integer()) -> {ok, [entry()]} | {error, term()}.
stream_from(Cursor) ->
    beam_agent_journal_core:stream_from(Cursor).

-doc "Replay journal entries after the given cursor with additional filters.".
-spec stream_from(non_neg_integer(), event_filter()) ->
    {ok, [entry()]} | {error, term()}.
stream_from(Cursor, Filter) ->
    beam_agent_journal_core:stream_from(Cursor, Filter).

-doc "Fetch a journal entry by id.".
-spec get(binary()) -> {ok, entry()} | {error, not_found}.
get(EventId) ->
    beam_agent_journal_core:get(EventId).

-doc "Acknowledge a journal entry for a consumer id. Idempotent.".
-spec ack(binary(), binary()) -> ok | {error, not_found}.
ack(ConsumerId, EventId) ->
    beam_agent_journal_core:ack(ConsumerId, EventId).

-doc "Fetch an ack record for a consumer and event.".
-spec get_ack(binary(), binary()) -> {ok, map()} | {error, not_found}.
get_ack(ConsumerId, EventId) ->
    beam_agent_journal_core:get_ack(ConsumerId, EventId).

-doc "List all ack records for a consumer, newest first.".
-spec list_acks(binary()) -> {ok, [map()]}.
list_acks(ConsumerId) ->
    beam_agent_journal_core:list_acks(ConsumerId).

%%--------------------------------------------------------------------
%% Audit Convenience API
%%--------------------------------------------------------------------

-doc "List all audit events, oldest first.".
-spec list_events() -> {ok, [audit_event()]}.
list_events() ->
    beam_agent_audit_core:list_events().

-doc "List audit events with exact-match filters.".
-spec list_events(audit_filter()) -> {ok, [audit_event()]} | {error, term()}.
list_events(Filter) ->
    beam_agent_audit_core:list_events(Filter).

-doc "Fetch an audit event by id.".
-spec get_event(binary()) -> {ok, audit_event()} | {error, not_found}.
get_event(EventId) ->
    beam_agent_audit_core:get_event(EventId).
