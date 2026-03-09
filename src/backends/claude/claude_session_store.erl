-module(claude_session_store).
-record(file_info,{size :: non_neg_integer() | undefined,
                   type ::
                       device | directory | other | regular | symlink |
                       undefined,
                   access ::
                       read | write | read_write | none | undefined,
                   atime ::
                       file:date_time() | non_neg_integer() | undefined,
                   mtime ::
                       file:date_time() | non_neg_integer() | undefined,
                   ctime ::
                       file:date_time() | non_neg_integer() | undefined,
                   mode :: non_neg_integer() | undefined,
                   links :: non_neg_integer() | undefined,
                   major_device :: non_neg_integer() | undefined,
                   minor_device :: non_neg_integer() | undefined,
                   inode :: non_neg_integer() | undefined,
                   uid :: non_neg_integer() | undefined,
                   gid :: non_neg_integer() | undefined}).
-export([config_dir/0,
         sanitize_path/1,
         list_sessions/0,
         list_sessions/1,
         get_session_messages/1,
         get_session_messages/2,
         find_session_file/2]).
-export_type([session_summary/0,list_opts/0,message_opts/0]).
-type session_summary() ::
          #{session_id := binary(),
            file_path := binary(),
            modified_at := integer(),
            model => binary(),
            cwd => binary()}.
-type list_opts() ::
          #{cwd => binary(),
            limit => pos_integer(),
            config_dir => binary()}.
-type message_opts() :: #{config_dir => binary()}.
-spec config_dir() -> binary().
config_dir() ->
    case os:getenv("CLAUDE_CONFIG_DIR") of
        false ->
            case os:getenv("HOME") of
                false ->
                    <<"/tmp/.claude">>;
                Home ->
                    HomeBin = unicode:characters_to_binary(Home),
                    <<HomeBin/binary,"/.claude">>
            end;
        Dir ->
            unicode:characters_to_binary(Dir)
    end.
-spec sanitize_path(binary()) -> binary().
sanitize_path(Path) when is_binary(Path) ->
    Sanitized = sanitize_chars(Path),
    case byte_size(Sanitized) > 200 of
        true ->
            Hash = crypto:hash(sha256, Path),
            HashHex =
                binary:encode_hex(binary:part(Hash, 0, 4), lowercase),
            Truncated = binary:part(Sanitized, 0, 200),
            <<Truncated/binary,"-",HashHex/binary>>;
        false ->
            Sanitized
    end.
-spec list_sessions() -> {ok, [session_summary()]}.
list_sessions() ->
    list_sessions(#{}).
-spec list_sessions(list_opts()) -> {ok, [session_summary()]}.
list_sessions(Opts) ->
    BaseDir = maps:get(config_dir, Opts, config_dir()),
    ProjectsDir = <<BaseDir/binary,"/projects">>,
    case filelib:is_dir(binary_to_list(ProjectsDir)) of
        false ->
            {ok, []};
        true ->
            CwdFilter = maps:get(cwd, Opts, undefined),
            Limit = maps:get(limit, Opts, infinity),
            Dir =
                case CwdFilter of
                    undefined ->
                        ProjectsDir;
                    Cwd ->
                        SanitizedCwd = sanitize_path(Cwd),
                        <<ProjectsDir/binary,"/",SanitizedCwd/binary>>
                end,
            {ok, Files} = collect_session_files(Dir),
            Summaries =
                lists:filtermap(fun(F) ->
                                       extract_summary(F)
                                end,
                                Files),
            Sorted =
                lists:sort(fun(A, B) ->
                                  maps:get(modified_at, A)
                                  >=
                                  maps:get(modified_at, B)
                           end,
                           Summaries),
            Limited =
                case Limit of
                    infinity ->
                        Sorted;
                    N when is_integer(N) ->
                        lists:sublist(Sorted, N)
                end,
            {ok, Limited}
    end.
-spec get_session_messages(binary()) -> {ok, [map()]} | {error, atom()}.
get_session_messages(SessionId) ->
    get_session_messages(SessionId, #{}).
-spec get_session_messages(binary(), message_opts()) ->
                              {ok, [map()]} | {error, atom()}.
get_session_messages(SessionId, Opts) ->
    BaseDir = maps:get(config_dir, Opts, config_dir()),
    ProjectsDir = <<BaseDir/binary,"/projects">>,
    case find_session_file(SessionId, ProjectsDir) of
        {ok, FilePath} ->
            parse_session_file(FilePath);
        {error, _} = Err ->
            Err
    end.
-spec find_session_file(binary(), binary()) ->
                           {ok, binary()} | {error, not_found}.
find_session_file(SessionId, ProjectsDir) ->
    Pattern =
        binary_to_list(ProjectsDir)
        ++
        "/*/" ++ binary_to_list(SessionId) ++ ".jsonl",
    case filelib:wildcard(Pattern) of
        [Path | _] ->
            {ok, unicode:characters_to_binary(Path)};
        [] ->
            {error, not_found}
    end.
-spec collect_session_files(binary()) -> {ok, [binary()]}.
collect_session_files(Dir) ->
    DirStr = binary_to_list(Dir),
    case filelib:is_dir(DirStr) of
        false ->
            {ok, []};
        true ->
            Pattern1 = DirStr ++ "/*.jsonl",
            Pattern2 = DirStr ++ "/*/*.jsonl",
            Files1 = filelib:wildcard(Pattern1),
            Files2 = filelib:wildcard(Pattern2),
            AllFiles =
                [ 
                 unicode:characters_to_binary(F) ||
                     F <- Files1 ++ Files2
                ],
            {ok, AllFiles}
    end.
-spec extract_summary(binary()) -> {true, session_summary()} | false.
extract_summary(FilePath) ->
    FilePathStr = binary_to_list(FilePath),
    case file:read_file_info(FilePathStr, [{time, posix}]) of
        {ok, #file_info{mtime = ModifiedAt}} ->
            SessionId = filename:basename(FilePathStr, ".jsonl"),
            Base =
                #{session_id => unicode:characters_to_binary(SessionId),
                  file_path => FilePath,
                  modified_at => ModifiedAt},
            case file:open(FilePathStr, [read, binary, raw]) of
                {ok, Fd} ->
                    Result =
                        case file:read(Fd, 65536) of
                            {ok, Data} ->
                                {true, enrich_summary(Base, Data)};
                            eof ->
                                {true, Base};
                            {error, _} ->
                                false
                        end,
                    _ = file:close(Fd),
                    Result;
                {error, _} ->
                    false
            end;
        {error, _} ->
            false
    end.
-spec enrich_summary(session_summary(), binary()) -> session_summary().
enrich_summary(Summary, Data) ->
    Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
    lists:foldl(fun(Line, Acc) ->
                       case safe_decode(Line) of
                           #{<<"type">> := <<"system">>,
                             <<"model">> := Model}
                               when is_binary(Model) ->
                               Acc#{model => Model};
                           #{<<"type">> := <<"system">>,
                             <<"cwd">> := Cwd}
                               when is_binary(Cwd) ->
                               Acc#{cwd => Cwd};
                           _ ->
                               Acc
                       end
                end,
                Summary, Lines).
-spec parse_session_file(binary()) -> {ok, [map()]} | {error, atom()}.
parse_session_file(FilePath) ->
    case file:read_file(binary_to_list(FilePath)) of
        {ok, Data} ->
            Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
            Messages =
                lists:filtermap(fun(Line) ->
                                       case safe_decode(Line) of
                                           Decoded when is_map(Decoded) ->
                                               {true, Decoded};
                                           _ ->
                                               false
                                       end
                                end,
                                Lines),
            Ordered = reconstruct_order(Messages),
            {ok, Ordered};
        {error, _} = Err ->
            Err
    end.
-spec reconstruct_order([map()]) -> [map()].
reconstruct_order(Messages) ->
    HasParent =
        lists:any(fun(M) ->
                         maps:is_key(<<"parentUuid">>, M)
                  end,
                  Messages),
    case HasParent of
        false ->
            Messages;
        true ->
            chain_by_parent(Messages)
    end.
-spec chain_by_parent([map()]) -> [map()].
chain_by_parent(Messages) ->
    ByUuid =
        lists:foldl(fun(M, Acc) ->
                           case maps:get(<<"uuid">>, M, undefined) of
                               undefined ->
                                   Acc;
                               Uuid ->
                                   Acc#{Uuid => M}
                           end
                    end,
                    #{},
                    Messages),
    ChildIndex =
        lists:foldl(fun(M, Acc) ->
                           case
                               maps:get(<<"parentUuid">>, M, undefined)
                           of
                               undefined ->
                                   Acc;
                               ParentId ->
                                   Existing =
                                       maps:get(ParentId, Acc, []),
                                   Acc#{ParentId => [M | Existing]}
                           end
                    end,
                    #{},
                    Messages),
    Roots =
        [ 
         M ||
             M <- Messages,
             case maps:get(<<"parentUuid">>, M, undefined) of
                 undefined ->
                     true;
                 PId ->
                     not maps:is_key(PId, ByUuid)
             end
        ],
    lists:reverse(walk_tree_acc(Roots, ChildIndex, [])).
-spec walk_tree_acc([map()], map(), [map()]) -> [map()].
walk_tree_acc([], _ChildIndex, Acc) ->
    Acc;
walk_tree_acc([Msg | Rest], ChildIndex, Acc) ->
    Uuid = maps:get(<<"uuid">>, Msg, undefined),
    Children = lists:reverse(maps:get(Uuid, ChildIndex, [])),
    Acc2 = walk_tree_acc(Children, ChildIndex, [Msg | Acc]),
    walk_tree_acc(Rest, ChildIndex, Acc2).
-spec sanitize_chars(binary()) -> binary().
sanitize_chars(Bin) ->
    << 
      <<(sanitize_char(C))/integer>> ||
          <<C>> <= Bin
    >>.
-spec sanitize_char(byte()) -> 1..255.
sanitize_char(C) when C >= $a, C =< $z ->
    C;
sanitize_char(C) when C >= $A, C =< $Z ->
    C;
sanitize_char(C) when C >= $0, C =< $9 ->
    C;
sanitize_char(_) ->
    $-.
-spec safe_decode(binary()) -> map() | undefined.
safe_decode(Line) ->
    try json:decode(Line) of
        Decoded when is_map(Decoded) ->
            Decoded;
        _ ->
            undefined
    catch
        _:_ ->
            undefined
    end.
