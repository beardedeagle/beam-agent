-module(beam_agent_sdk_config).
-moduledoc """
Public API for global SDK configuration.

This module delegates to `beam_agent_global_config` for all operations.
Global config is a shared key-value store for SDK-wide settings that
apply across all sessions. Mutations notify the reload bus so live
sessions react without restart.

This module is distinct from `beam_agent_config`, which manages
per-session backend configuration (model, provider, OAuth).

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.
""".

-export([
    ensure_table/0,
    set/2,
    get/1,
    get/2,
    delete/1,
    list/0,
    clear/0
]).

-doc "Create the global SDK config ETS table. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() -> beam_agent_global_config:ensure_table().

-doc "Set a global config key-value pair.".
-spec set(binary(), term()) -> ok.
set(Key, Value) -> beam_agent_global_config:set(Key, Value).

-doc "Fetch a global config value by key.".
-spec get(binary()) -> {ok, term()} | {error, not_found}.
get(Key) -> beam_agent_global_config:get(Key).

-doc "Fetch a global config value by key, returning a default if not found.".
-spec get(binary(), term()) -> term().
get(Key, Default) -> beam_agent_global_config:get(Key, Default).

-doc "Delete a global config key. Idempotent.".
-spec delete(binary()) -> ok.
delete(Key) -> beam_agent_global_config:delete(Key).

-doc "List all global config entries.".
-spec list() -> [beam_agent_global_config:config_entry()].
list() -> beam_agent_global_config:list().

-doc "Remove all global config entries.".
-spec clear() -> ok.
clear() -> beam_agent_global_config:clear().
