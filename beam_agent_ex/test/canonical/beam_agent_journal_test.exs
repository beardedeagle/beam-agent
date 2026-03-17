defmodule BeamAgent.JournalTest do
  use ExUnit.Case, async: false

  setup do
    :ok = :beam_agent_journal.clear()

    on_exit(fn ->
      :ok = :beam_agent_journal.clear()
    end)

    :ok
  end

  test "exports the canonical journal surface" do
    assert function_exported?(BeamAgent.Journal, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Journal, :clear, 0)
    assert function_exported?(BeamAgent.Journal, :append, 2)
    assert function_exported?(BeamAgent.Journal, :list, 0)
    assert function_exported?(BeamAgent.Journal, :list, 1)
    assert function_exported?(BeamAgent.Journal, :stream_from, 1)
    assert function_exported?(BeamAgent.Journal, :stream_from, 2)
    assert function_exported?(BeamAgent.Journal, :get, 1)
    assert function_exported?(BeamAgent.Journal, :ack, 2)
  end

  test "records and replays journal entries through the Elixir wrapper" do
    session = "beam-agent-journal-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, first} =
             BeamAgent.Journal.append("journal_started", %{
               session_id: session,
               tags: [:journal],
               payload: %{index: 1}
             })

    assert {:ok, second} =
             BeamAgent.Journal.append("journal_finished", %{
               session_id: session,
               tags: [:journal],
               payload: %{index: 2}
             })

    assert {:ok, [listed_first, listed_second]} = BeamAgent.Journal.list(%{session_id: session})
    assert listed_first.event_id == first.event_id
    assert listed_second.event_id == second.event_id

    assert {:ok, [replayed]} =
             BeamAgent.Journal.stream_from(first.sequence, %{session_id: session})

    assert replayed.event_id == second.event_id

    assert :ok = BeamAgent.Journal.ack("consumer-elixir", second.event_id)
  end
end
