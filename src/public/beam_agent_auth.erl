-module(beam_agent_auth).
-moduledoc """
Session-independent authentication API for backend CLI tools.

This module provides a unified interface to check, establish, and revoke
credentials for any supported backend **without requiring a running
session**.  It complements the session-bound `beam_agent_runtime` account
operations with real CLI/API authentication.

Supported backends: `claude`, `codex`, `copilot`, `opencode`, `gemini`.

## Quick start

```erlang
%% Check if Claude CLI is authenticated
{ok, #{authenticated := true}} = beam_agent_auth:status(claude).

%% Authenticate Codex with an API key (non-interactive)
{ok, #{outcome := authenticated}} =
    beam_agent_auth:login(codex, #{api_key => <<"sk-...">>}).

%% Log out of Copilot
ok = beam_agent_auth:logout(copilot).
```

## Interactive login flows

Some backends (codex device flow, copilot OAuth) require the user to
complete authentication in a browser.  `login/2` blocks until the flow
completes or the timeout expires (default 5 minutes).  The `raw_output`
field in the result contains any URLs or device codes emitted by the CLI.

## Architecture

```
beam_agent_auth (public — this module)
  └─ beam_agent_auth_core (dispatch + one-shot port runner)
       ├─ claude:   `claude auth status|login|logout`
       ├─ codex:    `codex login status`, `codex login [--with-api-key]`
       ├─ copilot:  `copilot auth status|login|logout`
       ├─ opencode: REST via httpc (localhost-only)
       └─ gemini:   env checks / PTY-interactive OAuth
```
""".

-export([
    status/1,
    status/2,
    login/1,
    login/2,
    login/3,
    logout/1,
    logout/2,
    hash_executable/1,
    from_vault/1,
    sanitize_for_agent/1
]).

-export_type([backend_like/0, vault_env/0]).

%% Accepts anything `beam_agent_backend:normalize/1` accepts.
-type backend_like() :: beam_agent_backend:backend()
                      | atom()
                      | binary()
                      | string().

%% Re-export from core — see `beam_agent_auth_core:vault_env()`.
-type vault_env() :: beam_agent_auth_core:vault_env().

%%====================================================================
%% Status
%%====================================================================

-doc """
Check the current authentication state for a backend.

Equivalent to `status(Backend, #{})`.
""".
-spec status(backend_like()) ->
    {ok, beam_agent_auth_core:auth_status()} | {error, term()}.
status(Backend) ->
    status(Backend, #{}).

-doc """
Check the current authentication state for a backend with options.

Options:
  - `cli_path` — override the CLI binary location
  - `timeout`  — override the default 10 s timeout
  - `base_url` — OpenCode server URL (default `http://localhost:4096`)

```erlang
{ok, #{authenticated := Auth}} = beam_agent_auth:status(claude).
```
""".
-spec status(backend_like(), beam_agent_auth_core:auth_opts()) ->
    {ok, beam_agent_auth_core:auth_status()} | {error, term()}.
status(Backend, Opts) ->
    with_backend(Backend, fun(B) -> beam_agent_auth_core:status(B, Opts) end).

%%====================================================================
%% Login
%%====================================================================

-doc """
Establish credentials for a backend.

Equivalent to `login(Backend, #{})`.
""".
-spec login(backend_like()) ->
    {ok, beam_agent_auth_core:auth_result()} | {error, term()}.
login(Backend) ->
    login(Backend, #{}).

-doc """
Establish credentials for a backend with options.

Options:
  - `api_key`  — authenticate via API key (non-interactive)
  - `cli_path` — override the CLI binary location (basename must match
                  the canonical binary name for the backend)
  - `timeout`  — override the default 5 min timeout

```erlang
%% Non-interactive with API key
{ok, _} = beam_agent_auth:login(codex, #{api_key => <<"sk-...">>}).

%% Interactive device flow (blocks until browser auth completes)
{ok, #{outcome := authenticated}} = beam_agent_auth:login(copilot).
```
""".
-spec login(backend_like(), beam_agent_auth_core:auth_opts()) ->
    {ok, beam_agent_auth_core:auth_result()} | {error, term()}.
login(Backend, Opts) ->
    login(Backend, Opts, from_vault([])).

-doc """
Establish credentials for a backend with Vault-sourced environment.

The `VaultEnv` parameter carries environment variables from a trusted
source (e.g. the MonkeyClaw Vault).  These bypass the internal env-var
allowlist because their provenance is user-configured, not agent-supplied.

This is the privileged API for Vault integration.  The agent's Opts map
has no mechanism to inject environment variables.

```erlang
%% With Vault-sourced env (only from trusted callers)
VaultEnv = beam_agent_auth:from_vault([{"ANTHROPIC_BASE_URL", "https://custom.endpoint"}]),
{ok, _} = beam_agent_auth:login(claude, #{}, VaultEnv).
```
""".
-spec login(backend_like(), beam_agent_auth_core:auth_opts(),
            beam_agent_auth_core:vault_env()) ->
    {ok, beam_agent_auth_core:auth_result()} | {error, term()}.
login(Backend, Opts, VaultEnv) ->
    with_backend(Backend, fun(B) -> beam_agent_auth_core:login(B, Opts, VaultEnv) end).

%%====================================================================
%% Logout
%%====================================================================

-doc """
Revoke or clear credentials for a backend.

Equivalent to `logout(Backend, #{})`.
""".
-spec logout(backend_like()) ->
    ok | {error, timeout | {atom(), term()} | {atom(), term(), term()} |
               {atom(), term(), term(), term()}}.
logout(Backend) ->
    logout(Backend, #{}).

-doc """
Revoke or clear credentials for a backend with options.

Options:
  - `cli_path` — override the CLI binary location
  - `timeout`  — override the default 10 s timeout

```erlang
ok = beam_agent_auth:logout(claude).
```
""".
-spec logout(backend_like(), beam_agent_auth_core:auth_opts()) ->
    ok | {error, term()}.
logout(Backend, Opts) ->
    with_backend(Backend, fun(B) -> beam_agent_auth_core:logout(B, Opts) end).

%%====================================================================
%% Executable integrity
%%====================================================================

-doc """
Compute the SHA-256 hash of an executable.

Returns a binary in the format `<<"sha256:hexdigest">>`.  Useful for
out-of-band integrity verification (startup checks, monitoring,
deployment validation).

```erlang
Hash = beam_agent_auth:hash_executable("claude"),
%% => <<"sha256:a1b2c3d4e5f6...">>
```
""".
-spec hash_executable(string() | binary()) -> <<_:56, _:_*8>>.
hash_executable(Path) ->
    beam_agent_auth_core:hash_executable(Path).

%%====================================================================
%% Vault environment
%%====================================================================

-doc """
Construct an opaque `vault_env()` from a proplist of environment variables.

Only values produced by this function are accepted by `login/3`.
This prevents agent-supplied data from being injected as environment
variables — only Vault-sourced (user-configured) values can flow
through.

```erlang
VaultEnv = beam_agent_auth:from_vault([{"ANTHROPIC_BASE_URL", "https://custom"}]),
{ok, _} = beam_agent_auth:login(claude, #{}, VaultEnv).
```
""".
-spec from_vault([{string(), string()}]) -> vault_env().
from_vault(Vars) ->
    beam_agent_auth_core:from_vault(Vars).

%%====================================================================
%% Agent sanitization
%%====================================================================

-doc """
Strip sensitive fields from an auth status or result before exposing
it to the agent.

Removes `raw_output` (CLI output with OAuth URLs, device codes, or
session tokens), `details` (internal state), and `oauth_url` (extracted
auth URL).  The result retains only the structured fields the agent
needs: `backend`, `authenticated`/`outcome`, `method`, `account`,
`message`.

```erlang
{ok, Status} = beam_agent_auth:status(claude),
Safe = beam_agent_auth:sanitize_for_agent(Status).
```
""".
-spec sanitize_for_agent(map()) -> map().
sanitize_for_agent(Result) ->
    beam_agent_auth_core:sanitize_for_agent(Result).

%%====================================================================
%% Internal
%%====================================================================

-spec with_backend(backend_like(), fun((beam_agent_backend:backend()) -> T)) ->
    T | {error, {unknown_backend, term()}} when T :: term().
with_backend(Backend, Fun) ->
    case beam_agent_backend:normalize(Backend) of
        {ok, B}          -> Fun(B);
        {error, _} = Err -> Err
    end.
