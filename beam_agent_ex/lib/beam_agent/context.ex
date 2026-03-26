defmodule BeamAgent.Context do
  @moduledoc """
  Elixir facade for canonical BeamAgent context management.

  `BeamAgent.Context` keeps compaction explicit and caller-driven. It reports
  current pressure, summary state, and memory handoff candidates, then lets the
  caller decide when to compact. It does not start a hidden scheduler or
  background compactor.

  Use `budget_estimate/1` or `context_status/1` to inspect pressure first, then
  call `maybe_compact/2` or `compact_now/2` from a boundary you already own,
  such as a routine runner or orchestration completion hook.
  """

  @typedoc "Session or thread scope accepted by the context manager."
  @type scope :: :beam_agent_context.scope()

  @typedoc "Current context status map."
  @type context_status :: :beam_agent_context.context_status()

  @typedoc "Context budget estimate map."
  @type budget_estimate_result :: :beam_agent_context.budget_estimate_result()

  @typedoc "Immediate compaction result map."
  @type compact_now_result :: :beam_agent_context.compact_now_result()

  @typedoc "Policy-driven compaction result map."
  @type maybe_compact_result :: :beam_agent_context.maybe_compact_result()

  @typedoc "Context-layer error returned by the Erlang public API."
  @type context_error :: :beam_agent_context.context_error()

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
  @spec compact_now(scope(), map()) ::
          {:ok, compact_now_result()}
          | {:error, context_error() | {:hook_denied, binary()} | {:hook_ask, binary()}}
  defdelegate compact_now(session_or_thread, opts), to: :beam_agent_context

  @doc """
  Compact only when a configured policy trigger fires.
  """
  @spec maybe_compact(scope(), map()) ::
          {:ok, maybe_compact_result()}
          | {:error, context_error() | {:hook_denied, binary()} | {:hook_ask, binary()}}
  defdelegate maybe_compact(session_or_thread, opts), to: :beam_agent_context
end
