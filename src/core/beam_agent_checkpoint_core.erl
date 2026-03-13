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

-define(CHECKPOINTS_TABLE, beam_agent_checkpoints).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the checkpoints ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?CHECKPOINTS_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Clear all checkpoint data.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?CHECKPOINTS_TABLE),
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
    {ok, checkpoint()}.
snapshot(SessionId, UUID, FilePaths)
  when is_binary(SessionId), is_binary(UUID), is_list(FilePaths) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Files = lists:map(fun snapshot_file/1, FilePaths),
    Checkpoint = #{
        uuid => UUID,
        session_id => SessionId,
        created_at => Now,
        files => Files
    },
    Key = {SessionId, UUID},
    beam_agent_ets:insert(?CHECKPOINTS_TABLE, {Key, Checkpoint}),
    {ok, Checkpoint}.

-doc """
Rewind files to a checkpoint state.
Restores each file's content, permissions, and existence.
Files created after the checkpoint are deleted if they didn't
exist at checkpoint time.
""".
-spec rewind(binary(), binary()) ->
    ok | {error, not_found | {restore_failed, binary(), file:posix()}}.
rewind(SessionId, UUID)
  when is_binary(SessionId), is_binary(UUID) ->
    ensure_tables(),
    Key = {SessionId, UUID},
    case ets:lookup(?CHECKPOINTS_TABLE, Key) of
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
        ({{SId, _}, CP}, Acc) when SId =:= SessionId ->
            [CP | Acc];
        (_, Acc) ->
            Acc
    end, [], ?CHECKPOINTS_TABLE),
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
    Key = {SessionId, UUID},
    case ets:lookup(?CHECKPOINTS_TABLE, Key) of
        [{_, CP}] -> {ok, CP};
        [] -> {error, not_found}
    end.

-doc "Delete a checkpoint.".
-spec delete_checkpoint(binary(), binary()) -> ok.
delete_checkpoint(SessionId, UUID)
  when is_binary(SessionId), is_binary(UUID) ->
    ensure_tables(),
    Key = {SessionId, UUID},
    beam_agent_ets:delete(?CHECKPOINTS_TABLE, Key),
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

-spec restore_files([file_snapshot()]) -> ok | {error, term()}.
restore_files([]) ->
    ok;
restore_files([#{path := Path, existed := false} | Rest]) ->
    %% File didn't exist at checkpoint — delete it if it exists now
    PathStr = unicode:characters_to_list(Path),
    _ = file:delete(PathStr),
    restore_files(Rest);
restore_files([#{path := Path, content := Content,
                 permissions := Perms} | Rest])
  when Content =/= undefined ->
    PathStr = unicode:characters_to_list(Path),
    case file:write_file(PathStr, Content) of
        ok ->
            case Perms of
                undefined -> ok;
                Mode when is_integer(Mode) ->
                    _ = file:change_mode(PathStr, Mode),
                    ok
            end,
            restore_files(Rest);
        {error, Reason} ->
            {error, {restore_failed, Path, Reason}}
    end;
restore_files([_ | Rest]) ->
    restore_files(Rest).

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

