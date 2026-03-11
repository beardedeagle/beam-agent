-module(test_mcp_http_client).
-moduledoc """
Test fixture for MCP HTTP transport tests.

Implements the `beam_agent_http_client` API surface used by
`beam_agent_mcp_transport_http`: `open/3`, `close/1`, `post/4`, `delete/3`.

Instead of real TCP connections, spawns a dummy process that the transport
can monitor. All outgoing HTTP requests are relayed to the test owner process
as tagged messages so the test can assert on them and simulate responses.

## Message formats

  - `{http_request, post,   Path, Headers, Body, StreamRef}`
  - `{http_request, delete, Path, Headers, StreamRef}`

## Usage

```erlang
test_mcp_http_client:setup(),
{ok, Ref} = beam_agent_mcp_transport_http:start(#{
    client_module => test_mcp_http_client,
    host          => <<"localhost">>,
    port          => 4096,
    path          => <<"/mcp">>
}),
ConnPid = test_mcp_http_client:conn_pid(),
%% Simulate transport_up
ConnPid ! {transport_up, ConnPid, http},
%% Drive a send and assert on the emitted request
ok = beam_agent_mcp_transport_http:send(Ref, #{<<"method">> => <<"ping">>}),
receive
    {http_request, post, <<"/mcp">>, _Headers, _Body, _Ref} -> ok
end,
test_mcp_http_client:teardown().
```
""".

%% Client API compatibility
-export([open/3, close/1, post/4, delete/3]).

%% Test API
-export([setup/0, teardown/0, conn_pid/0, set_owner/0, set_owner/1]).

%%====================================================================
%% Test API
%%====================================================================

-doc "Initialise the test fixture. Must be called before starting a transport.".
-spec setup() -> ok.
setup() ->
    catch ets:delete(test_mcp_http_client_state),
    _ = ets:new(test_mcp_http_client_state, [named_table, public, set]),
    ets:insert(test_mcp_http_client_state, {owner, self()}),
    ok.

-doc "Re-register the calling process as the request receiver.".
-spec set_owner() -> ok.
set_owner() ->
    set_owner(self()).

-doc "Register the given pid as the request receiver.".
-spec set_owner(pid()) -> ok.
set_owner(Pid) ->
    ets:insert(test_mcp_http_client_state, {owner, Pid}),
    ok.

-doc "Clean up the test fixture. Call in test teardown.".
-spec teardown() -> ok.
teardown() ->
    case ets:whereis(test_mcp_http_client_state) of
        undefined ->
            ok;
        _ ->
            case ets:lookup(test_mcp_http_client_state, conn_pid) of
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
            ets:delete(test_mcp_http_client_state)
    end,
    ok.

-doc "Return the ConnPid created during open/3.".
-spec conn_pid() -> pid().
conn_pid() ->
    case ets:lookup(test_mcp_http_client_state, conn_pid) of
        [{conn_pid, Pid}] -> Pid;
        []                -> error(test_mcp_http_client_not_started)
    end.

%%====================================================================
%% Client API
%%====================================================================

-doc "Spawn a dummy connection process (replaces beam_agent_http_client:open/3).".
-spec open(string(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(_Host, _Port, _Opts) ->
    ConnPid = spawn_link(fun conn_loop/0),
    ets:insert(test_mcp_http_client_state, {conn_pid, ConnPid}),
    {ok, ConnPid}.

-doc "Kill the dummy connection process (replaces close/1).".
-spec close(pid()) -> ok.
close(ConnPid) ->
    unlink(ConnPid),
    exit(ConnPid, shutdown),
    ok.

-doc """
Simulate POST — relays `{http_request, post, Path, Headers, Body, StreamRef}`
to the owner process.
""".
-spec post(pid(), iodata(), [{binary(), binary()}], iodata()) -> reference().
post(_ConnPid, Path, Headers, Body) ->
    Ref = make_ref(),
    notify_owner({http_request, post,
                  iolist_to_binary(Path), Headers,
                  iolist_to_binary(Body), Ref}),
    Ref.

-doc """
Simulate DELETE — relays `{http_request, delete, Path, Headers, StreamRef}`
to the owner process.
""".
-spec delete(pid(), iodata(), [{binary(), binary()}]) -> reference().
delete(_ConnPid, Path, Headers) ->
    Ref = make_ref(),
    notify_owner({http_request, delete, iolist_to_binary(Path), Headers, Ref}),
    Ref.

%%====================================================================
%% Internal
%%====================================================================

-spec notify_owner(term()) -> ok.
notify_owner(Msg) ->
    case ets:lookup(test_mcp_http_client_state, owner) of
        [{owner, Owner}] -> Owner ! Msg;
        _                -> ok
    end,
    ok.

-spec conn_loop() -> no_return().
conn_loop() ->
    receive _ -> conn_loop() end.
