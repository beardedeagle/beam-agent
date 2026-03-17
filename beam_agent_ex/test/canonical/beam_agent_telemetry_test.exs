defmodule BeamAgent.TelemetryTest do
  use ExUnit.Case, async: false

  test "exports the telemetry wrapper surface including domain state changes" do
    Code.ensure_loaded!(BeamAgent.Telemetry)

    assert function_exported?(BeamAgent.Telemetry, :span_start, 3)
    assert function_exported?(BeamAgent.Telemetry, :span_stop, 3)
    assert function_exported?(BeamAgent.Telemetry, :span_stop, 4)
    assert function_exported?(BeamAgent.Telemetry, :span_exception, 3)
    assert function_exported?(BeamAgent.Telemetry, :span_exception, 4)
    assert function_exported?(BeamAgent.Telemetry, :state_change, 3)
    assert function_exported?(BeamAgent.Telemetry, :state_change, 4)
    assert function_exported?(BeamAgent.Telemetry, :buffer_overflow, 2)
  end

  test "delegates domain state change events through the Erlang telemetry module" do
    Code.ensure_loaded!(BeamAgent.Telemetry)

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :attach, 4) do
      {:ok, _} = Application.ensure_all_started(:telemetry)
      parent = self()
      handler_id = {:beam_agent_telemetry_wrapper, make_ref()}

      :ok =
        apply(:telemetry, :attach, [
          handler_id,
          [:beam_agent, :run, :state_change],
          fn event_name, measurements, metadata, _config ->
            send(parent, {event_name, measurements, metadata})
          end,
          []
        ])

      try do
        assert :ok =
                 BeamAgent.Telemetry.state_change(:run, :created, :running, %{
                   run_id: "wrapper-run"
                 })

        assert_receive {[:beam_agent, :run, :state_change], measurements, metadata}, 1000
        assert is_integer(measurements[:system_time])
        assert metadata[:agent] == :run
        assert metadata[:from_state] == :created
        assert metadata[:to_state] == :running
        assert metadata[:run_id] == "wrapper-run"
      after
        apply(:telemetry, :detach, [handler_id])
      end
    else
      assert function_exported?(BeamAgent.Telemetry, :state_change, 4)
    end
  end
end
