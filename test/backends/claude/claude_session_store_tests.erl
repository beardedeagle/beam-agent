%%%-------------------------------------------------------------------
%%% @doc EUnit tests for claude_session_store.
%%%
%%% Tests use temporary directories with synthetic JSONL files to
%%% validate path sanitization, session listing, message parsing,
%%% and chain reconstruction.
%%% @end
%%%-------------------------------------------------------------------
-module(claude_session_store_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% sanitize_path/1
%%====================================================================

sanitize_simple_path_test() ->
    ?assertEqual(<<"-Users-bob-project">>,
        claude_session_store:sanitize_path(<<"/Users/bob/project">>)).

sanitize_alphanumeric_preserved_test() ->
    ?assertEqual(<<"abc123XYZ">>,
        claude_session_store:sanitize_path(<<"abc123XYZ">>)).

sanitize_special_chars_test() ->
    ?assertEqual(<<"-home-user--my-project-">>,
        claude_session_store:sanitize_path(<<"/home/user/ my project!">>)).

sanitize_truncation_with_hash_test() ->
    %% Create a path > 200 chars
    LongPath = iolist_to_binary(lists:duplicate(250, $a)),
    Sanitized = claude_session_store:sanitize_path(LongPath),
    %% Should be 200 chars + "-" + 8 hex chars = 209
    ?assertEqual(209, byte_size(Sanitized)),
    ?assertMatch(<<_:200/binary, "-", _:8/binary>>, Sanitized).

sanitize_short_path_no_hash_test() ->
    ShortPath = <<"abc">>,
    ?assertEqual(<<"abc">>, claude_session_store:sanitize_path(ShortPath)).

%%====================================================================
%% config_dir/0
%%====================================================================

config_dir_default_test() ->
    %% When CLAUDE_CONFIG_DIR is not set, returns ~/.claude
    OldVal = os:getenv("CLAUDE_CONFIG_DIR"),
    os:unsetenv("CLAUDE_CONFIG_DIR"),
    Dir = claude_session_store:config_dir(),
    ?assert(is_binary(Dir)),
    ?assertMatch(<<_/binary>>, Dir),
    %% Restore
    case OldVal of
        false -> ok;
        V -> os:putenv("CLAUDE_CONFIG_DIR", V)
    end.

config_dir_override_test() ->
    OldVal = os:getenv("CLAUDE_CONFIG_DIR"),
    os:putenv("CLAUDE_CONFIG_DIR", "/tmp/test-claude"),
    ?assertEqual(<<"/tmp/test-claude">>,
        claude_session_store:config_dir()),
    %% Restore
    case OldVal of
        false -> os:unsetenv("CLAUDE_CONFIG_DIR");
        V -> os:putenv("CLAUDE_CONFIG_DIR", V)
    end.

%%====================================================================
%% list_sessions/1
%%====================================================================

list_sessions_empty_dir_test_() ->
    {"list_sessions returns empty list for non-existent dir",
     {setup,
      fun setup_tmp_dir/0,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              {ok, Sessions} = claude_session_store:list_sessions(
                  #{config_dir => TmpDir}),
              ?assertEqual([], Sessions)
          end
      end}}.

list_sessions_with_files_test_() ->
    {"list_sessions finds and sorts session files",
     {setup,
      fun() ->
          TmpDir = setup_tmp_dir(),
          ProjectDir = binary_to_list(TmpDir) ++ "/projects/test-project",
          ok = filelib:ensure_dir(ProjectDir ++ "/"),
          %% Create two mock session files
          write_session_file(ProjectDir ++ "/session-aaa.jsonl", [
              #{<<"type">> => <<"system">>, <<"subtype">> => <<"init">>,
                <<"content">> => <<"ready">>,
                <<"model">> => <<"claude-sonnet-4-20250514">>}
          ]),
          timer:sleep(1100), %% Ensure different mtime
          write_session_file(ProjectDir ++ "/session-bbb.jsonl", [
              #{<<"type">> => <<"system">>, <<"subtype">> => <<"init">>,
                <<"content">> => <<"ready">>,
                <<"model">> => <<"claude-haiku-4-5-20251001">>}
          ]),
          TmpDir
      end,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              {ok, Sessions} = claude_session_store:list_sessions(
                  #{config_dir => TmpDir}),
              ?assertEqual(2, length(Sessions)),
              %% Should be sorted by modified_at descending
              [First, Second] = Sessions,
              ?assert(maps:get(modified_at, First) >=
                      maps:get(modified_at, Second)),
              %% Check session IDs
              Ids = [maps:get(session_id, S) || S <- Sessions],
              ?assert(lists:member(<<"session-aaa">>, Ids)),
              ?assert(lists:member(<<"session-bbb">>, Ids))
          end
      end}}.

list_sessions_with_limit_test_() ->
    {"list_sessions respects limit option",
     {setup,
      fun() ->
          TmpDir = setup_tmp_dir(),
          ProjectDir = binary_to_list(TmpDir) ++ "/projects/test-project",
          ok = filelib:ensure_dir(ProjectDir ++ "/"),
          write_session_file(ProjectDir ++ "/s1.jsonl", [
              #{<<"type">> => <<"system">>, <<"content">> => <<"ok">>}
          ]),
          write_session_file(ProjectDir ++ "/s2.jsonl", [
              #{<<"type">> => <<"system">>, <<"content">> => <<"ok">>}
          ]),
          write_session_file(ProjectDir ++ "/s3.jsonl", [
              #{<<"type">> => <<"system">>, <<"content">> => <<"ok">>}
          ]),
          TmpDir
      end,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              {ok, Sessions} = claude_session_store:list_sessions(
                  #{config_dir => TmpDir, limit => 2}),
              ?assertEqual(2, length(Sessions))
          end
      end}}.

%%====================================================================
%% get_session_messages/2
%%====================================================================

get_session_messages_test_() ->
    {"get_session_messages parses JSONL transcript",
     {setup,
      fun() ->
          TmpDir = setup_tmp_dir(),
          ProjectDir = binary_to_list(TmpDir) ++ "/projects/test-project",
          ok = filelib:ensure_dir(ProjectDir ++ "/"),
          write_session_file(ProjectDir ++ "/test-sess-123.jsonl", [
              #{<<"type">> => <<"system">>, <<"subtype">> => <<"init">>,
                <<"content">> => <<"ready">>},
              #{<<"type">> => <<"user">>, <<"content">> => <<"hello">>,
                <<"uuid">> => <<"msg-1">>},
              #{<<"type">> => <<"assistant">>,
                <<"content">> => [#{<<"type">> => <<"text">>,
                                    <<"text">> => <<"hi there">>}],
                <<"uuid">> => <<"msg-2">>,
                <<"parentUuid">> => <<"msg-1">>},
              #{<<"type">> => <<"result">>,
                <<"result">> => <<"done">>,
                <<"uuid">> => <<"msg-3">>,
                <<"parentUuid">> => <<"msg-2">>}
          ]),
          TmpDir
      end,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              {ok, Messages} = claude_session_store:get_session_messages(
                  <<"test-sess-123">>, #{config_dir => TmpDir}),
              ?assertEqual(4, length(Messages)),
              %% First message should be system
              [First | _] = Messages,
              ?assertEqual(<<"system">>, maps:get(<<"type">>, First))
          end
      end}}.

get_session_messages_not_found_test_() ->
    {"get_session_messages returns error for missing session",
     {setup,
      fun setup_tmp_dir/0,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              Result = claude_session_store:get_session_messages(
                  <<"nonexistent">>, #{config_dir => TmpDir}),
              ?assertEqual({error, not_found}, Result)
          end
      end}}.

%%====================================================================
%% find_session_file/2
%%====================================================================

find_session_file_test_() ->
    {"find_session_file locates file across project dirs",
     {setup,
      fun() ->
          TmpDir = setup_tmp_dir(),
          ProjectDir = binary_to_list(TmpDir) ++ "/projects/some-project",
          ok = filelib:ensure_dir(ProjectDir ++ "/"),
          write_session_file(ProjectDir ++ "/target-id.jsonl", [
              #{<<"type">> => <<"system">>, <<"content">> => <<"ok">>}
          ]),
          TmpDir
      end,
      fun cleanup_tmp_dir/1,
      fun(TmpDir) ->
          fun() ->
              ProjectsDir = <<TmpDir/binary, "/projects">>,
              {ok, Path} = claude_session_store:find_session_file(
                  <<"target-id">>, ProjectsDir),
              ?assert(is_binary(Path)),
              ?assertNotEqual(nomatch,
                  binary:match(Path, <<"target-id.jsonl">>))
          end
      end}}.

%%====================================================================
%% Helpers
%%====================================================================

setup_tmp_dir() ->
    TmpBase = "/tmp/claude_store_test_" ++
        integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(TmpBase),
    ProjectsDir = TmpBase ++ "/projects",
    ok = file:make_dir(ProjectsDir),
    unicode:characters_to_binary(TmpBase).

cleanup_tmp_dir(TmpDir) ->
    os:cmd("rm -rf " ++ binary_to_list(TmpDir)).

write_session_file(Path, Messages) ->
    Lines = [iolist_to_binary(json:encode(M)) || M <- Messages],
    Content = iolist_to_binary(lists:join(<<"\n">>, Lines)),
    ok = file:write_file(Path, <<Content/binary, "\n">>).
