-module(beam_agent_skills).
-moduledoc """
Public API for skill management.

This module provides operations for listing local and remote skills,
exporting skills to remote registries, and toggling skill configuration.
Every function uses native-first routing with universal fallbacks via
beam_agent_skills_core.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Skills} = beam_agent_skills:list(Session),
[io:format("~s~n", [maps:get(name, S, <<>>)]) || S <- Skills].
```

## See Also

  - beam_agent_skills_core: universal fallback implementations
  - beam_agent: lifecycle entry point
""".

-export([
    list/1,
    list/2,
    remote_list/1,
    remote_list/2,
    remote_export/2,
    config_write/3
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "List skills available for a session.".
-spec list(pid()) -> {ok, term()} | {error, term()}.
list(Session) ->
    beam_agent_core:native_or(Session, skills_list, [], fun() ->
        beam_agent_core:list_skills(Session)
    end).

-doc "List skills with optional filter criteria.".
-spec list(pid(), map()) -> {ok, term()} | {error, term()}.
list(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_list, [Opts], fun() ->
        beam_agent_core:list_skills(Session)
    end).

-doc "List skills available in remote registries.".
-spec remote_list(pid()) -> {ok, term()} | {error, term()}.
remote_list(Session) ->
    beam_agent_core:native_or(Session, skills_remote_list, [], fun() ->
        universal_skills_remote_list(Session, #{})
    end).

-doc "List remote skills with optional filters.".
-spec remote_list(pid(), map()) -> {ok, term()} | {error, term()}.
remote_list(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_remote_list, [Opts], fun() ->
        universal_skills_remote_list(Session, Opts)
    end).

-doc "Export a local skill to a remote registry.".
-spec remote_export(pid(), map()) -> {ok, term()} | {error, term()}.
remote_export(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_remote_export, [Opts], fun() ->
        beam_agent_skills_core:skills_remote_export(Session, Opts)
    end).

-doc "Enable or disable a skill by its file path.".
-spec config_write(pid(), binary(), boolean()) -> {ok, term()} | {error, term()}.
config_write(Session, Path, Enabled) ->
    beam_agent_core:native_or(Session, skills_config_write, [Path, Enabled], fun() ->
        beam_agent_skills_core:skills_config_write(Session, Path, Enabled),
        {ok, beam_agent_core:with_universal_source(Session, #{path => Path, enabled => Enabled})}
    end).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec universal_skills_remote_list(pid(), map()) -> {ok, map()} | {error, term()}.
universal_skills_remote_list(Session, _Opts) ->
    case beam_agent_core:list_skills(Session) of
        {ok, Skills} ->
            {ok, beam_agent_core:with_universal_source(Session, #{
                skills => Skills,
                count => length(Skills)
            })};
        {error, _} = Error ->
            Error
    end.
