-module(beam_agent_mcp_client_dispatch).
-moduledoc """
MCP client-side method dispatch, lifecycle state machine, and handler behaviour.

This module manages the client side of an MCP session. It generates outgoing
requests (with tracked IDs), routes incoming responses back to their originators,
handles server-initiated requests (sampling, elicitation, roots), and processes
server notifications.

Like `beam_agent_mcp_dispatch` (server-side), this is a pure-function dispatch
layer — **not** a process. The caller (typically a session handler) owns the
state and passes it through on each call.

## Lifecycle

The MCP client session progresses through three states:

  1. `uninitialized` — only `send_initialize/1` is valid
  2. `initializing`  — waiting for the server's initialize response
  3. `ready`         — all methods available

The `handle_message/2` function manages transitions, and `send_*` functions
enforce lifecycle gating.

## Handler Behaviour

Server-initiated requests (sampling, elicitation, roots) delegate to a
**handler** callback module implementing the `beam_agent_mcp_client_dispatch`
behaviour. If no handler is configured, those requests are rejected with
appropriate error responses.

## Timeout Tracking

Pending requests are tracked with deadlines. The caller should periodically
invoke `check_timeouts/2` (e.g., from a timer message in a GenServer or
GenStatem) to detect and clean up stale requests.

## Usage

```erlang
%% Create client dispatch state
State = beam_agent_mcp_client_dispatch:new(ClientInfo, ClientCaps, #{
    handler => my_mcp_client_handler,
    handler_state => HandlerState,
    default_timeout => 30000
}),

%% Send initialize to begin the handshake
{InitMsg, State1} = beam_agent_mcp_client_dispatch:send_initialize(State),
send_to_server(InitMsg),

%% On each incoming message from server:
case beam_agent_mcp_client_dispatch:handle_message(Msg, State1) of
    {response, _Id, Result, State2} -> process_result(Result);
    {server_request, RespMsg, State2} -> send_to_server(RespMsg);
    {notification, Method, Params, State2} -> handle_notif(Method, Params);
    {noreply, State2} -> ok
end,

%% Periodically check for timed-out requests:
{TimedOut, State3} = beam_agent_mcp_client_dispatch:check_timeouts(
    erlang:monotonic_time(millisecond), State2)
```
""".

-export([
    %% State management
    new/3,
    lifecycle_state/1,
    server_capabilities/1,
    session_capabilities/1,

    %% Outgoing requests (client → server)
    send_initialize/1,
    send_initialized/1,
    send_ping/1,
    send_tools_list/1,
    send_tools_list/2,
    send_tools_call/3,
    send_resources_list/1,
    send_resources_list/2,
    send_resources_read/2,
    send_resources_templates_list/1,
    send_resources_templates_list/2,
    send_resources_subscribe/2,
    send_resources_unsubscribe/2,
    send_prompts_list/1,
    send_prompts_list/2,
    send_prompts_get/2,
    send_prompts_get/3,
    send_completion_complete/3,
    send_completion_complete/4,
    send_logging_set_level/2,
    send_request/3,

    %% Outgoing notifications (client → server)
    send_cancelled/2,
    send_cancelled/3,
    send_progress/3,
    send_progress/4,
    send_progress/5,
    send_roots_list_changed/1,

    %% Incoming message handling (server → client)
    handle_message/2,

    %% Timeout management
    check_timeouts/2,
    pending_count/1
]).

-export_type([
    client_state/0,
    client_result/0,
    timed_out_request/0
]).

%%--------------------------------------------------------------------
%% Handler Behaviour
%%--------------------------------------------------------------------

-doc """
Callback behaviour for MCP client-side handlers.

Implement this behaviour to handle server-initiated requests: sampling,
elicitation, and roots listing. All callbacks are optional — only implement
those for capabilities your client advertises.

Callbacks receive the handler state and return a result tuple. The dispatch
layer handles encoding the response into the correct JSON-RPC format.
""".

-callback handle_sampling_create_message(
    Params :: map(),
    HandlerState :: term()) ->
    {ok, beam_agent_mcp_protocol:create_message_result(), term()}
  | {error, integer(), binary()}.

-callback handle_elicitation_create(
    Params :: map(),
    HandlerState :: term()) ->
    {ok, beam_agent_mcp_protocol:elicitation_result(), term()}
  | {error, integer(), binary()}.

-callback handle_roots_list(HandlerState :: term()) ->
    {ok, [beam_agent_mcp_protocol:root()], term()}
  | {error, integer(), binary()}.

-optional_callbacks([
    handle_sampling_create_message/2,
    handle_elicitation_create/2,
    handle_roots_list/1
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type lifecycle() :: uninitialized | initializing | ready.

-type pending_request() :: #{
    method := binary(),
    deadline := integer(),
    sent_at := integer()
}.

-type client_state() :: #{
    lifecycle := lifecycle(),
    client_info := beam_agent_mcp_protocol:implementation_info(),
    client_capabilities := beam_agent_mcp_protocol:client_capabilities(),
    server_capabilities => beam_agent_mcp_protocol:server_capabilities(),
    session_capabilities => beam_agent_mcp_protocol:session_capabilities(),
    next_id := pos_integer(),
    pending := #{beam_agent_mcp_protocol:request_id() => pending_request()},
    default_timeout := pos_integer(),
    handler => module(),
    handler_state => term()
}.

-type client_result() ::
    {response, beam_agent_mcp_protocol:request_id(), term(), client_state()}
  | {error_response, beam_agent_mcp_protocol:request_id(), integer(),
     binary(), client_state()}
  | {server_request, map(), client_state()}
  | {notification, binary(), map(), client_state()}
  | {noreply, client_state()}.

-type timed_out_request() :: #{
    id := beam_agent_mcp_protocol:request_id(),
    method := binary(),
    sent_at := integer()
}.

%% Default request timeout: 30 seconds.
-define(DEFAULT_TIMEOUT, 30000).

%%====================================================================
%% State Management
%%====================================================================

-doc """
Create a new client dispatch state.

`ClientInfo` is this client's implementation info (name + version).
`ClientCaps` declares which capabilities this client supports
(e.g., `#{roots => #{listChanged => true}, sampling => #{}}`).

Options:
  - `handler` — callback module implementing `beam_agent_mcp_client_dispatch`
  - `handler_state` — opaque state passed to handler callbacks
  - `default_timeout` — default timeout in ms for pending requests (default: 30000)
""".
-spec new(beam_agent_mcp_protocol:implementation_info(),
          beam_agent_mcp_protocol:client_capabilities(),
          map()) -> client_state().
new(ClientInfo, ClientCaps0, Opts)
  when is_map(ClientInfo), is_map(ClientCaps0), is_map(Opts) ->
    ClientCaps = normalize_client_caps(ClientCaps0),
    Base = #{
        lifecycle => uninitialized,
        client_info => ClientInfo,
        client_capabilities => ClientCaps,
        next_id => 1,
        pending => #{},
        default_timeout => maps:get(default_timeout, Opts, ?DEFAULT_TIMEOUT)
    },
    OptKeys = [handler, handler_state],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Opts) of
            {ok, Val} -> Acc#{Key => Val};
            error -> Acc
        end
    end, Base, OptKeys).

-doc "Return the current lifecycle state.".
-spec lifecycle_state(client_state()) -> lifecycle().
lifecycle_state(#{lifecycle := State}) -> State.

-doc """
Return the server's advertised capabilities.

Only available after the initialize handshake completes.
Returns `undefined` if not yet received.
""".
-spec server_capabilities(client_state()) ->
    beam_agent_mcp_protocol:server_capabilities() | undefined.
server_capabilities(State) ->
    maps:get(server_capabilities, State, undefined).

-doc """
Return the negotiated session capabilities.

Only available after the initialize handshake completes.
Returns `undefined` if not yet negotiated.
""".
-spec session_capabilities(client_state()) ->
    beam_agent_mcp_protocol:session_capabilities() | undefined.
session_capabilities(State) ->
    maps:get(session_capabilities, State, undefined).

%%====================================================================
%% Outgoing Requests — Lifecycle
%%====================================================================

-doc """
Generate an `initialize` request.

Only valid in the `uninitialized` state. Transitions lifecycle to
`initializing`. The caller must send the returned message to the server.
""".
-spec send_initialize(client_state()) -> {map(), client_state()}.
send_initialize(#{lifecycle := uninitialized,
                   client_info := ClientInfo,
                   client_capabilities := ClientCaps} = State) ->
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:initialize_request(Id, ClientInfo, ClientCaps),
    State2 = track_request_now(Id, <<"initialize">>, State1),
    {Msg, State2#{lifecycle => initializing}};
send_initialize(#{lifecycle := Lifecycle}) ->
    error({invalid_lifecycle, Lifecycle, initialize}).

-doc "Generate the `notifications/initialized` notification to complete the MCP handshake.".
-spec send_initialized(client_state()) -> {map(), client_state()}.
send_initialized(#{lifecycle := ready} = State) ->
    {beam_agent_mcp_protocol:initialized_notification(), State}.

-doc """
Generate a `ping` request.

Valid in any lifecycle state. The server should respond with an empty result.
""".
-spec send_ping(client_state()) -> {map(), client_state()}.
send_ping(State) ->
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:ping_request(Id),
    State2 = track_request_now(Id, <<"ping">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Tools
%%====================================================================

-doc "Generate a `tools/list` request. Requires `ready` state.".
-spec send_tools_list(client_state()) -> {map(), client_state()}.
send_tools_list(State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:tools_list_request(Id),
    State2 = track_request_now(Id, <<"tools/list">>, State1),
    {Msg, State2}.

-doc "Generate a `tools/list` request with cursor for pagination.".
-spec send_tools_list(beam_agent_mcp_protocol:cursor(),
                      client_state()) -> {map(), client_state()}.
send_tools_list(Cursor, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:tools_list_request(Id, Cursor),
    State2 = track_request_now(Id, <<"tools/list">>, State1),
    {Msg, State2}.

-doc "Generate a `tools/call` request.".
-spec send_tools_call(binary(), map(), client_state()) ->
    {map(), client_state()}.
send_tools_call(ToolName, Arguments, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:tools_call_request(Id, ToolName, Arguments),
    State2 = track_request_now(Id, <<"tools/call">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Resources
%%====================================================================

-doc "Generate a `resources/list` request. Requires `ready` state.".
-spec send_resources_list(client_state()) -> {map(), client_state()}.
send_resources_list(State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_list_request(Id),
    State2 = track_request_now(Id, <<"resources/list">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/list` request with cursor.".
-spec send_resources_list(beam_agent_mcp_protocol:cursor(),
                          client_state()) -> {map(), client_state()}.
send_resources_list(Cursor, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_list_request(Id, Cursor),
    State2 = track_request_now(Id, <<"resources/list">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/read` request.".
-spec send_resources_read(binary(), client_state()) ->
    {map(), client_state()}.
send_resources_read(Uri, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_read_request(Id, Uri),
    State2 = track_request_now(Id, <<"resources/read">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/templates/list` request.".
-spec send_resources_templates_list(client_state()) ->
    {map(), client_state()}.
send_resources_templates_list(State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_templates_list_request(Id),
    State2 = track_request_now(Id, <<"resources/templates/list">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/templates/list` request with cursor.".
-spec send_resources_templates_list(beam_agent_mcp_protocol:cursor(),
                                    client_state()) ->
    {map(), client_state()}.
send_resources_templates_list(Cursor, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_templates_list_request(Id, Cursor),
    State2 = track_request_now(Id, <<"resources/templates/list">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/subscribe` request.".
-spec send_resources_subscribe(binary(), client_state()) ->
    {map(), client_state()}.
send_resources_subscribe(Uri, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_subscribe_request(Id, Uri),
    State2 = track_request_now(Id, <<"resources/subscribe">>, State1),
    {Msg, State2}.

-doc "Generate a `resources/unsubscribe` request.".
-spec send_resources_unsubscribe(binary(), client_state()) ->
    {map(), client_state()}.
send_resources_unsubscribe(Uri, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:resources_unsubscribe_request(Id, Uri),
    State2 = track_request_now(Id, <<"resources/unsubscribe">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Prompts
%%====================================================================

-doc "Generate a `prompts/list` request. Requires `ready` state.".
-spec send_prompts_list(client_state()) -> {map(), client_state()}.
send_prompts_list(State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:prompts_list_request(Id),
    State2 = track_request_now(Id, <<"prompts/list">>, State1),
    {Msg, State2}.

-doc "Generate a `prompts/list` request with cursor.".
-spec send_prompts_list(beam_agent_mcp_protocol:cursor(),
                        client_state()) -> {map(), client_state()}.
send_prompts_list(Cursor, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:prompts_list_request(Id, Cursor),
    State2 = track_request_now(Id, <<"prompts/list">>, State1),
    {Msg, State2}.

-doc "Generate a `prompts/get` request.".
-spec send_prompts_get(binary(), client_state()) ->
    {map(), client_state()}.
send_prompts_get(Name, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:prompts_get_request(Id, Name),
    State2 = track_request_now(Id, <<"prompts/get">>, State1),
    {Msg, State2}.

-doc "Generate a `prompts/get` request with arguments.".
-spec send_prompts_get(binary(), map(), client_state()) ->
    {map(), client_state()}.
send_prompts_get(Name, Arguments, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:prompts_get_request(Id, Name, Arguments),
    State2 = track_request_now(Id, <<"prompts/get">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Completions
%%====================================================================

-doc "Generate a `completion/complete` request.".
-spec send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                               map(), client_state()) ->
    {map(), client_state()}.
send_completion_complete(Ref, Argument, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:completion_complete_request(
              Id, Ref, Argument),
    State2 = track_request_now(Id, <<"completion/complete">>, State1),
    {Msg, State2}.

-doc "Generate a `completion/complete` request with context.".
-spec send_completion_complete(beam_agent_mcp_protocol:completion_ref(),
                               map(), map(), client_state()) ->
    {map(), client_state()}.
send_completion_complete(Ref, Argument, Context, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:completion_complete_request(
              Id, Ref, Argument, Context),
    State2 = track_request_now(Id, <<"completion/complete">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Logging
%%====================================================================

-doc "Generate a `logging/setLevel` request.".
-spec send_logging_set_level(beam_agent_mcp_protocol:log_level(),
                             client_state()) -> {map(), client_state()}.
send_logging_set_level(Level, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:logging_set_level_request(Id, Level),
    State2 = track_request_now(Id, <<"logging/setLevel">>, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Requests — Generic
%%====================================================================

-doc """
Generate a generic request for methods not covered by specific `send_*`
functions. Requires `ready` state. The caller provides the full params map.
""".
-spec send_request(binary(), map(), client_state()) ->
    {map(), client_state()}.
send_request(Method, Params, State) ->
    require_ready(State),
    {Id, State1} = next_request_id(State),
    Msg = beam_agent_mcp_protocol:request(Id, Method, Params),
    State2 = track_request_now(Id, Method, State1),
    {Msg, State2}.

%%====================================================================
%% Outgoing Notifications (client → server)
%%====================================================================

-doc "Generate a `notifications/cancelled` notification for a pending request.".
-spec send_cancelled(beam_agent_mcp_protocol:request_id(),
                     client_state()) -> {map(), client_state()}.
send_cancelled(RequestId, State) ->
    Msg = beam_agent_mcp_protocol:cancelled_notification(RequestId),
    %% Remove from pending — we're giving up on this request
    State1 = untrack_request(RequestId, State),
    {Msg, State1}.

-doc "Generate a `notifications/cancelled` notification with a reason.".
-spec send_cancelled(beam_agent_mcp_protocol:request_id(), binary(),
                     client_state()) -> {map(), client_state()}.
send_cancelled(RequestId, Reason, State) ->
    Msg = beam_agent_mcp_protocol:cancelled_notification(RequestId, Reason),
    State1 = untrack_request(RequestId, State),
    {Msg, State1}.

-doc "Generate a `notifications/progress` notification.".
-spec send_progress(beam_agent_mcp_protocol:progress_token(), number(),
                    client_state()) -> {map(), client_state()}.
send_progress(Token, Progress, State) ->
    {beam_agent_mcp_protocol:progress_notification(Token, Progress), State}.

-doc "Generate a `notifications/progress` notification with total.".
-spec send_progress(beam_agent_mcp_protocol:progress_token(), number(),
                    number(), client_state()) -> {map(), client_state()}.
send_progress(Token, Progress, Total, State) ->
    {beam_agent_mcp_protocol:progress_notification(Token, Progress, Total),
     State}.

-doc "Generate a `notifications/progress` notification with total and message.".
-spec send_progress(beam_agent_mcp_protocol:progress_token(), number(),
                    number(), binary(), client_state()) ->
    {map(), client_state()}.
send_progress(Token, Progress, Total, Message, State) ->
    {beam_agent_mcp_protocol:progress_notification(
         Token, Progress, Total, Message),
     State}.

-doc "Generate a `notifications/roots/list_changed` notification.".
-spec send_roots_list_changed(client_state()) -> {map(), client_state()}.
send_roots_list_changed(State) ->
    require_ready(State),
    {beam_agent_mcp_protocol:roots_list_changed_notification(), State}.

%%====================================================================
%% Incoming Message Dispatch
%%====================================================================

-doc """
Handle an incoming message from the MCP server.

Validates the message, matches responses to pending requests, routes
server-initiated requests to the handler, and processes notifications.

Return values:
  - `{response, Id, Result, NewState}` — matched response to a pending request
  - `{error_response, Id, Code, Msg, NewState}` — error response from server
  - `{server_request, ResponseMsg, NewState}` — server request handled, send
    the response back
  - `{notification, Method, Params, NewState}` — server notification
  - `{noreply, NewState}` — no action needed
""".
-spec handle_message(map(), client_state()) -> client_result().
handle_message(RawMsg, State) ->
    case beam_agent_mcp_protocol:validate_message(RawMsg) of
        {request, Id, Method, Params} ->
            dispatch_server_request(Id, Method, Params, State);
        {notification, Method, Params} ->
            dispatch_notification(Method, Params, State);
        {response, Id, Result} ->
            handle_response(Id, Result, State);
        {error_response, Id, Code, Msg, _Data} ->
            handle_error_response(Id, Code, Msg, State);
        {invalid, _Reason} ->
            %% Invalid messages from server — ignore, nothing to respond to
            {noreply, State}
    end.

%%====================================================================
%% Timeout Management
%%====================================================================

-doc """
Check for timed-out pending requests.

`Now` should be `erlang:monotonic_time(millisecond)`. Returns a list
of timed-out request info and the updated state with those requests
removed from pending.

The caller should invoke this periodically (e.g., from a timer message).
""".
-spec check_timeouts(integer(), client_state()) ->
    {[timed_out_request()], client_state()}.
check_timeouts(Now, #{pending := Pending} = State) ->
    {TimedOut, Remaining} = maps:fold(
        fun(Id, #{deadline := Deadline, method := Method,
                  sent_at := SentAt} = _Req, {TOAcc, RemAcc}) ->
            case Now >= Deadline of
                true ->
                    Info = #{id => Id, method => Method, sent_at => SentAt},
                    {[Info | TOAcc], RemAcc};
                false ->
                    {TOAcc, RemAcc#{Id => _Req}}
            end
        end, {[], #{}}, Pending),
    {TimedOut, State#{pending => Remaining}}.

-doc "Return the number of pending (in-flight) requests.".
-spec pending_count(client_state()) -> non_neg_integer().
pending_count(#{pending := Pending}) ->
    map_size(Pending).

%%--------------------------------------------------------------------
%% Internal: Response Handling
%%--------------------------------------------------------------------

-spec handle_response(beam_agent_mcp_protocol:request_id(), term(),
                      client_state()) -> client_result().
handle_response(Id, Result, #{pending := Pending} = State) ->
    case maps:take(Id, Pending) of
        {#{method := <<"initialize">>}, Remaining} ->
            handle_initialize_response(Id, Result,
                                       State#{pending => Remaining});
        {_Req, Remaining} ->
            {response, Id, Result, State#{pending => Remaining}};
        error ->
            %% Response for unknown/already-expired request — ignore
            {noreply, State}
    end.

-spec handle_error_response(beam_agent_mcp_protocol:request_id(),
                            integer(), binary(), client_state()) ->
    client_result().
handle_error_response(Id, Code, Msg, #{pending := Pending} = State) ->
    State1 = State#{pending => maps:remove(Id, Pending)},
    {error_response, Id, Code, Msg, State1}.

%%--------------------------------------------------------------------
%% Internal: Initialize Response
%%--------------------------------------------------------------------

-spec handle_initialize_response(beam_agent_mcp_protocol:request_id(),
                                 map(), client_state()) -> client_result().
handle_initialize_response(Id, Result,
                           #{client_capabilities := ClientCaps} = State) ->
    ServerCaps = decode_server_capabilities(
                     maps:get(<<"capabilities">>, Result, #{})),
    SessionCaps = beam_agent_mcp_protocol:negotiate_capabilities(
                      ServerCaps, ClientCaps),
    NewState = State#{
        lifecycle => ready,
        server_capabilities => ServerCaps,
        session_capabilities => SessionCaps
    },
    {response, Id, Result, NewState}.

%%--------------------------------------------------------------------
%% Internal: Server-Initiated Request Dispatch
%%--------------------------------------------------------------------

-spec dispatch_server_request(beam_agent_mcp_protocol:request_id(),
                              binary(), map(), client_state()) ->
    client_result().

%% -- ping: always allowed, any state --
dispatch_server_request(Id, <<"ping">>, _Params, State) ->
    Resp = beam_agent_mcp_protocol:ping_response(Id),
    {server_request, Resp, State};

%% -- sampling/createMessage --
dispatch_server_request(Id, <<"sampling/createMessage">>, Params, State) ->
    dispatch_handler(Id, <<"sampling/createMessage">>, sampling,
                     fun dispatch_sampling/4, Params, State);

%% -- elicitation/create --
dispatch_server_request(Id, <<"elicitation/create">>, Params, State) ->
    dispatch_handler(Id, <<"elicitation/create">>, elicitation,
                     fun dispatch_elicitation/4, Params, State);

%% -- roots/list --
dispatch_server_request(Id, <<"roots/list">>, Params, State) ->
    dispatch_handler(Id, <<"roots/list">>, roots,
                     fun dispatch_roots_list/4, Params, State);

%% -- Unknown server request --
dispatch_server_request(Id, Method, _Params, State) ->
    Resp = beam_agent_mcp_protocol:error_response(
               Id,
               beam_agent_mcp_protocol:error_method_not_found(),
               <<"Unsupported server request: ", Method/binary>>),
    {server_request, Resp, State}.

%%--------------------------------------------------------------------
%% Internal: Handler Dispatch Helper
%%--------------------------------------------------------------------

%% Route a server-initiated request to a handler callback if the
%% capability is advertised and a handler is configured.
-spec dispatch_handler(beam_agent_mcp_protocol:request_id(), binary(),
                       atom(), fun(), map(), client_state()) ->
    client_result().
dispatch_handler(Id, Method, Capability, HandlerFun, Params, State) ->
    ClientCaps = maps:get(client_capabilities, State),
    case maps:is_key(Capability, ClientCaps) of
        false ->
            Resp = beam_agent_mcp_protocol:error_response(
                       Id,
                       beam_agent_mcp_protocol:error_method_not_found(),
                       <<"Capability not advertised: ", Method/binary>>),
            {server_request, Resp, State};
        true ->
            case maps:get(handler, State, undefined) of
                undefined ->
                    Resp = beam_agent_mcp_protocol:error_response(
                               Id,
                               beam_agent_mcp_protocol:error_internal(),
                               <<"No handler configured for: ",
                                 Method/binary>>),
                    {server_request, Resp, State};
                _Handler ->
                    HandlerFun(Id, Params, State, _Handler)
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Handler Implementations
%%--------------------------------------------------------------------

-spec dispatch_sampling(beam_agent_mcp_protocol:request_id(), map(),
                        client_state(), module()) -> client_result().
dispatch_sampling(Id, Params,
                  #{handler_state := HState} = State, Handler) ->
    try Handler:handle_sampling_create_message(Params, HState) of
        {ok, Result, NewHState} ->
            Resp = beam_agent_mcp_protocol:sampling_create_message_response(
                       Id, Result),
            {server_request, Resp, State#{handler_state => NewHState}};
        {error, Code, Msg} ->
            Resp = beam_agent_mcp_protocol:error_response(Id, Code, Msg),
            {server_request, Resp, State}
    catch
        Class:Reason:Stack ->
            SafeStack = [{M, F, if is_list(A) -> length(A); true -> A end, L}
                         || {M, F, A, L} <- Stack],
            logger:error("MCP client handler crash in ~s: ~p:~p~n~p",
                         [<<"handle_sampling_create_message">>, Class, Reason, SafeStack]),
            Resp = beam_agent_mcp_protocol:error_response(
                       Id, beam_agent_mcp_protocol:error_internal(),
                       <<"Handler crashed">>),
            {server_request, Resp, State}
    end.

-spec dispatch_elicitation(beam_agent_mcp_protocol:request_id(), map(),
                           client_state(), module()) -> client_result().
dispatch_elicitation(Id, Params,
                     #{handler_state := HState} = State, Handler) ->
    try Handler:handle_elicitation_create(Params, HState) of
        {ok, Result, NewHState} ->
            Resp = beam_agent_mcp_protocol:elicitation_create_response(
                       Id, Result),
            {server_request, Resp, State#{handler_state => NewHState}};
        {error, Code, Msg} ->
            Resp = beam_agent_mcp_protocol:error_response(Id, Code, Msg),
            {server_request, Resp, State}
    catch
        Class:Reason:Stack ->
            SafeStack = [{M, F, if is_list(A) -> length(A); true -> A end, L}
                         || {M, F, A, L} <- Stack],
            logger:error("MCP client handler crash in ~s: ~p:~p~n~p",
                         [<<"handle_elicitation_create">>, Class, Reason, SafeStack]),
            Resp = beam_agent_mcp_protocol:error_response(
                       Id, beam_agent_mcp_protocol:error_internal(),
                       <<"Handler crashed">>),
            {server_request, Resp, State}
    end.

-spec dispatch_roots_list(beam_agent_mcp_protocol:request_id(), map(),
                          client_state(), module()) -> client_result().
dispatch_roots_list(Id, _Params,
                    #{handler_state := HState} = State, Handler) ->
    try Handler:handle_roots_list(HState) of
        {ok, Roots, NewHState} ->
            Resp = beam_agent_mcp_protocol:roots_list_response(Id, Roots),
            {server_request, Resp, State#{handler_state => NewHState}};
        {error, Code, Msg} ->
            Resp = beam_agent_mcp_protocol:error_response(Id, Code, Msg),
            {server_request, Resp, State}
    catch
        Class:Reason:Stack ->
            SafeStack = [{M, F, if is_list(A) -> length(A); true -> A end, L}
                         || {M, F, A, L} <- Stack],
            logger:error("MCP client handler crash in ~s: ~p:~p~n~p",
                         [<<"handle_roots_list">>, Class, Reason, SafeStack]),
            Resp = beam_agent_mcp_protocol:error_response(
                       Id, beam_agent_mcp_protocol:error_internal(),
                       <<"Handler crashed">>),
            {server_request, Resp, State}
    end.

%%--------------------------------------------------------------------
%% Internal: Notification Dispatch
%%--------------------------------------------------------------------

-spec dispatch_notification(binary(), map(), client_state()) ->
    client_result().

%% Notifications that indicate server-side changes.
%% The caller may want to re-fetch the relevant list.
dispatch_notification(<<"notifications/tools/list_changed">>,
                      Params, State) ->
    {notification, <<"notifications/tools/list_changed">>, Params, State};
dispatch_notification(<<"notifications/resources/list_changed">>,
                      Params, State) ->
    {notification, <<"notifications/resources/list_changed">>, Params, State};
dispatch_notification(<<"notifications/resources/updated">>,
                      Params, State) ->
    {notification, <<"notifications/resources/updated">>, Params, State};
dispatch_notification(<<"notifications/prompts/list_changed">>,
                      Params, State) ->
    {notification, <<"notifications/prompts/list_changed">>, Params, State};

%% Logging message from server.
dispatch_notification(<<"notifications/message">>, Params, State) ->
    {notification, <<"notifications/message">>, Params, State};

%% Progress notification from server.
dispatch_notification(<<"notifications/progress">>, Params, State) ->
    {notification, <<"notifications/progress">>, Params, State};

%% Cancelled notification from server.
dispatch_notification(<<"notifications/cancelled">>, Params, State) ->
    RequestId = maps:get(<<"requestId">>, Params, undefined),
    %% If we have a pending request with this ID, remove it
    State1 = case RequestId of
        undefined -> State;
        _ -> untrack_request(RequestId, State)
    end,
    {notification, <<"notifications/cancelled">>, Params, State1};

%% Unknown notifications — surface to caller, don't drop silently.
dispatch_notification(Method, Params, State) ->
    {notification, Method, Params, State}.

%%--------------------------------------------------------------------
%% Internal: Request ID Generation
%%--------------------------------------------------------------------

-spec next_request_id(client_state()) ->
    {pos_integer(), client_state()}.
next_request_id(#{next_id := Id} = State) ->
    {Id, State#{next_id => Id + 1}}.

%%--------------------------------------------------------------------
%% Internal: Pending Request Tracking
%%--------------------------------------------------------------------

%% Pure: accepts the current monotonic time from the caller.
-spec track_request(beam_agent_mcp_protocol:request_id(), binary(),
                    integer(), client_state()) -> client_state().
track_request(Id, Method, Now, #{pending := Pending,
                                 default_timeout := Timeout} = State) ->
    Req = #{
        method => Method,
        deadline => Now + Timeout,
        sent_at => Now
    },
    State#{pending => Pending#{Id => Req}}.

%% Boundary: reads the monotonic clock and delegates to the pure tracker.
%% This is the sole point of impurity, kept at the outermost layer of the
%% internal API so that track_request/4 remains fully testable.
-spec track_request_now(beam_agent_mcp_protocol:request_id(), binary(),
                        client_state()) -> client_state().
track_request_now(Id, Method, State) ->
    track_request(Id, Method, erlang:monotonic_time(millisecond), State).

-spec untrack_request(beam_agent_mcp_protocol:request_id(),
                      client_state()) -> client_state().
untrack_request(Id, #{pending := Pending} = State) ->
    State#{pending => maps:remove(Id, Pending)}.

%%--------------------------------------------------------------------
%% Internal: Lifecycle Guards
%%--------------------------------------------------------------------

-spec require_ready(client_state()) -> ok.
require_ready(#{lifecycle := ready}) -> ok;
require_ready(#{lifecycle := Lifecycle}) ->
    error({not_ready, Lifecycle}).

%%--------------------------------------------------------------------
%% Internal: Client Capability Normalization
%%--------------------------------------------------------------------

%% Normalize client capabilities to use atom keys.
%% Accepts both atom-keyed and binary-keyed maps for caller convenience.
-spec normalize_client_caps(map()) -> map().
normalize_client_caps(Caps) when is_map(Caps) ->
    maps:fold(fun
        (K, V, Acc) when is_atom(K) -> Acc#{K => V};
        (K, V, Acc) when is_binary(K) ->
            case beam_agent_mcp_protocol:safe_capability_atom(K) of
                undefined -> Acc;
                Atom -> Acc#{Atom => V}
            end;
        (_, _, Acc) -> Acc
    end, #{}, Caps).

%%--------------------------------------------------------------------
%% Internal: Capability Decoding
%%--------------------------------------------------------------------

%% Decode server capabilities from wire format (binary keys) to atoms.
%% Delegates to the shared protocol decoder.
-spec decode_server_capabilities(map()) ->
    beam_agent_mcp_protocol:server_capabilities().
decode_server_capabilities(WireCaps) ->
    beam_agent_mcp_protocol:decode_wire_capabilities(WireCaps).
