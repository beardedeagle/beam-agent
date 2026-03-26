# beam-agent Hooks Enhancement

_Status: Phase 4 Complete — Phases 1–3 Proposed_
_Author: Randy Thompson_
_Date: 2026-03-25_

## 1. Problem Statement

beam-agent's hook system (`beam_agent_hooks_core`) dispatches lifecycle
events to registered callbacks but has a fundamental design flaw: hooks
cannot transform data flowing through the chain. Every hook in a chain
receives the **same original context** — there is no intermediate
transformation between hooks.

### Current Dispatch (broken)

```erlang
%% fire_blocking/2 — same Context passed to every hook:
fire_blocking([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_blocking(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {deny, Reason} -> {deny, Reason};
                ok             -> fire_blocking(Rest, Context)  %% ← same Context
            end
    end.
```

Hook A and Hook B both see the original context. Hook A cannot modify
`tool_input` in a way that Hook B observes. The handler at the boundary
also receives no modifications — it uses its original variables after
`fire/3` returns `ok`.

### What Claude Code gets right

Claude Code's hooks return structured output including `updatedInput`,
`updatedMCPToolOutput`, and `additionalContext`. Hooks transform data
at every lifecycle point, and the harness uses the transformed data.

beam-agent's hooks should work the same way: callbacks return modified
context, dispatch threads it through the chain, and the handler uses
the final result.

### What this is NOT

This is not the Plug/pipe framework from the earlier proposal. That
framework was a 19-file abstraction layer built to work around this
hooks design flaw. The right fix is to fix hooks directly.

---

## 2. Design Tenets

1. **Fix, don't wrap.** Enhance the existing hook system. No new
   abstraction layer. No new dispatch mechanism.

2. **Threaded context.** Each hook in a chain receives the context as
   modified by the previous hook. This is the core fix.

3. **Handlers use the result.** `fire/3` returns the final context.
   Handlers read from the returned context, not from their original
   variables. This enables hooks to actually influence behavior.

4. **Zero new dependencies.** Pure Erlang/OTP stdlib. Consistent with
   beam-agent's security boundary.

5. **Hot reloadable.** Global hooks + reload bus ship alongside this
   enhancement. Hot reloading is a day-one requirement that extends
   to hooks, skills, MCP servers, commands, and all registrable
   components.

---

## 3. Core Enhancement

### 3.1 Callback Return Type

**Current:**
```erlang
-type hook_callback() :: fun((hook_context()) -> ok | {deny, binary()}).
```

**Fixed:**
```erlang
-type hook_callback() :: fun((hook_context()) ->
    {ok, hook_context()}    %% Allow, with (possibly modified) context
  | {deny, binary()}        %% Block the action (blocking events only)
  | {ask, binary()}         %% Escalate to caller for decision (blocking events only)
).
```

Three-way return for blocking events:
- `{ok, Ctx}` — allow, continue the chain with (possibly modified) context
- `{deny, Reason}` — block the action, stop the chain
- `{ask, Reason}` — the hook cannot decide; escalate to the caller (e.g.,
  MonkeyClaw shows a confirmation dialog). Like `{deny, _}`, this stops
  the chain and propagates to the handler. The handler/caller decides
  how to resolve the ask — beam-agent does not own UI.

A hook that doesn't modify anything returns `{ok, Context}` as received.
For notification events, `{deny, _}` and `{ask, _}` are ignored.

### 3.2 Fire Return Type

**Current:**
```erlang
-spec fire(hook_event(), hook_context(), hook_registry() | undefined) ->
    ok | {deny, binary()}.
```

**Fixed:**
```erlang
-spec fire(hook_event(), hook_context(), hook_registry() | undefined) ->
    {ok, hook_context()} | {deny, binary()} | {ask, binary()}.
```

`fire/3` always returns the final context. For blocking events, the
handler uses the returned context to get transformed data. For
notification events, handlers can ignore the context (`{ok, _}`).
The `{ask, Reason}` return propagates from blocking hooks only —
the handler decides how to resolve it (auto-approve, prompt, deny).

### 3.3 Context Threading — Blocking Events

**Current** (same context to every hook):
```erlang
fire_blocking([], _Context) ->
    ok;
fire_blocking([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_blocking(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {deny, Reason} -> {deny, Reason};
                ok             -> fire_blocking(Rest, Context)
            end
    end.
```

**Enhanced** (threaded context, three-way return):
```erlang
fire_blocking([], Context) ->
    {ok, Context};
fire_blocking([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_blocking(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {deny, Reason}  -> {deny, Reason};
                {ask, Reason}   -> {ask, Reason};
                {ok, Context1}  -> fire_blocking(Rest, Context1)
            end
    end.
```

Each hook receives the previous hook's output. The final context
flows back to the handler. Both `{deny, _}` and `{ask, _}` stop
the chain immediately and propagate to the caller.

### 3.4 Context Threading — Notification Events

**Current** (same context, result ignored):
```erlang
fire_notification([], _Context) ->
    ok;
fire_notification([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false -> fire_notification(Rest, Context);
        true  -> _ = safe_call(Hook, Context),
                 fire_notification(Rest, Context)
    end.
```

**Enhanced** (threaded context):
```erlang
fire_notification([], Context) ->
    {ok, Context};
fire_notification([Hook | Rest], Context) ->
    case matches_context(Hook, Context) of
        false ->
            fire_notification(Rest, Context);
        true ->
            case safe_call(Hook, Context) of
                {ok, Context1}  -> fire_notification(Rest, Context1);
                {deny, _}       -> fire_notification(Rest, Context);  %% ignored
                {ask, _}        -> fire_notification(Rest, Context)   %% ignored
            end
    end.
```

Notification hooks can now compose — hook A adds metadata that hook B
observes. The `{deny, _}` return is still ignored for notification
events (context passes through unmodified).

### 3.5 Safe Call

**Current:**
```erlang
safe_call(#{callback := Callback}, Context) ->
    try Callback(Context) of
        ok -> ok;
        {deny, Reason} when is_binary(Reason) -> {deny, Reason};
        _Other -> ok
    catch ... -> ok
    end.
```

**Fixed:**
```erlang
safe_call(#{callback := Callback}, Context) ->
    try Callback(Context) of
        {ok, Ctx1} when is_map(Ctx1) ->
            {ok, Ctx1};
        {deny, Reason} when is_binary(Reason) ->
            {deny, Reason};
        {ask, Reason} when is_binary(Reason) ->
            {ask, Reason};
        Other ->
            logger:warning("SDK hook callback returned unexpected: ~tp",
                           [Other]),
            {ok, Context}
    catch
        Class:Reason:Stack ->
            logger:warning("SDK hook callback crashed: ~p:~p~n~p",
                           [Class,
                            beam_agent_redaction:reason(Reason),
                            beam_agent_redaction:stacktrace(Stack)]),
            {ok, Context}               %% crash: pass context through unmodified
    end.
```

### 3.6 Fire Dispatch

```erlang
fire(_Event, Context, undefined) ->
    {ok, Context};
fire(Event, Context, Registry) when is_map(Registry) ->
    Hooks = lists:reverse(maps:get(Event, Registry, [])),
    case is_blocking_event(Event) of
        true  -> fire_blocking(Hooks, Context);
        false -> fire_notification(Hooks, Context)
    end.
```

### 3.7 Phantom Event Wiring

Eight events exist in the `hook_event()` type but are **never fired**
in any backend. All eight are legitimate SDK-level lifecycle events —
the backends will fire them regardless of consumer. They need to be
wired to actual fire sites, not removed.

| Phantom Event | Blocking? | Fire Site |
|---------------|-----------|-----------|
| `post_tool_use_failure` | No | Tool error paths in all backends. Currently these paths silently skip hooks. |
| `subagent_start` | **Yes** | Sub-session or delegated agent spawn points. Hook can deny spawning. |
| `subagent_stop` | No | Sub-session termination points. Pair with `subagent_start`. |
| `notification` | No | Backend notification/info message dispatch (non-tool, non-error lifecycle signals). **Note:** name is ambiguous with the "notification" dispatch mechanism (non-blocking fire). Consider renaming to `info_message` or `backend_notification` during implementation to avoid confusion. |
| `pre_compact` | **Yes** | Before context window compaction in backends that support it. Hook can prevent compaction. |
| `config_change` | **Yes** | From the reload bus when configuration changes (Phase 4 integration). Hook can reject a config change. |
| `task_completed` | No | Task/tool execution completion paths. |
| `teammate_idle` | No | Multi-agent coordination — when a delegated agent completes and becomes available. |

**All 8 events are kept.** Each gets wired to actual fire sites in
Phase 2 (handler call site updates). The type is correct as-is.

**Blocking classification update:** `is_blocking_event/1` grows from
3 to 6 entries:

```erlang
is_blocking_event(pre_tool_use) -> true;
is_blocking_event(user_prompt_submit) -> true;
is_blocking_event(permission_request) -> true;
is_blocking_event(subagent_start) -> true;    %% new
is_blocking_event(pre_compact) -> true;        %% new
is_blocking_event(config_change) -> true;      %% new
is_blocking_event(_) -> false.
```

### 3.8 Copilot `error_occurred` Fix

`copilot_session_handler.erl:627` maps the wire protocol event
`<<"errorOccurred">>` to the atom `error_occurred`, which is **not** in
the `hook_event()` type. This bypasses dialyzer and silently does
nothing (no hooks match an unregistered event).

**Resolution:** Map `<<"errorOccurred">>` to `post_tool_use_failure`
instead. This aligns with the semantic meaning (an error occurred during
tool/action execution) and uses an event that hooks can actually register
for.

```erlang
%% Before:
<<"errorOccurred">> -> error_occurred;

%% After:
<<"errorOccurred">> -> post_tool_use_failure;
```

---

## 4. Handler Call Site Updates

### 4.1 Blocking Event Call Sites

All blocking `fire/3` call sites currently match on `ok | {deny, Reason}`.
They change to match on `{ok, FinalCtx} | {deny, Reason}` and read
transformed data from `FinalCtx`.

**Before** (claude_session_handler.erl):
```erlang
case beam_agent_hooks_core:fire(user_prompt_submit, HookCtx, HookReg) of
    ok ->
        QueryMsg = build_query_message(Prompt, Params),
        ...
    {deny, Reason} ->
        {error, {hook_denied, Reason}}
end
```

**After:**
```erlang
case beam_agent_hooks_core:fire(user_prompt_submit, HookCtx, HookReg) of
    {ok, FinalCtx} ->
        FinalPrompt = maps:get(prompt, FinalCtx),
        FinalParams = maps:get(params, FinalCtx),
        QueryMsg = build_query_message(FinalPrompt, FinalParams),
        ...
    {deny, Reason} ->
        {error, {hook_denied, Reason}};
    {ask, Reason} ->
        {error, {hook_ask, Reason}}
end
```

The handler uses the hook chain's output, not its original variables.
A hook that rewrites the prompt, modifies tool input, or injects
additional context now has its changes respected by the handler.

### 4.2 Notification Event Call Sites

All notification `fire/3` call sites currently use `_ = fire(...)`.
These continue to work — `_ = ` matches any return. No changes
required unless the handler wants to use the modified context.

**Post-tool-use example** (optional enhancement):
```erlang
%% Before: discard result
_ = beam_agent_hooks_core:fire(post_tool_use, HookCtx, HookReg),

%% After: optionally use modified context (e.g., updated content)
{ok, FinalCtx} = beam_agent_hooks_core:fire(post_tool_use, HookCtx, HookReg),
%% FinalCtx may have enriched/transformed content from notification hooks
```

### 4.3 Call Site Inventory

**Blocking (require update):**

| File | Line | Event | Notes |
|------|------|-------|-------|
| `claude_session_handler.erl` | 147 | `user_prompt_submit` | Matches `ok ->` |
| `claude_session_handler.erl` | 583 | `permission_request` | **Chained pair (1/2).** `fire_permission_hooks/2` fires two sequential blocking calls. `{ok, FinalCtx}` from this call must flow into the `pre_tool_use` call below. Currently both receive the original `HookCtx`. |
| `claude_session_handler.erl` | 589 | `pre_tool_use` | **Chained pair (2/2).** Must receive `FinalCtx` from permission_request above, not the original `HookCtx`. Threading: `permission_request(HookCtx) → {ok, Ctx1} → pre_tool_use(Ctx1#{event => pre_tool_use})`. |
| `codex_session_handler.erl` | 170 | `user_prompt_submit` | Matches `{deny,_} ->` |
| `codex_session_handler.erl` | 667 | `pre_tool_use` | `handle_server_request/4` |
| `codex_session_handler.erl` | 794 | `pre_tool_use` | `handle_approval_request/3` |
| `codex_exec.erl` | 125 | `user_prompt_submit` | `case fire(...) of` |
| `gemini_session_handler.erl` | 150 | `user_prompt_submit` | Matches `ok ->` |
| `opencode_session_handler.erl` | 215 | `user_prompt_submit` | Matches `{deny,_} ->` |
| `copilot_session_handler.erl` | 167 | `user_prompt_submit` | Matches `{deny,_} ->` |
| `copilot_session_handler.erl` | 634 | dynamic event | **Dual-mode dispatch + wire protocol translation.** Dispatches BOTH blocking and notification events through a single code path. Current match arms: `ok`, `{deny, Reason}`, `HookResult when is_map(HookResult)`, and catch-all `_`. Post-enhancement `fire/3` returns `{ok, Ctx} \| {deny, Reason}` — the `is_map(HookResult)` arm (line 639) and catch-all become dead code and must be removed. Rewrite to match `{ok, FinalCtx}` and extract wire-format fields from `FinalCtx`. |

**Anomalous (blocking event treated as notification):**

| File | Line | Event | Notes |
|------|------|-------|-------|
| `copilot_session_handler.erl` | 809 | `pre_tool_use` | `_ = fire_hook(pre_tool_use, Msg, HState)` — discards result of a blocking event. Either a bug or intentional fire-and-forget. Must be resolved during implementation. |

**Notification (`_ = fire(...)`):**

| File | Event |
|------|-------|
| `claude_session_handler.erl` | `session_start`, `session_end`, `post_tool_use`, `stop` |
| `codex_session_handler.erl` | `session_start`, `session_end`, `post_tool_use`, `stop` |
| `codex_exec.erl` | `session_end` |
| `gemini_session_handler.erl` | `session_start`, `session_end`, `post_tool_use`, `stop` |
| `opencode_session_handler.erl` | `session_start`, `session_end`, `stop` | **Parity gap:** missing `pre_tool_use` (blocking) and `post_tool_use` (notification). All other backends fire both. **In scope for Phase 2** — add fire sites in OpenCode's tool execution paths to match other backends. |
| `copilot_session_handler.erl` | `session_start`, `session_end`, `post_tool_use`, `stop` |

**Helper functions (delegate to core, type signature update only):**

| File | Function |
|------|----------|
| `codex_session_handler.erl:942` | `fire_hook/3` |
| `codex_exec.erl:411` | `fire_hook/3` |
| `opencode_session_handler.erl:1462` | `fire_hook/3` |
| `copilot_session_handler.erl:863` | `fire_hook/3` — **body change required**, not just type signature. The `undefined` registry clause returns bare `ok` (line 863). Must become `{ok, Context}` to match new return contract. Other backends delegate directly; only copilot has this short-circuit. |
| `beam_agent_hooks.erl:337` | `fire/3` |

---

## 5. Global Hooks

### 5.1 Motivation

Currently hooks are per-session — stored in handler state, passed via
`sdk_hooks` in session opts. There is no mechanism to register a hook
that applies to all sessions (e.g., an organization-wide audit hook or
a security policy hook).

Global hooks are stored in ETS and merged with session-local hooks at
fire time. They enable:
- Organization-wide policies that apply to every session
- Hot-added hooks that take effect on live sessions
- Default hooks that consumers can override per-session

### 5.2 Registry Design

**Architectural constraint:** beam-agent is a library application with
no supervision tree and no processes of its own. The global hook
registry follows the same pattern as `beam_agent_command_guard`: a
functional module backed by ETS + `persistent_term`. The caller owns
the control flow.

```erlang
%% New exports in beam_agent_hooks_core:
-export([
    register_global/1,       %% Register a hook globally (all sessions)
    unregister_global/1,     %% Remove a global hook
    global_registry/0        %% Retrieve the current global registry
]).
```

**Storage:**
- Global hooks in ETS table (via `beam_agent_ets:ensure_table/2`)
- Version counter in `persistent_term` for change detection
- Table created by `beam_agent:init/0` alongside existing tables

**Merge order at fire time:**
```
Global hooks (registration order) ++ Session hooks (registration order)
```

Global hooks fire first. Session hooks fire after, receiving the
context as modified by global hooks. This enables global policy hooks
to sanitize input before session-specific hooks see it.

### 5.3 Public API

```erlang
%% In beam_agent_hooks.erl:

-doc "Register a hook that fires for all sessions.".
-spec register_global(hook_def()) -> ok.

-doc "Remove a global hook by reference.".
-spec unregister_global(hook_def()) -> ok.

-doc "Retrieve the current global hook registry.".
-spec global_registry() -> hook_registry().
```

### 5.4 Fire Integration

`fire/3` gains a fourth source of hooks — the global registry:

```erlang
fire(Event, Context, SessionRegistry) ->
    GlobalRegistry = global_registry(),
    MergedHooks = merge_hooks(Event, GlobalRegistry, SessionRegistry),
    case is_blocking_event(Event) of
        true  -> fire_blocking(MergedHooks, Context);
        false -> fire_notification(MergedHooks, Context)
    end.
```

The merge is O(n) where n is the number of global hooks for that event.
In the common case (no global hooks), it's a map lookup returning `[]`.

---

## 6. Reload Bus — System-Wide Hot Reload

### 6.1 Architectural Requirement

The BEAM VM provides hot code loading, `persistent_term` for shared
immutable state, and message passing for process notification. beam-agent
must exploit all three for live reconfiguration of hooks, skills,
MCP servers, commands, and any other registrable component — without
restarting sessions, without dropping connections, without losing state.

### 6.2 Design

**Architectural constraint:** beam-agent is a library application with
no supervision tree and no processes of its own. The reload bus is a
**functional module** backed by ETS + `persistent_term`. The caller
owns the control flow. There is no bus process. This matches the
pattern established by `beam_agent_command_guard`.

```erlang
-module(beam_agent_reload_bus).

%% No process. State in ETS + persistent_term.
%% Call ensure_tables/0 from a durable host-app process at boot
%% (e.g., your top-level supervisor's init) so the subscriber
%% ETS table survives for the application's lifetime.

-export([
    ensure_tables/0,       %% Create ETS table (idempotent, call from host app)
    subscribe/0,           %% subscribe(self()) to all reload events
    subscribe/1,           %% subscribe(Component) to specific component
    unsubscribe/1,         %% Unsubscribe caller
    notify/2,              %% notify(Component, Meta) — bump version, fan-out
    version/0,             %% Global version counter
    version/1              %% Per-component version counter
]).

-type component() :: hooks | skills | mcp_servers
                    | commands | catalog | policy | all.
```

### 6.3 Mechanics

- **Version counters** in `persistent_term` (atomic reads, ~50ns)
- **Subscriber set** in ETS via `beam_agent_ets:ensure_table/2`
  (lazily created, owned by host application's boot process)
- **Fan-out** synchronous in the caller of `notify/2` — iterates
  subscriber ETS, sends messages, prunes dead pids
- **Table creation** via `beam_agent:init/0` (already called by host
  apps at boot)

**Subscriber message format:**
```erlang
{beam_agent_reload, Component :: component(),
 Version :: non_neg_integer(),
 Meta :: #{reason => term(), changed => [term()]}}
```

**Who subscribes:** Session engine processes (`gen_statem`) started by
the host application. They subscribe during `init/1` and receive
reload messages as `info` events.

### 6.4 Hook Reload Integration

When a global hook is registered or removed:

```erlang
register_global(HookDef) ->
    %% Insert into ETS...
    beam_agent_reload_bus:notify(hooks,
        #{reason => global_hook_added}).
```

Session engines receive `{beam_agent_reload, hooks, _, _}` and
invalidate their cached merged hook list. On next `fire/3`, the
fresh global registry is merged with session hooks.

### 6.5 Engine Reload Handling

The engine subscribes during `init/1` (runs inside the host-supervised
`gen_statem` process) and handles reload messages in all states:

```erlang
%% In init/1:
ok = beam_agent_reload_bus:subscribe(),

%% Handled in all states:
handle_event(info, {beam_agent_reload, Component, _Version, Meta},
             _State, #engine{handler_mod = Mod} = Data) ->
    case erlang:function_exported(Mod, handle_reload, 3) of
        true ->
            HState1 = Mod:handle_reload(Component, Meta,
                                         Data#engine.handler_state),
            {keep_state, Data#engine{handler_state = HState1}};
        false ->
            {keep_state, Data}  %% handler doesn't care about reloads
    end.
```

**Optional handler callback:**
```erlang
-callback handle_reload(Component :: beam_agent_reload_bus:component(),
                         Meta :: map(),
                         HandlerState :: term()) ->
    NewHandlerState :: term().
%% Optional. Called when a registrable component changes.
```

### 6.6 Subsystem Integration

| Subsystem | Current State | Reload Integration |
|-----------|--------------|-------------------|
| `beam_agent_hooks_core` | Per-session only | Global hooks + reload on global changes |
| `beam_agent_catalog_core` | ETS-backed, static after boot | Emit `{beam_agent_reload, catalog, ...}` on mutations |
| `beam_agent_skills_core` | Static per session | Emit `{beam_agent_reload, skills, ...}` on add/remove |
| `beam_agent_tool_registry` | ETS-backed | Emit `{beam_agent_reload, catalog, ...}` on changes |
| `beam_agent_command_policy` | Loaded at guard init | Emit `{beam_agent_reload, policy, ...}` on reload |

### 6.7 Safety Properties

1. **Atomic version bump.** `persistent_term:put/2` is atomic.
2. **Subscriber liveness.** Dead pids pruned during fan-out.
3. **No thundering herd.** BEAM message scheduling naturally staggers.
4. **Graceful degradation.** If a handler's `handle_reload/3` crashes,
   the engine catches it and continues. The session does not crash.

---

## 7. Performance

| Metric | Target | Rationale |
|--------|--------|-----------|
| `fire/3` overhead (no hooks) | <100ns | Map lookup + return |
| Per-hook dispatch overhead | <1µs | Match check + function call |
| Global registry merge | <1µs for 10 global hooks | List append |
| `persistent_term` read (version) | <50ns | Established pattern |
| Reload fan-out | <1ms for 100 sessions | ETS iterate + send |

Context threading adds one extra map binding per hook (the `{ok, Ctx1}`
match). This is negligible relative to the hook callback's own cost.

---

## 8. Implementation Phases

### Phase 1: Core Enhancement

**Goal:** Context threading, clean return types.

**Modified files:**
- `src/core/beam_agent_hooks_core.erl` — `safe_call/2`, `fire_blocking/2`,
  `fire_notification/2`, `fire/3`, `hook_callback()` type,
  `is_blocking_event/1` (add `subagent_start`, `pre_compact`, `config_change`)
- `src/public/beam_agent_hooks.erl` — `fire/3` return type, moduledoc

**Test changes:**
- `beam_agent_hooks_core_tests.erl` — rewrite all assertions matching
  `ok` from `fire/3` to match `{ok, _}` (~36 assertions)
- `prop_beam_agent_hooks_core.erl` — rewrite property assertions
  (`ok =:=` becomes `{ok, _}` pattern, ~2 assertions)

**New tests:**
- Context threading: hook A modifies `tool_input`, hook B sees modified value
- Deny mid-chain: verify context from last successful hook is not lost
- Ask mid-chain: `{ask, Reason}` stops chain and propagates to caller
- Crash mid-chain: crashing hook passes unmodified context forward
- Notification threading: notification hooks compose modifications
- Notification ignores deny/ask: `{deny, _}` and `{ask, _}` pass context through

**Acceptance criteria:**
- All rewritten hook tests pass
- Threading tests pass
- `fire/3` returns `{ok, Context}` in all non-blocking cases
- `{ask, Reason}` propagates correctly from blocking hooks
- All 15 `hook_event()` atoms retained (phantom wiring deferred to Phase 2)
- Zero dependencies added

### Phase 2: Handler Call Site Updates

**Goal:** All 5 backend handlers use transformed context from `fire/3`.

**Modified files:**
- `src/backends/claude/claude_session_handler.erl`
- `src/backends/codex/codex_session_handler.erl`
- `src/backends/codex/codex_exec.erl`
- `src/backends/gemini/gemini_session_handler.erl`
- `src/backends/opencode/opencode_session_handler.erl`
- `src/backends/copilot/copilot_session_handler.erl`
- `beam_agent_ex/lib/beam_agent/hooks.ex` — `@spec` and `@type` updates

**Changes per handler:**
1. All 11 blocking call sites: match `{ok, FinalCtx} | {deny, Reason} | {ask, Reason}`.
   Use `FinalCtx` for allow. Return `{error, {hook_denied, Reason}}` for deny.
   Return `{error, {hook_ask, Reason}}` for ask — the caller decides resolution.
2. `fire_hook/3` helpers: update return type spec
3. Where handlers use original variables after `fire/3`, switch to
   reading from the returned context
4. `claude_session_handler.erl:582`: `fire_permission_hooks/2` —
   thread `{ok, Ctx1}` from `permission_request` into the subsequent
   `pre_tool_use` call. Currently both receive the original `HookCtx`.
   After: `permission_request(HookCtx) → {ok, Ctx1} → pre_tool_use(Ctx1#{event => pre_tool_use})`
5. `copilot_session_handler.erl:634`: dual-mode dispatch + wire protocol —
   rewrite match arms to handle `{ok, FinalCtx} | {deny, Reason} | {ask, Reason}`.
   Remove dead `is_map(HookResult)` arm (line 639) and catch-all `_ -> #{}`
   (line 641). Extract wire-format fields from `FinalCtx`.
6. `copilot_session_handler.erl:863`: `fire_hook/3` undefined registry
   clause — change bare `ok` return to `{ok, Context}`. Only copilot
   has this short-circuit; other backends delegate directly.
7. `copilot_session_handler.erl:809`: resolve anomalous `_ = fire_hook(pre_tool_use, ...)`
   — either promote to proper blocking dispatch or document why
   fire-and-forget is intentional here
8. `copilot_session_handler.erl:627`: map `<<"errorOccurred">>` to
   `post_tool_use_failure` instead of the non-existent `error_occurred` atom

**Phantom event wiring:**
Wire all 8 phantom events to actual fire sites:
- `post_tool_use_failure` — fire in tool error paths (all backends)
- `subagent_start` / `subagent_stop` — fire in sub-session lifecycle
- `notification` — fire on backend notification/info message dispatch
- `pre_compact` — fire before context window compaction
- `config_change` — fire from reload bus integration (Phase 4)
- `task_completed` — fire on tool/task completion paths
- `teammate_idle` — fire when delegated agent completes and becomes available

**Elixir wrapper:**
- `beam_agent_ex/lib/beam_agent/hooks.ex` — update `@type hook_callback`
  and `@spec fire/3` to match new return types. Mandatory — the existing
  `@spec` declarations will be wrong after the core change.

**Acceptance criteria:**
- All 5 backend handler test suites pass
- A hook that modifies `prompt` in `user_prompt_submit` has the
  modification reflected in the query sent to the backend
- A hook that modifies `tool_input` in `pre_tool_use` has the
  modification reflected in the tool execution
- A hook returning `{ask, Reason}` propagates `{error, {hook_ask, Reason}}`
  to the caller across all 5 backends
- OpenCode fires `pre_tool_use` and `post_tool_use` (parity with other 4 backends)
- Cross-backend: same hook produces identical behavior on all 5 backends
- All 8 phantom events wired to actual fire sites
- `post_tool_use_failure` fires in tool error paths (all 5 backends)
- Copilot `error_occurred` → `post_tool_use_failure` mapping verified
- Elixir `BeamAgent.Hooks` types and specs match Erlang core
  (including `{ask, binary()}` return variant)

### Phase 3: Global Hooks + Reload Bus

**Goal:** Global hook registry, reload bus, live session updates.

**New files:**
- `src/core/beam_agent_reload_bus.erl`

**Modified files:**
- `src/core/beam_agent_hooks_core.erl` — `register_global/1`,
  `unregister_global/1`, `global_registry/0`, merge in `fire/3`
- `src/public/beam_agent_hooks.erl` — public global hook API
- `src/public/beam_agent.erl` — `init/0` calls
  `beam_agent_reload_bus:ensure_tables/0`
- `src/core/beam_agent_session_engine.erl` — subscribe to reload bus,
  handle `{beam_agent_reload, ...}` in all states
- `src/core/beam_agent_session_handler.erl` — optional `handle_reload/3`
  callback

**New tests:**
- `test/core/beam_agent_reload_bus_tests.erl`
- Global hook registration → appears in `fire/3` for all sessions
- Global hooks fire before session hooks (merge order)
- Reload bus: subscriber receives notification on global hook change
- Reload bus: dead subscriber pruning
- Live session update: register global hook → next fire in existing
  session includes the new hook
- Version counter: monotonically increasing, atomic reads

**Acceptance criteria:**
- Global hooks work across all 5 backends
- Reload bus notifies live sessions
- Existing per-session hook behavior unchanged when no global hooks exist
- Zero new processes, zero new supervision

### Phase 4: System-Wide Reload Integration

**Goal:** Wire reload bus into all registrable subsystems.

**Modified files:**
- `src/core/beam_agent_catalog_core.erl` — emit reload on mutations
- `src/core/beam_agent_skills_core.erl` — emit reload on add/remove
- `src/core/beam_agent_tool_registry.erl` — emit reload on changes
- `src/core/beam_agent_command_policy.erl` — emit reload on policy change

**New tests:**
- Per-subsystem: register skill → session receives notification
- Full lifecycle: start session → add global hook → add skill →
  change policy → all reflected in live session without restart

**Acceptance criteria:**
- All registrable subsystems emit reload notifications
- Live sessions respond to all component types
- No subsystem change requires session restart
- Existing tests for all modified subsystems pass unchanged

---

## 9. File Inventory

### New Files (1 Erlang + 2 test)

```
src/core/beam_agent_reload_bus.erl            # Reload bus (functional module)
test/core/beam_agent_reload_bus_tests.erl     # Reload bus tests
test/core/beam_agent_hooks_threading_tests.erl # Context threading tests
```

### Modified Files (16)

```
src/core/beam_agent_hooks_core.erl            # Core enhancement + global hooks
src/public/beam_agent_hooks.erl               # Public API (return types + global)
src/public/beam_agent.erl                     # init/0 calls reload bus ensure_tables
src/core/beam_agent_session_engine.erl        # Reload handling
src/core/beam_agent_session_handler.erl       # Optional handle_reload/3 callback
src/backends/claude/claude_session_handler.erl
src/backends/codex/codex_session_handler.erl
src/backends/codex/codex_exec.erl
src/backends/gemini/gemini_session_handler.erl
src/backends/opencode/opencode_session_handler.erl
src/backends/copilot/copilot_session_handler.erl
beam_agent_ex/lib/beam_agent/hooks.ex         # Elixir wrapper: @spec/@type updates (mandatory)
src/core/beam_agent_catalog_core.erl          # Phase 4: reload on mutations
src/core/beam_agent_skills_core.erl           # Phase 4: reload on add/remove
src/core/beam_agent_tool_registry.erl         # Phase 4: reload on changes
src/core/beam_agent_command_policy.erl        # Phase 4: reload on policy change
```

### Comparison to Pipe Architecture

| Metric | Pipe Architecture | Hooks Enhancement |
|--------|------------------|-------------------|
| New Erlang files | 19 | 1 |
| New Elixir files | 4 | 0 |
| New test files | 13 | 2 |
| Modified files | 13 | 16 |
| New abstractions | 4 (behaviour, context, compiler, runner) | 0 |
| New concepts for consumers | Pipeline, pipe points, pipe context | `{ok, ModifiedCtx}` return |

---

## 10. Use Case Examples

### Prompt Rewriting

A hook that prepends system context to every query:

```erlang
beam_agent_hooks:hook(user_prompt_submit, fun(Ctx) ->
    Prompt = maps:get(prompt, Ctx),
    Enriched = <<"[Project: my-app] ", Prompt/binary>>,
    {ok, Ctx#{prompt => Enriched}}
end)
```

### Tool Input Sanitization

A hook that normalizes file paths in tool input:

```erlang
beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_input, Ctx, #{}) of
        #{<<"file_path">> := Path} = Input ->
            Normalized = normalize_path(Path),
            {ok, Ctx#{tool_input => Input#{<<"file_path">> => Normalized}}};
        _ ->
            {ok, Ctx}  %% no file_path, pass through unchanged
    end
end)
```

### Post-Tool Output Enrichment

A notification hook that annotates tool output for downstream hooks:

```erlang
beam_agent_hooks:hook(post_tool_use, fun(Ctx) ->
    Content = maps:get(content, Ctx, <<>>),
    {ok, Ctx#{content => Content,
              metadata => #{processed_at => erlang:system_time(millisecond)}}}
end)
```

### Composing Hooks (the whole point)

Hook A sanitizes input, Hook B sees the sanitized version:

```erlang
%% Hook A: strip dangerous patterns
Sanitize = beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    Input = maps:get(tool_input, Ctx, #{}),
    Safe = sanitize_input(Input),
    {ok, Ctx#{tool_input => Safe}}
end),

%% Hook B: log the (already sanitized) input
Audit = beam_agent_hooks:hook(pre_tool_use, fun(Ctx) ->
    %% This sees Hook A's sanitized input, not the original
    logger:info("Tool input: ~p", [maps:get(tool_input, Ctx, #{})]),
    {ok, Ctx}
end),

%% Registration order = execution order
beam_agent:start_session(#{sdk_hooks => [Sanitize, Audit]})
```

---

## 11. Open Questions

1. **Should global hooks be orderable relative to session hooks?**
   Current design: global hooks always fire first. An alternative is
   priority-based ordering (e.g., global hooks have priority 0, session
   hooks have priority 100, consumers can set any priority). This adds
   complexity — start simple, add if needed.

2. **Should `fire/3` accept an optional accumulator?**
   Some handlers might want to pass additional state through the hook
   chain beyond the context map. The context map's `assigns`-like
   pattern (just add keys) may be sufficient. Defer unless a concrete
   use case emerges.

---

## 12. SDK Boundary — What's Intentionally Out of Scope

beam-agent is a runtime substrate, not a product. MonkeyClaw (and
other consumers) build product-level features on top. This plan
targets **functional parity** — implementing outcomes idiomatically
in Erlang/OTP — not feature-for-feature parity with Claude Code's
hook system.

### Out of scope (mechanism-level concerns, not outcomes)

| Claude Code Feature | Why Out of Scope | beam-agent Equivalent |
|---------------------|------------------|-----------------------|
| Command hooks (shell subprocess) | BEAM fun/1 callbacks are superior — no process isolation needed, no serialization overhead, full type safety | fun/1 *is* the answer |
| HTTP hooks | Direct function calls beat HTTP round-trips for in-process hooks | fun/1 |
| `suppressOutput` / `systemMessage` / `continue` | UI control fields for a terminal renderer. beam-agent has no UI — consumers own their rendering | Consumer's responsibility |
| `updatedMCPToolOutput` (as separate field) | Context threading already enables tool output transformation via the context map — no dedicated field needed | `{ok, ModifiedCtx}` return |
| `additionalContext` (as separate field) | Same — hooks can add arbitrary keys to the context map | `{ok, ModifiedCtx}` return |

### Design principle

> Anything the agentic coders can do, we can do better — but "better"
> means idiomatic Erlang/OTP, SOLID, safe, secure, and fault-tolerant.
> We implement the *outcome*, not the mechanism. Porting known-bad
> patterns from Node.js into BEAM would be writing known-bad code.

