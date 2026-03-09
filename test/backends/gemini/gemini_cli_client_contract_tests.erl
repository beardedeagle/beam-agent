-module(gemini_cli_client_contract_tests).

-include_lib("eunit/include/eunit.hrl").

thread_resume_with_opts_reads_messages_test() ->
    reset_state(),
    Session = fake_session(<<"gemini-thread">>, gemini),
    {ok, Thread} = gemini_cli_client:thread_start(Session, #{name => <<"review">>}),
    ThreadId = maps:get(thread_id, Thread),
    ok = beam_agent_threads_core:record_thread_message(<<"gemini-thread">>, ThreadId, #{
        type => text,
        content => <<"hello">>,
        session_id => <<"gemini-thread">>
    }),
    {ok, #{messages := Messages}} =
        gemini_cli_client:thread_resume(Session, ThreadId, #{include_messages => true}),
    ?assertEqual(1, length(Messages)),
    cleanup_session(Session),
    reset_state().

config_provider_and_collaboration_wrappers_test() ->
    reset_state(),
    Session = fake_session(<<"gemini-config">>, gemini),
    {ok, _} = gemini_cli_client:config_update(Session, #{
        provider_id => <<"google">>,
        provider => #{provider_id => <<"google">>, api_key => <<"secret">>}
    }),
    {ok, Config} = gemini_cli_client:config_read(Session),
    Runtime = maps:get(runtime, Config),
    ?assertEqual(<<"google">>, maps:get(provider_id, Runtime)),
    {ok, Providers} = gemini_cli_client:provider_list(Session),
    ?assert(lists:any(fun(#{id := <<"google">>}) -> true; (_) -> false end, Providers)),
    {ok, Methods} = gemini_cli_client:provider_auth_methods(Session),
    ?assert(lists:any(fun(#{provider_id := <<"google">>}) -> true; (_) -> false end, Methods)),
    {ok, Review} = gemini_cli_client:review_start(Session, #{target => <<"pr">>}),
    ?assertEqual(gemini, maps:get(backend, Review)),
    {ok, Realtime} = gemini_cli_client:thread_realtime_start(Session, #{}),
    ?assertEqual(gemini, maps:get(backend, Realtime)),
    ?assertEqual({error, not_found},
        gemini_cli_client:command_write_stdin(Session, <<"proc-1">>, <<"input">>)),
    cleanup_session(Session),
    reset_state().

fake_session(SessionId, Backend) ->
    Session = spawn(fun() -> fake_session_loop(SessionId, Backend) end),
    {ok, Backend} = beam_agent_backend:register_session(Session, Backend),
    Session.

fake_session_loop(SessionId, Backend) ->
    receive
        {'$gen_call', From, session_info} ->
            gen:reply(From, {ok, #{
                session_id => SessionId,
                backend => Backend,
                adapter => Backend
            }}),
            fake_session_loop(SessionId, Backend);
        stop ->
            ok;
        _Other ->
            fake_session_loop(SessionId, Backend)
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
