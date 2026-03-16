-module(beam_agent_transport_utils).
-moduledoc false.

-export([close_client/3, is_ready/1, status/1, ensure_list/1]).

-spec close_client(pid(), reference(), module()) -> ok.
close_client(ConnPid, MonRef, ClientMod) ->
    erlang:demonitor(MonRef, [flush]),
    catch ClientMod:close(ConnPid),
    ok.

-spec is_ready(pid()) -> boolean().
is_ready(ConnPid) ->
    erlang:is_process_alive(ConnPid).

-spec status(pid()) -> running | {exited, 0}.
status(ConnPid) ->
    case erlang:is_process_alive(ConnPid) of
        true  -> running;
        false -> {exited, 0}
    end.

-spec ensure_list(binary() | string()) -> string().
ensure_list(B) when is_binary(B) -> binary_to_list(B);
ensure_list(L) when is_list(L) -> L.
