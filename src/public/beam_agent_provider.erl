-module(beam_agent_provider).
-moduledoc """
Public API for provider and agent management.

This module provides operations for managing LLM providers (service
endpoints) and sub-agents within a session. Provider selection determines
which service subsequent queries route through. Agent selection determines
which model identity is used.

Functions that manage ETS-based runtime state delegate directly to
beam_agent_core (universal-only). Functions that may have native backend
implementations use native-first routing.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, ProviderId} = beam_agent_provider:current(Session),
io:format("Provider: ~s~n", [ProviderId]).
```

## See Also

  - beam_agent_runtime: runtime state management
  - beam_agent_config_core: provider auth and OAuth flows
  - beam_agent: lifecycle entry point
""".

-export([
    current/1,
    set/2,
    clear/1,
    list/1,
    auth_methods/1,
    oauth_authorize/3,
    oauth_callback/3,
    current_agent/1,
    set_agent/2,
    clear_agent/1
]).

%%--------------------------------------------------------------------
%% Provider API
%%--------------------------------------------------------------------

-doc "Return the currently active LLM provider for a session.".
-spec current(pid()) -> {ok, binary()} | {error, not_set}.
current(Session) ->
    beam_agent_core:current_provider(Session).

-doc "Set the active LLM provider for a session.".
-spec set(pid(), binary()) -> ok.
set(Session, ProviderId) ->
    beam_agent_core:set_provider(Session, ProviderId).

-doc "Clear the active provider for a session.".
-spec clear(pid()) -> ok.
clear(Session) ->
    beam_agent_core:clear_provider(Session).

-doc "List all available providers for a session.".
-spec list(pid()) -> {ok, [map()]} | {error, term()}.
list(Session) ->
    beam_agent_core:native_or(Session, provider_list, [], fun() ->
        beam_agent_runtime:list_providers(Session)
    end).

-doc "List authentication methods available for the session's providers.".
-spec auth_methods(pid()) -> {ok, term()} | {error, term()}.
auth_methods(Session) ->
    beam_agent_core:native_or(Session, provider_auth_methods, [], fun() ->
        beam_agent_config_core:provider_auth_methods(Session)
    end).

-doc "Initiate an OAuth authorization flow for a specific provider.".
-spec oauth_authorize(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
oauth_authorize(Session, ProviderId, Body) ->
    beam_agent_core:native_or(Session, provider_oauth_authorize, [ProviderId, Body], fun() ->
        beam_agent_config_core:provider_oauth_authorize(Session, ProviderId, Body)
    end).

-doc "Handle an OAuth callback after user authorization.".
-spec oauth_callback(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
oauth_callback(Session, ProviderId, Body) ->
    beam_agent_core:native_or(Session, provider_oauth_callback, [ProviderId, Body], fun() ->
        beam_agent_config_core:provider_oauth_callback(Session, ProviderId, Body)
    end).

%%--------------------------------------------------------------------
%% Agent API
%%--------------------------------------------------------------------

-doc "Return the currently active sub-agent for a session.".
-spec current_agent(pid()) -> {ok, binary()} | {error, not_set}.
current_agent(Session) ->
    beam_agent_core:current_agent(Session).

-doc "Set the active sub-agent for a session.".
-spec set_agent(pid(), binary()) -> ok.
set_agent(Session, AgentId) ->
    beam_agent_core:set_agent(Session, AgentId).

-doc "Clear the active sub-agent for a session.".
-spec clear_agent(pid()) -> ok.
clear_agent(Session) ->
    beam_agent_core:clear_agent(Session).
