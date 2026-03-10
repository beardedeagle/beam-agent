-module(beam_agent_transport).
-moduledoc """
Transport behaviour for agent wire communication.

Abstracts the communication channel between the SDK and the
Claude Code CLI process. The default implementation uses Erlang
Ports (local subprocess), but alternative transports can support:
  - Distributed Erlang (remote nodes)
  - SSH channels
  - TCP/Unix sockets
  - WebSocket connections

This follows the TS SDK's Transport/SpawnedProcess interface
pattern, adapted for OTP conventions.

## Implementing a Custom Transport

```erlang
-module(my_remote_transport).
-behaviour(beam_agent_transport).

start(Opts) ->
    %% Connect to remote CLI process
    {ok, Pid} = my_connector:connect(Opts),
    {ok, Pid}.

send(Pid, Data) ->
    my_connector:send(Pid, Data).

close(Pid) ->
    my_connector:disconnect(Pid).

is_ready(Pid) ->
    my_connector:is_connected(Pid).
```

The owning gen_statem receives transport data as messages.
For Erlang Ports: `{Port, {data, Binary}}`
Custom transports should send: `{transport_data, Ref, Binary}`
""".

-export_type([transport_ref/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Opaque reference to a transport instance.
%% For Erlang Ports this is port(), for custom transports it's
%% implementation-defined (typically pid() or reference()).
-type transport_ref() :: port() | pid() | reference() | term().

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------

-doc """
Start the transport and return a reference handle.

The transport MUST deliver received data as Erlang messages
to the calling process (the gen_statem owner).

For Erlang Ports: messages are `{Port, {data, Binary}}`.
For custom transports: use `{transport_data, Ref, Binary}`.
""".
-callback start(Opts :: map()) ->
    {ok, transport_ref()} | {error, term()}.

-doc "Send data via the transport. Format depends on the transport type (iodata for ports, structured terms for WS/HTTP).".
-callback send(Ref :: transport_ref(), Data :: term()) ->
    ok | {error, term()}.

-doc "Close the transport and release resources. Should be idempotent (safe to call multiple times).".
-callback close(Ref :: transport_ref()) -> ok.

-doc "Check if the transport is ready to send/receive data.".
-callback is_ready(Ref :: transport_ref()) -> boolean().

-doc """
Return exit/termination information if the transport has closed.

Returns `running` if still active, `{exited, Status}` if the
remote process has terminated.
""".
-callback status(Ref :: transport_ref()) ->
    running | {exited, non_neg_integer()}.

-doc """
Classify an incoming Erlang message as a transport event.

Called by the session engine on every info message. Returns a
`transport_event()` if this message belongs to this transport,
or `ignore` if it does not.

Required for use with `beam_agent_session_engine`.
""".
-callback classify_message(Msg :: term(), Ref :: transport_ref()) ->
    beam_agent_session_handler:transport_event() | ignore.

-optional_callbacks([status/1]).
