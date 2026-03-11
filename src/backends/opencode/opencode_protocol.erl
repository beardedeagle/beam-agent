-module(opencode_protocol).
-moduledoc false.
-export([normalize_event/1,
         build_prompt_input/2,
         build_session_init_input/1,
         build_shell_input/2,
         build_permission_reply/2,
         parse_session/1]).
-export_type([]).
-dialyzer({no_underspecs,
           [{parse_session, 1},
            {build_session_init_input, 1},
            {build_shell_input, 2},
            {maybe_add_model_ids, 2},
            {maybe_add_output_format, 2},
            {maybe_add_message_id, 2},
            {maybe_add_mode, 2},
            {maybe_add_system, 2},
            {maybe_add_tools, 2},
            {maybe_add_model_ref, 2},
            {normalize_attachments, 1},
            {normalize_attachment, 1},
            {attachment_to_file_part, 1},
            {normalize_file_part, 1},
            {infer_mime, 1},
            {default_message_id, 0}]}).
-dialyzer({no_extra_return,
           [{normalize_part_updated, 2},
            {dispatch_part_type, 4},
            {normalize_tool_part, 5}]}).
-spec normalize_event(map()) -> beam_agent_core:message() | skip.
normalize_event(SseEvent) ->
    EventType = maps:get(event, SseEvent, <<"unknown">>),
    Payload = maps:get(data, SseEvent, #{}),
    Now = erlang:system_time(millisecond),
    dispatch_event(EventType, Payload, Now).
-spec build_prompt_input(binary(), map()) -> map().
build_prompt_input(Prompt, Opts) ->
    Parts =
        case maps:get(parts, Opts, undefined) of
            Parts0 when is_list(Parts0) ->
                normalize_parts(Parts0);
            _ ->
                [text_part(Prompt) |
                 normalize_attachments(maps:get(attachments, Opts, []))]
        end,
    Base = #{<<"parts">> => Parts},
    M1 = maybe_add_message_id(Base, Opts),
    M2 = maybe_add_model_ids(M1, Opts),
    M3 = maybe_add_mode(M2, Opts),
    M4 = maybe_add_system(M3, Opts),
    M5 = maybe_add_tools(M4, Opts),
    maybe_add_output_format(M5, Opts).
-spec build_permission_reply(binary(), binary()) -> map().
build_permission_reply(PermId, Decision) ->
    #{<<"id">> => PermId, <<"decision">> => Decision}.
-spec build_session_init_input(map()) ->
                                  {ok, map()} |
                                  {error, invalid_init_opts}.
build_session_init_input(Opts) when is_map(Opts) ->
    MessageId =
        case
            maps:get(message_id, Opts,
                     maps:get(messageID, Opts, undefined))
        of
            undefined ->
                default_message_id();
            Value ->
                to_binary(Value)
        end,
    ModelId =
        maps:get(model_id, Opts,
                 extract_model_id(maps:get(model, Opts, undefined))),
    ProviderId =
        maps:get(provider_id, Opts,
                 extract_provider_id(maps:get(model, Opts, undefined))),
    case {ModelId, ProviderId} of
        {ModelIdBin, ProviderIdBin}
            when
                is_binary(ModelIdBin),
                is_binary(ProviderIdBin),
                byte_size(ModelIdBin) > 0,
                byte_size(ProviderIdBin) > 0 ->
            {ok,
             #{<<"messageID">> => MessageId,
               <<"modelID">> => ModelIdBin,
               <<"providerID">> => ProviderIdBin}};
        _ ->
            {error, invalid_init_opts}
    end.
-spec build_shell_input(binary(), map()) ->
                           {ok, map()} | {error, invalid_shell_opts}.
build_shell_input(Command, Opts) when is_binary(Command), is_map(Opts) ->
    Agent = maps:get(agent, Opts, undefined),
    case Agent of
        AgentBin when is_binary(AgentBin), byte_size(AgentBin) > 0 ->
            Base = #{<<"agent">> => AgentBin, <<"command">> => Command},
            {ok, maybe_add_model_ref(Base, Opts)};
        _ ->
            {error, invalid_shell_opts}
    end.
-spec parse_session(map()) -> map().
parse_session(Raw) when is_map(Raw) ->
    #{id => maps:get(<<"id">>, Raw, undefined),
      directory => maps:get(<<"directory">>, Raw, undefined),
      model => maps:get(<<"model">>, Raw, undefined),
      raw => Raw}.
-spec dispatch_event(binary(), map(), integer()) ->
                        beam_agent_core:message() | skip.
dispatch_event(<<"message.part.updated">>, Payload, Now) ->
    normalize_part_updated(Payload, Now);
dispatch_event(<<"message.updated">>, Payload, Now) ->
    case maps:get(<<"error">>, Payload, undefined) of
        undefined ->
            #{type => raw, raw => Payload, timestamp => Now};
        ErrorVal ->
            ErrName =
                case is_map(ErrorVal) of
                    true ->
                        maps:get(<<"name">>,
                                 ErrorVal,
                                 <<"unknown_error">>);
                    false ->
                        <<"message_error">>
                end,
            ErrData =
                case is_map(ErrorVal) of
                    true ->
                        maps:get(<<"data">>, ErrorVal, <<>>);
                    false ->
                        <<>>
                end,
            Content =
                iolist_to_binary([ErrName, <<": ">>, to_binary(ErrData)]),
            #{type => error,
              content => Content,
              raw => Payload,
              timestamp => Now}
    end;
dispatch_event(<<"session.idle">>, Payload, Now) ->
    SessionId = maps:get(<<"id">>, Payload, undefined),
    Base =
        #{type => result,
          content => <<>>,
          timestamp => Now,
          raw => Payload},
    case SessionId of
        undefined ->
            Base;
        SId ->
            Base#{session_id => SId}
    end;
dispatch_event(<<"session.error">>, Payload, Now) ->
    ErrMsg =
        maps:get(<<"message">>,
                 Payload,
                 maps:get(<<"error">>, Payload, <<"session error">>)),
    Content = to_binary(ErrMsg),
    #{type => error,
      content => Content,
      raw => Payload,
      timestamp => Now};
dispatch_event(<<"permission.updated">>, Payload, Now) ->
    PermId = maps:get(<<"id">>, Payload, undefined),
    ReqInfo = maps:get(<<"request">>, Payload, Payload),
    #{type => control_request,
      request_id => to_binary(PermId),
      request => ReqInfo,
      raw => Payload,
      timestamp => Now};
dispatch_event(<<"server.heartbeat">>, _Payload, _Now) ->
    skip;
dispatch_event(<<"server.connected">>, Payload, Now) ->
    #{type => system,
      subtype => <<"connected">>,
      content => <<>>,
      raw => Payload,
      timestamp => Now};
dispatch_event(_Other, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.
-spec normalize_part_updated(map(), integer()) ->
                                beam_agent_core:message() | skip.
normalize_part_updated(Payload, Now) ->
    Part = maps:get(<<"part">>, Payload, Payload),
    PartType = maps:get(<<"type">>, Part, <<>>),
    dispatch_part_type(PartType, Part, Payload, Now).
-spec dispatch_part_type(binary(), map(), map(), integer()) ->
                            beam_agent_core:message() | skip.
dispatch_part_type(<<"text">>, Part, Payload, Now) ->
    Content =
        case maps:get(<<"delta">>, Part, undefined) of
            undefined ->
                maps:get(<<"text">>, Part, <<>>);
            Delta ->
                to_binary(Delta)
        end,
    #{type => text,
      content => Content,
      raw => Payload,
      timestamp => Now};
dispatch_part_type(<<"reasoning">>, Part, Payload, Now) ->
    Content =
        maps:get(<<"text">>,
                 Part,
                 maps:get(<<"reasoning">>, Part, <<>>)),
    #{type => thinking,
      content => to_binary(Content),
      raw => Payload,
      timestamp => Now};
dispatch_part_type(<<"tool">>, Part, Payload, Now) ->
    State = maps:get(<<"state">>, Part, #{}),
    Status =
        maps:get(<<"status">>,
                 State,
                 maps:get(<<"status">>, Part, <<"pending">>)),
    normalize_tool_part(Status, Part, State, Payload, Now);
dispatch_part_type(<<"step-start">>, _Part, Payload, Now) ->
    #{type => system,
      subtype => <<"step_start">>,
      content => <<>>,
      raw => Payload,
      timestamp => Now};
dispatch_part_type(<<"step-finish">>, Part, Payload, Now) ->
    Cost = maps:get(<<"cost">>, Part, undefined),
    Tokens = maps:get(<<"tokens">>, Part, undefined),
    Base =
        #{type => system,
          subtype => <<"step_finish">>,
          content => <<>>,
          raw => Payload,
          timestamp => Now},
    M0 =
        case Cost of
            undefined ->
                Base;
            C ->
                Base#{total_cost_usd => C}
        end,
    M1 =
        case Tokens of
            undefined ->
                M0;
            T ->
                M0#{usage => T}
        end,
    M1;
dispatch_part_type(_Other, _Part, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.
-spec normalize_tool_part(binary(), map(), map(), map(), integer()) ->
                             beam_agent_core:message() | skip.
normalize_tool_part(Status, Part, State, Payload, Now)
    when Status =:= <<"pending">>; Status =:= <<"running">> ->
    ToolName =
        maps:get(<<"tool">>, State, maps:get(<<"tool">>, Part, <<>>)),
    ToolInput =
        maps:get(<<"input">>, State, maps:get(<<"input">>, Part, #{})),
    #{type => tool_use,
      tool_name => to_binary(ToolName),
      tool_input => ensure_map(ToolInput),
      raw => Payload,
      timestamp => Now};
normalize_tool_part(<<"completed">>, Part, State, Payload, Now) ->
    ToolName =
        maps:get(<<"tool">>, State, maps:get(<<"tool">>, Part, <<>>)),
    Output =
        maps:get(<<"output">>,
                 State,
                 maps:get(<<"output">>, Part, <<>>)),
    #{type => tool_result,
      tool_name => to_binary(ToolName),
      content => to_binary(Output),
      raw => Payload,
      timestamp => Now};
normalize_tool_part(<<"error">>, Part, State, Payload, Now) ->
    ErrMsg =
        maps:get(<<"error">>,
                 State,
                 maps:get(<<"error">>, Part, <<"tool error">>)),
    #{type => error,
      content => to_binary(ErrMsg),
      raw => Payload,
      timestamp => Now};
normalize_tool_part(_OtherStatus, _Part, _State, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.
-spec maybe_add_model_ids(map(), map()) -> map().
maybe_add_model_ids(Base, Opts) ->
    Base1 =
        case
            maps:get(model_id, Opts,
                     extract_model_id(maps:get(model, Opts, undefined)))
        of
            ModelId when is_binary(ModelId) ->
                Base#{<<"modelID">> => ModelId};
            _ ->
                Base
        end,
    case
        maps:get(provider_id, Opts,
                 extract_provider_id(maps:get(model, Opts, undefined)))
    of
        ProviderId when is_binary(ProviderId) ->
            Base1#{<<"providerID">> => ProviderId};
        _ ->
            Base1
    end.
-spec maybe_add_message_id(map(), map()) -> map().
maybe_add_message_id(Base, Opts) ->
    case
        maps:get(message_id, Opts, maps:get(messageID, Opts, undefined))
    of
        MessageId when is_binary(MessageId) ->
            Base#{<<"messageID">> => MessageId};
        _ ->
            Base
    end.
-spec maybe_add_mode(map(), map()) -> map().
maybe_add_mode(Base, Opts) ->
    case maps:get(mode, Opts, undefined) of
        Mode when is_binary(Mode) ->
            Base#{<<"mode">> => Mode};
        _ ->
            Base
    end.
-spec maybe_add_system(map(), map()) -> map().
maybe_add_system(Base, Opts) ->
    case
        maps:get(system, Opts, maps:get(system_prompt, Opts, undefined))
    of
        System when is_binary(System) ->
            Base#{<<"system">> => System};
        _ ->
            Base
    end.
-spec maybe_add_tools(map(), map()) -> map().
maybe_add_tools(Base, Opts) ->
    case maps:get(tools, Opts, undefined) of
        Tools when is_map(Tools) ->
            Base#{<<"tools">> => Tools};
        _ ->
            Base
    end.
-spec maybe_add_output_format(map(), map()) -> map().
maybe_add_output_format(Base, Opts) ->
    case maps:get(output_format, Opts, undefined) of
        undefined ->
            Base;
        Format when is_map(Format) ->
            Base#{<<"outputFormat">> => Format};
        Format when is_atom(Format) ->
            Base#{<<"outputFormat">> => atom_to_binary(Format, utf8)};
        _ ->
            Base
    end.
-spec maybe_add_model_ref(map(), map()) -> map().
maybe_add_model_ref(Base, Opts) ->
    ModelId =
        maps:get(model_id, Opts,
                 extract_model_id(maps:get(model, Opts, undefined))),
    ProviderId =
        maps:get(provider_id, Opts,
                 extract_provider_id(maps:get(model, Opts, undefined))),
    case {ModelId, ProviderId} of
        {ModelIdBin, ProviderIdBin}
            when
                is_binary(ModelIdBin),
                byte_size(ModelIdBin) > 0,
                is_binary(ProviderIdBin),
                byte_size(ProviderIdBin) > 0 ->
            Base#{<<"model">> =>
                      #{<<"providerID">> => ProviderIdBin,
                        <<"modelID">> => ModelIdBin}};
        _ ->
            Base
    end.
-spec normalize_parts([map()]) -> [map()].
normalize_parts(Parts) ->
    [ 
     normalize_part(Part) ||
         Part <- Parts
    ].
-spec normalize_part(map() | binary()) -> map().
normalize_part(Part) when is_binary(Part) ->
    text_part(Part);
normalize_part(#{<<"type">> := <<"text">>} = Part) ->
    #{<<"type">> => <<"text">>,
      <<"text">> => maps:get(<<"text">>, Part, <<>>)};
normalize_part(#{type := text} = Part) ->
    #{<<"type">> => <<"text">>,
      <<"text">> => maps:get(text, Part, <<>>)};
normalize_part(#{<<"type">> := <<"file">>} = Part) ->
    normalize_file_part(Part);
normalize_part(#{type := file} = Part) ->
    normalize_file_part(Part);
normalize_part(Part) when is_map(Part) ->
    maps:fold(fun(Key, Value, Acc) when is_atom(Key) ->
                     Acc#{atom_to_binary(Key, utf8) => Value};
                 (Key, Value, Acc) ->
                     Acc#{Key => Value}
              end,
              #{},
              Part).
-spec normalize_attachments([map()] | undefined) -> [map()].
normalize_attachments(undefined) ->
    [];
normalize_attachments(Attachments) when is_list(Attachments) ->
    [ 
     normalize_attachment(Attachment) ||
         Attachment <- Attachments
    ].
-spec normalize_attachment(map()) -> map().
normalize_attachment(#{<<"type">> := <<"file">>} = Attachment) ->
    normalize_file_part(Attachment);
normalize_attachment(#{type := file} = Attachment) ->
    normalize_file_part(Attachment);
normalize_attachment(#{<<"type">> := <<"image">>} = Attachment) ->
    normalize_file_part(attachment_to_file_part(Attachment));
normalize_attachment(#{type := image} = Attachment) ->
    normalize_file_part(attachment_to_file_part(Attachment));
normalize_attachment(#{<<"type">> := Type} = Attachment)
    when Type =:= <<"local_image">>; Type =:= <<"localImage">> ->
    normalize_file_part(attachment_to_file_part(Attachment));
normalize_attachment(#{type := Type} = Attachment)
    when Type =:= local_image; Type =:= localImage ->
    normalize_file_part(attachment_to_file_part(Attachment));
normalize_attachment(Attachment) ->
    normalize_file_part(attachment_to_file_part(Attachment)).
-spec attachment_to_file_part(map()) -> map().
attachment_to_file_part(Attachment) ->
    Path = attachment_value(Attachment, [<<"path">>, path], undefined),
    Url =
        case
            attachment_value(Attachment, [<<"url">>, url], undefined)
        of
            undefined when is_binary(Path) ->
                <<"file://",Path/binary>>;
            undefined ->
                <<>>;
            Value ->
                Value
        end,
    #{<<"type">> => <<"file">>,
      <<"url">> => Url,
      <<"mime">> => attachment_mime(Attachment, Path),
      <<"filename">> =>
          attachment_value(Attachment, [<<"filename">>, filename], <<>>)}.
-spec normalize_file_part(map()) -> map().
normalize_file_part(Part) ->
    Base =
        #{<<"type">> => <<"file">>,
          <<"url">> => attachment_value(Part, [<<"url">>, url], <<>>),
          <<"mime">> =>
              attachment_mime(Part,
                              attachment_value(Part,
                                               [<<"path">>, path],
                                               undefined))},
    Base1 =
        case
            attachment_value(Part,
                             [<<"filename">>, filename],
                             undefined)
        of
            Filename when is_binary(Filename), byte_size(Filename) > 0 ->
                Base#{<<"filename">> => Filename};
            _ ->
                Base
        end,
    case maps:get(<<"source">>, Part, maps:get(source, Part, undefined)) of
        Source when is_map(Source) ->
            Base1#{<<"source">> => normalize_part(Source)};
        _ ->
            Base1
    end.
-spec text_part(binary()) -> map().
text_part(Prompt) ->
    #{<<"type">> => <<"text">>, <<"text">> => Prompt}.
-spec extract_model_id(map() | binary() | undefined) ->
                          binary() | undefined.
extract_model_id(#{<<"id">> := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(#{id := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(#{<<"modelID">> := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(#{model_id := ModelId}) when is_binary(ModelId) ->
    ModelId;
extract_model_id(ModelId) when is_binary(ModelId) ->
    ModelId;
extract_model_id(_) ->
    undefined.
-spec extract_provider_id(map() | undefined) -> binary() | undefined.
extract_provider_id(#{<<"providerID">> := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(#{provider_id := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(#{providerID := ProviderId})
    when is_binary(ProviderId) ->
    ProviderId;
extract_provider_id(_) ->
    undefined.
-spec attachment_value(map(), [term()], binary() | undefined) ->
                          binary() | undefined.
attachment_value(Attachment, [Key | Rest], Default) ->
    case maps:find(Key, Attachment) of
        {ok, Value} when is_binary(Value) ->
            Value;
        {ok, Value} when is_list(Value) ->
            to_binary(Value);
        {ok, Value} when is_atom(Value) ->
            atom_to_binary(Value, utf8);
        _ ->
            attachment_value(Attachment, Rest, Default)
    end;
attachment_value(_Attachment, [], Default) ->
    Default.
-spec attachment_mime(map(), binary() | undefined) -> binary().
attachment_mime(Attachment, Path) ->
    case attachment_value(Attachment, [<<"mime">>, mime], undefined) of
        Mime when is_binary(Mime), byte_size(Mime) > 0 ->
            Mime;
        _ ->
            infer_mime(Path)
    end.
-spec infer_mime(binary() | undefined) -> binary().
infer_mime(Path) when is_binary(Path) ->
    Lower = string:lowercase(filename:extension(binary_to_list(Path))),
    case Lower of
        ".png" ->
            <<"image/png">>;
        ".jpg" ->
            <<"image/jpeg">>;
        ".jpeg" ->
            <<"image/jpeg">>;
        ".gif" ->
            <<"image/gif">>;
        ".webp" ->
            <<"image/webp">>;
        ".pdf" ->
            <<"application/pdf">>;
        ".txt" ->
            <<"text/plain">>;
        _ ->
            <<"application/octet-stream">>
    end;
infer_mime(_) ->
    <<"application/octet-stream">>.
-spec to_binary(term()) -> binary().
to_binary(B) when is_binary(B) ->
    B;
to_binary(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) ->
    integer_to_binary(I);
to_binary(F) when is_float(F) ->
    iolist_to_binary(io_lib:format("~g", [F]));
to_binary(L) when is_list(L) ->
    try
        iolist_to_binary(L)
    catch
        _:_ ->
            list_to_binary(io_lib:format("~p", [L]))
    end;
to_binary(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).
-spec default_message_id() -> binary().
default_message_id() ->
    <<"message-",
      (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.
-spec ensure_map(term()) -> map().
ensure_map(M) when is_map(M) ->
    M;
ensure_map(_) ->
    #{}.
