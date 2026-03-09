-module(codex_realtime_protocol).
-moduledoc """
Protocol helpers for the direct Codex realtime/voice transport.

This module keeps wire-shape concerns out of `codex_realtime_session`.
""".

-export([
    default_model/0,
    build_ws_path/1,
    build_headers/2,
    session_update_messages/2,
    text_messages/1,
    audio_messages/2,
    interrupt_message/0,
    normalize_server_event/1,
    session_update_payload/2
]).

-dialyzer({no_underspecs,
           [{default_model, 0},
            {build_ws_path, 1},
            {session_update_messages, 2},
            {text_messages, 1},
            {audio_messages, 2},
            {interrupt_message, 0},
            {session_update_payload, 2},
            {maybe_put, 3}]}).

-doc "Return the default model used for direct realtime sessions.".
-spec default_model() -> binary().
default_model() ->
    <<"gpt-4o-realtime-preview">>.

-doc "Build the websocket request path for the realtime API.".
-spec build_ws_path(binary()) -> binary().
build_ws_path(Model) when is_binary(Model), byte_size(Model) > 0 ->
    <<"/v1/realtime?model=", Model/binary>>.

-doc "Build websocket upgrade headers for direct realtime sessions.".
-spec build_headers(binary(), map()) -> [{binary(), binary()}].
build_headers(ApiKey, ExtraHeaders) when is_binary(ApiKey), is_map(ExtraHeaders) ->
    Base = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"openai-beta">>, <<"realtime=v1">>},
        {<<"user-agent">>, <<"beam_agent/0.1.0">>}
    ],
    Base ++ maps:to_list(ExtraHeaders).

-doc "Build the initial session-update messages for a realtime session.".
-spec session_update_messages(map(), map()) -> [map()].
session_update_messages(Opts, Params) ->
    case session_update_payload(Opts, Params) of
        undefined ->
            [];
        Payload ->
            [#{
                <<"type">> => <<"session.update">>,
                <<"session">> => Payload
            }]
    end.

-doc "Build outbound text messages for a user turn.".
-spec text_messages(binary()) -> [map()].
text_messages(Text) when is_binary(Text) ->
    [
        #{
            <<"type">> => <<"conversation.item.create">>,
            <<"item">> => #{
                <<"type">> => <<"message">>,
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"input_text">>, <<"text">> => Text}
                ]
            }
        },
        #{<<"type">> => <<"response.create">>}
    ].

-doc "Build outbound audio messages for a user turn.".
-spec audio_messages(binary(), boolean()) -> [map()].
audio_messages(Audio, Commit) when is_binary(Audio) ->
    Base = #{
        <<"type">> => <<"input_audio_buffer.append">>,
        <<"audio">> => base64:encode(Audio)
    },
    case Commit of
        true ->
            [Base, #{<<"type">> => <<"input_audio_buffer.commit">>}];
        false ->
            [Base]
    end.

-doc "Build the interrupt/cancel message.".
-spec interrupt_message() -> map().
interrupt_message() ->
    #{<<"type">> => <<"response.cancel">>}.

-doc "Normalize a server websocket event into canonical `beam_agent` messages.".
-spec normalize_server_event(map()) -> [beam_agent_core:message()].
normalize_server_event(#{<<"type">> := <<"error">>} = Json) ->
    [(base_message(error, Json))#{
        content => event_message(Json),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.audio.delta">>} = Json) ->
    [(base_message(system, Json))#{
        subtype => <<"thread_realtime_output_audio_delta">>,
        content => <<"thread realtime audio delta">>,
        audio => decode_audio(Json),
        item_id => maps:get(<<"item_id">>, Json, <<>>),
        response_id => maps:get(<<"response_id">>, Json, <<>>),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.audio.done">>} = Json) ->
    [(base_message(system, Json))#{
        subtype => <<"thread_realtime_audio_done">>,
        content => <<"thread realtime audio done">>,
        item_id => maps:get(<<"item_id">>, Json, <<>>),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.audio_transcript.delta">>} = Json) ->
    [(base_message(text, Json))#{
        content => maps:get(<<"delta">>, Json, <<>>),
        delta => true,
        item_id => maps:get(<<"item_id">>, Json, <<>>),
        response_id => maps:get(<<"response_id">>, Json, <<>>),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.function_call_arguments.done">>} = Json) ->
    [(base_message(tool_use, Json))#{
        tool_name => maps:get(<<"name">>, Json, <<>>),
        tool_input => parse_arguments(maps:get(<<"arguments">>, Json, <<"{}">>)),
        tool_use_id => maps:get(<<"call_id">>, Json, <<>>),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"conversation.item.created">>,
                         <<"item">> := Item} = Json) ->
    normalize_created_item(Item, Json);
normalize_server_event(#{<<"type">> := <<"conversation.item.input_audio_transcription.completed">>} = Json) ->
    [(base_message(system, Json))#{
        subtype => <<"input_audio_transcription_completed">>,
        content => maps:get(<<"transcript">>, Json, <<>>),
        item_id => maps:get(<<"item_id">>, Json, <<>>),
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.created">>} = Json) ->
    [(base_message(system, Json))#{
        subtype => <<"thread_realtime_started">>,
        content => <<"thread realtime started">>,
        raw => Json
    }];
normalize_server_event(#{<<"type">> := <<"response.done">>} = Json) ->
    [(base_message(system, Json))#{
        subtype => <<"thread_realtime_done">>,
        content => <<"thread realtime done">>,
        raw => Json
    }];
normalize_server_event(Json) when is_map(Json) ->
    [(base_message(raw, Json))#{raw => Json}].

-doc "Build the session.update payload from static opts and runtime params.".
-spec session_update_payload(map(), map()) -> map() | undefined.
session_update_payload(Opts, Params) ->
    Model = value(Params, [model, <<"model">>], maps:get(model, Opts, default_model())),
    Voice = value(Params, [voice, <<"voice">>], maps:get(voice, Opts, undefined)),
    Instructions = value(Params, [instructions, <<"instructions">>], maps:get(instructions, Opts, undefined)),
    Modalities = value(Params, [modalities, <<"modalities">>], maps:get(modalities, Opts, [<<"text">>, <<"audio">>])),
    Payload0 = #{
        <<"model">> => Model,
        <<"modalities">> => normalize_modalities(Modalities)
    },
    Payload1 = maybe_put(<<"voice">>, Voice, Payload0),
    Payload2 = maybe_put(<<"instructions">>, Instructions, Payload1),
    case map_size(Payload2) of
        0 -> undefined;
        _ -> Payload2
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec normalize_created_item(map(), map()) -> [beam_agent_core:message()].
normalize_created_item(#{<<"type">> := <<"message">>,
                         <<"role">> := <<"assistant">>,
                         <<"content">> := Content}, Json)
  when is_list(Content) ->
    lists:foldl(fun(ContentPart, Acc) ->
        case ContentPart of
            #{<<"type">> := <<"text">>} ->
                [(base_message(text, Json))#{
                    content => maps:get(<<"text">>, ContentPart, <<>>),
                    delta => false,
                    raw => Json
                } | Acc];
            #{<<"type">> := <<"audio">>} ->
                Transcript = maps:get(<<"transcript">>, ContentPart, <<>>),
                case Transcript of
                    <<>> ->
                        Acc;
                    _ ->
                        [(base_message(text, Json))#{
                            content => Transcript,
                            delta => false,
                            raw => Json
                        } | Acc]
                end;
            _ ->
                Acc
        end
    end, [], Content);
normalize_created_item(Item, Json) ->
    [(base_message(raw, Json))#{
        raw => #{item => Item, event => Json}
    }].

base_message(Type, Json) ->
    #{
        type => Type,
        timestamp => erlang:system_time(millisecond),
        event_type => maps:get(<<"type">>, Json, <<>>)
    }.

-spec event_message(map()) -> binary().
event_message(Json) ->
    case maps:get(<<"error">>, Json, undefined) of
        #{<<"message">> := Message} when is_binary(Message) ->
            Message;
        _ ->
            maps:get(<<"message">>, Json, <<"realtime error">>)
    end.

-spec decode_audio(map()) -> binary().
decode_audio(Json) ->
    case maps:get(<<"delta">>, Json, <<>>) of
        Encoded when is_binary(Encoded), byte_size(Encoded) > 0 ->
            try base64:decode(Encoded) of
                Audio -> Audio
            catch
                _:_ -> <<>>
            end;
        _ ->
            <<>>
    end.

-spec parse_arguments(binary()) -> map().
parse_arguments(Arguments) when is_binary(Arguments), byte_size(Arguments) > 0 ->
    try json:decode(Arguments) of
        Parsed when is_map(Parsed) -> Parsed;
        _ -> #{<<"arguments">> => Arguments}
    catch
        _:_ ->
            #{<<"arguments">> => Arguments}
    end;
parse_arguments(_) ->
    #{}.

-spec normalize_modalities(term()) -> [binary()].
normalize_modalities(Modalities) when is_list(Modalities) ->
    [normalize_modality(Modality) || Modality <- Modalities];
normalize_modalities(_) ->
    [<<"text">>, <<"audio">>].

-spec normalize_modality(term()) -> binary().
normalize_modality(Modality) when is_binary(Modality) ->
    Modality;
normalize_modality(Modality) when is_atom(Modality) ->
    atom_to_binary(Modality, utf8);
normalize_modality(Modality) ->
    iolist_to_binary(io_lib:format("~tp", [Modality])).

-spec maybe_put(binary(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(_Key, <<>>, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec value(map(), [term()], term()) -> term().
value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Found} ->
            Found;
        error ->
            value(Map, Rest, Default)
    end;
value(_Map, [], Default) ->
    Default.
