-module(beam_agent_transport_utils).
-moduledoc false.

-export([close_client/3, is_ready/1, status/1, ensure_list/1,
         tls_client_opts/3]).

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

-spec tls_client_opts(string(), list(), boolean()) ->
    {ok, list()} | {error, unsafe_tls_opts}.
tls_client_opts(Host, Custom, AllowInsecure) ->
    DefaultTls = default_tls_opts(Host),
    Merged = lists:foldl(fun merge_tls_opt/2, DefaultTls, Custom),
    case AllowInsecure orelse not has_unsafe_tls_opt(Merged) of
        true ->
            case AllowInsecure of
                true ->
                    logger:warning(
                        "beam_agent_transport: TLS certificate verification "
                        "disabled for host '~s' — connections are vulnerable "
                        "to MITM attacks",
                        [Host]);
                false ->
                    ok
            end,
            {ok, [Opt || Opt <- Merged, not is_internal_tls_flag(Opt)]};
        false ->
            {error, unsafe_tls_opts}
    end.

-spec default_tls_opts(string()) -> list().
default_tls_opts(Host) ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 4},
     {server_name_indication, Host},
     {versions, ['tlsv1.2', 'tlsv1.3']}].

-spec merge_tls_opt(term(), list()) -> list().
merge_tls_opt(Opt, Acc) when is_tuple(Opt), tuple_size(Opt) >= 2 ->
    Key = element(1, Opt),
    [Opt | [Existing || Existing <- Acc,
                       not (is_tuple(Existing) andalso tuple_size(Existing) >= 2 andalso
                            element(1, Existing) =:= Key)]];
merge_tls_opt(Opt, Acc) ->
    [Opt | Acc].

-spec has_unsafe_tls_opt([term(), ...]) -> boolean().
has_unsafe_tls_opt(Opts) ->
    lists:any(fun
        ({verify, verify_none}) -> true;
        ({cacerts, []}) -> true;
        ({server_name_indication, disable}) -> true;
        ({versions, Versions}) ->
            lists:any(fun
                ('tlsv1.2') -> false;
                ('tlsv1.3') -> false;
                (_) -> true
            end, Versions);
        (_) -> false
    end, Opts).

-spec is_internal_tls_flag(term()) -> boolean().
is_internal_tls_flag({allow_insecure_tls, _}) -> true;
is_internal_tls_flag(_) -> false.
