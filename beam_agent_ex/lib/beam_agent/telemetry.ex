defmodule BeamAgent.Telemetry do
  @moduledoc """
  OpenTelemetry-style span and event emission for the BeamAgent SDK.

  All five backend session handlers emit telemetry events via this module so that
  consuming applications can attach handlers once and observe every backend
  uniformly. No OTLP export or collector is built in — this module follows the
  Erlang/OTP `:telemetry` convention: the library emits events, applications
  handle them.

  ## When to use directly vs through `BeamAgent`

  Backends call this module internally during session operation. Use it directly
  only when implementing a custom backend adapter or adding instrumentation to a
  session handler.

  ## Event namespace

  All events are published under the `[:beam_agent, ...]` prefix. The `agent`
  parameter (an atom such as `:claude` or `:codex`) becomes the second element of
  the event name list:

  ```
  [:beam_agent, :claude, :query, :start]
  [:beam_agent, :claude, :query, :stop]
  [:beam_agent, :claude, :query, :exception]
  [:beam_agent, :session, :state_change]   # always at this fixed path
  [:beam_agent, :buffer, :overflow]        # always at this fixed path
  ```

  ## Span lifecycle example

  ```elixir
  start_time = BeamAgent.Telemetry.span_start(:claude, :query, %{session_id: id})
  # ... do work ...
  BeamAgent.Telemetry.span_stop(:claude, :query, start_time)
  ```

  ## Attaching handlers

  Use the standard `:telemetry.attach/4` or `:telemetry.attach_many/4` call in
  your application startup:

  ```elixir
  :telemetry.attach_many(
    :my_handler,
    [
      [:beam_agent, :claude, :query, :start],
      [:beam_agent, :claude, :query, :stop]
    ],
    &MyTelemetryHandler.handle/4,
    []
  )
  ```

  See the `:telemetry` library documentation for handler function signature details.
  """

  @doc """
  Emit a span start event and return a monotonic start time.

  The returned integer must be passed unchanged to `span_stop/3` or
  `span_exception/3` so the duration can be computed.

  Parameters:
  - `agent` — backend atom, e.g. `:claude`, `:codex`, `:gemini`
  - `event_suffix` — atom labelling the operation, e.g. `:query`, `:connect`
  - `metadata` — arbitrary map attached to the telemetry event

  Returns a monotonic integer (result of `:erlang.monotonic_time/0`).

  ## Example

  ```elixir
  t = BeamAgent.Telemetry.span_start(:claude, :query, %{session_id: id})
  # work...
  BeamAgent.Telemetry.span_stop(:claude, :query, t)
  ```
  """
  @spec span_start(atom(), atom(), map()) :: integer()
  defdelegate span_start(agent, suffix, metadata), to: :beam_agent_telemetry

  @doc """
  Emit a span stop event, computing duration from the start time.

  The event is published at `[:beam_agent, agent, event_suffix, :stop]` with a
  `duration` measurement in native time units.

  Parameters:
  - `agent` — same atom passed to `span_start/3`
  - `suffix` — same atom passed to `span_start/3`
  - `start_time` — the integer returned by `span_start/3`
  """
  @spec span_stop(atom(), atom(), integer()) :: :ok
  defdelegate span_stop(agent, suffix, start_time), to: :beam_agent_telemetry

  @doc """
  Emit a span exception event when a unit of work fails.

  The event is published at `[:beam_agent, agent, event_suffix, :exception]`.
  Call this instead of `span_stop/3` when the work raised an error or exception.

  Parameters:
  - `agent` — backend atom
  - `suffix` — operation atom, must match the `span_start/3` call
  - `reason` — the error reason or exception term
  """
  @spec span_exception(atom(), atom(), term()) :: :ok
  defdelegate span_exception(agent, suffix, reason), to: :beam_agent_telemetry

  @doc """
  Emit a state change event for a `gen_statem` transition.

  The event is published at the fixed path `[:beam_agent, :session, :state_change]`.
  Backend session handlers call this on every state machine transition so that
  consumers can observe the full session lifecycle.

  Parameters:
  - `agent` — backend atom identifying which session handler fired
  - `from_state` — the state the session is leaving (e.g. `:connecting`, `:ready`)
  - `to_state` — the state the session is entering

  Valid state atoms: `:connecting`, `:initializing`, `:ready`, `:active_query`,
  `:error`.
  """
  @spec state_change(atom(), atom(), atom()) :: :ok
  defdelegate state_change(agent, from_state, to_state), to: :beam_agent_telemetry

  @doc """
  Emit a buffer overflow warning when accumulated transport data exceeds the limit.

  The event is published at the fixed path `[:beam_agent, :buffer, :overflow]`.
  This event fires when the session engine's inbound buffer grows beyond the
  configured maximum, which typically signals a misbehaving backend or extremely
  large responses.

  Parameters:
  - `buffer_size` — current size of the buffer in bytes
  - `max` — the configured maximum in bytes
  """
  @spec buffer_overflow(pos_integer(), pos_integer()) :: :ok
  defdelegate buffer_overflow(buffer_size, max), to: :beam_agent_telemetry
end
