%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport_utils TLS option merging.
%%%-------------------------------------------------------------------
-module(beam_agent_transport_tls_merge_tests).

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

default_tls_opts_includes_versions_key_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test", [], false),
    ?assertNotEqual(undefined, proplists:get_value(versions, Opts)).

default_tls_opts_version_is_tls13_only_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test", [], false),
    ?assertEqual(['tlsv1.3'], proplists:get_value(versions, Opts)).

tls_client_opts_allows_tls12_opt_in_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test",
        [{versions, ['tlsv1.2', 'tlsv1.3']}],
        false),
    ?assertEqual(lists:sort(['tlsv1.2', 'tlsv1.3']),
                 lists:sort(proplists:get_value(versions, Opts))).

tls_client_opts_rejects_legacy_version_test() ->
    ?assertEqual({error, unsafe_tls_opts},
        beam_agent_transport_utils:tls_client_opts(
            "example.test",
            [{versions, ['tlsv1']}],
            false)).

tls_client_opts_allows_safe_version_override_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test",
        [{versions, ['tlsv1.2', 'tlsv1.3']}],
        false),
    ?assertEqual(['tlsv1.2', 'tlsv1.3'], proplists:get_value(versions, Opts)).

tls_client_opts_custom_versions_override_default_test() ->
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.test",
        [{versions, ['tlsv1.3']}],
        false),
    ?assertEqual(['tlsv1.3'], proplists:get_value(versions, Opts)).
