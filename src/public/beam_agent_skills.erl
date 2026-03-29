-module(beam_agent_skills).
-moduledoc """
Public API for skill management.

This module provides operations for listing local and remote skills,
exporting skills to remote registries, and toggling skill configuration.
Every function uses native-first routing with universal fallbacks via
beam_agent_skills_core.

Universal operations accept either a live session pid or a persisted
session id binary.

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
    config_write/3,
    %% Global skill registration (shared across all sessions)
    ensure_global_table/0,
    register_global/2,
    unregister_global/1,
    get_global/1,
    list_global/0,
    list_global/1,
    clear_global/0
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "List skills available for a session.".
-spec list(pid() | binary()) -> {ok, [map()]} | {error, term()}.
list(Session) ->
    beam_agent_core:native_or(Session, skills_list, [], fun() ->
        beam_agent_core:list_skills(Session)
    end).

-doc "List skills with optional filter criteria.".
-spec list(pid() | binary(), map()) -> {ok, [map()]} | {error, term()}.
list(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_list, [Opts], fun() ->
        beam_agent_core:list_skills(Session)
    end).

-doc "List skills available in remote registries.".
-spec remote_list(pid() | binary()) -> {ok, map()} | {error, term()}.
remote_list(Session) ->
    beam_agent_core:native_or(Session, skills_remote_list, [], fun() ->
        universal_skills_remote_list(Session, #{})
    end).

-doc "List remote skills with optional filters.".
-spec remote_list(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
remote_list(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_remote_list, [Opts], fun() ->
        universal_skills_remote_list(Session, Opts)
    end).

-doc "Export a local skill to a remote registry.".
-spec remote_export(pid() | binary(), map()) -> {ok, #{skills := [beam_agent_skills_core:skill_entry()], exported_at := integer()}} | {error, term()}.
remote_export(Session, Opts) ->
    beam_agent_core:native_or(Session, skills_remote_export, [Opts], fun() ->
        beam_agent_skills_core:skills_remote_export(Session, Opts)
    end).

-doc "Enable or disable a skill by its file path.".
-spec config_write(pid() | binary(), binary(), boolean()) -> {ok, map()} | {error, term()}.
config_write(Session, Path, Enabled) ->
    beam_agent_core:native_or(Session, skills_config_write, [Path, Enabled], fun() ->
        beam_agent_skills_core:skills_config_write(Session, Path, Enabled),
        {ok, beam_agent_core:with_universal_source(Session, #{path => Path, enabled => Enabled})}
    end).

%%--------------------------------------------------------------------
%% Global Skill Registration
%%--------------------------------------------------------------------

-doc "Create the global skills ETS table. Idempotent.".
-spec ensure_global_table() -> ok.
ensure_global_table() ->
    beam_agent_skills_core:ensure_global_table().

-doc "Register a skill globally (shared across all sessions).".
-spec register_global(binary(), map()) -> ok.
register_global(SkillId, Opts) ->
    beam_agent_skills_core:register_global_skill(SkillId, Opts).

-doc "Unregister a global skill by id.".
-spec unregister_global(binary()) -> ok.
unregister_global(SkillId) ->
    beam_agent_skills_core:unregister_global_skill(SkillId).

-doc "Fetch a single global skill by id.".
-spec get_global(binary()) ->
    {ok, beam_agent_skills_core:skill_entry()} | {error, not_found}.
get_global(SkillId) ->
    beam_agent_skills_core:get_global_skill(SkillId).

-doc "List all globally registered skills.".
-spec list_global() -> [beam_agent_skills_core:skill_entry()].
list_global() ->
    beam_agent_skills_core:list_global_skills().

-doc "List globally registered skills with optional filters.".
-spec list_global(beam_agent_skills_core:list_opts()) ->
    [beam_agent_skills_core:skill_entry()].
list_global(Opts) ->
    beam_agent_skills_core:list_global_skills(Opts).

-doc "Remove all globally registered skills.".
-spec clear_global() -> ok.
clear_global() ->
    beam_agent_skills_core:clear_global_skills().

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec universal_skills_remote_list(pid() | binary(), map()) -> {ok, map()} | {error, term()}.
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
