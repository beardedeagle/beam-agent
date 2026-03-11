-module(beam_agent_transport).
-moduledoc false.

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

