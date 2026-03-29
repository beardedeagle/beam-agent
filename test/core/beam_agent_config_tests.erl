-module(beam_agent_config_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_credential_key_test() ->
    _ = beam_agent_test_setup:ensure_test_key().

config_requirements_include_provider_catalog_test() ->
    SessionId = <<"config-req-session">>,
    {ok, Requirements} = beam_agent_config:config_requirements_read(SessionId),
    Providers = maps:get(providers, Requirements),
    ?assert(lists:any(fun(#{id := <<"openai">>}) -> true; (_) -> false end, Providers)),
    ?assert(lists:any(fun(#{id := <<"google">>}) -> true; (_) -> false end, Providers)),
    ?assertEqual([runtime, control, session], maps:get(config_sources, Requirements)).

provider_auth_methods_follow_current_provider_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"config-auth-session">>,
    ok = beam_agent_runtime_core:set_provider(SessionId, <<"google">>),
    {ok, Methods} = beam_agent_config:provider_auth_methods(SessionId),
    ?assert(lists:any(fun
        (#{kind := <<"api_key">>, provider_id := <<"google">>, current := true}) -> true;
        (_) -> false
    end, Methods)),
    ?assert(lists:any(fun
        (#{kind := <<"oauth_callback">>, provider_id := <<"google">>, current := true}) -> true;
        (_) -> false
    end, Methods)),
    ok = beam_agent_runtime_core:clear().

provider_oauth_authorize_includes_provider_metadata_test() ->
    ok = beam_agent_control_core:clear(),
    SessionId = <<"config-oauth-session">>,
    {ok, Pending} = beam_agent_config:provider_oauth_authorize(SessionId, <<"openai">>, #{
        authorize_url => <<"https://example.test/oauth">>
    }),
    ?assertEqual(<<"oauth_callback">>, maps:get(auth_method, Pending)),
    Provider = maps:get(provider, Pending),
    ?assertEqual(<<"openai">>, maps:get(id, Provider)),
    {ok, Requests} = beam_agent_control_core:list_pending_requests(<<"config-oauth-session">>),
    [Stored] = Requests,
    StoredRequest = maps:get(request, Stored),
    ?assertEqual(<<"beam_agent.control.request.v1">>, maps:get(schema_version, StoredRequest)),
    ?assertEqual(<<"oauth_callback">>, maps:get(auth_method, StoredRequest)),
    ok = beam_agent_control_core:clear().

provider_auth_methods_accept_session_identity_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"config-auth-id">>,
    ok = beam_agent_runtime_core:set_provider(SessionId, <<"google">>),
    {ok, Methods} = beam_agent_config:provider_auth_methods(SessionId),
    ?assert(lists:any(fun
        (#{kind := <<"api_key">>, provider_id := <<"google">>, current := true}) -> true;
        (_) -> false
    end, Methods)),
    ok = beam_agent_runtime_core:clear().

provider_oauth_callback_redacts_callback_payload_test() ->
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_control_core:clear(),
    SessionId = <<"config-oauth-callback">>,
    ok = beam_agent_runtime_core:set_provider_config(SessionId, #{
        provider_id => <<"openai">>,
        api_key => <<"secret-api-key">>
    }),
    {ok, Pending} = beam_agent_config:provider_oauth_authorize(SessionId, <<"openai">>, #{
        authorize_url => <<"https://example.test/oauth">>
    }),
    RequestId = maps:get(request_id, Pending),
    {ok, Callback} = beam_agent_config:provider_oauth_callback(SessionId, <<"openai">>, #{
        request_id => RequestId,
        code => <<"secret-code">>,
        access_token => <<"secret-token">>
    }),
    Provider = maps:get(provider, Callback),
    ?assertEqual(redacted, maps:get(api_key, Provider)),
    OAuthCallback = maps:get(oauth_callback, Provider),
    ?assertEqual(redacted, maps:get(code, OAuthCallback)),
    ?assertEqual(redacted, maps:get(access_token, OAuthCallback)),
    {ok, Config} = beam_agent_config:config_read(SessionId),
    Runtime = maps:get(runtime, Config),
    RuntimeProvider = maps:get(provider, Runtime),
    ?assertEqual(redacted, maps:get(api_key, RuntimeProvider)),
    RuntimeCallback = maps:get(oauth_callback, RuntimeProvider),
    ?assertEqual(redacted, maps:get(code, RuntimeCallback)),
    ?assertEqual(redacted, maps:get(access_token, RuntimeCallback)),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_runtime_core:clear().

external_agent_detect_redacts_provider_secrets_test() ->
    ok = beam_agent_runtime_core:clear(),
    SessionId = <<"config-detect-redaction">>,
    ok = beam_agent_runtime_core:set_provider_config(SessionId, #{
        provider_id => <<"openai">>,
        api_key => <<"secret-api-key">>
    }),
    {ok, Detect} = beam_agent_config:external_agent_config_detect(SessionId, #{}),
    SanitizedConfig = maps:get(config, Detect),
    Runtime = maps:get(runtime, SanitizedConfig),
    Provider = maps:get(provider, Runtime),
    ?assertEqual(redacted, maps:get(api_key, Provider)),
    ok = beam_agent_runtime_core:clear().
