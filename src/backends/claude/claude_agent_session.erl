-module(claude_agent_session).
-moduledoc """
Claude Code session — thin wrapper over the session engine.

Implements `beam_agent_behaviour` by delegating all lifecycle operations
to `beam_agent_session_engine` with `claude_session_handler` as the
backend handler. Also exposes Claude-specific convenience functions
(cancel, rewind, MCP, etc.) that map to `send_control/3` calls.

## Usage

```erlang
{ok, Pid} = claude_agent_session:start_link(#{
    cli_path => "/usr/local/bin/claude",
    model    => <<"claude-sonnet-4-20250514">>
}).
{ok, Ref} = claude_agent_session:send_query(Pid, <<"Hello">>, #{}, 30000).
{ok, Msg} = claude_agent_session:receive_message(Pid, Ref, 30000).
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

%% Claude-specific convenience functions
-export([
    cancel/2,
    rewind_files/2,
    stop_task/2,
    set_max_thinking_tokens/2,
    mcp_server_status/1,
    set_mcp_servers/2,
    reconnect_mcp_server/2,
    toggle_mcp_server/3
]).

%%====================================================================
%% beam_agent_behaviour callbacks
%%====================================================================

-spec start_link(beam_agent_core:session_opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Opts) ->
    beam_agent_session_engine:start_link(claude_session_handler, Opts).

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
%% Claude-specific convenience functions
%%====================================================================

-spec cancel(pid(), reference()) -> ok.
cancel(Pid, Ref) ->
    gen_statem:call(Pid, {cancel, Ref}, 5_000).

-spec rewind_files(pid(), binary()) -> {ok, term()} | {error, term()}.
rewind_files(Pid, CheckpointUuid) ->
    send_control(Pid, <<"rewind_files">>,
                 #{<<"checkpoint_uuid">> => CheckpointUuid}).

-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Pid, TaskId) ->
    send_control(Pid, <<"stop_task">>, #{<<"task_id">> => TaskId}).

-spec set_max_thinking_tokens(pid(), pos_integer()) ->
    {ok, term()} | {error, term()}.
set_max_thinking_tokens(Pid, MaxTokens)
  when is_integer(MaxTokens), MaxTokens > 0 ->
    send_control(Pid, <<"set_max_thinking_tokens">>,
                 #{<<"maxThinkingTokens">> => MaxTokens}).

-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Pid) ->
    send_control(Pid, <<"mcp_status">>, #{}).

-spec set_mcp_servers(pid(), map()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Pid, Servers) when is_map(Servers) ->
    send_control(Pid, <<"mcp_set_servers">>, #{<<"servers">> => Servers}).

-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Pid, ServerName) when is_binary(ServerName) ->
    send_control(Pid, <<"mcp_reconnect">>,
                 #{<<"serverName">> => ServerName}).

-spec toggle_mcp_server(pid(), binary(), boolean()) ->
    {ok, term()} | {error, term()}.
toggle_mcp_server(Pid, ServerName, Enabled)
  when is_binary(ServerName), is_boolean(Enabled) ->
    send_control(Pid, <<"mcp_toggle">>,
                 #{<<"serverName">> => ServerName,
                   <<"enabled">> => Enabled}).
