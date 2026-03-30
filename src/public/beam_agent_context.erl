-module(beam_agent_context).
-moduledoc """
Public API for canonical BeamAgent context management.

This module is the stable public API facade for context management. It adds
input validation guards on top of the core implementation in
`beam_agent_context_core`.

Every public function validates its arguments before delegation to the core
implementation.

`beam_agent_context` keeps compaction explicit and caller-driven. It does not
start a scheduler, compactor, or maintenance process inside BeamAgent. Instead,
it gives the caller enough information to decide when context pressure is high
and enough primitives to compact intentionally at boundaries the caller already
owns.

The module sits on top of existing shared primitives:

  - session summarization through `beam_agent_session_store`
  - thread rollback/compaction through `beam_agent_threads`
  - optional memory promotion through `beam_agent_memory`

Typical flow:

  1. Call `budget_estimate/1` or `context_status/1` to inspect the current
     pressure and summary state.
  2. Call `maybe_compact/2` from a caller-owned boundary such as a routine
     runner, orchestration completion hook, or explicit maintenance endpoint.
  3. Call `compact_now/2` when you want deterministic summarization and
     compaction immediately.

This keeps the context layer process-free while still making compaction policy
first-class and observable.

== Architecture

This module is the stable public API facade for context management. It
delegates all operations to `beam_agent_context_core`, which owns the
implementation. The two-layer split decouples the public API contract from
internal implementation, allowing the core module to be refactored freely
without breaking callers. Type aliases re-exported here let callers depend on
`beam_agent_context:scope()` rather than the internal module name.
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
    budget_estimate_result/0,
    context_error/0,
    compact_now_result/0,
    maybe_compact_result/0
]).

-type scope() :: beam_agent_context_core:scope().
-type context_status() :: beam_agent_context_core:context_status().
-type budget_estimate_result() :: beam_agent_context_core:budget_estimate_result().
-type context_error() :: beam_agent_context_core:context_error().
-type compact_now_result() :: beam_agent_context_core:compact_now_result().
-type maybe_compact_result() :: beam_agent_context_core:maybe_compact_result().

-doc "Return current context pressure and available summary/memory state.".
-spec context_status(scope()) -> {ok, context_status()} | {error, term()}.
context_status(SessionOrThread) when is_pid(SessionOrThread); is_binary(SessionOrThread) ->
    beam_agent_context_core:context_status(SessionOrThread);
context_status(#{session_id := SId} = SessionOrThread) when is_binary(SId), is_map(SessionOrThread) ->
    beam_agent_context_core:context_status(SessionOrThread);
context_status(_) ->
    {error, {bad_arg, <<"scope must be a pid, binary session id, or map with binary session_id">>}}.

-doc "Estimate current context budget pressure using default thresholds.".
-spec budget_estimate(scope()) -> {ok, budget_estimate_result()} | {error, term()}.
budget_estimate(SessionOrThread) when is_pid(SessionOrThread); is_binary(SessionOrThread) ->
    beam_agent_context_core:budget_estimate(SessionOrThread);
budget_estimate(#{session_id := SId} = SessionOrThread) when is_binary(SId), is_map(SessionOrThread) ->
    beam_agent_context_core:budget_estimate(SessionOrThread);
budget_estimate(_) ->
    {error, {bad_arg, <<"scope must be a pid, binary session id, or map with binary session_id">>}}.

-doc "Summarize, optionally promote to memory, and compact immediately.".
-spec compact_now(scope(), map()) ->
    {ok, compact_now_result()}
  | {error, context_error() | {hook_denied, binary()} | {hook_ask, binary()} | {bad_arg, binary()}}.
compact_now(SessionOrThread, Opts) when is_pid(SessionOrThread), is_map(Opts) ->
    beam_agent_context_core:compact_now(SessionOrThread, Opts);
compact_now(SessionOrThread, Opts) when is_binary(SessionOrThread), is_map(Opts) ->
    beam_agent_context_core:compact_now(SessionOrThread, Opts);
compact_now(#{session_id := SId} = SessionOrThread, Opts) when is_binary(SId), is_map(Opts) ->
    beam_agent_context_core:compact_now(SessionOrThread, Opts);
compact_now(_, Opts) when is_map(Opts) ->
    {error, {bad_arg, <<"scope must be a pid, binary session id, or map with binary session_id">>}};
compact_now(_, _) ->
    {error, {bad_arg, <<"opts must be a map">>}}.

-doc "Compact only when a configured policy trigger fires.".
-spec maybe_compact(scope(), map()) ->
    {ok, maybe_compact_result()}
  | {error, context_error() | {hook_denied, binary()} | {hook_ask, binary()} | {bad_arg, binary()}}.
maybe_compact(SessionOrThread, Opts) when is_pid(SessionOrThread), is_map(Opts) ->
    beam_agent_context_core:maybe_compact(SessionOrThread, Opts);
maybe_compact(SessionOrThread, Opts) when is_binary(SessionOrThread), is_map(Opts) ->
    beam_agent_context_core:maybe_compact(SessionOrThread, Opts);
maybe_compact(#{session_id := SId} = SessionOrThread, Opts) when is_binary(SId), is_map(Opts) ->
    beam_agent_context_core:maybe_compact(SessionOrThread, Opts);
maybe_compact(_, Opts) when is_map(Opts) ->
    {error, {bad_arg, <<"scope must be a pid, binary session id, or map with binary session_id">>}};
maybe_compact(_, _) ->
    {error, {bad_arg, <<"opts must be a map">>}}.
