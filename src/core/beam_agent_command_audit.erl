-module(beam_agent_command_audit).
-moduledoc """
Security audit and observability for the BEAM Agent command system (Layer 5).

Provides opt-in audit capabilities that extend the command security
architecture with deeper observability.  No processes are spawned —
all functions operate on the calling process or are pure.

  - **Sequential trace** (`seq_trace`) — enables causal audit trails
    across processes for a command execution.  Sets per-process tokens
    on the caller.

  - **System monitor** (`erlang:system_monitor/2`) — detects resource
    abuse (long GC, large heaps, busy ports).  The caller installs
    itself as the monitor and handles messages in its own receive loop
    via `handle_monitor_message/1`.

Both features are opt-in.  The command security system works without them.

## Sequential Trace

```erlang
Label = make_ref(),
beam_agent_command_audit:start_audit_trail(Label),
{ok, Result} = beam_agent_command_core:run(<<"ls">>),
beam_agent_command_audit:stop_audit_trail().
```

## System Monitor

Install the calling process as the system monitor, then handle
messages in its receive loop or `handle_info`:

```erlang
%% In init or start:
beam_agent_command_audit:install_system_monitor(),

%% In handle_info or receive loop:
handle_info(Msg, State) ->
    case beam_agent_command_audit:handle_monitor_message(Msg) of
        {alarm, Type, Details} ->
            %% Resource abuse detected — telemetry already emitted
            logger:warning("resource alarm: ~p ~p", [Type, Details]),
            {noreply, State};
        ignore ->
            {noreply, State}
    end.

%% On shutdown:
beam_agent_command_audit:uninstall_system_monitor().
```
""".

-export([
    %% Sequential trace
    start_audit_trail/1,
    stop_audit_trail/0,

    %% System monitor (caller owns the process)
    install_system_monitor/0,
    install_system_monitor/1,
    uninstall_system_monitor/0,
    handle_monitor_message/1
]).

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
%% System Monitor (caller owns the process)
%%--------------------------------------------------------------------

-doc """
Install the calling process as the VM system monitor with defaults.

Default thresholds:
  - `long_gc`: 50ms
  - `long_schedule`: 50ms
  - `large_heap`: 10,000,000 words (~80MB on 64-bit)
  - `busy_port`: enabled

WARNING: `erlang:system_monitor/2` is a VM-global setting.  Only one
process can be the system monitor at any time.  Calling this replaces
any existing system monitor.

The caller must handle monitor messages in its receive loop using
`handle_monitor_message/1`.
""".
-spec install_system_monitor() -> ok.
install_system_monitor() ->
    install_system_monitor(#{}).

-doc """
Install the calling process as the VM system monitor with custom
thresholds.

Options:
  - `long_gc` — GC pause threshold in ms (default: 50)
  - `long_schedule` — scheduling delay threshold in ms (default: 50)
  - `large_heap` — heap size threshold in words (default: 10,000,000)
  - `busy_port` — monitor busy ports (default: true)
""".
-spec install_system_monitor(map()) -> ok.
install_system_monitor(Opts) ->
    MonitorOpts = build_monitor_opts(Opts),
    _ = erlang:system_monitor(self(), MonitorOpts),
    ok.

-doc "Remove the system monitor.  Safe to call even if not installed.".
-spec uninstall_system_monitor() -> ok.
uninstall_system_monitor() ->
    _ = erlang:system_monitor(undefined),
    ok.

-doc """
Parse a system monitor message, emit telemetry, and return a
structured result.

Returns `{alarm, AlarmType, Details}` for recognized monitor messages,
or `ignore` for unrecognized messages.  Telemetry is emitted under
`[beam_agent, security, resource_alarm]` before returning.

Call this from your process's `handle_info` or receive loop.
""".
-spec handle_monitor_message(_) ->
    {alarm, long_gc | long_schedule | large_heap | busy_port,
     #{pid := pid(), info => term(), heap_size => non_neg_integer(),
       port => port() | term()}} | ignore.
handle_monitor_message({monitor, Pid, long_gc, Info}) ->
    Details = #{pid => Pid, info => Info},
    emit_resource_alarm(long_gc, Details),
    {alarm, long_gc, Details};
handle_monitor_message({monitor, Pid, long_schedule, Info}) ->
    Details = #{pid => Pid, info => Info},
    emit_resource_alarm(long_schedule, Details),
    {alarm, long_schedule, Details};
handle_monitor_message({monitor, Pid, large_heap, Size}) ->
    Details = #{pid => Pid, heap_size => Size},
    emit_resource_alarm(large_heap, Details),
    {alarm, large_heap, Details};
handle_monitor_message({monitor, Pid, busy_port, Port}) ->
    Details = #{pid => Pid, port => Port},
    emit_resource_alarm(busy_port, Details),
    {alarm, busy_port, Details};
handle_monitor_message(_) ->
    ignore.

%%--------------------------------------------------------------------
%% Internal
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
