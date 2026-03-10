-module(beam_agent_session_engine).
-moduledoc """
Generic session engine for all agentic coder backends.

Implements the session lifecycle as a gen_statem framework that
delegates backend-specific logic to a `beam_agent_session_handler`
callback module. The engine handles all shared orchestration:

  - State machine lifecycle (connecting → initializing → ready →
    active_query → error)
  - Consumer/queue management (blocking receive, queue drain)
  - Telemetry (state transitions, query spans)
  - Query ref validation and cancel support
  - Buffer overflow detection
  - Error state with auto-stop (60s)
  - Transport lifecycle (start, close, classify incoming messages)

Adding a new backend requires only implementing ~10 focused callbacks
in a handler module. The engine provides all shared behaviour for free.

## Starting a Session

```erlang
beam_agent_session_engine:start_link(my_session_handler, Opts).
```

The engine calls `my_session_handler:init_handler(Opts)` to get the
transport specification, initial state, and handler state. The engine
starts the transport and enters the initial state.

## Architecture

```
Consumer → beam_agent_behaviour API
         → beam_agent_session_engine (this module, gen_statem)
         → beam_agent_session_handler callbacks (per-backend)
         → beam_agent_transport (byte I/O)
```

Zero additional processes — the engine gen_statem IS the session process.
""".

-behaviour(gen_statem).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-export([
    start_link/2,
    send_query/4,
    receive_message/3,
    health/1,
    stop/1,
    send_control/3,
    interrupt/1,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

-export([
    callback_mode/0,
    init/1,
    terminate/3
]).

-export([
    connecting/3,
    initializing/3,
    ready/3,
    active_query/3,
    error/3
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type state_name() :: beam_agent_session_handler:state_name().

-record(engine, {
    %% Handler
    handler_mod   :: module(),
    handler_state :: term(),

    %% Transport
    transport_mod :: module(),
    transport_ref :: beam_agent_transport:transport_ref(),

    %% Buffering (used in ready/active_query; handlers own buffer
    %% during connecting/initializing)
    buffer     = <<>> :: binary(),
    buffer_max        :: pos_integer(),

    %% Consumer management
    consumer  :: gen_statem:from() | undefined,
    query_ref :: reference() | undefined,
    msg_queue = queue:new() :: queue:queue(),

    %% Session identity
    session_id      :: binary(),
    model           :: binary() | undefined,
    permission_mode :: binary() | undefined,
    opts            :: map(),

    %% Telemetry
    query_start_time :: integer() | undefined,

    %% Query outcome for ready-state drain
    query_status = complete :: complete | interrupted | cancelled
}).

%%--------------------------------------------------------------------
%% Default timeout values
%%--------------------------------------------------------------------

-define(CONNECT_TIMEOUT, 15_000).
-define(INIT_TIMEOUT, 15_000).
-define(BUFFER_MAX_DEFAULT, 10_000_000).
-define(ERROR_AUTO_STOP, 60_000).

%%====================================================================
%% Public API
%%====================================================================

-doc "Start a session engine with the given handler module.".
-spec start_link(Handler :: module(), Opts :: beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_link(HandlerMod, Opts) ->
    gen_statem:start_link(?MODULE, {HandlerMod, Opts}, []).

-doc "Send a query to the backend. Returns a ref for receive_message/3.".
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

-doc "Receive the next message for the given query ref. Blocks if none available.".
-spec receive_message(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

-doc "Return the current session state as a health indicator.".
-spec health(pid()) -> state_name().
health(Pid) ->
    gen_statem:call(Pid, health, 5_000).

-doc "Stop the session engine.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10_000).

-doc "Send a control message to the backend.".
-spec send_control(pid(), binary(), map()) ->
    {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 10_000).

-doc "Interrupt the current query.".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5_000).

-doc "Return session info (handler info merged with engine metadata).".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5_000).

-doc "Change the model at runtime.".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5_000).

-doc "Change the permission mode at runtime.".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5_000).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() ->
    [state_functions, state_enter].

-spec init({module(), map()}) ->
    gen_statem:init_result(state_name()) | {stop, term()}.
init({HandlerMod, Opts}) ->
    process_flag(trap_exit, true),
    %% Generate session_id before calling init_handler so the handler
    %% can rely on it being present in Opts.
    SessionId = ensure_session_id(maps:get(session_id, Opts, undefined)),
    Opts1 = Opts#{session_id => SessionId},
    case HandlerMod:init_handler(Opts1) of
        {ok, #{transport_spec := {TMod, TOpts},
               initial_state  := InitState,
               handler_state  := HState}} ->
            case TMod:start(TOpts) of
                {ok, TRef} ->
                    HState1 = notify_transport_started(HandlerMod, TRef,
                                                       HState),
                    Data = #engine{
                        handler_mod   = HandlerMod,
                        handler_state = HState1,
                        transport_mod = TMod,
                        transport_ref = TRef,
                        buffer_max    = maps:get(buffer_max, Opts1,
                                                 ?BUFFER_MAX_DEFAULT),
                        session_id    = SessionId,
                        model         = maps:get(model, Opts1, undefined),
                        permission_mode = maps:get(permission_mode, Opts1,
                                                   undefined),
                        opts          = Opts1
                    },
                    TimeoutAction = timeout_action(InitState, Opts1),
                    {ok, InitState, Data, TimeoutAction};
                {error, Reason} ->
                    {stop, {transport_start_failed, Reason}}
            end;
        {stop, Reason} ->
            {stop, Reason}
    end.

-spec terminate(term(), state_name(), #engine{}) -> ok.
terminate(Reason, _State, #engine{handler_mod   = H,
                                   handler_state = HState,
                                   transport_mod = TMod,
                                   transport_ref = TRef}) ->
    _ = H:terminate_handler(Reason, HState),
    _ = TMod:close(TRef),
    ok.

%%====================================================================
%% State: connecting
%%====================================================================

-spec connecting(gen_statem:event_type(), term(), #engine{}) ->
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).
connecting(enter, OldState, Data) ->
    fire_state_enter(connecting, OldState, Data);
connecting(state_timeout, connect_timeout, Data) ->
    dispatch_connecting(connect_timeout, Data);
connecting(info, Msg, Data) ->
    case classify(Msg, Data) of
        ignore ->
            dispatch_handler_info(Msg, connecting, Data);
        Event ->
            dispatch_connecting(Event, Data)
    end;
connecting({call, From}, Request, Data) ->
    handle_common_call(From, Request, connecting, Data).

%%====================================================================
%% State: initializing
%%====================================================================

-spec initializing(gen_statem:event_type(), term(), #engine{}) ->
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).
initializing(enter, OldState, Data) ->
    fire_state_enter(initializing, OldState, Data);
initializing(state_timeout, init_timeout, Data) ->
    dispatch_initializing(init_timeout, Data);
initializing(info, Msg, Data) ->
    case classify(Msg, Data) of
        ignore ->
            dispatch_handler_info(Msg, initializing, Data);
        Event ->
            dispatch_initializing(Event, Data)
    end;
initializing({call, From}, Request, Data) ->
    handle_common_call(From, Request, initializing, Data).

%%====================================================================
%% State: ready
%%====================================================================

-spec ready(gen_statem:event_type(), term(), #engine{}) ->
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).
ready(enter, OldState, Data) ->
    Data1 = Data#engine{consumer = undefined, query_ref = undefined},
    fire_state_enter(ready, OldState, Data1);
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    handle_send_query(From, Prompt, Params, Data);
ready({call, From}, {receive_message, _Ref},
      #engine{query_status = Status} = Data)
  when Status =/= complete ->
    %% Query was interrupted/cancelled — discard stale messages
    {keep_state,
     Data#engine{msg_queue = queue:new(), query_status = complete},
     [{reply, From, {error, Status}}]};
ready({call, From}, {receive_message, _Ref}, Data) ->
    %% In ready state: drain queue, then signal complete
    case queue:out(Data#engine.msg_queue) of
        {{value, Msg}, Q2} ->
            {keep_state, Data#engine{msg_queue = Q2},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state_and_data,
             [{reply, From, {error, complete}}]}
    end;
ready(info, Msg, Data) ->
    case classify(Msg, Data) of
        ignore ->
            dispatch_handler_info(Msg, ready, Data);
        {data, RawData} ->
            handle_incoming_data(RawData, ready, Data);
        {exit, Status} ->
            handle_transport_exit(Status, Data);
        {disconnected, Reason} ->
            enter_error({disconnected, Reason}, Data);
        _Other ->
            keep_state_and_data
    end;
ready({call, From}, Request, Data) ->
    handle_common_call(From, Request, ready, Data).

%%====================================================================
%% State: active_query
%%====================================================================

-spec active_query(gen_statem:event_type(), term(), #engine{}) ->
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).
active_query(enter, OldState, Data) ->
    fire_state_enter(active_query, OldState, Data);
active_query({call, From}, {receive_message, Ref},
             #engine{query_ref = Ref} = Data) ->
    %% Matching ref: deliver from queue or block
    case queue:out(Data#engine.msg_queue) of
        {{value, Msg}, Q2} ->
            Data1 = Data#engine{msg_queue = Q2},
            maybe_complete_on_deliver(Msg, From, Data1);
        {empty, _} ->
            {keep_state, Data#engine{consumer = From}}
    end;
active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};
active_query({call, From}, interrupt, Data) ->
    handle_interrupt(From, Data);
active_query({call, From}, {cancel, Ref},
             #engine{query_ref = Ref} = Data) ->
    Actions = [{reply, From, ok}
               | consumer_error_actions(cancelled, Data)],
    maybe_span_stop(Data),
    {next_state, ready,
     Data#engine{consumer = undefined, query_start_time = undefined,
                 msg_queue = queue:new(), query_status = cancelled},
     Actions};
active_query({call, From}, {cancel, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};
active_query(info, Msg, Data) ->
    case classify(Msg, Data) of
        ignore ->
            dispatch_handler_info(Msg, active_query, Data);
        {data, RawData} ->
            handle_incoming_data(RawData, active_query, Data);
        {exit, Status} ->
            reply_consumer_error({cli_exit, Status}, Data),
            handle_transport_exit(Status,
                                  Data#engine{consumer = undefined,
                                              query_start_time = undefined});
        {disconnected, Reason} ->
            reply_consumer_error({disconnected, Reason}, Data),
            enter_error({disconnected, Reason},
                        Data#engine{consumer = undefined});
        _Other ->
            keep_state_and_data
    end;
active_query({call, From}, Request, Data) ->
    handle_common_call(From, Request, active_query, Data).

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #engine{}) ->
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).
error(enter, OldState, #engine{transport_mod = TMod,
                               transport_ref = TRef} = Data) ->
    %% Close transport, reply to pending consumer
    _ = TMod:close(TRef),
    reply_consumer_error(session_error, Data),
    Data1 = Data#engine{consumer = undefined},
    fire_state_enter(error, OldState, Data1,
                     [{state_timeout, ?ERROR_AUTO_STOP, auto_stop}]);
error(state_timeout, auto_stop, _Data) ->
    {stop, {shutdown, session_error}};
error(internal, Reason, #engine{handler_mod = H}) ->
    Backend = H:backend_name(),
    logger:error("~s session engine error: ~p", [Backend, Reason]),
    keep_state_and_data;
error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};
error({call, From}, session_info, Data) ->
    Info = build_engine_session_info(error, Data),
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
error({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]};
error(info, _Msg, _Data) ->
    keep_state_and_data.

%%====================================================================
%% Common call dispatch (health, session_info, set_model, etc.)
%%====================================================================

-spec handle_common_call(gen_statem:from(), term(), state_name(),
                         #engine{}) ->
    gen_statem:event_handler_result(state_name()).
handle_common_call(From, interrupt, _StateName, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};
handle_common_call(From, health, StateName, _Data) ->
    {keep_state_and_data, [{reply, From, StateName}]};
handle_common_call(From, session_info, StateName, Data) ->
    Info = build_engine_session_info(StateName, Data),
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
handle_common_call(From, {send_control, Method, Params}, _StateName,
                   #engine{handler_mod = H, handler_state = HState} = Data) ->
    case erlang:function_exported(H, handle_control, 4) of
        true ->
            case H:handle_control(Method, Params, From, HState) of
                {reply, Result, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    {keep_state, Data1, [{reply, From, {ok, Result}}]};
                {noreply, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    {keep_state, Data1};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        false ->
            {keep_state_and_data,
             [{reply, From, {error, not_supported}}]}
    end;
handle_common_call(From, {set_model, Model},
                   _StateName,
                   #engine{handler_mod = H, handler_state = HState} = Data) ->
    case erlang:function_exported(H, handle_set_model, 2) of
        true ->
            case H:handle_set_model(Model, HState) of
                {ok, Result, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1,
                                            model = Model}),
                    {keep_state, Data1, [{reply, From, {ok, Result}}]};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        false ->
            {keep_state, Data#engine{model = Model},
             [{reply, From, {ok, Model}}]}
    end;
handle_common_call(From, {set_permission_mode, Mode},
                   _StateName,
                   #engine{handler_mod = H, handler_state = HState} = Data) ->
    case erlang:function_exported(H, handle_set_permission_mode, 2) of
        true ->
            case H:handle_set_permission_mode(Mode, HState) of
                {ok, Result, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1,
                                            permission_mode = Mode}),
                    {keep_state, Data1, [{reply, From, {ok, Result}}]};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        false ->
            {keep_state, Data#engine{permission_mode = Mode},
             [{reply, From, {ok, Mode}}]}
    end;
handle_common_call(From, Request, _StateName,
                   #engine{handler_mod = H, handler_state = HState} = Data) ->
    %% Unknown call — route to handler's handle_custom_call if implemented
    case erlang:function_exported(H, handle_custom_call, 3) of
        true ->
            case H:handle_custom_call(Request, From, HState) of
                {reply, Reply, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    {keep_state, Data1, [{reply, From, Reply}]};
                {noreply, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    {keep_state, Data1};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        false ->
            {keep_state_and_data,
             [{reply, From, {error, unsupported}}]}
    end.

%%====================================================================
%% Internal: connecting/initializing dispatch
%%====================================================================

-spec dispatch_connecting(beam_agent_session_handler:transport_event(),
                          #engine{}) ->
    gen_statem:event_handler_result(state_name()).
dispatch_connecting(Event,
                    #engine{handler_mod = H, handler_state = HState} = Data) ->
    case H:handle_connecting(Event, HState) of
        {next_state, NextState, Actions, HState1} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1}),
            TimeoutAction = timeout_action(NextState, Data1#engine.opts),
            {next_state, NextState, Data1, TimeoutAction};
        {next_state, NextState, Actions, HState1, Buffer} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1,
                                    buffer = Buffer}),
            TimeoutAction = timeout_action(NextState, Data1#engine.opts),
            {next_state, NextState, Data1, TimeoutAction};
        {keep_state, Actions, HState1} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1}),
            {keep_state, Data1};
        {error_state, Reason, HState1} ->
            enter_error(Reason,
                        Data#engine{handler_state = HState1})
    end.

-spec dispatch_initializing(beam_agent_session_handler:transport_event(),
                            #engine{}) ->
    gen_statem:event_handler_result(state_name()).
dispatch_initializing(Event,
                      #engine{handler_mod = H,
                              handler_state = HState} = Data) ->
    case H:handle_initializing(Event, HState) of
        {next_state, NextState, Actions, HState1} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1}),
            {next_state, NextState, Data1};
        {next_state, NextState, Actions, HState1, Buffer} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1,
                                    buffer = Buffer}),
            {next_state, NextState, Data1};
        {keep_state, Actions, HState1} ->
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1}),
            {keep_state, Data1};
        {error_state, Reason, HState1} ->
            enter_error(Reason,
                        Data#engine{handler_state = HState1})
    end.

%%====================================================================
%% Internal: handler info dispatch (unclassified messages)
%%====================================================================

-spec dispatch_handler_info(term(), state_name(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
dispatch_handler_info(Msg, StateName,
                      #engine{handler_mod = H,
                              handler_state = HState} = Data) ->
    case erlang:function_exported(H, handle_info, 3) of
        false ->
            keep_state_and_data;
        true ->
            case H:handle_info(Msg, StateName, HState) of
                ignore ->
                    keep_state_and_data;
                {messages, Messages, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    case StateName of
                        active_query ->
                            deliver_messages(Messages, Data1);
                        _ ->
                            Data2 = queue_messages(Messages, Data1),
                            {keep_state, Data2}
                    end;
                {next_state, NextState, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    TimeoutAction = timeout_action(NextState,
                                                   Data1#engine.opts),
                    {next_state, NextState, Data1, TimeoutAction};
                {next_state, NextState, Actions, HState1, Buffer} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1,
                                            buffer = Buffer}),
                    TimeoutAction = timeout_action(NextState,
                                                   Data1#engine.opts),
                    {next_state, NextState, Data1, TimeoutAction};
                {keep_state, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    {keep_state, Data1};
                {error_state, Reason, HState1} ->
                    enter_error(Reason,
                                Data#engine{handler_state = HState1})
            end
    end.

%%====================================================================
%% Internal: send_query
%%====================================================================

-spec handle_send_query(gen_statem:from(), binary(),
                        beam_agent_core:query_opts(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
handle_send_query(From, Prompt, Params,
                  #engine{handler_mod = H, handler_state = HState} = Data) ->
    case H:encode_query(Prompt, Params, HState) of
        {ok, Encoded, HState1} ->
            case send_transport(Encoded, Data) of
                ok ->
                    Ref = make_ref(),
                    Backend = H:backend_name(),
                    StartTime = beam_agent_telemetry_core:span_start(
                                    Backend, query, #{prompt => Prompt}),
                    Data1 = Data#engine{
                        handler_state    = HState1,
                        query_ref        = Ref,
                        msg_queue        = queue:new(),
                        query_start_time = StartTime,
                        query_status     = complete
                    },
                    {next_state, active_query, Data1,
                     [{reply, From, {ok, Ref}}]};
                {error, Reason} ->
                    {keep_state, Data#engine{handler_state = HState1},
                     [{reply, From, {error, {send_failed, Reason}}}]}
            end;
        {error, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, Reason}}]}
    end.

%%====================================================================
%% Internal: interrupt
%%====================================================================

-spec handle_interrupt(gen_statem:from(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
handle_interrupt(From, #engine{handler_mod = H,
                               handler_state = HState} = Data) ->
    case erlang:function_exported(H, encode_interrupt, 1) of
        true ->
            case H:encode_interrupt(HState) of
                {ok, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{handler_state = HState1}),
                    ReplyActions = [{reply, From, ok}
                                   | consumer_error_actions(interrupted,
                                                            Data1)],
                    maybe_span_stop(Data1),
                    {next_state, ready,
                     Data1#engine{consumer         = undefined,
                                  query_start_time = undefined,
                                  msg_queue        = queue:new(),
                                  query_status     = interrupted},
                     ReplyActions};
                not_supported ->
                    {keep_state_and_data,
                     [{reply, From, {error, not_supported}}]}
            end;
        false ->
            {keep_state_and_data,
             [{reply, From, {error, not_supported}}]}
    end.

%%====================================================================
%% Internal: incoming data handling
%%====================================================================

-spec handle_incoming_data(binary(), state_name(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
handle_incoming_data(RawData, StateName,
                     #engine{handler_mod = H,
                             handler_state = HState} = Data) ->
    Combined = <<(Data#engine.buffer)/binary, RawData/binary>>,
    case byte_size(Combined) > Data#engine.buffer_max of
        true ->
            beam_agent_telemetry_core:buffer_overflow(
                byte_size(Combined), Data#engine.buffer_max),
            reply_consumer_error(buffer_overflow, Data),
            enter_error(buffer_overflow,
                        Data#engine{consumer = undefined});
        false ->
            case H:handle_data(Combined, HState) of
                {ok, Messages, NewBuf, Actions, HState1} ->
                    Data1 = execute_send_actions(
                                Actions,
                                Data#engine{buffer        = NewBuf,
                                            handler_state = HState1}),
                    case StateName of
                        active_query ->
                            deliver_messages(Messages, Data1);
                        ready ->
                            Data2 = queue_messages(Messages, Data1),
                            {keep_state, Data2}
                    end
            end
    end.

%%====================================================================
%% Internal: message delivery (active_query)
%%====================================================================

-spec deliver_messages([beam_agent_core:message()], #engine{}) ->
    gen_statem:event_handler_result(state_name()).
deliver_messages([], Data) ->
    {keep_state, Data};
deliver_messages([Msg | Rest], Data) ->
    Complete = is_query_complete(Msg, Data),
    Data1 = try_deliver_message(Msg, Data),
    case Complete of
        true ->
            Data2 = queue_messages(Rest, Data1),
            maybe_span_stop(Data2),
            {next_state, ready,
             Data2#engine{query_start_time = undefined}};
        false ->
            deliver_messages(Rest, Data1)
    end.

-spec try_deliver_message(beam_agent_core:message(), #engine{}) -> #engine{}.
try_deliver_message(Msg, #engine{consumer = undefined} = Data) ->
    Data#engine{msg_queue = queue:in(Msg, Data#engine.msg_queue)};
try_deliver_message(Msg, #engine{consumer = From} = Data) ->
    gen_statem:reply(From, {ok, Msg}),
    Data#engine{consumer = undefined}.

-spec maybe_complete_on_deliver(beam_agent_core:message(),
                                gen_statem:from(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
maybe_complete_on_deliver(Msg, From, Data) ->
    case is_query_complete(Msg, Data) of
        true ->
            maybe_span_stop(Data),
            {next_state, ready,
             Data#engine{query_start_time = undefined},
             [{reply, From, {ok, Msg}}]};
        false ->
            {keep_state, Data, [{reply, From, {ok, Msg}}]}
    end.

%%====================================================================
%% Internal: transport helpers
%%====================================================================

-spec classify(term(), #engine{}) ->
    beam_agent_session_handler:transport_event() | ignore.
classify(Msg, #engine{transport_mod = TMod, transport_ref = TRef}) ->
    TMod:classify_message(Msg, TRef).

-spec send_transport(term(), #engine{}) -> ok | {error, term()}.
send_transport(Data, #engine{transport_mod = TMod, transport_ref = TRef}) ->
    TMod:send(TRef, Data).

-spec execute_send_actions([beam_agent_session_handler:handler_action()],
                           #engine{}) -> #engine{}.
execute_send_actions([], Data) ->
    Data;
execute_send_actions([{send, Payload} | Rest], Data) ->
    _ = send_transport(Payload, Data),
    execute_send_actions(Rest, Data).

%%====================================================================
%% Internal: state enter / telemetry
%%====================================================================

-spec fire_state_enter(state_name(), state_name() | undefined, #engine{}) ->
    gen_statem:state_enter_result(state_name()).
fire_state_enter(NewState, OldState, Data) ->
    fire_state_enter(NewState, OldState, Data, []).

-spec fire_state_enter(state_name(), state_name() | undefined,
                       #engine{}, [gen_statem:action()]) ->
    gen_statem:state_enter_result(state_name()).
fire_state_enter(NewState, OldState,
                 #engine{handler_mod = H, handler_state = HState} = Data,
                 ExtraActions) ->
    Backend = H:backend_name(),
    OldForTelemetry = case OldState of
        NewState -> undefined;  % gen_statem repeat_state
        Other    -> Other
    end,
    beam_agent_telemetry_core:state_change(Backend, OldForTelemetry, NewState),
    case erlang:function_exported(H, on_state_enter, 3) of
        true ->
            {ok, Actions, HState1} =
                H:on_state_enter(NewState, OldForTelemetry, HState),
            Data1 = execute_send_actions(
                        Actions,
                        Data#engine{handler_state = HState1}),
            {keep_state, Data1, ExtraActions};
        false ->
            {keep_state, Data, ExtraActions}
    end.

%%====================================================================
%% Internal: query completion detection
%%====================================================================

-spec is_query_complete(beam_agent_core:message(), #engine{}) -> boolean().
is_query_complete(Msg, #engine{handler_mod = H, handler_state = HState}) ->
    case erlang:function_exported(H, is_query_complete, 2) of
        true  -> H:is_query_complete(Msg, HState);
        false -> maps:get(type, Msg, undefined) =:= result
    end.

%%====================================================================
%% Internal: telemetry span helpers
%%====================================================================

-spec maybe_span_stop(#engine{}) -> ok.
maybe_span_stop(#engine{query_start_time = undefined}) ->
    ok;
maybe_span_stop(#engine{handler_mod = H,
                         query_start_time = StartTime}) ->
    beam_agent_telemetry_core:span_stop(H:backend_name(), query, StartTime).

%%====================================================================
%% Internal: error state transition
%%====================================================================

-spec enter_error(term(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
enter_error(Reason, Data) ->
    {next_state, error, Data,
     [{next_event, internal, Reason}]}.

%%====================================================================
%% Internal: transport exit handling
%%====================================================================

-spec handle_transport_exit(non_neg_integer(), #engine{}) ->
    gen_statem:event_handler_result(state_name()).
handle_transport_exit(Status, Data) ->
    maybe_span_exception(Data, {transport_exit, Status}),
    enter_error({transport_exit, Status}, Data).

-spec maybe_span_exception(#engine{}, term()) -> ok.
maybe_span_exception(#engine{query_start_time = undefined}, _Reason) ->
    ok;
maybe_span_exception(#engine{handler_mod = H}, Reason) ->
    beam_agent_telemetry_core:span_exception(H:backend_name(), query, Reason).

%%====================================================================
%% Internal: consumer management helpers
%%====================================================================

-spec reply_consumer_error(term(), #engine{}) -> ok.
reply_consumer_error(_Reason, #engine{consumer = undefined}) ->
    ok;
reply_consumer_error(Reason, #engine{consumer = From}) ->
    gen_statem:reply(From, {error, Reason}).

-spec consumer_error_actions(term(), #engine{}) -> [gen_statem:action()].
consumer_error_actions(_Reason, #engine{consumer = undefined}) ->
    [];
consumer_error_actions(Reason, #engine{consumer = Consumer}) ->
    [{reply, Consumer, {error, Reason}}].

%%====================================================================
%% Internal: queue helpers
%%====================================================================

-spec queue_messages([beam_agent_core:message()], #engine{}) -> #engine{}.
queue_messages([], Data) ->
    Data;
queue_messages([Msg | Rest], Data) ->
    Q = queue:in(Msg, Data#engine.msg_queue),
    queue_messages(Rest, Data#engine{msg_queue = Q}).

%%====================================================================
%% Internal: session info builder
%%====================================================================

-spec build_engine_session_info(state_name(), #engine{}) -> map().
build_engine_session_info(StateName,
                          #engine{handler_mod = H,
                                  handler_state = HState,
                                  session_id = SessionId,
                                  model = Model,
                                  permission_mode = PermMode}) ->
    HandlerInfo = H:build_session_info(HState),
    EngineInfo = #{
        session_id      => SessionId,
        state           => StateName,
        backend         => H:backend_name()
    },
    EngineInfo1 = maybe_put(model, Model, EngineInfo),
    EngineInfo2 = maybe_put(permission_mode, PermMode, EngineInfo1),
    maps:merge(HandlerInfo, EngineInfo2).

%%====================================================================
%% Internal: handler notification helpers
%%====================================================================

-spec notify_transport_started(module(),
                               beam_agent_transport:transport_ref(),
                               term()) -> term().
notify_transport_started(H, TRef, HState) ->
    case erlang:function_exported(H, transport_started, 2) of
        true  -> H:transport_started(TRef, HState);
        false -> HState
    end.

%%====================================================================
%% Internal: utility helpers
%%====================================================================

-spec ensure_session_id(binary() | undefined) -> binary().
ensure_session_id(undefined) ->
    make_session_id();
ensure_session_id(Id) when is_binary(Id) ->
    Id.

-spec make_session_id() -> binary().
make_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    <<"session_", Hex/binary>>.

-spec timeout_action(state_name(), map()) -> [gen_statem:action()].
timeout_action(connecting, Opts) ->
    Timeout = maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT),
    [{state_timeout, Timeout, connect_timeout}];
timeout_action(initializing, Opts) ->
    Timeout = maps:get(init_timeout, Opts, ?INIT_TIMEOUT),
    [{state_timeout, Timeout, init_timeout}];
timeout_action(_State, _Opts) ->
    [].

-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.
