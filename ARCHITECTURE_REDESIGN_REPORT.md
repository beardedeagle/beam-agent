# BeamAgent Architecture Redesign Report

**Date**: 2026-03-29
**Scope**: Full architecture research, industry comparison, ideal target state design
**Goal**: Determine the ideal architecture for BeamAgent given its 6 design constraints, informed by industry patterns and Claude Code SDK internals

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Design Constraints (Non-Negotiable)](#2-design-constraints-non-negotiable)
3. [The Verdict: Consolidation, Not Rewrite](#3-the-verdict-consolidation-not-rewrite)
4. [What's Architecturally Sound (Don't Touch)](#4-whats-architecturally-sound-dont-touch)
5. [Industry Comparison: BEAM Multi-Backend SDK Patterns](#5-industry-comparison-beam-multi-backend-sdk-patterns)
6. [Claude Code Architecture and MonkeyClaw Requirements](#6-claude-code-architecture-and-monkeyclaw-requirements)
7. [Target Architecture Blueprint](#7-target-architecture-blueprint)
8. [ETS Table Redesign](#8-ets-table-redesign)
9. [Backend Contract](#9-backend-contract)
10. [Extensibility: Adding Inference API SDKs and New Backends](#10-extensibility-adding-inference-api-sdks-and-new-backends)
11. [Packaging Boundaries](#11-packaging-boundaries)
12. [Public API Surface](#12-public-api-surface)
13. [The Public/Core Split Verdict](#13-the-publiccore-split-verdict)
14. [Resource Budget](#14-resource-budget)
15. [Erlang Packaging and Design Best Practices](#15-erlang-packaging-and-design-best-practices)
16. [Security Requirements for MonkeyClaw](#16-security-requirements-for-monkeyclaw)
17. [Implementation Roadmap](#17-implementation-roadmap)
18. [Trade-offs](#18-trade-offs)
19. [Sources](#19-sources)

---

## 1. Executive Summary

BeamAgent currently has 149 modules (~64,700 LOC) and ~75 ETS tables for an SDK wrapping 5 agentic coder backends. Four parallel research tracks (ideal architecture design, BEAM multi-backend SDK patterns, Claude Code internals, and Erlang packaging best practices) converge on the same conclusion:

**The architecture is fundamentally sound. The bloat is structural over-decomposition, not architectural unsoundness. It is fixable through aggressive consolidation without losing a single feature.**

The target state:

| Metric | Current | Target | Delta |
|--------|---------|--------|-------|
| Module count | 149 | ~85 | -64 |
| ETS tables | ~75 | ~20 | -55 |
| Public API modules | 37 | 14 | -23 |
| Lines of code | ~64,700 | ~52,000 | -20% |
| persistent_term keys | 13 | 13 | 0 |
| Runtime dependencies | 0 | 0 | 0 |
| Features lost | - | - | 0 |

The session engine / handler behaviour / transport behaviour spine is architecturally correct and maps directly to patterns used by Tesla, Ecto, and Swoosh. The `native_or` fallback routing is the correct parity mechanism. The security pipeline is correctly decomposed. The backend self-containment is already extraction-ready for independent hex packages.

Critically, the architecture must also scale to accommodate **new backend categories**: additional agentic coder backends (Cursor, Aider, Windsurf, etc.) and raw inference provider API SDKs (Anthropic API, OpenAI API, Google AI API, Mistral, etc.). The current flat behaviour contract assumes all backends are session-based agentic coders, which does not fit stateless API backends. This report addresses the gap with an Ecto-style composite sub-behaviour contract that makes the session engine optional, enabling both categories to coexist behind the same unified interface with zero core changes per new backend.

What needs to change: eliminate 24 pure-delegation wrappers, unify 3 identical registry patterns, collapse ~15 single-caller `_core` modules, consolidate 4 config modules into 1, merge ~55 ETS tables into ~20 via namespaced keys.

---

## 2. Design Constraints (Non-Negotiable)

These are the 6 constraints that every architectural decision must satisfy:

a) **5 backend SDKs extractable as independent hex packages** -- Each backend (Claude, Codex, Gemini, OpenCode, Copilot) must be self-contained and publishable as its own hex package with minimal work.

b) **Single unified interface with feature parity** -- If one backend has a feature natively, all backends get it via universal fallback. The consumer never needs to know which backend supports what natively.

c) **SOLID, correct, complete, defensive, safe, secure, modern, idiomatic Erlang, resilient, fault-tolerant, performant** -- Engineering excellence is not optional.

d) **Minimize resource utilization** -- ETS tables, processes, memory -- as aggressively as possible across all resources.

e) **Never force design decisions on the consumer** -- Library, not framework. No mandatory supervisors, no required OTP structures. Let the caller own the process tree.

f) **North star consumer is MonkeyClaw** -- A *Claw (Claude Code) clone with security-first posture.

---

## 3. The Verdict: Consolidation, Not Rewrite

All four research tracks agree:

**FOR consolidation:**
- The session engine (`gen_statem`), handler behaviour, transport behaviour, and `native_or` routing are proven and correct
- 2361 eunit tests pass, dialyzer is clean, all features work
- A rewrite loses every tested behaviour, every edge case fix, every backend quirk already solved
- Rewrites of working systems consistently take 2-3x longer than estimated
- The comparable BEAM libraries (Tesla 31 modules, Ecto 25 modules, ExAws 16 modules) validate that ~85 modules is a reasonable target for BeamAgent's genuine complexity

**AGAINST rewrite:**
- The problem is structural (too many modules, too many ETS tables), not behavioral (wrong abstractions, wrong patterns)
- The foundational patterns (`beam_agent_table_owner`, `native_or`, session handler behaviour) are validated by industry research as correct
- Backend self-containment is already at the right boundary for package extraction
- The security pipeline is correctly decomposed per security best practices

---

## 4. What's Architecturally Sound (Don't Touch)

### Session Engine

`beam_agent_session_engine` is a `gen_statem` that owns the connection lifecycle: connecting -> initializing -> ready -> active_query -> reconnecting -> error. It handles buffering, consumer management, and queue overflow protection identically for all 5 backends. This IS the session -- it is the process the consumer supervises.

This maps directly to Claude Code's session model (JSONL-persisted conversation history with continue/resume/fork). The engine handles reconnection, buffering, and state management while the handler provides the backend-specific codec.

### Handler Behaviour

`beam_agent_session_handler` defines the backend contract: 6 required callbacks + 7 optional callbacks. This matches Ecto's composite sub-behaviour pattern -- the gold standard for multi-backend abstraction in the BEAM ecosystem. Each backend only implements what it supports; the engine provides the rest.

### Transport Behaviour

`beam_agent_transport` is a clean 5-callback contract (`start/1`, `send/2`, `close/1`, `is_ready/1`, `status/1`, `classify_message/2`). Each transport (port/stdio, WebSocket, HTTP SSE) is genuinely distinct.

### `native_or` Fallback Routing

The `native_or` pattern in `beam_agent_core` tries the native backend call first; on `{error, {unsupported_native_call, _}}`, runs the universal fallback. This is exactly the Swoosh `@optional_callbacks` + degradation pattern, implemented idiomatically in Erlang.

### Security Pipeline

8 modules covering parse -> policy -> validate -> guard -> execute -> audit. Each layer is independently testable and replaceable. Security-critical code SHOULD be over-decomposed for auditability.

### Table Ownership Model

`beam_agent_table_owner` follows the correct Erlang pattern: caller calls `init/1` in their own process, tables are owned by the caller or by shard processes linked to the caller with `{heir, Consumer, TableName}`. The library never owns tables independently.

### Backend Self-Containment

Each backend in `src/backends/<backend>/` is fully self-contained:
- Facade implementing `beam_agent_behaviour`
- Session module wrapping `beam_agent_session_engine`
- Session handler implementing `beam_agent_session_handler`
- Protocol encoder/decoder
- Backend-specific extras (Codex has realtime protocol, Copilot has frame codec, etc.)

No cross-backend dependencies exist. This is already extraction-ready for independent hex packages.

---

## 5. Industry Comparison: BEAM Multi-Backend SDK Patterns

### Comparison Table

| Library | Core Modules | Backend Count | Contract Mechanism | Optional Features | Packaging | ETS Usage | Consumer API |
|---------|-------------|--------------|-------------------|-------------------|-----------|-----------|-------------|
| **Tesla** | ~31 (9 core + 22 middleware) | 6 adapters | `@behaviour Tesla.Adapter` -- 1 callback (`call/2`) | None -- pass-through opts | Single package, all in-tree | None | 2 modules |
| **Swoosh** | ~50 (40 adapters + core) | 40 providers | `@behaviour Swoosh.Adapter` -- 3 callbacks | `@optional_callbacks [deliver_many: 2]` | Single package, all in-tree | None | 1 module via `use` |
| **Ecto** | ~25 core | Unlimited | Composite: base + 4 sub-behaviours | Compile-time gating on sub-behaviours | Core + SQL + per-driver packages | None in SDK | 1 module via `use Ecto.Repo` |
| **ExAws** | ~16 core | N/A (services) | Operation struct + protocol dispatch | Protocol dispatch on struct type | One hex package per service | None | 1 module: `ExAws` |
| **Commanded** | ~20 core | 2 shipped | 11 required callbacks | `function_exported?/3` arity guards | Single + separate adapter packages | None in SDK | `Commanded.Application` |
| **gen_smtp** | ~8 | Unlimited | 13 required + 3 optional via `-optional_callbacks` | `erlang:function_exported/3` | Single OTP application | None | 2 modules |
| **BeamAgent (current)** | 149 | 5 | 5 req + 6 opt callbacks | `native_or` fallback routing | Single package | ~75 tables | 37 modules |
| **BeamAgent (target)** | ~85 | 5 | Same (no change needed) | Same (no change needed) | 7 packages (core + 5 backends + Elixir) | ~20 tables | 14 modules |

### Key Design Patterns from Industry

#### Pattern 1: Minimal Behaviour Contract (Tesla)
One required callback is enough when all backends share the same data shape. Tesla adapters all take a request env and return a response env. Options are pass-through -- unknown options never cause contract violations.

#### Pattern 2: `@optional_callbacks` + Graceful Degradation (Swoosh)
Mark capabilities as optional. The framework checks with `function_exported?/3` and provides a fallback implementation. Consumers never see the difference. This maps directly to BeamAgent's `native_or` pattern.

#### Pattern 3: Composite Sub-Behaviour Gating (Ecto)
Split the contract into a required base + capability sub-behaviours. Use compile-time inspection to gate which public API functions exist. If an adapter doesn't declare `Ecto.Adapter.Transaction`, the consumer's repo module literally doesn't have `transaction/2`.

#### Pattern 4: Operation Struct + Protocol Dispatch (ExAws)
When backends share the same execution engine but differ in how requests are built, use data-oriented dispatch. Services produce data (operation structs); the engine consumes it. Service packages are pure struct builders with zero runtime dependencies on each other.

#### Pattern 5: `Code.ensure_loaded?` Compile-Time Guarding (Tesla/Swoosh)
All in-tree adapters are guarded at load time so missing optional dependencies don't break compilation. Each adapter module is conditionally compiled only when its dependency is available.

#### Pattern 6: `use` Macro as Single Entry Point
All five libraries surface one entry point. The consumer never calls adapter modules directly. Adapter swaps are config changes, not API changes.

#### Pattern 7: No Processes in SDK Layer
Official Elixir Library Guidelines (directly applicable to Erlang): "Libraries should avoid spawning background processes independently." All five libraries have zero ETS and zero processes in their SDK layer. State is either caller-owned or in a process the caller starts and supervises.

#### Pattern 8: Package Extraction (ExAws v2)
Core package owns: auth, signing, HTTP execution, retry, config, telemetry. Service package owns: request building (struct construction only), response parsing, type specs. Contract: operation protocol. Zero cross-service imports. One-way dependency direction.

---

## 6. Claude Code Architecture and MonkeyClaw Requirements

### Claude Code's 5-Layer Architecture

```
User Prompt
     |
     v
Session Layer          -- persistent conversation history, resume, fork, compaction
     |
     v
Agent Loop             -- multi-turn execution, tool dispatch, result handling
     |
     v
Tool / Hook Layer      -- built-in tools + MCP tools + lifecycle hooks
     |
     v
Permission Layer       -- allow/deny rules, permission modes, canUseTool callbacks
     |
     v
Backend / Model        -- Claude API (or routed alternative)
```

### Claude Code SDK Feature Matrix

**Session Model**: JSONL files on disk at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Full conversation transcript: every prompt, every tool call, every tool result, every response. APIs: `listSessions`, `getSessionMessages`, `getSessionInfo`, `renameSession`, `tagSession`, `continue`, `resume`, `forkSession`, `persistSession: false` (ephemeral).

**Context Compaction**: Auto-fires at ~95% context window utilization. `PreCompact` hook fires before compaction for archival. Session memory writes summaries in background for near-instant compaction.

**Tool System**: Built-in tools (`Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `Agent`, `AskUserQuestion`). MCP tools addressed as `mcp__<server-name>__<action>`. Custom tools via `tool()` function with Zod schema + handler. External MCP servers via `.mcp.json`.

**Permission Evaluation Order** (strictly sequential):
1. Hooks -- can allow, deny, or pass through
2. Deny rules (`disallowedTools`) -- matched tools blocked in all modes, including `bypassPermissions`
3. Permission mode -- global posture
4. Allow rules (`allowedTools`) -- pre-approved tools skip prompting
5. `canUseTool` callback -- runtime approval; skipped in `dontAsk` mode

**Permission Modes**: `default`, `dontAsk` (TS only), `acceptEdits`, `bypassPermissions`, `plan`

**Subagent Model**: Isolated agent instances with own context window, system prompt, tool access, permission mode, optional own model and MCP servers. Cannot spawn other subagents (no recursion). Can be foreground (blocking) or background (concurrent). Custom subagents defined as Markdown files in `.claude/agents/`.

### Full Hook Event Table

| Hook Event | Fires When | Can Block? |
|------------|-----------|------------|
| `PreToolUse` | Tool call requested | Yes -- allow / deny / modify input |
| `PostToolUse` | Tool execution completed | No -- can inject additionalContext |
| `PostToolUseFailure` | Tool execution failed | No |
| `UserPromptSubmit` | User prompt submitted | Can inject context |
| `Stop` | Agent execution stops | No |
| `SubagentStart` | Subagent initializes | No |
| `SubagentStop` | Subagent completes | No |
| `PreCompact` | Compaction requested | Archive before summary |
| `PermissionRequest` | Permission dialog would appear | Custom handling |
| `SessionStart` | Session initializes (TS only) | No |
| `SessionEnd` | Session terminates (TS only) | No |
| `Notification` | Agent status message | No |
| `Setup` | Session setup (TS only) | No |
| `TeammateIdle` | Teammate becomes idle (TS only) | No |
| `TaskCompleted` | Background task done (TS only) | No |
| `ConfigChange` | Config file changes (TS only) | Reload settings |
| `WorktreeCreate` / `WorktreeRemove` | Git worktree lifecycle (TS only) | Cleanup |

### MonkeyClaw Feature Tiers

**TIER 1 -- Must-Have (blocking for any useful session)**
- Session lifecycle: create, continue, resume, fork
- Multi-turn agent loop with streaming
- Built-in tool set: Bash, Read, Write, Edit, Glob, Grep
- `PreToolUse` / `PostToolUse` hooks
- Allow/deny tool rules + permission modes
- `canUseTool` runtime approval callback
- Auto-compaction + `PreCompact` hook
- MCP server integration
- Abort / cancellation propagation
- Audit logging of all tool decisions

**TIER 2 -- Should-Have (needed for production Claude Code clone)**
- Subagent spawn, delegate, await, cancel
- Subagent lifecycle hooks (SubagentStart, SubagentStop)
- Background (concurrent) subagents
- Subagent-scoped MCP servers and permission modes
- File checkpointing (snapshot + revert)
- SessionStart/SessionEnd hooks
- `UserPromptSubmit` hook (prompt injection defense)
- `Notification` hook (ops integration)
- Git worktree isolation per subagent
- Fork session / ephemeral session
- Effort control, fallback model routing
- Multi-agent teams (cross-session coordination)

**TIER 3 -- Nice-to-Have (extend incrementally)**
- Session tagging, renaming, search
- Long-term memory (cross-session recall, embedding adapters)
- Scheduled / routine execution
- Artifact store (plans, diffs, reviews)
- Durable event journal (replayable)
- Pluggable storage adapters
- Routing policy engine (round-robin, sticky, failover, capability-first)
- Auto-compaction policy control (thresholds, strategies)
- Telemetry spans for routing, memory, compaction

---

## 7. Target Architecture Blueprint

### Module Inventory by Tier

#### Tier 1: Session Spine (7 modules) -- KEEP AS-IS

| Module | LOC | Responsibility | Why Separate |
|--------|-----|---------------|-------------|
| `beam_agent_core` | 1441 | Types, routing helpers (`native_or`, `native_call`, `with_session_backend`), message normalization | Central type registry + routing; every module depends on its types |
| `beam_agent_session_engine` | 1424 | `gen_statem` connection lifecycle, buffering, consumer management, queue overflow | This IS the session process |
| `beam_agent_session_handler` | ~370 | Behaviour: `init_handler/1`, `handle_data/2`, `encode_query/3`, etc. | Behaviour contract must be separate from engine (Erlang convention) |
| `beam_agent_transport` | 61 | Behaviour: `start/1`, `send/2`, `close/1`, `is_ready/1`, `status/1`, `classify_message/2` | Same -- behaviour definition separate from implementors |
| `beam_agent_backend` | 211 | Backend registry: `normalize/1`, `adapter_module/1`, `session_backend/1` | Centralizes 5-backend routing |
| `beam_agent_behaviour` | 72 | Top-level adapter behaviour: `start_link/1`, `send_query/4`, etc. | Contract between core and 5 adapter facades |
| `beam_agent_adapter_types` | 91 | Shared type re-exports for adapter facades | Eliminates type duplication; pure type module |

#### Tier 2: Public API Surface (14 modules) -- CONSOLIDATED FROM 37

| Module | Responsibility | Action |
|--------|---------------|--------|
| `beam_agent` | Session lifecycle: `start_session/1`, `query/2`, `stop/1`, events | KEEP -- primary entry point |
| `beam_agent_config` | Session + global config with fallback chain | MERGE `beam_agent_config_core` + `beam_agent_global_config` + `beam_agent_sdk_config` into one |
| `beam_agent_capabilities` | Capability matrix: `supports/2`, `status/2`, `for_session/1` | KEEP (708 LOC, substantial) |
| `beam_agent_command` | Command execution with security pipeline | KEEP paired with `beam_agent_command_core` |
| `beam_agent_mcp` | MCP server management, tool registry | KEEP (1449 LOC) |
| `beam_agent_runtime` | Model, permissions, status, interrupts | FOLD `beam_agent_runtime_core` into it |
| `beam_agent_control` | Collaboration, review, realtime, server admin | FOLD `beam_agent_control_core` + `beam_agent_collaboration` into it |
| `beam_agent_session_store` | Session CRUD, message history | KEEP paired with `_core` (multiple internal callers) |
| `beam_agent_threads` | Thread lifecycle | FOLD `beam_agent_threads_core` into it |
| `beam_agent_hooks` | SDK lifecycle hooks | KEEP paired with `_core` (used by session handlers directly) |
| `beam_agent_catalog` | Tools, skills, plugins, agents, models -- unified catalog query | ABSORB `beam_agent_agents`, `beam_agent_plugins`, `beam_agent_slash_commands`, `beam_agent_skills`, `beam_agent_file`, `beam_agent_search` |
| `beam_agent_telemetry` | Telemetry emission | FOLD `beam_agent_telemetry_core` into it |
| `beam_agent_raw` | Escape hatch for direct backend calls | KEEP -- explicitly separate from unified API |
| `beam_agent_provider` | Provider/agent selection | FOLD into `beam_agent_config` |

**Modules to DELETE outright** (pure delegation wrappers absorbed into above):
- `beam_agent_agents` (21 LOC) -> `beam_agent_catalog`
- `beam_agent_plugins` (21 LOC) -> `beam_agent_catalog`
- `beam_agent_slash_commands` (21 LOC) -> `beam_agent_catalog`
- `beam_agent_sdk_config` (25 LOC) -> `beam_agent_config`
- `beam_agent_account` (45 LOC) -> `beam_agent_config` or `beam_agent_runtime`
- `beam_agent_apps` (48 LOC) -> `beam_agent_runtime`
- `beam_agent_file` (65 LOC) -> `beam_agent_catalog`
- `beam_agent_search` (~50 LOC) -> `beam_agent_catalog`
- `beam_agent_todo` (75 LOC) -> `beam_agent_runtime`

#### Tier 3: Canonical Domain Modules (~22 modules) -- KEEP, SLIM PAIRS

Durable domain subsystems. Pair is justified only when core has multiple internal callers.

| Module Group | Purpose | ETS | Keep Pair? | Action |
|-------------|---------|-----|-----------|--------|
| `beam_agent_journal` + `_core` + `_store` | Durable event journal | 3 tables | YES -- core called by audit + public | Keep |
| `beam_agent_routines` + `_core` + `_store` | Scheduled execution | 3 tables | YES -- core called by routine_runner + public | Keep |
| `beam_agent_runs` + `_core` + `_store` | Run/step lifecycle | 2 tables | YES -- core called by orchestrator + public | Keep |
| `beam_agent_orchestrator` + `_core` + `_store` | Parent-child delegation | 2 tables | YES -- 1368 LOC real logic | Keep |
| `beam_agent_memory` + `_core` + `_store` | Long-term memory | 1 table | YES -- 1396 LOC, used by context_core | Keep |
| `beam_agent_artifacts` + `_core` + `_store` | Artifact storage | 1 table | NO -- only 1 caller | COLLAPSE core into parent |
| `beam_agent_audit` + `_core` | Audit records | 0 | NO -- audit is a journal layer | COLLAPSE into `beam_agent_journal` |
| `beam_agent_context` + `_core` | Context pressure/compaction | 0 | NO -- only 1 caller | COLLAPSE |
| `beam_agent_content` + `_core` | Content normalization | 0 | NO -- only 1 caller | COLLAPSE |
| `beam_agent_policy` + `_core` | Allow/deny profiles | 1 table | NO -- only 1 caller | COLLAPSE |
| `beam_agent_routing` + `_core` | Backend routing | 2 -> 1 | NO -- only 1 caller | COLLAPSE |
| `beam_agent_checkpoint` + `_core` | Checkpoint/rewind | 1 table | NO -- only 1 caller | COLLAPSE |

#### Tier 4: Security Pipeline (8 modules) -- KEEP AS-IS

| Module | LOC | Layer |
|--------|-----|-------|
| `beam_agent_command` | 629 | Public entry |
| `beam_agent_command_core` | 643 | Execute + orchestrate |
| `beam_agent_command_parser` | 609 | Layer 0: structural parse |
| `beam_agent_command_policy` | 352 | Layer 1: static rules |
| `beam_agent_command_validator` | 194 | Layer 2: pluggable behaviour |
| `beam_agent_command_validator_default` | 34 | Default validator impl |
| `beam_agent_command_guard` | 904 | Layer 3: stateful guard (ETS state machine) |
| `beam_agent_command_audit` | 212 | Layer 5: audit trail |

Security-critical code where each layer is independently testable and replaceable. Do not merge.

#### Tier 5: Infrastructure (14 modules) -- CONSOLIDATED FROM ~20

| Module | Responsibility | Action |
|--------|---------------|--------|
| `beam_agent_ets` | ETS write proxy (hardened mode) | KEEP |
| `beam_agent_table_owner` | Table ownership, sharding, write proxy loop | KEEP |
| `beam_agent_store` | Store adapter boundary (ETS/DETS switching) | KEEP |
| `beam_agent_store_ets` | ETS store adapter | KEEP |
| `beam_agent_store_dets` | DETS store adapter | KEEP |
| `beam_agent_json` | Safe JSON decode with size limit | KEEP |
| `beam_agent_jsonl` | JSONL line-delimited parsing | KEEP |
| `beam_agent_jsonrpc` | JSON-RPC 2.0 encode/decode | KEEP |
| `beam_agent_credential` | AES-256-GCM credential encryption | KEEP |
| `beam_agent_redaction` | Sensitive data redaction | ABSORB `beam_agent_sensitive_keys` |
| `beam_agent_events` | Event subscription bus | KEEP |
| `beam_agent_reload_bus` | Hot-reload notification | KEEP |
| `beam_agent_os_signal` | OS signal handling | KEEP |
| `beam_agent_registry` | **NEW** unified parameterized registry | CREATE (replaces `beam_agent_agent_registry` + `beam_agent_plugin_registry` + `beam_agent_slash_registry`) |

**DELETE**: `beam_agent_agent_registry`, `beam_agent_plugin_registry`, `beam_agent_slash_registry` (3 identical patterns -> 1 parameterized module)
**FOLD**: `beam_agent_error_core` -> `beam_agent_core`, `beam_agent_sensitive_keys` -> `beam_agent_redaction`

#### Tier 6: MCP Protocol (5 modules) -- KEEP AS-IS

| Module | LOC | Responsibility |
|--------|-----|---------------|
| `beam_agent_mcp_protocol` | 1635 | Wire protocol encode/decode |
| `beam_agent_mcp_dispatch` | 1006 | Server-side dispatch |
| `beam_agent_mcp_client_dispatch` | 1181 | Client-side dispatch |
| `beam_agent_tool_registry` | 668 | Tool + MCP server registry |
| `beam_agent_mcp` (public) | 1449 | Public API |

All five are substantial (650+ LOC each). Protocol, dispatch (inbound vs outbound), tool registry, and public API are genuinely different concerns.

#### Tier 7: Transport Implementations (10 modules) -- KEEP AS-IS

| Module | LOC | Responsibility |
|--------|-----|---------------|
| `beam_agent_transport` | 61 | Behaviour definition |
| `beam_agent_transport_port` | 90 | Erlang port transport (stdio to CLI) |
| `beam_agent_transport_ws` | 90 | WebSocket transport |
| `beam_agent_transport_http` | 77 | HTTP SSE transport |
| `beam_agent_transport_utils` | 103 | Shared transport helpers |
| `beam_agent_ws_client` | 478 | WebSocket client implementation |
| `beam_agent_ws_frame` | 315 | WebSocket frame codec |
| `beam_agent_http_client` | 307 | HTTP client for SSE |
| `beam_agent_mcp_transport_http` | 144 | MCP over HTTP |
| `beam_agent_mcp_transport_stdio` | 85 | MCP over stdio |

Each maps 1:1 to a distinct transport mechanism.

#### Tier 8: Backends (31 modules) -- KEEP AS-IS

Each backend follows this structure:
```
<backend>_<facade>.erl       -- implements beam_agent_behaviour
<backend>_session.erl        -- thin start_link wrapper around session_engine
<backend>_session_handler.erl -- implements beam_agent_session_handler
<backend>_protocol.erl       -- wire protocol encode/decode
[backend-specific modules]   -- e.g., codex_exec, copilot_frame, etc.
```

| Backend | Modules | LOC | Backend-Specific Extras |
|---------|---------|-----|------------------------|
| Claude | 4 | 2,767 | `claude_session_store` (server-side session ops) |
| Codex | 9 | 4,494 | `codex_exec`, `codex_port_utils`, `codex_realtime_*` (3 modules) |
| Copilot | 5 | 3,401 | `copilot_frame` (frame codec) |
| Gemini | 7 | 2,920 | `gemini_wire`, `gemini_translate`, `gemini_reverse_requests` |
| OpenCode | 6 | 3,775 | `opencode_http`, `opencode_sse` |

Per-backend module count (4-9) reflects genuine complexity differences. Do not normalize.

#### Tier 9: Misc Core (consolidation targets)

| Module | LOC | Action |
|--------|-----|--------|
| `beam_agent_collaboration` | 521 | FOLD into `beam_agent_control` |
| `beam_agent_attachments` | 688 | KEEP (substantial, multiple callers) |
| `beam_agent_router` | ~200 | FOLD into `beam_agent_routing` |
| `beam_agent_routine_runner` | ~200 | KEEP (separate execution concern) |
| `beam_agent_raw_core` | ~150 | FOLD into `beam_agent_raw` |
| `beam_agent_app_core` | ~200 | FOLD into `beam_agent_runtime` |
| `beam_agent_account_core` | ~150 | FOLD into `beam_agent_config` |
| `beam_agent_file_core` | ~150 | FOLD into `beam_agent_catalog` |
| `beam_agent_search_core` | ~200 | FOLD into `beam_agent_catalog` |
| `beam_agent_skills_core` | ~200 | FOLD into `beam_agent_catalog` |
| `beam_agent_config_core` | ~250 | FOLD into `beam_agent_config` |
| `beam_agent_global_config` | ~150 | FOLD into `beam_agent_config` |

### Module Count Summary

| Category | Current | Target | Delta |
|----------|---------|--------|-------|
| Session spine | 7 | 7 | 0 |
| Public API | 37 | 14 | -23 |
| Canonical domains | ~30 | ~22 | -8 |
| Security pipeline | 8 | 8 | 0 |
| Infrastructure | ~20 | 14 | -6 |
| MCP protocol | 5 | 5 | 0 |
| Transports | 10 | 10 | 0 |
| Backends | 31 | 31 | 0 |
| **Total** | **149** | **~85** | **-64** |

---

## 8. ETS Table Redesign

### Principle

One table per distinct access pattern (type + concurrency combination), namespaced keys within.

### Target: 20 Tables (from ~75)

| # | Table Name | Type | Options | Modules Using | Key Pattern |
|---|-----------|------|---------|---------------|-------------|
| 1 | `beam_agent_registry` | set | `read_concurrency` | Unified registry, capabilities, tool_registry | `{agent, Id}`, `{plugin, Id}`, `{slash, Id}`, `{capability, Backend, Cap}`, `{cap_meta, Key}`, `{tool, SessionId, Name}`, `{mcp, Name}` |
| 2 | `beam_agent_config` | set | `read_concurrency` | Config (unified) | `{session, SessionId, Key}`, `{global, Key}` |
| 3 | `beam_agent_backend_sessions` | set | `read_concurrency` | Backend | `{Pid, Backend}` |
| 4 | `beam_agent_hooks` | duplicate_bag | none | Hooks core | `{Point, Hook}` (ordered by priority) |
| 5 | `beam_agent_events` | set | `read_concurrency` | Events | `{Ref, Pid, SessionKey}`, `{session, SessionKey, Ref}` |
| 6 | `beam_agent_reload` | set | `read+write_concurrency` | Reload bus | `{subscriber, Pid}`, `{version, Type}` |
| 7 | `beam_agent_sessions` | set | `read_concurrency` | Session store core | `{SessionId, Meta}` |
| 8 | `beam_agent_session_messages` | ordered_set | `read_concurrency` | Session store core | `{SessionId, SeqNo}` -- ordering critical |
| 9 | `beam_agent_runtime` | set | `read_concurrency` | Runtime, control, collaboration | `{runtime, SessionKey, Key}`, `{control_config, Key}`, `{control_task, Id}`, `{review, Id}`, `{realtime, Id}`, `{app, Id}`, `{account, Id}`, `{search, Id}`, `{checkpoint, Id}` |
| 10 | `beam_agent_domains` | set | `read_concurrency` | Threads, routing, policy, memory, artifacts | `{thread, Id}`, `{routing, Key}`, `{policy, Id}`, `{memory, Id}`, `{artifact, Id}` |
| 11 | `beam_agent_store_config` | set | `read_concurrency` | Store | `{Domain, Config}` |
| 12 | `beam_agent_guard_state` | set | `read+write_concurrency` | Command guard | Guard state + rate limits (namespaced) |
| 13 | `beam_agent_command_history` | ordered_set | `read_concurrency` | Command guard | Time-ordered history -- must be ordered_set |
| 14 | `beam_agent_active_commands` | set | `write_concurrency` | Command guard | Write-heavy tracking |
| 15 | `beam_agent_journal_events` | set | `read_concurrency` | Journal store | Event records |
| 16 | `beam_agent_journal_sequence` | ordered_set | `read_concurrency` | Journal store | Replay ordering -- must be ordered_set |
| 17 | `beam_agent_journal_acks` | set | `read_concurrency` | Journal store | Consumer acknowledgments |
| 18 | `beam_agent_routines_jobs` | set | `read_concurrency` | Routines store | Job records |
| 19 | `beam_agent_routines_due` | ordered_set | `read_concurrency` | Routines store | Due-time scheduling -- must be ordered_set |
| 20 | `beam_agent_routines_claims` | set | `read+write_concurrency` | Routines store | Lock state for concurrent claim |

### Storage Decision Framework

| Storage Mechanism | Use When | Avoid When |
|-------------------|----------|------------|
| **ETS (named table)** | Mutable state, cross-process visibility, per-key concurrent reads/writes | Single-process state; use process state instead |
| **persistent_term** | Read millions/sec, rarely or never updated (config flags, dispatch tables, compiled match specs) | Frequently updated -- each write triggers global GC |
| **Caller-owned state** | State scoped to a single session/process | State needing cross-session visibility |
| **Explicit options map** | Per-call configuration, library functions | State surviving across calls |
| **application:get_env** | Per-application boot-time defaults only | Library configuration (forces global namespace, prevents multi-instance) |

### Why All 20 Tables Need ETS

Every table needs cross-session or cross-process visibility:
- Registries: global by definition
- Config: sessions need to read defaults set before they started
- Sessions/threads: listing requires querying across all session pids
- Command guard: rate limits are per-node, not per-session
- Journal/routines: durable domain data persisted across session lifecycles

---

## 9. Backend Contract

The backend contract must serve two fundamentally different categories of backend:

1. **Agentic coder backends** (Claude, Codex, Gemini, OpenCode, Copilot, and future additions like Cursor, Aider, Windsurf) -- long-running session processes communicating via stdio/WebSocket/HTTP with a CLI tool
2. **Inference API backends** (Anthropic API, OpenAI API, Google AI API, Mistral API, and future additions) -- stateless HTTP request/response with no persistent process or transport

The current flat `beam_agent_behaviour` assumes all backends are session-based. This must be refactored into a composite sub-behaviour system (following the Ecto pattern) before consolidation begins.

### Base Behaviour: `beam_agent_adapter` (ALL backends implement this)

```erlang
-module(beam_agent_adapter).

%% Required -- the universal contract every backend must satisfy:
-callback backend_name() -> atom().
-callback backend_type() -> agentic | api.
-callback capabilities() -> [capability()].
-callback query(query_request(), adapter_opts()) ->
    {ok, [message()]} | {error, term()}.
-callback stream(query_request(), adapter_opts()) ->
    {ok, stream_ref()} | {error, term()}.

%% Types
-type capability() :: atom().
-type query_request() :: #{
    prompt := binary(),
    model => binary(),
    max_tokens => pos_integer(),
    system_prompt => binary(),
    tools => [tool_def()],
    messages => [message()]
}.
-type adapter_opts() :: #{
    timeout => timeout(),
    stream => boolean(),
    atom() => term()
}.
```

The base contract is intentionally minimal: name yourself, declare your type and capabilities, handle a query, handle streaming. Every backend -- agentic or API -- can satisfy this. The `query_request()` type is the normalized input shape; adapters translate it to their wire format internally.

### Sub-Behaviour: `beam_agent_adapter_session` (Agentic coder backends)

```erlang
-module(beam_agent_adapter_session).

%% Required -- agentic backends that manage persistent sessions:
-callback start_link(session_opts()) -> {ok, pid()} | {error, term()}.
-callback send_query(pid(), binary(), query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
-callback receive_message(pid(), reference(), timeout()) ->
    {ok, message()} | {error, term()}.
-callback health(pid()) -> ready | connecting | initializing | active_query | error.
-callback stop(pid()) -> ok.

%% Optional -- backends with control protocols:
-callback send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
-callback interrupt(pid()) -> ok | {error, term()}.
-callback handle_control_request(binary(), map()) -> permission_result().
-callback session_info(pid()) -> {ok, map()} | {error, term()}.
-callback set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
-callback set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.

-optional_callbacks([
    send_control/3,
    interrupt/1,
    handle_control_request/2,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).
```

This is the existing `beam_agent_behaviour` contract, now scoped to its correct category. Agentic backends use the session engine (`gen_statem`), transport behaviours, and session handler behaviours exactly as they do today. No changes to existing backend code.

### Sub-Behaviour: `beam_agent_adapter_api` (Inference API backends)

```erlang
-module(beam_agent_adapter_api).

%% Required -- stateless API backends:
-callback chat(messages(), api_opts()) ->
    {ok, response()} | {error, term()}.
-callback chat_stream(messages(), api_opts()) ->
    {ok, stream_pid()} | {error, term()}.

%% Optional -- not all APIs support these:
-callback embeddings(input(), api_opts()) ->
    {ok, [vector()]} | {error, term()}.
-callback models(api_opts()) ->
    {ok, [model_info()]} | {error, term()}.
-callback cancel(request_id()) -> ok | {error, term()}.

-optional_callbacks([
    embeddings/2,
    models/1,
    cancel/1
]).

%% Types
-type messages() :: [#{role := binary(), content := binary()}].
-type api_opts() :: #{
    model := binary(),
    max_tokens => pos_integer(),
    temperature => float(),
    tools => [tool_def()],
    api_key => binary(),
    base_url => binary(),
    atom() => term()
}.
-type response() :: #{
    content := binary(),
    model := binary(),
    usage := #{prompt_tokens := non_neg_integer(),
               completion_tokens := non_neg_integer()},
    stop_reason => binary(),
    tool_calls => [tool_call()]
}.
```

API backends are stateless -- no `start_link`, no process, no transport. They make HTTP calls and return results. The unified layer wraps responses in the normalized `message()` format so consumers never see the difference.

### Sub-Behaviour: `beam_agent_adapter_tools` (Tool-capable backends)

```erlang
-module(beam_agent_adapter_tools).

%% Backends that support native tool/function calling:
-callback format_tools([tool_def()]) -> term().
-callback parse_tool_calls(response()) -> [tool_call()].
-callback format_tool_results([tool_result()]) -> term().

-optional_callbacks([]).
```

This sub-behaviour is relevant to both agentic and API backends. Agentic coders have their own tool systems; inference APIs support function calling. The unified layer needs to know how to translate tools for each backend.

### Session Handler Behaviour (Agentic backends only)

```erlang
%% Required (6):
-callback backend_name() -> atom().
-callback init_handler(session_opts()) -> init_result().
-callback handle_data(binary(), HandlerState) -> data_result().
-callback encode_query(binary(), query_opts(), HandlerState) ->
    {ok, [handler_action()], HandlerState}.
-callback build_session_info(HandlerState) -> map().
-callback terminate_handler(term(), HandlerState) -> ok.

%% Optional (7+):
-callback transport_started(transport_ref(), HandlerState) -> HandlerState.
-callback handle_connecting(transport_event(), HandlerState) -> phase_result().
-callback handle_initializing(transport_event(), HandlerState) -> phase_result().
-callback encode_interrupt(HandlerState) ->
    {ok, [handler_action()], HandlerState} | not_supported.
-callback handle_control(binary(), map(), gen_statem:from(), HandlerState) ->
    control_result().
-callback handle_set_model(binary(), HandlerState) ->
    {ok, term(), [handler_action()], HandlerState} | {error, term()}.
-callback handle_set_permission_mode(binary(), HandlerState) ->
    {ok, term(), [handler_action()], HandlerState} | {error, term()}.
-callback on_state_enter(state_name(), state_name() | undefined, HandlerState) ->
    {ok, [handler_action()], HandlerState}.
-callback is_query_complete(message(), HandlerState) -> boolean().

-optional_callbacks([
    transport_started/2,
    handle_connecting/2,
    handle_initializing/2,
    encode_interrupt/1,
    handle_control/4,
    handle_set_model/2,
    handle_set_permission_mode/2,
    on_state_enter/3,
    is_query_complete/2
]).
```

The session engine is a generic `gen_statem`; the handler is the backend-specific codec. This separation means the engine handles reconnection, buffering, queue overflow, and consumer management identically for all agentic backends. API backends skip this layer entirely.

### Unified Routing in `beam_agent_core`

The core dispatcher inspects which sub-behaviours a backend declares and routes accordingly:

```erlang
%% In beam_agent_core -- the unified dispatch
query(Backend, Prompt, Opts) ->
    Mod = beam_agent_backend:adapter_module(Backend),
    case Mod:backend_type() of
        agentic ->
            %% Session-based: start_link, send_query, receive_message
            session_query(Mod, Prompt, Opts);
        api ->
            %% Stateless: direct HTTP call, normalize response
            Messages = build_messages(Prompt, Opts),
            case Mod:chat(Messages, Opts) of
                {ok, Response} -> {ok, normalize_response(Response)};
                {error, _} = Err -> Err
            end
    end.

%% Feature dispatch with sub-behaviour awareness
native_or(Mod, Feature, Args, Fallback) ->
    case erlang:function_exported(Mod, Feature, length(Args)) of
        true  -> apply(Mod, Feature, Args);
        false -> Fallback(Args)
    end.
```

### Graceful Return Convention

Optional callbacks that a backend partially supports should return `not_supported` as an explicit atom (not `{error, not_supported}`), so callers can distinguish "unsupported feature" from "feature tried and failed":

```erlang
-callback checkpoint(state()) -> {ok, binary()} | not_supported.
```

### Type Export Gap

`session_opts()` and `query_opts()` are defined only in `beam_agent_core`. For backend extraction as independent packages, these types need to be in `beam_agent_adapter_types` (which exists but only re-exports a subset). Add `session_opts()`, `query_opts()`, `message()`, `message_type()`, `query_request()`, and `adapter_opts()` exports.

---

## 10. Extensibility: Adding Inference API SDKs and New Backends

### The Core Question

Does the architecture scale when we add inference provider API SDKs or additional agentic coder backends? This section stress-tests the design.

### Scenario 1: Adding More Agentic Coder Backends

Adding backend #6 (Cursor), #7 (Aider), #8 (Windsurf), etc. scales perfectly:

- Each new backend is 4-9 modules following the same pattern (facade + session + handler + protocol + extras)
- Implements `beam_agent_adapter` (base) + `beam_agent_adapter_session` (session sub-behaviour)
- Implements `beam_agent_session_handler` for the session engine
- Self-contained in `src/backends/<backend>/`, extractable as its own hex package
- Core stays at ~80 modules, unchanged
- ETS tables stay at ~20, unchanged (backends don't create their own)
- `native_or` handles parity automatically

**Cost per new agentic backend**: 4-9 new modules, 0 core changes. Linear scaling.

### Scenario 2: Adding Inference API SDKs

Adding raw API backends (Anthropic API, OpenAI API, Google AI API, Mistral, etc.):

- Each API backend is 1-3 modules (adapter + optional protocol helpers)
- Implements `beam_agent_adapter` (base) + `beam_agent_adapter_api` (API sub-behaviour)
- Optionally implements `beam_agent_adapter_tools` if the API supports function calling
- **Does NOT implement** `beam_agent_adapter_session` or `beam_agent_session_handler` -- no session engine, no transport, no `gen_statem`
- Self-contained in `src/backends/<backend>/`, extractable as its own hex package
- Core stays unchanged. The `backend_type() -> api` return tells the dispatcher to use the stateless path.

**Cost per new API backend**: 1-3 new modules, 0 core changes. Linear scaling.

**Example**: An Anthropic API backend would look like:

```
src/backends/anthropic_api/
    anthropic_api.erl              -- implements beam_agent_adapter, beam_agent_adapter_api, beam_agent_adapter_tools
    anthropic_api_protocol.erl     -- HTTP request building, response parsing
```

2 modules. The adapter builds HTTP requests to the Anthropic Messages API, parses responses, formats tool definitions, and returns normalized `message()` records. No session engine, no transport, no process.

### Scenario 3: Mixed Agentic + API Backends Coexisting

The unified `beam_agent` entry point handles both categories transparently:

```erlang
%% Consumer code -- identical regardless of backend type:
{ok, Session} = beam_agent:start_session(#{backend => claude}).       %% agentic
{ok, Result}  = beam_agent:query(Session, <<"Explain this code">>).

{ok, Session} = beam_agent:start_session(#{backend => anthropic_api}). %% API
{ok, Result}  = beam_agent:query(Session, <<"Explain this code">>).
```

For API backends, `start_session/1` returns a lightweight session handle (no process, just a state map) rather than a pid. The session store tracks both types. The consumer API is identical.

### Scenario 4: Features That Only Apply to One Category

Some features are inherently category-specific:

| Feature | Agentic Only | API Only | Both |
|---------|-------------|----------|------|
| Session persistence (resume/fork) | X | | |
| Transport management (reconnect) | X | | |
| MCP server integration | X | | |
| Permission modes | X | | |
| Collaboration/review | X | | |
| Embeddings | | X | |
| Fine-tuning | | X | |
| Tool/function calling | | | X |
| Streaming | | | X |
| Context compaction | X | | |
| Model selection | | | X |
| Rate limiting | | | X |
| Credential management | | | X |
| Audit logging | | | X |

The `beam_agent_capabilities` module already handles this -- `supports(Backend, Feature)` returns `true` or `false`. API backends declare their capabilities via the `capabilities/0` callback; agentic backends declare theirs. The consumer checks before calling category-specific features.

### Scaling Assessment

| Scenario | Core Changes | ETS Impact | New Modules Per Backend | Risk |
|----------|-------------|------------|------------------------|------|
| Add agentic coder #6 | None | None | 4-9 | Low |
| Add agentic coder #10 | None | None | 4-9 | Low |
| Add 1st inference API SDK | Sub-behaviour addition (one-time) | None | 1-3 | Medium (one-time) |
| Add 5 more inference API SDKs | None after first | None | 1-3 each | Low |
| Mix agentic + API in same app | `backend_type()` routing (one-time) | None | 0 | Medium (one-time) |
| Add embeddings capability | New sub-behaviour (one-time) | None | 0 | Low |
| Add fine-tuning capability | New sub-behaviour (one-time) | None | 0 | Low |
| Scale to 20 total backends | None | None | Linear | Low |

### Key Architectural Decisions for Extensibility

1. **Sub-behaviours must be defined before consolidation begins** (Phase 0 of implementation roadmap). This is a design-time decision, not a retrofit.

2. **`backend_type/0` is the routing discriminator**. The core dispatcher checks this once per query and takes the appropriate path. No runtime overhead for backends that don't need it.

3. **API backends get a lightweight session handle, not a process**. This maintains the `start_session/query/stop` consumer API while avoiding unnecessary process overhead for stateless backends.

4. **The `native_or` pattern extends naturally**. "Does this backend support sessions? If yes, session path. If no, stateless path." Same mechanism, new dimension.

5. **Feature parity takes on a new meaning with mixed categories**. Some features (MCP, collaboration) only make sense for agentic backends. Others (embeddings) only for API backends. The capability matrix handles this cleanly.

6. **Package structure scales linearly**. Each new backend is a new hex package regardless of category: `beam_agent_cursor`, `beam_agent_anthropic_api`, etc. The core package never grows.

---

## 11. Packaging Boundaries

### Target: 7 Hex Packages

```
beam_agent              -- unified SDK (what consumers depend on)
beam_agent_claude       -- Claude backend (extractable)
beam_agent_codex        -- Codex backend (extractable)
beam_agent_copilot      -- Copilot backend (extractable)
beam_agent_gemini       -- Gemini backend (extractable)
beam_agent_opencode     -- OpenCode backend (extractable)
beam_agent_ex           -- Elixir wrapper (depends on beam_agent)
```

### What Ships in `beam_agent` (Core Package)

Everything in Tiers 1-7: session spine, public API, canonical domains, security pipeline, infrastructure, MCP protocol, transports. ~80 modules. No backend code.

### What Ships in Each `beam_agent_<backend>` Package

Only the modules in `src/backends/<backend>/`. Each backend declares `beam_agent` as a dependency:

```erlang
%% beam_agent_claude/rebar.config
{deps, [{beam_agent, "~> 0.2"}]}.
```

### Extraction Surgery Required

Minimal:
1. Move type exports (`session_opts()`, `query_opts()`, `message()`) to `beam_agent_adapter_types`
2. Split `rebar.config` `src_dirs` per backend
3. Create per-backend `.app.src` files with `{applications, [kernel, stdlib, beam_agent]}`
4. No code changes inside backend modules themselves

### Hex Publishing Constraint

Hex enforces: a published package cannot have git dependencies, only other hex packages. The core package must be published to hex before any backend package can be published. Use `_checkouts/` for local development before core is published.

### Required `.app.src` Metadata Per Package

```erlang
{application, beam_agent_claude, [
    {description, "Claude Code backend for beam_agent"},
    {vsn, "0.1.0"},
    {licenses, ["MIT"]},
    {links, [{"GitHub", "https://github.com/yourorg/beam-agent-claude"}]},
    {applications, [kernel, stdlib, beam_agent]}
]}.
```

---

## 12. Public API Surface

### Consumer Sees 14 Modules

```erlang
%% Session lifecycle (primary entry point)
beam_agent:start_session/1, query/2, query/3, stop/1
beam_agent:event_subscribe/1, receive_event/2, event_unsubscribe/2
beam_agent:health/1, backend/1, list_backends/0
beam_agent:set_model/2, set_permission_mode/2

%% Configuration (unified session + global with fallback)
beam_agent_config:get/2, set/3, get_global/1, set_global/2

%% Feature introspection
beam_agent_capabilities:supports/2, status/2, for_session/1, all/0

%% Catalog (agents, plugins, skills, slash commands, tools, models)
beam_agent_catalog:register/3, unregister/2, get/2, list/1

%% Command execution
beam_agent_command:run/2, run/3

%% MCP management
beam_agent_mcp:server_status/1, set_servers/2, tool/4

%% Runtime control
beam_agent_runtime:interrupt/1, abort/1, set_model/2

%% Session control (collaboration, review, realtime, admin)
beam_agent_control:start_review/2, collaboration_modes/1

%% Session storage
beam_agent_session_store:list_sessions/0, get_session/1

%% Thread management
beam_agent_threads:start/2, resume/2, list/1, fork/2

%% Hooks
beam_agent_hooks:register/1, register_global/1, fire/3

%% Telemetry
beam_agent_telemetry:emit/3, attach/4

%% Escape hatch
beam_agent_raw:call/3
```

### API Shape Principle

Every public function follows one of these patterns:

```erlang
%% Session-scoped (needs a live pid)
beam_agent:query(Session, Prompt) -> {ok, [message()]} | {error, term()}.

%% Session-or-id (pid for live, binary for persisted)
beam_agent_session_store:get_session(SessionOrId) -> {ok, meta()} | {error, not_found}.

%% Global (no session context)
beam_agent_catalog:list(agents) -> [agent_def()].

%% Init (called once, idempotent)
beam_agent:init(#{table_access => hardened}) -> ok.
```

---

## 13. The Public/Core Split Verdict

**The blanket public/core split is not worth keeping.** Replace with a targeted rule.

### Current Problem

24 of 37 public modules are pure delegation -- every function is a one-liner call to `_core`. This doubles module count for zero benefit.

### The Claimed Benefit

Test isolation via `-ifdef(TEST)` exports. But: most `_core` modules have no `-ifdef(TEST)` blocks at all. Only `beam_agent_session_engine` actually uses this pattern.

### The Better Rule

**A module gets a `_core` partner only when it has multiple callers OR needs `-ifdef(TEST)` exports.**

**Keep the pair:**

| Pair | Why |
|------|-----|
| `beam_agent_session_store` + `_core` | Core called by session handlers, backend facades, and public module (3+ callers) |
| `beam_agent_hooks` + `_core` | Core called by session handlers directly for `fire/3` |
| `beam_agent_command` + `_core` | Security pipeline; core called by guard and public module |
| `beam_agent_journal` + `_core` | Core called by audit and public module |
| `beam_agent_routines` + `_core` | Core called by routine_runner and public module |
| `beam_agent_runs` + `_core` | Core called by orchestrator and public module |
| `beam_agent_orchestrator` + `_core` | 1368 LOC of real logic, multiple domain callers |
| `beam_agent_memory` + `_core` | 1396 LOC, used by context_core for compaction |

**Collapse into single module:** Everything else (only one caller, no `-ifdef(TEST)` exports, under 500 LOC combined).

### Test Isolation Without Module Splitting

For modules needing test-only exports without a separate `_core`:

```erlang
-ifdef(TEST).
-export([internal_helper/1, validate_thing/2]).
-endif.
```

This works in the same module. `-ifdef(TEST)` exports are only visible in test builds. The concern about "polluting the public API" is a non-issue.

---

## 14. Resource Budget

| Metric | Current | Target | Rationale |
|--------|---------|--------|-----------|
| **Module count** | 149 | ~85 | -24 pure-delegation, -3 duplicate registries, -15 single-caller cores, -10 tiny absorbed, -3 config consolidation |
| **ETS tables** | ~75 | 20 | Namespaced keys; splits only for different table types or concurrency requirements |
| **Public API modules** | 37 | 14 | Domains that earned their names; everything else folded in |
| **persistent_term keys** | 13 | 13 | All correctly write-once/write-rarely; no change |
| **Lines of code** | ~64,700 | ~52,000 | -20% from eliminating delegation boilerplate, duplicate registry code, redundant scaffolding |
| **Processes spawned** | 0 (+ session engines) | 0 (+ session engines) | No mandatory supervisors per constraint (e) |
| **Backend modules** | 31 | 31 | No change -- intrinsic complexity |
| **Transport modules** | 10 | 10 | No change -- distinct mechanisms |
| **Runtime deps** | 0 | 0 | Zero runtime deps. `json` is OTP 27 stdlib. |

---

## 15. Erlang Packaging and Design Best Practices

### Configuration Strategy (Ranked Best to Worst)

1. **Explicit options map per call** (best) -- No global state, composable, testable, two instances can have different configs.
2. **Options map at process/session start** -- Validated once at boundary, stored in process state. No global ETS touched.
3. **`persistent_term` for truly global, rarely-changing values** -- Access mode, dispatch tables, compiled match specs. BeamAgent's use is correct.
4. **`application:get_env` for library defaults only** (use sparingly) -- Acceptable for deployer defaults in `sys.config`, never for per-instance config. Anti-pattern: two callers in the same node can't have different configs.

### Process Ownership Guidelines

**Library SHOULD NOT own:**
- Named ETS tables created without caller participation
- Background processes started outside caller-provided supervisor
- Application env keys in other applications' namespaces
- Timers firing independently of caller's lifecycle

**Library SHOULD own (or provide):**
- Pure functions -- no side effects, no process dependencies
- Behaviour/callback contracts
- Message-format helpers (decode/encode)
- Convenience init functions the caller invokes in their own process
- A supervisor module the caller can `child_spec/1` into their tree

### Storage Callback Injection Pattern

For maximum flexibility, accept a storage module or function as an option:

```erlang
beam_agent:start_session(claude, #{
    store => {my_app_session_store, [table_ref]}
}).
```

Callers can use ETS, DETS, Mnesia, Redis, or an in-process map. The library stays pure.

### The `-optional_callbacks` Attribute

Since OTP 18.0, use `-optional_callbacks([...])` for callbacks not all backends implement. The dispatcher uses `erlang:function_exported/3` to check at runtime:

```erlang
native_or_fallback(Mod, State, Args) ->
    case erlang:function_exported(Mod, native_mcp_call, 2) of
        true  -> Mod:native_mcp_call(Args, State);
        false -> universal_mcp_fallback(Args, State)
    end.
```

This is exactly what BeamAgent's `native_or` pattern already does.

### Graceful Return Convention

Optional callbacks should return `not_supported` (not `{error, not_supported}`) so callers can distinguish "unsupported" from "tried and failed":

```erlang
-callback checkpoint(state()) -> {ok, binary()} | not_supported.
```

---

## 16. Security Requirements for MonkeyClaw

### Non-Negotiable Security Controls

| Control | Implementation |
|---------|---------------|
| Deny rules before permission modes | `disallowedTools` checked before `bypassPermissions`; cannot be overridden |
| No `bypassPermissions` without explicit opt-in | `allowDangerouslySkipPermissions: true` required; never default |
| `PreToolUse` hooks for all destructive operations | Block Bash write ops, `.env` access, `/etc` writes, credential paths |
| Static analysis of Bash commands | Flag commands touching system files, sudo, sensitive paths |
| Filesystem isolation | Agent writes only to configured directories; sensitive paths never accessible |
| Credential proxy pattern | Agent never sees raw credentials; proxy injects into outgoing requests |
| MCP tool surface minimization | Scope MCP servers to the subagent that needs them |
| Subagent permission inheritance audit | Subagents do not auto-inherit parent permissions; explicit grant required |
| Audit log all tool approvals and denials | `PostToolUse` hooks emit structured audit records |
| Network egress control | Agent communicates through proxy with domain allowlist |
| Sensitive credential file exclusion | Never mount `.env`, `~/.aws/credentials`, `~/.kube/config`, `*.pem`, `*.key` |
| `PreCompact` hook archives transcripts | Never lose evidence of what agent did before compaction |
| Rate limiting and budget enforcement | `max_turns`, `max_budget_usd`, error on exceeded limits |
| `dontAsk` mode for headless/automation | Explicit tool surface; unexpected tools denied |

### MonkeyClaw-Specific Requirements

1. All destructive Bash commands require hook validation -- never auto-approved in production
2. Credential redaction in audit logs -- scan tool inputs/outputs before emitting
3. Path normalization before policy match -- resolve symlinks, strip `..`
4. Workspace filesystem boundary enforcement -- cwd is the hard boundary
5. MCP server allowlist per session -- no wildcard MCP grants
6. Subagent `bypassPermissions` prohibition -- only in fully sandboxed environments
7. Every `PermissionRequest` event audited -- decision reason, tool name, session ID

---

## 17. Implementation Roadmap

Each step is independently shippable and testable. No big bang.

### Phase 0: Sub-Behaviour Contract Refactor (MUST BE FIRST)

**What**: Define the composite sub-behaviour system before any consolidation work begins. Create `beam_agent_adapter` (base), `beam_agent_adapter_session` (agentic), `beam_agent_adapter_api` (stateless), and `beam_agent_adapter_tools` (tool-capable). Refactor existing `beam_agent_behaviour` callbacks into `beam_agent_adapter` + `beam_agent_adapter_session`. Add `-optional_callbacks` to `beam_agent_session_handler`. Update `beam_agent_core` dispatch to route on `backend_type()`.

**Why first**: This is a design-time decision that shapes everything downstream. If done as a retrofit after consolidation, it requires re-touching every module that was just refactored. Doing it first means all subsequent phases build on the extensible foundation.

**Impact on existing backends**: Minimal. Existing 5 agentic backends add `beam_agent_adapter` + `beam_agent_adapter_session` to their `-behaviour` declarations and implement `backend_name/0`, `backend_type/0` (returns `agentic`), and `capabilities/0`. Their existing callbacks stay exactly as they are.

**New modules**: `beam_agent_adapter` (~60 LOC), `beam_agent_adapter_api` (~80 LOC), `beam_agent_adapter_tools` (~40 LOC). `beam_agent_adapter_session` absorbs `beam_agent_behaviour` (rename, not net-new).

**ETS impact**: None.

### Phase 1: Config Consolidation (4 modules -> 1)

**What**: Merge `beam_agent_config_core`, `beam_agent_global_config`, `beam_agent_sdk_config` into `beam_agent_config`. Add the missing fallback chain: session -> global -> hardcoded defaults.

**Why first**: Config is referenced everywhere. Fixing the single-source-of-truth gap first means every subsequent change builds on a solid foundation.

**ETS impact**: 4 tables -> 1 (`beam_agent_config` with namespaced keys `{session, Id, Key}` and `{global, Key}`).

### Phase 2: Registry Unification (6 modules -> 2)

**What**: Create `beam_agent_registry` with parameterized `kind` atom. Delete `beam_agent_agent_registry`, `beam_agent_plugin_registry`, `beam_agent_slash_registry`. Update callers.

**Why second**: Eliminates the most obviously duplicated code pattern.

**ETS impact**: 3 tables -> 1 (`beam_agent_registry` with keys `{agent, Id}`, `{plugin, Id}`, `{slash, Id}`).

### Phase 3: Pure-Delegation Wrapper Deletion (9 modules -> 0)

**What**: Delete `beam_agent_agents`, `beam_agent_plugins`, `beam_agent_slash_commands`, `beam_agent_sdk_config`, `beam_agent_account`, `beam_agent_apps`, `beam_agent_file`, `beam_agent_search`, `beam_agent_todo`. Move logic (if any) into target modules (`beam_agent_catalog`, `beam_agent_config`, `beam_agent_runtime`).

**Why third**: Largest module-count reduction with lowest risk. These wrappers are 21-75 LOC each.

### Phase 4: Single-Caller Core Collapses (~15 modules absorbed)

**What**: For each `_core` module with only one caller and no `-ifdef(TEST)` exports, fold the implementation into the parent module.

**Targets**: `beam_agent_runtime_core`, `beam_agent_control_core`, `beam_agent_threads_core`, `beam_agent_telemetry_core`, `beam_agent_context_core`, `beam_agent_content_core`, `beam_agent_policy_core`, `beam_agent_routing_core`, `beam_agent_checkpoint_core`, `beam_agent_artifacts_core`, `beam_agent_raw_core`, `beam_agent_app_core`, `beam_agent_account_core`, `beam_agent_file_core`, `beam_agent_search_core`, `beam_agent_skills_core`.

### Phase 5: ETS Table Merges (~55 tables eliminated)

**What**: Consolidate tables that share the same access pattern (type + concurrency) into shared tables with namespaced keys. Maintain strict per-table type/concurrency requirements.

**High priority** (biggest impact): runtime/control/collaboration tables into `beam_agent_runtime`; domain stores into `beam_agent_domains`; registry tables into `beam_agent_registry`.

**Careful**: Do NOT merge tables with different `ordered_set` vs `set` types or different concurrency requirements.

### Phase 6: Catalog Creation

**What**: Create `beam_agent_catalog` unifying agents, plugins, skills, slash_commands, file, and search capabilities under one query interface: `beam_agent_catalog:register/3`, `unregister/2`, `get/2`, `list/1`.

### Phase 7: Domain Collapses

**What**: Fold `beam_agent_audit` into `beam_agent_journal` (audit is a journal layer). Absorb `beam_agent_collaboration` into `beam_agent_control`. Absorb `beam_agent_sensitive_keys` into `beam_agent_redaction`. Absorb `beam_agent_error_core` into `beam_agent_core`. Absorb `beam_agent_router` into `beam_agent_routing`.

---

## 18. Trade-offs

| Decision | Pros | Cons |
|----------|------|------|
| Composite sub-behaviour contract | Supports both agentic + API backends; extensible to new categories; Ecto-proven pattern | One more abstraction layer; existing backends need minor declaration updates |
| Eliminate blanket public/core split | -64 modules, -20% LOC, simpler navigation | Modules with test-only exports now use `-ifdef(TEST)` in public module |
| Unified registry with `kind` parameter | 3 modules -> 1, 3 ETS tables -> 1 | Slightly more complex key structure; `ets:tab2list` returns mixed types |
| 20 ETS tables via namespaced keys | 55 fewer tables, dramatic resource reduction | Some tables become larger; `ets:match_object` patterns get more complex |
| Backend extraction as hex packages | Independent versioning, consumers choose backends | 7+ rebar.config files; CI matrix expands; version coordination |
| Keeping security pipeline at 8 modules | Each layer independently testable/replaceable/auditable | 8 modules for one subsystem; may seem over-engineered |
| Keeping session engine + handler separation | Backend authors only implement handler; engine handles state machine | Two modules to understand; handler callback surface is large |
| Lightweight session handle for API backends | Uniform `start_session/query/stop` consumer API regardless of backend type | Slight impedance mismatch: "session" means different things for agentic vs API |
| Phase 0 before consolidation | All subsequent phases build on extensible foundation; no retrofit | Delays visible module-count reduction by one phase |
| Consolidation over rewrite | Preserves all tested behavior, incremental delivery | Takes discipline; partial states may be confusing during transition |

---

## 19. Sources

### Claude Code / Agent SDK
- [Agent SDK reference (TypeScript)](https://platform.claude.com/docs/en/agent-sdk/typescript) -- `query()`, `tool()`, all Options fields. SDK 0.2.x (2026).
- [Hooks documentation](https://platform.claude.com/docs/en/agent-sdk/hooks) -- All 17 event types, matchers, callback I/O.
- [Permissions documentation](https://platform.claude.com/docs/en/agent-sdk/permissions) -- 5 modes, evaluation order, deny/allow rules.
- [Sessions documentation](https://platform.claude.com/docs/en/agent-sdk/sessions) -- Lifecycle, continue/resume/fork.
- [Sub-agents documentation](https://code.claude.com/docs/en/sub-agents) -- Frontmatter, scoping, memory, hooks.
- [Secure deployment guide](https://platform.claude.com/docs/en/agent-sdk/secure-deployment) -- Threat model, credential proxy, container isolation.
- [Claude Code sandboxing blog post](https://www.anthropic.com/engineering/claude-code-sandboxing) -- Reduced permission prompts by 84%.
- Local: `.backup/BEAM_AGENT_MONKEYCLAW_ARCHITECTURE_PLAN.md` -- Boundary document for BeamAgent vs MonkeyClaw ownership.

### BEAM Multi-Backend SDK Libraries
- [Tesla adapter.ex](https://github.com/elixir-tesla/tesla/blob/master/lib/tesla/adapter.ex) -- Single-callback behaviour.
- [Swoosh adapter.ex](https://github.com/swoosh/swoosh/blob/main/lib/swoosh/adapter.ex) -- `@optional_callbacks` pattern.
- [Ecto adapter.ex](https://github.com/elixir-ecto/ecto/blob/master/lib/ecto/adapter.ex) -- Base behaviour.
- [Ecto.Adapter.Queryable](https://github.com/elixir-ecto/ecto/blob/master/lib/ecto/adapter/queryable.ex) -- Sub-behaviour pattern.
- [Ecto repo supervisor](https://github.com/elixir-ecto/ecto/blob/master/lib/ecto/repo/supervisor.ex) -- Compile-time behaviour gating.
- [ExAws core README](https://github.com/ex-aws/ex_aws#readme) -- Package extraction rationale.
- [ex_aws_s3 on Hex](https://hex.pm/packages/ex_aws_s3) -- Separate service package.
- [Commanded event_store.ex](https://github.com/commanded/commanded/blob/master/lib/commanded/event_store.ex) -- 11-callback contract.
- [gen_smtp server session](https://github.com/gen-smtp/gen_smtp/blob/master/src/gen_smtp_server_session.erl) -- Erlang `-optional_callbacks`.

### Erlang/OTP Design
- [hex.pm rebar3 publish docs](https://hex.pm/docs/rebar3-publish) -- Publishing requirements.
- [Adopting Erlang: Dependencies](https://adoptingerlang.org/docs/development/dependencies/) -- Single-app repo constraint.
- [Adopting Erlang: Umbrella Projects](https://adoptingerlang.org/docs/development/umbrella_projects/) -- Umbrella limitations.
- [Erlang persistent_term blog](https://www.erlang.org/blog/persistent_term/) -- Global GC trade-off.
- [ETS stdlib docs](https://www.erlang.org/doc/apps/stdlib/ets.html) -- Ownership, heir, access patterns.
- [OTP Design Principles](https://www.erlang.org/doc/system/design_principles.html) -- Behaviour conventions.
- [OTP PR #1346](https://github.com/erlang/otp/pull/1346) -- Making callbacks optional.
- [Elixir Library Guidelines](https://hexdocs.pm/elixir/library-guidelines.html) -- No-process-in-library rule.

---

*This report was generated from 4 parallel research tracks: ideal architecture design (Opus architect agent analyzing the full codebase), BEAM multi-backend SDK patterns (Tesla, Ecto, ExAws, Swoosh, Commanded, gen_smtp), Claude Code internals and MonkeyClaw requirements, and Erlang packaging/design best practices. All findings cross-referenced against the current BeamAgent codebase (149 modules, ~64,700 LOC, ~75 ETS tables).*
