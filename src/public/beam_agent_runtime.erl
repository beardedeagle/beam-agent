-module(beam_agent_runtime).
-moduledoc """
Runtime state management for providers and agents.

This module is the public API for the BeamAgent runtime layer. It manages
per-session provider selection, provider configuration, default agent
selection, and query option merging. All state is ETS-backed, keyed by
session pid or session ID binary, and persists for the node lifetime or
until explicitly cleared.

The runtime layer is backend-agnostic. It stores canonical defaults that
can be merged into future requests regardless of which backend transport
is active.

## Getting Started

```erlang
%% 1. Ensure the runtime ETS table exists (idempotent)
beam_agent_runtime:ensure_tables(),

%% 2. Prime runtime state from session options
beam_agent_runtime:register_session(Session, #{
    provider_id => <<"anthropic">>,
    agent => <<"claude-sonnet-4-6">>
}),

%% 3. Query and modify provider selection
{ok, <<"anthropic">>} = beam_agent_runtime:current_provider(Session),
ok = beam_agent_runtime:set_provider(Session, <<"openai">>),

%% 4. Merge runtime defaults into query params
Params = beam_agent_runtime:merge_query_opts(Session, #{prompt => <<"Hello">>}).
```

## Key Concepts

  - Providers: API key sources that supply model access. Each provider has
    an ID (e.g., <<"anthropic">>, <<"openai">>, <<"google">>), authentication
    methods, capabilities, and configuration keys. The runtime maintains a
    built-in provider catalog for well-known providers.

  - Agents: AI model identities used for queries. The runtime tracks the
    currently selected default agent per session and merges it into query
    options automatically.

  - Session State: An ETS-backed map per session holding provider_id,
    provider config, model_id, agent, mode, system prompt, and tools.
    State is primed at session registration time from the session opts and
    can be updated incrementally.

  - Query Merging: The merge_query_opts/2 function combines stored runtime
    defaults with explicit query params. Explicit params always win; nested
    provider config maps are merged shallowly.

## Architecture

```
beam_agent_runtime (public API)
        |
        v
beam_agent_runtime_core (ETS state, provider catalog, inference)
        |
        +-- beam_agent_raw_core (native provider list for OpenCode)
        +-- beam_agent_backend (backend detection)
        +-- gen_statem:call (session_info for inference)
```

## Core concepts

Runtime state tracks what model, provider, and agent a session is
currently using. Think of it as the session's "settings panel" -- you
can switch models or providers mid-session without restarting.

A provider is an API endpoint that supplies model access (e.g.,
Anthropic, OpenAI, Google). An agent is the specific AI model identity
used for queries. The runtime merges these defaults into every query
so you do not have to specify them each time.

Use current_provider/1 and set_provider/2 to check and change the
active provider. Use current_agent/1 and set_agent/2 for models.
merge_query_opts/2 combines stored defaults with explicit query params.

## Architecture deep dive

Runtime state is ETS-backed via beam_agent_runtime_core, keyed by
session pid or session ID binary. The ETS table stores a map per
session holding provider_id, provider config, model_id, agent, mode,
system prompt, and tools.

Provider and agent switching updates ETS state only -- it does not
restart the transport or renegotiate with the backend. Model switching
may require backend-specific negotiation depending on the adapter.

merge_query_opts/2 performs shallow map merging: explicit params win
over stored defaults, and nested provider config maps are merged one
level deep. The built-in provider catalog is compiled-in static data.

## See Also

  - `beam_agent` -- Main SDK entry point
  - `beam_agent_catalog` -- Tool, skill, and agent catalog accessors
  - `beam_agent_control` -- Session configuration and permissions
  - `beam_agent_runtime_core` -- Core implementation (internal)
""".

-export([
    ensure_tables/0,
    clear/0,
    register_session/2,
    clear_session/1,
    get_state/1,
    current_provider/1,
    set_provider/2,
    clear_provider/1,
    get_provider_config/1,
    set_provider_config/2,
    current_agent/1,
    set_agent/2,
    clear_agent/1,
    list_providers/1,
    provider_status/1,
    provider_status/2,
    validate_provider_config/2,
    merge_query_opts/2,
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    send_control/3,
    get_status/1,
    get_auth_status/1,
    get_last_session_id/1,
    windows_sandbox_setup_start/2,
    set_max_thinking_tokens/2,
    stop_task/2
]).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the runtime ETS table exists.

Creates the runtime state table if it does not already exist.
This function is idempotent.
""".
-spec ensure_tables() -> ok.
ensure_tables() -> beam_agent_runtime_core:ensure_tables().

-doc """
Clear all runtime state across every session.

Deletes all objects from the runtime ETS table. Use this for
test cleanup or node-wide reset.
""".
-spec clear() -> ok.
clear() -> beam_agent_runtime_core:clear().

%%--------------------------------------------------------------------
%% Session Lifecycle
%%--------------------------------------------------------------------

-doc """
Prime runtime state from session options.

Extracts canonical runtime keys (provider_id, provider, model_id,
agent, mode, system, tools) from the options map and persists them
in ETS. Keys with undefined or null values are filtered out.

This is typically called once during session initialization.

Example:

```erlang
ok = beam_agent_runtime:register_session(Session, #{
    provider_id => <<"anthropic">>,
    agent => <<"claude-sonnet-4-6">>,
    mode => <<"code">>
}).
```
""".
-spec register_session(pid() | binary(), map()) -> ok.
register_session(Session, Opts) -> beam_agent_runtime_core:register_session(Session, Opts).

-doc """
Delete all runtime state for a session.

Removes the session's entry from the runtime ETS table entirely.
""".
-spec clear_session(pid() | binary()) -> ok.
clear_session(Session) -> beam_agent_runtime_core:clear_session(Session).

-doc """
Read the current runtime state map for a session.

Returns the full state map, or an empty map if no state has been
registered. Always returns {ok, Map}.
""".
-spec get_state(pid() | binary()) -> {ok, beam_agent_runtime_core:runtime_state()}.
get_state(Session) -> beam_agent_runtime_core:get_state(Session).

%%--------------------------------------------------------------------
%% Provider Management
%%--------------------------------------------------------------------

-doc """
Return the currently selected provider for a session.

Checks the runtime state first. If no provider is explicitly set,
attempts to infer the provider from the session's backend metadata.
Returns {error, not_set} when the provider cannot be determined.
""".
-spec current_provider(pid() | binary()) -> {ok, binary()} | {error, not_set}.
current_provider(Session) -> beam_agent_runtime_core:current_provider(Session).

-doc """
Set the default provider for future queries on a session.

Stores the provider ID in the runtime state. The provider ID must
be a non-empty binary.

Example:

```erlang
ok = beam_agent_runtime:set_provider(Session, <<"anthropic">>),
{ok, <<"anthropic">>} = beam_agent_runtime:current_provider(Session).
```
""".
-spec set_provider(pid() | binary(), binary()) -> ok.
set_provider(Session, ProviderId) -> beam_agent_runtime_core:set_provider(Session, ProviderId).

-doc """
Clear any default provider selection for a session.

Removes both the provider_id and provider config from the runtime
state. After clearing, current_provider/1 will attempt inference
from session metadata.
""".
-spec clear_provider(pid() | binary()) -> ok.
clear_provider(Session) -> beam_agent_runtime_core:clear_provider(Session).

-doc """
Read the provider configuration map for a session.

Returns the structured provider config (API keys, base URLs, etc.)
associated with the session. Returns an empty map when no config
is stored.
""".
-spec get_provider_config(pid() | binary()) -> {ok, map()}.
get_provider_config(Session) -> beam_agent_runtime_core:get_provider_config(Session).

-doc """
Set provider configuration for future queries on a session.

Stores a structured provider config map and attempts to infer the
provider ID from the config. If the provider ID cannot be inferred,
the config is validated before storage.

Returns {error, invalid_api_key} if the config contains a
malformed API key.
""".
-spec set_provider_config(pid() | binary(), map()) ->
    ok | {error, invalid_api_key | invalid_provider_config}.
set_provider_config(Session, Config) -> beam_agent_runtime_core:set_provider_config(Session, Config).

%%--------------------------------------------------------------------
%% Agent Management
%%--------------------------------------------------------------------

-doc """
Return the currently selected default agent for a session.

Checks the runtime state first. If no agent is explicitly set,
attempts to infer the agent from the session's backend metadata.
Returns {error, not_set} when the agent cannot be determined.

Example:

```erlang
{ok, <<"claude-sonnet-4-6">>} = beam_agent_runtime:current_agent(Session).
```
""".
-spec current_agent(pid() | binary()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) -> beam_agent_runtime_core:current_agent(Session).

-doc """
Set the default agent for future queries on a session.

The agent ID is stored in the runtime state and merged into
future query options via merge_query_opts/2.
""".
-spec set_agent(pid() | binary(), binary()) -> ok.
set_agent(Session, AgentId) -> beam_agent_runtime_core:set_agent(Session, AgentId).

-doc """
Clear any default agent selection for a session.

After clearing, current_agent/1 will attempt inference from
session metadata.
""".
-spec clear_agent(pid() | binary()) -> ok.
clear_agent(Session) -> beam_agent_runtime_core:clear_agent(Session).

%%--------------------------------------------------------------------
%% Provider Listing and Status
%%--------------------------------------------------------------------

-doc """
List providers visible through the unified runtime layer.

Prefers native provider listings when the backend exposes them
(e.g., OpenCode's provider_list). Falls back to a best-effort
catalog derived from the built-in provider registry and current
runtime state.
""".
-spec list_providers(pid() | binary()) -> {ok, [map()]}.
list_providers(Session) -> beam_agent_runtime_core:list_providers(Session).

-doc """
Return high-level provider status for the session's current provider.

If a provider is selected, returns its detailed status via
provider_status/2. If no provider is set, returns a summary with
provider_id set to undefined and whether any config exists.
""".
-spec provider_status(pid() | binary()) ->
    {ok, #{provider_id := undefined | binary(), _ => _}}.
provider_status(Session) -> beam_agent_runtime_core:provider_status(Session).

-doc """
Return status for a specific provider by ID.

When the backend exposes native provider/admin endpoints, the
result includes their payload. Otherwise, returns a normalized
best-effort summary including configured state, authentication
methods, capabilities, config keys, and whether the provider is
the current selection.
""".
-spec provider_status(pid() | binary(), binary()) ->
    {ok, #{provider_id := binary(), _ => _}}.
provider_status(Session, ProviderId) -> beam_agent_runtime_core:provider_status(Session, ProviderId).

%%--------------------------------------------------------------------
%% Validation and Merging
%%--------------------------------------------------------------------

-doc """
Validate a provider configuration map.

Performs conservative validation: checks shape and obvious type
errors without overfitting to a single backend's schema. Currently
validates that any api_key present is a non-empty binary.

Returns ok for valid configs, or {error, Reason} for invalid ones.

Example:

```erlang
ok = beam_agent_runtime:validate_provider_config(
    <<"anthropic">>, #{api_key => <<"sk-ant-...">>}),

{error, invalid_api_key} = beam_agent_runtime:validate_provider_config(
    <<"anthropic">>, #{api_key => <<>>}).
```
""".
-spec validate_provider_config(binary() | undefined, map()) ->
    ok | {error, invalid_api_key | invalid_provider_config}.
validate_provider_config(ProviderId, Config) ->
    beam_agent_runtime_core:validate_provider_config(ProviderId, Config).

-doc """
Merge runtime defaults into query parameters.

Combines stored runtime state (provider_id, provider, model_id,
agent, mode, system, tools) with the explicit query params.
Explicit params always take precedence. Nested provider config maps
are merged shallowly (explicit keys override stored keys).

This function is called internally before every query to ensure
runtime defaults are applied.
""".
-spec merge_query_opts(pid() | binary(), map()) -> map().
merge_query_opts(Session, Params) -> beam_agent_runtime_core:merge_query_opts(Session, Params).

%%--------------------------------------------------------------------
%% Session Control
%%--------------------------------------------------------------------

-doc """
Change the model for a running session.

Sends a set_model control message to the session engine. The backend
handler may process this natively (e.g., sending a protocol message)
or the engine stores it in its own state.

Parameters:
  - Session: pid of a running session.
  - Model: binary model identifier (e.g., <<"claude-sonnet-4-20250514">>).

Returns {ok, Model} on success or {error, Reason}.
""".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) -> beam_agent_core:set_model(Session, Model).

-doc """
Change the permission mode for a running session.

Controls how the backend handles tool execution and file edit approval.

Parameters:
  - Session: pid of a running session.
  - Mode: binary permission mode (e.g., <<"default">>, <<"accept_edits">>).

Returns {ok, Mode} on success or {error, Reason}.
""".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) -> beam_agent_core:set_permission_mode(Session, Mode).

-doc """
Interrupt the currently active query on a session.

Sends an interrupt signal to the backend. If the backend supports
native interrupts (e.g., sending a protocol-level cancel), it uses
that; otherwise falls back to an OS-level signal for port-based
transports.

Parameters:
  - Session: pid of a running session.

Returns ok if the interrupt was sent, or {error, not_supported} if the
backend does not support interrupts, or {error, Reason} on failure.
""".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) -> beam_agent_core:interrupt(Session).

-doc """
Abort the currently active query and reset the session to ready state.

Stronger than interrupt/1: forcibly cancels the query and transitions
the session engine back to the ready state.

Parameters:
  - Session: pid of a running session.

Returns ok or {error, Reason}.
""".
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) -> beam_agent_core:abort(Session).

-doc """
Send a backend-specific control message to a session.

Control messages provide a generic extension point for features not
covered by the typed API. The Method string identifies the operation
and Params carries its arguments. The backend handler processes the
message via its handle_control/4 callback.

Parameters:
  - Session: pid of a running session.
  - Method: binary method name (e.g., <<"mcp_message">>, <<"set_config">>).
  - Params: map of method-specific parameters.

Returns {ok, Result} on success or {error, not_supported} if the
backend does not handle this method, or {error, Reason} on failure.
""".
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    beam_agent_core:send_control(Session, Method, Params).

%%--------------------------------------------------------------------
%% Session Status
%%--------------------------------------------------------------------

-doc """
Return the overall status of a running session.

Assembles a composite status view including session health, connection
state, active backend, and session metadata. Use this for dashboards,
health checks, or debugging connectivity issues.

Tries the backend-native implementation first; falls back to the
universal layer, which assembles a status map from session_info/1
and health/1.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map includes keys such as
status, backend, health, and session_id. Returns {error, Reason}
if the session is unreachable.
""".
-spec get_status(pid()) -> {ok, term()} | {error, term()}.
get_status(Session) ->
    beam_agent_core:native_or(Session, get_status, [], fun() ->
        universal_get_status(Session)
    end).

-doc """
Return the authentication status for a session's provider.

Checks whether the session holds valid credentials for its backend
provider. Use this to verify that API keys or OAuth tokens are still
valid before issuing queries.

Tries the backend-native implementation first; falls back to the
universal layer, which assembles status from account_info/1.

Session is the pid of a running beam_agent session.

Returns {ok, Map} on success, where Map includes whether the session
is authenticated, the authentication method, and token expiration if
applicable. Returns {error, Reason} on failure.
""".
-spec get_auth_status(pid()) -> {ok, term()} | {error, term()}.
get_auth_status(Session) ->
    beam_agent_core:native_or(Session, get_auth_status, [], fun() ->
        universal_get_auth_status(Session)
    end).

-doc """
Return the backend's own session identifier for a running session.

Retrieves the session ID assigned by the backend service, which is
distinct from the Erlang pid. Use this when you need to correlate
BEAM-side state with backend logs, API calls, or external tooling.

Tries the backend-native implementation first; falls back to the
universal layer, which derives the identifier from session_identity/1.

Session is the pid of a running beam_agent session.

Returns {ok, SessionId} where SessionId is typically a binary string,
or {error, Reason} if the identifier cannot be determined.
""".
-spec get_last_session_id(pid()) -> {ok, term()} | {error, term()}.
get_last_session_id(Session) ->
    beam_agent_core:native_or(Session, get_last_session_id, [], fun() ->
        {ok, beam_agent_core:session_identity(Session)}
    end).

%%--------------------------------------------------------------------
%% Extended Backend Controls
%%--------------------------------------------------------------------

-doc """
Start the Windows sandbox setup process.

Initiates sandbox configuration for backends that run in a Windows
environment. On non-Windows platforms the universal fallback returns
status => not_applicable with the current platform architecture.
""".
-spec windows_sandbox_setup_start(pid(), map()) -> {ok, term()} | {error, term()}.
windows_sandbox_setup_start(Session, Opts) ->
    beam_agent_core:native_or(Session, windows_sandbox_setup_start, [Opts], fun() ->
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => not_applicable,
            reason => <<"Windows sandbox not applicable on this platform">>,
            platform => list_to_binary(erlang:system_info(system_architecture))})}
    end).

-doc """
Set the maximum number of thinking tokens for the session.

Controls how many tokens the backend's reasoning model may use for
internal chain-of-thought before producing a visible response. Higher
values allow deeper reasoning at the cost of latency and token usage.
The universal fallback persists this as a configuration value.
""".
-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, term()} | {error, term()}.
set_max_thinking_tokens(Session, MaxTokens) ->
    beam_agent_core:native_or(Session, set_max_thinking_tokens, [MaxTokens], fun() ->
        _ = beam_agent_config_core:config_value_write(
            Session, <<"max_thinking_tokens">>, MaxTokens, #{}),
        {ok, beam_agent_core:with_universal_source(Session, #{
            max_thinking_tokens => MaxTokens})}
    end).

-doc """
Stop a running task by its identifier.

Sends an interrupt to the session and marks the task as stopped.
TaskId identifies the specific task (query or sub-agent invocation)
to cancel. The universal fallback calls interrupt/1 on the session
process.
""".
-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Session, TaskId) ->
    beam_agent_core:native_or(Session, stop_task, [TaskId], fun() ->
        _ = beam_agent_core:interrupt(Session),
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => stopped, task_id => TaskId})}
    end).

%%--------------------------------------------------------------------
%% Private Helpers
%%--------------------------------------------------------------------

-spec universal_get_status(pid()) ->
    {ok, #{'source' := 'universal', _ => _}} | {error, term()}.
universal_get_status(Session) ->
    case beam_agent_core:session_info(Session) of
        {ok, Info} ->
            {ok, beam_agent_core:with_universal_source(Session, Info#{
                health => beam_agent_core:safe_session_health(Session)
            })};
        {error, _} = Error ->
            Error
    end.

-spec universal_get_auth_status(pid()) ->
    {ok, #{'source' := 'universal', _ => _}}.
universal_get_auth_status(Session) ->
    {ok, Status} = beam_agent_runtime_core:provider_status(Session),
    {ok, beam_agent_core:with_universal_source(Session, Status)}.
