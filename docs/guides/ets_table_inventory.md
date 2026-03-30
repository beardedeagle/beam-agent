# ETS Table Inventory

## Overview

The SDK manages ETS tables through two mechanisms:

- **`beam_agent_ets`** — a drop-in wrapper around the `ets` module. Every write
  operation (`insert`, `delete`, `update_counter`, etc.) routes through this
  module so that writes can be proxied to the shard owner process when running
  in hardened mode. Read operations delegate directly to `ets` with zero
  overhead.

- **`beam_agent_table_owner`** — owns and monitors the tables in hardened mode.
  In hardened mode all tables are `protected`; writes from non-owner processes
  are serialised through one or more shard owner processes. In public mode
  (the default) all tables are `public` and no process is spawned.

Tables are created lazily via `ensure_table/2` or `ensure_tables/0` calls,
which are idempotent. No central startup step is required; the first caller
creates the table and subsequent callers are no-ops.

---

## Shared Tables

### `beam_agent_domains`

The shared composite-key table. Multiple domain modules share a single ETS
table to avoid proliferating named tables. Each domain namespaces its entries
with a unique prefix tuple as the key.

- **Owner module**: `beam_agent_store` (coordinates creation via
  `beam_agent_store:ensure_table/3`; each domain calls this independently)
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Access pattern**: read-heavy with scattered writes per domain
- **Lifecycle**: created on first call to any domain `ensure_tables/0`

#### Domains and their key prefixes

| Domain module                    | Key prefix(es)                                              |
|----------------------------------|-------------------------------------------------------------|
| `beam_agent_runs_store`          | `{run, RunId}`, `{run_step, {RunId, StepId}}`               |
| `beam_agent_artifacts_store`     | `{artifact, ArtifactId}`                                    |
| `beam_agent_memory_store`        | `{memory, MemoryId}`                                        |
| `beam_agent_threads_core`        | `{thread, ThreadKey}`, `{active_thread, SessionId}`         |
| `beam_agent_orchestrator_store`  | `{orch_link, ChildRunId}`                                   |
| `beam_agent_policy_core`         | `{policy, PolicyId}`                                        |
| `beam_agent_routing_core`        | `{routing_affinity, Key}`, `{routing_rr, Key}`              |

**Rules for shared-table domains:**

1. Key prefix atoms must be unique — no two domains may use the same prefix.
2. `clear/0` must use `match_delete/2` scoped to the domain's own prefix, never
   `delete_all_objects/1`.
3. Each domain calls `beam_agent_store:ensure_table/3` independently; the call
   is idempotent.

---

### `beam_agent_runtime`

The unified runtime state table. Stores session runtime state, app registry
entries, control configuration, checkpoint metadata, account state, and search
sessions. Multiple modules write to this table using distinct key prefix tuples.

- **Owner module**: `beam_agent_runtime` (via `app_ensure_tables/0`; delegates
  to `beam_agent_ets:ensure_table/2`)
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Access pattern**: read-heavy, scattered writes across many modules
- **Lifecycle**: created on first call to `beam_agent_runtime:app_ensure_tables/0`
- **Macro**: `-define(TABLE, beam_agent_runtime)` — defined locally in each
  consumer module; `-define(RUNTIME_TABLE, beam_agent_runtime)` in
  `beam_agent_runtime_core`

#### Key prefixes sharing this table

| Module                         | Key pattern(s)                                                |
|--------------------------------|---------------------------------------------------------------|
| `beam_agent_runtime_core`      | `{runtime, SessionKey}`                                       |
| `beam_agent_control_core`      | `{control_config, {SessionId, Key}}`, `{control_task, ...}`,  |
|                                | `{control_callback, SessionId}`, `{control_pending, {SessionId, RequestId}}` |
| `beam_agent_control` (public)  | `{review, {SessionId, ReviewId}}`, `{realtime, {SessionId, ThreadId}}` |
| `beam_agent_checkpoint_core`   | `{checkpoint, CheckpointId}`                                  |
| `beam_agent_account_core`      | `{account, SessionKey}`                                       |
| `beam_agent_search_core`       | `{search, {SessionKey, SearchSessionId}}`                     |
| `beam_agent_runtime` (public)  | `{app, SessionKey, AppId}`                                    |

---

## Standalone Tables

### `beam_agent_registry`

Unified global registry for tools, skills, slash commands, MCP servers, agents,
and plugins.

- **Owner module**: `beam_agent_registry`
- **Macro**: `-define(TABLE, beam_agent_registry)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `{Kind, Id}` where `Kind :: tool | skill | command | mcp | agent | plugin`
  and `Id :: binary()`
- **Access pattern**: read-heavy; writes on registration/unregistration
- **Lifecycle**: created on first call to `beam_agent_registry:ensure_table/0`
- **Note**: also referenced as `?REG_TABLE` in `beam_agent_skills_core`,
  `beam_agent_tool_registry`, and `beam_agent_capabilities`

---

### `beam_agent_config`

Global configuration key-value store (flat binary keys, arbitrary values).

- **Owner module**: `beam_agent_config`
- **Macro**: `-define(CONFIG_TABLE, beam_agent_config)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `config_key()` — a binary string (e.g. `<<"provider">>`,
  `<<"model">>`)
- **Access pattern**: read-heavy; infrequent writes
- **Lifecycle**: created on first call to `beam_agent_config:ensure_table/0`

---

### `beam_agent_store_config`

Stores the configured persistence adapter for each canonical domain. Defaults
to `beam_agent_store_ets` when no override is present.

- **Owner module**: `beam_agent_store`
- **Macro**: `-define(CONFIG_TABLE, beam_agent_store_config)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `domain()` atom (e.g. `session_store`, `journal`, `routines`)
- **Value**: `store_config()` map `#{adapter := module(), options => map()}`
- **Access pattern**: read-heavy (consulted on every store operation); written
  only when `beam_agent_store:configure_domain/2` is called
- **Lifecycle**: created on first call to `beam_agent_store:ensure_tables/0`

---

### `beam_agent_reload`

Reload notification bus. Tracks subscribers and a monotonic version counter.
When a global component changes (hooks, tools, config, etc.) the bus broadcasts
`{beam_agent_reload, Type, Version}` messages to all subscribed pids.

- **Owner module**: `beam_agent_reload_bus`
- **Macro**: `-define(TABLE, beam_agent_reload)`
- **Options**: `[set, named_table, {read_concurrency, true}, {write_concurrency, true}]`
- **Keys**:
  - `{subscriber, Pid}` — one entry per subscribed process
  - `version` — monotonic integer counter (seeded to `0` on table creation)
- **Access pattern**: write-heavy during reload events; read on version checks
- **Lifecycle**: created on first call to `beam_agent_reload_bus:ensure_tables/0`

---

### `beam_agent_sessions`

Session metadata records (session id, backend, state, timestamps).

- **Owner module**: `beam_agent_session_store_core`
- **Macro**: `-define(SESSIONS_TABLE, beam_agent_sessions)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `SessionId :: binary()`
- **Access pattern**: balanced reads and writes across session lifecycle
- **Lifecycle**: created on first call to `beam_agent_session_store_core:ensure_tables/0`
- **Store domain**: `session_store` (pluggable via `beam_agent_store`)

---

### `beam_agent_session_messages`

Per-session message history. Uses `ordered_set` to enable efficient prefix-scan
iteration over `{SessionId, Seq}` keys.

- **Owner module**: `beam_agent_session_store_core`
- **Macro**: `-define(MESSAGES_TABLE, beam_agent_session_messages)`
- **Options**: `[ordered_set, named_table, {read_concurrency, true}]`
- **Key**: `{SessionId :: binary(), Seq :: non_neg_integer()}`
- **Access pattern**: append-heavy writes; range-read for message replay
- **Lifecycle**: created alongside `beam_agent_sessions`
- **Store domain**: `session_store`

---

### `beam_agent_session_counters`

Monotonic sequence number counter per session, used to assign message
sequence numbers.

- **Owner module**: `beam_agent_session_store_core`
- **Macro**: `-define(COUNTERS_TABLE, beam_agent_session_counters)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `SessionId :: binary()`
- **Value**: `non_neg_integer()` (current sequence number)
- **Access pattern**: write on every message append (`update_counter`)
- **Lifecycle**: created alongside `beam_agent_sessions`
- **Store domain**: `session_store`

---

### `beam_agent_backend_sessions`

Maps a session pid to its backend atom. The routing layer uses this for fast
backend dispatch without consulting the full runtime table.

- **Owner module**: `beam_agent_backend`
- **Macro**: `-define(SESSIONS_TABLE, beam_agent_backend_sessions)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `pid()`
- **Value**: `backend()` atom (e.g. `claude`, `codex`, `gemini`)
- **Access pattern**: write on session start/stop; read-heavy during routing
- **Lifecycle**: created on first call to `beam_agent_backend:ensure_tables/0`

---

### `beam_agent_event_subscriptions`

Maps subscription references to subscriber metadata (session id, owner pid).

- **Owner module**: `beam_agent_events`
- **Macro**: `-define(SUBSCRIPTIONS_TABLE, beam_agent_event_subscriptions)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `reference()` (the subscription ref returned by `subscribe/1`)
- **Value**: `#{session_id => binary(), owner => pid()}`
- **Access pattern**: write on subscribe/unsubscribe; read on event publish
- **Lifecycle**: created on first call to `beam_agent_events:ensure_tables/0`

---

### `beam_agent_event_session_refs`

`bag` table that maps session ids back to their subscription references, used
to fan out published events to all subscribers for a session.

- **Owner module**: `beam_agent_events`
- **Macro**: `-define(SESSIONS_TABLE, beam_agent_event_session_refs)`
- **Options**: `[bag, named_table, {read_concurrency, true}]`
- **Key**: `SessionId :: binary()`
- **Value**: `reference()` (subscription ref)
- **Access pattern**: write on subscribe/unsubscribe; read on every publish
- **Lifecycle**: created alongside `beam_agent_event_subscriptions`

---

### `beam_agent_global_hooks`

Global hook registry. Stores hook definitions keyed by event type.

- **Owner module**: `beam_agent_hooks_core`
- **Macro**: `-define(GLOBAL_TABLE, beam_agent_global_hooks)`
- **Options**: `[set, named_table, {read_concurrency, true}]` (created via
  `beam_agent_ets:ensure_table/2`)
- **Key**: `hook_event()` atom (e.g. `pre_tool_use`, `post_tool_use`, `stop`)
- **Value**: `[hook_def()]` list in registration order
- **Access pattern**: read-heavy during event firing; written on register/clear
- **Lifecycle**: created on first call to `beam_agent_hooks_core:ensure_tables/0`

---

### `beam_agent_journal_events`

Journal event records, keyed by event id.

- **Owner module**: `beam_agent_journal_store`
- **Macro**: `-define(EVENTS_TABLE, beam_agent_journal_events)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `EventId :: binary()`
- **Value**: `event_record()` map
- **Access pattern**: write-once per event; read on lookup
- **Lifecycle**: created on first call to `beam_agent_journal_store:ensure_tables/0`
- **Store domain**: `journal`

---

### `beam_agent_journal_sequence`

Ordered index from sequence number to event id, enabling range scans in
ascending sequence order.

- **Owner module**: `beam_agent_journal_store`
- **Macro**: `-define(SEQUENCE_TABLE, beam_agent_journal_sequence)`
- **Options**: `[ordered_set, named_table, {read_concurrency, true}]`
- **Key**: `Sequence :: pos_integer()`
- **Value**: `EventId :: binary()`
- **Access pattern**: append on insert; range-read for list queries
- **Lifecycle**: created alongside `beam_agent_journal_events`
- **Store domain**: `journal`

---

### `beam_agent_journal_acks`

Acknowledgement state for journal consumers.

- **Owner module**: `beam_agent_journal_store`
- **Macro**: `-define(ACKS_TABLE, beam_agent_journal_acks)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `ConsumerId :: binary()`
- **Value**: `Sequence :: non_neg_integer()` (last acknowledged sequence)
- **Access pattern**: write on ack; read on consumer resume
- **Lifecycle**: created alongside `beam_agent_journal_events`
- **Store domain**: `journal`

---

### `beam_agent_routine_jobs`

Routine job definitions keyed by job id.

- **Owner module**: `beam_agent_routines_store`
- **Macro**: `-define(JOBS_TABLE, beam_agent_routine_jobs)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `JobId :: binary()`
- **Value**: job record map
- **Access pattern**: write on put/delete; read on get/list
- **Lifecycle**: created on first call to `beam_agent_routines_store:ensure_tables/0`
- **Store domain**: `routines`

---

### `beam_agent_routine_due`

Ordered index of due-time to job id, enabling efficient "next due" queries.

- **Owner module**: `beam_agent_routines_store`
- **Macro**: `-define(DUE_TABLE, beam_agent_routine_due)`
- **Options**: `[ordered_set, named_table, {read_concurrency, true}]`
- **Key**: `{DueAt :: integer(), JobId :: binary()}`
- **Access pattern**: write on job put/delete; range-read to find due jobs
- **Lifecycle**: created alongside `beam_agent_routine_jobs`
- **Store domain**: `routines`

---

### `beam_agent_routine_claims`

Tracks which jobs are currently claimed (locked) by a worker, preventing
double-execution.

- **Owner module**: `beam_agent_routines_store`
- **Macro**: `-define(CLAIMS_TABLE, beam_agent_routine_claims)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `JobId :: binary()`
- **Value**: `#{claimed_until := integer()}` (epoch ms expiry)
- **Access pattern**: write on claim/release; read on every due-check
- **Lifecycle**: created alongside `beam_agent_routine_jobs`
- **Store domain**: `routines`

---

### `beam_agent_orchestrator_children`

Bag table indexing parent run ids to their direct child run ids. Supports
`list_children/1` without scanning `beam_agent_domains`.

- **Owner module**: `beam_agent_orchestrator_store`
- **Macro**: `-define(CHILDREN_TABLE, beam_agent_orchestrator_children)`
- **Options**: `[bag, named_table, {read_concurrency, true}]`
- **Key**: `ParentRunId :: binary()`
- **Value**: `ChildRunId :: binary()`
- **Access pattern**: write on link insert/delete; read on `list_children/1`
- **Lifecycle**: created on first call to `beam_agent_orchestrator_store:ensure_tables/0`
- **Store domain**: `orchestrator`
- **Note**: lineage records themselves live in `beam_agent_domains` under the
  `{orch_link, ChildRunId}` prefix

---

### `beam_agent_guard_state`

Security guard evaluation state (global lockdown flag, policy epoch).

- **Owner module**: `beam_agent_command_guard`
- **Macro**: `-define(STATE_TABLE, beam_agent_guard_state)`
- **Options**: `[set, named_table, {read_concurrency, true}, {write_concurrency, true}]`
- **Key**: atom keys (e.g. `lockdown`, `epoch`)
- **Access pattern**: high-frequency reads on every command evaluation;
  writes on state transitions
- **Lifecycle**: created on `beam_agent_command_guard:init/0,1`

---

### `beam_agent_command_history`

Ordered history of evaluated commands. Used for temporal pattern detection
and audit.

- **Owner module**: `beam_agent_command_guard`
- **Macro**: `-define(HISTORY_TABLE, beam_agent_command_history)`
- **Options**: `[ordered_set, named_table, {read_concurrency, true}]`
- **Key**: `{Timestamp :: integer(), Ref :: reference()}`
- **Access pattern**: append on every evaluated command; range-read for
  temporal analysis
- **Lifecycle**: created on `beam_agent_command_guard:init/0,1`

---

### `beam_agent_rate_limits`

Per-program and per-category rate limit counters.

- **Owner module**: `beam_agent_command_guard`
- **Macro**: `-define(RATE_TABLE, beam_agent_rate_limits)`
- **Options**: `[set, named_table, {read_concurrency, true}, {write_concurrency, true}]`
- **Key**: `{program | category, Name :: binary()}` or similar compound key
- **Value**: `#{count := integer(), window_start := integer()}`
- **Access pattern**: read-modify-write on every command evaluation (high
  frequency); `write_concurrency` enabled to reduce lock contention
- **Lifecycle**: created on `beam_agent_command_guard:init/0,1`

---

### `beam_agent_active_commands`

Tracks commands that are currently executing (in-flight).

- **Owner module**: `beam_agent_command_guard`
- **Macro**: `-define(COMMAND_TABLE, beam_agent_active_commands)`
- **Options**: `[set, named_table, {write_concurrency, true}]`
- **Key**: `reference()` (unique per command invocation)
- **Access pattern**: write on command start/end; read for concurrency limit
  checks
- **Lifecycle**: created on `beam_agent_command_guard:init/0,1`

---

### `beam_agent_control_feedback`

Ordered buffer of feedback messages for interactive control sessions.

- **Owner module**: `beam_agent_control_core`
- **Macro**: `-define(FEEDBACK_TABLE, beam_agent_control_feedback)`
- **Options**: `[ordered_set, named_table]`
- **Key**: `{SessionId :: binary(), Seq :: integer()}`
- **Access pattern**: append on feedback post; range-read by control consumers
- **Lifecycle**: created on first call to `beam_agent_control_core:ensure_tables/0`

---

### `beam_agent_tool_registries`

Maps session pids to their session-scoped MCP tool registries. Global MCP
servers are stored in `beam_agent_registry` under `{mcp, Name}` keys.

- **Owner module**: `beam_agent_tool_registry`
- **Macro**: `-define(SESSION_REGISTRY_TABLE, beam_agent_tool_registries)`
- **Options**: `[set, named_table, {read_concurrency, true}]`
- **Key**: `pid()` (session pid)
- **Value**: `mcp_registry()` map
- **Access pattern**: write on session init/tool update; read on tool dispatch
- **Lifecycle**: created on first call to `beam_agent_tool_registry:ensure_registry_table/0`

---

## Ephemeral Tables (Not SDK-managed)

### `beam_agent_credential_init`

A mutex-by-existence table used to serialize the one-time ephemeral cookie
generation path. The first process to call `ets:new/2` wins the critical
section; all others spin on `persistent_term` until the key is cached. The
table is deleted immediately after the key is written.

- **Owner**: whichever process calls `beam_agent_credential:auto_generate_and_cache/0` first
- **Lifetime**: microseconds — deleted in an `after` block once the key is stored
- **Options**: `[named_table]` (raw `ets:new/2`, intentionally bypasses `beam_agent_ets`)
- **Purpose**: mutex primitive; not a data store

---

### `beam_agent_dets_atomic_counters`

Internal bookkeeping table used by `beam_agent_store_dets` when
`atomic_counters => true` is configured. Stores `atomics` refs so the DETS
adapter can provide atomic counter semantics that DETS natively lacks.

- **Owner module**: `beam_agent_store_dets`
- **Macro**: `-define(ATOMIC_COUNTERS_TABLE, beam_agent_dets_atomic_counters)`
- **Options**: raw `ets:new/2` call — intentionally bypasses `beam_agent_ets`
  and hardened-mode proxying (adapter-internal bookkeeping only)
- **Schema**: `{{TableName, Key}, atomics_ref(), Pos :: pos_integer()}`
- **Lifecycle**: created by `beam_agent_store_dets` on first atomic counter use

---

## Table Owner (Hardened Mode)

`beam_agent_table_owner` manages the ownership lifecycle for all SDK-managed
tables in hardened mode:

- In **public mode** (default): tables are `public`; `beam_agent_ets` writes
  go directly to `ets` with zero overhead. No owner process is spawned.
- In **hardened mode**: tables are `protected`; writes from non-owner processes
  are sent as synchronous messages to a pool of shard owner processes
  (`shard_count` configurable, default 1). Each shard traps exits and
  registers the consumer process as the ETS heir, so tables survive shard
  crashes and transfer to the consumer for graceful recovery.
- The primary shard (shard 0) supports `monitor_for_cleanup/2`: when a
  monitored pid dies the shard executes a registered `{M, F, A}` callback to
  clean up that pid's ETS entries (e.g. `beam_agent_events` uses this to
  remove dead subscribers).

Initialise hardened mode from a `gen_server init/1`:

```erlang
ok = beam_agent_table_owner:init(#{table_access => hardened, shard_count => 4}).
```

---

## Guidelines for New Tables

**Add to `beam_agent_domains` when:**

- The data is naturally keyed by a unique record id (run, artifact, memory,
  thread, policy, etc.)
- The domain will never need `bag` semantics or `ordered_set` iteration
- The domain's clear operation can be expressed as a prefix `match_delete`

**Create a standalone table when:**

- The table needs `bag` or `ordered_set` type
- The table needs `write_concurrency` (the shared domains table uses neither)
- The access pattern or key shape is incompatible with a prefix-tuple key
- The table is adapter-internal and should not route through `beam_agent_ets`
  (e.g. `beam_agent_dets_atomic_counters`)

**Always use `beam_agent_ets:ensure_table/2`** (not raw `ets:new/2`) for new
SDK tables so that hardened-mode access control is applied automatically.
Omit the `public`/`protected`/`private` access specifier from the options
list — `ensure_table/2` inserts the correct specifier based on the current
global access mode.
