# BeamAgent Command Security Architecture

> Design specification for the layered command execution security system in the
> BeamAgent SDK. This document covers the competitive landscape, BEAM/OTP
> security primitives, architectural design, implementation details, and
> extension points for external security systems (Citadel/Warden).

**Status**: Design specification — not yet implemented
**Last updated**: 2026-03-14
**Author**: BeamAgent team

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Competitive Landscape](#2-competitive-landscape)
3. [BEAM/OTP Security Primitives Inventory](#3-beamotp-security-primitives-inventory)
4. [Architecture Overview](#4-architecture-overview)
5. [Layer 0: Structural Command Parser](#5-layer-0-structural-command-parser)
6. [Layer 1: Static Policy Engine](#6-layer-1-static-policy-engine)
7. [Layer 2: Validator Callback Behaviour](#7-layer-2-validator-callback-behaviour)
8. [Layer 3: Security Guard Process](#8-layer-3-security-guard-process)
9. [Layer 4: Restricted Executor](#9-layer-4-restricted-executor)
10. [Layer 5: Audit and Observability](#10-layer-5-audit-and-observability)
11. [Telemetry Events](#11-telemetry-events)
12. [Types and Data Structures](#12-types-and-data-structures)
13. [Default Policies](#13-default-policies)
14. [Extension Points (Citadel Integration)](#14-extension-points-citadel-integration)
15. [Implementation Phasing](#15-implementation-phasing)
16. [Governance Boundary](#16-governance-boundary)
17. [Threat Model](#17-threat-model)
18. [Appendix A: BEAM Attack Surface](#appendix-a-beam-attack-surface)
19. [Appendix B: Competitive Detail](#appendix-b-competitive-detail)

---

## 1. Design Philosophy

### Core Principles

1. **The SDK provides extension points, not a policy engine.** BeamAgent ships
   sensible defaults and clean interfaces. Deep policy enforcement belongs in
   dedicated security systems (Citadel/Warden).

2. **Layered and interleaved defense.** No single mechanism is sufficient.
   Multiple independent layers evaluate each command, and the layers are
   designed to compose — a bypass at one layer is caught by the next.

3. **Default-deny for unsafe forms.** String-form commands (which pass through
   `sh -c`) are second-class citizens requiring explicit policy approval.
   List-form commands (which use `spawn_executable` with discrete args) are the
   safe default and cannot be shell-injected.

4. **Security as a stateful, concurrent system.** Unlike every competitor in the
   industry (which uses stateless per-command filtering), BeamAgent models
   security state as a `gen_statem` that tracks temporal context — what the
   agent has done, what state it is in, what patterns are emerging across
   commands.

5. **Every security decision is observable.** All policy evaluations, denials,
   approvals, and escalations emit telemetry events. Observability is not
   optional.

6. **The enforcement layer cannot be killed by the thing it guards.** The
   security guard runs as an unkillable system process under OTP supervision.

### What This Is NOT

- This is **not a sandbox**. OS-level containment (syscall filtering, filesystem
  sandboxing, network namespacing) belongs in Citadel/Warden.
- This is **not a policy language**. The SDK provides evaluation hooks, not a
  DSL for defining complex policies.
- This is **not security theatre**. The built-in defaults provide genuine
  protection against common command injection patterns, composition attacks,
  and resource abuse — not just string matching.

---

## 2. Competitive Landscape

Research conducted against local source code of 6 agentic coding SDKs plus
training knowledge of additional tools (Aider, Cursor, Cline/Continue).

### Summary Matrix

| Feature | Codex | Gemini CLI | Copilot SDK | OpenCode | Amp SDK | Claude Code |
|---------|-------|------------|-------------|----------|---------|-------------|
| **Approach** | Starlark DSL | Prefix matching | Hook callbacks | Wildcard rules | Permission rules | PreToolUse hooks |
| **Allowlist** | Per-program spec | `tools.core` | `availableTools` | Per-tool patterns | `PermissionRule` | Hook-based |
| **Blocklist** | `forbidden` + regex | `tools.exclude` | `excludedTools` | `deny` rules | `guardedFiles` | Hook deny |
| **Cmd chaining** | Parsed by policy | Split & validate | N/A | N/A | N/A | N/A |
| **Arg validation** | Typed args (deep) | Prefix only | Hook inspection | Glob patterns | N/A | Hook inspection |
| **Sandbox** | OS (Seatbelt) | Planned | N/A | Explicit non-sandbox | N/A | Container |
| **Permission tiers** | 3 sandbox + 4 approval | Allow/block | Deny-by-default | Allow/ask/deny | Allow/deny | Permission modes |
| **State awareness** | None | None | None | None | None | None |
| **Timeout** | Yes | Inactivity | Hook-injectable | N/A | N/A | Yes |
| **Output limits** | N/A | N/A | N/A | N/A | N/A | Yes (1MB) |

### Key Findings

**Universal weakness**: Every competitor uses stateless per-command evaluation.
None reason about command sequences, temporal patterns, or session context.

**Codex** (most sophisticated): Uses a Starlark-based `execpolicy` DSL where
each program gets a `define_program()` spec with typed args, allowed flags, and
embedded test vectors (`should_match`/`should_not_match`). Notable: `sed` is
specifically handled because GNU sed's `s/pattern/cmd/e` flag executes arbitrary
shell commands. Sandbox modes: `read-only`, `workspace-write`,
`danger-full-access`. Approval modes: `never`, `on-request`, `on-failure`,
`untrusted`. OS enforcement via macOS Seatbelt.

**Gemini CLI** (cleanest prefix model): `tools.core` allowlist with prefix
matching. Command chaining detection — splits on `&&`, `||`, `;` and validates
each segment. Blocklist always takes precedence. Enterprise admin controls can
override user configs.

**Copilot SDK** (deny-by-default + hooks): `onPermissionRequest` handler where
all actions are denied unless explicitly allowed. `onPreToolUse` hooks can
inspect args, modify args (e.g., inject default timeouts), deny, or add
context. `availableTools` whitelist / `excludedTools` blacklist.

**OpenCode** (honest about limitations): Per-tool permission rules with
`allow`/`ask`/`deny` actions and wildcard matching. Last matching rule wins.
`SECURITY.md` explicitly states: "The permission system is not a sandbox. It
exists as a UX feature."

**Amp SDK** (Elixir-native): `PermissionRule` structs with `{tool, action,
context, to, matches}`. `permissions test` evaluates before execution.
`guardedFiles` allowlist for file-level protection. Environment variable
whitelisting.

**Claude Code** (hooks-based): `PreToolUse`/`PostToolUse` hooks with regex
matchers on tool names. Can deny based on arg inspection (e.g., block commands
containing `rm -rf`). Container-based sandboxing for deployment with domain
allowlisting via unix socket proxy.

### Industry-Wide Gaps

1. **No temporal awareness** — no tool tracks what commands were executed before
   the current one to detect suspicious sequences.
2. **No composition analysis** — string-level matching cannot reason about what
   `cmd1 && cmd2` means as a unit.
3. **No resource containment** — most tools have timeout but no memory limits,
   CPU throttling, or I/O control.
4. **No bypass resistance** — security is typically an optional addon that can
   be disabled with a config flag.
5. **Shallow string matching** — prefix/regex/glob matching is trivially
   bypassed via shell features (aliases, variable expansion, subshells,
   heredocs, process substitution).

---

## 3. BEAM/OTP Security Primitives Inventory

Verified against OTP 28. This section catalogues every BEAM/OTP primitive
relevant to security enforcement.

### 3.1 Process-Level Controls

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `erts_internal:spawn_system_process/3` | Creates processes immune to `exit(Pid, kill)` | Unkillable security guard |
| `process_flag(max_heap_size, #{size => N, kill => true})` | Hard per-process memory limit | Prevent runaway command output |
| `process_flag(sensitive, true)` | Hides backtrace and dictionary from inspection | Protect credential-handling processes |
| `process_flag(priority, high)` | Scheduler priority elevation | Security processes always get CPU |
| `process_flag(error_handler, Module)` | Per-process undefined function interception | Module-call-level restrictions |
| `process_flag(save_calls, N)` | Records last N function calls | Per-process audit trail |
| `erlang:suspend_process/1` | Freeze any process | Suspend suspicious processes |
| `erlang:bump_reductions/1` | Consume reductions artificially | Throttle CPU consumption |
| `erlang:hibernate/3` | Reduce heap to minimum, GC all data | Wipe sensitive data from memory |
| `erlang:garbage_collect/1` | Force GC on any process | Force cleanup of secrets |
| `timer:kill_after/1,2` | Kill process after timeout | Enforce time limits |

### 3.2 I/O and Communication

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `erlang:group_leader/2` | Redirect all I/O for a process | Intercept, filter, or block all I/O |
| `erlang:monitor(port, Port)` | Monitor port lifecycle | Track subprocess health |
| `port_connect/2` | Transfer port ownership | Isolate port to security process |
| Ports as OS processes | Port programs run in separate OS processes | Natural containment boundary |

### 3.3 Code Loading and Integrity

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `code:stick_mod/1` | Prevent module reload/purge | Protect security modules |
| `erl -mode embedded` | No automatic code loading | Prevent unauthorized module loading |
| `code:module_md5/1` | Runtime module checksum | Verify code integrity |
| `code:set_path/1` | Control module search path | Restrict loadable code |
| `code:atomic_load/1` | Atomic multi-module loading | Swap policy modules atomically |
| Custom `erl_prim_loader` | Replace boot-time loader | Enforce code signing |

### 3.4 Restricted Evaluation

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `erl_eval` function handlers | Intercept all `M:F(A)` in eval | Block dangerous function calls |
| `-stdlib restricted_shell Module` | ACL for interactive evaluation | Model for call-level ACL |
| `error_handler:undefined_function/3` | Intercept undefined calls | Per-process module restrictions |

### 3.5 Observation and Audit

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `erlang:trace/3` | Trace process events (observation only) | Security monitoring |
| `trace:session_create/3` (OTP 27+) | Isolated trace sessions | Security trace separate from debug |
| `seq_trace` | Causal tracking across processes/nodes | Request-scoped audit trails |
| `erlang:system_monitor/2` | Long GC, large heap, busy port alerts | Resource abuse detection |
| `sys:install/2` | Observe all messages to OTP process | Message-level audit |
| Logger metadata | Per-process log context | Audit trail enrichment |

### 3.6 Distribution and Network

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `net_kernel:allow/1` | Node connection ACL | Restrict which nodes can connect |
| `-proto_dist inet_tls` | TLS for distribution | Encrypted inter-node communication |
| Custom EPMD (`-epmd_module`) | Replace node discovery | Authenticated node registration |
| Custom distribution protocol | Replace transport layer | Custom encryption/auth |
| Invisible nodes (`-dist_listen false`) | Node doesn't accept connections | Hide from network |
| `net_kernel:monitor_nodes/1` | Node connect/disconnect alerts | Detect unauthorized nodes |

### 3.7 Data Storage and Access

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| ETS `private` access | Only owning process can access | Isolated policy state |
| ETS `protected` access | Owner writes, all read | Shared policy rules |
| `mnesia:set_access_control/1` | Table-level ACL | Per-table read/write restrictions |
| `persistent_term` | Global read, no ACL | NOT suitable for secrets |

### 3.8 Supervision and Fault Tolerance

| Primitive | What It Does | Security Application |
|-----------|-------------|---------------------|
| `one_for_one` supervisor | Restart failed children | Auto-recover security processes |
| `rest_for_one` supervisor | Restart failed + subsequent | Ordered recovery for dependent layers |
| Process links and monitors | Crash propagation/notification | Security process crash detection |
| `trap_exit` flag | Convert exit signals to messages | Prevent cascading failure |
| `gen_statem` | State machine with typed transitions | Model security state transitions |
| Hot code loading | Replace modules without restart | Update policies without downtime |

### 3.9 What The BEAM Cannot Do

These require OS-level enforcement (Citadel/Warden domain):

- **Syscall filtering** — seccomp-bpf, pledge/unveil, Seatbelt
- **Filesystem sandboxing** — kernel-level path restrictions (landlock)
- **Network namespacing** — isolate network stack per process
- **NIF containment** — NIFs run in scheduler threads, can crash the VM
- **Mandatory access control** — SELinux, AppArmor
- **cgroups** — kernel-level CPU/memory/IO limits per process group
- **User namespace isolation** — run as unprivileged user inside container

### 3.10 Architectural Insight

The BEAM's security model is **cooperative, not adversarial** — it assumes all
code in the VM is trusted. However, the primitives for building adversarial
security exist. They have never been composed for this purpose because the BEAM
community historically runs trusted code. Agentic systems change that
assumption: the agent decides which commands to run, and those commands are not
trusted. BeamAgent is the first system to compose these primitives into a
security architecture for agentic command execution.

---

## 4. Architecture Overview

### Execution Flow

```
beam_agent_command_core:run/2
  |
  v
+-------------------------------------+
|  Layer 0: Structural Parse           |
|  Command string -> structured repr   |
|  Detect: | ; && || $() `` > < >>     |
|  List-form commands bypass this      |
+------------------+------------------+
                   |
                   v
+-------------------------------------+
|  Layer 1: Static Policy              |
|  Allowlist / denylist evaluation     |
|  Pattern matching on command struct  |
|  Fast path: ETS lookup              |
|  Default: list-form=allow,          |
|           string-form=check         |
+------------------+------------------+
                   |
                   v
+-------------------------------------+
|  Layer 2: Validator Callback         |
|  User-defined behaviour callback    |
|  Receives rich context:             |
|    - Parsed command structure       |
|    - Session state (gen_statem)     |
|    - Command history (last N)       |
|    - Agent identity + backend       |
|    - Options map                    |
|  Returns: allow | {deny, Reason}    |
|                                     |
|  *** CITADEL PLUGS IN HERE ***      |
+------------------+------------------+
                   |
                   v
+-------------------------------------+
|  Layer 3: Security Guard            |
|  gen_statem (unkillable process)    |
|  Tracks:                            |
|    - Command history in ETS         |
|    - Rate limits per category       |
|    - Temporal patterns (sequences)  |
|    - Session security state         |
|  Can: block, throttle, alert        |
+------------------+------------------+
                   |
                   v
+-------------------------------------+
|  Layer 4: Restricted Executor       |
|  Spawned process with:              |
|    - max_heap_size (hard limit)     |
|    - custom group_leader (I/O)      |
|    - sensitive flag (if creds)      |
|    - monitored by guard             |
|    - timeout enforcement            |
|  Opens port, collects output        |
+------------------+------------------+
                   |
                   v
+-------------------------------------+
|  Layer 5: Audit                     |
|  Telemetry: start/stop/exception    |
|  + security decision events         |
|  + seq_trace for causal chains      |
|  + ETS history update               |
|  + system_monitor for resources     |
+-------------------------------------+
```

### Process Architecture

```
beam_agent_sup (application supervisor)
  |
  +-- beam_agent_command_guard (gen_statem)
  |     - Created via erts_internal:spawn_system_process/3
  |     - Priority: high
  |     - Owns ETS tables: command_history, policy_cache
  |     - Cannot be killed even with exit(Pid, kill)
  |
  +-- beam_agent_command_sup (simple_one_for_one)
        - Spawns restricted executor processes on demand
        - Each executor:
            - max_heap_size enforced
            - custom group_leader
            - linked to its port
            - monitored by guard
```

### Layer Independence

Each layer operates independently and can function without the others:

- **Layer 0 alone**: Detects composition operators in command strings.
- **Layer 1 alone**: Provides Gemini-level allowlist/blocklist security.
- **Layers 0+1+2**: Provides Copilot-level hook-based security with structural
  awareness.
- **Layers 0-3**: Provides security superior to any existing competitor — adds
  temporal and stateful evaluation.
- **Layers 0-4**: Adds BEAM-native process containment.
- **Layers 0-5**: Full observability.
- **All layers + Citadel**: Novel architecture — application-level contextual
  enforcement + OS-level containment.

---

## 5. Layer 0: Structural Command Parser

### Purpose

Parse command strings into structured representations that expose composition
operators, making them visible to subsequent security layers instead of hiding
them inside flat strings.

### Why This Matters

String matching on `"git status && rm -rf /"` might match `git` as an allowed
prefix and miss the `rm -rf /` entirely. Structural parsing decomposes the
command into its constituent parts so each can be evaluated independently.

### Command Forms

**List-form** (safe by default):

```erlang
%% Cannot be shell-injected — each element is a separate arg
%% to spawn_executable. No shell interpretation occurs.
beam_agent_command_core:run([<<"git">>, <<"status">>])
```

**String-form** (requires security evaluation):

```erlang
%% Passed to sh -c, subject to shell interpretation.
%% Composition operators, variable expansion, subshells,
%% and all other shell features are active.
beam_agent_command_core:run(<<"git status && rm -rf /">>)
```

### Parsed Structure

String-form commands are parsed into a structured representation:

```erlang
-type command_struct() ::
    %% A simple command with no composition
    #{type := simple,
      program := binary(),
      args := [binary()],
      raw := binary()} |

    %% Commands connected by composition operators
    #{type := chain,
      operator := '&&' | '||' | ';',
      commands := [command_struct()]} |

    %% Pipeline
    #{type := pipeline,
      commands := [command_struct()]} |

    %% Subshell or command substitution
    #{type := subshell,
      form := '()' | '$()' | backtick,
      inner := binary()} |

    %% Redirection detected
    #{type := redirect,
      command := command_struct(),
      redirects := [redirect_spec()]} |

    %% Unparseable — treated as opaque and high-risk
    #{type := opaque,
      raw := binary()}.

-type redirect_spec() ::
    #{direction := in | out | append | here,
      target := binary()}.
```

### Parse Depth

The parser is intentionally **shallow** — it detects top-level composition
operators and common shell metacharacters but does not attempt to fully parse
shell grammar. The goal is to surface structure, not to implement a complete
shell parser (which would be a security liability itself — parser bugs become
bypasses).

### Detected Patterns

| Pattern | Parsed As | Risk Level |
|---------|-----------|------------|
| `cmd1 && cmd2` | `chain('&&', ...)` | Each command evaluated separately |
| `cmd1 \|\| cmd2` | `chain('\|\|', ...)` | Each command evaluated separately |
| `cmd1 ; cmd2` | `chain(';', ...)` | Each command evaluated separately |
| `cmd1 \| cmd2` | `pipeline(...)` | Each stage evaluated separately |
| `$(cmd)` | `subshell('$()', ...)` | Inner command flagged for evaluation |
| `` `cmd` `` | `subshell(backtick, ...)` | Inner command flagged for evaluation |
| `cmd > file` | `redirect(out, ...)` | Target file path visible to policy |
| `cmd >> file` | `redirect(append, ...)` | Target file path visible to policy |
| `cmd < file` | `redirect(in, ...)` | Source file path visible to policy |
| Unrecognized | `opaque(raw)` | Highest risk — policy sees raw string only |

### List-Form Fast Path

List-form commands skip the structural parser entirely — they are inherently
structured and cannot contain composition operators:

```erlang
parse_command([<<"git">>, <<"status">>]) ->
    #{type => simple,
      program => <<"git">>,
      args => [<<"status">>],
      raw => <<"'git' 'status'">>}.
```

---

## 6. Layer 1: Static Policy Engine

### Purpose

Fast, configuration-driven allowlist/denylist evaluation against the parsed
command structure. This is the first line of defense after parsing.

### Policy Storage

Policies are stored in a `protected` ETS table owned by the security guard
process. This allows concurrent read access from any process while restricting
writes to the guard.

```erlang
%% Table: beam_agent_command_policy
%% Access: protected (guard writes, all read)
%% Key: {policy_type, pattern}
%% Value: action

-type policy_type() :: allow | deny.
-type policy_action() :: allow | deny | {deny, binary()}.
```

### Policy Rule Format

```erlang
-type policy_rule() :: #{
    type := allow | deny,
    match := match_spec(),
    reason => binary()   %% optional denial reason
}.

-type match_spec() ::
    %% Match program name (prefix, exact, or pattern)
    {program, binary()} |
    %% Match program + specific args
    {program_args, binary(), [arg_match()]} |
    %% Match any command containing substring
    {contains, binary()} |
    %% Match via custom function
    {function, fun((command_struct()) -> boolean())} |
    %% Match everything
    '*'.

-type arg_match() ::
    %% Exact match
    {exact, binary()} |
    %% Prefix match
    {prefix, binary()} |
    %% Wildcard
    '*'.
```

### Evaluation Order

1. **Deny rules are evaluated first.** If any deny rule matches, the command is
   denied regardless of allow rules. Deny always wins.
2. **Allow rules are evaluated second.** If the command matches an allow rule,
   it proceeds to the next layer.
3. **Default action** applies if no rule matches. The default depends on
   command form:
   - **List-form commands**: `allow` (inherently safe)
   - **String-form simple commands**: `ask` (defer to validator callback)
   - **String-form with composition**: `deny` (requires explicit allowlisting)
   - **Opaque commands**: `deny` (unparseable = untrusted)

### Chain Evaluation

For chain/pipeline commands, each sub-command is evaluated independently:

```erlang
evaluate_chain(#{type := chain, commands := Cmds}) ->
    Results = [evaluate_command(Cmd) || Cmd <- Cmds],
    case lists:any(fun(R) -> R =:= deny end, Results) of
        true -> deny;  %% Any denied sub-command denies the whole chain
        false -> allow
    end.
```

### Default Policy

The SDK ships with a sensible default policy that blocks known-dangerous
patterns without being overly restrictive:

```erlang
default_deny_rules() -> [
    %% Recursive force removal
    #{type => deny,
      match => {contains, <<"rm -rf">>},
      reason => <<"Recursive force removal blocked">>},

    %% Disk format
    #{type => deny,
      match => {program, <<"mkfs">>},
      reason => <<"Filesystem creation blocked">>},

    %% Disk operations
    #{type => deny,
      match => {program, <<"dd">>},
      reason => <<"Raw disk operation blocked">>},

    %% Shell fork bomb patterns
    #{type => deny,
      match => {contains, <<":(){:|:&};:">>},
      reason => <<"Fork bomb pattern detected">>},

    %% chmod 777
    #{type => deny,
      match => {contains, <<"chmod 777">>},
      reason => <<"Overly permissive chmod blocked">>},

    %% curl piped to shell
    #{type => deny,
      match => {contains, <<"curl">>},  %% refined by chain detection
      reason => <<"curl piped to shell blocked">>}
].
```

Note: The default deny list is intentionally conservative. It blocks obvious
destructive patterns but does not attempt to enumerate all dangerous commands.
Deep policy enforcement belongs in the validator callback (Layer 2) or Citadel.

### Policy Configuration

Users configure policies via the application environment:

```erlang
%% In sys.config or runtime config:
{beam_agent, [
    {command_policy, #{
        deny => [
            {program, <<"rm">>},
            {contains, <<"sudo">>}
        ],
        allow => [
            {program, <<"git">>},
            {program, <<"rebar3">>},
            {program, <<"mix">>},
            {program, <<"make">>}
        ],
        default_string_action => deny,  %% or ask | allow
        default_list_action => allow
    }}
]}.
```

### Policy Hot-Reload

Policies can be updated at runtime without restarting sessions:

```erlang
beam_agent_command_guard:reload_policy(NewPolicy).
%% Atomically replaces all ETS entries.
%% Active commands are not affected — policy is evaluated at submission time.
```

---

## 7. Layer 2: Validator Callback Behaviour

### Purpose

User-definable callback that receives rich context about the command and the
session, enabling custom security logic that goes beyond pattern matching.
This is the primary extension point for Citadel.

### Behaviour Definition

```erlang
-module(beam_agent_command_validator).

-doc """
Behaviour for command execution validation.

Implement this behaviour to define custom security policies for command
execution. The validator is called after static policy evaluation (Layer 1)
and before the security guard check (Layer 3).

The default implementation (`beam_agent_command_validator_default`) checks
the static allowlist/denylist. Replace it to implement deep inspection,
intent-based reasoning, or integration with external security systems.
""".

-callback validate(Command, Context) -> Result when
    Command :: beam_agent_command_security:command_struct(),
    Context :: beam_agent_command_security:validation_context(),
    Result  :: allow
             | {deny, Reason :: binary()}
             | {deny, Reason :: binary(), Details :: map()}.

-callback init(Config :: map()) -> {ok, State :: term()} | {error, term()}.

-callback handle_post_execution(Command, Context, ExecResult, State) ->
    {ok, NewState :: term()} when
    Command    :: beam_agent_command_security:command_struct(),
    Context    :: beam_agent_command_security:validation_context(),
    ExecResult :: {ok, map()} | {error, term()},
    State      :: term().

-optional_callbacks([init/1, handle_post_execution/4]).
```

### Validation Context

The validator receives comprehensive context — not just the command string:

```erlang
-type validation_context() :: #{
    %% The parsed command structure (from Layer 0)
    command_struct := command_struct(),

    %% Raw command as provided by caller
    raw_command := binary() | string() | [binary()],

    %% Command form: list-form is inherently safer
    command_form := list | string,

    %% Session state from the backend gen_statem
    session_state := atom(),

    %% Agent identity
    agent := atom(),  %% claude | codex | gemini | opencode | copilot

    %% Command execution options
    opts := command_opts(),

    %% Working directory (if specified)
    cwd := binary() | undefined,

    %% Environment variables being set
    env := [{string(), string()}] | undefined,

    %% Command history — last N commands with results
    history := [command_record()],

    %% Timestamp
    timestamp := integer(),

    %% Static policy result (from Layer 1)
    policy_result := allow | deny | ask,

    %% Custom metadata (extensible by Citadel)
    metadata := map()
}.

-type command_record() :: #{
    command := binary(),
    command_struct := command_struct(),
    result := {ok, integer()} | {error, term()},  %% exit_code or error
    timestamp := integer(),
    duration := integer()
}.
```

### Default Validator

The SDK ships with a default validator that defers to the static policy:

```erlang
-module(beam_agent_command_validator_default).
-behaviour(beam_agent_command_validator).

-export([validate/2]).

validate(_Command, #{policy_result := allow}) -> allow;
validate(_Command, #{policy_result := deny}) ->
    {deny, <<"Denied by static policy">>};
validate(_Command, #{policy_result := ask, command_form := list}) ->
    allow;  %% List-form commands are safe
validate(Command, #{policy_result := ask}) ->
    %% String-form with no explicit policy: deny by default
    {deny, <<"String-form command requires explicit allowlisting">>}.
```

### Configuration

```erlang
%% In sys.config:
{beam_agent, [
    {command_validator, beam_agent_command_validator_default},
    %% Or a custom validator:
    %% {command_validator, my_app_command_validator},
    %% Or Citadel's validator:
    %% {command_validator, citadel_beam_validator},

    {command_validator_config, #{
        %% Passed to validator's init/1
    }}
]}.
```

### Validator Lifecycle

1. **Initialization**: `init/1` called once when the security guard starts.
   Returns state that persists across validations.
2. **Validation**: `validate/2` called for every command. Must return quickly —
   the command is blocked until validation completes.
3. **Post-execution** (optional): `handle_post_execution/4` called after each
   command completes, allowing the validator to update its internal state based
   on outcomes.

---

## 8. Layer 3: Security Guard Process

### Purpose

A persistent `gen_statem` process that tracks command execution history,
enforces rate limits, detects temporal patterns, and manages overall security
state. This is the stateful layer that gives BeamAgent an advantage over every
competitor.

### Process Properties

```erlang
%% Created during application startup
%% Properties:
%%   - erts_internal:spawn_system_process/3 (unkillable)
%%   - process_flag(priority, high)
%%   - process_flag(trap_exit, true)
%%   - Owns ETS tables: command_history, policy_cache, rate_limits
%%   - Supervised by beam_agent_sup with permanent restart
```

### State Machine

```
                    +----------+
                    |          |
          init ---> | inactive | <--- policy reload
                    |          |
                    +----+-----+
                         |
                   first command
                         |
                    +----v-----+
                    |          |
              +---> |  active  | <---+
              |     |          |     |
              |     +----+-----+     |
              |          |           |
         command ok   rate limit     command ok
              |       exceeded       |
              |          |           |
              |     +----v-----+    |
              |     |          |    |
              +---- | throttle +----+
                    |          |
                    +----+-----+
                         |
                    threshold
                    exceeded
                         |
                    +----v-----+
                    |          |
                    | lockdown |
                    |          |
                    +----------+
```

**States**:

- `inactive` — No commands executed yet. Waiting for first command.
- `active` — Normal operation. Commands evaluated and tracked.
- `throttle` — Rate limit exceeded. Commands delayed or denied until rate
  subsides.
- `lockdown` — Suspicious pattern detected. All commands denied until
  explicitly reset. Telemetry alert emitted.

### ETS Tables

**`beam_agent_command_history`** (ordered_set, protected):

```erlang
%% Key: {Timestamp, Ref}
%% Value: command_record()
%% Automatically pruned to last N entries (default: 100)
```

**`beam_agent_policy_cache`** (set, protected):

```erlang
%% Key: {policy_type, match_spec}
%% Value: policy_action
%% Rebuilt on policy reload
```

**`beam_agent_rate_limits`** (set, protected):

```erlang
%% Key: {Category, Window}
%% Value: {Count, WindowStart}
%% Categories: per-program, per-type (destructive, read, write), global
```

### Rate Limiting

```erlang
-type rate_limit_config() :: #{
    %% Global: max commands per window across all programs
    global => {MaxCount :: pos_integer(), WindowMs :: pos_integer()},

    %% Per-program: max invocations of a specific program per window
    per_program => {MaxCount :: pos_integer(), WindowMs :: pos_integer()},

    %% Per-category: max commands of a category per window
    per_category => #{
        destructive => {MaxCount :: pos_integer(), WindowMs :: pos_integer()},
        filesystem_write => {MaxCount :: pos_integer(), WindowMs :: pos_integer()},
        network => {MaxCount :: pos_integer(), WindowMs :: pos_integer()}
    }
}.
```

Default rate limits:

```erlang
default_rate_limits() -> #{
    global => {60, 60000},           %% 60 commands per minute
    per_program => {20, 60000},      %% 20 invocations of same program per minute
    per_category => #{
        destructive => {5, 60000},   %% 5 destructive commands per minute
        filesystem_write => {30, 60000},
        network => {10, 60000}
    }
}.
```

### Temporal Pattern Detection

The guard tracks command sequences and can detect suspicious patterns:

```erlang
-type temporal_rule() :: #{
    name := binary(),
    description := binary(),
    %% Pattern: sequence of command matchers that must occur within window
    pattern := [command_matcher()],
    window_ms := pos_integer(),
    action := throttle | lockdown | alert
}.

-type command_matcher() :: #{
    program => binary(),
    args_contain => binary(),
    exit_code => integer(),
    category => atom()
}.
```

Example built-in patterns:

```erlang
default_temporal_rules() -> [
    #{name => <<"rapid_deletion">>,
      description => <<"Multiple file deletions in rapid succession">>,
      pattern => [
          #{program => <<"rm">>},
          #{program => <<"rm">>},
          #{program => <<"rm">>}
      ],
      window_ms => 10000,
      action => throttle},

    #{name => <<"recon_then_destroy">>,
      description => <<"Directory listing followed by recursive deletion">>,
      pattern => [
          #{program => <<"ls">>},
          #{program => <<"rm">>, args_contain => <<"-r">>}
      ],
      window_ms => 30000,
      action => alert},

    #{name => <<"repeated_failures">>,
      description => <<"Multiple command failures may indicate probing">>,
      pattern => [
          #{exit_code => 1},
          #{exit_code => 1},
          #{exit_code => 1},
          #{exit_code => 1},
          #{exit_code => 1}
      ],
      window_ms => 30000,
      action => alert}
].
```

### Guard API

```erlang
%% Submit a command for evaluation (called by command_core)
-spec evaluate(command_struct(), validation_context()) ->
    allow | {deny, binary()} | {throttle, RetryAfterMs :: pos_integer()}.

%% Force lockdown
-spec lockdown(Reason :: binary()) -> ok.

%% Reset from lockdown
-spec reset() -> ok.

%% Reload policies from config
-spec reload_policy(policy_config()) -> ok.

%% Get current state
-spec status() -> #{state := atom(), history_size := non_neg_integer(),
                     rate_limits := map()}.
```

---

## 9. Layer 4: Restricted Executor

### Purpose

Execute approved commands in a restricted process with hard resource limits,
I/O interception, and lifecycle monitoring.

### Executor Process Properties

Each command execution spawns a dedicated process with the following
restrictions:

```erlang
spawn_restricted_executor(Command, Opts, Guard) ->
    MaxHeap = maps:get(max_heap_size, Opts,
        application:get_env(beam_agent, command_max_heap, 50_000_000)),
    MaxOutput = maps:get(max_output, Opts, 1_048_576),  %% 1MB
    Timeout = maps:get(timeout, Opts, 30_000),

    Pid = spawn_opt(fun() ->
        %% Set hard memory limit
        process_flag(max_heap_size,
            #{size => MaxHeap, kill => true, error_logger => true}),

        %% Set sensitive flag if handling credentials
        case maps:get(sensitive, Opts, false) of
            true -> process_flag(sensitive, true);
            false -> ok
        end,

        %% Execute command via port
        execute_port(Command, Opts, MaxOutput, Timeout)
    end, [
        link,
        {priority, normal},  %% Security guard runs at high, executor at normal
        monitor
    ]),

    %% Install custom group leader for I/O interception
    GroupLeader = spawn_link(fun() -> io_interceptor(Pid, Guard) end),
    erlang:group_leader(GroupLeader, Pid),

    %% Register with guard for monitoring
    beam_agent_command_guard:register_executor(Pid, Command),

    Pid.
```

### I/O Interceptor

The group leader process intercepts all I/O from the executor:

```erlang
io_interceptor(ExecutorPid, Guard) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            %% Log all I/O through the executor
            %% Could filter, block, or redirect based on policy
            case handle_io_request(Request, Guard) of
                {ok, Reply} ->
                    From ! {io_reply, ReplyAs, Reply};
                {deny, Reason} ->
                    From ! {io_reply, ReplyAs, {error, Reason}}
            end,
            io_interceptor(ExecutorPid, Guard);
        {'EXIT', ExecutorPid, _Reason} ->
            ok
    end.
```

### Resource Limits Summary

| Resource | Mechanism | Default | Configurable |
|----------|-----------|---------|-------------|
| Memory | `max_heap_size` | 50MB | Yes |
| Output | `max_output` truncation | 1MB | Yes |
| Time | `receive after Timeout` + `port_close` | 30s | Yes |
| CPU | Process priority (normal, guard is high) | normal | No |
| I/O | Group leader interception | Log only | Yes |

---

## 10. Layer 5: Audit and Observability

### Purpose

Comprehensive audit trail of all security decisions, command executions, and
system events. Every security-relevant action emits telemetry and is recorded
in the command history.

### Telemetry Integration

Extends the existing telemetry infrastructure (from `beam_agent_telemetry_core`)
with security-specific events. See [Section 11](#11-telemetry-events) for the
complete event catalogue.

### Sequential Trace Integration

For high-security environments, `seq_trace` can be enabled to track causal
chains across processes:

```erlang
%% Enable causal tracking for a command
seq_trace:set_token(label, CommandRef),
seq_trace:set_token(send, true),
seq_trace:set_token('receive', true),
seq_trace:set_token(timestamp, true),
%% Now every message send/receive in this request chain is recorded
```

### System Monitor Integration

```erlang
%% Monitor for resource abuse
erlang:system_monitor(SecurityGuardPid, [
    {long_gc, 50},           %% GC pauses > 50ms
    {long_schedule, 50},     %% Scheduling delays > 50ms
    {large_heap, 10_000_000}, %% Heaps > 10MB
    busy_port                 %% Port sending blocked
]).
```

### Command History

All executed commands are recorded in the `beam_agent_command_history` ETS
table with full metadata:

```erlang
-type history_entry() :: #{
    ref := reference(),
    timestamp := integer(),
    command := binary(),
    command_struct := command_struct(),
    command_form := list | string,
    agent := atom(),
    session_state := atom(),
    policy_result := allow | deny | ask,
    validator_result := allow | {deny, binary()},
    guard_result := allow | {deny, binary()} | {throttle, pos_integer()},
    execution_result := {ok, integer()} | {error, term()} | skipped,
    duration := integer() | undefined,
    cwd := binary() | undefined,
    env_keys := [string()]  %% keys only, never values
}.
```

---

## 11. Telemetry Events

All events are under the `[:beam_agent, command, ...]` prefix.

### Existing Events (from bead 2r7.1)

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[beam_agent, command, run, start]` | `system_time` | `command, cwd, agent` |
| `[beam_agent, command, run, stop]` | `duration` | `command, cwd, agent, exit_code` |
| `[beam_agent, command, run, exception]` | `system_time` | `command, cwd, agent, reason` |

### New Security Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[beam_agent, command, security, allowed]` | `evaluation_time` | `command, agent, layers_passed, policy_result, validator_result` |
| `[beam_agent, command, security, denied]` | `evaluation_time` | `command, agent, denied_by, reason, layer` |
| `[beam_agent, command, security, throttled]` | `evaluation_time` | `command, agent, retry_after_ms, rate_category` |
| `[beam_agent, command, security, lockdown]` | `system_time` | `agent, reason, trigger_pattern` |
| `[beam_agent, command, security, reset]` | `system_time` | `agent, reset_by` |
| `[beam_agent, command, security, policy_reload]` | `system_time` | `rules_count, source` |
| `[beam_agent, command, security, pattern_detected]` | `system_time` | `pattern_name, description, action, commands` |
| `[beam_agent, command, security, resource_alarm]` | `system_time` | `alarm_type, value, threshold` |

### Event Flow Example

A denied command produces:

```
1. [beam_agent, command, run, start]           — command submitted
2. [beam_agent, command, security, denied]     — denied at Layer 1 (denylist)
3. [beam_agent, command, run, exception]       — command not executed
```

An allowed command with rate limiting:

```
1. [beam_agent, command, run, start]           — command submitted
2. [beam_agent, command, security, allowed]    — passed all layers
3. [beam_agent, command, run, stop]            — command completed
4. (guard updates history, checks patterns)
5. [beam_agent, command, security, pattern_detected]  — if pattern matched
```

---

## 12. Types and Data Structures

### Core Types

```erlang
%%--------------------------------------------------------------------
%% Command representation
%%--------------------------------------------------------------------

-type command_struct() ::
    #{type := simple,
      program := binary(),
      args := [binary()],
      raw := binary()} |
    #{type := chain,
      operator := '&&' | '||' | ';',
      commands := [command_struct()]} |
    #{type := pipeline,
      commands := [command_struct()]} |
    #{type := subshell,
      form := '()' | '$()' | backtick,
      inner := binary()} |
    #{type := redirect,
      command := command_struct(),
      redirects := [redirect_spec()]} |
    #{type := opaque,
      raw := binary()}.

-type redirect_spec() ::
    #{direction := in | out | append | here,
      target := binary()}.

%%--------------------------------------------------------------------
%% Policy types
%%--------------------------------------------------------------------

-type policy_rule() :: #{
    type := allow | deny,
    match := match_spec(),
    reason => binary()
}.

-type match_spec() ::
    {program, binary()} |
    {program_args, binary(), [arg_match()]} |
    {contains, binary()} |
    {function, fun((command_struct()) -> boolean())} |
    '*'.

-type arg_match() ::
    {exact, binary()} |
    {prefix, binary()} |
    '*'.

-type policy_config() :: #{
    deny := [policy_rule()],
    allow := [policy_rule()],
    default_string_action := allow | deny | ask,
    default_list_action := allow | deny | ask
}.

%%--------------------------------------------------------------------
%% Validation types
%%--------------------------------------------------------------------

-type validation_context() :: #{
    command_struct := command_struct(),
    raw_command := binary() | string() | [binary()],
    command_form := list | string,
    session_state := atom(),
    agent := atom(),
    opts := map(),
    cwd := binary() | undefined,
    env := [{string(), string()}] | undefined,
    history := [command_record()],
    timestamp := integer(),
    policy_result := allow | deny | ask,
    metadata := map()
}.

-type command_record() :: #{
    command := binary(),
    command_struct := command_struct(),
    result := {ok, integer()} | {error, term()},
    timestamp := integer(),
    duration := integer()
}.

%%--------------------------------------------------------------------
%% Guard types
%%--------------------------------------------------------------------

-type guard_state() :: inactive | active | throttle | lockdown.

-type rate_limit_config() :: #{
    global => {pos_integer(), pos_integer()},
    per_program => {pos_integer(), pos_integer()},
    per_category => #{atom() => {pos_integer(), pos_integer()}}
}.

-type temporal_rule() :: #{
    name := binary(),
    description := binary(),
    pattern := [command_matcher()],
    window_ms := pos_integer(),
    action := throttle | lockdown | alert
}.

-type command_matcher() :: #{
    program => binary(),
    args_contain => binary(),
    exit_code => integer(),
    category => atom()
}.

%%--------------------------------------------------------------------
%% Security evaluation result
%%--------------------------------------------------------------------

-type security_result() ::
    allow |
    {deny, Reason :: binary()} |
    {deny, Reason :: binary(), Details :: map()} |
    {throttle, RetryAfterMs :: pos_integer()}.
```

---

## 13. Default Policies

### Built-in Deny Rules

These are always active unless explicitly removed:

| Pattern | Reason |
|---------|--------|
| `rm -rf /` | Root filesystem deletion |
| `rm -rf ~` | Home directory deletion |
| `rm -rf .` | Working directory deletion |
| `mkfs.*` | Filesystem creation |
| `dd if=` | Raw disk operations |
| `:(){ :\|:& };:` | Fork bomb |
| `chmod 777` | Overly permissive permissions |
| `> /dev/sda` | Direct device write |
| `shutdown` | System shutdown |
| `reboot` | System reboot |
| `halt` | System halt |
| `init 0` | System halt |
| `kill -9 1` | Kill init process |

### Built-in Allow Rules (for list-form only)

List-form commands are allowed by default because they cannot be
shell-injected. No built-in allow rules for string-form commands.

### Command Categories

Commands are categorized for rate limiting and temporal pattern detection:

| Category | Examples | Default Rate Limit |
|----------|---------|-------------------|
| `destructive` | `rm`, `rmdir`, `shred`, `truncate` | 5/min |
| `filesystem_write` | `cp`, `mv`, `touch`, `mkdir`, `chmod`, `chown` | 30/min |
| `filesystem_read` | `ls`, `cat`, `head`, `tail`, `find`, `grep` | unlimited |
| `network` | `curl`, `wget`, `ssh`, `scp`, `nc` | 10/min |
| `process` | `kill`, `pkill`, `killall` | 5/min |
| `package` | `apt`, `yum`, `brew`, `npm`, `pip`, `cargo` | 10/min |
| `vcs` | `git`, `hg`, `svn` | unlimited |
| `build` | `make`, `rebar3`, `mix`, `cargo build`, `go build` | unlimited |
| `unknown` | Anything not categorized | uses global limit |

---

## 14. Extension Points (Citadel Integration)

### Primary Extension: Validator Behaviour

Citadel replaces the default validator with its own implementation:

```erlang
%% In Citadel's configuration:
{beam_agent, [
    {command_validator, citadel_beam_validator},
    {command_validator_config, #{
        citadel_endpoint => "https://citadel.internal:8443",
        policy_set => <<"production-agentic">>,
        cache_ttl => 5000
    }}
]}
```

Citadel's validator receives the full `validation_context()` including session
state, command history, and structured command representation — enabling deep
contextual reasoning that the SDK's default validator doesn't attempt.

### Secondary Extension: Custom Temporal Rules

Citadel can register additional temporal pattern rules:

```erlang
beam_agent_command_guard:add_temporal_rule(#{
    name => <<"citadel_exfiltration_detect">>,
    description => <<"Data listing followed by network command">>,
    pattern => [
        #{category => filesystem_read},
        #{category => network}
    ],
    window_ms => 60000,
    action => lockdown
}).
```

### Tertiary Extension: Custom Command Categories

Citadel can register additional command categories:

```erlang
beam_agent_command_guard:register_category(
    database,
    [<<"psql">>, <<"mysql">>, <<"mongosh">>, <<"redis-cli">>],
    #{rate_limit => {5, 60000}}
).
```

### Quaternary Extension: Guard State Callbacks

Citadel can register callbacks for guard state transitions:

```erlang
beam_agent_command_guard:on_state_change(fun(OldState, NewState, Reason) ->
    citadel_alerting:notify(#{
        event => guard_state_change,
        from => OldState,
        to => NewState,
        reason => Reason
    })
end).
```

### Extension Architecture

```
+-------------------+     +---------------------------+
|   BeamAgent SDK   |     |       Citadel/Warden      |
|                   |     |                           |
| Layer 0: Parser   |     |                           |
| Layer 1: Policy   |     |                           |
| Layer 2: --------->---->| Deep Validator            |
|   (behaviour)     |     |   - Intent reasoning      |
| Layer 3: Guard    |<----<- Temporal rules           |
|   (gen_statem)    |<----<- Custom categories        |
| Layer 4: Executor |     |   - State callbacks       |
| Layer 5: Audit  -->---->| Compliance reporting      |
|                   |     |                           |
| (Application)     |     | (Application + OS)        |
+-------------------+     +---------------------------+
                                    |
                          +---------v---------+
                          |   OS Enforcement   |
                          |  - seccomp-bpf     |
                          |  - landlock        |
                          |  - namespaces      |
                          |  - cgroups         |
                          +-------------------+
```

---

## 15. Implementation Phasing

### Phase 1: Foundation (beads 2r7.2 + 2r7.3)

**Modules**: `beam_agent_command_parser`, `beam_agent_command_validator`

- Structural command parser (Layer 0)
- Validator callback behaviour definition
- Default validator implementation
- Documentation recommending list-form as safe default
- Update `beam_agent_command_core:run/2` to route through validator

### Phase 2: Static Policy (bead 2r7.4)

**Modules**: `beam_agent_command_policy`

- Allowlist/denylist with pattern matching
- ETS-backed policy storage
- Default deny rules
- Policy configuration via application environment
- Policy hot-reload API
- Command categorization

### Phase 3: Security Guard (bead 2r7.5 + new work)

**Modules**: `beam_agent_command_guard`

- `gen_statem` security guard process
- Command history tracking in ETS
- Rate limiting per category
- Temporal pattern detection
- Guard state machine (inactive/active/throttle/lockdown)
- Permission checks on execution path

### Phase 4: Restricted Executor (new work)

**Modules**: modifications to `beam_agent_command_core`

- Spawn executor with `max_heap_size`
- Group leader interception
- Sensitive flag for credential-handling commands
- Integration with guard for lifecycle monitoring

### Phase 5: Audit Enhancement (new work)

- Security telemetry events
- `seq_trace` integration (optional, for high-security deployments)
- `system_monitor` integration
- Command history pruning and retention

### Phase 6: Citadel Integration Points (future)

- Validator behaviour stabilization
- Temporal rule registration API
- Custom category API
- Guard state callbacks
- Documentation for Citadel integration

---

## 16. Governance Boundary

The SDK provides **extension points**, not a **policy engine**.

| Responsibility | BeamAgent SDK | Citadel/Warden |
|---------------|---------------|----------------|
| Command parsing | Structural parser | N/A (uses SDK parser) |
| Default policies | Conservative denylist | Deep policy sets |
| Validation interface | Behaviour definition | Behaviour implementation |
| Stateful tracking | History, rate limits | Cross-session, intent |
| Process containment | max_heap, group_leader | cgroups, namespaces |
| OS enforcement | N/A | seccomp, landlock, Seatbelt |
| Audit | Telemetry events | Compliance reporting |
| Policy language | App env config | Full policy DSL |

The SDK does not attempt to:

- Define a policy language or DSL
- Implement intent-based reasoning
- Provide OS-level sandboxing
- Manage cross-session security state
- Generate compliance reports
- Implement RBAC or multi-tenant isolation

These belong in Citadel/Warden.

---

## 17. Threat Model

### In-Scope Threats (SDK addresses)

| Threat | Mitigation Layer |
|--------|-----------------|
| Shell injection via string-form commands | Layer 0 (structural parse) + Layer 1 (default-deny for string-form) |
| Command composition attacks (`&&`, `\|\|`, `;`) | Layer 0 (chain detection) + Layer 1 (per-segment evaluation) |
| Subshell/command substitution (`$()`, backticks) | Layer 0 (detection) + Layer 1 (deny by default) |
| Known dangerous commands (`rm -rf /`, `mkfs`) | Layer 1 (built-in denylist) |
| Rapid destructive command sequences | Layer 3 (temporal pattern detection) |
| Resource exhaustion (memory) | Layer 4 (`max_heap_size`) |
| Resource exhaustion (time) | Layer 4 (timeout enforcement) |
| Resource exhaustion (output) | Layer 4 (`max_output` truncation) |
| Unobserved security decisions | Layer 5 (telemetry for all decisions) |

### Out-of-Scope Threats (Citadel/OS domain)

| Threat | Required Mitigation |
|--------|-------------------|
| NIF loading (arbitrary native code) | OS-level code signing, seccomp |
| Filesystem access beyond command scope | landlock, filesystem sandboxing |
| Network access from port programs | Network namespacing, firewall |
| Process inspection (`process_info`) | N/A — cooperative model limitation |
| `erlang:halt/0` (VM shutdown) | Container restart policies |
| Kernel exploits from port programs | Container isolation, seccomp |
| Side-channel attacks | Hardware/OS mitigations |

### Bypass Considerations

The SDK's security is **application-level**. A determined attacker with the
ability to execute arbitrary Erlang code in the VM can bypass all layers
(e.g., by calling `erlang:open_port/2` directly, bypassing
`beam_agent_command_core`). This is by design — the SDK protects against
**agent-initiated** command execution through the SDK's API, not against
arbitrary code execution within the VM. OS-level containment (Citadel) is
required for the latter.

---

## Appendix A: BEAM Attack Surface

Functions with no built-in access control that represent the attack surface
for agentic systems:

| Function | Risk | Notes |
|----------|------|-------|
| `os:cmd/1,2` | Execute arbitrary OS commands | Bypasses all SDK security if called directly |
| `erlang:open_port/2` | Spawn arbitrary executables | The primitive that `beam_agent_command_core` wraps |
| `erlang:load_nif/2` | Load arbitrary native code | NIFs run in scheduler threads |
| `erlang:halt/0,1,2` | Shut down entire VM | No protection possible within the VM |
| `init:stop/0,1` | Stop VM via init | Same as halt |
| `init:restart/0,1` | Restart VM | Disruption |
| `heart:set_cmd/1` | Set command run on VM death | Persistence mechanism |
| `erlang:load_module/2` | Load arbitrary BEAM code | Code injection |
| `erlang:purge_module/1` | Kill processes running module | Denial of service |
| `erlang:suspend_process/1` | Freeze any process | Can suspend security guard |
| `erlang:exit/2` | Kill any process (except system) | Can kill non-system security processes |
| `erlang:set_cookie/1,2` | Change distribution auth | Weaken distribution security |
| `erlang:process_flag/3` | Modify other process flags | Change error handler, priority |
| `sys:replace_state/2` | Modify OTP process state | Tamper with security guard state |
| `erlang:group_leader/2` | Redirect I/O for any process | Bypass I/O interception |
| `persistent_term:put/2` | Write globally visible data | Information disclosure |
| `code:set_path/1` | Redirect module loading | Load malicious modules |
| `code:unstick_mod/1` | Allow reloading sticky modules | Replace security modules |
| `erlang:fun_info/1` | Extract closure internals | Secret extraction from closures |

---

## Appendix B: Competitive Detail

### Codex: Execution Policy Deep Dive

Codex uses a Starlark-based `execpolicy` DSL (`default.policy`) where each
allowed program is defined with:

```python
define_program(
    program="sed",
    options=[flag("-n"), flag("-u")],  # -i and -f deliberately excluded
    args=[ARG_SED_COMMAND, ARG_RFILES],
    system_path=["/usr/bin/sed"],
)
```

Key design: `sed` is specifically handled because GNU sed's `s/pattern/cmd/e`
flag executes arbitrary shell commands. The policy deliberately excludes `-i`
(in-place edit) and `-f` (script file) flags.

Sandbox modes: `read-only` | `workspace-write` | `danger-full-access`
Approval modes: `never` | `on-request` | `on-failure` | `untrusted`
OS enforcement: macOS Seatbelt (`/usr/bin/sandbox-exec`)

### Gemini CLI: Shell Command Restrictions

Configuration-driven with prefix matching:

```json
{
  "tools": {
    "core": ["run_shell_command(git)", "run_shell_command(npm)"],
    "exclude": ["run_shell_command(rm)"]
  }
}
```

Command chaining: splits on `&&`, `||`, `;` and validates each segment.
Blocklist always takes precedence over allowlist.

### OpenCode: Permission System

Three-action model with wildcard matching:

```json
{
  "permission": {
    "bash": {
      "*": "ask",
      "git *": "allow",
      "rm *": "deny"
    }
  }
}
```

Last matching rule wins. Explicit `SECURITY.md` caveat: "The permission system
is not a sandbox."

Reply model: `once` | `always` | `reject`. "Always" persists the approval.

### Copilot SDK: Pre-Tool-Use Hooks

Deny-by-default with hook-based validation:

```typescript
const session = await client.createSession({
  hooks: {
    onPreToolUse: async (input) => {
      if (BLOCKED_TOOLS.includes(input.toolName)) {
        return {
          permissionDecision: "deny",
          permissionDecisionReason: "Not permitted",
        };
      }
      return {
        permissionDecision: "allow",
        modifiedArgs: { ...args, timeout: args.timeout ?? 30000 },
      };
    },
  },
});
```

Notable: hooks can modify args (inject timeouts, redirect paths) in addition
to allowing/denying.
