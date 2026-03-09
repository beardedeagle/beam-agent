defmodule BeamAgent.Command do
  @moduledoc "Command execution helpers for the canonical `BeamAgent` package."

  defdelegate run(command), to: :beam_agent_command
  defdelegate run(command, opts), to: :beam_agent_command
end
