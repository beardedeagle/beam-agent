-module(test_gun).
-moduledoc """
Test fixture replacing `gun` for WebSocket transport tests.

Implements the gun API surface used by `beam_agent_transport_ws`:
`open/3`, `ws_upgrade/3`, `ws_send/3`, `close/1`.

Instead of real TCP/TLS connections, spawns a dummy process that the
transport can monitor. All outgoing WebSocket frames sent via `ws_send/3`
are relayed to the test owner process as `{ws_send, Frame}` messages.

## Usage

```erlang
test_gun:setup(),
{ok, Pid} = codex_realtime_session:start_link(#{
    gun_module => test_gun,
    api_key    => <<"test-key">>,
    ...
}),
ConnPid = test_gun:conn_pid(),
%% Simulate gun_up and gun_upgrade
Pid ! {gun_up, ConnPid, http},
Pid ! {gun_upgrade, ConnPid, make_ref(), [<<"websocket">>], []},
%% Assert on outgoing frames
receive {ws_send, {text, Json}} -> ... end,
test_gun:teardown().
```
""".

%% gun API compatibility
-export([open/3, ws_upgrade/3, ws_send/3, close/1]).

%% Test API
-export([setup/0, teardown/0, conn_pid/0, set_owner/0, set_owner/1]).

%%====================================================================
%% Test API
%%====================================================================

-doc "Initialize the test fixture. Must be called before starting a session.".
-spec setup() -> ok.
setup() ->
    catch ets:delete(test_gun_state),
    _ = ets:new(test_gun_state, [named_table, public, set]),
    ets:insert(test_gun_state, {owner, self()}),
    ok.

-doc "Re-register the calling process as the frame receiver.".
-spec set_owner() -> ok.
set_owner() ->
    set_owner(self()).

-doc "Register the given pid as the frame receiver.".
-spec set_owner(pid()) -> ok.
set_owner(Pid) ->
    ets:insert(test_gun_state, {owner, Pid}),
    ok.

-doc "Clean up the test fixture. Call in test teardown.".
-spec teardown() -> ok.
teardown() ->
    case ets:whereis(test_gun_state) of
        undefined -> ok;
        _ ->
            case ets:lookup(test_gun_state, conn_pid) of
                [{conn_pid, Pid}] when is_pid(Pid) ->
                    unlink(Pid),
                    exit(Pid, shutdown);
                _ ->
                    ok
            end,
            ets:delete(test_gun_state)
    end,
    ok.

-doc "Return the ConnPid created during open/3.".
-spec conn_pid() -> pid().
conn_pid() ->
    case ets:lookup(test_gun_state, conn_pid) of
        [{conn_pid, Pid}] -> Pid;
        [] -> error(test_gun_not_started)
    end.

%%====================================================================
%% gun API
%%====================================================================

-doc "Spawn a dummy connection process (replaces gun:open/3).".
-spec open(string(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(_Host, _Port, _Opts) ->
    ConnPid = spawn_link(fun conn_loop/0),
    ets:insert(test_gun_state, {conn_pid, ConnPid}),
    {ok, ConnPid}.

-doc "Return a fresh ref for the WebSocket stream (replaces gun:ws_upgrade/3).".
-spec ws_upgrade(pid(), string(), [{binary(), binary()}]) -> reference().
ws_upgrade(_ConnPid, _Path, _Headers) ->
    make_ref().

-doc "Relay frame to the test owner process (replaces gun:ws_send/3).".
-spec ws_send(pid(), reference(), {text, binary()}) -> ok.
ws_send(_ConnPid, _WsRef, Frame) ->
    case ets:lookup(test_gun_state, owner) of
        [{owner, Owner}] -> Owner ! {ws_send, Frame};
        _ -> ok
    end,
    ok.

-doc "Kill the dummy connection process (replaces gun:close/1).".
-spec close(pid()) -> ok.
close(ConnPid) ->
    unlink(ConnPid),
    exit(ConnPid, shutdown),
    ok.

%%====================================================================
%% Internal
%%====================================================================

-spec conn_loop() -> no_return().
conn_loop() ->
    receive _ -> conn_loop() end.
