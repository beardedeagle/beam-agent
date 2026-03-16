%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport_utils TLS option merging.
%%%-------------------------------------------------------------------
-module(beam_agent_transport_utils_tests).

-include_lib("eunit/include/eunit.hrl").

tls_client_opts_merges_defaults_by_key_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test",
        [{depth, 8}, {cacerts, [<<"custom-ca">>]}],
        false),
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(8, proplists:get_value(depth, Opts)),
    ?assertEqual([<<"custom-ca">>], proplists:get_value(cacerts, Opts)),
    ?assertEqual("example.test", proplists:get_value(server_name_indication, Opts)).

tls_client_opts_rejects_verify_none_by_default_test() ->
    ?assertEqual({error, unsafe_tls_opts},
        beam_agent_transport_utils:tls_client_opts(
            "example.test",
            [{verify, verify_none}],
            false)).

tls_client_opts_allows_verify_none_when_explicitly_enabled_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test",
        [{verify, verify_none}],
        true),
    ?assertEqual(verify_none, proplists:get_value(verify, Opts)).
