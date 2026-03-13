defmodule BeamAgent.Account do
  @moduledoc """
  Account management for the BeamAgent SDK.

  This module provides account lifecycle operations -- login, logout, rate limits,
  and account information retrieval -- across all five agentic coder backends
  (Claude, Codex, Gemini, OpenCode, Copilot).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with accounts through `BeamAgent`. Use this module
  directly when you need focused access to account operations -- for example,
  in a login flow UI, an account dashboard, or a rate-limit monitor that polls
  account state independently of query operations.

  ## Quick example

  ```elixir
  # Check account info:
  {:ok, info} = BeamAgent.Account.info(session)
  IO.puts("Plan: \#{info.plan}, Email: \#{info.email}")

  # Login with credentials:
  {:ok, _} = BeamAgent.Account.login(session, %{api_key: "sk-..."})

  # Check rate limits:
  {:ok, limits} = BeamAgent.Account.rate_limits(session)

  # Logout:
  {:ok, _} = BeamAgent.Account.logout(session)
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_account` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying account data is stored in ETS tables managed by
  `:beam_agent_account_core`.

  See also: `BeamAgent`, `BeamAgent.Runtime`, `BeamAgent.Provider`.
  """

  @doc """
  Retrieve account and authentication information for the session's backend.

  Returns details about the authenticated user including identity,
  subscription plan, usage quotas, and the authentication method in use.
  Useful for displaying account dashboards, checking remaining quota
  before expensive operations, or verifying that credentials are valid.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, info_map}` where `info_map` contains `:account_id` (binary),
    `:email` (binary), `:plan` (binary plan name), `:usage` (map with
    quota/consumption data), and `:auth_method` (atom such as `:api_key`
    or `:oauth`).
  - `{:error, reason}` on failure.

  ## Examples

      {:ok, info} = BeamAgent.Account.info(session)
      IO.puts("Plan: \#{info.plan}, Email: \#{info.email}")
  """
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  defdelegate info(session), to: :beam_agent_account

  @doc """
  Initiate an account login flow.

  `opts` contains credentials or OAuth tokens required by the backend's
  authentication provider. The exact keys depend on the provider (e.g.,
  `:api_key`, `:access_token`, `:email`).

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- credentials/OAuth parameters map.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec login(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate login(session, opts), to: :beam_agent_account

  @doc """
  Cancel an in-progress account login flow.

  Aborts a login that was started with `login/2` but has not yet
  completed (e.g., waiting for OAuth redirect).

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- should match the original login parameters.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec cancel(pid(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate cancel(session, opts), to: :beam_agent_account

  @doc """
  Log out of the current account.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec logout(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate logout(session), to: :beam_agent_account

  @doc """
  Get rate limit information for the current account.

  Falls back to `info/1` for backends without native
  rate limit reporting.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, rate_limit_info}` or `{:error, reason}`.
  """
  @spec rate_limits(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate rate_limits(session), to: :beam_agent_account
end
