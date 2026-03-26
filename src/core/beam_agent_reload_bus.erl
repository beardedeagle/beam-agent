-module(beam_agent_reload_bus).
-moduledoc """
Reload notification bus for the BEAM Agent SDK.

Provides a lightweight, process-free mechanism for notifying live sessions
when global registrable components change (hooks, skills, MCP servers,
command policies). Sessions subscribe to the bus during init and receive
`{beam_agent_reload, Type, Version}` messages when changes occur.

The bus uses two ETS tables:
  - `beam_agent_reload_subscribers` — tracks subscriber pids
  - `beam_agent_reload_version` — monotonic version counter

No processes are spawned. Subscriber notifications are sent via
`erlang:send/2` from the caller of `notify/1`. Dead subscribers
are pruned during notification (checked via `erlang:is_process_alive/1`).

## Usage

```erlang
%% During application init (called once):
ok = beam_agent_reload_bus:ensure_tables().

%% In a session engine init:
ok = beam_agent_reload_bus:subscribe().

%% When a global component changes:
ok = beam_agent_reload_bus:notify(hooks).

%% Subscribers receive:
receive {beam_agent_reload, hooks, Version} -> ... end

%% On session termination:
ok = beam_agent_reload_bus:unsubscribe().
```

## Architecture

This module is a thin functional layer over ETS — no gen_server,
no supervision tree, no inter-process communication beyond the
notification messages themselves. Reads are zero-cost from any
process. Version increments use `beam_agent_ets:update_counter/3`
for atomic updates (proxied in hardened mode).
""".

-export([
    ensure_tables/0,
    subscribe/0,
    subscribe/1,
    unsubscribe/0,
    unsubscribe/1,
    notify/1,
    version/0
]).

-export_type([reload_type/0]).

-doc """
Type of component that was reloaded.

Active reload types:
- `hooks` — global hook registration/unregistration
- `skills` — global skill registration/unregistration/config changes
- `tools` — global MCP server registration/unregistration
- `plugins` — global plugin registration/unregistration
- `agents` — global agent type registration/unregistration
- `commands` — global slash command registration/unregistration
- `config` — global SDK configuration changes
- `routines` — scheduled task/routine job mutations

Reserved for future use: `policy`.
""".
-type reload_type() :: hooks | skills | tools | plugins | agents
                     | commands | config | routines | policy.

-define(SUBS_TABLE, beam_agent_reload_subscribers).
-define(VERSION_TABLE, beam_agent_reload_version).

%%--------------------------------------------------------------------
%% Table Management
%%--------------------------------------------------------------------

-doc """
Create the reload bus ETS tables. Idempotent.

Called from `beam_agent:init/0` during application startup.
Safe to call multiple times — subsequent calls are no-ops.
""".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SUBS_TABLE,
        [set, named_table, {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?VERSION_TABLE,
        [set, named_table, {read_concurrency, true}]),
    %% Seed the version counter if it doesn't exist yet.
    %% insert_new is atomic and returns false if key exists.
    %% Uses beam_agent_ets for hardened mode compatibility.
    case ets:whereis(?VERSION_TABLE) of
        undefined -> ok;
        _Tid ->
            _ = beam_agent_ets:insert_new(?VERSION_TABLE, {version, 0}),
            ok
    end.

%%--------------------------------------------------------------------
%% Subscription
%%--------------------------------------------------------------------

-doc "Subscribe the calling process to reload notifications.".
-spec subscribe() -> ok.
subscribe() -> subscribe(self()).

-doc """
Subscribe a process to reload notifications.

The process will receive `{beam_agent_reload, Type, Version}`
messages when global components change. Idempotent — subscribing
an already-subscribed pid is a no-op.
""".
-spec subscribe(pid()) -> ok.
subscribe(Pid) when is_pid(Pid) ->
    case ets:whereis(?SUBS_TABLE) of
        undefined -> ok;
        _Tid ->
            beam_agent_ets:insert(?SUBS_TABLE, {Pid}),
            ok
    end.

-doc "Unsubscribe the calling process from reload notifications.".
-spec unsubscribe() -> ok.
unsubscribe() -> unsubscribe(self()).

-doc """
Unsubscribe a process from reload notifications.

Idempotent — unsubscribing a pid that is not subscribed is a no-op.
""".
-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) when is_pid(Pid) ->
    case ets:whereis(?SUBS_TABLE) of
        undefined -> ok;
        _Tid ->
            beam_agent_ets:delete(?SUBS_TABLE, Pid),
            ok
    end.

%%--------------------------------------------------------------------
%% Notification
%%--------------------------------------------------------------------

-doc """
Notify all subscribers that a component type has changed.

Increments the version counter atomically and sends
`{beam_agent_reload, Type, NewVersion}` to every live subscriber.
Dead subscribers are pruned during iteration.

Returns `ok`. Safe to call even if tables do not exist yet.
""".
-spec notify(reload_type()) -> ok.
notify(Type) when is_atom(Type) ->
    case ets:whereis(?VERSION_TABLE) of
        undefined -> ok;
        _Tid ->
            Version = beam_agent_ets:update_counter(
                ?VERSION_TABLE, version, {2, 1}, {version, 0}),
            Msg = {beam_agent_reload, Type, Version},
            notify_subscribers(Msg)
    end.

%%--------------------------------------------------------------------
%% Version
%%--------------------------------------------------------------------

-doc """
Read the current reload version counter.

Returns 0 if tables have not been created yet.
The version is monotonically increasing and incremented
atomically on each `notify/1` call.
""".
-spec version() -> non_neg_integer().
version() ->
    case ets:whereis(?VERSION_TABLE) of
        undefined -> 0;
        _Tid ->
            case ets:lookup(?VERSION_TABLE, version) of
                [{version, V}] -> V;
                [] -> 0
            end
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec notify_subscribers({beam_agent_reload, reload_type(), pos_integer()}) -> ok.
notify_subscribers(Msg) ->
    case ets:whereis(?SUBS_TABLE) of
        undefined -> ok;
        _Tid ->
            Subscribers = ets:tab2list(?SUBS_TABLE),
            lists:foreach(fun({Pid}) ->
                case erlang:is_process_alive(Pid) of
                    true ->
                        _ = erlang:send(Pid, Msg, [noconnect]),
                        ok;
                    false ->
                        %% Prune dead subscriber
                        beam_agent_ets:delete(?SUBS_TABLE, Pid),
                        ok
                end
            end, Subscribers)
    end.
