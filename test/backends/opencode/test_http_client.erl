-module(test_http_client).
-moduledoc """
Test fixture for OpenCode HTTP transport tests.

Implements the `beam_agent_http_client` API surface used by
`beam_agent_transport_http` and `opencode_session_handler`:
`open/3`, `close/1`, `get/3`, `post/4`, `patch/4`, `delete/3`.

Instead of real TCP connections, spawns a dummy process that the
transport can monitor. All outgoing HTTP requests are relayed to the
test owner process as `{http_request, Method, Path, Ref}` or
`{http_request, Method, Path, Body, Ref}` messages so the test can
simulate responses.

## Usage

```erlang
test_http_client:setup(),
{ok, Pid} = opencode_session:start_link(#{
    client_module => test_http_client,
    directory     => <<"/tmp/test">>,
    base_url      => <<"http://localhost:4096">>
}),
ConnPid = test_http_client:conn_pid(),
%% Simulate transport_up
Pid ! {transport_up, ConnPid, http},
%% Receive SSE GET ref
receive {http_request, get, _Path, SseRef} -> ok end,
%% Simulate SSE response + data
Pid ! {http_response, ConnPid, SseRef, nofin, 200, []},
Pid ! {http_data, ConnPid, SseRef, nofin, SseBytes},
test_http_client:teardown().
```
""".

%% Client API compatibility
-export([open/3, close/1, get/3, post/4, patch/4, delete/3]).

%% Test API
-export([setup/0, teardown/0, conn_pid/0, set_owner/0, set_owner/1]).

%%====================================================================
%% Test API
%%====================================================================

-doc "Initialize the test fixture. Must be called before starting a session.".
-spec setup() -> ok.
setup() ->
    catch ets:delete(test_http_client_state),
    _ = ets:new(test_http_client_state, [named_table, public, set]),
    ets:insert(test_http_client_state, {owner, self()}),
    ok.

-doc "Re-register the calling process as the request receiver.".
-spec set_owner() -> ok.
set_owner() ->
    set_owner(self()).

-doc "Register the given pid as the request receiver.".
-spec set_owner(pid()) -> ok.
set_owner(Pid) ->
    ets:insert(test_http_client_state, {owner, Pid}),
    ok.

-doc "Clean up the test fixture. Call in test teardown.".
-spec teardown() -> ok.
teardown() ->
    case ets:whereis(test_http_client_state) of
        undefined -> ok;
        _ ->
            case ets:lookup(test_http_client_state, conn_pid) of
                [{conn_pid, Pid}] when is_pid(Pid) ->
                    MonRef = erlang:monitor(process, Pid),
                    unlink(Pid),
                    exit(Pid, shutdown),
                    receive
                        {'DOWN', MonRef, process, Pid, _} -> ok
                    after 1000 -> ok
                    end;
                _ ->
                    ok
            end,
            ets:delete(test_http_client_state)
    end,
    ok.

-doc "Return the ConnPid created during open/3.".
-spec conn_pid() -> pid().
conn_pid() ->
    case ets:lookup(test_http_client_state, conn_pid) of
        [{conn_pid, Pid}] -> Pid;
        [] -> error(test_http_client_not_started)
    end.

%%====================================================================
%% Client API
%%====================================================================

-doc "Spawn a dummy connection process (replaces beam_agent_http_client:open/3).".
-spec open(string(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(_Host, _Port, _Opts) ->
    ConnPid = spawn_link(fun conn_loop/0),
    ets:insert(test_http_client_state, {conn_pid, ConnPid}),
    {ok, ConnPid}.

-doc "Kill the dummy connection process (replaces close/1).".
-spec close(pid()) -> ok.
close(ConnPid) ->
    unlink(ConnPid),
    exit(ConnPid, shutdown),
    ok.

-doc "Simulate GET request — relays {http_request, get, Path, Ref} to owner.".
-spec get(pid(), string(), [{binary(), binary()}]) -> reference().
get(_ConnPid, Path, _Headers) ->
    Ref = make_ref(),
    notify_owner({http_request, get, iolist_to_binary(Path), Ref}),
    Ref.

-doc "Simulate POST request — relays {http_request, post, Path, Body, Ref} to owner.".
-spec post(pid(), string(), [{binary(), binary()}], iodata()) -> reference().
post(_ConnPid, Path, _Headers, Body) ->
    Ref = make_ref(),
    notify_owner({http_request, post, iolist_to_binary(Path), Body, Ref}),
    Ref.

-doc "Simulate PATCH request — relays {http_request, patch, Path, Body, Ref} to owner.".
-spec patch(pid(), string(), [{binary(), binary()}], iodata()) -> reference().
patch(_ConnPid, Path, _Headers, Body) ->
    Ref = make_ref(),
    notify_owner({http_request, patch, iolist_to_binary(Path), Body, Ref}),
    Ref.

-doc "Simulate DELETE request — relays {http_request, delete, Path, Ref} to owner.".
-spec delete(pid(), string(), [{binary(), binary()}]) -> reference().
delete(_ConnPid, Path, _Headers) ->
    Ref = make_ref(),
    notify_owner({http_request, delete, iolist_to_binary(Path), Ref}),
    Ref.

%%====================================================================
%% Internal
%%====================================================================

-spec notify_owner(term()) -> ok.
notify_owner(Msg) ->
    case ets:lookup(test_http_client_state, owner) of
        [{owner, Owner}] -> Owner ! Msg;
        _ -> ok
    end,
    ok.

-spec conn_loop() -> no_return().
conn_loop() ->
    receive _ -> conn_loop() end.
