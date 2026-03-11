defmodule BeamAgent.Todo do
  @moduledoc """
  Todo tracking helpers for BeamAgent message streams.

  This module extracts, filters, and summarises todo items from the message
  history produced by any agentic coder backend. Backends emit structured todo
  lists as part of their message streams; this module provides a uniform API for
  consuming them regardless of which backend produced the messages.

  ## When to use directly vs through `BeamAgent`

  Use this module when you need to inspect task progress in a session — for
  example, to display a task dashboard, poll for completion, or gate downstream
  actions on todo status.

  ## Quick example

  ```elixir
  {:ok, messages} = BeamAgent.SessionStore.get_session_messages(session_id)

  todos = BeamAgent.Todo.extract_todos(messages)
  in_progress = BeamAgent.Todo.filter_by_status(todos, :in_progress)
  summary = BeamAgent.Todo.todo_summary(todos)
  # => %{total: 5, pending: 2, in_progress: 1, completed: 2}
  ```

  ## Core concepts

  - **Todo items**: maps with a `:content` string (the task description) and a
    `:status` (`:pending`, `:in_progress`, or `:completed`). Some items also carry
    an `:active_form` field with the in-progress display variant.

  - **Extraction**: `extract_todos/1` scans a flat message list for messages that
    carry todo arrays and returns all todo items found, in order.

  - **Summary**: `todo_summary/1` returns a map with `:total` and one key per
    distinct status value, giving counts at a glance.

  ## Architecture deep dive

  This module is a thin Elixir facade that delegates to `:beam_agent_todo`. All
  functions are pure — no ETS, no processes, no side effects.
  """

  @type todo_status :: :pending | :in_progress | :completed
  @type todo_item :: %{
          required(:content) => binary(),
          required(:status) => todo_status(),
          optional(:active_form) => binary()
        }

  @doc """
  Extract all todo items from a flat list of messages.

  Scans the message list for messages that carry todo arrays (as emitted by
  agentic coder backends) and returns all todo items in order.

  ## Example

  ```elixir
  {:ok, messages} = BeamAgent.SessionStore.get_session_messages(session_id)
  todos = BeamAgent.Todo.extract_todos(messages)
  ```
  """
  @spec extract_todos([BeamAgent.message()]) :: [todo_item()]
  defdelegate extract_todos(messages), to: :beam_agent_todo

  @doc """
  Filter a todo list by status.

  Returns only the todo items whose `:status` matches `status`.

  ## Example

  ```elixir
  pending = BeamAgent.Todo.filter_by_status(todos, :pending)
  completed = BeamAgent.Todo.filter_by_status(todos, :completed)
  ```
  """
  @spec filter_by_status([todo_item()], todo_status()) :: [todo_item()]
  defdelegate filter_by_status(todos, status), to: :beam_agent_todo

  @doc """
  Summarise a todo list as a count map.

  Returns a map with `:total` and one key per distinct status (`:pending`,
  `:in_progress`, `:completed`), giving counts at a glance.

  ## Example

  ```elixir
  %{total: 5, pending: 2, in_progress: 1, completed: 2} =
    BeamAgent.Todo.todo_summary(todos)
  ```
  """
  @spec todo_summary([todo_item()]) :: %{:total => non_neg_integer(), atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: :beam_agent_todo
end
