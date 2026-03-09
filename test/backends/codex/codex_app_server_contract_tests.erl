-module(codex_app_server_contract_tests).

-include_lib("eunit/include/eunit.hrl").

provider_and_config_wrappers_test() ->
    reset_state(),
    Session = fake_session(<<"codex-config">>, codex),
    {ok, _} = codex_app_server:config_update(Session, #{
        provider_id => <<"openai">>,
        provider => #{provider_id => <<"openai">>, api_key => <<"secret">>}
    }),
    {ok, Providers} = codex_app_server:provider_list(Session),
    ?assert(lists:any(fun(#{id := <<"openai">>}) -> true; (_) -> false end, Providers)),
    {ok, ConfigProviders} = codex_app_server:config_providers(Session),
    ?assertEqual(Providers, ConfigProviders),
    {ok, Methods} = codex_app_server:provider_auth_methods(Session),
    ?assert(lists:any(fun(#{provider_id := <<"openai">>}) -> true; (_) -> false end, Methods)),
    {ok, Pending} =
        codex_app_server:provider_oauth_authorize(Session, <<"openai">>, #{
            authorize_url => <<"https://example.test/oauth">>
        }),
    ?assertEqual(<<"openai">>, maps:get(provider_id, Pending)),
    cleanup_session(Session),
    reset_state().

realtime_transport_bridges_review_and_collaboration_test() ->
    reset_state(),
    Session = fake_session(<<"codex-realtime">>, codex, #{transport => realtime}),
    {ok, Review} = codex_app_server:review_start(Session, #{
        target => <<"pull-request">>,
        stage => <<"triage">>
    }),
    ?assertEqual(universal, maps:get(source, Review)),
    ?assertEqual(codex, maps:get(backend, Review)),
    ?assertEqual(realtime, maps:get(transport, maps:get(params, Review))),
    {ok, Modes} = codex_app_server:collaboration_mode_list(Session),
    ?assertEqual(universal, maps:get(source, Modes)),
    ?assertEqual(codex, maps:get(backend, Modes)),
    ?assertEqual(realtime, maps:get(transport, Modes)),
    ?assert(lists:any(fun(#{id := <<"review">>}) -> true; (_) -> false end, maps:get(modes, Modes))),
    {ok, Features} = codex_app_server:experimental_feature_list(Session),
    ?assertEqual(universal, maps:get(source, Features)),
    ?assertEqual(codex, maps:get(backend, Features)),
    ?assertEqual(realtime, maps:get(transport, Features)),
    ?assert(lists:any(fun(#{id := <<"universal_review">>}) -> true; (_) -> false end,
                      maps:get(features, Features))),
    cleanup_session(Session),
    reset_state().

fake_session(SessionId, Backend) ->
    fake_session(SessionId, Backend, #{}).

fake_session(SessionId, Backend, ExtraInfo) ->
    Session = spawn(fun() -> fake_session_loop(SessionId, Backend, ExtraInfo) end),
    {ok, Backend} = beam_agent_backend:register_session(Session, Backend),
    Session.

fake_session_loop(SessionId, Backend, ExtraInfo) ->
    receive
        {'$gen_call', From, session_info} ->
            BaseInfo = #{
                session_id => SessionId,
                backend => Backend,
                adapter => Backend
            },
            gen:reply(From, {ok, maps:merge(BaseInfo, ExtraInfo)}),
            fake_session_loop(SessionId, Backend, ExtraInfo);
        stop ->
            ok;
        _Other ->
            fake_session_loop(SessionId, Backend, ExtraInfo)
    end.

cleanup_session(Session) ->
    ok = beam_agent_backend:unregister_session(Session),
    Session ! stop.

reset_state() ->
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_collaboration:clear(),
    ok = beam_agent_events:clear().
