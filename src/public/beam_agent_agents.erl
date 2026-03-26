-module(beam_agent_agents).
-moduledoc """
Public API for global agent type management.

This module delegates to `beam_agent_agent_registry` for all operations.
Agent types are registered globally and shared across all sessions.
Mutations notify the reload bus so live sessions react without restart.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.
""".

-export([
    ensure_table/0,
    register/2,
    unregister/1,
    get/1,
    list/0,
    clear/0
]).

-doc "Create the global agent types ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() -> beam_agent_agent_registry:ensure_table().

-doc "Register an agent type globally.".
-spec register(binary(), map()) -> ok.
register(Id, Opts) -> beam_agent_agent_registry:register(Id, Opts).

-doc "Unregister an agent type by id. Idempotent.".
-spec unregister(binary()) -> ok.
unregister(Id) -> beam_agent_agent_registry:unregister(Id).

-doc "Fetch a single agent type by id.".
-spec get(binary()) ->
    {ok, beam_agent_agent_registry:agent_def()} | {error, not_found}.
get(Id) -> beam_agent_agent_registry:get(Id).

-doc "List all registered agent types.".
-spec list() -> [beam_agent_agent_registry:agent_def()].
list() -> beam_agent_agent_registry:list().

-doc "Remove all registered agent types.".
-spec clear() -> ok.
clear() -> beam_agent_agent_registry:clear().
