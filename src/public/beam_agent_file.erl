-module(beam_agent_file).
-moduledoc """
Public API for file operations.

This module provides text search, file search, symbol search, directory
listing, file reading, and version-control status within a session's
working directory. Every function uses native-first routing with universal
fallbacks via beam_agent_file_core.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Matches} = beam_agent_file:find_text(Session, <<"TODO">>),
[io:format("~s:~p: ~s~n", [
    maps:get(path, M), maps:get(line, M), maps:get(content, M)
]) || M <- Matches].
```

## See Also

  - beam_agent_file_core: universal fallback implementations
  - beam_agent: lifecycle entry point
""".

-export([
    find_text/2,
    find_files/2,
    find_symbols/2,
    list/2,
    read/2,
    status/1
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Search for text matching Pattern in the session's working directory.".
-spec find_text(pid(), binary()) -> {ok, term()} | {error, term()}.
find_text(Session, Pattern) ->
    beam_agent_core:native_or(Session, find_text, [Pattern], fun() ->
        beam_agent_file_core:find_text(Pattern, session_file_opts(Session))
    end).

-doc "Find files matching a pattern in the session's working directory.".
-spec find_files(pid(), map()) -> {ok, term()} | {error, term()}.
find_files(Session, Opts) ->
    beam_agent_core:native_or(Session, find_files, [Opts], fun() ->
        beam_agent_file_core:find_files(maps:merge(session_file_opts(Session), Opts))
    end).

-doc "Search for code symbols matching Query in the session's project.".
-spec find_symbols(pid(), binary()) -> {ok, term()} | {error, term()}.
find_symbols(Session, Query) ->
    beam_agent_core:native_or(Session, find_symbols, [Query], fun() ->
        beam_agent_file_core:find_symbols(Query, session_file_opts(Session))
    end).

-doc "List files and directories at the given Path.".
-spec list(pid(), binary()) -> {ok, term()} | {error, term()}.
list(Session, Path) ->
    beam_agent_core:native_or(Session, file_list, [Path], fun() ->
        beam_agent_file_core:file_list(Path)
    end).

-doc "Read the contents of a file at the given Path.".
-spec read(pid(), binary()) -> {ok, term()} | {error, term()}.
read(Session, Path) ->
    beam_agent_core:native_or(Session, file_read, [Path], fun() ->
        beam_agent_file_core:file_read(Path)
    end).

-doc "Get the version-control status of files in the session's project.".
-spec status(pid()) -> {ok, term()} | {error, term()}.
status(Session) ->
    beam_agent_core:native_or(Session, file_status, [], fun() ->
        beam_agent_file_core:file_status(session_file_opts(Session))
    end).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec session_file_opts(pid()) -> beam_agent_file_core:search_opts().
session_file_opts(Session) ->
    case beam_agent_core:session_info(Session) of
        {ok, Info} ->
            Cwd = maps:get(cwd, Info,
                    maps:get(working_directory, Info,
                    maps:get(project_path, Info, undefined))),
            case Cwd of
                CwdBin when is_binary(CwdBin), byte_size(CwdBin) > 0 ->
                    #{cwd => CwdBin};
                _ ->
                    #{}
            end;
        {error, _} ->
            #{}
    end.
