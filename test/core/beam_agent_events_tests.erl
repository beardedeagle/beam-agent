-module(beam_agent_events_tests).

-include_lib("eunit/include/eunit.hrl").

subscribe_publish_receive_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"events-session">>),
    ok = beam_agent_events:publish(<<"events-session">>, #{type => system, subtype => <<"tick">>}),
    ?assertEqual({ok, #{type => system, subtype => <<"tick">>}},
        beam_agent_events:receive_event(Ref, 0)),
    ?assertEqual(ok, beam_agent_events:unsubscribe(<<"events-session">>, Ref)),
    ok = beam_agent_events:clear().

complete_stream_test() ->
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(<<"events-complete">>),
    ok = beam_agent_events:complete(<<"events-complete">>),
    ?assertEqual({error, complete}, beam_agent_events:receive_event(Ref, 0)),
    ok = beam_agent_events:clear().
