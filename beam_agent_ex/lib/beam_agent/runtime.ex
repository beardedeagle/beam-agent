defmodule BeamAgent.Runtime do
  @moduledoc "Runtime/provider state helpers for the canonical `BeamAgent` package."

  defdelegate get_state(session), to: :beam_agent_runtime
  defdelegate current_provider(session), to: :beam_agent_runtime
  defdelegate set_provider(session, provider_id), to: :beam_agent_runtime
  defdelegate clear_provider(session), to: :beam_agent_runtime
  defdelegate get_provider_config(session), to: :beam_agent_runtime
  defdelegate set_provider_config(session, config), to: :beam_agent_runtime
  defdelegate current_agent(session), to: :beam_agent_runtime
  defdelegate set_agent(session, agent_id), to: :beam_agent_runtime
  defdelegate clear_agent(session), to: :beam_agent_runtime
  defdelegate list_providers(session), to: :beam_agent_runtime
  defdelegate provider_status(session), to: :beam_agent_runtime
  defdelegate provider_status(session, provider_id), to: :beam_agent_runtime
  defdelegate validate_provider_config(provider_id, config), to: :beam_agent_runtime
end
