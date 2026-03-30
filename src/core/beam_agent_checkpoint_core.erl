-module(beam_agent_checkpoint_core).
-moduledoc """
Universal file checkpointing and rewind for the BEAM Agent SDK.

Provides file snapshot and restore capabilities across all adapters.
Before a tool mutates files, callers snapshot the target paths.
Rewind restores files to their checkpointed state.

Uses ETS for checkpoint metadata and stores file content directly.
Checkpoints persist for the lifetime of the BEAM node (or until
explicitly deleted/cleared).

Usage:
```erlang
%% Snapshot files before a mutation:
{ok, CP} = beam_agent_checkpoint_core:snapshot(SessionId, UUID, ["/tmp/foo.txt"]),

%% Later, rewind to that checkpoint:
ok = beam_agent_checkpoint_core:rewind(SessionId, UUID)
```
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Checkpoint operations
    snapshot/3,
    rewind/2,
    list_checkpoints/1,
    get_checkpoint/2,
    delete_checkpoint/2,
    %% Hook helpers
    extract_file_paths/2
]).

-export_type([checkpoint/0, file_snapshot/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% A single file's snapshot.
-type file_snapshot() :: #{
    path := binary(),
    content := binary() | undefined,
    existed := boolean(),
    permissions := non_neg_integer() | undefined
}.

%% Checkpoint metadata stored in ETS.
-type checkpoint() :: #{
    uuid := binary(),
    session_id := binary(),
    created_at := integer(),
    files := [file_snapshot()]
}.

-define(TABLE, beam_agent_runtime).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the checkpoints ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_runtime:app_ensure_tables().

-doc "Clear all checkpoint data.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?TABLE, {{checkpoint, '_'}, '_'}),
    ok.

%%--------------------------------------------------------------------
%% Checkpoint Operations
%%--------------------------------------------------------------------

-doc """
Snapshot a list of file paths for later rewind.
Reads each file's content and permissions. Files that don't
exist are recorded as non-existent (rewind will delete them).
""".
-spec snapshot(binary(), binary(), [binary() | string()]) ->
    {ok, checkpoint()} | {error, {path_traversal, binary()}}.
snapshot(SessionId, UUID, FilePaths)
  when is_binary(SessionId), is_binary(UUID), is_list(FilePaths) ->
    ensure_tables(),
    case validate_all_paths(FilePaths) of
        {error, _} = Err ->
            Err;
        ok ->
            snapshot_validated(SessionId, UUID, FilePaths)
    end.

-spec snapshot_validated(binary(), binary(), [binary() | string()]) ->
    {ok, checkpoint()}.
snapshot_validated(SessionId, UUID, FilePaths) ->
    Now = erlang:system_time(millisecond),
    Files = lists:map(fun snapshot_file/1, FilePaths),
    Checkpoint = #{
        uuid => UUID,
        session_id => SessionId,
        created_at => Now,
        files => Files
    },
    Key = {checkpoint, {SessionId, UUID}},
    beam_agent_ets:insert(?TABLE, {Key, Checkpoint}),
    {ok, Checkpoint}.

-doc """
Rewind files to a checkpoint state.
Restores each file's content, permissions, and existence.
Files created after the checkpoint are deleted if they didn't
exist at checkpoint time.
""".
-spec rewind(binary(), binary()) ->
    ok | {error, not_found | {restore_failed, binary(), file:posix() | path_traversal}}.
rewind(SessionId, UUID)
  when is_binary(SessionId), is_binary(UUID) ->
    ensure_tables(),
    Key = {checkpoint, {SessionId, UUID}},
    case ets:lookup(?TABLE, Key) of
        [{_, #{files := Files}}] ->
            restore_files(Files);
        [] ->
            {error, not_found}
    end.

-doc "List all checkpoints for a session, newest first.".
-spec list_checkpoints(binary()) -> {ok, [checkpoint()]}.
list_checkpoints(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Checkpoints = ets:foldl(fun
        ({{checkpoint, {SId, _}}, CP}, Acc) when SId =:= SessionId ->
            [CP | Acc];
        (_, Acc) ->
            Acc
    end, [], ?TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(created_at, A, 0) >= maps:get(created_at, B, 0)
    end, Checkpoints),
    {ok, Sorted}.

-doc "Get a specific checkpoint.".
-spec get_checkpoint(binary(), binary()) ->
    {ok, checkpoint()} | {error, not_found}.
get_checkpoint(SessionId, UUID)
  when is_binary(SessionId), is_binary(UUID) ->
    ensure_tables(),
    Key = {checkpoint, {SessionId, UUID}},
    case ets:lookup(?TABLE, Key) of
        [{_, CP}] -> {ok, CP};
        [] -> {error, not_found}
    end.

-doc "Delete a checkpoint.".
-spec delete_checkpoint(binary(), binary()) -> ok.
delete_checkpoint(SessionId, UUID)
  when is_binary(SessionId), is_binary(UUID) ->
    ensure_tables(),
    Key = {checkpoint, {SessionId, UUID}},
    beam_agent_ets:delete(?TABLE, Key),
    ok.

%%--------------------------------------------------------------------
%% Hook Helpers
%%--------------------------------------------------------------------

-doc """
Extract file paths from a tool use message for checkpointing.
Inspects the tool name and input to determine which files will
be modified.
""".
-spec extract_file_paths(binary(), map()) -> [binary()].
extract_file_paths(ToolName, ToolInput) when is_map(ToolInput) ->
    case ToolName of
        <<"Write">> ->
            extract_path(ToolInput);
        <<"Edit">> ->
            extract_path(ToolInput);
        <<"write">> ->
            extract_path(ToolInput);
        <<"edit">> ->
            extract_path(ToolInput);
        _ ->
            []
    end;
extract_file_paths(_, _) ->
    [].

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec snapshot_file(binary() | string()) -> file_snapshot().
snapshot_file(Path) when is_list(Path) ->
    snapshot_file(unicode:characters_to_binary(Path));
snapshot_file(Path) when is_binary(Path) ->
    PathStr = unicode:characters_to_list(Path),
    case file:read_file(PathStr) of
        {ok, Content} ->
            Perms = case file:read_file_info(PathStr) of
                {ok, Info} -> element(8, Info);  %% mode field (1=tag,2=size,3=type,4=access,5=atime,6=mtime,7=ctime,8=mode)
                _ -> undefined
            end,
            #{path => Path, content => Content,
              existed => true, permissions => Perms};
        {error, enoent} ->
            #{path => Path, content => undefined,
              existed => false, permissions => undefined};
        {error, _} ->
            %% Can't read — record as non-existent to be safe
            #{path => Path, content => undefined,
              existed => false, permissions => undefined}
    end.

-spec restore_files([file_snapshot()]) ->
    ok | {error, {restore_failed, binary(), file:posix() | path_traversal}}.
restore_files([]) ->
    ok;
restore_files([#{path := Path, existed := false} | Rest]) ->
    %% File didn't exist at checkpoint — delete it if it exists now
    case validate_checkpoint_path(Path) of
        {error, path_traversal} ->
            {error, {restore_failed, Path, path_traversal}};
        ok ->
            PathStr = unicode:characters_to_list(Path),
            _ = file:delete(PathStr),
            restore_files(Rest)
    end;
restore_files([#{path := Path, content := Content,
                 permissions := Perms} | Rest])
  when Content =/= undefined ->
    case validate_checkpoint_path(Path) of
        {error, path_traversal} ->
            {error, {restore_failed, Path, path_traversal}};
        ok ->
            restore_file_content(Path, Content, Perms, Rest)
    end;
restore_files([_ | Rest]) ->
    restore_files(Rest).

-spec restore_file_content(binary(), binary(), non_neg_integer() | undefined,
                           [file_snapshot()]) ->
    ok | {error, {restore_failed, binary(), file:posix() | path_traversal}}.
restore_file_content(Path, Content, Perms, Rest) ->
    PathStr = unicode:characters_to_list(Path),
    TmpPath = PathStr ++ ".beam_agent_tmp",
    case file:write_file(TmpPath, Content) of
        ok ->
            case file:rename(TmpPath, PathStr) of
                ok ->
                    case Perms of
                        undefined -> ok;
                        Mode when is_integer(Mode) ->
                            _ = file:change_mode(PathStr, Mode),
                            ok
                    end,
                    restore_files(Rest);
                {error, RenameErr} ->
                    _ = file:delete(TmpPath),
                    {error, {restore_failed, Path, RenameErr}}
            end;
        {error, Reason} ->
            {error, {restore_failed, Path, Reason}}
    end.

-spec extract_path(map()) -> [binary()].
extract_path(Input) ->
    case maps:find(<<"file_path">>, Input) of
        {ok, P} when is_binary(P) -> [P];
        _ ->
            case maps:find(file_path, Input) of
                {ok, P} when is_binary(P) -> [P];
                _ -> []
            end
    end.

%%--------------------------------------------------------------------
%% Path validation
%%--------------------------------------------------------------------

%% Validate paths for directory traversal.
%% Absolute paths are allowed; relative paths must not escape the cwd.
-spec validate_all_paths([binary() | string()]) ->
    ok | {error, {path_traversal, binary()}}.
validate_all_paths([]) ->
    ok;
validate_all_paths([Path | Rest]) ->
    BinPath = case is_list(Path) of
        true  -> unicode:characters_to_binary(Path);
        false -> Path
    end,
    case validate_checkpoint_path(BinPath) of
        ok -> validate_all_paths(Rest);
        {error, path_traversal} -> {error, {path_traversal, BinPath}}
    end.

%% Validate a single checkpoint path for directory traversal.
%%
%% Absolute paths are allowed — they are explicit and do not constitute
%% traversal. Policy enforcement (which absolute paths are permitted)
%% is the responsibility of the command guard, not checkpoint.
%%
%% Relative paths are validated with filelib:safe_relative_path/2 (OTP 25+)
%% which rejects embedded .. components that would escape the base directory.
-spec validate_checkpoint_path(binary()) -> ok | {error, path_traversal}.
validate_checkpoint_path(Path) when is_binary(Path) ->
    PathStr = unicode:characters_to_list(Path),
    case filename:pathtype(PathStr) of
        absolute ->
            ok;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} ->
                    case filelib:safe_relative_path(PathStr, Cwd) of
                        unsafe -> {error, path_traversal};
                        _Safe  -> ok
                    end;
                {error, _Reason} ->
                    {error, path_traversal}
            end
    end.

