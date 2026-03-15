-module(beam_agent_command_audit).
-moduledoc """
Security audit and observability for the BEAM Agent command system (Layer 5).

Provides opt-in audit capabilities that extend the command security
architecture with deeper observability:

  - **Sequential trace** (`seq_trace`) — enables causal audit trails
    across processes for a command execution.  Useful for tracing the
    full evaluation path from parse to policy to validator to guard
    to executor.

  - **System monitor** (`erlang:system_monitor/2`) — detects resource
    abuse (long GC, large heaps, busy ports) and emits telemetry events.
    This is a VM-global setting — only one system monitor can be active
    at any time.

Both features are opt-in.  The command security system works without them.

## Sequential Trace

```erlang
Label = make_ref(),
beam_agent_command_audit:start_audit_trail(Label),
{ok, Result} = beam_agent_command_core:run(<<"ls">>),
beam_agent_command_audit:stop_audit_trail().
```

## System Monitor

```erlang
beam_agent_command_audit:start_monitor(),
%% Resource abuse events emitted as telemetry:
%%   [beam_agent, security, resource_alarm]
beam_agent_command_audit:stop_monitor().
```
""".

-export([
    %% Sequential trace
    start_audit_trail/1,
    stop_audit_trail/0,

    %% System monitor
    start_monitor/0,
    start_monitor/1,
    stop_monitor/0
]).

%% persistent_term key for monitor pid
-define(PT_MONITOR_PID, beam_agent_audit_monitor_pid).

%% Default thresholds
-define(DEFAULT_LONG_GC_MS, 50).
-define(DEFAULT_LONG_SCHEDULE_MS, 50).
-define(DEFAULT_LARGE_HEAP, 10_000_000).  %% ~80MB on 64-bit

%%--------------------------------------------------------------------
%% Sequential Trace
%%--------------------------------------------------------------------

-doc """
Enable sequential trace for causal audit trails.

Sets `seq_trace` tokens on the calling process so that all subsequent
message sends and receives are traced with the given label.  The label
is typically a unique reference identifying the command execution.

This is a per-process setting.  Call `stop_audit_trail/0` when done.
""".
-spec start_audit_trail(term()) -> ok.
start_audit_trail(Label) ->
    _ = seq_trace:set_token(label, Label),
    _ = seq_trace:set_token(send, true),
    _ = seq_trace:set_token('receive', true),
    _ = seq_trace:set_token(timestamp, true),
    ok.

-doc "Clear sequential trace tokens on the calling process.".
-spec stop_audit_trail() -> ok.
stop_audit_trail() ->
    _ = seq_trace:set_token([]),
    ok.

%%--------------------------------------------------------------------
%% System Monitor
%%--------------------------------------------------------------------

-doc """
Start the system monitor with default thresholds.

Default thresholds:
  - `long_gc`: 50ms
  - `long_schedule`: 50ms
  - `large_heap`: 10,000,000 words (~80MB on 64-bit)
  - `busy_port`: enabled

WARNING: `erlang:system_monitor/2` is a VM-global setting.  Only one
process can be the system monitor at any time.  Calling this replaces
any existing system monitor.
""".
-spec start_monitor() -> ok.
start_monitor() ->
    start_monitor(#{}).

-doc """
Start the system monitor with custom thresholds.

Options:
  - `long_gc` — GC pause threshold in ms (default: 50)
  - `long_schedule` — scheduling delay threshold in ms (default: 50)
  - `large_heap` — heap size threshold in words (default: 10,000,000)
  - `busy_port` — monitor busy ports (default: true)
""".
-spec start_monitor(map()) -> ok.
start_monitor(Opts) ->
    stop_monitor(),
    MonitorOpts = build_monitor_opts(Opts),
    Pid = spawn(fun() -> monitor_loop() end),
    _ = erlang:system_monitor(Pid, MonitorOpts),
    persistent_term:put(?PT_MONITOR_PID, Pid),
    ok.

-doc "Stop the system monitor and clean up.".
-spec stop_monitor() -> ok.
stop_monitor() ->
    case persistent_term:get(?PT_MONITOR_PID, undefined) of
        undefined ->
            ok;
        Pid ->
            _ = erlang:system_monitor(undefined),
            exit(Pid, shutdown),
            _ = persistent_term:erase(?PT_MONITOR_PID),
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Monitor process
%%--------------------------------------------------------------------

-spec monitor_loop() -> no_return().
monitor_loop() ->
    receive
        {monitor, Pid, long_gc, Info} ->
            emit_resource_alarm(long_gc, #{pid => Pid, info => Info}),
            monitor_loop();
        {monitor, Pid, long_schedule, Info} ->
            emit_resource_alarm(long_schedule, #{pid => Pid, info => Info}),
            monitor_loop();
        {monitor, Pid, large_heap, Size} ->
            emit_resource_alarm(large_heap, #{pid => Pid, heap_size => Size}),
            monitor_loop();
        {monitor, Pid, busy_port, Port} ->
            emit_resource_alarm(busy_port, #{pid => Pid, port => Port}),
            monitor_loop();
        _ ->
            monitor_loop()
    end.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-type monitor_opt() :: busy_port
                     | {long_gc, non_neg_integer()}
                     | {long_schedule, non_neg_integer()}
                     | {large_heap, non_neg_integer()}.

-spec build_monitor_opts(map()) -> [monitor_opt()].
build_monitor_opts(Opts) ->
    LongGc = maps:get(long_gc, Opts, ?DEFAULT_LONG_GC_MS),
    LongSched = maps:get(long_schedule, Opts, ?DEFAULT_LONG_SCHEDULE_MS),
    LargeHeap = maps:get(large_heap, Opts, ?DEFAULT_LARGE_HEAP),
    BusyPort = maps:get(busy_port, Opts, true),
    Base = [
        {long_gc, LongGc},
        {long_schedule, LongSched},
        {large_heap, LargeHeap}
    ],
    case BusyPort of
        true  -> [busy_port | Base];
        false -> Base
    end.

-spec emit_resource_alarm(atom(), map()) -> ok.
emit_resource_alarm(AlarmType, Details) ->
    case erlang:function_exported(telemetry, execute, 3) of
        true ->
            apply(telemetry, execute,
                  [[beam_agent, security, resource_alarm],
                   #{system_time => erlang:system_time()},
                   Details#{alarm_type => AlarmType}]);
        false ->
            ok
    end.
