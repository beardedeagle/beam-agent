-module(beam_agent_apps).
-moduledoc """
Public API for app and project management.

This module provides operations for listing, inspecting, initializing,
and logging against apps/projects registered for a session. Every function
uses native-first routing with universal fallbacks via beam_agent_app_core.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Apps} = beam_agent_apps:list(Session),
[io:format("~s~n", [maps:get(name, A, <<>>)]) || A <- Apps].
```

## See Also

  - beam_agent_app_core: universal fallback implementations
  - beam_agent: lifecycle entry point
""".

-export([
    list/1,
    list/2,
    info/1,
    init/1,
    log/2,
    modes/1
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "List apps and projects registered for a session.".
-spec list(pid()) -> {ok, term()} | {error, term()}.
list(Session) ->
    beam_agent_core:native_or(Session, apps_list, [], fun() ->
        beam_agent_app_core:apps_list(Session)
    end).

-doc "List apps and projects with optional filter criteria.".
-spec list(pid(), map()) -> {ok, term()} | {error, term()}.
list(Session, Opts) ->
    beam_agent_core:native_or(Session, apps_list, [Opts], fun() ->
        beam_agent_app_core:apps_list(Session, Opts)
    end).

-doc "Return information about the current app or project context.".
-spec info(pid()) -> {ok, term()} | {error, term()}.
info(Session) ->
    beam_agent_core:native_or(Session, app_info, [], fun() ->
        beam_agent_app_core:app_info(Session)
    end).

-doc "Initialize the app and project context for a session.".
-spec init(pid()) -> {ok, term()} | {error, term()}.
init(Session) ->
    beam_agent_core:native_or(Session, app_init, [], fun() ->
        beam_agent_app_core:app_init(Session)
    end).

-doc "Append a log entry to the session's app log.".
-spec log(pid(), map()) -> {ok, term()} | {error, term()}.
log(Session, Body) ->
    beam_agent_core:native_or(Session, app_log, [Body], fun() ->
        _ = beam_agent_app_core:app_log(Session, Body),
        {ok, beam_agent_core:with_universal_source(Session, #{status => logged})}
    end).

-doc "List available app modes for a session.".
-spec modes(pid()) -> {ok, term()} | {error, term()}.
modes(Session) ->
    beam_agent_core:native_or(Session, app_modes, [], fun() ->
        beam_agent_app_core:app_modes(Session)
    end).
