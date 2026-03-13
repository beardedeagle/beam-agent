defmodule BeamAgent.File do
  @moduledoc """
  File operations for the BeamAgent SDK.

  This module provides file discovery and inspection operations -- text search,
  file search, symbol search, directory listing, file reading, and version
  control status -- across all five agentic coder backends (Claude, Codex,
  Gemini, OpenCode, Copilot).

  ## When to use directly vs through `BeamAgent`

  Most callers interact with files through `BeamAgent`. Use this module
  directly when you need focused access to file operations -- for example,
  in a file browser UI, a code search tool, or a version control status
  dashboard.

  ## Quick example

  ```elixir
  # Search for text in files:
  {:ok, matches} = BeamAgent.File.find_text(session, "TODO")
  for m <- matches, do: IO.puts("\#{m.path}:\#{m.line}: \#{m.content}")

  # Find files by pattern:
  {:ok, files} = BeamAgent.File.find_files(session, %{pattern: "*.erl"})

  # List directory contents:
  {:ok, entries} = BeamAgent.File.list(session, "/src")

  # Read a file:
  {:ok, content} = BeamAgent.File.read(session, "/src/main.erl")

  # Check version control status:
  {:ok, status} = BeamAgent.File.status(session)
  ```

  ## Architecture deep dive

  This module is a thin Elixir facade that `defdelegate`s every call to the
  Erlang `:beam_agent_file` module. Zero business logic, zero state, zero
  processes live here -- the Erlang module owns the implementation. The
  underlying file operations are provided by `:beam_agent_file_core`.

  See also: `BeamAgent`, `BeamAgent.Search`, `BeamAgent.Config`.
  """

  @doc """
  Search for text matching `pattern` in the session's working directory.

  Performs a grep-like search across files under the session's configured
  working directory. `pattern` is a binary string (not a regex). Returns a
  list of match maps, each containing the file path, line number, and
  matching line content.

  ## Parameters

  - `session` -- pid of a running session.
  - `pattern` -- binary search pattern.

  ## Returns

  - `{:ok, matches}` or `{:error, reason}`.

  ## Examples

      {:ok, matches} = BeamAgent.File.find_text(session, "TODO")
      for m <- matches do
        IO.puts("\#{m.path}:\#{m.line}: \#{m.content}")
      end
  """
  @spec find_text(pid(), binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate find_text(session, pattern), to: :beam_agent_file

  @doc """
  Find files matching a pattern in the session's working directory.

  ## Parameters

  - `session` -- pid of a running session.
  - `opts` -- search options map. Common keys:
    - `:pattern` -- a glob or name substring to match (e.g., `"*.erl"`)
    - `:max_results` -- maximum number of files to return
    - `:include_hidden` -- whether to include dot-files (default `false`)

  ## Returns

  - `{:ok, files}` or `{:error, reason}`.

  ## Examples

      {:ok, files} = BeamAgent.File.find_files(session, %{pattern: "*.erl"})
      for f <- files, do: IO.puts(f.path)
  """
  @spec find_files(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate find_files(session, opts), to: :beam_agent_file

  @doc """
  Search for code symbols matching `query` in the session's project.

  Searches for function, module, type, and record definitions whose
  names match `query`. Returns a list of symbol maps with keys such as
  `:name`, `:kind`, `:path`, and `:line`.

  ## Parameters

  - `session` -- pid of a running session.
  - `query` -- binary symbol name query.

  ## Returns

  - `{:ok, symbols}` or `{:error, reason}`.
  """
  @spec find_symbols(pid(), binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate find_symbols(session, query), to: :beam_agent_file

  @doc """
  List files and directories at the given path.

  Returns directory entries as a list of maps. Each entry includes
  the `:name`, `:type` (file or directory), and `:size` where available.
  `path` is resolved relative to the session's working directory when
  it is not absolute.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary directory path.

  ## Returns

  - `{:ok, entries}` or `{:error, reason}`.
  """
  @spec list(pid(), binary()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list(session, path), to: :beam_agent_file

  @doc """
  Read the contents of a file at the given path.

  Returns the file content as a binary. `path` is resolved relative to
  the session's working directory when it is not absolute.

  ## Parameters

  - `session` -- pid of a running session.
  - `path` -- binary file path.

  ## Returns

  - `{:ok, content}` or `{:error, :enoent}` if the file does not exist.
  """
  @spec read(pid(), binary()) :: {:ok, binary()} | {:error, :enoent | term()}
  defdelegate read(session, path), to: :beam_agent_file

  @doc """
  Get the version-control status of files in the session's project.

  Returns a summary of file modifications, additions, and deletions
  relative to the project's version control baseline (typically git).

  ## Parameters

  - `session` -- pid of a running session.

  ## Returns

  - `{:ok, status}` or `{:error, reason}`.
  """
  @spec status(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate status(session), to: :beam_agent_file
end
