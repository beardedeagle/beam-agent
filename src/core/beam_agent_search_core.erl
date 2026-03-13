-module(beam_agent_search_core).
-moduledoc false.

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Search
    fuzzy_file_search/2,
    fuzzy_file_search/3,
    %% Sessions
    session_start/3,
    session_update/3,
    session_stop/2
]).

-export_type([
    search_match/0,
    search_session/0,
    search_opts/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type search_match() :: #{
    path  := binary(),
    score := float(),
    name  := binary()
}.

-type search_session() :: #{
    id           := binary(),
    session      := pid() | binary(),
    roots        := [binary()],
    last_query   := binary(),
    last_results := [search_match()],
    created_at   := integer()
}.

-type search_opts() :: #{
    cwd         => binary(),
    max_results => pos_integer(),
    roots       => [binary()]
}.

-define(SESSIONS_TABLE, beam_agent_search_sessions).
-define(DEFAULT_MAX_RESULTS, 50).
-define(MAX_WALK_DEPTH, 10).
-define(EXCLUDED_DIRS, [<<".git">>, <<"_build">>, <<"node_modules">>, <<"deps">>]).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the search sessions ETS table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SESSIONS_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Delete all search session data.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?SESSIONS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Fuzzy File Search
%%--------------------------------------------------------------------

-doc """
Fuzzy search for file names matching Query.

Walks the filesystem under the `roots` or `cwd` option (defaulting to the
process working directory). Returns up to `max_results` matches (default 50)
sorted by score descending.
""".
-spec fuzzy_file_search(binary(), search_opts()) ->
    {ok, [search_match()]}.
fuzzy_file_search(Query, Opts) when is_binary(Query), is_map(Opts) ->
    Roots = resolve_roots(Opts),
    fuzzy_file_search(Query, Roots, Opts).

-doc """
Fuzzy search for file names matching Query under the given Roots.
""".
-spec fuzzy_file_search(binary(), [binary()], search_opts()) ->
    {ok, [search_match()]}.
fuzzy_file_search(Query, Roots, Opts)
  when is_binary(Query), is_list(Roots), is_map(Opts) ->
    MaxResults = maps:get(max_results, Opts, ?DEFAULT_MAX_RESULTS),
    Files = walk_files(Roots, ?MAX_WALK_DEPTH),
    Matches = score_and_filter(Query, Files),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(score, A) >= maps:get(score, B)
    end, Matches),
    Limited = lists:sublist(Sorted, MaxResults),
    {ok, Limited}.

%%--------------------------------------------------------------------
%% Sessions
%%--------------------------------------------------------------------

-doc """
Start a search session.

Stores the session with its roots in ETS under key `{SessionKey, SearchSessionId}`.
""".
-spec session_start(pid() | binary(), binary(), [binary()]) ->
    {ok, search_session()}.
session_start(Session, SearchSessionId, Roots)
  when is_binary(SearchSessionId), is_list(Roots) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    SKey = session_key(Session),
    Entry = #{
        id           => SearchSessionId,
        session      => Session,
        roots        => Roots,
        last_query   => <<>>,
        last_results => [],
        created_at   => Now
    },
    beam_agent_ets:insert(?SESSIONS_TABLE, {{SKey, SearchSessionId}, Entry}),
    {ok, Entry}.

-doc """
Update a search session with a new query.

Runs fuzzy search against the stored roots and caches the results.
Returns `{error, not_found}` if the session does not exist.
""".
-spec session_update(pid() | binary(), binary(), binary()) ->
    {ok, [search_match()]} | {error, not_found}.
session_update(Session, SearchSessionId, Query)
  when is_binary(SearchSessionId), is_binary(Query) ->
    ensure_tables(),
    SKey = session_key(Session),
    EtsKey = {SKey, SearchSessionId},
    case ets:lookup(?SESSIONS_TABLE, EtsKey) of
        [{_, Entry}] ->
            Roots = maps:get(roots, Entry),
            {ok, Matches} = fuzzy_file_search(Query, Roots, #{}),
            Updated = Entry#{last_query => Query, last_results => Matches},
            beam_agent_ets:insert(?SESSIONS_TABLE, {EtsKey, Updated}),
            {ok, Matches};
        [] ->
            {error, not_found}
    end.

-doc "Stop and clean up a search session.".
-spec session_stop(pid() | binary(), binary()) -> ok.
session_stop(Session, SearchSessionId)
  when is_binary(SearchSessionId) ->
    ensure_tables(),
    SKey = session_key(Session),
    beam_agent_ets:delete(?SESSIONS_TABLE, {SKey, SearchSessionId}),
    ok.

%%--------------------------------------------------------------------
%% Internal: Fuzzy Scoring
%%--------------------------------------------------------------------

%% Score Query against each file path. Zero-score entries are excluded.
-spec score_and_filter(binary(), [binary()]) -> [search_match()].
score_and_filter(Query, Files) ->
    QLower = string:lowercase(Query),
    lists:filtermap(fun(Path) ->
        Name = filename_part(Path),
        Score = fuzzy_score(QLower, string:lowercase(Name)),
        case Score > 0.0 of
            true  -> {true, #{path => Path, score => Score, name => Name}};
            false -> false
        end
    end, Files).

%% Compute a fuzzy match score between Query and Candidate (both lowercase).
%% Returns 0.0 when Query chars do not appear in Candidate in order.
%% Returns up to 1.0 for an exact match.
-spec fuzzy_score(binary(), binary()) -> float().
fuzzy_score(<<>>, _Candidate) ->
    %% Empty query matches everything at minimum score
    0.1;
fuzzy_score(Query, Candidate) when is_binary(Query), is_binary(Candidate) ->
    fuzzy_score_chars(binary_to_list(Query), binary_to_list(Candidate)).

%% Core scoring: carries previous character for accurate word-boundary detection.
-spec fuzzy_score_chars([byte()], [byte()]) -> float().
fuzzy_score_chars(QChars, CChars) ->
    case match_chars_with_prev(QChars, CChars, 0, 0.0, 0.0, $\0) of
        no_match ->
            0.0;
        {Consec, Boundary, Matched} ->
            QLen = length(QChars),
            CLen = max(length(CChars), 1),
            BaseScore    = Matched / QLen,
            ConsecScore  = Consec / QLen,
            BoundScore   = Boundary / QLen,
            LengthPenalty = 1.0 - (min(CLen - QLen, CLen) / (CLen + 1)),
            Raw = BaseScore * 0.4
                + ConsecScore * 0.35
                + BoundScore  * 0.15
                + LengthPenalty * 0.10,
            min(Raw, 1.0)
    end.

-spec match_chars_with_prev(
    [byte()], [byte()],
    non_neg_integer(), float(), float(),
    byte()
) -> {non_neg_integer(), float(), 1} | no_match.
match_chars_with_prev([], _CRest, Consec, Boundary, _Prev, _PrevC) ->
    {Consec, Boundary, 1};
match_chars_with_prev(_QRest, [], _Consec, _Boundary, _Prev, _PrevC) ->
    no_match;
match_chars_with_prev([QH | QT] = Query, [CH | CT],
                      Consec, Boundary, Prev, PrevC) ->
    case QH =:= CH of
        true ->
            ConsecInc = case Prev > 0 of true -> 1; false -> 0 end,
            BoundInc  = case is_word_boundary(PrevC) of
                            true  -> 1.0;
                            false -> 0.0
                        end,
            case match_chars_with_prev(QT, CT, Consec + ConsecInc,
                                       Boundary + BoundInc, 1.0, CH) of
                no_match ->
                    match_chars_with_prev(Query, CT, 0, Boundary, 0.0, CH);
                Result ->
                    Result
            end;
        false ->
            match_chars_with_prev(Query, CT, 0, Boundary, 0.0, CH)
    end.

-spec is_word_boundary(byte()) -> boolean().
is_word_boundary($/) -> true;
is_word_boundary($\\) -> true;
is_word_boundary($.) -> true;
is_word_boundary($_) -> true;
is_word_boundary($-) -> true;
is_word_boundary($\0) -> true;   %% start of string
is_word_boundary(_)   -> false.

%%--------------------------------------------------------------------
%% Internal: File Walking
%%--------------------------------------------------------------------

%% Walk Roots up to MaxDepth levels deep. Returns a flat list of file paths
%% (binaries). Excludes known noise directories (.git, _build, etc.).
-spec walk_files([binary()], non_neg_integer()) -> [binary()].
walk_files(Roots, MaxDepth) ->
    lists:flatmap(fun(Root) ->
        walk_dir(Root, MaxDepth)
    end, Roots).

-spec walk_dir(binary(), non_neg_integer()) -> [binary()].
walk_dir(_Dir, 0) ->
    [];
walk_dir(Dir, Depth) when is_binary(Dir) ->
    DirStr = binary_to_list(Dir),
    case file:list_dir(DirStr) of
        {ok, Entries} ->
            lists:flatmap(fun(Entry) ->
                EntryBin = list_to_binary(Entry),
                FullPath = join_path(Dir, EntryBin),
                FullPathStr = binary_to_list(FullPath),
                case is_excluded(EntryBin) of
                    true ->
                        [];
                    false ->
                        case filelib:is_dir(FullPathStr) of
                            true  -> walk_dir(FullPath, Depth - 1);
                            false -> [FullPath]
                        end
                end
            end, Entries);
        {error, _} ->
            []
    end.

-spec is_excluded(binary()) -> boolean().
is_excluded(Name) ->
    lists:member(Name, ?EXCLUDED_DIRS).

-spec join_path(binary(), binary()) -> binary().
join_path(Dir, Name) ->
    case binary:last(Dir) of
        $/ -> <<Dir/binary, Name/binary>>;
        _  -> <<Dir/binary, "/", Name/binary>>
    end.

%% Extract the base file name (last component after the final slash).
-spec filename_part(binary()) -> binary().
filename_part(Path) ->
    case binary:split(Path, <<"/">>, [global]) of
        Parts when length(Parts) > 1 ->
            lists:last(Parts);
        _ ->
            Path
    end.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec resolve_roots(search_opts()) -> [binary()].
resolve_roots(Opts) ->
    case maps:find(roots, Opts) of
        {ok, Roots} when is_list(Roots), Roots =/= [] ->
            Roots;
        _ ->
            case maps:find(cwd, Opts) of
                {ok, Cwd} when is_binary(Cwd) -> [Cwd];
                _ -> [cwd_binary()]
            end
    end.

-spec cwd_binary() -> binary().
cwd_binary() ->
    case file:get_cwd() of
        {ok, Cwd} -> list_to_binary(Cwd);
        {error, _} -> <<".">>
    end.

-spec session_key(pid() | binary()) -> pid() | binary().
session_key(Session) when is_pid(Session) -> Session;
session_key(Session) when is_binary(Session) -> Session.
