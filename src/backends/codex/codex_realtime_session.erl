-module(codex_realtime_session).
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

%% Realtime-specific functions
-export([
    thread_realtime_start/2,
    thread_realtime_append_audio/3,
    thread_realtime_append_text/3,
    thread_realtime_stop/2
]).

%%====================================================================
%% beam_agent_behaviour callbacks
%%====================================================================

-spec start_link(beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    beam_agent_session_engine:start_link(
        codex_realtime_session_handler, Opts).

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
%% Realtime-specific functions
%%====================================================================

-doc "Start a new realtime thread for audio/text streaming.".
-spec thread_realtime_start(pid(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_start(Pid, Params) ->
    gen_statem:call(Pid, {thread_realtime_start, Params}, 30000).

-doc "Append audio data to an active realtime thread.".
-spec thread_realtime_append_audio(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_audio(Pid, ThreadId, Params) ->
    gen_statem:call(Pid, {thread_realtime_append_audio, ThreadId, Params}, 30000).

-doc "Append text to an active realtime thread.".
-spec thread_realtime_append_text(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
thread_realtime_append_text(Pid, ThreadId, Params) ->
    gen_statem:call(Pid, {thread_realtime_append_text, ThreadId, Params}, 30000).

-doc "Stop an active realtime thread.".
-spec thread_realtime_stop(pid(), binary()) ->
    {ok, map()} | {error, term()}.
thread_realtime_stop(Pid, ThreadId) ->
    gen_statem:call(Pid, {thread_realtime_stop, ThreadId}, 30000).
