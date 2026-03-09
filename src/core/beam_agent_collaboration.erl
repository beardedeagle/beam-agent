-module(beam_agent_collaboration).
-moduledoc """
Universal review, collaboration, and realtime state for the canonical SDK.

The native Codex surface remains the richest implementation. This module
provides backend-agnostic fallbacks so the canonical API stays available for
every supported backend.
""".

-export([
    ensure_tables/0,
    clear/0,
    start_review/2,
    collaboration_modes/1,
    experimental_features/2,
    start_realtime/2,
    append_realtime_text/3,
    append_realtime_audio/3,
    stop_realtime/2
]).

-dialyzer({no_underspecs,
           [{start_review, 2},
            {collaboration_modes, 1},
            {start_realtime, 2},
            {append_realtime_text, 3},
            {append_realtime_audio, 3},
            {stop_realtime, 2},
            {record_thread_event, 4},
            {event_content, 2},
            {ensure_thread, 3},
            {request_id, 2},
            {value, 3},
            {normalize_participants, 2},
            {normalize_participant, 2},
            {normalize_review_items, 3},
            {normalize_review_item, 3},
            {append_output_event, 2},
            {stage_event, 3},
            {review_metrics, 4},
            {increment_input_summary, 2},
            {ensure_ets, 2}]}).

-define(REVIEWS_TABLE, beam_agent_review_sessions).
-define(REALTIME_TABLE, beam_agent_realtime_sessions).

-type review_session() :: #{
    review_id := binary(),
    session_id := binary(),
    thread_id := binary(),
    backend => term(),
    mode := term(),
    source := term(),
    target := term(),
    stage := term(),
    status := active,
    participants := [map()],
    comments := [map()],
    issues := [map()],
    resolutions := [map()],
    stage_history := [map()],
    review_metrics := map(),
    created_at := integer(),
    updated_at := integer(),
    params := map()
}.
-type audio_meta() :: #{
    mime := term(),
    path := term(),
    size := term()
}.
-type realtime_session() :: #{
    realtime_id := binary(),
    session_id := binary(),
    thread_id := binary(),
    backend => term(),
    transport := term(),
    mode := term(),
    status := active | stopped,
    source := universal,
    started_at := integer(),
    params := map(),
    transport_metadata := map(),
    inputs := [map()],
    event_count := non_neg_integer(),
    output_events := [map()],
    input_summary := map(),
    voice_enabled := boolean(),
    last_text => binary(),
    last_audio => audio_meta(),
    updated_at => integer(),
    stopped_at => integer()
}.

-doc "Ensure collaboration ETS tables exist.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    ensure_ets(?REVIEWS_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_ets(?REALTIME_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear all universal collaboration state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    ets:delete_all_objects(?REVIEWS_TABLE),
    ets:delete_all_objects(?REALTIME_TABLE),
    ok.

-doc "Start a universal review session for the canonical API.".
-spec start_review(binary(), map()) -> {ok, review_session()}.
start_review(SessionId, Params)
  when is_binary(SessionId), is_map(Params) ->
    ensure_tables(),
    ThreadId = ensure_thread(SessionId, Params, <<"review">>),
    ReviewId = request_id(Params, [review_id, <<"review_id">>]),
    Mode = value(Params, [mode, <<"mode">>], <<"review">>),
    Backend = value(Params, [backend, <<"backend">>], undefined),
    Source = value(Params, [source, <<"source">>], universal),
    Target = value(Params, [target, <<"target">>], <<"canonical">>),
    Stage = value(Params, [stage, <<"stage">>, review_stage, <<"review_stage">>], <<"requested">>),
    Now = now_ms(),
    Participants = normalize_participants(value(Params, [participants, <<"participants">>], []), Now),
    Comments = normalize_review_items(comment, value(Params, [comments, <<"comments">>], []), Now),
    Issues = normalize_review_items(issue, value(Params, [issues, <<"issues">>], []), Now),
    Resolutions = normalize_review_items(resolution,
        value(Params, [resolutions, <<"resolutions">>], []), Now),
    StageHistory = [stage_event(Stage, Source, Now)],
    Review = #{
        review_id => ReviewId,
        session_id => SessionId,
        thread_id => ThreadId,
        backend => Backend,
        mode => Mode,
        source => Source,
        target => Target,
        stage => Stage,
        status => active,
        participants => Participants,
        comments => Comments,
        issues => Issues,
        resolutions => Resolutions,
        stage_history => StageHistory,
        review_metrics => review_metrics(Participants, Comments, Issues, Resolutions),
        created_at => Now,
        updated_at => Now,
        params => Params
    },
    ets:insert(?REVIEWS_TABLE, {{SessionId, ReviewId}, Review}),
    ok = record_thread_event(SessionId, ThreadId, <<"review_started">>, #{
        review_id => ReviewId,
        backend => Backend,
        mode => Mode,
        stage => Stage,
        review => review_projection(Review)
    }),
    {ok, Review}.

-doc "List canonical collaboration modes available through the universal layer.".
-spec collaboration_modes(binary()) ->
    {ok,
     #{session_id := binary(),
       source := universal,
       modes := [map(), ...]}}.
collaboration_modes(SessionId) when is_binary(SessionId) ->
    {ok, #{
        session_id => SessionId,
        source => universal,
        modes => [
            #{id => <<"solo">>,
              label => <<"Solo">>,
              source => universal,
              capabilities => [thread_management]},
            #{id => <<"review">>,
              label => <<"Review">>,
              source => universal,
              stages => [<<"requested">>, <<"active">>, <<"resolved">>],
              capabilities => [review_start, collaboration_mode_list]},
            #{id => <<"realtime">>,
              label => <<"Realtime">>,
              source => universal,
              transports => [universal, mediated],
              capabilities => [thread_realtime_start, thread_realtime_append_text,
                               thread_realtime_append_audio, thread_realtime_stop]}
        ]
    }}.

-doc "List universal experimental features visible through the canonical API.".
-spec experimental_features(binary(), map()) -> {ok, map()}.
experimental_features(SessionId, _Opts) when is_binary(SessionId) ->
    {ok, #{
        session_id => SessionId,
        source => universal,
        features => [
            #{id => <<"universal_review">>, status => enabled},
            #{id => <<"universal_realtime_text">>, status => enabled},
            #{id => <<"universal_realtime_audio_bridge">>, status => enabled}
        ]
    }}.

-doc "Start a universal realtime session for a thread.".
-spec start_realtime(binary(), map()) -> {ok, realtime_session()}.
start_realtime(SessionId, Params)
  when is_binary(SessionId), is_map(Params) ->
    ensure_tables(),
    ThreadId = ensure_thread(SessionId, Params, <<"realtime">>),
    RealtimeId = request_id(Params, [realtime_id, <<"realtime_id">>]),
    Mode = value(Params, [mode, <<"mode">>], <<"text">>),
    Backend = value(Params, [backend, <<"backend">>], undefined),
    Transport = value(Params, [transport, <<"transport">>], universal),
    Now = now_ms(),
    TransportMetadata = transport_metadata(Params),
    Session = #{
        realtime_id => RealtimeId,
        session_id => SessionId,
        thread_id => ThreadId,
        backend => Backend,
        transport => Transport,
        mode => Mode,
        status => active,
        source => universal,
        started_at => Now,
        updated_at => Now,
        params => Params,
        transport_metadata => TransportMetadata,
        inputs => [],
        event_count => 1,
        input_summary => #{text_chunks => 0, audio_chunks => 0},
        voice_enabled => voice_enabled(Mode),
        output_events => [
            #{type => <<"realtime_started">>,
              timestamp => Now,
              transport => Transport,
              sequence => 1,
              metadata => TransportMetadata}
        ]
    },
    ets:insert(?REALTIME_TABLE, {{SessionId, ThreadId}, Session}),
    ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_started">>, #{
        realtime_id => RealtimeId,
        backend => Backend,
        transport => Transport,
        mode => Mode
    }),
    {ok, Session}.

-doc "Append canonical realtime text to a universal realtime thread.".
-spec append_realtime_text(binary(), binary(), map()) ->
    {ok, realtime_session()} | {error, not_found}.
append_realtime_text(SessionId, ThreadId, Params)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Params) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            Text = value(Params, [text, <<"text">>, content, <<"content">>], <<>>),
            Now = now_ms(),
            Input = #{
                type => text,
                payload => #{text => Text},
                sequence => next_sequence(Session),
                timestamp => Now
            },
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_text_appended">>, #{
                content => Text
            }),
            EventCount = next_event_count(Session),
            Updated = Session#{
                last_text => Text,
                updated_at => Now,
                inputs => append_item(maps:get(inputs, Session, []), Input),
                event_count => EventCount,
                input_summary => increment_input_summary(text, maps:get(input_summary, Session, #{})),
                output_events => append_output_event(Session, #{
                    type => <<"realtime_text_appended">>,
                    payload => #{text => Text},
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            ets:insert(?REALTIME_TABLE, {{SessionId, ThreadId}, Updated}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Append canonical realtime audio metadata to a universal realtime thread.".
-spec append_realtime_audio(binary(), binary(), map()) ->
    {ok, realtime_session()} | {error, not_found}.
append_realtime_audio(SessionId, ThreadId, Params)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Params) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            AudioMeta = #{
                mime => value(Params, [mime, <<"mime">>], undefined),
                path => value(Params, [path, <<"path">>], undefined),
                size => value(Params, [size, <<"size">>], undefined)
            },
            Now = now_ms(),
            Input = #{
                type => audio,
                payload => AudioMeta,
                sequence => next_sequence(Session),
                timestamp => Now
            },
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_audio_appended">>, #{
                audio => AudioMeta
            }),
            EventCount = next_event_count(Session),
            Updated = Session#{
                last_audio => AudioMeta,
                updated_at => Now,
                inputs => append_item(maps:get(inputs, Session, []), Input),
                event_count => EventCount,
                input_summary => increment_input_summary(audio, maps:get(input_summary, Session, #{})),
                output_events => append_output_event(Session, #{
                    type => <<"realtime_audio_appended">>,
                    payload => AudioMeta,
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            ets:insert(?REALTIME_TABLE, {{SessionId, ThreadId}, Updated}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Stop a universal realtime thread.".
-spec stop_realtime(binary(), binary()) ->
    {ok, realtime_session()} | {error, not_found}.
stop_realtime(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    case lookup_realtime(SessionId, ThreadId) of
        {ok, Session} ->
            Now = now_ms(),
            EventCount = next_event_count(Session),
            Updated = Session#{
                status => stopped,
                stopped_at => Now,
                updated_at => Now,
                event_count => EventCount,
                output_events => append_output_event(Session, #{
                    type => <<"realtime_stopped">>,
                    timestamp => Now,
                    sequence => EventCount
                })
            },
            ets:insert(?REALTIME_TABLE, {{SessionId, ThreadId}, Updated}),
            ok = record_thread_event(SessionId, ThreadId, <<"thread_realtime_stopped">>, #{}),
            {ok, Updated};
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec ensure_thread(binary(), map(), binary()) -> binary().
ensure_thread(SessionId, Params, DefaultName) ->
    case value(Params, [thread_id, <<"thread_id">>, <<"threadId">>], undefined) of
        ThreadId when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
            ThreadId;
        _ ->
            case beam_agent_threads_core:active_thread(SessionId) of
                {ok, ThreadId} ->
                    ThreadId;
                {error, none} ->
                    {ok, Thread} = beam_agent_threads_core:start_thread(SessionId, #{
                        name => DefaultName
                    }),
                    maps:get(thread_id, Thread)
            end
    end.

-spec lookup_realtime(binary(), binary()) -> {ok, map()} | {error, not_found}.
lookup_realtime(SessionId, ThreadId) ->
    ensure_tables(),
    case ets:lookup(?REALTIME_TABLE, {SessionId, ThreadId}) of
        [{{SessionId, ThreadId}, Session}] ->
            {ok, Session};
        [] ->
            {error, not_found}
    end.

-spec record_thread_event(binary(), binary(), binary(), map()) -> ok.
record_thread_event(SessionId, ThreadId, Subtype, Extra) ->
    Message = #{
        type => system,
        content => event_content(Subtype, Extra),
        session_id => SessionId,
        thread_id => ThreadId,
        subtype => Subtype,
        system_info => maps:merge(Extra, #{source => universal}),
        timestamp => now_ms()
    },
    beam_agent_threads_core:record_thread_message(SessionId, ThreadId, Message).

-spec event_content(binary(), map()) -> binary().
event_content(_Subtype, #{content := Content}) when is_binary(Content) ->
    Content;
event_content(Subtype, _Extra) ->
    Subtype.

-spec request_id(map(), [term()]) -> binary().
request_id(Params, Keys) ->
    case value(Params, Keys, undefined) of
        Existing when is_binary(Existing), byte_size(Existing) > 0 ->
            Existing;
        _ ->
            beam_agent_core:make_request_id()
    end.

-spec value(map(), [term()], term()) -> term().
value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            value(Map, Rest, Default)
    end;
value(_Map, [], Default) ->
    Default.

-spec normalize_items(term()) -> [map()].
normalize_items(Items) when is_list(Items) ->
    [normalize_item(Item) || Item <- Items];
normalize_items(_) ->
    [].

-spec normalize_participants(term(), integer()) -> [map()].
normalize_participants(Items, Now) ->
    [normalize_participant(Item, Now) || Item <- normalize_items(Items)].

-spec normalize_participant(map(), integer()) -> map().
normalize_participant(Item, Now) ->
    Item#{
        joined_at => maps:get(joined_at, Item, Now),
        presence => maps:get(presence, Item, online)
    }.

-spec normalize_review_items(atom(), term(), integer()) -> [map()].
normalize_review_items(Kind, Items, Now) ->
    [normalize_review_item(Kind, Item, Now) || Item <- normalize_items(Items)].

-spec normalize_review_item(atom(), map(), integer()) -> map().
normalize_review_item(Kind, Item, Now) ->
    Item#{
        kind => maps:get(kind, Item, Kind),
        created_at => maps:get(created_at, Item, Now)
    }.

-spec normalize_item(term()) -> map().
normalize_item(Item) when is_map(Item) ->
    Item;
normalize_item(Item) ->
    #{value => Item}.

review_projection(Review) ->
    maps:with([review_id, backend, source, target, stage, participants,
               stage_history, review_metrics], Review).

-spec append_item([map()], map()) -> [map()].
append_item(Items, Item) when is_list(Items), is_map(Item) ->
    Items ++ [Item].

-spec next_sequence(realtime_session()) -> pos_integer().
next_sequence(Session) ->
    length(maps:get(inputs, Session, [])) + 1.

-spec next_event_count(realtime_session()) -> pos_integer().
next_event_count(Session) ->
    maps:get(event_count, Session, length(maps:get(output_events, Session, []))) + 1.

-spec append_output_event(realtime_session(), map()) -> [map()].
append_output_event(Session, Event) ->
    append_item(maps:get(output_events, Session, []), Event).

-spec stage_event(term(), term(), integer()) -> map().
stage_event(Stage, Source, Timestamp) ->
    #{stage => Stage, source => Source, timestamp => Timestamp}.

-spec review_metrics([map()], [map()], [map()], [map()]) -> map().
review_metrics(Participants, Comments, Issues, Resolutions) ->
    #{
        participant_count => length(Participants),
        comment_count => length(Comments),
        issue_count => length(Issues),
        resolution_count => length(Resolutions)
    }.

-spec transport_metadata(map()) -> map().
transport_metadata(Params) ->
    maps:merge(
        maps:with([codec, sample_rate, sample_rate_hz, channels, language], Params),
        normalize_map(value(Params, [transport_metadata, <<"transport_metadata">>], #{}))).

-spec voice_enabled(term()) -> boolean().
voice_enabled(<<"voice">>) ->
    true;
voice_enabled(voice) ->
    true;
voice_enabled(_) ->
    false.

-spec increment_input_summary(text | audio, map()) -> map().
increment_input_summary(text, Summary) ->
    Summary#{
        text_chunks => maps:get(text_chunks, Summary, 0) + 1,
        audio_chunks => maps:get(audio_chunks, Summary, 0)
    };
increment_input_summary(audio, Summary) ->
    Summary#{
        text_chunks => maps:get(text_chunks, Summary, 0),
        audio_chunks => maps:get(audio_chunks, Summary, 0) + 1
    }.

-spec normalize_map(term()) -> map().
normalize_map(Map) when is_map(Map) ->
    Map;
normalize_map(_) ->
    #{}.

-spec now_ms() -> integer().
now_ms() ->
    erlang:system_time(millisecond).

-spec ensure_ets(atom(), [term()]) -> ok.
ensure_ets(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.
