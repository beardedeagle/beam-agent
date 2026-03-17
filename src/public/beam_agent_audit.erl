-module(beam_agent_audit).
-moduledoc """
Public API for canonical BeamAgent audit records.

Audit entries are stored in the durable journal with an `audit` tag so they
can be replayed and filtered like other canonical domain events.
""".

-export([
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

-type category() :: beam_agent_audit_core:category().
-type action() :: beam_agent_audit_core:action().
-type audit_event() :: beam_agent_audit_core:audit_event().
-type audit_filter() :: beam_agent_audit_core:audit_filter().

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
