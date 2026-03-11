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
| `BeamAgent.Runtime` | Shared provider and default-agent runtime state |
| `BeamAgent.Catalog` | Shared tools/skills/plugins/agents accessors |
| `BeamAgent.Capabilities` | Support-level / implementation / fidelity introspection |
| `BeamAgent.Raw` | Explicit backend-native escape hatch |
| `BeamAgent.MCP` | MCP 2025-06-18 protocol, server/client dispatch, tool registry, and transports |
| `BeamAgent.Hooks` | SDK lifecycle hooks (pre/post tool use, stop, etc.) |
| `BeamAgent.Content` | Content block / flat message conversion |
| `BeamAgent.Telemetry` | Telemetry event helpers |
| `BeamAgent.SessionStore` | Universal session history, fork, revert, share, summarize |
| `BeamAgent.Threads` | Universal thread start/resume/read/archive/rollback |
| `BeamAgent.Todo` | Todo extraction and summary helpers |
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
    _ -> :ok
  end
end)
```

### Telemetry

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
- `telemetry` ~> 1.3 (transitive via `beam_agent`)

## Backend Wrappers

`BeamAgent` is the preferred public entrypoint. The adapter-specific wrappers
remain available when you want preset backend configuration or direct access to
backend-native APIs:

- `ClaudeEx`
- `CodexEx`
- `GeminiEx`
- `OpencodeEx`
- `CopilotEx`
