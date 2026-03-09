-module(beam_agent_fallback_tests).

-include_lib("eunit/include/eunit.hrl").

event_stream_fallback_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-session">>, gemini),
    {ok, Ref} = beam_agent:event_subscribe(Session),
    ok = beam_agent_session_store_core:record_message(<<"fallback-session">>, #{
        type => text,
        session_id => <<"fallback-session">>,
        content => <<"hello">>
    }),
    ?assertEqual({ok, #{
        type => text,
        session_id => <<"fallback-session">>,
        content => <<"hello">>
    }}, beam_agent:receive_event(Session, Ref, 0)),
    ?assertEqual(ok, beam_agent:event_unsubscribe(Session, Ref)),
    cleanup_session(Session).

universal_review_and_config_fallbacks_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-review">>, gemini),
    {ok, Review} = beam_agent:review_start(Session, #{
        target => <<"pull-request">>,
        stage => <<"triage">>,
        participants => [
            #{id => <<"author">>, role => <<"author">>, presence => online}
        ],
        issues => [#{id => <<"issue-1">>, title => <<"Verify fallback">>}]
    }),
    ?assertEqual(universal, maps:get(source, Review)),
    ?assertEqual(gemini, maps:get(backend, Review)),
    ?assertEqual(<<"pull-request">>, maps:get(target, Review)),
    ?assertEqual(<<"triage">>, maps:get(stage, Review)),
    ?assertEqual(1, length(maps:get(participants, Review))),
    {ok, Modes} = beam_agent:collaboration_mode_list(Session),
    ?assertEqual(universal, maps:get(source, Modes)),
    [ReviewMode] = [Mode || #{id := <<"review">>} = Mode <- maps:get(modes, Modes)],
    ?assertMatch(#{stages := [_ | _]}, ReviewMode),
    {ok, _Config} = beam_agent:config_update(Session, #{
        provider_id => <<"openai">>,
        provider => #{id => <<"openai">>, api_key => <<"secret">>},
        control => #{permission_mode => <<"acceptEdits">>}
    }),
    {ok, Config} = beam_agent:config_read(Session),
    Runtime = maps:get(runtime, Config),
    Control = maps:get(control, Config),
    ?assertEqual(<<"openai">>, maps:get(provider_id, Runtime)),
    ?assertEqual(<<"acceptEdits">>, maps:get(permission_mode, Control)),
    {ok, Methods} = beam_agent:provider_auth_methods(Session),
    ?assert(length(Methods) >= 1),
    cleanup_session(Session).

universal_realtime_fallback_records_thread_history_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-realtime">>, gemini),
    {ok, Realtime} = beam_agent:thread_realtime_start(Session, #{
        mode => <<"voice">>,
        transport => mediated
    }),
    ThreadId = maps:get(thread_id, Realtime),
    ?assertEqual(universal, maps:get(source, Realtime)),
    ?assertEqual(gemini, maps:get(backend, Realtime)),
    ?assertEqual(mediated, maps:get(transport, Realtime)),
    ?assertMatch([#{type := <<"realtime_started">>}], maps:get(output_events, Realtime)),
    {ok, Features} = beam_agent:experimental_feature_list(Session),
    ?assertEqual(universal, maps:get(source, Features)),
    {ok, TextSession} = beam_agent:thread_realtime_append_text(Session, ThreadId, #{
        text => <<"hello realtime">>
    }),
    ?assertEqual(<<"hello realtime">>, maps:get(last_text, TextSession)),
    ?assertEqual(1, length(maps:get(inputs, TextSession))),
    {ok, AudioSession} = beam_agent:thread_realtime_append_audio(Session, ThreadId, #{
        mime => <<"audio/wav">>,
        path => <<"/tmp/realtime.wav">>,
        size => 12
    }),
    AudioMeta = maps:get(last_audio, AudioSession),
    ?assertEqual(<<"audio/wav">>, maps:get(mime, AudioMeta)),
    ?assertEqual(2, length(maps:get(inputs, AudioSession))),
    {ok, #{messages := Messages}} =
        beam_agent:thread_read(Session, ThreadId, #{include_messages => true}),
    Subtypes = [maps:get(subtype, Message) || Message <- Messages],
    ?assert(lists:member(<<"thread_realtime_started">>, Subtypes)),
    ?assert(lists:member(<<"thread_realtime_text_appended">>, Subtypes)),
    ?assert(lists:member(<<"thread_realtime_audio_appended">>, Subtypes)),
    {ok, Stopped} = beam_agent:thread_realtime_stop(Session, ThreadId),
    ?assertEqual(stopped, maps:get(status, Stopped)),
    cleanup_session(Session).

universal_review_and_realtime_cover_non_native_backends_test() ->
    lists:foreach(fun(Backend) ->
        reset_universal_state(),
        SessionId = <<"fallback-", (atom_to_binary(Backend, utf8))/binary>>,
        Session = fake_session(SessionId, Backend),
        {ok, Review} = beam_agent:review_start(Session, #{}),
        ?assertEqual(Backend, maps:get(backend, Review)),
        {ok, Realtime} = beam_agent:thread_realtime_start(Session, #{}),
        ThreadId = maps:get(thread_id, Realtime),
        ?assertEqual(Backend, maps:get(backend, Realtime)),
        {ok, Updated} = beam_agent:thread_realtime_append_text(Session, ThreadId, #{
            text => <<"backend coverage">>
        }),
        ?assertEqual(1, length(maps:get(inputs, Updated))),
        cleanup_session(Session)
    end, [opencode, copilot]).

universal_provider_oauth_and_config_workflow_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-provider">>, gemini),
    ?assertEqual({error, not_set}, beam_agent:current_provider(Session)),
    {ok, Ref} = beam_agent:event_subscribe(Session),
    {ok, Pending} = beam_agent:provider_oauth_authorize(Session, <<"openai">>, #{
        authorize_url => <<"https://example.test/oauth">>
    }),
    RequestId = maps:get(request_id, Pending),
    ?assertMatch({ok, #{
        subtype := <<"pending_request_stored">>,
        request_id := RequestId
    }}, beam_agent:receive_event(Session, Ref, 0)),
    {ok, Callback} = beam_agent:provider_oauth_callback(Session, <<"openai">>, #{
        request_id => RequestId,
        code => <<"authorized">>
    }),
    ?assertEqual(configured, maps:get(status, Callback)),
    ?assertMatch({ok, #{
        subtype := <<"pending_request_resolved">>,
        request_id := RequestId
    }}, beam_agent:receive_event(Session, Ref, 0)),
    ?assertEqual({ok, <<"openai">>}, beam_agent:current_provider(Session)),
    {ok, Providers} = beam_agent:provider_list(Session),
    ?assert(lists:any(fun
        (#{id := <<"openai">>}) -> true;
        (_) -> false
    end, Providers)),
    {ok, Config} = beam_agent:config_read(Session),
    Runtime = maps:get(runtime, Config),
    Provider = maps:get(provider, Runtime),
    OAuthCallback = maps:get(oauth_callback, Provider),
    ?assertEqual(<<"openai">>, maps:get(provider_id, Runtime)),
    ?assertEqual(<<"authorized">>, maps:get(code, OAuthCallback)),
    ?assertEqual(ok, beam_agent:event_unsubscribe(Session, Ref)),
    cleanup_session(Session).

universal_config_import_and_key_write_fallbacks_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-import">>, gemini),
    {ok, Detect0} = beam_agent:external_agent_config_detect(Session),
    ?assertEqual(false, maps:get(detected, Detect0)),
    {ok, Requirements} = beam_agent:config_requirements_read(Session),
    Writable = maps:get(writable_key_paths, Requirements),
    ?assert(lists:member(<<"runtime.provider_id">>, Writable)),
    {ok, _} = beam_agent:config_value_write(Session, <<"runtime.provider_id">>, <<"openai">>),
    {ok, _} = beam_agent:config_batch_write(Session, [
        #{key_path => <<"control.permission_mode">>, value => <<"acceptEdits">>},
        #{key_path => <<"control.max_thinking_tokens">>, value => 42}
    ]),
    {ok, _Imported} = beam_agent:external_agent_config_import(Session, #{
        config => #{
            runtime => #{agent => <<"planner">>},
            control => #{permission_mode => <<"bypassPermissions">>}
        }
    }),
    {ok, Detect1} = beam_agent:external_agent_config_detect(Session),
    ?assertEqual(true, maps:get(detected, Detect1)),
    ?assertEqual(universal, maps:get(source, Detect1)),
    {ok, Config} = beam_agent:config_read(Session),
    Runtime = maps:get(runtime, Config),
    Control = maps:get(control, Config),
    ?assertEqual(<<"openai">>, maps:get(provider_id, Runtime)),
    ?assertEqual(<<"planner">>, maps:get(agent, Runtime)),
    ?assertEqual(<<"bypassPermissions">>, maps:get(permission_mode, Control)),
    ?assertEqual(42, maps:get(max_thinking_tokens, Control)),
    cleanup_session(Session).

universal_thread_admin_native_leak_fallbacks_test() ->
    reset_universal_state(),
    SessionId = <<"fallback-thread-admin">>,
    Session = fake_session(SessionId, gemini),
    {ok, Thread} = beam_agent:thread_start(Session, #{name => <<"draft">>}),
    ThreadId = maps:get(thread_id, Thread),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, #{
        type => text,
        session_id => SessionId,
        thread_id => ThreadId,
        content => <<"first">>
    }),
    ok = beam_agent_threads_core:record_thread_message(SessionId, ThreadId, #{
        type => text,
        session_id => SessionId,
        thread_id => ThreadId,
        content => <<"second">>
    }),
    {ok, Renamed} = beam_agent:thread_name_set(Session, ThreadId, <<"renamed">>),
    ?assertEqual(universal, maps:get(source, Renamed)),
    ?assertEqual(<<"renamed">>, maps:get(name, maps:get(thread, Renamed))),
    {ok, MetadataUpdated} =
        beam_agent:thread_metadata_update(Session, ThreadId, #{topic => <<"parity">>}),
    Metadata = maps:get(metadata, maps:get(thread, MetadataUpdated)),
    ?assertEqual(<<"parity">>, maps:get(topic, Metadata)),
    {ok, Loaded} = beam_agent:thread_loaded_list(Session),
    ?assertEqual(universal, maps:get(source, Loaded)),
    ?assertEqual(ThreadId, maps:get(active_thread_id, Loaded)),
    [LoadedThread] = maps:get(threads, Loaded),
    ?assertEqual(<<"renamed">>, maps:get(name, LoadedThread)),
    {ok, Compacted} =
        beam_agent:thread_compact(Session, #{thread_id => ThreadId, count => 1}),
    CompactedThread = maps:get(thread, Compacted),
    ?assertEqual(1, maps:get(visible_message_count, CompactedThread)),
    {ok, Unsubscribed} = beam_agent:thread_unsubscribe(Session, ThreadId),
    ?assertEqual(true, maps:get(unsubscribed, Unsubscribed)),
    ?assertEqual(undefined, maps:get(active_thread_id, Unsubscribed)),
    ?assertEqual({ok, #{
        thread_id => ThreadId,
        turn_id => <<"turn-1">>,
        status => interrupted,
        source => universal,
        backend => gemini
    }}, beam_agent:turn_interrupt(Session, ThreadId, <<"turn-1">>)),
    cleanup_session(Session).

universal_status_and_session_admin_native_leak_fallbacks_test() ->
    reset_universal_state(),
    SessionId = <<"fallback-status">>,
    Session = fake_session(SessionId, gemini, #{
        system_info => #{
            skills => [#{id => <<"skill-a">>, name => <<"Skill A">>}]
        }
    }),
    {ok, Skills} = beam_agent:skills_remote_list(Session),
    ?assertEqual(universal, maps:get(source, Skills)),
    ?assertEqual(1, maps:get(count, Skills)),
    [Skill] = maps:get(skills, Skills),
    ?assertEqual(<<"skill-a">>, maps:get(id, Skill)),
    {ok, Status} = beam_agent:get_status(Session),
    ?assertEqual(universal, maps:get(source, Status)),
    ?assertEqual(SessionId, maps:get(session_id, Status)),
    ?assertEqual(ready, maps:get(health, Status)),
    {ok, AuthStatus} = beam_agent:get_auth_status(Session),
    ?assertEqual(universal, maps:get(source, AuthStatus)),
    ?assertEqual(undefined, maps:get(provider_id, AuthStatus)),
    ?assertEqual({ok, SessionId}, beam_agent:get_last_session_id(Session)),
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => gemini
    }),
    ?assertMatch({ok, #{
        session_id := SessionId,
        destroyed := true,
        source := universal,
        backend := gemini
    }}, beam_agent:session_destroy(Session)),
    ?assertEqual({error, not_found}, beam_agent:get_session(SessionId)),
    cleanup_session(Session).

universal_command_and_turn_response_fallbacks_test() ->
    reset_universal_state(),
    SessionId = <<"fallback-command">>,
    Session = fake_session(SessionId, gemini),
    {ok, RunResult} = beam_agent:command_run(Session, [<<"printf">>, <<"beam-agent">>]),
    ?assertEqual(0, maps:get(exit_code, RunResult)),
    ?assertEqual(<<"beam-agent">>, maps:get(output, RunResult)),
    ?assertEqual(universal, maps:get(source, RunResult)),
    FeedbackResult = beam_agent:submit_feedback(Session, #{rating => good}),
    ?assert(FeedbackResult =:= ok orelse
        (is_tuple(FeedbackResult) andalso tuple_size(FeedbackResult) >= 1
            andalso element(1, FeedbackResult) =:= ok)),
    {ok, [Feedback]} = beam_agent_control_core:get_feedback(SessionId),
    ?assertEqual(good, maps:get(rating, Feedback)),
    RequestId = <<"request-1">>,
    ok = beam_agent_control:store_pending_request(SessionId, RequestId, #{
        kind => <<"question">>
    }),
    Responded = beam_agent:turn_respond(Session, RequestId, #{answer => <<"approved">>}),
    ?assert(Responded =:= ok orelse
        (is_tuple(Responded) andalso tuple_size(Responded) >= 1
            andalso element(1, Responded) =:= ok)),
    PendingResponse = beam_agent_control:get_pending_response(SessionId, RequestId),
    ?assert(lists:member(PendingResponse, [
        {ok, #{answer => <<"approved">>}},
        {ok, #{
            response => #{answer => <<"approved">>},
            source => universal
        }}
    ])),
    cleanup_session(Session).

universal_async_prompt_and_shell_command_fallbacks_test() ->
    reset_universal_state(),
    Session = fake_session(<<"fallback-ux">>, gemini),
    {ok, PromptResult} = beam_agent:prompt_async(Session, <<"hello async">>),
    ?assertEqual(true, maps:get(accepted, PromptResult)),
    ?assertEqual(universal, maps:get(source, PromptResult)),
    ?assertEqual(gemini, maps:get(backend, PromptResult)),
    ?assert(is_reference(maps:get(query_ref, PromptResult))),
    {ok, ShellResult} = beam_agent:shell_command(Session, <<"printf beam-agent-shell">>),
    ?assertEqual(0, maps:get(exit_code, ShellResult)),
    ?assertEqual(<<"beam-agent-shell">>, maps:get(output, ShellResult)),
    ?assertEqual(universal, maps:get(source, ShellResult)),
    ?assertEqual(gemini, maps:get(backend, ShellResult)),
    cleanup_session(Session).

fake_session(SessionId, Backend) ->
    fake_session(SessionId, Backend, #{}).

fake_session(SessionId, Backend, InfoExtra) ->
    Session = spawn(fun() -> fake_session_loop(SessionId, Backend, InfoExtra) end),
    {ok, Backend} = beam_agent_backend:register_session(Session, Backend),
    Session.

fake_session_loop(SessionId, Backend, InfoExtra) ->
    SessionInfo = maps:merge(#{
        session_id => SessionId,
        backend => Backend,
        adapter => Backend
    }, InfoExtra),
    receive
        {'$gen_call', From, session_info} ->
            gen:reply(From, {ok, SessionInfo}),
            fake_session_loop(SessionId, Backend, InfoExtra);
        {'$gen_call', From, health} ->
            gen:reply(From, ready),
            fake_session_loop(SessionId, Backend, InfoExtra);
        {'$gen_call', From, interrupt} ->
            gen:reply(From, ok),
            fake_session_loop(SessionId, Backend, InfoExtra);
        {'$gen_call', From, {send_query, _Prompt, _Params}} ->
            gen:reply(From, {ok, make_ref()}),
            fake_session_loop(SessionId, Backend, InfoExtra);
        stop ->
            ok;
        _Other ->
            fake_session_loop(SessionId, Backend, InfoExtra)
    end.

cleanup_session(Session) ->
    ok = beam_agent_backend:unregister_session(Session),
    Session ! stop.

reset_universal_state() ->
    ok = beam_agent_runtime_core:clear(),
    ok = beam_agent_control_core:clear(),
    ok = beam_agent_events:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_collaboration:clear().
