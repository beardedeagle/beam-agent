-module(beam_agent_session_handler).
-moduledoc """
Callback behaviour for backend session handlers.

Each agentic coder backend (Claude, Codex, Copilot, Gemini, OpenCode)
implements this behaviour to provide backend-specific logic for:

  - Transport selection and configuration
  - Protocol encoding/decoding (JSONL, JSON-RPC, SSE, WebSocket)
  - Session initialization handshakes
  - Query encoding and message normalization
  - Backend-specific features (hooks, MCP, permissions, etc.)

The `beam_agent_session_engine` gen_statem calls these callbacks at
well-defined points in the session lifecycle. The engine handles all
shared orchestration (state machine, consumer/queue, telemetry, error
recovery) so handlers focus only on what is unique to their backend.

## Implementing a Handler

```erlang
-module(my_session_handler).
-behaviour(beam_agent_session_handler).

backend_name() -> my_backend.

init_handler(Opts) ->
    {ok, #{
        transport_spec => {beam_agent_transport_port, #{
            executable => \"/usr/local/bin/my-cli\",
            args       => [\"--json\"]
        }},
        initial_state => connecting,
        handler_state => #{opts => Opts}
    }}.

handle_data(Buffer, State) ->
    {Messages, NewBuf} = decode_buffer(Buffer),
    {ok, Messages, NewBuf, [], State}.

encode_query(Prompt, _Params, State) ->
    {ok, beam_agent_jsonl:encode_line(#{<<\"type\">> => <<\"user\">>,
                                        <<\"content\">> => Prompt}), State}.

build_session_info(#{opts := Opts}) ->
    #{backend => my_backend, opts => Opts}.

terminate_handler(_Reason, _State) -> ok.
```
""".

-export_type([handler_action/0, transport_event/0, state_name/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type state_name() :: connecting | initializing | ready | active_query | error.

-type transport_event() ::
    {data, binary()}
  | connected
  | {disconnected, term()}
  | {exit, non_neg_integer()}
  | connect_timeout
  | init_timeout.

-type handler_action() :: {send, term()}.
%% Instructs the engine to send data via the transport.
%%
%% The data format depends on the transport type: iodata for ports,
%% structured terms for WebSocket/HTTP. Handler and transport must
%% agree on the format since they are always paired.
%%
%% All other side effects (hook firing, session store registration,
%% thread tracking, etc.) are performed by the handler directly.

-type init_result() :: {ok, #{
    transport_spec := {module(), map()},
    initial_state  := connecting | initializing | ready,
    handler_state  := term()
}} | {stop, term()}.

-type data_result() :: {ok,
    Messages        :: [beam_agent_core:message()],
    LeftoverBuffer  :: binary(),
    Actions         :: [handler_action()],
    NewHandlerState :: term()
}.

-doc """
The 5-tuple variant passes leftover buffer data to the engine.
Use this when transitioning to ready from connecting or
initializing with accumulated buffer data that the engine
should continue processing.
""".
-type phase_result() ::
    {next_state, initializing | ready, [handler_action()], term()}
  | {next_state, initializing | ready, [handler_action()], term(),
     LeftoverBuffer :: binary()}
  | {keep_state, [handler_action()], term()}
  | {error_state, Reason :: term(), term()}.

-doc """
Result type for send_control/3 handler callbacks.

The reply variant causes the engine to reply {ok, Result} to the
caller immediately. The noreply variant defers the reply — the handler
must store From and call gen_statem:reply/2 later (e.g., when a
protocol response arrives in handle_data/2). The error variant causes
the engine to reply {error, Reason} to the caller.
""".
-type control_result() ::
    {reply, Result :: term(), [handler_action()], term()}
  | {noreply, [handler_action()], term()}
  | {error, term()}.

-doc """
Return type for handle_info/3.

The messages variant delivers messages to the consumer (or queue if no
active query), executes send actions, and updates handler state. No
buffer involvement — this bypasses the engine's buffer management.

A phase_result() triggers a state transition (e.g., connecting to
initializing when a transport_up arrives for an HTTP transport).

The ignore atom means the handler does not handle this message either.
""".
-type info_result() ::
    {messages, [beam_agent_core:message()], [handler_action()], term()}
  | phase_result()
  | ignore.

-export_type([init_result/0, data_result/0, phase_result/0,
              control_result/0, info_result/0]).

%%--------------------------------------------------------------------
%% Required Callbacks
%%--------------------------------------------------------------------

-doc "Return the backend identifier for telemetry and session registration.".
-callback backend_name() -> atom().

-doc """
Initialize the handler.

Called once during engine init/1. Returns the transport configuration,
initial state, and opaque handler state.

`transport_spec` is `{TransportModule, TransportOpts}`. The engine calls
`TransportModule:start(TransportOpts)` to start the transport.

`initial_state` determines where the state machine begins:
  - `connecting`:    transport needs async setup or backend must wait
                     for a system init message before handshake
  - `initializing`:  transport is immediately ready, protocol handshake needed
  - `ready`:         no handshake (useful for testing or stateless protocols)

The engine generates a `session_id` before calling this function and
includes it in `Opts`. The handler can rely on `session_id` being present.
""".
-callback init_handler(Opts :: beam_agent_core:session_opts()) -> init_result().

-doc """
Decode incoming transport data into normalized messages.

Called when the engine receives data from the transport during `ready`
or `active_query` states. The `Buffer` parameter contains all accumulated
data (engine combines old buffer + new data before calling).

The handler must:
  1. Extract complete protocol frames from the buffer
  2. Decode frames and normalize into `beam_agent_core:message()` format
  3. Handle internal messages (e.g., control_requests) by processing them
     and returning only messages that should be delivered to the consumer
  4. Return send actions for any responses (e.g., control_response)
  5. Return the leftover buffer after extracting complete frames
""".
-callback handle_data(
    Buffer       :: binary(),
    HandlerState :: term()
) -> data_result().

-doc """
Encode an outgoing query for transmission via the transport.

Called when `send_query` is received in the `ready` state. The handler
encodes the prompt and parameters into the backend's wire format and
returns iodata to send via the transport.
""".
-callback encode_query(
    Prompt       :: binary(),
    Params       :: beam_agent_core:query_opts(),
    HandlerState :: term()
) -> {ok, term(), term()} | {error, term()}.

-doc """
Build the session info map returned by `session_info/1`.

Called in any state. The engine merges the handler's map with engine-level
metadata (`session_id`, `model`, current state).
""".
-callback build_session_info(HandlerState :: term()) -> map().

-doc """
Clean up handler resources.

Called during engine `terminate/3`. The engine closes the transport
separately — the handler only needs to clean up its own resources
(hook registries, ETS tables, etc.).
""".
-callback terminate_handler(Reason :: term(), HandlerState :: term()) -> ok.

%%--------------------------------------------------------------------
%% Optional Callbacks
%%--------------------------------------------------------------------

-doc """
Called after the engine starts the transport.

Allows the handler to store the transport reference for direct access
(e.g., sending OS signals to a port process). The handler returns the
updated handler state.
""".
-callback transport_started(
    Ref          :: beam_agent_transport:transport_ref(),
    HandlerState :: term()
) -> term().

-doc """
Handle transport events during the connecting phase.

Called when the engine receives a classified transport event while in
the `connecting` state. The handler decides whether to transition to
`initializing`, `ready`, or stay in `connecting`.

The 5-tuple `{next_state, State, Actions, HState, Buffer}` variant
passes leftover buffer data to the engine for continued processing
in the next state.

Not called if `initial_state` is `initializing` or `ready`.
""".
-callback handle_connecting(
    Event        :: transport_event(),
    HandlerState :: term()
) -> phase_result().

-doc """
Handle transport events during the initializing phase.

Called when the engine receives data/events while in the `initializing`
state. The handler processes init handshake responses and decides
when to transition to `ready`.

The 5-tuple `{next_state, ready, Actions, HState, Buffer}` variant
passes leftover buffer data to the engine for continued processing.

Not called if `initial_state` is `ready`.
""".
-callback handle_initializing(
    Event        :: transport_event(),
    HandlerState :: term()
) -> phase_result().

-doc """
Encode an interrupt signal.

Called when `interrupt/1` is received during `active_query`. Returns
a list of actions to execute (e.g., `[{send, InterruptMsg}]`), or
an empty list if the handler performs the interrupt directly (e.g.,
sending an OS signal via a stored transport ref).

If not implemented, the engine returns `{error, not_supported}`.
""".
-callback encode_interrupt(HandlerState :: term()) ->
    {ok, [handler_action()], term()} | not_supported.

-doc """
Handle `send_control/3` calls.

Called when the consumer sends a control message to the backend.
The `From` parameter allows deferred replies — the handler can store
it and call `gen_statem:reply(From, {ok, Result})` later when the
backend responds (e.g., in `handle_data/2`).

If not implemented, the engine returns `{error, not_supported}`.
""".
-callback handle_control(
    Method       :: binary(),
    Params       :: map(),
    From         :: gen_statem:from(),
    HandlerState :: term()
) -> control_result().

-doc """
Handle `set_model/2` calls.

If not implemented, the engine stores the model in its own state
and returns `{ok, Model}`.
""".
-callback handle_set_model(
    Model        :: binary(),
    HandlerState :: term()
) -> {ok, Result :: term(), [handler_action()], term()} | {error, term()}.

-doc """
Handle `set_permission_mode/2` calls.

If not implemented, the engine stores the mode and returns `{ok, Mode}`.
""".
-callback handle_set_permission_mode(
    Mode         :: binary(),
    HandlerState :: term()
) -> {ok, Result :: term(), [handler_action()], term()} | {error, term()}.

-doc """
Called on each state transition (enter event).

Allows the handler to perform side effects on state transitions,
such as firing lifecycle hooks or sending initialization data.

The handler can call any function directly (e.g., `beam_agent_hooks_core:fire/3`).
Return send actions for transport I/O. The engine fires telemetry
separately — the handler should not duplicate telemetry calls.

If not implemented, the engine only fires telemetry on transitions.
""".
-callback on_state_enter(
    NewState     :: state_name(),
    OldState     :: state_name() | undefined,
    HandlerState :: term()
) -> {ok, [handler_action()], term()}.

-doc """
Detect whether a message signals query completion.

Called for each decoded message during `active_query`. If the handler
returns `true`, the engine transitions back to `ready` after delivering
the message.

Default: checks for `type => result` in the message map.
""".
-callback is_query_complete(
    Message      :: beam_agent_core:message(),
    HandlerState :: term()
) -> boolean().

-doc """
Handle backend-specific API calls not covered by `beam_agent_behaviour`.

Called when the engine receives a `gen_statem:call` it does not recognize.
This allows backends to expose custom functions (e.g., Codex RT's
`thread_realtime_start/2`; OpenCode's `subscribe_events/1`) without
modifying the engine.

The `From` parameter allows deferred replies if needed.

If not implemented, the engine returns `{error, unsupported}`.
""".
-callback handle_custom_call(
    Request      :: term(),
    From         :: gen_statem:from(),
    HandlerState :: term()
) -> control_result().

-doc """
Handle raw messages the transport did not classify.

Called when `classify_message/2` returns `ignore` for an incoming
erlang message. This allows handlers to process transport-level
messages that require handler state to interpret.

Primary use case: dual-channel transports (e.g., OpenCode SSE + REST
over the same HTTP connection) where the transport cannot distinguish
SSE data from REST responses without knowing which stream ref is which.

The handler receives the raw message, the current state name, and its
state. It can:
  - Deliver messages to the consumer: `{messages, Msgs, Actions, HState}`
  - Trigger a state transition: any `phase_result()` variant
  - Decline to handle: `ignore` (engine discards the message)

If not implemented, the engine discards all unclassified messages.
""".
-callback handle_info(
    Message      :: term(),
    StateName    :: state_name(),
    HandlerState :: term()
) -> info_result().

-optional_callbacks([
    transport_started/2,
    handle_connecting/2,
    handle_initializing/2,
    encode_interrupt/1,
    handle_control/4,
    handle_set_model/2,
    handle_set_permission_mode/2,
    on_state_enter/3,
    is_query_complete/2,
    handle_custom_call/3,
    handle_info/3
]).
