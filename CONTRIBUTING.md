# Contributing to BEAM Agent

Thanks for your interest in contributing to BEAM Agent! This guide covers
everything you need to get a development environment running, understand the
codebase layout, and submit changes.

## Prerequisites

| Tool | Minimum Version | Notes |
|------|-----------------|-------|
| Erlang/OTP | 27+ | OTP 28 recommended |
| Elixir | 1.17+ | Only needed for the `beam_agent_ex` wrapper |
| rebar3 | 3.23+ | Erlang build tool |
| Mix | ships with Elixir | Elixir build tool |

No external runtime dependencies are required — the SDK uses only OTP standard
libraries. Test dependencies (`proper`) and dev tools (`rebar3_hex`,
`rebar3_ex_doc`, `dialyxir`) are fetched automatically.

## Development Setup

```bash
# Clone the repo
git clone https://github.com/beardedeagle/beam-agent.git
cd beam-agent

# Build and verify the Erlang SDK
rebar3 compile
rebar3 eunit
rebar3 dialyzer

# Build and verify the Elixir wrapper
cd beam_agent_ex
mix deps.get
mix test
```

There is also a convenience alias that runs all checks in sequence:

```bash
rebar3 check    # compile + dialyzer + eunit + ct
```

## Project Layout

```
beam-agent/
  src/
    public/             Canonical public API modules (beam_agent, beam_agent_raw, etc.)
    core/               Shared runtime, routing, control, hooks, MCP, codecs
    transports/         Reusable transport modules (HTTP/SSE, stdio, WebSocket)
    backends/
      claude/           Claude Code adapter
      codex/            Codex CLI adapter
      copilot/          GitHub Copilot adapter
      gemini/           Gemini CLI adapter
      opencode/         OpenCode adapter
  test/
    public/             Public API surface tests
    core/               Core module tests (including PropEr property tests)
    backends/           Backend-specific tests (unit + property)
    contract/           Cross-cutting contract tests
    conformance/        Backend conformance tests
  beam_agent_ex/
    lib/                Elixir wrapper modules
    test/               Elixir wrapper tests
  docs/
    guides/             User-facing guides (backend integration, etc.)
```

### Key architectural layers

1. **Public API** (`src/public/`) — The user-facing surface. `beam_agent.erl` is
   the canonical Erlang entry point; `beam_agent_raw.erl` provides escape hatches.
2. **Core** (`src/core/`) — Shared logic used by all backends: session engine,
   hooks, MCP protocol, codecs (JSONL, JSON-RPC, WebSocket frames), ETS stores.
3. **Transports** (`src/transports/`) — Byte-level I/O: HTTP/SSE, stdio with
   JSON lines, stdio with JSON-RPC, WebSocket.
4. **Backends** (`src/backends/`) — Each backend implements
   `beam_agent_session_handler` callbacks. Handlers focus on wire-protocol
   differences; the shared engine handles lifecycle, queuing, and telemetry.

## Running Tests

### Erlang

```bash
rebar3 eunit                          # Run all EUnit tests (includes PropEr)
rebar3 eunit --module=beam_agent_tests  # Run a specific test module
rebar3 eunit --verbose                # Verbose output
```

### Elixir

```bash
cd beam_agent_ex
mix test                              # Run all ExUnit tests
mix test test/canonical/              # Run only canonical wrapper tests
```

### Static Analysis

```bash
rebar3 dialyzer                       # Erlang — zero warnings expected
cd beam_agent_ex && mix dialyzer      # Elixir (via Dialyxir)
```

The Erlang build uses `warnings_as_errors` and `warn_missing_spec` — all
exported functions require typespecs and any compiler warning fails the build.

## Writing Tests

### Unit tests

Place tests alongside their source layer:

- `test/public/` for public API tests
- `test/core/` for core module tests
- `test/backends/<name>/` for backend-specific tests

Test modules follow the naming convention `<module>_tests.erl`.

### Property-based tests

We use [PropEr](https://proper-testing.github.io/) for fuzz testing codecs,
stores, and protocol modules. Property test modules are named
`prop_<module>.erl` and live in the same test directory as the module they cover.

Each property runs 200 test cases via EUnit integration:

```erlang
my_property_test() ->
    ?assert(proper:quickcheck(prop_my_property(),
        [{numtests, 200}, {to_file, user}])).
```

When writing generators for JSON-related tests, use UTF-8 safe binaries (ASCII
range 32–126) rather than arbitrary `binary()` — JSON requires valid UTF-8.

## Compiler and Dialyzer Standards

- **Zero compiler warnings** — `warnings_as_errors` is enabled.
- **All exports have typespecs** — `warn_missing_spec` is enabled.
- **Zero dialyzer warnings** — the CI target is clean dialyzer output.

If you add or change an exported function, add or update its `-spec`.

## Submitting Changes

1. **Fork and branch** — Create a feature branch from `main`:
   ```bash
   git checkout -b feat/my-feature main
   ```

2. **Make your changes** — Follow the existing code style (see below).

3. **Verify locally** — All four checks must pass before submitting:
   ```bash
   rebar3 compile
   rebar3 eunit
   rebar3 dialyzer
   cd beam_agent_ex && mix test
   ```

4. **Commit** — Write a concise commit message that explains *why*, not just
   *what*. Use imperative mood ("Add X" not "Added X").

5. **Open a PR** — Target `main`. Include a summary of what changed and a test
   plan.

## Code Style

- Follow existing patterns in the file you're editing.
- Use `snake_case` for functions and variables in both Erlang and Elixir.
- Module-level `@doc` / `%%% @doc` documentation for all public modules.
- Keep lines under 90 characters where practical.
- Erlang formatting: standard OTP style. No auto-formatter is enforced, but
  match the surrounding code.
- Elixir formatting: `mix format` is the standard. Run it before committing
  Elixir changes.

## Adding a New Backend

To add a sixth backend:

1. Create a new directory under `src/backends/<name>/`.
2. Implement the `beam_agent_session_handler` behaviour — see the moduledoc in
   `src/core/beam_agent_session_handler.erl` for the callback reference.
3. Add the backend's test directory under `test/backends/<name>/`.
4. Register the backend atom in `beam_agent_capabilities.erl`.
5. Add an Elixir wrapper module in `beam_agent_ex/lib/` if needed.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
