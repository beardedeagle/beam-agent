-module(beam_agent_hooks).
-moduledoc """
Public API for SDK lifecycle hooks.

This module provides a hook system that lets callers register
in-process callback functions at key session lifecycle points.
Hooks enable cross-cutting concerns (logging, permission gates,
tool filtering, telemetry) without modifying adapter internals.

The hook system is modeled after the TypeScript SDK v0.2.66
SessionConfig.hooks and Python SDK hook support.

Most callers pass hooks via the sdk_hooks option when starting a
session. Use this module directly when you need to construct hook
definitions, build registries, or fire hooks from custom adapters.

## Getting Started

```erlang
%% Create a hook that blocks shell access:
DenyBash = beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"No shell access allowed">>};
        _ -> {ok, Ctx}
    end
end),

%% Create a hook that logs all tool usage:
LogTool = beam_agent_hooks:hook(post_tool_use, fun(Ctx) ->
    logger:info("Tool used: ~s", [maps:get(tool_name, Ctx, <<"unknown">>)]),
    {ok, Ctx}
end),

%% Build a registry and pass to session:
Registry = beam_agent_hooks:build_registry([DenyBash, LogTool]),
beam_agent:start_session(#{sdk_hooks => [DenyBash, LogTool]})
```

## Key Concepts

- Hook events: atoms identifying lifecycle points. Two categories:

  Blocking events (pre_tool_use, user_prompt_submit, permission_request,
  subagent_start, pre_compact, config_change) support three-way returns:
  {ok, Ctx} to allow, {deny, Reason} to block, {ask, Reason} to
  escalate to the caller for a decision.

  Notification-only events (post_tool_use, post_tool_use_failure, stop,
  session_start, session_end, subagent_stop, notification,
  task_completed, teammate_idle) always proceed regardless of callback
  return values. Context is still threaded through for composition.

- Hook callback: a fun/1 receiving a hook_context() map and returning
  {ok, Ctx}, {deny, Reason}, or {ask, Reason}. Callbacks are wrapped
  in try/catch for crash protection.

- Matchers: optional filters that restrict which tools trigger a hook.
  The tool_name field in a matcher can be an exact string or a regex
  pattern. Patterns are pre-compiled at registration time for efficient
  dispatch.

- Hook registry: a map from hook_event() to a list of hook_def() maps,
  maintained in registration order. The registry is passed to fire/3
  at dispatch time.

## Architecture

This module is a thin public wrapper that delegates every call to
beam_agent_hooks_core. The core module contains all constructor,
registry, and dispatch logic.

Per-session hooks are entirely in-process -- no ETS tables or
inter-process communication. The hook registry is typically stored in
the session handler state and passed to fire/3 when lifecycle events
occur.

Global hooks (registered via register_global/1) apply to every session.
They are backed by a shared ETS table and fire before per-session hooks
in the dispatch chain. Changes to the global registry automatically
notify the reload bus so live sessions pick up updates.

## Core concepts

Hooks are callback functions that run at specific points in a session
lifecycle. Think of them as event listeners: you register a function,
and the SDK calls it when something happens (e.g., before a tool runs,
when a session starts, when a query completes).

There are two kinds of hook events. Blocking events (like pre_tool_use)
let your callback prevent an action by returning {deny, Reason}.
Notification events (like post_tool_use, session_start) are fire-and-forget
-- your callback runs but cannot block anything.

Matchers let you filter which tools trigger a hook. For example, you can
write a hook that only fires when the Bash tool is used by adding a
tool_name matcher. Matchers support exact strings and regex patterns.

## Architecture deep dive

Hooks are entirely in-process -- no ETS tables, no inter-process
communication. The hook registry is a map from hook_event() to an
ordered list of hook_def() maps, stored in the session handler state
and threaded through fire/3 at dispatch time.

Fire order is registration order. Context is threaded through the
chain: each hook receives the context as modified by the previous
hook. Crash protection is provided by try/catch in fire/3 -- a
crashing callback logs a warning and passes the context through
unmodified. Blocking events short-circuit on the first {deny, Reason}
or {ask, Reason} return.

This module is a thin re-export layer over beam_agent_hooks_core, which
contains all constructor, registry building, and dispatch logic.

## See Also

- beam_agent_hooks_core: implementation module with full internals
- beam_agent_checkpoint: automatic file checkpointing via hooks
- beam_agent_session_handler: session handler behaviour (fires hooks)
- beam_agent: main SDK entry point

## Backend Integration

Backend authors do not need to implement hooks directly. The session engine
fires hooks automatically at lifecycle points. Your handler callbacks run
inside the hook dispatch chain. See docs/guides/backend_integration_guide.md
for the full handler callback reference.
""".

-export([
    hook/2,
    hook/3,
    new_registry/0,
    register_hook/2,
    register_hooks/2,
    fire/3,
    build_registry/1,
    %% Global hooks
    ensure_global_table/0,
    register_global/1,
    unregister_global/1,
    global_registry/0
]).

-export_type([
    hook_event/0,
    hook_callback/0,
    hook_context/0,
    hook_matcher/0,
    hook_def/0,
    hook_registry/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc """
Hook event atom identifying a lifecycle point.

Blocking events: pre_tool_use, user_prompt_submit, permission_request,
subagent_start, pre_compact, config_change.
Notification-only events: post_tool_use, post_tool_use_failure, stop,
session_start, session_end, subagent_stop, notification,
task_completed, teammate_idle.
""".
-type hook_event() :: beam_agent_hooks_core:hook_event().

-doc """
Hook callback function.

Receives a hook_context() map and returns a three-way result:
- `{ok, Ctx}` — allow, continue chain with (possibly modified) context
- `{deny, Reason}` — block the action (blocking events only)
- `{ask, Reason}` — escalate to caller for decision (blocking events only)

For notification-only events, `{deny, _}` and `{ask, _}` returns are
ignored; context passes through unmodified from those hooks.

Blocking events: pre_tool_use, user_prompt_submit, permission_request,
subagent_start, pre_compact, config_change.
""".
-type hook_callback() :: beam_agent_hooks_core:hook_callback().

-doc """
Context map passed to hook callbacks.

Always contains the event key. Other keys depend on the event type:
tool_name, tool_input, tool_use_id for tool events; prompt, params
for user_prompt_submit; stop_reason, duration_ms for stop; etc.
""".
-type hook_context() :: beam_agent_hooks_core:hook_context().

-doc """
Matcher filter for restricting which tools trigger a hook.

The tool_name field can be an exact binary string or a regex pattern.
When a regex pattern is provided, it is pre-compiled at hook/3
registration time for O(1) dispatch.
""".
-type hook_matcher() :: beam_agent_hooks_core:hook_matcher().

-doc """
A single hook definition.

Contains the event atom, callback function, optional matcher, and
an optional pre-compiled regex (populated internally by hook/3).
""".
-type hook_def() :: beam_agent_hooks_core:hook_def().

-doc """
Hook registry mapping events to their registered hook definitions.

A map from hook_event() to a list of hook_def() maps in registration
order. Created via new_registry/0 and populated via register_hook/2
or build_registry/1.
""".
-type hook_registry() :: beam_agent_hooks_core:hook_registry().

%%--------------------------------------------------------------------
%% Constructors
%%--------------------------------------------------------------------

-doc """
Create a hook that fires on all occurrences of an event.

Event is the lifecycle event atom (e.g. pre_tool_use, session_start).
Callback is a fun/1 receiving a hook_context() map.

Returns a hook_def() map suitable for register_hook/2 or
build_registry/1.

```erlang
Hook = beam_agent_hooks:hook(session_start, fun(Ctx) ->
    logger:info("Session started: ~s",
        [maps:get(session_id, Ctx, <<"unknown">>)]),
    {ok, Ctx}
end)
```
""".
-spec hook(hook_event(), hook_callback()) -> hook_def().
hook(Event, Callback) ->
    beam_agent_hooks_core:hook(Event, Callback).

-doc """
Create a hook with a matcher filter.

The matcher restricts which tools trigger the hook. Only relevant
for tool-related events (pre_tool_use, post_tool_use,
post_tool_use_failure).

The tool_name field in the matcher can be an exact binary string
or a regex pattern. The regex is pre-compiled at registration time
for O(1) dispatch. Invalid regex patterns cause a crash (fail-fast).

Event is the lifecycle event atom.
Callback is a fun/1 receiving a hook_context() map.
Matcher is a hook_matcher() map with a tool_name key.

```erlang
%% Only fire for Write and Edit tools:
Hook = beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    logger:info("File mutation: ~s", [maps:get(tool_name, Ctx, <<>>)]),
    {ok, Ctx}
end, #{tool_name => <<"^(Write|Edit)$">>})
```
""".
-spec hook(hook_event(), hook_callback(), hook_matcher()) -> hook_def().
hook(Event, Callback, Matcher) ->
    beam_agent_hooks_core:hook(Event, Callback, Matcher).

%%--------------------------------------------------------------------
%% Registry Management
%%--------------------------------------------------------------------

-doc """
Create an empty hook registry.

Returns a new hook_registry() map with no registered hooks.
""".
-spec new_registry() -> hook_registry().
new_registry() -> beam_agent_hooks_core:new_registry().

-doc """
Register a single hook in the registry.

Adds HookDef to the registry under its event key. Hooks are
prepended internally (O(1)) and reversed at fire time to preserve
registration order.

HookDef is a hook_def() map (from hook/2 or hook/3).
Registry is the current hook_registry().

Returns the updated registry.

```erlang
Registry0 = beam_agent_hooks:new_registry(),
Hook = beam_agent_hooks:hook(stop, fun(Ctx) -> {ok, Ctx} end),
Registry1 = beam_agent_hooks:register_hook(Hook, Registry0)
```
""".
-spec register_hook(hook_def(), hook_registry()) -> hook_registry().
register_hook(Hook, Registry) ->
    beam_agent_hooks_core:register_hook(Hook, Registry).

-doc """
Register multiple hooks in the registry.

Adds all hook definitions to the registry in list order.

Hooks is a list of hook_def() maps.
Registry is the current hook_registry().

Returns the updated registry.
""".
-spec register_hooks([hook_def()], hook_registry()) -> hook_registry().
register_hooks(Hooks, Registry) ->
    beam_agent_hooks_core:register_hooks(Hooks, Registry).

%%--------------------------------------------------------------------
%% Dispatch
%%--------------------------------------------------------------------

-doc """
Fire all hooks registered for an event.

Context is threaded through the hook chain: each hook receives the
context as modified by the previous hook. The final context flows
back to the caller via `{ok, FinalCtx}`.

For blocking events (pre_tool_use, user_prompt_submit,
permission_request, subagent_start, pre_compact, config_change):
returns `{ok, FinalCtx}` if all hooks allow, `{deny, Reason}` on
first deny, or `{ask, Reason}` on first ask. Both deny and ask
stop the chain immediately.

For notification-only events: always returns `{ok, FinalCtx}`.
`{deny, _}` and `{ask, _}` from callbacks are ignored.

Handles an undefined registry (no hooks configured) gracefully by
returning `{ok, Context}`. Each callback is wrapped in try/catch
for crash protection -- a crashing callback is logged and the
context passes through unmodified.

Event is the hook_event() atom.
Context is a hook_context() map describing the current lifecycle event.
Registry is a hook_registry() or undefined.

```erlang
case beam_agent_hooks:fire(pre_tool_use, #{
    event => pre_tool_use,
    tool_name => <<"Bash">>,
    tool_input => #{<<"command">> => <<"rm -rf /">>}
}, Registry) of
    {ok, FinalCtx} ->
        proceed_with_tool(FinalCtx);
    {deny, Reason} ->
        reject_tool(Reason);
    {ask, Reason} ->
        escalate_to_caller(Reason)
end
```
""".
-spec fire(hook_event(), hook_context(), hook_registry() | undefined) ->
    {ok, hook_context()} | {deny, binary()} | {ask, binary()}.
fire(Event, Ctx, Registry) ->
    beam_agent_hooks_core:fire(Event, Ctx, Registry).

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

-doc """
Build a hook registry from a list of hook definitions.

Convenience function that creates a new registry and registers all
provided hooks. Returns undefined when the input is an empty list
or undefined (no hooks configured).

Used by all adapter session modules during init to convert the
sdk_hooks option into a registry.

Hooks is a list of hook_def() maps, or undefined.

```erlang
Hooks = [
    beam_agent_hooks:hook(pre_tool_use, fun deny_bash/1),
    beam_agent_hooks:hook(post_tool_use, fun log_tool/1)
],
Registry = beam_agent_hooks:build_registry(Hooks)
```
""".
-spec build_registry([hook_def()] | undefined) ->
    hook_registry() | undefined.
build_registry(Opts) ->
    beam_agent_hooks_core:build_registry(Opts).

%%--------------------------------------------------------------------
%% Global Hooks
%%--------------------------------------------------------------------

-doc """
Create the global hooks ETS table. Idempotent.

The global hook table is an ordered_set keyed by `{Event, Seq}` where
`Seq` is a monotonically increasing integer assigned at registration
time. This guarantees deterministic firing order across all OTP
versions. Called automatically by beam_agent:init/0. Safe to call
multiple times.
""".
-spec ensure_global_table() -> ok.
ensure_global_table() ->
    beam_agent_hooks_core:ensure_global_table().

-doc """
Register a hook globally (fires for every session).

Inserts the hook into the global ETS table and notifies the reload
bus so live sessions pick up the change. The table is created
automatically if it does not exist yet.

HookDef is a hook_def() map (from hook/2 or hook/3).

```erlang
Hook = beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"No Bash globally">>};
        _ -> {ok, Ctx}
    end
end),
ok = beam_agent_hooks:register_global(Hook)
```
""".
-spec register_global(hook_def()) -> ok.
register_global(HookDef) ->
    beam_agent_hooks_core:register_global(HookDef).

-doc """
Unregister a hook from the global registry.

Removes the exact hook object. Other hooks for the same event are
unaffected. Notifies the reload bus after removal.

Returns ok even if the hook was not found (idempotent).
""".
-spec unregister_global(hook_def()) -> ok.
unregister_global(HookDef) ->
    beam_agent_hooks_core:unregister_global(HookDef).

-doc """
Read the entire global hook registry as a hook_registry() map.

Returns a map from event atoms to lists of hook definitions.
Returns an empty map if no global hooks are registered.
""".
-spec global_registry() -> hook_registry().
global_registry() ->
    beam_agent_hooks_core:global_registry().
