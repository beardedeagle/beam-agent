-module(beam_agent_file_core).
-include_lib("kernel/include/file.hrl").
-moduledoc """
Universal file operations for the BEAM Agent SDK.

Provides file listing, reading, searching, and status capabilities
using Erlang stdlib (`file`, `filelib`, `re` modules). These are
universal fallbacks for when a backend does not support native file
operations natively.

No ETS tables. No processes. Pure I/O via Erlang stdlib.

Usage:
```erlang
%% Search for text across files:
{ok, Results} = beam_agent_file_core:find_text(<<"TODO">>, #{}),

%% Find files matching a pattern:
{ok, Entries} = beam_agent_file_core:find_files(<<"**/*.erl">>, #{}),

%% Read a file:
{ok, #{content := Bin}} = beam_agent_file_core:file_read(<<"/tmp/foo.txt">>),

%% List a directory:
{ok, Entries} = beam_agent_file_core:file_list(<<"/tmp">>),

%% Git-aware working directory status:
{ok, Status} = beam_agent_file_core:file_status(#{cwd => <<"/my/project">>}).
```
""".

-export([
    find_text/2, find_text/3,
    find_files/1, find_files/2,
    find_symbols/1, find_symbols/2,
    file_list/1, file_list/2,
    file_read/1, file_read/2,
    file_status/0, file_status/1
]).

-export_type([search_result/0, file_entry/0, search_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% A single text match inside a file.
-type search_result() :: #{
    path    := binary(),
    line    := pos_integer(),
    content := binary()
}.

%% A directory entry returned by find_files/file_list.
-type file_entry() :: #{
    path     := binary(),
    type     := file | directory | symlink | other,
    size     => non_neg_integer(),
    modified => calendar:datetime()
}.

%% Options shared across search and list operations.
-type search_opts() :: #{
    cwd            => binary(),
    max_results    => pos_integer(),
    include        => [binary()],
    exclude        => [binary()],
    case_sensitive => boolean()
}.

-define(DEFAULT_MAX_RESULTS, 100).
-define(DEFAULT_MAX_FILE_SIZE, 10485760). %% 10 MB
-define(DEFAULT_EXCLUDES, [<<".git">>, <<"_build">>, <<"node_modules">>, <<"deps">>]).

%%--------------------------------------------------------------------
%% Public API: find_text
%%--------------------------------------------------------------------

-doc """
Search for a text pattern across files under the current working directory.

Returns up to 100 matching lines by default. Each result carries the
file path, 1-based line number, and the matching line content.

Default excludes: `.git`, `_build`, `node_modules`, `deps`.
""".
-spec find_text(binary(), search_opts()) ->
    {ok, [search_result()]} | {error, {invalid_pattern, term(), non_neg_integer()}}.
find_text(Pattern, Opts) when is_binary(Pattern), is_map(Opts) ->
    find_text(Pattern, <<"**/*">>, Opts).

-doc """
Search for a text pattern across files matching a glob under cwd.

`FileGlob` is an Erlang wildcard pattern (e.g. `<<"**/*.erl">>`).
Options are the same as `find_text/2`.
""".
-spec find_text(binary(), binary(), search_opts()) ->
    {ok, [search_result()]} | {error, {invalid_pattern, term(), non_neg_integer()}}.
find_text(Pattern, FileGlob, Opts)
  when is_binary(Pattern), is_binary(FileGlob), is_map(Opts) ->
    CaseSensitive = maps:get(case_sensitive, Opts, true),
    REOpts = case CaseSensitive of
        true  -> [];
        false -> [caseless]
    end,
    case re:compile(Pattern, REOpts) of
        {ok, CompiledRE} ->
            Cwd = cwd_binary(Opts),
            Files = resolve_glob(FileGlob, Cwd, Opts),
            MaxResults = maps:get(max_results, Opts, ?DEFAULT_MAX_RESULTS),
            Results = search_files(CompiledRE, Files, MaxResults, []),
            {ok, Results};
        {error, {Reason, Pos}} ->
            {error, {invalid_pattern, Reason, Pos}}
    end.

%%--------------------------------------------------------------------
%% Public API: find_files
%%--------------------------------------------------------------------

-doc """
Find files under the current working directory using a wildcard pattern.

Equivalent to `find_files(<<"**/*">>, Opts)`. Returns file entries
with path, type, size, and modified time.
""".
-spec find_files(search_opts()) -> {ok, [file_entry()]}.
find_files(Opts) when is_map(Opts) ->
    find_files(<<"**/*">>, Opts).

-doc """
Find files matching a glob pattern under the configured working directory.

`Pattern` is an Erlang wildcard (passed to `filelib:wildcard/2`).
Common excludes (`.git`, `_build`, `node_modules`, `deps`) are applied
unless overridden via the `exclude` option.

Returns `{ok, Entries}` sorted by path.
""".
-spec find_files(binary(), search_opts()) -> {ok, [file_entry()]}.
find_files(Pattern, Opts) when is_binary(Pattern), is_map(Opts) ->
    Cwd = cwd_binary(Opts),
    Files = resolve_glob(Pattern, Cwd, Opts),
    Entries = [file_to_entry(Cwd, F) || F <- Files],
    Sorted = lists:sort(fun(A, B) ->
        maps:get(path, A) =< maps:get(path, B)
    end, Entries),
    {ok, Sorted}.

%%--------------------------------------------------------------------
%% Public API: find_symbols
%%--------------------------------------------------------------------

-doc """
Search for code symbol definitions under the current working directory.

Builds a regex from common definition patterns for multiple languages
and delegates to `find_text/3`. Searches all source files under cwd.

Recognized patterns:
- Erlang: `-spec Query(`, function head `Query(`
- Elixir: `def Query`, `defp Query`, `defmodule Query`
- Python: `def Query`, `class Query`
- JavaScript/TypeScript: `function Query`, `class Query`, `const Query =`
""".
-spec find_symbols(search_opts()) ->
    {ok, [search_result()]} | {error, {invalid_pattern, term(), non_neg_integer()}}.
find_symbols(Opts) when is_map(Opts) ->
    find_symbols(<<>>, Opts).

-doc """
Search for a named symbol definition across source files under cwd.

When `Query` is empty, returns all definition-like lines. When non-empty,
restricts matches to lines containing `Query`.
""".
-spec find_symbols(binary(), search_opts()) ->
    {ok, [search_result()]} | {error, term()}.
find_symbols(Query, Opts) when is_binary(Query), is_map(Opts) ->
    Q = re:replace(Query, <<"[\\^$.|?*+(){}\\[\\]\\\\]">>, <<"\\\\&">>,
                   [global, {return, binary}]),
    Pattern = case Q of
        <<>> ->
            <<"(-spec |^[a-z_][a-zA-Z0-9_]*\\(|"
              "def |defp |defmodule |"
              "class |function )">>;
        _ ->
            Parts = [
                <<"(-spec ", Q/binary, "\\()">>,
                <<"(^", Q/binary, "\\()">>,
                <<"(def ", Q/binary, "\\b)">>,
                <<"(defp ", Q/binary, "\\b)">>,
                <<"(defmodule ", Q/binary, "\\b)">>,
                <<"(class ", Q/binary, "\\b)">>,
                <<"(function ", Q/binary, "\\b)">>,
                <<"(const ", Q/binary, "\\s*=)">>
            ],
            join_binary(Parts, <<"|">>)
    end,
    find_text(Pattern, <<"**/*">>, Opts#{case_sensitive => true}).

%%--------------------------------------------------------------------
%% Public API: file_list
%%--------------------------------------------------------------------

-doc """
List all entries in a directory using default options.
""".
-spec file_list(binary()) -> {ok, [file_entry()]} | {error, term()}.
file_list(Path) when is_binary(Path) ->
    file_list(Path, #{}).

-doc """
List entries in a directory.

Returns `{ok, Entries}` sorted by name. Entries include path, type,
size, and modified time. The returned paths are absolute.
""".
-spec file_list(binary(), search_opts()) ->
    {ok, [file_entry()]} | {error, term()}.
file_list(Path, Opts) when is_binary(Path), is_map(Opts) ->
    PathStr = unicode:characters_to_list(Path),
    case file:list_dir(PathStr) of
        {ok, Names} ->
            Sorted = lists:sort(Names),
            Entries = [file_to_entry(Path, list_to_binary(N)) || N <- Sorted],
            _ = Opts,
            {ok, Entries};
        {error, Reason} ->
            {error, {list_dir_failed, Path, Reason}}
    end.

%%--------------------------------------------------------------------
%% Public API: file_read
%%--------------------------------------------------------------------

-doc """
Read file contents using default options.
""".
-spec file_read(binary()) ->
    {ok, #{path := binary(), content := binary()}}
    | {error, {file_too_large, binary()}}
    | {error, {read_failed, binary(), term()}}.
file_read(Path) when is_binary(Path) ->
    file_read(Path, #{}).

-doc """
Read file contents.

Returns `{ok, #{path => Path, content => Binary}}` on success.
Returns `{error, {read_failed, Path, Reason}}` on failure.

Files larger than 10 MB are rejected with `{error, {file_too_large, Path}}`.
""".
-spec file_read(binary(), search_opts()) ->
    {ok, #{path := binary(), content := binary()}}
    | {error, {file_too_large, binary()}}
    | {error, {read_failed, binary(), term()}}.
file_read(Path, Opts) when is_binary(Path), is_map(Opts) ->
    PathStr = unicode:characters_to_list(Path),
    case file:read_file_info(PathStr) of
        {ok, #file_info{size = Size}} ->
            MaxSize = maps:get(max_file_size, Opts, ?DEFAULT_MAX_FILE_SIZE),
            case Size > MaxSize of
                true ->
                    {error, {file_too_large, Path}};
                false ->
                    case file:read_file(PathStr) of
                        {ok, Content} ->
                            {ok, #{path => Path, content => Content}};
                        {error, Reason} ->
                            {error, {read_failed, Path, Reason}}
                    end
            end;
        {error, Reason} ->
            {error, {read_failed, Path, Reason}}
    end.

%%--------------------------------------------------------------------
%% Public API: file_status
%%--------------------------------------------------------------------

-doc """
Get working directory file status using default options.

Attempts `git status --porcelain` first. Falls back to listing files
with modification times if git is unavailable or the directory is not
a git repo.
""".
-spec file_status() ->
    {ok, #{cwd := binary(), source := git | filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), term()}}.
file_status() ->
    file_status(#{}).

-doc """
Get working directory file status.

Tries `git status --porcelain` via `beam_agent_command_core:run/2`.
On success, parses git status lines into change entries. On failure
(not a git repo, git not installed, etc.), falls back to listing all
files in cwd with their modification times.

Opts:
- `cwd`: working directory (default: current directory)
""".
-spec file_status(search_opts()) ->
    {ok, #{cwd := binary(), source := git | filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), term()}}.
file_status(Opts) when is_map(Opts) ->
    Cwd = cwd_binary(Opts),
    CmdOpts = #{cwd => Cwd, timeout => 10000},
    case beam_agent_command_core:run(<<"git status --porcelain">>, CmdOpts) of
        {ok, #{exit_code := 0, output := Output}} ->
            Lines = binary:split(Output, <<"\n">>, [global, trim]),
            Files = [parse_git_status_line(L) || L <- Lines, L =/= <<>>],
            {ok, #{cwd => Cwd, source => git, files => Files}};
        _ ->
            fallback_file_status(Cwd)
    end.

%%--------------------------------------------------------------------
%% Internal: CWD resolution
%%--------------------------------------------------------------------

-spec cwd_binary(search_opts()) -> binary().
cwd_binary(Opts) ->
    case maps:find(cwd, Opts) of
        {ok, Dir} when is_binary(Dir) ->
            Dir;
        {ok, Dir} when is_list(Dir) ->
            unicode:characters_to_binary(Dir);
        error ->
            case file:get_cwd() of
                {ok, Cwd} -> unicode:characters_to_binary(Cwd);
                {error, _} -> <<".">>
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Glob resolution
%%--------------------------------------------------------------------

-spec resolve_glob(binary(), binary(), search_opts()) -> [binary()].
resolve_glob(Glob, Cwd, Opts) ->
    GlobStr = unicode:characters_to_list(Glob),
    CwdStr = unicode:characters_to_list(Cwd),
    RawPaths = filelib:wildcard(GlobStr, CwdStr),
    Excludes = maps:get(exclude, Opts, ?DEFAULT_EXCLUDES),
    AbsFiles = [begin
        Abs = filename:join(CwdStr, P),
        unicode:characters_to_binary(Abs)
    end || P <- RawPaths, filelib:is_regular(filename:join(CwdStr, P))],
    [F || F <- AbsFiles, not is_excluded(F, Excludes)].

-spec is_excluded(binary(), [binary()]) -> boolean().
is_excluded(Path, Excludes) ->
    lists:any(fun(Pat) ->
        binary:match(Path, Pat) =/= nomatch
    end, Excludes).

%%--------------------------------------------------------------------
%% Internal: File search
%%--------------------------------------------------------------------

-spec search_files(re:mp(), [binary()], pos_integer(), [search_result()]) ->
    [search_result()].
search_files(_RE, [], _MaxResults, Acc) ->
    lists:reverse(Acc);
search_files(_RE, _Files, MaxResults, Acc)
  when length(Acc) >= MaxResults ->
    lists:reverse(Acc);
search_files(RE, [File | Rest], MaxResults, Acc) ->
    Remaining = MaxResults - length(Acc),
    NewAcc = case file:read_file(unicode:characters_to_list(File)) of
        {ok, Content} when byte_size(Content) =< ?DEFAULT_MAX_FILE_SIZE ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            search_lines(RE, File, Lines, 1, Remaining, Acc);
        {ok, _TooBig} ->
            Acc;
        {error, _} ->
            Acc
    end,
    search_files(RE, Rest, MaxResults, NewAcc).

-spec search_lines(re:mp(), binary(), [binary()], pos_integer(),
                   pos_integer(), [search_result()]) -> [search_result()].
search_lines(_RE, _File, [], _LineNum, _Remaining, Acc) ->
    Acc;
search_lines(_RE, _File, _Lines, _LineNum, 0, Acc) ->
    Acc;
search_lines(RE, File, [Line | Rest], LineNum, Remaining, Acc) ->
    case re:run(Line, RE, [{capture, none}]) of
        match ->
            Result = #{path => File, line => LineNum, content => Line},
            search_lines(RE, File, Rest, LineNum + 1, Remaining - 1,
                         [Result | Acc]);
        nomatch ->
            search_lines(RE, File, Rest, LineNum + 1, Remaining, Acc)
    end.

%%--------------------------------------------------------------------
%% Internal: File entry construction
%%--------------------------------------------------------------------

-spec file_to_entry(binary(), binary()) -> file_entry().
file_to_entry(BasePath, Name) ->
    FullPath = case binary:last(BasePath) of
        $/ -> <<BasePath/binary, Name/binary>>;
        _  -> <<BasePath/binary, "/", Name/binary>>
    end,
    PathStr = unicode:characters_to_list(FullPath),
    Base = #{path => FullPath},
    case file:read_file_info(PathStr, [{time, local}]) of
        {ok, #file_info{size = Size, type = RawType, mtime = Mtime}} ->
            Type = normalize_file_type(RawType),
            Base#{type => Type, size => Size, modified => Mtime};
        {error, _} ->
            Base#{type => other}
    end.

-spec normalize_file_type(device | directory | other | regular | symlink) -> file | directory | symlink | other.
normalize_file_type(regular)   -> file;
normalize_file_type(directory) -> directory;
normalize_file_type(symlink)   -> symlink;
normalize_file_type(_)         -> other.

%%--------------------------------------------------------------------
%% Internal: Git status parsing
%%--------------------------------------------------------------------

-spec parse_git_status_line(binary()) -> #{status := binary(), path := binary()}.
parse_git_status_line(Line) when byte_size(Line) >= 3 ->
    <<XY:2/binary, _Space:1/binary, Rest/binary>> = Line,
    #{status => XY, path => Rest};
parse_git_status_line(Line) ->
    #{status => <<>>, path => Line}.

%%--------------------------------------------------------------------
%% Internal: Fallback file status (non-git)
%%--------------------------------------------------------------------

-spec fallback_file_status(binary()) ->
    {ok, #{cwd := binary(), source := filesystem, files := [map()]}}
    | {error, {list_dir_failed, binary(), term()}}.
fallback_file_status(Cwd) ->
    CwdStr = unicode:characters_to_list(Cwd),
    case file:list_dir(CwdStr) of
        {ok, Names} ->
            Entries = lists:filtermap(fun(Name) ->
                FullStr = filename:join(CwdStr, Name),
                FullBin = unicode:characters_to_binary(FullStr),
                case file:read_file_info(FullStr, [{time, local}]) of
                    {ok, #file_info{mtime = Mtime}} ->
                        {true, #{path => FullBin, modified => Mtime}};
                    {error, _} ->
                        false
                end
            end, lists:sort(Names)),
            {ok, #{cwd => Cwd, source => filesystem, files => Entries}};
        {error, Reason} ->
            {error, {list_dir_failed, Cwd, Reason}}
    end.

%%--------------------------------------------------------------------
%% Internal: Binary helpers
%%--------------------------------------------------------------------

-spec join_binary([binary(), ...], binary()) -> binary().
join_binary([H], _Sep) -> H;
join_binary([H | T], Sep) ->
    lists:foldl(fun(Part, Acc) ->
        <<Acc/binary, Sep/binary, Part/binary>>
    end, H, T).
