-module(beam_agent_config_tests).

-include_lib("eunit/include/eunit.hrl").

config_requirements_include_provider_catalog_test() ->
    Session = beam_agent_test_helpers:fake_session(<<"config-req-session">>, gemini),
    {ok, Requirements} = beam_agent_config_core:config_requirements_read(Session),
    Providers = maps:get(providers, Requirements),
    ?assert(lists:any(fun(#{id := <<"openai">>}) -> true; (_) -> false end, Providers)),
    ?assert(lists:any(fun(#{id := <<"google">>}) -> true; (_) -> false end, Providers)),
    ?assertEqual([runtime, control, session], maps:get(config_sources, Requirements)),
    ok = beam_agent_test_helpers:cleanup_session(Session).

provider_auth_methods_follow_current_provider_test() ->
    ok = beam_agent_runtime_core:clear(),
    Session = beam_agent_test_helpers:fake_session(<<"config-auth-session">>, gemini),
    ok = beam_agent_runtime_core:set_provider(Session, <<"google">>),
    {ok, Methods} = beam_agent_config_core:provider_auth_methods(Session),
    ?assert(lists:any(fun
        (#{kind := <<"api_key">>, provider_id := <<"google">>, current := true}) -> true;
        (_) -> false
    end, Methods)),
    ?assert(lists:any(fun
        (#{kind := <<"oauth_callback">>, provider_id := <<"google">>, current := true}) -> true;
        (_) -> false
    end, Methods)),
    ok = beam_agent_test_helpers:cleanup_session(Session),
    ok = beam_agent_runtime_core:clear().

provider_oauth_authorize_includes_provider_metadata_test() ->
    ok = beam_agent_control_core:clear(),
    Session = beam_agent_test_helpers:fake_session(<<"config-oauth-session">>, gemini),
    {ok, Pending} = beam_agent_config_core:provider_oauth_authorize(Session, <<"openai">>, #{
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
    ok = beam_agent_test_helpers:cleanup_session(Session),
    ok = beam_agent_control_core:clear().
