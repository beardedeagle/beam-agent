%%%-------------------------------------------------------------------
%%% @doc PropEr property-based tests for opencode_http.
%%%
%%% Fuzz-tests the pure HTTP helper functions with random inputs
%%% to verify robustness. Focuses on URL parsing, path building,
%%% and header generation.
%%%
%%% Properties (200 test cases each):
%%%   1. parse_base_url/1 never crashes on any binary input
%%%   2. parse_base_url/1 always returns valid {Host, Port, BasePath}
%%%   3. build_path/2 concatenates correctly
%%%   4. auth_headers/1 returns list for any valid input
%%%   5. common_headers always includes content-type and accept
%%%   6. Scheme defaults: no scheme → port 80, https → port 443
%%% @end
%%%-------------------------------------------------------------------
-module(prop_opencode_http).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit integration
%%====================================================================

parse_url_never_crashes_test() ->
    ?assert(proper:quickcheck(prop_parse_url_never_crashes(),
        [{numtests, 200}, {to_file, user}])).

parse_url_valid_tuple_test() ->
    ?assert(proper:quickcheck(prop_parse_url_valid_tuple(),
        [{numtests, 200}, {to_file, user}])).

build_path_concatenates_test() ->
    ?assert(proper:quickcheck(prop_build_path_concatenates(),
        [{numtests, 200}, {to_file, user}])).

auth_headers_returns_list_test() ->
    ?assert(proper:quickcheck(prop_auth_headers_returns_list(),
        [{numtests, 200}, {to_file, user}])).

common_headers_required_fields_test() ->
    ?assert(proper:quickcheck(prop_common_headers_required_fields(),
        [{numtests, 200}, {to_file, user}])).

scheme_defaults_test() ->
    ?assert(proper:quickcheck(prop_scheme_defaults(),
        [{numtests, 200}, {to_file, user}])).

%%====================================================================
%% Properties
%%====================================================================

%% Property 1: parse_base_url/1 never crashes on any binary
prop_parse_url_never_crashes() ->
    ?FORALL(Url, gen_url_binary(),
        begin
            Result = opencode_http:parse_base_url(Url),
            is_tuple(Result) andalso tuple_size(Result) =:= 3
        end).

%% Property 2: parse_base_url/1 always returns {binary, integer, binary}
prop_parse_url_valid_tuple() ->
    ?FORALL(Url, gen_url_binary(),
        begin
            {Host, Port, BasePath} = opencode_http:parse_base_url(Url),
            is_binary(Host) andalso
            is_integer(Port) andalso Port > 0 andalso
            is_binary(BasePath)
        end).

%% Property 3: build_path/2 produces binary starting with base
prop_build_path_concatenates() ->
    ?FORALL({Base, Endpoint}, {gen_path_segment(), gen_path_segment()},
        begin
            Result = opencode_http:build_path(Base, Endpoint),
            is_binary(Result) andalso
            byte_size(Result) =:= byte_size(Base) + byte_size(Endpoint)
        end).

%% Property 4: auth_headers/1 always returns a list
prop_auth_headers_returns_list() ->
    ?FORALL(Auth, gen_auth(),
        is_list(opencode_http:auth_headers(Auth))).

%% Property 5: common_headers always includes content-type and accept
prop_common_headers_required_fields() ->
    ?FORALL({Auth, Dir}, {gen_auth(), binary()},
        begin
            Headers = opencode_http:common_headers(Auth, Dir),
            is_list(Headers) andalso
            lists:keymember(<<"content-type">>, 1, Headers) andalso
            lists:keymember(<<"accept">>, 1, Headers) andalso
            lists:keymember(<<"x-opencode-directory">>, 1, Headers)
        end).

%% Property 6: Scheme defaults — no scheme or http → 80, https → 443
prop_scheme_defaults() ->
    ?FORALL(Host, gen_hostname(),
        begin
            {_, Port80, _} = opencode_http:parse_base_url(
                <<"http://", Host/binary>>),
            {_, Port443, _} = opencode_http:parse_base_url(
                <<"https://", Host/binary>>),
            {_, PortDefault, _} = opencode_http:parse_base_url(Host),
            Port80 =:= 80 andalso
            Port443 =:= 443 andalso
            PortDefault =:= 80
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_url_binary() ->
    oneof([
        %% Well-formed URLs
        ?LET({Scheme, Host, Port, Path},
            {oneof([<<"http://">>, <<"https://">>, <<>>]),
             gen_hostname(),
             oneof([<<>>, <<":">>, ?LET(P, range(1, 65535),
                                         iolist_to_binary([":", integer_to_list(P)]))]),
             oneof([<<>>, <<"/api">>, <<"/v1/endpoint">>])},
            <<Scheme/binary, Host/binary, Port/binary, Path/binary>>),
        %% Random binary (adversarial)
        binary()
    ]).

gen_hostname() ->
    oneof([
        <<"localhost">>,
        <<"127.0.0.1">>,
        <<"api.example.com">>,
        <<"host">>
    ]).

gen_path_segment() ->
    oneof([
        <<>>,
        <<"/session">>,
        <<"/api/v1">>,
        ?LET(S, binary(), <<"/", S/binary>>)
    ]).

gen_auth() ->
    oneof([
        none,
        {basic, base64:encode(<<"user:pass">>)}
    ]).
