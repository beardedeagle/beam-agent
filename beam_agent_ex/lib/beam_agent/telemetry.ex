defmodule BeamAgent.Telemetry do
  @moduledoc "Telemetry helpers for the canonical `BeamAgent` package."

  defdelegate span_start(agent, suffix, metadata), to: :beam_agent_telemetry
  defdelegate span_stop(agent, suffix, start_time), to: :beam_agent_telemetry
  defdelegate span_exception(agent, suffix, reason), to: :beam_agent_telemetry
  defdelegate state_change(agent, from_state, to_state), to: :beam_agent_telemetry
  defdelegate buffer_overflow(buffer_size, max), to: :beam_agent_telemetry
end
