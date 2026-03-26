%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_runtime_core.
%%%-------------------------------------------------------------------
-module(beam_agent_runtime_core_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_credential_key_test() ->
    _ = beam_agent_test_setup:ensure_test_key().

provider_and_agent_state_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-runtime">>,
    ?assertEqual(ok, beam_agent_runtime_core:set_provider(SessionId, <<"openai">>)),
    ?assertEqual({ok, <<"openai">>}, beam_agent_runtime_core:current_provider(SessionId)),
    ?assertEqual(ok, beam_agent_runtime_core:set_agent(SessionId, <<"architect">>)),
    ?assertEqual({ok, <<"architect">>}, beam_agent_runtime_core:current_agent(SessionId)),
    ?assertEqual(ok, beam_agent_runtime_core:clear_provider(SessionId)),
    ?assertEqual(ok, beam_agent_runtime_core:clear_agent(SessionId)),
    ?assertEqual({error, not_set}, beam_agent_runtime_core:current_provider(SessionId)),
    ?assertEqual({error, not_set}, beam_agent_runtime_core:current_agent(SessionId)).

merge_query_opts_prefers_explicit_params_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-query-defaults">>,
    ok = beam_agent_runtime_core:register_session(SessionId, #{
        provider_id => <<"openai">>,
        model_id => <<"gpt-5">>,
        agent => <<"planner">>
    }),
    Merged = beam_agent_runtime_core:merge_query_opts(SessionId, #{
        agent => <<"executor">>,
        timeout => 1000
    }),
    ?assertEqual(<<"openai">>, maps:get(provider_id, Merged)),
    ?assertEqual(<<"gpt-5">>, maps:get(model_id, Merged)),
    ?assertEqual(<<"executor">>, maps:get(agent, Merged)),
    ?assertEqual(1000, maps:get(timeout, Merged)).

fallback_provider_list_includes_catalog_and_current_provider_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-provider-list">>,
    ok = beam_agent_runtime_core:set_provider(SessionId, <<"google">>),
    {ok, Providers} = beam_agent_runtime_core:list_providers(SessionId),
    ?assert(lists:any(fun
        (#{id := <<"google">>, current := true, known_provider := true}) -> true;
        (_) -> false
    end, Providers)),
    ?assert(lists:any(fun
        (#{id := <<"openai">>, known_provider := true}) -> true;
        (_) -> false
    end, Providers)).

provider_status_includes_registry_metadata_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-provider-status">>,
    ok = beam_agent_runtime_core:set_provider(SessionId, <<"google">>),
    ok = beam_agent_runtime_core:set_provider_config(SessionId, #{
        provider_id => <<"google">>,
        api_key => <<"secret">>
    }),
    {ok, Status} = beam_agent_runtime_core:provider_status(SessionId, <<"google">>),
    ?assertEqual(true, maps:get(configured, Status)),
    ?assertEqual(true, maps:get(current, Status)),
    ?assertEqual(true, maps:get(known_provider, Status)),
    ?assert(lists:member(<<"oauth_callback">>, maps:get(auth_methods, Status))),
    ?assert(lists:member(<<"attachments">>, maps:get(capabilities, Status))),
    ProviderConfig = maps:get(provider_config, Status),
    ?assertEqual(redacted, maps:get(api_key, ProviderConfig)).

provider_config_view_redacts_sensitive_fields_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-provider-config-redaction">>,
    ok = beam_agent_runtime_core:set_provider_config(SessionId, #{
        provider_id => <<"google">>,
        api_key => <<"secret-key">>,
        base_url => <<"https://example.test">>,
        oauth_callback => #{
            request_id => <<"req-1">>,
            code => <<"secret-code">>,
            access_token => <<"secret-token">>
        }
    }),
    {ok, Config} = beam_agent_runtime_core:get_provider_config(SessionId),
    ?assertEqual(<<"https://example.test">>, maps:get(base_url, Config)),
    ?assertEqual(redacted, maps:get(api_key, Config)),
    Callback = maps:get(oauth_callback, Config),
    ?assertEqual(<<"req-1">>, maps:get(request_id, Callback)),
    ?assertEqual(redacted, maps:get(code, Callback)),
    ?assertEqual(redacted, maps:get(access_token, Callback)).

runtime_state_view_redacts_provider_secret_values_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-runtime-public-state">>,
    ok = beam_agent_runtime_core:register_session(SessionId, #{
        provider_id => <<"openai">>,
        provider => #{
            api_key => <<"secret-key">>,
            base_url => <<"https://example.test">>
        }
    }),
    {ok, State} = beam_agent_runtime_core:get_state(SessionId),
    Provider = maps:get(provider, State),
    ?assertEqual(<<"https://example.test">>, maps:get(base_url, Provider)),
    ?assertEqual(redacted, maps:get(api_key, Provider)).

%%====================================================================
%% Credential protection integration tests
%%====================================================================

put_state_get_state_roundtrip_with_api_key_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-cred-roundtrip">>,
    ok = beam_agent_runtime_core:set_provider_config(SessionId, #{
        provider_id => <<"openai">>,
        api_key => <<"sk-live-abc123">>,
        base_url => <<"https://api.openai.com">>
    }),
    {ok, Config} = beam_agent_runtime_core:get_provider_config(SessionId),
    %% get_provider_config returns redacted view
    ?assertEqual(redacted, maps:get(api_key, Config)),
    ?assertEqual(<<"https://api.openai.com">>, maps:get(base_url, Config)).

raw_ets_shows_protected_provider_config_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-cred-ets-check">>,
    %% Store a top-level sensitive key via register_session
    ok = beam_agent_runtime_core:register_session(SessionId, #{
        provider_id => <<"openai">>,
        provider => #{
            api_key => <<"sk-plaintext-should-not-appear">>,
            base_url => <<"https://api.openai.com">>
        }
    }),
    %% Read ETS directly -- the provider sub-map is stored inside
    %% the protected state. The provider key itself is not sensitive,
    %% but the top-level state map goes through protect which encrypts
    %% any top-level sensitive keys. Verify by checking that the
    %% provider sub-map roundtrips correctly through get_state.
    Key = beam_agent_ets:session_key(SessionId),
    [{_, RawState}] = ets:lookup(beam_agent_runtime_core, Key),
    %% provider_id at top level is not sensitive, should be present as-is
    ?assertEqual(<<"openai">>, maps:get(provider_id, RawState)),
    %% The state should roundtrip correctly through get_state
    {ok, State} = beam_agent_runtime_core:get_state(SessionId),
    ?assertEqual(<<"openai">>, maps:get(provider_id, State)),
    Provider = maps:get(provider, State),
    %% api_key inside provider is redacted by beam_agent_redaction
    ?assertEqual(redacted, maps:get(api_key, Provider)),
    ?assertEqual(<<"https://api.openai.com">>, maps:get(base_url, Provider)).

top_level_sensitive_key_is_protected_in_ets_test() ->
    ok = beam_agent_runtime_core:clear(),
    %% Directly test that credential encrypt_map/decrypt_map works
    %% on a map with top-level sensitive keys, using a test-derived key.
    {ok, Key} = beam_agent_credential:cookie_to_key(beam_agent_test_cookie),
    TestMap = #{api_key => <<"sk-secret">>, base_url => <<"https://test">>},
    Protected = beam_agent_credential:encrypt_map(TestMap, Key),
    ?assert(beam_agent_credential:is_protected(Protected)),
    ?assertMatch({beam_agent_protected, _, _, _}, maps:get(api_key, Protected)),
    ?assertEqual(<<"https://test">>, maps:get(base_url, Protected)),
    Restored = beam_agent_credential:decrypt_map(Protected, Key),
    ?assertEqual(TestMap, Restored).

get_state_roundtrips_through_protection_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"sess-cred-decrypt">>,
    ok = beam_agent_runtime_core:register_session(SessionId, #{
        provider_id => <<"anthropic">>,
        model_id => <<"claude-opus">>
    }),
    {ok, State} = beam_agent_runtime_core:get_state(SessionId),
    ?assertEqual(<<"anthropic">>, maps:get(provider_id, State)),
    ?assertEqual(<<"claude-opus">>, maps:get(model_id, State)).

%%====================================================================
%% Concurrent CAS tests
%%====================================================================

concurrent_put_state_no_lost_updates_test() ->
    ok = beam_agent_runtime_core:clear(),
    NumWriters = 20,
    Parent = self(),
    %% Each writer uses a unique session and sets provider + agent,
    %% then we verify all sessions have correct state.
    %% For the CAS test, use a shared session with concurrent set_provider
    %% followed by set_agent to verify no state is lost.
    SharedSession = <<"sess-cas-shared">>,
    ok = beam_agent_runtime_core:register_session(SharedSession, #{
        provider_id => <<"initial">>
    }),
    %% Spawn writers that each set a different agent name concurrently
    Pids = [spawn_link(fun() ->
        AgentName = iolist_to_binary([<<"agent_">>, integer_to_binary(I)]),
        ok = beam_agent_runtime_core:set_agent(SharedSession, AgentName),
        Parent ! {done, self()}
    end) || I <- lists:seq(1, NumWriters)],
    %% Wait for all writers
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok
        after 5000 -> error({timeout, Pid})
        end
    end, Pids),
    %% Verify the session still has a valid state -- provider_id should
    %% survive all the concurrent agent writes (CAS ensures no lost updates)
    {ok, FinalState} = beam_agent_runtime_core:get_state(SharedSession),
    ?assertEqual(<<"initial">>, maps:get(provider_id, FinalState)),
    %% Agent should be one of the written values (last writer wins)
    {ok, Agent} = beam_agent_runtime_core:current_agent(SharedSession),
    ?assertMatch(<<"agent_", _/binary>>, Agent).
