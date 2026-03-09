-module(opencode_client_contract_tests).

-include_lib("eunit/include/eunit.hrl").

thread_filter_and_compact_wrappers_test() ->
    reset_state(),
    Session = fake_session(<<"opencode-thread">>, opencode),
    {ok, Thread} = opencode_client:thread_start(Session, #{name => <<"ops">>}),
    ThreadId = maps:get(thread_id, Thread),
    ok = beam_agent_threads_core:record_thread_message(<<"opencode-thread">>, ThreadId, #{
        type => text,
        content => <<"one">>,
        session_id => <<"opencode-thread">>
    }),
    {ok, #{threads := Threads, count := 1}} =
        opencode_client:thread_loaded_list(Session, #{thread_id => ThreadId}),
    ?assertEqual(1, length(Threads)),
    {ok, Compacted} = opencode_client:thread_compact(Session, #{thread_id => ThreadId, count => 1}),
    ?assertEqual(true, maps:get(compacted, Compacted)),
    cleanup_session(Session),
    reset_state().

config_and_realtime_wrappers_test() ->
    reset_state(),
    Session = fake_session(<<"opencode-config">>, opencode),
    {ok, _} = opencode_client:config_value_write(Session, <<"runtime.provider_id">>, <<"openai">>),
    {ok, Detect} = opencode_client:external_agent_config_detect(Session),
    ?assertEqual(true, maps:get(detected, Detect)),
    {ok, Review} = opencode_client:review_start(Session, #{}),
    ?assertEqual(opencode, maps:get(backend, Review)),
    {ok, Realtime} = opencode_client:thread_realtime_start(Session, #{transport => mediated}),
    ?assertEqual(opencode, maps:get(backend, Realtime)),
    ?assertEqual({error, not_found},
        opencode_client:command_write_stdin(Session, <<"proc-1">>, <<"input">>)),
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
