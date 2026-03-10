-module(opencode_session).
-moduledoc """
OpenCode session — thin wrapper over the session engine.

Implements `beam_agent_behaviour` by delegating all lifecycle operations
to `beam_agent_session_engine` with `opencode_session_handler` as the
backend handler. Also exposes OpenCode-specific functions (event
subscription, REST endpoints) that route through the engine as custom
calls.

## Usage

```erlang
{ok, Pid} = opencode_session:start_link(#{
    directory => <<"/home/user/project">>,
    base_url  => <<"http://localhost:4096">>
}).
{ok, Ref} = opencode_session:send_query(Pid, <<"Hello">>, #{}, 30000).
{ok, Msg} = opencode_session:receive_message(Pid, Ref, 30000).
```
""".

-behaviour(beam_agent_behaviour).

%% beam_agent_behaviour callbacks
-export([
    start_link/1,
    send_query/4,
    receive_message/3,
    health/1,
    stop/1
]).

%% Extended session API
-export([
    send_control/3,
    interrupt/1,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).

%% OpenCode-specific: event subscription
-export([
    subscribe_events/1,
    receive_event/3,
    unsubscribe_events/2
]).

%%====================================================================
%% beam_agent_behaviour callbacks
%%====================================================================

-spec start_link(beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    beam_agent_session_engine:start_link(
        opencode_session_handler, Opts).

-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    beam_agent_session_engine:send_query(Pid, Prompt, Params, Timeout).

-spec receive_message(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    beam_agent_session_engine:receive_message(Pid, Ref, Timeout).

-spec health(pid()) ->
    ready | connecting | initializing | active_query | error.
health(Pid) ->
    beam_agent_session_engine:health(Pid).

-spec stop(pid()) -> ok.
stop(Pid) ->
    beam_agent_session_engine:stop(Pid).

%%====================================================================
%% Extended session API
%%====================================================================

-spec send_control(pid(), binary(), map()) ->
    {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    beam_agent_session_engine:send_control(Pid, Method, Params).

-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    beam_agent_session_engine:interrupt(Pid).

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    beam_agent_session_engine:session_info(Pid).

-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    beam_agent_session_engine:set_model(Pid, Model).

-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    beam_agent_session_engine:set_permission_mode(Pid, Mode).

%%====================================================================
%% OpenCode-specific: event subscription
%%====================================================================

-doc "Subscribe to server-sent events from the OpenCode backend.".
-spec subscribe_events(pid()) -> {ok, reference()} | {error, term()}.
subscribe_events(Pid) ->
    gen_statem:call(Pid, subscribe_events, 5000).

-doc "Receive the next event (blocks until available or timeout).".
-spec receive_event(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_event(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_event, Ref}, Timeout).

-doc "Unsubscribe from server-sent events.".
-spec unsubscribe_events(pid(), reference()) -> ok | {error, term()}.
unsubscribe_events(Pid, Ref) ->
    gen_statem:call(Pid, {unsubscribe_events, Ref}, 5000).
