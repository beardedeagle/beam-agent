%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_search_core (fuzzy file search & sessions).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Fuzzy file search (matches sorted by score, empty query)
%%%   - Session start (creates session with required keys)
%%%   - Session update (updates query/results, not_found for missing)
%%%   - Session stop (removes session, idempotent)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_search_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TMP_DIR, "/tmp/beam_agent_search_core_test").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = beam_agent_search_core:ensure_tables(),
    ok = beam_agent_search_core:ensure_tables(),
    ok = beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear().

clear_removes_all_data_test() ->
    beam_agent_search_core:ensure_tables(),
    Session = <<"sess-clear">>,
    {ok, _} = beam_agent_search_core:session_start(Session, <<"search-1">>, [<<"/tmp">>]),
    ok = beam_agent_search_core:clear(),
    %% Session should be gone after clear
    ?assertEqual({error, not_found},
        beam_agent_search_core:session_update(Session, <<"search-1">>, <<"q">>)).

%%====================================================================
%% Fuzzy file search tests
%%====================================================================

fuzzy_file_search_returns_matches_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<"foo">>, Roots, #{}),
    ?assert(length(Matches) >= 1),
    %% foo_bar.erl should match "foo" with a higher score than baz_qux.erl
    FooPaths = [M || M <- Matches, maps:get(name, M) =:= <<"foo_bar.erl">>],
    ?assertEqual(1, length(FooPaths)),
    [FooMatch] = FooPaths,
    ?assert(maps:get(score, FooMatch) > 0.0),
    ?assert(is_binary(maps:get(path, FooMatch))),
    ?assert(is_binary(maps:get(name, FooMatch))),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

fuzzy_file_search_sorted_by_score_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<"bar">>, Roots, #{}),
    ?assert(length(Matches) >= 1),
    Scores = [maps:get(score, M) || M <- Matches],
    ?assertEqual(Scores, lists:sort(fun(A, B) -> A >= B end, Scores)),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

fuzzy_file_search_empty_query_matches_all_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<>>, Roots, #{}),
    %% Empty query should match all files at minimum score
    ?assertEqual(2, length(Matches)),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

fuzzy_file_search_no_matches_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<"zzzznotafile">>, Roots, #{}),
    ?assertEqual([], Matches),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

fuzzy_file_search_with_opts_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Opts = #{roots => [list_to_binary(?TMP_DIR)]},
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<"foo">>, Opts),
    ?assert(length(Matches) >= 1),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

fuzzy_file_search_max_results_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, Matches} = beam_agent_search_core:fuzzy_file_search(<<>>, Roots, #{max_results => 1}),
    ?assertEqual(1, length(Matches)),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

%%====================================================================
%% Session start tests
%%====================================================================

session_start_creates_session_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Session = <<"sess-start-1">>,
    SearchId = <<"search-start-1">>,
    Roots = [<<"/tmp">>],
    {ok, Entry} = beam_agent_search_core:session_start(Session, SearchId, Roots),
    ?assertEqual(SearchId, maps:get(id, Entry)),
    ?assertEqual(Session, maps:get(session, Entry)),
    ?assertEqual(Roots, maps:get(roots, Entry)),
    ?assertEqual(<<>>, maps:get(last_query, Entry)),
    ?assertEqual([], maps:get(last_results, Entry)),
    ?assert(is_integer(maps:get(created_at, Entry))),
    beam_agent_search_core:clear().

session_start_with_pid_session_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Session = self(),
    SearchId = <<"search-pid-1">>,
    Roots = [<<"/tmp">>],
    {ok, Entry} = beam_agent_search_core:session_start(Session, SearchId, Roots),
    ?assertEqual(Session, maps:get(session, Entry)),
    ?assertEqual(SearchId, maps:get(id, Entry)),
    beam_agent_search_core:clear().

%%====================================================================
%% Session update tests
%%====================================================================

session_update_runs_search_test() ->
    setup_tmp_dir(),
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Session = <<"sess-update-1">>,
    SearchId = <<"search-update-1">>,
    Roots = [list_to_binary(?TMP_DIR)],
    {ok, _} = beam_agent_search_core:session_start(Session, SearchId, Roots),
    {ok, Matches} = beam_agent_search_core:session_update(Session, SearchId, <<"foo">>),
    ?assert(is_list(Matches)),
    ?assert(length(Matches) >= 1),
    cleanup_tmp_dir(),
    beam_agent_search_core:clear().

session_update_not_found_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Result = beam_agent_search_core:session_update(<<"no-sess">>, <<"no-search">>, <<"q">>),
    ?assertEqual({error, not_found}, Result),
    beam_agent_search_core:clear().

%%====================================================================
%% Session stop tests
%%====================================================================

session_stop_removes_session_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Session = <<"sess-stop-1">>,
    SearchId = <<"search-stop-1">>,
    {ok, _} = beam_agent_search_core:session_start(Session, SearchId, [<<"/tmp">>]),
    ok = beam_agent_search_core:session_stop(Session, SearchId),
    %% Updating a stopped session should return not_found
    ?assertEqual({error, not_found},
        beam_agent_search_core:session_update(Session, SearchId, <<"q">>)),
    beam_agent_search_core:clear().

session_stop_idempotent_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    Session = <<"sess-stop-idem">>,
    SearchId = <<"search-stop-idem">>,
    {ok, _} = beam_agent_search_core:session_start(Session, SearchId, [<<"/tmp">>]),
    ok = beam_agent_search_core:session_stop(Session, SearchId),
    ok = beam_agent_search_core:session_stop(Session, SearchId),
    beam_agent_search_core:clear().

session_stop_nonexistent_test() ->
    beam_agent_search_core:ensure_tables(),
    beam_agent_search_core:clear(),
    ok = beam_agent_search_core:session_stop(<<"ghost-sess">>, <<"ghost-search">>),
    beam_agent_search_core:clear().

%%====================================================================
%% Helpers
%%====================================================================

setup_tmp_dir() ->
    file:make_dir(?TMP_DIR),
    file:write_file(?TMP_DIR ++ "/foo_bar.erl", <<"test">>),
    file:write_file(?TMP_DIR ++ "/baz_qux.erl", <<"test">>).

cleanup_tmp_dir() ->
    file:delete(?TMP_DIR ++ "/foo_bar.erl"),
    file:delete(?TMP_DIR ++ "/baz_qux.erl"),
    file:del_dir(?TMP_DIR).
