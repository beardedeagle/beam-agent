-module(beam_agent_slash_commands).
-moduledoc """
Public API for global slash command management.

This module delegates to `beam_agent_slash_registry` for all operations.
Slash commands are registered globally and shared across all sessions.
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

-doc "Create the global slash commands ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() -> beam_agent_slash_registry:ensure_table().

-doc "Register a slash command globally.".
-spec register(binary(), map()) -> ok.
register(Id, Opts) -> beam_agent_slash_registry:register(Id, Opts).

-doc "Unregister a slash command by id. Idempotent.".
-spec unregister(binary()) -> ok.
unregister(Id) -> beam_agent_slash_registry:unregister(Id).

-doc "Fetch a single slash command by id.".
-spec get(binary()) ->
    {ok, beam_agent_slash_registry:command_def()} | {error, not_found}.
get(Id) -> beam_agent_slash_registry:get(Id).

-doc "List all registered slash commands.".
-spec list() -> [beam_agent_slash_registry:command_def()].
list() -> beam_agent_slash_registry:list().

-doc "Remove all registered slash commands.".
-spec clear() -> ok.
clear() -> beam_agent_slash_registry:clear().
