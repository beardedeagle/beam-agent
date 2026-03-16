%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_runtime_core.
%%%-------------------------------------------------------------------
-module(beam_agent_runtime_core_tests).

-include_lib("eunit/include/eunit.hrl").

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
