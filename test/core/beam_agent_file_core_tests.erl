%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_file_core (file search and read).
%%%
%%% Tests cover:
%%%   - find_text/2,3: regex search, invalid pattern, case insensitive
%%%   - find_files/1,2: glob file listing
%%%   - find_symbols/1,2: symbol definition search
%%%   - file_list/1,2: directory listing, invalid directory
%%%   - file_read/1,2: read existing file, missing file
%%%   - file_status/0,1: cwd and source fields
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_file_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

tmp_dir() ->
    Dir = <<"/tmp/beam_agent_file_core_test">>,
    DirStr = unicode:characters_to_list(Dir),
    filelib:ensure_dir(filename:join(DirStr, "dummy")),
    file:make_dir(DirStr),
    Dir.

write_tmp_file(Dir, Name, Content) ->
    Path = filename:join(unicode:characters_to_list(Dir),
                         unicode:characters_to_list(Name)),
    ok = file:write_file(Path, Content),
    unicode:characters_to_binary(Path).

cleanup_tmp() ->
    os:cmd("rm -rf /tmp/beam_agent_file_core_test").

%%====================================================================
%% find_text/2 tests
%%====================================================================

find_text_matches_pattern_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"search.txt">>, <<"alpha\nbeta\ngamma\n">>),
    {ok, Results} = beam_agent_file_core:find_text(<<"beta">>, #{cwd => Dir}),
    ?assert(length(Results) >= 1),
    [First | _] = Results,
    ?assert(is_map(First)),
    ?assert(binary:match(maps:get(content, First), <<"beta">>) =/= nomatch),
    ?assert(is_integer(maps:get(line, First))),
    cleanup_tmp().

find_text_no_match_returns_empty_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"empty_search.txt">>, <<"nothing here\n">>),
    {ok, Results} = beam_agent_file_core:find_text(<<"zzzzz">>, #{cwd => Dir}),
    ?assertEqual([], Results),
    cleanup_tmp().

find_text_invalid_regex_returns_error_test() ->
    {error, {invalid_pattern, _Reason, _Pos}} =
        beam_agent_file_core:find_text(<<"[invalid">>, #{}).

%%====================================================================
%% find_text/3 tests
%%====================================================================

find_text_with_glob_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"code.erl">>, <<"-module(test).\n">>),
    write_tmp_file(Dir, <<"notes.txt">>, <<"-module(fake).\n">>),
    {ok, Results} = beam_agent_file_core:find_text(
        <<"-module">>, <<"*.erl">>, #{cwd => Dir}),
    Paths = [maps:get(path, R) || R <- Results],
    ?assert(lists:any(fun(P) ->
        binary:match(P, <<"code.erl">>) =/= nomatch
    end, Paths)),
    ?assertNot(lists:any(fun(P) ->
        binary:match(P, <<"notes.txt">>) =/= nomatch
    end, Paths)),
    cleanup_tmp().

find_text_case_insensitive_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"case.txt">>, <<"Hello World\n">>),
    {ok, Results} = beam_agent_file_core:find_text(
        <<"hello">>, #{cwd => Dir, case_sensitive => false}),
    ?assert(length(Results) >= 1),
    cleanup_tmp().

find_text_case_sensitive_no_match_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"case2.txt">>, <<"Hello World\n">>),
    {ok, Results} = beam_agent_file_core:find_text(
        <<"hello">>, #{cwd => Dir, case_sensitive => true}),
    ?assertEqual([], Results),
    cleanup_tmp().

%%====================================================================
%% find_files/1,2 tests
%%====================================================================

find_files_returns_entries_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"a.txt">>, <<"aaa">>),
    write_tmp_file(Dir, <<"b.txt">>, <<"bbb">>),
    {ok, Entries} = beam_agent_file_core:find_files(#{cwd => Dir}),
    ?assert(length(Entries) >= 2),
    [E | _] = Entries,
    ?assert(maps:is_key(path, E)),
    ?assert(maps:is_key(type, E)),
    cleanup_tmp().

find_files_with_glob_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"keep.erl">>, <<"ok">>),
    write_tmp_file(Dir, <<"skip.txt">>, <<"ok">>),
    {ok, Entries} = beam_agent_file_core:find_files(<<"*.erl">>, #{cwd => Dir}),
    Paths = [maps:get(path, E) || E <- Entries],
    ?assert(lists:any(fun(P) ->
        binary:match(P, <<"keep.erl">>) =/= nomatch
    end, Paths)),
    ?assertNot(lists:any(fun(P) ->
        binary:match(P, <<"skip.txt">>) =/= nomatch
    end, Paths)),
    cleanup_tmp().

find_files_empty_dir_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    {ok, Entries} = beam_agent_file_core:find_files(#{cwd => Dir}),
    ?assertEqual([], Entries),
    cleanup_tmp().

%%====================================================================
%% find_symbols/1,2 tests
%%====================================================================

find_symbols_erlang_function_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"mod.erl">>,
        <<"-module(mod).\nmy_func(X) -> X.\n">>),
    {ok, Results} = beam_agent_file_core:find_symbols(<<"my_func">>, #{cwd => Dir}),
    ?assert(length(Results) >= 1),
    cleanup_tmp().

find_symbols_no_query_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"defs.erl">>,
        <<"-spec start() -> ok.\nstart() -> ok.\n">>),
    {ok, Results} = beam_agent_file_core:find_symbols(#{cwd => Dir}),
    ?assert(length(Results) >= 1),
    cleanup_tmp().

%%====================================================================
%% file_list/1 tests
%%====================================================================

file_list_valid_directory_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"listed.txt">>, <<"data">>),
    {ok, Entries} = beam_agent_file_core:file_list(Dir),
    ?assert(length(Entries) >= 1),
    [E | _] = Entries,
    ?assert(maps:is_key(path, E)),
    ?assert(maps:is_key(type, E)),
    cleanup_tmp().

file_list_with_opts_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"opt.txt">>, <<"data">>),
    {ok, Entries} = beam_agent_file_core:file_list(Dir, #{}),
    ?assert(length(Entries) >= 1),
    cleanup_tmp().

file_list_invalid_directory_test() ->
    {error, {list_dir_failed, _, _}} =
        beam_agent_file_core:file_list(<<"/tmp/beam_agent_no_such_dir_xyzzy">>).

file_list_entries_sorted_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    write_tmp_file(Dir, <<"z.txt">>, <<"z">>),
    write_tmp_file(Dir, <<"a.txt">>, <<"a">>),
    write_tmp_file(Dir, <<"m.txt">>, <<"m">>),
    {ok, Entries} = beam_agent_file_core:file_list(Dir),
    Paths = [maps:get(path, E) || E <- Entries],
    ?assertEqual(Paths, lists:sort(Paths)),
    cleanup_tmp().

%%====================================================================
%% file_read/1,2 tests
%%====================================================================

file_read_existing_file_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    Path = write_tmp_file(Dir, <<"readable.txt">>, <<"file content here">>),
    {ok, Result} = beam_agent_file_core:file_read(Path),
    ?assertEqual(Path, maps:get(path, Result)),
    ?assertEqual(<<"file content here">>, maps:get(content, Result)),
    cleanup_tmp().

file_read_with_opts_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    Path = write_tmp_file(Dir, <<"opts.txt">>, <<"opts content">>),
    {ok, Result} = beam_agent_file_core:file_read(Path, #{}),
    ?assertEqual(<<"opts content">>, maps:get(content, Result)),
    cleanup_tmp().

file_read_missing_file_test() ->
    {error, {read_failed, _, _}} =
        beam_agent_file_core:file_read(<<"/tmp/beam_agent_no_such_file_xyzzy.txt">>).

file_read_result_has_required_keys_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    Path = write_tmp_file(Dir, <<"keys.txt">>, <<"k">>),
    {ok, Result} = beam_agent_file_core:file_read(Path),
    ?assert(maps:is_key(path, Result)),
    ?assert(maps:is_key(content, Result)),
    cleanup_tmp().

file_read_content_is_binary_test() ->
    cleanup_tmp(),
    Dir = tmp_dir(),
    Path = write_tmp_file(Dir, <<"bin.txt">>, <<"binary data">>),
    {ok, Result} = beam_agent_file_core:file_read(Path),
    ?assert(is_binary(maps:get(content, Result))),
    cleanup_tmp().

%%====================================================================
%% file_status/0,1 tests
%%====================================================================

file_status_returns_ok_test() ->
    {ok, Status} = beam_agent_file_core:file_status(),
    ?assert(maps:is_key(cwd, Status)),
    ?assert(maps:is_key(source, Status)),
    ?assert(maps:is_key(files, Status)).

file_status_cwd_is_binary_test() ->
    {ok, Status} = beam_agent_file_core:file_status(),
    ?assert(is_binary(maps:get(cwd, Status))).

file_status_source_is_atom_test() ->
    {ok, Status} = beam_agent_file_core:file_status(),
    Source = maps:get(source, Status),
    ?assert(Source =:= git orelse Source =:= filesystem).

file_status_files_is_list_test() ->
    {ok, Status} = beam_agent_file_core:file_status(),
    ?assert(is_list(maps:get(files, Status))).

file_status_with_cwd_opt_test() ->
    {ok, Status} = beam_agent_file_core:file_status(#{cwd => <<"/tmp">>}),
    ?assert(maps:is_key(cwd, Status)),
    ?assert(maps:is_key(source, Status)),
    ?assert(maps:is_key(files, Status)).
