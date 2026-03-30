# Canonical Domain Guide

How the shared BeamAgent domain modules fit together, which modules own durable
state, and where process boundaries are intentionally allowed.

## Why this guide exists

BeamAgent now exposes more than just session lifecycle and query helpers. It
also provides canonical domain modules for runs, artifacts, journaling, memory,
routing, context management, routines, orchestration, policy, and audit.

Those modules are meant to be reusable substrate, not hidden services. This
guide explains the ownership rules so new features stay consistent with the rest
of the codebase.

## Design rules

### 1. Runtime processes are explicit

Long-lived BeamAgent-owned processes exist only where the runtime genuinely
needs ownership of external resources or state transitions:

- session engines
- transport clients
- backend runtime wrappers
- the hardened ETS table owner when hardened table access is enabled

Domain modules such as runs, artifacts, journal, memory, routing, context,
routines, orchestration, policy, and audit do not create their own resident
services.

### 2. Caller-owned boundaries stay caller-owned

If a feature needs scheduling, polling, or monitoring, BeamAgent exposes the
primitive and leaves invocation to a process the caller already owns:

- routines expose `run_due/*` instead of starting a scheduler
- context exposes `maybe_compact/2` instead of starting a compactor
- orchestrator exposes `await/2` instead of starting a watcher

### 3. Normalization should be lossless

Unknown wire messages and content blocks are preserved as `raw` data instead of
being discarded. This is a defensive rule that keeps normalization from
destroying information the caller may need later.

### 4. Durable truth lives in canonical stores

Runs, artifacts, journal entries, memories, routing state, routines,
orchestration lineage, and policy profiles are all canonical state. Higher
level features should reuse these stores instead of inventing parallel tables.

## Domain map

| Module | Responsibility | Durable state | Process model |
| --- | --- | --- | --- |
| `beam_agent_runs` | Run and step lifecycle | runs + steps | process-free |
| `beam_agent_artifacts` | Typed artifacts and references | artifacts + links | process-free |
| `beam_agent_journal` | Append-only domain event journal | journal entries + acknowledgements | process-free |
| `beam_agent_journal` (audit) | Filtered audit view over journal-backed events | audit-tagged journal entries | process-free |
| `beam_agent_memory` | Cross-session memory and recall | memories + expiry/pin state | process-free |
| `beam_agent_routing` | Backend-selection policy and sticky state | routing cursors + affinity | process-free |
| `beam_agent_context` | Pressure estimation and compaction entrypoints | no new store; composes summaries, threads, memory | process-free |
| `beam_agent_routines` | Durable scheduled work definitions | routine jobs + execution metadata | process-free |
| `beam_agent_orchestrator` | Parent-child lineage across runs/sessions/threads | lineage + live-handle metadata | process-free |
| `beam_agent_policy` | Reusable allow/deny policy profiles | policy profiles | process-free |

## Typical flows

### Query execution with durable lineage

1. `beam_agent_runs` creates the canonical run.
2. Session execution emits normalized messages.
3. Domain mutations append to `beam_agent_journal`.
4. `beam_agent_journal` provides filtered access to audit-tagged entries.
5. `beam_agent_orchestrator` links child runs when work fans out.

### Scheduled work without hidden schedulers

1. A caller-owned process decides when to check due work.
2. `beam_agent_routines:run_due/0,1` materializes due jobs as canonical runs.
3. `beam_agent_context:maybe_compact/2` can be invoked after routine execution.
4. Policy decisions route through `beam_agent_policy`.
5. Journal and audit capture the durable history.

### Backend selection without special workers

1. The caller supplies routing intent or `backend => auto`.
2. `beam_agent_routing` resolves the backend using stored state and capability
   requirements.
3. The session engine starts the selected backend runtime.
4. The routing decision is journaled for later inspection.

## Documentation map

Use these docs together:

- `README.md` for the public surface and high-level architecture
- `docs/guides/backend_integration_guide.md` for adding a new backend
- public module docs in `src/public/*.erl` for canonical domain APIs
- Elixir facade docs in `beam_agent_ex/lib/beam_agent/*.ex` for wrapper usage

## When adding new features

Before introducing a new module or table, ask:

1. Can this feature reuse an existing canonical store?
2. Does it genuinely need a resident process, or only caller-driven entrypoints?
3. Should it append into the canonical journal instead of inventing another log?
4. Does its public doc explain what it owns, what it does not own, and how it
   fits with the existing domains?

If the answer to question 2 is "resident process", the burden of proof is high.
The default BeamAgent pattern is explicit runtime ownership only where the
runtime cannot work correctly without it.
