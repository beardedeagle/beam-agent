-module(codex_session).
-moduledoc false.

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

%% Codex-specific functions
-export([
    respond_request/3
]).

%%====================================================================
%% beam_agent_behaviour callbacks
%%====================================================================

-spec start_link(beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    beam_agent_session_engine:start_link(codex_session_handler, Opts).

-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    beam_agent_session_engine:send_query(Pid, Prompt, Params, Timeout).

-spec receive_message(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    beam_agent_session_engine:receive_message(Pid, Ref, Timeout).

-spec health(pid()) -> ready | connecting | initializing | active_query | error.
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
%% Codex-specific functions
%%====================================================================

-doc """
Respond to a pending server request (approval, user input, etc.).

The request_id comes from a `control_request` message delivered via
`receive_message/3`. The params map depends on the request kind.
""".
-spec respond_request(pid(), binary() | integer(), map()) ->
    {ok, term()} | {error, term()}.
respond_request(Pid, RequestId, Params) ->
    gen_statem:call(Pid, {respond_request, RequestId, Params}, 30000).
