# Backend Integration Guide

How to add a new agentic coder backend to BeamAgent.

---

## Table of Contents

- [Part 1: Overview](#part-1-overview)
  - [What Is a Backend?](#what-is-a-backend)
  - [Architecture](#architecture)
  - [Module Relationships](#module-relationships)
  - [Prerequisites](#prerequisites)
- [Part 2: Step-by-Step Implementation](#part-2-step-by-step-implementation)
  - [Step 1: Implementing beam_agent_session_handler Callbacks](#step-1-implementing-beam_agent_session_handler-callbacks)
  - [Step 2: Choosing and Implementing a Transport](#step-2-choosing-and-implementing-a-transport)
  - [Step 3: Writing the Protocol Parser](#step-3-writing-the-protocol-parser)
  - [Step 4: Creating the Backend Adapter Module](#step-4-creating-the-backend-adapter-module)
  - [Step 5: Registering the Backend](#step-5-registering-the-backend)
  - [Step 6: Wiring Universal Fallbacks in beam_agent.erl](#step-6-wiring-universal-fallbacks-in-beam_agenterl)
  - [Step 7: Testing](#step-7-testing)
- [Part 3: Advanced Topics](#part-3-advanced-topics)
  - [The Session Engine State Machine](#the-session-engine-state-machine)
  - [Handler State Management Patterns](#handler-state-management-patterns)
  - [Error Recovery and Reconnection](#error-recovery-and-reconnection)
  - [Performance Considerations](#performance-considerations)
  - [Thick Framework, Thin Adapters](#thick-framework-thin-adapters)
  - [The Event Streaming Architecture](#the-event-streaming-architecture)
  - [MCP Integration](#mcp-integration)
- [Part 4: Reference](#part-4-reference)
  - [Complete Callback Reference](#complete-callback-reference)
  - [Capability Matrix Explained](#capability-matrix-explained)
  - [Backend Readiness Checklist](#backend-readiness-checklist)

---

## Part 1: Overview

### What Is a Backend?

A **backend** in BeamAgent is an adapter layer that connects the unified
BeamAgent SDK to a specific agentic coder CLI tool. Each backend
translates between BeamAgent's normalized API and the wire protocol spoken
by one external agent (Claude Code, Codex, Gemini CLI, OpenCode, or
GitHub Copilot).

The existing backends live under `src/backends/`:

```
src/backends/
  claude/        # Claude Code (claude_agent_sdk)
  codex/         # OpenAI Codex (codex_app_server)
  copilot/       # GitHub Copilot (copilot_client)
  gemini/        # Gemini CLI (gemini_cli_client)
  opencode/      # OpenCode (opencode_client)
```

Every backend consists of exactly four module layers:

| Layer | Module naming | Purpose |
|-------|--------------|---------|
| **Session handler** | `*_session_handler.erl` | Implements `beam_agent_session_handler` callbacks |
| **Session wrapper** | `*_session.erl` | Thin wrapper implementing `beam_agent_behaviour` |
| **Adapter (client)** | `*_client.erl` or `*_sdk.erl` | High-level facade with backend-specific features |
| **Protocol helpers** | `*_protocol.erl`, `*_frame.erl` | Wire format encoding/decoding |


### Architecture

The following diagram shows how a query flows from user code through the
BeamAgent stack down to a backend CLI process and back:

```
                      User Code
                         |
                         v
              +---------------------+
              |    beam_agent.erl   |   Public API (native_or routing)
              +---------------------+
                         |
              +---------------------+
              | beam_agent_core.erl |   Shared lifecycle helpers
              +---------------------+
                         |
              +---------------------+
              | beam_agent_behaviour|   Callback contract
              +---------------------+
                         |
         +-------------------------------+
         |  *_session.erl               |   e.g., copilot_session
         |  (beam_agent_behaviour impl) |   Thin delegation layer
         +-------------------------------+
                         |
         +-------------------------------+
         | beam_agent_session_engine.erl |   gen_statem framework
         |   - State machine lifecycle  |   (connecting -> initializing
         |   - Consumer/queue mgmt      |    -> ready -> active_query)
         |   - Telemetry, buffer mgmt   |
         |   - Transport lifecycle      |
         +-------------------------------+
                |                |
     callbacks  |                | transport I/O
                v                v
  +-------------------------+  +---------------------------+
  | *_session_handler.erl  |  | beam_agent_transport_*.erl|
  | (handler callbacks)    |  | (byte I/O abstraction)    |
  +-------------------------+  +---------------------------+
                                         |
                                         v
                                  +-----------+
                                  |  CLI      |
                                  | Process   |
                                  +-----------+
```

Key architectural property: **zero additional processes**. The
`beam_agent_session_engine` gen_statem IS the session process. The handler
callbacks run synchronously inside the gen_statem. The transport (for port
transports) is an Erlang port owned by the gen_statem process.


### Module Relationships

Understanding which module does what is critical before you start coding.

**`beam_agent_session_handler`** (`src/core/beam_agent_session_handler.erl`)
is the behaviour (interface) that your handler module must implement. It
defines ~6 required callbacks and ~11 optional callbacks. The session engine
calls these callbacks at well-defined points in the session lifecycle.

**`beam_agent_session_engine`** (`src/core/beam_agent_session_engine.erl`)
is the gen_statem that drives all session handlers. It manages the state
machine, consumer/queue, buffer, telemetry, and transport lifecycle. You
never modify this module when adding a backend.

**`beam_agent_transport`** (`src/transports/beam_agent_transport.erl`)
is the behaviour for transports. The engine calls `TransportModule:start/1`
to launch the transport and `TransportModule:classify_message/2` on every
incoming Erlang message to determine if the message belongs to this
transport.

**`beam_agent_behaviour`** (`src/core/beam_agent_behaviour.erl`)
is the top-level behaviour that the session wrapper module implements.
It provides the unified API contract (`start_link`, `send_query`,
`receive_message`, `health`, `stop`) that consumers program against.

**`beam_agent_backend`** (`src/core/beam_agent_backend.erl`)
is the backend registry. It normalizes backend identifiers, maps backends
to adapter modules, and caches session-to-backend lookups.

**`beam_agent_capabilities`** (`src/public/beam_agent_capabilities.erl`)
is the capability registry. Every backend must declare its support level
for all 22 capabilities.


### Prerequisites

Before adding a new backend, you need:

1. **A working CLI binary** for the agentic coder you want to integrate.
   BeamAgent backends communicate with external CLI processes via stdin/stdout,
   HTTP, or WebSocket -- not embedded libraries.

2. **Protocol documentation** for the CLI's wire format. You need to know:
   - How the CLI is launched (command-line arguments, environment variables)
   - What framing it uses (JSONL, Content-Length framed JSON-RPC, SSE, etc.)
   - The initialization handshake (if any)
   - The query request/response format
   - How streaming responses are delivered (notifications, SSE events, etc.)
   - How to detect query completion (terminal message format)

3. **An Erlang/OTP development environment** with:
   - Erlang/OTP 27+
   - rebar3
   - The BeamAgent repository cloned and compiling (`rebar3 compile`)


---

## Part 2: Step-by-Step Implementation

This section walks through every step needed to add a backend called
`myagent`. Replace `myagent` with your actual backend name throughout.

### Step 1: Implementing beam_agent_session_handler Callbacks

Create `src/backends/myagent/myagent_session_handler.erl`. This is the
core of your backend -- where all protocol logic lives.

```erlang
-module(myagent_session_handler).
-behaviour(beam_agent_session_handler).
```

The handler behaviour defines six **required** callbacks and eleven
**optional** callbacks. We walk through each one below.


#### Required Callback 1: `backend_name/0`

```erlang
-callback backend_name() -> atom().
```

**What it does:** Returns a unique atom identifying your backend. Used for
telemetry event names, session registration, and capability lookups.

**When called:** During engine init, on every telemetry event, and when
building session info.

**Expected return:** A single atom. Must match the atom you register in
`beam_agent_backend`.

**Example (from Copilot handler):**

```erlang
-spec backend_name() -> copilot.
backend_name() -> copilot.
```

**Your implementation:**

```erlang
-spec backend_name() -> myagent.
backend_name() -> myagent.
```

**Common mistakes:**
- Returning a binary instead of an atom. This must be an atom.
- Using a name that conflicts with an existing backend.


#### Required Callback 2: `init_handler/1`

```erlang
-callback init_handler(Opts :: beam_agent_core:session_opts()) ->
    init_result().
```

**What it does:** Initializes the handler. Called once during
session engine initialization. Returns the transport configuration,
the initial state machine state, and the opaque handler state that will be
threaded through all subsequent callbacks.

**When called:** Exactly once, when the session starts.

**Expected return type:**

```erlang
-type init_result() :: {ok, #{
    transport_spec := {module(), map()},
    initial_state  := connecting | initializing | ready,
    handler_state  := term()
}} | {stop, term()}.
```

The three fields:

- `transport_spec`: A `{TransportModule, TransportOpts}` tuple. The engine
  calls `TransportModule:start(TransportOpts)` to start the transport.
- `initial_state`: Where the state machine begins.
  - `connecting` -- transport needs async setup, or backend must wait for
    a system init message before handshake (most common for CLI backends).
  - `initializing` -- transport is immediately ready, protocol handshake
    needed.
  - `ready` -- no handshake required (useful for testing or stateless
    protocols).
- `handler_state`: Your opaque state. Typically an Erlang record containing
  protocol buffers, pending request maps, configuration, and SDK registries.

**Example (from Copilot handler, simplified):**

```erlang
init_handler(Opts) ->
    CliPath = resolve_cli_path(Opts),
    Args = copilot_protocol:build_cli_args(Opts),
    Env = copilot_protocol:build_env(Opts),
    TransportOpts = #{
        executable      => CliPath,
        args            => Args,
        env             => Env,
        mode            => raw,           %% Content-Length framing, not JSONL
        extra_port_opts => [hide]
    },
    HState = #hstate{
        cli_path  = CliPath,
        opts      = Opts,
        model     = maps:get(model, Opts, undefined)
    },
    {ok, #{
        transport_spec => {beam_agent_transport_port, TransportOpts},
        initial_state  => connecting,
        handler_state  => HState
    }}.
```

**Key decisions you make here:**
- Which transport module to use (see Step 2)
- Whether to start in `connecting`, `initializing`, or `ready`
- What state to carry forward (pending requests, buffers, config)

**Common mistakes:**
- Forgetting to extract `session_id` from `Opts`. The engine generates a
  session_id and includes it in `Opts` before calling `init_handler/1`.
- Using `mode => line` when the backend uses non-JSONL framing (Content-Length,
  SSE, etc.). This causes data corruption.
- Not returning `{stop, Reason}` on invalid configuration. The engine will
  crash with a less helpful error if you let bad config through.

> **Tip:** The engine calls `TransportModule:start(TransportOpts)` immediately
> after `init_handler/1` returns. If transport start fails, the engine
> returns `{stop, {transport_start_failed, Reason}}`. You do not need to
> start the transport yourself.


#### Required Callback 3: `handle_data/2`

```erlang
-callback handle_data(
    Buffer       :: binary(),
    HandlerState :: term()
) -> data_result().
```

**What it does:** Decodes incoming transport data into normalized messages.
This is the heart of your protocol parser.

**When called:** When the engine receives data from the transport during
the `ready` or `active_query` states. The engine combines the old buffer
with new data before calling this function, so `Buffer` contains all
accumulated bytes.

**Expected return type:**

```erlang
-type data_result() :: {ok,
    Messages        :: [beam_agent_core:message()],
    LeftoverBuffer  :: binary(),
    Actions         :: [handler_action()],
    NewHandlerState :: term()
}.
```

The four return elements:

1. `Messages`: A list of normalized messages to deliver to the consumer.
   Each message is a map following the `beam_agent_core:message()` format
   (see "Message Format" below).
2. `LeftoverBuffer`: Any incomplete data that could not be parsed. The
   engine stores this and prepends it to the next chunk.
3. `Actions`: A list of `{send, Data}` actions. The engine sends each
   `Data` value via the transport. Use this to send protocol-level
   responses (e.g., responding to server-side JSON-RPC requests).
4. `NewHandlerState`: Your updated handler state.

**Message format:** Every message must be a map with at least a `type` key:

| Type | Meaning | Required keys |
|------|---------|---------------|
| `assistant` | Full assistant message | `content` |
| `text` | Streaming text delta | `content` |
| `thinking` | Reasoning/thinking content | `content` |
| `tool_use` | Tool invocation | `tool_name`, `tool_input` |
| `tool_result` | Tool output | `tool_name`, `content` |
| `result` | Query complete (terminal) | -- |
| `error` | Error (may be terminal) | `content` |
| `system` | System event | `subtype`, `content` |
| `control_request` | Permission/hook request | `subtype`, `content` |
| `control_response` | Permission resolution | `subtype`, `content` |
| `raw` | Unrecognized event | `content` |

**Example (from Copilot handler):**

```erlang
handle_data(Buffer, HState) ->
    %% 1. Extract complete Content-Length framed messages
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Buffer),
    %% 2. Dispatch JSON-RPC: responses update pending map,
    %%    notifications yield events, requests get handled inline
    {Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    %% 3. Normalize raw events into beam_agent_core:message() format
    Messages = [copilot_protocol:normalize_event(E) || E <- Events],
    %% 4. Fire hooks on messages, track in session store
    {DeliverMsgs, Actions, HState2} =
        process_normalized_messages(Messages, HState1, [], []),
    {ok, DeliverMsgs, RestBuf, Actions, HState2}.
```

**Common mistakes:**
- Not returning the leftover buffer. If you return `<<>>` when there is
  partial data, you lose bytes and the next message will be corrupted.
- Returning messages that the consumer should not see (e.g., internal
  protocol handshake responses). Filter these out and only return
  user-visible messages.
- Forgetting to handle server-side requests (requests from the CLI to the
  SDK). These must be processed and responded to in `handle_data` via
  send actions.

> **Warning:** The engine calls `handle_data/2` only in `ready` and
> `active_query` states. During `connecting` and `initializing`, data is
> routed to `handle_connecting/2` and `handle_initializing/2` instead.


#### Required Callback 4: `encode_query/3`

```erlang
-callback encode_query(
    Prompt       :: binary(),
    Params       :: beam_agent_core:query_opts(),
    HandlerState :: term()
) -> {ok, term(), term()} | {error, term()}.
```

**What it does:** Encodes a user query into the backend's wire format.

**When called:** When `send_query/4` is received in the `ready` state.
The engine sends the returned data via the transport and transitions to
`active_query`.

**Expected return:**
- `{ok, EncodedData, NewHandlerState}` on success. `EncodedData` is
  passed to `TransportModule:send/2`.
- `{error, Reason}` if the query cannot be encoded (e.g., no active
  session).

**Example (from Copilot handler):**

```erlang
encode_query(Prompt, Params,
             #hstate{copilot_session_id = SessionId} = HState) ->
    ReqId = make_request_id(HState),
    SendParams = copilot_protocol:build_session_send_params(
                     SessionId, Prompt, Params),
    Msg = copilot_protocol:encode_request(
              ReqId, <<"session.send">>, SendParams),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, Encoded, HState1}.
```

**Common mistakes:**
- Not checking for preconditions (e.g., the Copilot handler returns
  `{error, no_session}` if `copilot_session_id` is `undefined`).
- Forgetting to update handler state (e.g., incrementing request ID
  counters, adding to pending request maps).


#### Required Callback 5: `build_session_info/1`

```erlang
-callback build_session_info(HandlerState :: term()) -> map().
```

**What it does:** Builds the handler-specific portion of session info.
The engine merges this map with engine-level metadata (`session_id`,
`model`, current state).

**When called:** Whenever `session_info/1` is called, in any state.

**Expected return:** A map. At minimum, include `adapter => myagent`.

**Example (from Copilot handler):**

```erlang
build_session_info(#hstate{copilot_session_id = CopilotSId,
                            cli_path = CliPath,
                            model = Model}) ->
    Base = #{adapter => copilot,
             model => Model,
             cli_path => list_to_binary(CliPath)},
    case CopilotSId of
        undefined -> Base;
        SId -> Base#{copilot_session_id => SId}
    end.
```

**Common mistakes:**
- Omitting the `adapter` key. The `beam_agent_backend:session_backend/1`
  function uses this field to resolve which backend a session belongs to.


#### Required Callback 6: `terminate_handler/2`

```erlang
-callback terminate_handler(Reason :: term(), HandlerState :: term()) -> ok.
```

**What it does:** Cleans up handler-specific resources. The engine closes
the transport separately -- you only need to clean up your own resources
(ETS tables, hook registries, pending caller replies, etc.).

**When called:** During engine `terminate/3`.

**Expected return:** `ok`.

**Example (from Copilot handler):**

```erlang
terminate_handler(Reason, #hstate{pending = Pending} = HState) ->
    _ = fire_hook(session_end,
                  #{event => session_end, reason => Reason},
                  HState),
    %% Reply {error, session_terminated} to all pending callers
    maps:foreach(
        fun(_Id, {From, TRef}) ->
            cancel_timer(TRef),
            case From of
                internal -> ok;
                internal_create -> ok;
                internal_resume -> ok;
                _ -> gen_statem:reply(From, {error, session_terminated})
            end
        end,
        Pending),
    ok.
```

**Common mistakes:**
- Not replying to pending callers. If your handler stores `gen_statem:from()`
  values for deferred replies (e.g., in a pending map), you must reply to
  them in `terminate_handler/2` or those callers will hang.


#### Optional Callbacks

The following callbacks are optional. Implement them as needed for your
backend's protocol requirements.

##### `transport_started/2`

```erlang
-callback transport_started(
    Ref          :: beam_agent_transport:transport_ref(),
    HandlerState :: term()
) -> term().
```

**What it does:** Called after the engine starts the transport. Store the
transport reference if you need direct access (e.g., sending OS signals
to a port process, or making HTTP requests directly on a connection).

**When to implement:** Always implement this if you use `beam_agent_transport_port`
and need to call `port_command/2` directly (e.g., for responding to
server-side requests outside of `handle_data`).

**Example (from Copilot handler):**

```erlang
transport_started(TRef, HState) ->
    HState#hstate{port_ref = TRef}.
```

##### `handle_connecting/2`

```erlang
-callback handle_connecting(
    Event        :: transport_event(),
    HandlerState :: term()
) -> phase_result().
```

**What it does:** Handles transport events during the `connecting` phase.
You decide when to transition to `initializing` or `ready`.

**When to implement:** When `initial_state` is `connecting` (most CLI
backends).

**Transport events you may receive:**

| Event | Meaning |
|-------|---------|
| `{data, Binary}` | Data arrived from the transport |
| `connected` | Transport connection established (HTTP/WS) |
| `{disconnected, Reason}` | Transport disconnected |
| `{exit, Status}` | Transport process exited |
| `connect_timeout` | Connection timeout fired |

**Return type (`phase_result()`):**

```erlang
-type phase_result() ::
    {next_state, initializing | ready, [handler_action()], term()}
  | {next_state, initializing | ready, [handler_action()], term(),
     LeftoverBuffer :: binary()}
  | {keep_state, [handler_action()], term()}
  | {error_state, Reason :: term(), term()}.
```

The 5-tuple variant with `LeftoverBuffer` passes remaining data to the
engine for continued processing in the next state. Use this when your
connecting-phase parse consumed some bytes but left others.

**Example (from Copilot handler):**

```erlang
handle_connecting({data, RawData}, HState) ->
    Combined = <<(HState#hstate.init_buffer)/binary, RawData/binary>>,
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Combined),
    {_Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    HState2 = HState1#hstate{init_buffer = RestBuf},
    case maps:size(HState2#hstate.pending) of
        0 ->
            %% Ping response received -- transition to initializing
            {next_state, initializing, [],
             HState2#hstate{init_buffer = <<>>}, RestBuf};
        _ ->
            {keep_state, [], HState2}
    end;
handle_connecting({exit, Status}, HState) ->
    {error_state, {cli_exit, Status}, HState};
handle_connecting(connect_timeout, HState) ->
    {error_state, {timeout, connecting}, HState};
handle_connecting(_Event, HState) ->
    {keep_state, [], HState}.
```

> **Tip:** Notice the 5-tuple return on transition: `{next_state,
> initializing, [], HState2, RestBuf}`. This hands leftover bytes to the
> engine so they get processed in the `initializing` state.

##### `handle_initializing/2`

```erlang
-callback handle_initializing(
    Event        :: transport_event(),
    HandlerState :: term()
) -> phase_result().
```

**What it does:** Handles transport events during the `initializing` phase.
Process the backend's init handshake and transition to `ready` when the
handshake completes.

**When to implement:** When the backend requires an initialization handshake
(session.create, capability exchange, etc.).

**Example (from Copilot handler):**

```erlang
handle_initializing({data, RawData}, HState) ->
    Combined = <<(HState#hstate.init_buffer)/binary, RawData/binary>>,
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Combined),
    {_Events, HState1} = dispatch_jsonrpc(RawMsgs, HState, []),
    HState2 = HState1#hstate{init_buffer = RestBuf},
    case HState2#hstate.copilot_session_id of
        undefined ->
            {keep_state, [], HState2};
        _SessionId ->
            %% Session created -- transition to ready
            {next_state, ready, [],
             HState2#hstate{init_buffer = <<>>}, RestBuf}
    end.
```

##### `on_state_enter/3`

```erlang
-callback on_state_enter(
    NewState     :: state_name(),
    OldState     :: state_name() | undefined,
    HandlerState :: term()
) -> {ok, [handler_action()], term()}.
```

**What it does:** Called on each state transition (enter event). Use this
to send initialization messages when entering a new state or fire lifecycle
hooks.

**When to implement:** When you need to send protocol messages on state
transitions (e.g., ping on entering `connecting`, session.create on entering
`initializing`, fire session_start hook on entering `ready`).

**Example (from Copilot handler):**

```erlang
on_state_enter(connecting, _OldState, HState) ->
    %% Send ping request
    ReqId = make_request_id(HState),
    PingMsg = copilot_protocol:encode_request(
                  ReqId, <<"ping">>, #{<<"message">> => <<"hello">>}),
    Encoded = copilot_frame:encode_message(PingMsg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1};
on_state_enter(initializing, _OldState, HState) ->
    %% Send session.create or session.resume
    {Method, Params, PendingTag} = init_request(HState),
    ReqId = make_request_id(HState),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {PendingTag, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1};
on_state_enter(ready, OldState, HState)
  when OldState =:= initializing; OldState =:= connecting ->
    _ = fire_hook(session_start, #{session_id => ...}, HState),
    {ok, [], HState};
on_state_enter(_State, _OldState, HState) ->
    {ok, [], HState}.
```

##### `encode_interrupt/1`

```erlang
-callback encode_interrupt(HandlerState :: term()) ->
    {ok, [handler_action()], term()} | not_supported.
```

**What it does:** Encodes an interrupt signal to abort the current query.

**When called:** When `interrupt/1` is called during `active_query`.

**Return:** `{ok, Actions, NewState}` to send interrupt actions, or
`not_supported` if the backend does not support interruption.

**Example (from Copilot handler):**

```erlang
encode_interrupt(#hstate{copilot_session_id = SessionId} = HState) ->
    ReqId = make_request_id(HState),
    Params = #{<<"sessionId">> => SessionId},
    Msg = copilot_protocol:encode_request(
              ReqId, <<"session.abort">>, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           HState#hstate.pending)
    },
    {ok, [{send, Encoded}], HState1}.
```

##### `is_query_complete/2`

```erlang
-callback is_query_complete(
    Message      :: beam_agent_core:message(),
    HandlerState :: term()
) -> boolean().
```

**What it does:** Determines whether a message signals query completion.

**When called:** For each decoded message during `active_query`. If you
return `true`, the engine transitions back to `ready`.

**Default behavior:** If not implemented, the engine checks for
`type => result` in the message map.

**When to implement:** When your backend has non-standard terminal messages.
For example, Copilot emits non-terminal `error` messages (warnings), so
it must distinguish fatal errors from informational ones.

**Example (from Copilot handler):**

```erlang
is_query_complete(#{type := result}, _HState) -> true;
is_query_complete(#{type := error, is_error := true}, _HState) -> true;
is_query_complete(_Msg, _HState) -> false.
```

##### `handle_control/4`

```erlang
-callback handle_control(
    Method       :: binary(),
    Params       :: map(),
    From         :: gen_statem:from(),
    HandlerState :: term()
) -> control_result().
```

**What it does:** Handles `send_control/3` calls from the consumer.

**Return type:**

```erlang
-type control_result() ::
    {reply, Result :: term(), [handler_action()], term()}
  | {noreply, [handler_action()], term()}
  | {error, term()}.
```

The `noreply` variant defers the reply. Store `From` and call
`gen_statem:reply(From, {ok, Result})` later when the backend responds
(typically in `handle_data/2`).

**Example (from Copilot handler):**

```erlang
handle_control(Method, Params, From, HState) ->
    ReqId = make_request_id(HState),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    Encoded = copilot_frame:encode_message(Msg),
    HState1 = HState#hstate{
        next_id = HState#hstate.next_id + 1,
        pending = maps:put(ReqId, {From, undefined},
                           HState#hstate.pending)
    },
    {noreply, [{send, Encoded}], HState1}.
```

##### `handle_set_model/2`

```erlang
-callback handle_set_model(
    Model        :: binary(),
    HandlerState :: term()
) -> {ok, Result :: term(), [handler_action()], term()} | {error, term()}.
```

**What it does:** Handles runtime model switching.

**Default behavior:** If not implemented, the engine stores the model in
its own state and returns `{ok, Model}`.

**When to implement:** When the backend has a native model-switching
protocol command.

##### `handle_set_permission_mode/2`

```erlang
-callback handle_set_permission_mode(
    Mode         :: binary(),
    HandlerState :: term()
) -> {ok, Result :: term(), [handler_action()], term()} | {error, term()}.
```

**What it does:** Handles runtime permission mode changes.

**Default behavior:** If not implemented, the engine stores the mode and
returns `{ok, Mode}`.

##### `handle_custom_call/3`

```erlang
-callback handle_custom_call(
    Request      :: term(),
    From         :: gen_statem:from(),
    HandlerState :: term()
) -> control_result().
```

**What it does:** Handles backend-specific API calls not covered by the
standard callbacks. The engine routes any unrecognized `gen_statem:call`
to this callback.

**When to implement:** When your backend exposes custom functions (e.g.,
Codex's `thread_realtime_start/2`).

##### `handle_info/3`

```erlang
-callback handle_info(
    Message      :: term(),
    StateName    :: state_name(),
    HandlerState :: term()
) -> info_result().
```

**What it does:** Handles raw messages the transport did not classify.
Called when `classify_message/2` returns `ignore`.

**Primary use case:** Dual-channel transports (e.g., HTTP transports where
SSE data arrives as `http_data` messages that the transport cannot classify
without handler context).

**Return type:**

```erlang
-type info_result() ::
    {messages, [beam_agent_core:message()], [handler_action()], term()}
  | phase_result()
  | ignore.
```


### Step 2: Choosing and Implementing a Transport

BeamAgent provides four transport modules. Choose the one that matches
your backend's communication model.

#### Option A: `beam_agent_transport_port` (stdio subprocess)

**Source:** `src/transports/beam_agent_transport_port.erl`

**When to use:** The backend is a local CLI binary that communicates over
stdin/stdout. This is the most common transport for agentic coders.

**Two modes:**

| Mode | Port options | Use case |
|------|-------------|----------|
| `line` (default) | `{line, N}` | JSONL protocols (one JSON object per line). Claude, Codex, Gemini. |
| `raw` | `stream` | Custom framing (Content-Length, binary protocols). Copilot. |

**Configuration example (line mode for JSONL):**

```erlang
TransportOpts = #{
    executable => "/usr/local/bin/myagent-cli",
    args       => ["--json", "--no-color"],
    env        => [{"NO_COLOR", "1"}],
    mode       => line
}.
{beam_agent_transport_port, TransportOpts}
```

**Configuration example (raw mode for Content-Length framing):**

```erlang
TransportOpts = #{
    executable      => "/usr/local/bin/copilot",
    args            => ["server", "--stdio"],
    env             => [{"NO_COLOR", "1"}],
    mode            => raw,
    extra_port_opts => [hide]
}.
{beam_agent_transport_port, TransportOpts}
```

**How data arrives:** In line mode, the transport re-appends the newline
stripped by `{line, N}` mode, so your handler receives complete JSONL lines.
In raw mode, you receive arbitrary binary chunks and must handle framing
yourself.

#### Option B: `beam_agent_transport_http` (HTTP / SSE)

**Source:** `src/transports/beam_agent_transport_http.erl`

**When to use:** The backend communicates via HTTP REST and/or Server-Sent
Events. The transport establishes a TCP connection. HTTP-level messages
(`http_response`, `http_data`) are returned as `ignore` by `classify_message`
-- your handler processes them via `handle_info/3`.

**Configuration example:**

```erlang
TransportOpts = #{
    host => <<"localhost">>,
    port => 4096
}.
{beam_agent_transport_http, TransportOpts}
```

> **Tip:** The HTTP transport uses `beam_agent_http_client` for the
> underlying connection. Pass `client_module` in opts to inject a test
> implementation.

#### Option C: `beam_agent_transport_ws` (WebSocket)

**Source:** `src/transports/beam_agent_transport_ws.erl`

**When to use:** The backend communicates via WebSocket. The transport
manages connection, upgrade, and frame classification. Send actions use
the `{ws_frames, WsRef, [MessageMap]}` format.

**Configuration example:**

```erlang
TransportOpts = #{
    host   => <<"localhost">>,
    port   => 8080,
    scheme => <<"wss">>
}.
{beam_agent_transport_ws, TransportOpts}
```

**Connection lifecycle:**
1. `start/1` opens a TCP/TLS connection and returns `{ConnPid, MonRef, WsModule}`
2. `classify_message` returns `connected` on `transport_up`
3. Your handler calls `WsModule:ws_upgrade(ConnPid, Path, Headers)` to get a `WsRef`
4. `classify_message` returns `connected` on `ws_upgraded`
5. Incoming frames arrive as `{data, Payload}` events

#### Option D: Custom Transport

Implement the `beam_agent_transport` behaviour:

```erlang
-module(myagent_transport).
-behaviour(beam_agent_transport).

-export([start/1, send/2, close/1, is_ready/1, status/1, classify_message/2]).

start(Opts) ->
    %% Start your transport and return a reference
    {ok, Ref}.

send(Ref, Data) ->
    %% Send data via the transport
    ok.

close(Ref) ->
    %% Close the transport
    ok.

is_ready(Ref) ->
    %% Return true if transport can send/receive
    true.

status(Ref) ->
    %% Return running | {exited, Status}
    running.

classify_message(Msg, Ref) ->
    %% Return a transport_event() or ignore
    ignore.
```

The transport MUST deliver received data as Erlang messages to the calling
process (the gen_statem owner). For custom transports, send messages as
`{transport_data, Ref, Binary}` and classify them in `classify_message/2`.


### Step 3: Writing the Protocol Parser

Your protocol parser is the bridge between raw wire bytes and normalized
`beam_agent_core:message()` maps. Typically this is split into two modules:

1. **Frame extraction** (`myagent_frame.erl`) -- extracts complete protocol
   frames from a byte buffer.
2. **Protocol translation** (`myagent_protocol.erl`) -- translates extracted
   frames into normalized messages and encodes outgoing requests.

#### Frame Extraction

The job of the frame extractor is: given a binary buffer that may contain
zero or more complete frames plus a partial trailing frame, extract all
complete frames and return the leftover bytes.

**JSONL framing** (one JSON object per newline-delimited line):

Use the built-in `beam_agent_jsonl` module:

```erlang
%% In your handle_data/2:
{Lines, RestBuf} = beam_agent_jsonl:extract_lines(Buffer),
Decoded = [beam_agent_jsonl:decode_line(L) || L <- Lines],
Messages = [Msg || {ok, Msg} <- Decoded],
```

**Content-Length framing** (e.g., JSON-RPC with `Content-Length:` headers):

Study `src/backends/copilot/copilot_frame.erl` for a complete
implementation. The pattern is:

```erlang
extract_message(Buffer) ->
    case find_header_boundary(Buffer) of    %% Look for "\r\n\r\n"
        nomatch -> incomplete;
        {HeaderEnd, BodyStart} ->
            case parse_content_length(Header) of
                {ok, ContentLength} ->
                    case byte_size(Buffer) - BodyStart >= ContentLength of
                        true ->
                            Body = binary:part(Buffer, BodyStart, ContentLength),
                            Rest = binary:part(Buffer, BodyStart + ContentLength,
                                               byte_size(Buffer) - BodyStart - ContentLength),
                            decode_body(Body, Rest);
                        false ->
                            incomplete
                    end
            end
    end.
```

**SSE framing** (Server-Sent Events):

Use `opencode_sse` for SSE parsing:

```erlang
State0 = opencode_sse:new_state(),
{Events, State1} = opencode_sse:parse_chunk(Chunk, State0),
```

#### Protocol Translation

Create a `myagent_protocol.erl` module that handles:

1. **Normalizing incoming events** into `beam_agent_core:message()` format:

```erlang
-spec normalize_event(map()) -> beam_agent_core:message().
normalize_event(#{<<"type">> := <<"text_delta">>, <<"content">> := C}) ->
    #{type => text, content => C};
normalize_event(#{<<"type">> := <<"tool_call">>, <<"name">> := N,
                  <<"input">> := I}) ->
    #{type => tool_use, tool_name => N, tool_input => I};
normalize_event(#{<<"type">> := <<"done">>}) ->
    #{type => result};
normalize_event(Event) ->
    #{type => raw, content => Event}.
```

2. **Encoding outgoing requests**:

```erlang
-spec encode_query(binary(), binary(), map()) -> map().
encode_query(SessionId, Prompt, Params) ->
    #{<<"type">> => <<"query">>,
      <<"session_id">> => SessionId,
      <<"prompt">> => Prompt,
      <<"params">> => Params}.
```

3. **Building CLI arguments and environment variables**:

```erlang
-spec build_cli_args(map()) -> [string()].
build_cli_args(Opts) ->
    Base = ["--json", "--no-interactive"],
    case maps:get(model, Opts, undefined) of
        undefined -> Base;
        Model -> Base ++ ["--model", binary_to_list(Model)]
    end.
```

> **Tip:** Keep frame extraction and protocol translation in separate
> modules. Frame extraction is pure binary parsing and easy to test with
> property-based tests. Protocol translation involves business logic and
> is better tested with unit tests.


### Step 4: Creating the Backend Adapter Module

The adapter module (`myagent_client.erl`) is the high-level facade that
consumers use directly for backend-specific features. It wraps the session
module and provides convenience functions.

#### The Session Wrapper

First, create `src/backends/myagent/myagent_session.erl`:

```erlang
-module(myagent_session).
-behaviour(beam_agent_behaviour).

%% beam_agent_behaviour callbacks
-export([start_link/1, send_query/4, receive_message/3, health/1, stop/1]).

%% Extended session API
-export([send_control/3, interrupt/1, session_info/1, set_model/2,
         set_permission_mode/2]).

start_link(Opts) ->
    beam_agent_session_engine:start_link(myagent_session_handler, Opts).

send_query(Pid, Prompt, Params, Timeout) ->
    beam_agent_session_engine:send_query(Pid, Prompt, Params, Timeout).

receive_message(Pid, Ref, Timeout) ->
    beam_agent_session_engine:receive_message(Pid, Ref, Timeout).

health(Pid) ->
    beam_agent_session_engine:health(Pid).

stop(Pid) ->
    beam_agent_session_engine:stop(Pid).

send_control(Pid, Method, Params) ->
    beam_agent_session_engine:send_control(Pid, Method, Params).

interrupt(Pid) ->
    beam_agent_session_engine:interrupt(Pid).

session_info(Pid) ->
    beam_agent_session_engine:session_info(Pid).

set_model(Pid, Model) ->
    beam_agent_session_engine:set_model(Pid, Model).

set_permission_mode(Pid, Mode) ->
    beam_agent_session_engine:set_permission_mode(Pid, Mode).
```

This module is intentionally thin -- it only delegates to the engine.
Every session module in the codebase follows this exact pattern.

#### The Adapter/Client Module

Then create `src/backends/myagent/myagent_client.erl`:

```erlang
-module(myagent_client).

-export([
    start_session/1,
    stop/1,
    query/2, query/3,
    session_info/1,
    set_model/2,
    interrupt/1,
    health/1,
    %% ... add backend-specific exports
]).

-spec start_session(beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_session(Opts) ->
    myagent_session:start_link(Opts).

-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

-spec query(pid(), binary()) ->
    {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

-spec query(pid(), binary(), map()) ->
    {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case myagent_session:send_query(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            collect_messages(Session, Ref, Deadline, []);
        {error, _} = Err ->
            Err
    end.

%% ... Standard functions following the copilot_client pattern:
%%   session_info/1, set_model/2, interrupt/1, health/1,
%%   thread_start/2, thread_list/1, fork_session/2, etc.
%%
%% Most of these delegate to universal core modules:
%%   beam_agent_session_store_core (sessions, fork, revert, share)
%%   beam_agent_threads_core (threads)
%%   beam_agent_control_core (permission mode, thinking budget, tasks)
%%   beam_agent_checkpoint_core (file checkpointing)
%%   beam_agent_events (event streaming)
%%   beam_agent_collaboration (realtime, review)
```

Study `src/backends/copilot/copilot_client.erl` for the full list of
functions a complete adapter implements. The vast majority delegate to
universal core modules -- you do not need to reimplement session storage,
thread management, or event streaming.


### Step 5: Registering the Backend

#### 5a. Register in `beam_agent_backend`

Edit `src/core/beam_agent_backend.erl`:

1. **Add to the `backend()` type:**

```erlang
-type backend() :: claude | codex | gemini | opencode | copilot | myagent.
```

2. **Add to the `adapter_module()` type:**

```erlang
-type adapter_module() ::
    claude_agent_sdk |
    codex_app_server |
    gemini_cli_client |
    opencode_client |
    copilot_client |
    myagent_client.
```

3. **Add to `available_backends/0`:**

```erlang
available_backends() ->
    [claude, codex, gemini, opencode, copilot, myagent].
```

4. **Add `normalize/1` clauses:**

```erlang
normalize(myagent) -> {ok, myagent};
normalize(myagent_client) -> {ok, myagent};
normalize(<<"myagent">>) -> {ok, myagent};
normalize(<<"myagent_client">>) -> {ok, myagent};
```

5. **Add `adapter_module/1` clause:**

```erlang
adapter_module(myagent) -> myagent_client.
```

6. **Add `is_terminal/2` clauses if your backend has non-standard terminal
   message semantics:**

```erlang
is_terminal(myagent, #{type := result}) -> true;
is_terminal(myagent, #{type := error}) -> true;
```

#### 5b. Register capabilities in `beam_agent_capabilities`

Edit `src/public/beam_agent_capabilities.erl`:

Every capability entry must include your backend. There are 22 capabilities
that each need a support declaration. For each one, you specify:

- `support_level`: `full`, `partial`, `baseline`, or `missing`
- `implementation`: `direct_backend`, `universal`, or `direct_backend_and_universal`
- `fidelity`: `exact` or `validated_equivalent`

Most new backends will start with `universal` implementation for most
capabilities (since the universal fallback modules handle them), and
`direct_backend` for capabilities where you implement native support.

**Example entries for a new backend:**

```erlang
capability(session_lifecycle, <<"Session lifecycle">>, #{
    claude => support(full, direct_backend, exact),
    %% ... existing backends ...
    myagent => support(full, direct_backend, exact)
}),
capability(session_history, <<"Session history">>, #{
    %% ... existing backends ...
    myagent => support(full, universal, validated_equivalent)
}),
```

For all 22 capabilities, use `full` support level with `universal`
implementation and `validated_equivalent` fidelity as the starting point.
Upgrade to `direct_backend` and `exact` fidelity as you add native
protocol support.

> **Warning:** The `all/0` function must include your backend in every
> single capability entry. Missing entries cause runtime crashes when
> `beam_agent_capabilities:status/2` is called for your backend.


### Step 6: Wiring Universal Fallbacks in beam_agent.erl

The public `beam_agent.erl` module uses a pattern called `native_or` for
every API function. Understanding this pattern is essential.

#### The native_or Pattern

Located at the bottom of `src/public/beam_agent.erl`:

```erlang
native_call(Session, Function, Args) ->
    beam_agent_raw_core:call(Session, Function, Args).

native_or(Session, Function, Args, Fallback) ->
    case native_call(Session, Function, Args) of
        {error, {unsupported_native_call, _}} ->
            Fallback();
        Other ->
            Other
    end.
```

**How it works:**

1. `native_call` attempts to call `Function` on the backend's adapter module
   via the raw core dispatch layer.
2. If the adapter implements the function, its result is returned directly.
3. If the adapter does not implement the function, the raw core layer
   returns `{error, {unsupported_native_call, _}}`.
4. The `Fallback` function is then called, which invokes a universal core
   module that provides the functionality via the shared session store,
   thread system, or other framework services.

**Example usage in beam_agent.erl:**

```erlang
fork_session(Session, Opts) ->
    native_or(Session, fork_session, [Opts], fun() ->
        SessionId = session_identity(Session),
        beam_agent_session_store_core:fork_session(SessionId, Opts)
    end).
```

#### What This Means for Your Backend

For most capabilities, you do not need to modify `beam_agent.erl` at all.
The `native_or` pattern already has universal fallbacks for every function.
Your adapter module just needs to export the functions it supports natively
-- unsupported functions automatically fall through to the universal
implementation.

The only case where you would modify `beam_agent.erl` is if your backend
introduces entirely new API functions that do not exist in the current
public API.

#### Universal Fallback Modules

These modules provide the "universal" implementations that power the
fallback path:

| Module | Capabilities |
|--------|-------------|
| `beam_agent_session_store_core` | Session history, fork, revert, share, summarize |
| `beam_agent_threads_core` | Thread lifecycle, fork, archive, rollback |
| `beam_agent_file_core` | File search, find text, find symbols |
| `beam_agent_app_core` | App listing, info, init, log, modes |
| `beam_agent_account_core` | Login, logout, auth status, rate limits |
| `beam_agent_search_core` | Fuzzy file search, search sessions |
| `beam_agent_skills_core` | Skills listing, remote export, config |
| `beam_agent_control_core` | Permission mode, thinking budget, task stop |
| `beam_agent_checkpoint_core` | File checkpointing and rewind |
| `beam_agent_command_core` | Command execution |
| `beam_agent_events` | Event streaming (subscribe/receive/unsubscribe) |
| `beam_agent_collaboration` | Realtime, review, collaboration modes |
| `beam_agent_catalog_core` | Tool, skill, plugin, agent listing |
| `beam_agent_tool_registry` | MCP tool management |
| `beam_agent_hooks_core` | SDK lifecycle hooks |


### Step 7: Testing

BeamAgent has three test categories. Your backend needs tests in each.

#### Test Directory Structure

```
test/
  backends/
    myagent/
      myagent_protocol_tests.erl    # Protocol encoding/decoding
      myagent_frame_tests.erl       # Frame extraction
      myagent_session_tests.erl     # Session lifecycle
      myagent_adapter_contract_tests.erl  # Adapter contract
      prop_myagent_frame.erl        # Property-based frame tests
      prop_myagent_protocol.erl     # Property-based protocol tests
  contract/
    beam_agent_capability_contract_tests.erl  # (update existing)
  conformance/
    (cross-backend conformance tests)
```

#### Unit Tests: Protocol and Frame

Test your frame extraction with edge cases:

```erlang
-module(myagent_frame_tests).
-include_lib("eunit/include/eunit.hrl").

empty_buffer_test() ->
    ?assertEqual(incomplete, myagent_frame:extract_message(<<>>)).

single_complete_message_test() ->
    Frame = encode_test_frame(#{<<"type">> => <<"hello">>}),
    {ok, Msg, <<>>} = myagent_frame:extract_message(Frame),
    ?assertEqual(<<"hello">>, maps:get(<<"type">>, Msg)).

partial_message_test() ->
    Frame = encode_test_frame(#{<<"type">> => <<"hello">>}),
    Partial = binary:part(Frame, 0, byte_size(Frame) - 5),
    ?assertEqual(incomplete, myagent_frame:extract_message(Partial)).

multiple_messages_test() ->
    F1 = encode_test_frame(#{<<"a">> => 1}),
    F2 = encode_test_frame(#{<<"b">> => 2}),
    {Msgs, <<>>} = myagent_frame:extract_messages(<<F1/binary, F2/binary>>),
    ?assertEqual(2, length(Msgs)).
```

Test your protocol normalization:

```erlang
-module(myagent_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

normalize_text_delta_test() ->
    Event = #{<<"type">> => <<"text_delta">>, <<"content">> => <<"hi">>},
    ?assertEqual(#{type => text, content => <<"hi">>},
                 myagent_protocol:normalize_event(Event)).

normalize_result_test() ->
    Event = #{<<"type">> => <<"done">>},
    ?assertMatch(#{type := result}, myagent_protocol:normalize_event(Event)).

encode_query_test() ->
    Encoded = myagent_protocol:encode_query(<<"s1">>, <<"hello">>, #{}),
    ?assertEqual(<<"query">>, maps:get(<<"type">>, Encoded)).
```

#### Contract Tests: Adapter Conformance

Verify your adapter module exports the expected functions:

```erlang
-module(myagent_adapter_contract_tests).
-include_lib("eunit/include/eunit.hrl").

exports_start_session_test() ->
    ?assert(erlang:function_exported(myagent_client, start_session, 1)).

exports_query_test() ->
    ?assert(erlang:function_exported(myagent_client, query, 2)),
    ?assert(erlang:function_exported(myagent_client, query, 3)).

exports_session_info_test() ->
    ?assert(erlang:function_exported(myagent_client, session_info, 1)).

%% ... test all required adapter exports
```

#### Property-Based Tests

Use PropEr for frame extraction (roundtrip properties):

```erlang
-module(prop_myagent_frame).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Any JSON object, when encoded into a frame and then extracted,
%% should yield the original map.
prop_roundtrip() ->
    ?FORALL(Map, json_object(),
        begin
            Frame = myagent_frame:encode_message(Map),
            FrameBin = iolist_to_binary(Frame),
            {ok, Decoded, <<>>} = myagent_frame:extract_message(FrameBin),
            maps:size(Decoded) =:= maps:size(Map)
        end).

json_object() ->
    ?LET(Pairs, list({binary(), oneof([binary(), integer(), boolean()])}),
        maps:from_list(Pairs)).
```

#### Running Tests

```shell
# Compile and run all unit tests
rebar3 eunit

# Run only your backend's tests
rebar3 eunit --module=myagent_frame_tests
rebar3 eunit --module=myagent_protocol_tests
rebar3 eunit --module=myagent_session_tests

# Run dialyzer
rebar3 dialyzer

# Run Elixir wrapper tests (if you add Elixir wrappers)
cd beam_agent_ex && mix deps.get && mix test
```


---

## Part 3: Advanced Topics

### The Session Engine State Machine

The `beam_agent_session_engine` gen_statem manages the session lifecycle
as a five-state machine:

```
                              +-------+
                    start --> |connect| --timeout--> [error]
                              |  -ing |
                              +---+---+
                                  |
                         handle_connecting returns
                         {next_state, initializing, ...}
                                  |
                                  v
                              +-------+
                              |initia-| --timeout--> [error]
                              |lizing |
                              +---+---+
                                  |
                         handle_initializing returns
                         {next_state, ready, ...}
                                  |
                                  v
                              +-------+
                              | ready | <-----------+
                              +---+---+              |
                                  |              query complete
                         send_query received    (is_query_complete
                                  |             returns true)
                                  v              |
                              +-------+          |
                              |active | ---------+
                              | query |
                              +---+---+
                                  |
                           {exit,N} / disconnect
                                  |
                                  v
                              +-------+
                              | error | --60s--> {stop, ...}
                              +-------+
```

**State transitions the engine manages:**

| From | To | Trigger |
|------|----|---------|
| `connecting` | `initializing` | `handle_connecting` returns `{next_state, initializing, ...}` |
| `connecting` | `ready` | `handle_connecting` returns `{next_state, ready, ...}` |
| `connecting` | `error` | Timeout or `handle_connecting` returns `{error_state, ...}` |
| `initializing` | `ready` | `handle_initializing` returns `{next_state, ready, ...}` |
| `initializing` | `error` | Timeout or `handle_initializing` returns `{error_state, ...}` |
| `ready` | `active_query` | `send_query` call received and `encode_query` succeeds |
| `active_query` | `ready` | `is_query_complete` returns `true` for a message |
| `active_query` | `ready` | `interrupt` or `cancel` |
| `active_query` | `error` | Transport exit or disconnect |
| Any | `error` | Buffer overflow (>10MB default) |
| `error` | STOP | 60-second auto-stop timer |

**Timeouts:**
- `connecting` state: 15 seconds (configurable via `connect_timeout` in opts)
- `initializing` state: 15 seconds (configurable via `init_timeout` in opts)
- `error` state: 60 seconds auto-stop

**The state_enter callback:** The engine uses `callback_mode() -> [state_functions, state_enter]`,
which means every state transition triggers an `enter` event. The engine
calls `on_state_enter/3` (if implemented) on every transition, then fires
telemetry. This is where you send init handshake messages.


### Handler State Management Patterns

#### The Record Pattern

All existing handlers use an Erlang record for handler state:

```erlang
-record(hstate, {
    %% Transport ref (stored via transport_started/2)
    port_ref              :: port() | undefined,

    %% Pending JSON-RPC responses
    pending = #{}         :: #{binary() => {gen_statem:from() | internal, reference() | undefined}},

    %% Monotonic request ID counter
    next_id = 1           :: pos_integer(),

    %% Session identity
    session_id            :: binary() | undefined,

    %% Configuration
    opts                  :: map(),
    model                 :: binary() | undefined,

    %% SDK registries
    sdk_mcp_registry      :: beam_agent_tool_registry:mcp_registry() | undefined,
    sdk_hook_registry     :: beam_agent_hooks_core:hook_registry() | undefined,

    %% Permission & input handlers
    permission_handler    :: fun() | undefined,
    user_input_handler    :: fun() | undefined,

    %% Init-phase buffer
    init_buffer = <<>>    :: binary()
}).
```

**Key patterns to follow:**

1. **Pending request tracking.** If your protocol is request/response
   (JSON-RPC), maintain a map from request IDs to callers. When a response
   arrives in `handle_data/2`, look up the caller and reply.

2. **Init-phase buffer.** During `connecting` and `initializing`, the engine
   does not manage the buffer. If your protocol sends data during init
   (before `ready`), you must buffer it yourself in handler state.

3. **SDK registries.** Build MCP and hook registries in `init_handler` from
   the opts map. These enable the universal MCP and hooks framework.


### Error Recovery and Reconnection

The current engine design does not support automatic reconnection. When a
transport exits or disconnects, the engine transitions to `error` state
and auto-stops after 60 seconds.

**Patterns for resilience:**

1. **Supervision.** Use the adapter's `child_spec/1` function with a
   supervisor. The supervisor restarts the session on crash.

2. **Session resume.** If the backend supports session resumption, the
   adapter's `resume_session/1` function creates a new session with the
   old session ID. The Copilot handler demonstrates this with
   `session.resume` vs `session.create` in `init_request/1`.

3. **Pending caller cleanup.** In `terminate_handler/2`, reply to all
   pending callers with `{error, session_terminated}`. This prevents
   callers from hanging indefinitely.


### Performance Considerations

#### Buffer Management

The engine enforces a maximum buffer size (default 10MB, configurable via
`buffer_max` in opts). If accumulated data exceeds this limit, the engine
transitions to `error` state.

**Your handler should:**
- Return accurate leftover buffers from `handle_data/2`. Returning too
  much data wastes memory; returning too little loses data.
- Be efficient in frame extraction. The engine calls `handle_data/2`
  on every data chunk, so O(n^2) scanning of the buffer per call becomes
  expensive with large responses.

#### Message Queuing

The engine uses an Erlang `queue` for message buffering. Messages are
enqueued when no consumer is waiting and dequeued on `receive_message`.
This is efficient for the typical pattern of alternating send/receive
calls.

**Avoid returning excessively large message lists** from `handle_data/2`.
The engine iterates through the list to check `is_query_complete` for each
message during `active_query`. If your backend sends thousands of tiny
deltas, consider batching them in your handler.

#### Zero-Copy Transport

The `beam_agent_transport_port` with `mode => raw` delivers data as
binaries directly from the port driver. These are refc binaries (not
copied on the heap). Keep this in mind when storing binary references in
handler state -- they hold a reference to the underlying binary, preventing
garbage collection of the full port buffer.


### Thick Framework, Thin Adapters

BeamAgent follows a "thick framework, thin adapter" architecture. The
session engine handles:

- State machine lifecycle with timeouts
- Consumer/queue management (blocking receive)
- Buffer management and overflow detection
- Telemetry (state transitions, query spans)
- Transport lifecycle (start, close, classify)
- Query ref validation and cancel support
- Error state with auto-stop

Your handler only needs to implement:

- Protocol encoding/decoding (wire format specifics)
- Init handshake logic
- Query encoding
- Terminal message detection
- Backend-specific features (if any)

This means most of your handler's logic is in three callbacks:
`init_handler/1`, `handle_data/2`, and `encode_query/3`. The optional
callbacks add features incrementally.


### The Event Streaming Architecture

BeamAgent provides a universal event streaming system via `beam_agent_events`.
Events are published when messages are tracked in the session store.

**How to integrate:**

1. In your `handle_data/2`, after normalizing messages, track them:

```erlang
track_message(Msg, HState) ->
    SessionId = session_store_id(HState),
    beam_agent_session_store_core:register_session(
        SessionId, #{adapter => myagent}),
    beam_agent_session_store_core:record_message(SessionId, Msg).
```

2. The event streaming system (subscribe and receive via the events module)
   works automatically once messages
   are recorded in the session store.

3. Your adapter module exposes the standard event functions by delegating
   to `beam_agent_events`:

```erlang
event_subscribe(Session) ->
    beam_agent_events:subscribe(get_session_id(Session)).

receive_event(_Session, Ref, Timeout) ->
    beam_agent_events:receive_event(Ref, Timeout).

event_unsubscribe(Session, Ref) ->
    beam_agent_events:unsubscribe(get_session_id(Session), Ref).
```


### MCP Integration

BeamAgent's MCP (Model Context Protocol) integration allows SDK consumers
to register custom tools that the backend can invoke during a query.

**How it works:**

1. The consumer passes `sdk_mcp_servers` in session opts.
2. In `init_handler/1`, build the MCP registry:

```erlang
McpRegistry = beam_agent_tool_registry:build_registry(
    maps:get(sdk_mcp_servers, Opts, undefined)).
```

3. When the backend sends a tool call request, look up and invoke the
   tool in your `handle_data/2` or server request handler:

```erlang
handle_server_request(ReqId, <<"tool.call">>, Params,
                      #hstate{sdk_mcp_registry = Registry}) ->
    ToolName = maps:get(<<"toolName">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Result = beam_agent_tool_registry:call_tool_by_name(
                 ToolName, Arguments, Registry),
    %% Encode and send response...
```

4. Optionally inject SDK tool definitions into the CLI's available tools
   via CLI arguments or init parameters (as Copilot does with
   `maybe_inject_sdk_tools/2`).


---

## Part 4: Reference

### Complete Callback Reference

#### Required Callbacks

| Callback | Signature | When Called | Expected Return |
|----------|-----------|------------|-----------------|
| `backend_name/0` | `() -> atom()` | Init, telemetry, session info | Backend identifier atom |
| `init_handler/1` | `(Opts) -> init_result()` | Engine `init/1`, once | `{ok, #{transport_spec, initial_state, handler_state}}` or `{stop, Reason}` |
| `handle_data/2` | `(Buffer, HState) -> data_result()` | On transport data in `ready`/`active_query` | `{ok, Messages, LeftoverBuf, Actions, NewHState}` |
| `encode_query/3` | `(Prompt, Params, HState) -> ...` | On `send_query` in `ready` | `{ok, EncodedData, NewHState}` or `{error, Reason}` |
| `build_session_info/1` | `(HState) -> map()` | On `session_info/1`, any state | Map with at least `adapter => myagent` |
| `terminate_handler/2` | `(Reason, HState) -> ok` | Engine `terminate/3` | `ok` |

#### Optional Callbacks

| Callback | Signature | When Called | Expected Return |
|----------|-----------|------------|-----------------|
| `transport_started/2` | `(TRef, HState) -> HState` | After transport start | Updated handler state |
| `handle_connecting/2` | `(Event, HState) -> phase_result()` | Transport events in `connecting` | State transition or keep_state |
| `handle_initializing/2` | `(Event, HState) -> phase_result()` | Transport events in `initializing` | State transition or keep_state |
| `on_state_enter/3` | `(New, Old, HState) -> {ok, Actions, HState}` | Every state transition | Actions to execute on enter |
| `encode_interrupt/1` | `(HState) -> {ok, Actions, HState} \| not_supported` | On `interrupt/1` in `active_query` | Interrupt actions or not_supported |
| `is_query_complete/2` | `(Msg, HState) -> boolean()` | Per message in `active_query` | `true` if message is terminal |
| `handle_control/4` | `(Method, Params, From, HState) -> control_result()` | On `send_control/3` | Reply, noreply, or error |
| `handle_set_model/2` | `(Model, HState) -> ...` | On `set_model/2` | `{ok, Result, Actions, HState}` or `{error, Reason}` |
| `handle_set_permission_mode/2` | `(Mode, HState) -> ...` | On `set_permission_mode/2` | `{ok, Result, Actions, HState}` or `{error, Reason}` |
| `handle_custom_call/3` | `(Request, From, HState) -> control_result()` | On unrecognized gen_statem calls | Reply, noreply, or error |
| `handle_info/3` | `(Msg, StateName, HState) -> info_result()` | On unclassified messages | Messages, state transition, or ignore |


### Capability Matrix Explained

The capability system has three dimensions:

**`support_level`** indicates whether the capability is available:

| Level | Meaning |
|-------|---------|
| `full` | Complete support, all sub-features work |
| `partial` | Some sub-features work |
| `baseline` | Minimal viable support |
| `missing` | Not supported |

**`implementation`** indicates how the capability is provided:

| Implementation | Meaning |
|----------------|---------|
| `direct_backend` | Implemented via the backend's native protocol |
| `universal` | Implemented via BeamAgent's universal core modules |
| `direct_backend_and_universal` | Both paths available |

**`fidelity`** indicates how closely the implementation matches the
backend's native behavior:

| Fidelity | Meaning |
|----------|---------|
| `exact` | Bit-for-bit equivalent to native |
| `validated_equivalent` | Functionally equivalent but uses a different implementation |

**The 22 capabilities:**

| # | Capability | Description |
|---|-----------|-------------|
| 1 | `session_lifecycle` | Start, stop, health check |
| 2 | `session_info` | Query session metadata |
| 3 | `runtime_model_switch` | Change model during session |
| 4 | `interrupt` | Abort active query |
| 5 | `permission_mode` | Change permission mode at runtime |
| 6 | `session_history` | View past session messages |
| 7 | `session_mutation` | Fork, revert, share, summarize sessions |
| 8 | `thread_management` | Thread lifecycle and history |
| 9 | `metadata_accessors` | List tools, skills, agents, etc. |
| 10 | `in_process_mcp` | In-process MCP servers and tools |
| 11 | `mcp_management` | MCP server status, reconnect, toggle |
| 12 | `hooks` | SDK lifecycle hooks |
| 13 | `checkpointing` | File checkpointing and rewind |
| 14 | `thinking_budget` | Thinking token budget control |
| 15 | `task_stop` | Stop task by ID |
| 16 | `command_execution` | Run shell commands |
| 17 | `approval_callbacks` | Permission request handling |
| 18 | `user_input_callbacks` | User input request handling |
| 19 | `realtime_review` | Realtime collaboration and review |
| 20 | `config_management` | Config read/write |
| 21 | `provider_management` | Provider selection and auth |
| 22 | `event_streaming` | Subscribe to backend events |


### Backend Readiness Checklist

Use this checklist to verify your backend is complete before merging.

#### Handler Implementation

- [ ] `backend_name/0` returns a unique atom
- [ ] `init_handler/1` returns valid transport spec, initial state, and handler state
- [ ] `handle_data/2` extracts frames, decodes protocol, returns normalized messages
- [ ] `encode_query/3` encodes prompts into the backend's wire format
- [ ] `build_session_info/1` returns a map with `adapter => myagent`
- [ ] `terminate_handler/2` replies to all pending callers and cleans up resources
- [ ] `handle_connecting/2` transitions through the connecting phase (if applicable)
- [ ] `handle_initializing/2` completes the init handshake (if applicable)
- [ ] `on_state_enter/3` sends init messages on state transitions (if applicable)
- [ ] `is_query_complete/2` correctly identifies terminal messages
- [ ] `encode_interrupt/1` sends an interrupt signal (if the backend supports it)

#### Session and Adapter Modules

- [ ] `myagent_session.erl` implements `beam_agent_behaviour` and delegates to the engine
- [ ] `myagent_client.erl` exposes `start_session/1`, `query/2`, `query/3`, `session_info/1`
- [ ] `myagent_client.erl` delegates universal capabilities to core modules

#### Protocol Modules

- [ ] `myagent_frame.erl` handles frame extraction with proper leftover buffer handling
- [ ] `myagent_protocol.erl` normalizes all backend event types to `beam_agent_core:message()` format
- [ ] `myagent_protocol.erl` encodes all outgoing request types

#### Registration

- [ ] `beam_agent_backend`: backend type, adapter module type, `available_backends/0`, `normalize/1`, `adapter_module/1`
- [ ] `beam_agent_capabilities`: all 22 capabilities have entries for your backend
- [ ] `beam_agent_backend:is_terminal/2` handles your backend's terminal message patterns

#### Testing

- [ ] Frame extraction unit tests (empty buffer, single message, partial, multiple, edge cases)
- [ ] Protocol normalization unit tests (all event types)
- [ ] Protocol encoding unit tests (all request types)
- [ ] Adapter contract tests (all required exports present)
- [ ] Property-based tests for frame roundtrip
- [ ] Session lifecycle tests (if integration testing is feasible)

#### Verification

- [ ] `rebar3 compile` -- zero errors
- [ ] `rebar3 eunit` -- all tests pass
- [ ] `rebar3 dialyzer` -- no new warnings from your modules
- [ ] `cd beam_agent_ex && mix test` -- Elixir wrapper tests pass (if applicable)

#### Documentation

- [ ] Module-level `-moduledoc` on all new modules
- [ ] Function-level `-doc` on all public exports
- [ ] Type specs (`-spec`) on all exported functions


---

## Appendix: File Reference

| File | Purpose |
|------|---------|
| `src/core/beam_agent_session_handler.erl` | Handler behaviour definition |
| `src/core/beam_agent_session_engine.erl` | gen_statem engine (do not modify) |
| `src/core/beam_agent_behaviour.erl` | Top-level behaviour contract |
| `src/core/beam_agent_backend.erl` | Backend registry |
| `src/public/beam_agent_capabilities.erl` | Capability registry |
| `src/public/beam_agent.erl` | Public API with native_or routing |
| `src/transports/beam_agent_transport.erl` | Transport behaviour |
| `src/transports/beam_agent_transport_port.erl` | Stdio port transport |
| `src/transports/beam_agent_transport_http.erl` | HTTP transport |
| `src/transports/beam_agent_transport_ws.erl` | WebSocket transport |
| `src/backends/opencode/opencode_sse.erl` | SSE parsing helpers |
| `src/core/beam_agent_jsonl.erl` | JSONL framing helpers |
| `src/core/beam_agent_jsonrpc.erl` | JSON-RPC framing helpers |
| `src/backends/copilot/copilot_session_handler.erl` | Reference handler implementation |
| `src/backends/copilot/copilot_session.erl` | Reference session wrapper |
| `src/backends/copilot/copilot_client.erl` | Reference adapter module |
| `src/backends/copilot/copilot_protocol.erl` | Reference protocol module |
| `src/backends/copilot/copilot_frame.erl` | Reference frame extraction |
| `test/backends/copilot/` | Reference test suite |
