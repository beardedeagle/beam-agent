-module(beam_agent_config).
-moduledoc """
Public API for session configuration management.

This module provides read, write, and batch-update operations for session
configuration, including provider management, key-path writes, and
external agent config detection/import. Delegates to beam_agent_config_core
for universal fallback implementations.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Config} = beam_agent_config:read(Session),
io:format("Runtime: ~p~n", [maps:get(runtime, Config)]).
```

## See Also

  - beam_agent_config_core: universal fallback implementations
  - beam_agent_provider: provider-specific operations
  - beam_agent: lifecycle entry point
""".

-export([
    read/1,
    read/2,
    update/2,
    providers/1,
    value_write/3,
    value_write/4,
    batch_write/2,
    batch_write/3,
    requirements_read/1,
    external_agent_detect/1,
    external_agent_detect/2,
    external_agent_import/2
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Read the full configuration for a session.".
-spec read(pid()) -> {ok, map()} | {error, term()}.
read(Session) ->
    beam_agent_core:native_or(Session, config_read, [], fun() ->
        beam_agent_config_core:config_read(Session)
    end).

-doc "Read the session configuration with additional options.".
-spec read(pid(), map()) -> {ok, map()} | {error, term()}.
read(Session, Opts) ->
    beam_agent_core:native_or(Session, config_read, [Opts], fun() ->
        beam_agent_config_core:config_read(Session)
    end).

-doc "Update the session configuration with a partial patch.".
-spec update(pid(), map()) -> {ok, term()} | {error, term()}.
update(Session, Body) ->
    beam_agent_core:native_or(Session, config_update, [Body], fun() ->
        beam_agent_config_core:config_update(Session, Body)
    end).

-doc "List the providers available in the session configuration.".
-spec providers(pid()) -> {ok, term()} | {error, term()}.
providers(Session) ->
    beam_agent_core:native_or(Session, config_providers, [], fun() ->
        beam_agent_runtime:list_providers(Session)
    end).

-doc "Write a single configuration value at the given key path.".
-spec value_write(pid(), binary(), term()) -> {ok, term()} | {error, term()}.
value_write(Session, KeyPath, Value) ->
    value_write(Session, KeyPath, Value, #{}).

-doc "Write a single configuration value with options.".
-spec value_write(pid(), binary(), term(), map()) -> {ok, term()} | {error, term()}.
value_write(Session, KeyPath, Value, Opts) ->
    beam_agent_core:native_or(Session, config_value_write, [KeyPath, Value, Opts], fun() ->
        beam_agent_config_core:config_value_write(Session, KeyPath, Value, Opts)
    end).

-doc "Write multiple configuration values in a single batch.".
-spec batch_write(pid(), [map()]) -> {ok, term()} | {error, term()}.
batch_write(Session, Edits) ->
    batch_write(Session, Edits, #{}).

-doc "Write multiple configuration values in a batch with options.".
-spec batch_write(pid(), [map()], map()) -> {ok, term()} | {error, term()}.
batch_write(Session, Edits, Opts) ->
    beam_agent_core:native_or(Session, config_batch_write, [Edits, Opts], fun() ->
        beam_agent_config_core:config_batch_write(Session, Edits, Opts)
    end).

-doc "Read the configuration requirements for a session.".
-spec requirements_read(pid()) -> {ok, term()} | {error, term()}.
requirements_read(Session) ->
    beam_agent_core:native_or(Session, config_requirements_read, [], fun() ->
        beam_agent_config_core:config_requirements_read(Session)
    end).

-doc "Detect external agent configuration files in the project.".
-spec external_agent_detect(pid()) -> {ok, term()} | {error, term()}.
external_agent_detect(Session) ->
    external_agent_detect(Session, #{}).

-doc "Detect external agent configuration files with options.".
-spec external_agent_detect(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_detect(Session, Opts) ->
    beam_agent_core:native_or(Session, external_agent_config_detect, [Opts], fun() ->
        beam_agent_config_core:external_agent_config_detect(Session, Opts)
    end).

-doc "Import an external agent configuration into the session.".
-spec external_agent_import(pid(), map()) -> {ok, term()} | {error, term()}.
external_agent_import(Session, Opts) ->
    beam_agent_core:native_or(Session, external_agent_config_import, [Opts], fun() ->
        beam_agent_config_core:external_agent_config_import(Session, Opts)
    end).
