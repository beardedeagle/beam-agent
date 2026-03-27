-module(beam_agent_os_signal).
-moduledoc """
OS signal delivery via Erlang ports.

Replaces shell-based `os:cmd("kill ...")` calls with direct executable
invocation using `open_port/2` with `spawn_executable`. This eliminates
shell interpretation, avoids bypassing the SDK's command security pipeline,
and prevents establishing a precedent for `os:cmd/1` usage.

Signals are delivered by invoking the system `kill` binary directly,
resolved via `os:find_executable/1` on each call. This is appropriate
because signal delivery is infrequent (cancellation paths only).

All signal delivery attempts (success and failure) are logged via
`logger` for operational visibility and audit trail.

Unix-only. The `kill` binary must be available on the system PATH.

## Why not `os:cmd/1`?

While `os:cmd("kill -INT " ++ integer_to_list(Pid))` is safe when the PID
comes from `erlang:port_info/2` (trusted integer, no injection), it:

1. Bypasses the SDK's 4-layer command security pipeline
2. Establishes a pattern that could be copied with less-trusted input
3. Is invisible to operational logging

This module eliminates all three concerns by using `spawn_executable`
(no shell) and logging every signal delivery attempt.
""".

-export([send_signal/2]).

-export_type([signal/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Supported POSIX signals for delivery to OS processes.".
-type signal() :: sigint | sigterm | sigkill | sighup.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% Timeout for the kill command to exit. The kill(1) binary is
%% near-instantaneous; 5 seconds is astronomically generous and only
%% guards against pathological system states.
-define(KILL_TIMEOUT_MS, 5000).

-doc """
Send a POSIX signal to an OS process identified by PID.

Uses `open_port/2` with `spawn_executable` to invoke the system `kill`
binary directly — no shell interpretation, no injection surface.

`OsPid` must be a positive integer, typically from
`erlang:port_info(Port, os_pid)`.

All signal delivery attempts are logged: `logger:info` on success,
`logger:warning` on failure.

Returns `ok` when the `kill` command exits with status 0. Returns
`{error, Reason}` on failure:

- `{invalid_pid, OsPid}` — PID is not a positive integer
- `kill_not_found` — `kill` binary not found on system PATH
- `{exit_status, N}` — `kill` exited non-zero (process not found,
  permission denied, etc.)
- `timeout` — `kill` did not exit within 5 seconds

Crashes with `function_clause` for unrecognised signal atoms (fail-fast).

```erlang
{os_pid, OsPid} = erlang:port_info(Port, os_pid),
ok = beam_agent_os_signal:send_signal(sigint, OsPid)
```
""".
-spec send_signal(signal(), pos_integer()) -> ok | {error, term()}.
send_signal(Signal, OsPid) when is_integer(OsPid), OsPid > 0 ->
    SigFlag = signal_flag(Signal),
    PidStr = integer_to_list(OsPid),
    Result = case os:find_executable("kill") of
        false ->
            {error, kill_not_found};
        KillPath ->
            send_via_port(KillPath, SigFlag, PidStr)
    end,
    log_result(Signal, OsPid, Result),
    Result;
send_signal(_Signal, OsPid) ->
    {error, {invalid_pid, OsPid}}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

send_via_port(KillPath, SigFlag, PidStr) ->
    try
        Port = open_port({spawn_executable, KillPath},
                         [{args, [SigFlag, PidStr]},
                          exit_status,
                          %% Capture stderr so kill error messages do not
                          %% leak to the BEAM node's stderr. Errors are
                          %% reported via exit_status and logged by the
                          %% caller.
                          stderr_to_stdout]),
        receive
            {Port, {exit_status, 0}} ->
                ok;
            {Port, {exit_status, N}} ->
                {error, {exit_status, N}}
        after ?KILL_TIMEOUT_MS ->
            catch port_close(Port),
            flush_port(Port),
            {error, timeout}
        end
    catch
        Class:Reason:Stack ->
            logger:warning("Signal delivery port error: ~p:~tp~n~p",
                           [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%% Drain any pending messages from a closed port to prevent mailbox leaks.
-spec flush_port(port()) -> ok.
flush_port(Port) ->
    receive {Port, _} -> flush_port(Port)
    after 0 -> ok
    end.

signal_flag(sigint)  -> "-INT";
signal_flag(sigterm) -> "-TERM";
signal_flag(sigkill) -> "-KILL";
signal_flag(sighup)  -> "-HUP".

%% Log every signal delivery attempt for operational visibility.
log_result(Signal, OsPid, ok) ->
    logger:info("Signal ~s delivered to OS process ~b", [Signal, OsPid]);
log_result(Signal, OsPid, {error, Reason}) ->
    logger:warning("Signal ~s to OS process ~b failed: ~tp",
                   [Signal, OsPid, Reason]).
