defmodule BeamAgent.Context do
  @moduledoc """
  Elixir facade for canonical BeamAgent context management.
  """

  @typedoc "Session or thread scope accepted by the context manager."
  @type scope :: :beam_agent_context.scope()

  @typedoc "Current context status map."
  @type context_status :: :beam_agent_context.context_status()

  @typedoc "Context budget estimate map."
  @type budget_estimate_result :: :beam_agent_context.budget_estimate_result()

  @doc """
  Return current context pressure and available summary/memory state.
  """
  @spec context_status(scope()) :: {:ok, context_status()} | {:error, term()}
  defdelegate context_status(session_or_thread), to: :beam_agent_context

  @doc """
  Estimate current context budget pressure using default thresholds.
  """
  @spec budget_estimate(scope()) :: {:ok, budget_estimate_result()} | {:error, term()}
  defdelegate budget_estimate(session_or_thread), to: :beam_agent_context

  @doc """
  Summarize, optionally promote to memory, and compact immediately.
  """
  @spec compact_now(scope(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate compact_now(session_or_thread, opts), to: :beam_agent_context

  @doc """
  Compact only when a configured policy trigger fires.
  """
  @spec maybe_compact(scope(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate maybe_compact(session_or_thread, opts), to: :beam_agent_context
end

