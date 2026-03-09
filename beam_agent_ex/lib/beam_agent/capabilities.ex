defmodule BeamAgent.Capabilities do
  @moduledoc """
  Capability metadata for the canonical `BeamAgent` package.

  Results are reported in terms of `support_level`, `implementation`, and
  `fidelity`.

  All capabilities are at full parity across all backends. The canonical Erlang
  registry drives support levels and implementation/fidelity fields describe
  the routing strategy for each capability/backend pair.
  """

  defdelegate all(), to: :beam_agent_capabilities
  defdelegate backends(), to: :beam_agent_capabilities
  defdelegate capability_ids(), to: :beam_agent_capabilities
  defdelegate for_backend(backend), to: :beam_agent_capabilities
  defdelegate for_session(session), to: :beam_agent_capabilities
  defdelegate status(capability, backend), to: :beam_agent_capabilities
  defdelegate supports(capability, backend), to: :beam_agent_capabilities
end
