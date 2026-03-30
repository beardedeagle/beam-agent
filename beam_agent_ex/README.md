# BeamAgent

Idiomatic Elixir wrapper for the canonical `beam_agent` SDK.

`BeamAgent` is the public Elixir boundary for the repo. It provides
backend-selected session lifecycle/query APIs, shared runtime/catalog
capabilities, capability introspection, and the lower-level foundation modules
used across all five supported backends (Claude, Codex, Gemini, OpenCode,
Copilot).

Backend-specific wrappers such as `ClaudeEx`, `CodexEx`, `GeminiEx`,
`OpencodeEx`, and `CopilotEx` still ship inside this same package as native
escape hatches.

## Why This Wrapper?

The Erlang `:beam_agent` module works from Elixir, but this wrapper provides:

- **Elixir namespacing**: `BeamAgent.MCP`, `BeamAgent.Hooks`, `BeamAgent.Content`
- **Full typespecs**: visible to Dialyxir, LSP, and ExDoc
- **Idiomatic API**: `nil` instead of `:undefined`, guard clauses, doc examples
- **ExDoc documentation**: browsable on hex.pm

## Modules

| Module | Purpose |
|--------|---------|
| `BeamAgent` | Canonical session lifecycle/query surface plus wire utilities |
| `BeamAgent.Account` | Account lifecycle operations — login, logout, rate limits, and account info |
| `BeamAgent.Apps` | App and project management — listing, initializing, logging, and app modes |
| `BeamAgent.Artifacts` | Durable runtime outputs — plans, diffs, reviews, summaries, and transcript snapshots |
| `BeamAgent.Capabilities` | Support-level / implementation / fidelity introspection |
| `BeamAgent.Catalog` | Shared tools/skills/plugins/agents accessors |
| `BeamAgent.Checkpoint` | Checkpoint save/restore for rollback and recovery |
| `BeamAgent.Command` | Command execution lifecycle — validation, audit, and dispatch |
| `BeamAgent.CommandValidator` | Pluggable command validation behaviour |
| `BeamAgent.Config` | Configuration read/write — individual values, batches, and external agent config import |
| `BeamAgent.Content` | Content block / flat message conversion |
| `BeamAgent.Context` | Context pressure reporting and caller-driven compaction |
| `BeamAgent.Control` | Collaboration, realtime sessions, thinking budget, and feedback |
| `BeamAgent.File` | File discovery and inspection — text search, file search, symbol search, and VCS status |
| `BeamAgent.Hooks` | SDK lifecycle hooks (pre/post tool use, stop, etc.) |
| `BeamAgent.Journal` | Durable append-only event journal for replay of canonical domain events |
| `BeamAgent.MCP` | MCP 2025-06-18 protocol, server/client dispatch, tool registry, and transports |
| `BeamAgent.Memory` | Durable cross-session facts and notes with lexical recall |
| `BeamAgent.Orchestrator` | Process-free parent-child execution with cross-session lineage |
| `BeamAgent.Policy` | Reusable allow/deny policy profiles with deterministic, deny-wins evaluation |
| `BeamAgent.Provider` | LLM provider and sub-agent management — selection, OAuth, and multi-provider routing |
| `BeamAgent.Raw` | Explicit backend-native escape hatch |
| `BeamAgent.Routing` | Backend routing by policy — sticky, round-robin, failover, and capability-first |
| `BeamAgent.Routines` | Durable one-shot and interval job records with caller-driven scheduling |
| `BeamAgent.Runs` | Durable run and step lifecycle scoped to sessions, threads, and parent runs |
| `BeamAgent.Runtime` | Shared provider and default-agent runtime state |
| `BeamAgent.Search` | Fuzzy file search — one-shot and stateful sessions with cached listings |
| `BeamAgent.SessionStore` | Universal session history, fork, revert, share, summarize |
| `BeamAgent.Skills` | Skill lifecycle — listing, exporting, and enabling/disabling local and remote skills |
| `BeamAgent.Telemetry` | Telemetry event helpers |
| `BeamAgent.Threads` | Universal thread start/resume/read/archive/rollback |
| `BeamAgent.Todo` | Todo extraction and summary helpers |
| `BeamAgent.Agents` | Convenience facade for agent registration (delegates to Catalog) |
| `BeamAgent.Plugins` | Convenience facade for plugin registration (delegates to Catalog) |
| `BeamAgent.SlashCommands` | Convenience facade for slash command registration (delegates to Catalog) |
| `BeamAgent.Credential` | Secure credential storage — cookie generation and sensitive key encryption |
| `BeamAgent.SensitiveKeys` | Canonical sensitive key registry for credential and redaction subsystems |
| `BeamAgent.Store` | Pluggable store adapter API (ETS default, DETS durable) |
| `ClaudeEx` / `CodexEx` / `GeminiEx` / `OpencodeEx` / `CopilotEx` | Backend-specific wrappers |

## Quick Start

### Starting Sessions

```elixir
{:ok, session} = BeamAgent.start_session(
  backend: :claude,
  cli_path: "claude",
  permission_mode: "bypassPermissions"
)

{:ok, messages} = BeamAgent.query(session, "Explain OTP supervisors")
BeamAgent.stop(session)
```

### Streaming

```elixir
session
|> BeamAgent.stream!("Explain GenServer")
|> Enum.each(fn
  %{type: :text, content: text} -> IO.write(text)
  %{type: :result} -> IO.puts("\n--- Done ---")
  _ -> :ok
end)
```

### Runtime and Catalog Access

```elixir
BeamAgent.set_provider(session, "openai")
BeamAgent.set_agent(session, "architect")

{:ok, tools} = BeamAgent.list_tools(session)
{:ok, skills} = BeamAgent.Catalog.list_skills(session)
{:ok, caps} = BeamAgent.Capabilities.for_backend(:codex)

# Per-session model and permission mode
BeamAgent.set_model(session, "o3")
BeamAgent.set_permission_mode(session, "bypassPermissions")

# Runtime capability discovery (23-capability matrix)
{:ok, caps} = BeamAgent.session_capabilities(session)
```

### Backend Event Streaming

```elixir
session
|> BeamAgent.event_stream!(timeout: 30_000)
|> Enum.each(&IO.inspect/1)
```

Backends with richer native event feeds keep them. The canonical event bus
fills the same API surface for the rest.

### Codex Direct Realtime Voice

Use the canonical wrapper with `transport: :realtime` when you want the direct
Codex realtime websocket path instead of app-server JSON-RPC:

```elixir
{:ok, session} =
  BeamAgent.start_session(
    backend: :codex,
    transport: :realtime,
    api_key: "sk-live-key",
    voice: "alloy"
  )

{:ok, %{thread_id: thread_id}} = BeamAgent.thread_realtime_start(session, %{mode: "voice"})
{:ok, _} = BeamAgent.thread_realtime_append_text(session, thread_id, %{text: "Hello"})
:ok = BeamAgent.stop(session)
```

### MCP and Hooks

```elixir
tool = BeamAgent.MCP.tool(
  "lookup_user",
  "Look up a user by ID",
  %{"type" => "object",
    "properties" => %{"id" => %{"type" => "string"}}},
  fn input ->
    id = Map.get(input, "id", "")
    {:ok, [%{type: :text, text: "User: #{id}"}]}
  end
)

server = BeamAgent.MCP.server("my-tools", [tool])
hook = BeamAgent.Hooks.hook(:pre_tool_use, fn ctx ->
  case Map.get(ctx, :tool_name, "") do
    "Bash" -> {:deny, "Shell access denied"}
    _ -> {:ok, ctx}
  end
end)
```

### Telemetry

The `:telemetry` library is an **optional** dependency. When present, all
adapters emit events via `:telemetry.execute/3`. When absent, emission is a
silent no-op. To opt in, add `{:telemetry, "~> 1.3"}` to your application's
`deps` and ensure it is started, then attach handlers:

```elixir
:telemetry.attach("my-handler",
  [:beam_agent, :claude, :query, :stop],
  fn _event, %{duration: d}, _meta, _config ->
    IO.puts("Query took #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end,
  nil
)
```

## Message Types

All adapters normalize messages into `BeamAgent.message()`:

| Type | Key Fields |
|------|-----------|
| `:text` | `content` |
| `:assistant` | `content_blocks` |
| `:tool_use` | `tool_name`, `tool_input` |
| `:tool_result` | `tool_name`, `content` |
| `:result` | `content`, `duration_ms`, `total_cost_usd` |
| `:error` | `content` |
| `:thinking` | `content` |
| `:system` | `content`, `subtype`, `system_info` |

## Requirements

- Elixir ~> 1.17
- Erlang/OTP 27+
- Optional: `{:telemetry, "~> 1.3"}` for instrumentation (see [Telemetry](#telemetry))

## Backend Wrappers

`BeamAgent` is the preferred public entrypoint. The adapter-specific wrappers
remain available when you want preset backend configuration or direct access to
backend-native APIs:

- `ClaudeEx`
- `CodexEx`
- `GeminiEx`
- `OpencodeEx`
- `CopilotEx`
