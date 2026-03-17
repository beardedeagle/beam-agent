-module(beam_agent_context).
-moduledoc """
Public API for canonical BeamAgent context management.

This module estimates context pressure, reports current summary/memory state,
and applies policy-driven compaction using the existing session-summary and
thread-compaction primitives.
""".

-export([
    context_status/1,
    compact_now/2,
    maybe_compact/2,
    budget_estimate/1
]).

-export_type([
    scope/0,
    context_status/0,
    budget_estimate_result/0
]).

-type scope() :: beam_agent_context_core:scope().
-type context_status() :: beam_agent_context_core:context_status().
-type budget_estimate_result() :: beam_agent_context_core:budget_estimate_result().

-doc "Return current context pressure and available summary/memory state.".
-spec context_status(scope()) -> {ok, context_status()} | {error, term()}.
context_status(SessionOrThread) ->
    beam_agent_context_core:context_status(SessionOrThread).

-doc "Estimate current context budget pressure using default thresholds.".
-spec budget_estimate(scope()) -> {ok, budget_estimate_result()} | {error, term()}.
budget_estimate(SessionOrThread) ->
    beam_agent_context_core:budget_estimate(SessionOrThread).

-doc "Summarize, optionally promote to memory, and compact immediately.".
-spec compact_now(scope(), map()) -> {ok, map()} | {error, term()}.
compact_now(SessionOrThread, Opts) ->
    beam_agent_context_core:compact_now(SessionOrThread, Opts).

-doc "Compact only when a configured policy trigger fires.".
-spec maybe_compact(scope(), map()) -> {ok, map()} | {error, term()}.
maybe_compact(SessionOrThread, Opts) ->
    beam_agent_context_core:maybe_compact(SessionOrThread, Opts).

