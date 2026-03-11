-module(opencode_http).
-moduledoc false.
-export([parse_base_url/1,
         build_path/2,
         auth_headers/1,
         common_headers/2,
         encode_basic_auth/2]).
-dialyzer({no_underspecs, [{auth_headers, 1}, {split_scheme, 1}]}).
-spec parse_base_url(binary() | string()) ->
                        {binary(), inet:port_number(), binary()}.
parse_base_url(Url) when is_list(Url) ->
    parse_base_url(list_to_binary(Url));
parse_base_url(Url) when is_binary(Url) ->
    {Scheme, Rest0} = split_scheme(Url),
    DefaultPort =
        case Scheme of
            <<"https">> ->
                443;
            _ ->
                80
        end,
    {HostPort, Path} = split_host_path(Rest0),
    {Host, Port} = split_host_port(HostPort, DefaultPort),
    BasePath =
        case Path of
            <<>> ->
                <<>>;
            <<"/">> ->
                <<>>;
            P ->
                strip_trailing_slash(P)
        end,
    {Host, Port, BasePath}.
-spec build_path(binary(), iodata()) -> binary().
build_path(BasePath, Endpoint) ->
    iolist_to_binary([BasePath, Endpoint]).
-spec auth_headers(none | {basic, binary()}) -> [{binary(), binary()}].
auth_headers(none) ->
    [];
auth_headers({basic, Encoded}) ->
    [{<<"authorization">>, <<"Basic ",Encoded/binary>>}].
-spec common_headers(none | {basic, binary()}, binary()) ->
                        [{binary(), binary()}].
common_headers(Auth, Dir) ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json">>},
     {<<"x-opencode-directory">>, Dir} |
     auth_headers(Auth)].
-spec encode_basic_auth(binary(), binary()) -> {basic, binary()}.
encode_basic_auth(User, Pass) ->
    {basic, base64:encode(<<User/binary,":",Pass/binary>>)}.
-spec split_scheme(binary()) -> {binary(), binary()}.
split_scheme(<<"https://",Rest/binary>>) ->
    {<<"https">>, Rest};
split_scheme(<<"http://",Rest/binary>>) ->
    {<<"http">>, Rest};
split_scheme(Rest) ->
    {<<"http">>, Rest}.
-spec split_host_path(binary()) -> {binary(), binary()}.
split_host_path(HostAndPath) ->
    case binary:split(HostAndPath, <<"/">>) of
        [HostPort] ->
            {HostPort, <<>>};
        [HostPort | Parts] ->
            Path =
                iolist_to_binary([<<"/">> | lists:join(<<"/">>, Parts)]),
            {HostPort, Path}
    end.
-spec split_host_port(binary(), inet:port_number()) ->
                         {binary(), inet:port_number()}.
split_host_port(HostPort, DefaultPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host] ->
            {Host, DefaultPort};
        [Host, PortBin] ->
            Port =
                try binary_to_integer(PortBin) of
                    P when P >= 1, P =< 65535 -> P;
                    _ -> DefaultPort
                catch
                    _:_ ->
                        DefaultPort
                end,
            {Host, Port}
    end.
-spec strip_trailing_slash(binary()) -> binary().
strip_trailing_slash(<<>>) ->
    <<>>;
strip_trailing_slash(B) ->
    case binary:last(B) of
        $/ ->
            binary:part(B, 0, byte_size(B) - 1);
        _ ->
            B
    end.

