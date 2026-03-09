defmodule BeamAgent.Todo do
  @moduledoc """
  Todo tracking helpers for canonical `BeamAgent` message streams.
  """

  @type todo_status :: :pending | :in_progress | :completed
  @type todo_item :: %{
          required(:content) => binary(),
          required(:status) => todo_status(),
          optional(:active_form) => binary()
        }

  @spec extract_todos([BeamAgent.message()]) :: [todo_item()]
  defdelegate extract_todos(messages), to: :beam_agent_todo

  @spec filter_by_status([todo_item()], todo_status()) :: [todo_item()]
  defdelegate filter_by_status(todos, status), to: :beam_agent_todo

  @spec todo_summary([todo_item()]) :: %{atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: :beam_agent_todo
end
