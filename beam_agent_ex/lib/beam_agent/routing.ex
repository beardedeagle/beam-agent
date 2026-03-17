defmodule BeamAgent.Routing do
  @moduledoc """
  Elixir facade for canonical BeamAgent backend routing.

  This module chooses a backend according to reusable routing policy instead of
  forcing callers to hard-code backend choice on every session start.

  Supported policies are `:explicit`, `:sticky`, `:round_robin`, `:failover`,
  `:capability_first`, and `:preferred_then_fallback`. Sticky affinity and
  round-robin cursors are stored as canonical BeamAgent state, but the module
  itself stays process-free.
  """

  @typedoc """
  Routing policy name.

  Supported values are `:explicit`, `:sticky`, `:round_robin`, `:failover`,
  `:capability_first`, and `:preferred_then_fallback`.
  """
  @type route_policy :: :beam_agent_routing.route_policy()

  @typedoc """
  Fallback behavior after preferred candidates are exhausted.

  Supported values are `:none` and `:available`.
  """
  @type fallback_policy :: :beam_agent_routing.fallback_policy()

  @typedoc """
  Backend health override for routing.

  Supported values are `:healthy`, `:degraded`, `:unhealthy`, and `:down`.
  """
  @type health_status :: :beam_agent_routing.health_status()

  @typedoc """
  Routing request map.
  """
  @type route_request :: :beam_agent_routing.route_request()

  @typedoc """
  Routing decision map.
  """
  @type route_decision :: :beam_agent_routing.route_decision()

  @doc """
  Ensure routing state tables exist.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_routing

  @doc """
  Clear sticky affinity and round-robin routing state.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_routing

  @doc """
  Select a backend using a normalized routing request.
  """
  @spec select_backend(route_request()) :: {:ok, route_decision()} | {:error, term()}
  defdelegate select_backend(route_request), to: :beam_agent_routing

  @doc """
  Select a backend after deriving defaults from a session identity or session opts.
  """
  @spec select_backend(pid() | binary() | map(), route_request()) ::
          {:ok, route_decision()} | {:error, term()}
  defdelegate select_backend(session_or_opts, route_request), to: :beam_agent_routing
end
