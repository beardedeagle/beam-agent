defmodule BeamAgent.Search do
  @moduledoc """
  Fuzzy file search for the BeamAgent SDK.

  This module provides fuzzy file search operations -- one-shot searches and
  stateful search sessions with cached file listings -- across all five agentic
  coder backends (Claude, Codex, Gemini, OpenCode, Copilot).

  Stateful search sessions cache file listings from root directories and reuse
  the cache for fast incremental searches, making them ideal for typeahead UIs.

  ## When to use directly vs through `BeamAgent`

  Most callers interact with search through `BeamAgent`. Use this module
  directly when you need focused access to search operations -- for example,
  in a file picker with typeahead, a project-wide file finder, or a search
  session manager that tracks multiple concurrent searches.

  ## Quick example

  ```elixir
  # One-shot fuzzy search:
  {:ok, matches} = BeamAgent.Search.fuzzy(session, "sess_eng")

  # Stateful search session for typeahead:
  {:ok, _} = BeamAgent.Search.session_start(session, "search_001", ["/project/src"])
  {:ok, matches} = BeamAgent.Search.session_update(session, "search_001", "agent")
  {:ok, _} = BeamAgent.Search.session_stop(session, "search_001")
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_search` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying search data is stored in ETS tables managed by
  `:beam_agent_search_core`.

  See also: `BeamAgent`, `BeamAgent.File`.
  """

  @doc """
  Fuzzy-search for files by name in the session's project.

  Convenience wrapper that calls `fuzzy/3` with empty options.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- partial file name to match (e.g., `"sess_eng"` matches
    `beam_agent_session_engine.erl`).

  ## Returns

  - `{:ok, matches}` sorted by score descending.
  """
  @spec fuzzy(pid(), binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate fuzzy(session, query), to: :beam_agent_search

  @doc """
  Fuzzy-search for files by name with options.

  Returns up to `:max_results` matches sorted by score descending. Each
  match is a map with `:path`, `:score`, and `:name` keys. The scoring
  algorithm rewards consecutive matches and word-boundary hits.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- partial file name to match.
  - `opts` -- search options map. Optional keys:
    - `:cwd` -- base directory to search under
    - `:max_results` -- maximum matches to return (default 50)
    - `:roots` -- list of root directories to search

  ## Returns

  - `{:ok, matches}` or `{:error, reason}`.
  """
  @spec fuzzy(pid(), binary(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate fuzzy(session, query, opts), to: :beam_agent_search

  @doc """
  Start a stateful fuzzy file search session.

  Creates a search session identified by `search_session_id` that caches
  file listings from `roots`. Subsequent calls to
  `session_update/3` reuse this cache for faster
  incremental searches (useful for typeahead UIs). The session persists
  in ETS until explicitly stopped with `session_stop/2`.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary identifier for the search session.
  - `roots` -- list of root directories to index.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec session_start(pid(), binary(), [binary()]) :: {:ok, term()} | {:error, term()}
  defdelegate session_start(session, search_session_id, roots), to: :beam_agent_search

  @doc """
  Update a search session with a new query string.

  Runs the fuzzy scoring algorithm against the roots cached in the
  session identified by `search_session_id`. Returns the new set of matches.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary search session identifier.
  - `query` -- new query string.

  ## Returns

  - `{:ok, matches}` or `{:error, :not_found}`.
  """
  @spec session_update(pid(), binary(), binary()) :: {:ok, [map()]} | {:error, :not_found}
  defdelegate session_update(session, search_session_id, query), to: :beam_agent_search

  @doc """
  Stop and clean up a fuzzy file search session.

  Removes the session identified by `search_session_id` from ETS, freeing
  its cached file listing and results. Safe to call even if the session
  has already been stopped.

  ## Parameters

  - `session` -- pid of a running session.
  - `search_session_id` -- binary search session identifier.

  ## Returns

  - `{:ok, result}` or `{:error, reason}`.
  """
  @spec session_stop(pid(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate session_stop(session, search_session_id), to: :beam_agent_search
end
