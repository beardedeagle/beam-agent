-module(beam_agent_routing).
-moduledoc """
Public API for canonical BeamAgent backend routing.

Routing lets consumers ask BeamAgent to choose a backend according to reusable
policy instead of hard-coding one every time. The implementation is process-free
and backed by the canonical store abstraction.

Supported routing policies in this slice are:

  - `explicit`
  - `sticky`
  - `round_robin`
  - `failover`
  - `capability_first`
  - `preferred_then_fallback`

Routing decisions can use session identity, explicit exclusions, health
overrides, preferred backend order, and capability requirements. Sticky and
round-robin state are durable BeamAgent state, not hidden scheduler state.

## Quick example

```erlang
{ok, Decision} = beam_agent_routing:select_backend(#{
    policy => preferred_then_fallback,
    preferred_backends => [gemini, codex],
    excluded_backends => [copilot]
}),
Backend = maps:get(backend, Decision).
```
""".

-export([
    ensure_tables/0,
    clear/0,
    select_backend/1,
    select_backend/2
]).

-export_type([
    route_policy/0,
    fallback_policy/0,
    health_status/0,
    route_request/0,
    route_decision/0
]).

-type route_policy() :: beam_agent_routing_core:route_policy().
-type fallback_policy() :: beam_agent_routing_core:fallback_policy().
-type health_status() :: beam_agent_routing_core:health_status().
-type route_request() :: beam_agent_routing_core:route_request().
-type route_decision() :: beam_agent_routing_core:route_decision().

-doc "Ensure routing state tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_routing_core:ensure_tables().

-doc "Clear sticky affinity and round-robin routing state.".
-spec clear() -> ok.
clear() ->
    beam_agent_routing_core:clear().

-doc "Select a backend using a normalized routing request.".
-spec select_backend(route_request()) ->
    {ok, route_decision()} | {error, term()}.
select_backend(RouteRequest) ->
    beam_agent_routing_core:select_backend(RouteRequest).

-doc """
Select a backend after deriving defaults from a session identity or session opts.
""".
-spec select_backend(pid() | binary() | map(), route_request()) ->
    {ok, route_decision()} | {error, term()}.
select_backend(SessionOrOpts, RouteRequest) ->
    beam_agent_routing_core:select_backend(SessionOrOpts, RouteRequest).
