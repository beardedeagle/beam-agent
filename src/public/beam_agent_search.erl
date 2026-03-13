-module(beam_agent_search).
-moduledoc """
Public API for fuzzy file search.

This module provides fuzzy filename matching and stateful search sessions
for typeahead-style file navigation. Every function uses native-first
routing with universal fallbacks via beam_agent_search_core.

This module is a pure delegation layer — it holds no state, no processes,
and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Matches} = beam_agent_search:fuzzy(Session, <<"sess_eng">>),
[io:format("~s (~.2f)~n", [maps:get(path, M), maps:get(score, M)]) || M <- Matches].
```

## See Also

  - beam_agent_search_core: universal fallback implementations
  - beam_agent: lifecycle entry point
""".

-export([
    fuzzy/2,
    fuzzy/3,
    session_start/3,
    session_update/3,
    session_stop/2
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Fuzzy-search for files by name in the session's project.".
-spec fuzzy(pid(), binary()) -> {ok, term()} | {error, term()}.
fuzzy(Session, Query) ->
    fuzzy(Session, Query, #{}).

-doc "Fuzzy-search for files by name with options.".
-spec fuzzy(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
fuzzy(Session, Query, Opts) ->
    beam_agent_core:native_or(Session, fuzzy_file_search, [Query, Opts], fun() ->
        beam_agent_search_core:fuzzy_file_search(Query, Opts)
    end).

-doc "Start a stateful fuzzy file search session.".
-spec session_start(pid(), binary(), [term()]) -> {ok, term()} | {error, term()}.
session_start(Session, SearchSessionId, Roots) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_start,
              [SearchSessionId, Roots], fun() ->
        beam_agent_search_core:session_start(Session, SearchSessionId, Roots)
    end).

-doc "Update a search session with a new query string.".
-spec session_update(pid(), binary(), binary()) -> {ok, term()} | {error, term()}.
session_update(Session, SearchSessionId, Query) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_update,
              [SearchSessionId, Query], fun() ->
        beam_agent_search_core:session_update(Session, SearchSessionId, Query)
    end).

-doc "Stop and clean up a fuzzy file search session.".
-spec session_stop(pid(), binary()) -> {ok, term()} | {error, term()}.
session_stop(Session, SearchSessionId) ->
    beam_agent_core:native_or(Session, fuzzy_file_search_session_stop,
              [SearchSessionId], fun() ->
        beam_agent_search_core:session_stop(Session, SearchSessionId),
        {ok, beam_agent_core:with_universal_source(Session, #{
            status => stopped,
            search_session_id => SearchSessionId})}
    end).
