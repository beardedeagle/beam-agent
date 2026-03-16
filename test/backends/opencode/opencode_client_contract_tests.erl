-module(opencode_client_contract_tests).

-include_lib("eunit/include/eunit.hrl").

thread_filter_and_compact_wrappers_test() ->
    ok = beam_agent_test_helpers:reset_state(),
    Session = beam_agent_test_helpers:register_session(<<"opencode-thread">>, opencode),
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
    ok = beam_agent_test_helpers:cleanup_session(Session),
    ok = beam_agent_test_helpers:reset_state().

config_and_realtime_wrappers_test() ->
    ok = beam_agent_test_helpers:reset_state(),
    Session = beam_agent_test_helpers:register_session(<<"opencode-config">>, opencode),
    {ok, _} = opencode_client:config_value_write(Session, <<"runtime.provider_id">>, <<"openai">>),
    {ok, Detect} = opencode_client:external_agent_config_detect(Session),
    ?assertEqual(true, maps:get(detected, Detect)),
    {ok, Review} = opencode_client:review_start(Session, #{}),
    ?assertEqual(opencode, maps:get(backend, Review)),
    {ok, Realtime} = opencode_client:thread_realtime_start(Session, #{transport => mediated}),
    ?assertEqual(opencode, maps:get(backend, Realtime)),
    ?assertEqual({error, not_found},
        opencode_client:command_write_stdin(Session, <<"proc-1">>, <<"input">>)),
    ok = beam_agent_test_helpers:cleanup_session(Session),
    ok = beam_agent_test_helpers:reset_state().
