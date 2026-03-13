defmodule BeamAgent.Provider do
  @moduledoc """
  Provider and agent management for the BeamAgent SDK.

  This module provides LLM provider operations -- selecting active providers,
  managing sub-agents, listing available providers, querying authentication
  methods, and handling OAuth flows -- across all five agentic coder backends
  (Claude, Codex, Gemini, OpenCode, Copilot).

  Providers represent authentication and API endpoints for LLM services (e.g.,
  Anthropic, OpenAI, Google). Sub-agents are specialized agents that handle
  delegated work like code review or test generation.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with providers through `BeamAgent`. Use this module
  directly when you need focused access to provider operations -- for example,
  in a provider switching UI, an OAuth login flow, or a multi-provider routing
  layer that selects providers per query.

  ## Quick example

  ```elixir
  # List available providers:
  {:ok, providers} = BeamAgent.Provider.list(session)

  # Set active provider:
  :ok = BeamAgent.Provider.set(session, "anthropic")

  # Check current provider:
  {:ok, provider_id} = BeamAgent.Provider.current(session)

  # Set a sub-agent:
  :ok = BeamAgent.Provider.set_agent(session, "code-reviewer")

  # Start OAuth flow:
  {:ok, result} = BeamAgent.Provider.oauth_authorize(session, "anthropic", %{
    redirect_uri: "http://localhost:3000/callback"
  })
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_provider` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation.

  See also: `BeamAgent`, `BeamAgent.Account`, `BeamAgent.Config`.
  """

  @doc """
  Get the currently active LLM provider for a session.

  Providers represent authentication and API endpoints for LLM services
  (e.g., Anthropic, OpenAI, Google). This is most relevant for backends
  like OpenCode that support routing queries to different LLM providers.
  If no provider has been explicitly set, returns `{:error, :not_set}`
  indicating the backend's default provider is in use.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, provider_id}` where `provider_id` is a binary (e.g.,
    `"anthropic"`, `"openai"`).
  - `{:error, :not_set}` if no provider has been explicitly selected.
  """
  @spec current(pid()) :: {:ok, binary()} | {:error, :not_set}
  defdelegate current(session), to: :beam_agent_provider

  @doc """
  Set the active LLM provider for a session.

  Changes which LLM service endpoint handles subsequent queries. Use
  `list/1` to discover available providers before calling this.
  The change takes effect immediately for the next query.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`,
    `"openai"`, `"google"`).

  ## Returns

  `:ok`

  ## Examples

      :ok = BeamAgent.Provider.set(session, "anthropic")
  """
  @spec set(pid(), binary()) :: :ok
  defdelegate set(session, provider_id), to: :beam_agent_provider

  @doc """
  Clear the active provider selection and revert to the backend's default.

  Undoes a previous `set/2` call so the session uses the
  backend's default LLM provider for subsequent queries.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  `:ok`
  """
  @spec clear(pid()) :: :ok
  defdelegate clear(session), to: :beam_agent_provider

  @doc """
  Get the currently active sub-agent for a session.

  Returns the identifier of the sub-agent that is currently handling
  delegated work. When no sub-agent has been explicitly activated via
  `set_agent/2`, this returns `{:error, :not_set}`, meaning the primary
  agent handles all queries directly.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, agent_id}` where `agent_id` is a binary sub-agent identifier.
  - `{:error, :not_set}` if no sub-agent is active (primary agent in use).
  """
  @spec current_agent(pid()) :: {:ok, binary()} | {:error, :not_set}
  defdelegate current_agent(session), to: :beam_agent_provider

  @doc """
  Set the active sub-agent for a session.

  Activates a sub-agent so that subsequent queries are routed through it
  instead of the primary agent. Sub-agents specialize in tasks like code
  review or test generation. Use `supported_agents/1` or `list_agents/1`
  to discover valid identifiers before calling this.

  ## Parameters

  - `session` -- pid of a running session.
  - `agent_id` -- binary sub-agent identifier.

  ## Returns

  `:ok`

  ## Examples

      :ok = BeamAgent.Provider.set_agent(session, "code-reviewer")
  """
  @spec set_agent(pid(), binary()) :: :ok
  defdelegate set_agent(session, agent_id), to: :beam_agent_provider

  @doc """
  Clear the active sub-agent and revert to the primary agent.

  Undoes a previous `set_agent/2` call so that subsequent queries are
  handled directly by the primary agent rather than a sub-agent.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  `:ok`
  """
  @spec clear_agent(pid()) :: :ok
  defdelegate clear_agent(session), to: :beam_agent_provider

  @doc """
  List all available LLM providers for the session.

  Providers represent authentication and API endpoints for different LLM
  services (e.g., Anthropic, OpenAI, Google). Use this to discover which
  providers are configured and available for routing queries via
  `set/2`. Uses native-first routing with a universal fallback.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, providers}` where `providers` is a list of provider maps, each
    containing `:id` (binary provider identifier), `:name` (human-readable
    display name), and `:status` (atom such as `:available` or
    `:unconfigured`).
  - `{:error, reason}` on failure.
  """
  @spec list(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session), to: :beam_agent_provider

  @doc """
  List authentication methods available for each provider.

  Returns the supported authentication mechanisms (API key, OAuth, SSO)
  for all configured providers. Use this to determine which login flow
  to present to the user, or to check whether OAuth is available before
  calling `oauth_authorize/3`.

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, auth_methods}` where `auth_methods` is a list of maps, each
    containing a `:provider_id` (binary) and `:methods` (list of method
    atoms such as `:api_key`, `:oauth`, or `:sso`).
  - `{:error, reason}` on failure.
  """
  @spec auth_methods(pid()) :: {:ok, [map()]} | {:error, term()}
  defdelegate auth_methods(session), to: :beam_agent_provider

  @doc """
  Initiate an OAuth authorization flow for a specific provider.

  Starts the OAuth handshake by generating an authorization URL that the
  user should visit to grant access. After the user authorizes, the
  provider redirects to the specified URI with an authorization code that
  should be passed to `oauth_callback/3` to complete the flow.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`).
  - `body` -- OAuth parameters map. Supported keys:
    - `:redirect_uri` -- binary callback URL for the OAuth redirect
    - `:scope` -- binary or list of OAuth scopes to request

  ## Returns

  - `{:ok, result_map}` where `result_map` contains `:authorization_url`
    (binary URL the user should visit to authorize).
  - `{:error, reason}` on failure.
  """
  @spec oauth_authorize(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate oauth_authorize(session, provider_id, body), to: :beam_agent_provider

  @doc """
  Handle an OAuth callback to complete the authorization flow.

  Exchanges the authorization code received from the OAuth redirect for
  an access token. This is the second step of the OAuth flow started by
  `oauth_authorize/3`. On success, the session is authenticated
  with the provider and ready to route queries.

  ## Parameters

  - `session` -- pid of a running session.
  - `provider_id` -- binary provider identifier (e.g., `"anthropic"`).
  - `body` -- OAuth callback parameters map. Required keys:
    - `:code` -- binary authorization code from the OAuth redirect
    - `:state` -- binary state parameter for CSRF verification

  ## Returns

  - `{:ok, result_map}` where `result_map` contains token information
    such as `:access_token`, `:token_type`, and `:expires_in`.
  - `{:error, reason}` on failure (e.g., invalid code or state mismatch).
  """
  @spec oauth_callback(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate oauth_callback(session, provider_id, body), to: :beam_agent_provider
end
