-module(beam_agent_plugins).
-moduledoc """
Public API for global plugin management.

This module delegates to `beam_agent_plugin_registry` for all operations.
Plugins are registered globally and shared across all sessions. Mutations
notify the reload bus so live sessions react without restart.

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

-doc "Create the global plugins ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() -> beam_agent_plugin_registry:ensure_table().

-doc "Register a plugin globally.".
-spec register(binary(), map()) -> ok.
register(Id, Opts) -> beam_agent_plugin_registry:register(Id, Opts).

-doc "Unregister a plugin by id. Idempotent.".
-spec unregister(binary()) -> ok.
unregister(Id) -> beam_agent_plugin_registry:unregister(Id).

-doc "Fetch a single plugin by id.".
-spec get(binary()) ->
    {ok, beam_agent_plugin_registry:plugin_def()} | {error, not_found}.
get(Id) -> beam_agent_plugin_registry:get(Id).

-doc "List all registered plugins.".
-spec list() -> [beam_agent_plugin_registry:plugin_def()].
list() -> beam_agent_plugin_registry:list().

-doc "Remove all registered plugins.".
-spec clear() -> ok.
clear() -> beam_agent_plugin_registry:clear().
