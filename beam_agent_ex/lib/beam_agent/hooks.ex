defmodule BeamAgent.Hooks do
  @moduledoc "Lifecycle hook helpers for the canonical `BeamAgent` package."

  defdelegate hook(event, callback), to: :beam_agent_hooks
  defdelegate hook(event, callback, matcher), to: :beam_agent_hooks
  defdelegate new_registry(), to: :beam_agent_hooks
  defdelegate register_hook(hook, registry), to: :beam_agent_hooks
  defdelegate register_hooks(hooks, registry), to: :beam_agent_hooks
  defdelegate fire(event, context, registry), to: :beam_agent_hooks
  defdelegate build_registry(opts), to: :beam_agent_hooks
end
