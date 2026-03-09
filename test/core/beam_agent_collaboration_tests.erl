-module(beam_agent_collaboration_tests).

-include_lib("eunit/include/eunit.hrl").

start_review_populates_stage_history_and_metrics_test() ->
    reset_state(),
    {ok, Review} = beam_agent_collaboration:start_review(<<"review-session">>, #{
        backend => gemini,
        target => <<"pull-request">>,
        stage => <<"triage">>,
        participants => [#{id => <<"author">>, role => <<"author">>}],
        comments => [#{body => <<"Looks good">>}],
        issues => [#{id => <<"issue-1">>, title => <<"Check docs">>}],
        resolutions => [#{id => <<"resolution-1">>, summary => <<"Add docs">>}]
    }),
    ?assertEqual(<<"triage">>, maps:get(stage, Review)),
    [StageEvent] = maps:get(stage_history, Review),
    ?assertEqual(<<"triage">>, maps:get(stage, StageEvent)),
    ?assertEqual(universal, maps:get(source, StageEvent)),
    [Participant] = maps:get(participants, Review),
    ?assertEqual(online, maps:get(presence, Participant)),
    ?assert(is_integer(maps:get(joined_at, Participant))),
    Metrics = maps:get(review_metrics, Review),
    ?assertEqual(1, maps:get(participant_count, Metrics)),
    ?assertEqual(1, maps:get(comment_count, Metrics)),
    ?assertEqual(1, maps:get(issue_count, Metrics)),
    ?assertEqual(1, maps:get(resolution_count, Metrics)),
    reset_state().

realtime_tracks_transport_metadata_and_event_counts_test() ->
    reset_state(),
    {ok, Realtime0} = beam_agent_collaboration:start_realtime(<<"realtime-session">>, #{
        backend => gemini,
        mode => <<"voice">>,
        transport => mediated,
        codec => <<"pcm16">>,
        sample_rate => 16000
    }),
    ThreadId = maps:get(thread_id, Realtime0),
    ?assertEqual(true, maps:get(voice_enabled, Realtime0)),
    ?assertEqual(1, maps:get(event_count, Realtime0)),
    TransportMeta = maps:get(transport_metadata, Realtime0),
    ?assertEqual(<<"pcm16">>, maps:get(codec, TransportMeta)),
    ?assertEqual(16000, maps:get(sample_rate, TransportMeta)),
    {ok, Realtime1} =
        beam_agent_collaboration:append_realtime_text(<<"realtime-session">>, ThreadId, #{
            text => <<"hello realtime">>
        }),
    ?assertEqual(2, maps:get(event_count, Realtime1)),
    ?assertEqual(1, maps:get(text_chunks, maps:get(input_summary, Realtime1))),
    {ok, Realtime2} =
        beam_agent_collaboration:append_realtime_audio(<<"realtime-session">>, ThreadId, #{
            mime => <<"audio/wav">>,
            path => <<"/tmp/realtime.wav">>,
            size => 42
        }),
    ?assertEqual(3, maps:get(event_count, Realtime2)),
    ?assertEqual(1, maps:get(audio_chunks, maps:get(input_summary, Realtime2))),
    {ok, Realtime3} =
        beam_agent_collaboration:stop_realtime(<<"realtime-session">>, ThreadId),
    ?assertEqual(4, maps:get(event_count, Realtime3)),
    Sequences = [maps:get(sequence, Event) || Event <- maps:get(output_events, Realtime3)],
    ?assertEqual([1, 2, 3, 4], Sequences),
    reset_state().

reset_state() ->
    ok = beam_agent_collaboration:clear(),
    ok = beam_agent_threads_core:clear(),
    ok = beam_agent_session_store_core:clear(),
    ok = beam_agent_events:clear().
