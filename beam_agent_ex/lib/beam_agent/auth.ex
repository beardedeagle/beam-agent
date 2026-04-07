defmodule BeamAgent.Auth do
  @moduledoc """
  Session-independent authentication for backend CLI tools.

  Unlike `BeamAgent.Account`, which manages per-session auth state,
  this module checks, establishes, and revokes **system-wide** credentials
  for backend CLIs.  No running session is required.

  ## When to use

  Use `BeamAgent.Auth` when you need to:

    * Check if a backend is authenticated before starting a session
    * Set up credentials during onboarding or setup flows
    * Manage API keys across backends from a unified UI

  ## Supported backends

  | Backend    | Status check | API key login | Interactive login | Logout |
  |------------|:-------------|:--------------|:------------------|:-------|
  | `:claude`  | `claude auth status` | via env | `claude auth login` | yes |
  | `:codex`   | `codex login status` | via `OPENAI_API_KEY` env | device flow | yes |
  | `:copilot` | `copilot auth status` | n/a | OAuth device flow | yes |
  | `:opencode`| REST `/provider` | REST `/auth` | n/a | REST |
  | `:gemini`  | env / OAuth creds | via env | PTY-interactive OAuth | file delete |

  ## Quick example

      # Check Claude auth status
      {:ok, %{authenticated: true}} = BeamAgent.Auth.status(:claude)

      # Authenticate Codex with an API key
      {:ok, %{outcome: :authenticated}} =
        BeamAgent.Auth.login(:codex, %{api_key: "sk-..."})

      # Log out of Copilot
      :ok = BeamAgent.Auth.logout(:copilot)

  ## Architecture

  This module delegates to `:beam_agent_auth`, which normalizes the
  backend identifier and dispatches to `:beam_agent_auth_core` for
  per-backend CLI invocation or REST calls.
  """

  @type backend :: :claude | :codex | :copilot | :opencode | :gemini | atom() | binary()

  @typedoc "Options for auth operations."
  @type auth_opts :: map()

  @typedoc """
  Auth status returned by `status/1,2`.

  Always contains `:backend` (atom), `:authenticated` (boolean), and
  `:method` (`:cli | :api | :env | :manual | :unknown`).  May also
  contain `:account`, `:details`, and `:raw_output`.
  """
  @type auth_status :: map()

  @typedoc """
  Auth result returned by `login/1,2,3`.

  Always contains `:backend` (atom), `:outcome`
  (`:authenticated | :logged_out | :pending | :failed`), and `:method`.
  May also contain `:message` and `:raw_output`.
  """
  @type auth_result :: map()

  @doc """
  Check the current authentication state for a backend.

  ## Examples

      {:ok, %{authenticated: true}} = BeamAgent.Auth.status(:claude)
      {:ok, %{authenticated: false, details: details}} = BeamAgent.Auth.status(:gemini)
  """
  @spec status(backend()) :: {:ok, auth_status()} | {:error, term()}
  defdelegate status(backend), to: :beam_agent_auth

  @doc """
  Check the current authentication state with options.

  ## Options

    * `:cli_path` — override the CLI binary location
    * `:timeout` — override the default 10s timeout
    * `:base_url` — OpenCode server URL (localhost only, default `http://localhost:4096`)

  ## Examples

      {:ok, status} = BeamAgent.Auth.status(:claude, %{timeout: 5_000})
  """
  @spec status(backend(), auth_opts()) :: {:ok, auth_status()} | {:error, term()}
  defdelegate status(backend, opts), to: :beam_agent_auth

  @doc """
  Establish credentials for a backend.

  ## Examples

      {:ok, _} = BeamAgent.Auth.login(:codex)
      {:ok, _} = BeamAgent.Auth.login(:codex, %{api_key: "sk-..."})
  """
  @spec login(backend()) :: {:ok, auth_result()} | {:error, term()}
  defdelegate login(backend), to: :beam_agent_auth

  @doc """
  Establish credentials for a backend with options.

  ## Options

    * `:api_key` — authenticate with an API key (non-interactive)
    * `:cli_path` — override the CLI binary location (basename must match
      the canonical binary name for the backend)
    * `:timeout` — override the default 5min timeout
    * `:base_url` — override the local OpenCode server base URL (localhost only)

  For backends with device/OAuth flows (codex, copilot), the call blocks
  until the user completes authentication in a browser or the timeout
  expires.  The `:raw_output` field contains any URLs or device codes.
  """
  @spec login(backend(), auth_opts()) :: {:ok, auth_result()} | {:error, term()}
  defdelegate login(backend, opts), to: :beam_agent_auth

  @doc """
  Establish credentials for a backend with Vault-sourced environment.

  The `vault_env` parameter carries environment variables from a trusted
  source (e.g. the MonkeyClaw Vault).  These bypass the internal env-var
  allowlist because their provenance is user-configured, not agent-supplied.

  This is the privileged API for Vault integration.  The agent's opts map
  has no mechanism to inject environment variables.  Only values produced
  by `from_vault/1` are accepted.

  ## Examples

      vault_env = BeamAgent.Auth.from_vault([{"ANTHROPIC_BASE_URL", "https://custom.endpoint"}])
      {:ok, _} = BeamAgent.Auth.login(:claude, %{}, vault_env)
  """
  @spec login(backend(), auth_opts(), :beam_agent_auth_core.vault_env()) ::
          {:ok, auth_result()} | {:error, term()}
  defdelegate login(backend, opts, vault_env), to: :beam_agent_auth

  @doc """
  Revoke or clear credentials for a backend.

  ## Examples

      :ok = BeamAgent.Auth.logout(:claude)
  """
  @spec logout(backend()) :: :ok | {:error, term()}
  defdelegate logout(backend), to: :beam_agent_auth

  @doc """
  Revoke or clear credentials for a backend with options.

  ## Options

    * `:cli_path` — override the CLI binary location
    * `:timeout` — override the default 10s timeout
    * `:base_url` — override the local OpenCode server base URL (localhost only)
  """
  @spec logout(backend(), auth_opts()) :: :ok | {:error, term()}
  defdelegate logout(backend, opts), to: :beam_agent_auth

  @doc """
  Compute the SHA-256 hash of an executable.

  Returns a binary in the format `"sha256:hexdigest"`.  Useful for
  out-of-band integrity verification (startup checks, monitoring,
  deployment validation).

      hash = BeamAgent.Auth.hash_executable("claude")
      # => "sha256:a1b2c3d4e5f6..."
  """
  @spec hash_executable(String.t() | binary()) :: binary()
  defdelegate hash_executable(path), to: :beam_agent_auth

  @doc """
  Construct an opaque `vault_env` from a list of environment variable tuples.

  Only values produced by this function are accepted by `login/3`.
  This prevents agent-supplied data from being injected as environment
  variables — only Vault-sourced (user-configured) values can flow through.

  ## Examples

      vault_env = BeamAgent.Auth.from_vault([{"ANTHROPIC_BASE_URL", "https://custom"}])
      {:ok, _} = BeamAgent.Auth.login(:claude, %{}, vault_env)
  """
  @spec from_vault([{String.t(), String.t()}]) :: :beam_agent_auth_core.vault_env()
  defdelegate from_vault(vars), to: :beam_agent_auth

  @doc """
  Strip sensitive fields from an auth status or result before exposing
  it to the agent.

  Removes `raw_output` (CLI output with OAuth URLs, device codes, or
  session tokens), `details` (internal state), and `oauth_url` (extracted
  auth URL).  The result retains only the structured fields the agent
  needs: `backend`, `authenticated`/`outcome`, `method`, `account`,
  `message`.

  ## Examples

      {:ok, status} = BeamAgent.Auth.status(:claude)
      safe = BeamAgent.Auth.sanitize_for_agent(status)
  """
  @spec sanitize_for_agent(map()) :: map()
  defdelegate sanitize_for_agent(result), to: :beam_agent_auth
end
