-module(beam_agent_attachments).
-moduledoc """
Universal attachment materialization for backends without native rich input
parts.

When a backend already supports structured attachments natively, query params
are passed through unchanged. Otherwise attachments are rendered into a stable
text appendix so the canonical API remains usable across every backend.
""".

-export([prepare/3]).

-dialyzer({no_underspecs,
           [describe_named_attachment/2,
            normalize_attachment/2,
            value/3,
            absolute_uri/1,
            attachment_name/2,
            attachment_mime/2,
            fallback_attachment_backend/1,
            attachment_manifest_entry/1]}).

-doc """
Prepare query input for the selected backend.

For Claude and Gemini today the fallback converts `attachments` into a textual
appendix and removes the raw attachment payload from params before dispatch.
""".
-spec prepare(pid(), binary(), map()) -> {binary(), map()}.
prepare(Session, Prompt, Params)
  when is_pid(Session), is_binary(Prompt), is_map(Params) ->
    case maps:get(attachments, Params, []) of
        Attachments when is_list(Attachments), Attachments =/= [] ->
            case fallback_attachment_backend(Session) of
                native ->
                    {Prompt, Params};
                gemini ->
                    {Prompt,
                     maps:merge(maps:remove(attachments, Params), #{
                         beam_agent_attachment_blocks => normalize_attachments(Attachments),
                         beam_agent_attachment_manifest => attachment_manifest(Attachments),
                         beam_agent_prompt_blocks => canonical_prompt_blocks(Prompt, Attachments)
                     })};
                fallback ->
                    {augment_prompt(Prompt, Attachments),
                     maps:merge(maps:remove(attachments, Params), #{
                         beam_agent_attachment_blocks => normalize_attachments(Attachments),
                         beam_agent_attachment_manifest => attachment_manifest(Attachments),
                         beam_agent_prompt_blocks => canonical_prompt_blocks(Prompt, Attachments)
                     })}
            end;
        _ ->
            {Prompt, Params}
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec fallback_attachment_backend(pid()) -> native | gemini | fallback.
fallback_attachment_backend(Session) ->
    case resolve_backend(Session) of
        {ok, codex} ->
            native;
        {ok, opencode} ->
            native;
        {ok, copilot} ->
            native;
        {ok, gemini} ->
            gemini;
        _ ->
            fallback
    end.

-spec resolve_backend(pid()) -> {ok, beam_agent_backend:backend()} | {error, term()}.
resolve_backend(Session) ->
    case beam_agent_backend:session_backend(Session) of
        {ok, _Backend} = Ok ->
            Ok;
        {error, _} ->
            maybe_backend_from_session_info(Session)
    end.

-spec maybe_backend_from_session_info(pid()) ->
    {ok, beam_agent_backend:backend()} | {error, term()}.
maybe_backend_from_session_info(Session) ->
    try gen_statem:call(Session, session_info, 5000) of
        {ok, Info} when is_map(Info) ->
            maybe_register_backend(Session,
                maps:get(adapter, Info, maps:get(backend, Info, undefined)));
        Other ->
            {error, {invalid_session_info, Other}}
    catch
        exit:Reason ->
            {error, Reason}
    end.

maybe_register_backend(_Session, undefined) ->
    {error, backend_not_present};
maybe_register_backend(Session, BackendLike) ->
    case beam_agent_backend:register_session(Session, BackendLike) of
        {ok, _Backend} ->
            beam_agent_backend:session_backend(Session);
        {error, _} = Error ->
            Error
    end.

-spec augment_prompt(binary(), [term()]) -> binary().
augment_prompt(Prompt, Attachments) ->
    Appendix = iolist_to_binary([
        <<"\n\n[BeamAgent attachments]\n">>,
        lists:join(<<"\n">>, [attachment_line(Attachment) || Attachment <- Attachments])
    ]),
    <<Prompt/binary, Appendix/binary>>.

gemini_prompt_blocks(Prompt, Attachments) ->
    Base =
        case Prompt of
            <<>> -> [];
            _ -> [text_block(Prompt)]
        end,
    Base ++ lists:flatmap(fun gemini_attachment_blocks/1, Attachments).

canonical_prompt_blocks(Prompt, Attachments) ->
    gemini_prompt_blocks(Prompt, Attachments).

gemini_attachment_blocks(Attachment) when is_map(Attachment) ->
    Type = value(Attachment, [type, <<"type">>], undefined),
    case Type of
        text ->
            [text_block(value(Attachment, [text, <<"text">>, content, <<"content">>], <<>>))];
        <<"text">> ->
            [text_block(value(Attachment, [text, <<"text">>, content, <<"content">>], <<>>))];
        image ->
            image_blocks(Attachment);
        <<"image">> ->
            image_blocks(Attachment);
        local_image ->
            image_blocks(Attachment);
        <<"local_image">> ->
            image_blocks(Attachment);
        audio ->
            audio_blocks(Attachment);
        <<"audio">> ->
            audio_blocks(Attachment);
        file ->
            resource_blocks(Attachment);
        <<"file">> ->
            resource_blocks(Attachment);
        document ->
            resource_blocks(Attachment);
        <<"document">> ->
            resource_blocks(Attachment);
        mention ->
            named_context_blocks(<<"mention">>, Attachment);
        <<"mention">> ->
            named_context_blocks(<<"mention">>, Attachment);
        skill ->
            named_context_blocks(<<"skill">>, Attachment);
        <<"skill">> ->
            named_context_blocks(<<"skill">>, Attachment);
        _Other ->
            [text_block(attachment_line(Attachment))]
    end;
gemini_attachment_blocks(Other) ->
    [text_block(iolist_to_binary(io_lib:format("~tp", [Other])))].

text_block(Text) when is_binary(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text}.

image_blocks(Attachment) ->
    case media_block(<<"image">>, Attachment, <<"image/png">>) of
        {ok, Block} ->
            [Block];
        error ->
            resource_link_or_text_blocks(<<"image">>, Attachment)
    end.

audio_blocks(Attachment) ->
    case media_block(<<"audio">>, Attachment, <<"audio/wav">>) of
        {ok, Block} ->
            [Block];
        error ->
            resource_link_or_text_blocks(<<"audio">>, Attachment)
    end.

resource_blocks(Attachment) ->
    case embedded_resource_block(Attachment) of
        {ok, Block} ->
            [Block];
        error ->
            resource_link_or_text_blocks(<<"file">>, Attachment)
    end.

named_context_blocks(Label, Attachment) ->
    case resource_link_block(Label, Attachment) of
        {ok, Block} ->
            [Block];
        error ->
            [text_block(describe_named_attachment(Label, Attachment))]
    end.

resource_link_or_text_blocks(DefaultName, Attachment) ->
    case resource_link_block(DefaultName, Attachment) of
        {ok, Block} ->
            [Block];
        error ->
            [text_block(attachment_line(Attachment))]
    end.

media_block(Type, Attachment, DefaultMime) ->
    case read_attachment_file(Attachment) of
        {ok, Path, Data} ->
            Uri = absolute_uri(Path),
            Mime = attachment_mime(Attachment, DefaultMime),
            {ok, maps:merge(
                #{<<"type">> => Type,
                  <<"mimeType">> => Mime,
                  <<"data">> => base64:encode(Data)},
                case Uri of
                    undefined -> #{};
                    _ -> #{<<"uri">> => Uri}
                end)};
        error ->
            error
    end.

embedded_resource_block(Attachment) ->
    case read_attachment_file(Attachment) of
        {ok, Path, Data} ->
            Uri = absolute_uri(Path),
            Mime = attachment_mime(Attachment, <<"application/octet-stream">>),
            Resource0 = #{
                <<"uri">> => Uri
            },
            Resource1 =
                case maybe_text_binary(Data) of
                    {ok, Text} ->
                        Resource0#{<<"text">> => Text};
                    error ->
                        Resource0#{<<"blob">> => base64:encode(Data)}
                end,
            Resource2 =
                case Mime of
                    undefined -> Resource1;
                    _ -> Resource1#{<<"mimeType">> => Mime}
                end,
            {ok, #{
                <<"type">> => <<"resource">>,
                <<"resource">> => Resource2
            }};
        error ->
            error
    end.

resource_link_block(DefaultName, Attachment) ->
    case preferred_uri(Attachment) of
        undefined ->
            error;
        UriLike ->
            Name = attachment_name(Attachment, DefaultName),
            Mime = attachment_mime(Attachment, undefined),
            Base = #{
                <<"type">> => <<"resource_link">>,
                <<"uri">> => UriLike,
                <<"name">> => Name
            },
            {ok,
             case Mime of
                 undefined -> Base;
                 _ -> Base#{<<"mimeType">> => Mime}
             end}
    end.

-spec preferred_uri(map()) -> binary() | undefined.
preferred_uri(Attachment) ->
    case value(Attachment,
           [uri, <<"uri">>, path, <<"path">>, url, <<"url">>, image_url, <<"image_url">>],
           undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 ->
            absolute_uri(Value);
        _ ->
            undefined
    end.

-spec read_attachment_file(map()) -> {ok, binary(), binary()} | error.
read_attachment_file(Attachment) ->
    case value(Attachment, [path, <<"path">>], undefined) of
        Path when is_binary(Path), byte_size(Path) > 0 ->
            case read_local_file(Path) of
                {ok, Data} -> {ok, Path, Data};
                error -> error
            end;
        _ ->
            error
    end.

-spec read_local_file(binary()) -> {ok, binary()} | error.
read_local_file(Path) ->
    case is_uri(Path) of
        true ->
            error;
        false ->
            case file:read_file(ensure_list(Path)) of
                {ok, Data} when is_binary(Data) ->
                    {ok, Data};
                _ ->
                    error
            end
    end.

-spec maybe_text_binary(binary()) -> {ok, binary()} | error.
maybe_text_binary(Data) when is_binary(Data) ->
    try unicode:characters_to_binary(Data) of
        Text when is_binary(Text) ->
            {ok, Text}
    catch
        error:_ ->
            error
    end.

-spec absolute_uri(binary()) -> binary() | undefined.
absolute_uri(Value) when is_binary(Value), byte_size(Value) > 0 ->
    case is_uri(Value) of
        true ->
            Value;
        false ->
            Abs = filename:absname(ensure_list(Value)),
            <<"file://", (unicode:characters_to_binary(Abs))/binary>>
    end;
absolute_uri(_) ->
    undefined.

-spec is_uri(binary()) -> boolean().
is_uri(Value) ->
    binary:match(Value, <<"://">>) =/= nomatch.

-spec attachment_name(map(), binary()) -> binary().
attachment_name(Attachment, Default) ->
    case value(Attachment, [name, <<"name">>, filename, <<"filename">>], undefined) of
        Name when is_binary(Name), byte_size(Name) > 0 ->
            Name;
        _ ->
            case value(Attachment, [path, <<"path">>, url, <<"url">>, uri, <<"uri">>], undefined) of
                Path when is_binary(Path), byte_size(Path) > 0 ->
                    unicode:characters_to_binary(filename:basename(ensure_list(Path)));
                _ ->
                    Default
            end
    end.

-spec attachment_mime(map(), binary() | undefined) -> binary() | undefined.
attachment_mime(Attachment, Default) ->
    case value(Attachment, [mime, <<"mime">>, mime_type, <<"mime_type">>, content_type, <<"content_type">>], undefined) of
        Mime when is_binary(Mime), byte_size(Mime) > 0 ->
            Mime;
        _ ->
            infer_mime(attachment_name(Attachment, <<"attachment">>), Default)
    end.

infer_mime(Name, Default) ->
    case filename:extension(ensure_list(Name)) of
        ".erl" -> <<"text/x-erlang">>;
        ".ex" -> <<"text/x-elixir">>;
        ".exs" -> <<"text/x-elixir">>;
        ".md" -> <<"text/markdown">>;
        ".txt" -> <<"text/plain">>;
        ".json" -> <<"application/json">>;
        ".pdf" -> <<"application/pdf">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".gif" -> <<"image/gif">>;
        ".wav" -> <<"audio/wav">>;
        ".mp3" -> <<"audio/mpeg">>;
        _ -> Default
    end.

normalize_attachments(Attachments) ->
    [normalize_attachment(value(Attachment, [type, <<"type">>], undefined), Attachment)
     || Attachment <- Attachments].

attachment_manifest(Attachments) ->
    [attachment_manifest_entry(Attachment) || Attachment <- Attachments].

-spec attachment_line(term()) -> binary().
attachment_line(Attachment) when is_map(Attachment) ->
    Type = value(Attachment, [type, <<"type">>], undefined),
    Content = case Type of
        text ->
            value(Attachment, [text, <<"text">>, content, <<"content">>], <<>>);
        <<"text">> ->
            value(Attachment, [text, <<"text">>, content, <<"content">>], <<>>);
        image ->
            describe_media(Attachment);
        <<"image">> ->
            describe_media(Attachment);
        local_image ->
            describe_media(Attachment);
        <<"local_image">> ->
            describe_media(Attachment);
        file ->
            describe_media(Attachment);
        <<"file">> ->
            describe_media(Attachment);
        mention ->
            describe_named_attachment(<<"mention">>, Attachment);
        <<"mention">> ->
            describe_named_attachment(<<"mention">>, Attachment);
        skill ->
            describe_named_attachment(<<"skill">>, Attachment);
        <<"skill">> ->
            describe_named_attachment(<<"skill">>, Attachment);
        Other ->
            iolist_to_binary(io_lib:format("~tp", [normalize_attachment(Other, Attachment)]))
    end,
    Prefix = iolist_to_binary([
        <<"- ">>,
        type_label(Type),
        <<": ">>
    ]),
    <<Prefix/binary, Content/binary>>;
attachment_line(Other) ->
    iolist_to_binary(io_lib:format("- raw: ~tp", [Other])).

-spec describe_media(map()) -> binary().
describe_media(Attachment) ->
    Path = value(Attachment, [path, <<"path">>], undefined),
    Url = value(Attachment, [url, <<"url">>, image_url, <<"image_url">>], undefined),
    Name = value(Attachment, [name, <<"name">>, filename, <<"filename">>], undefined),
    iolist_to_binary(io_lib:format("path=~tp url=~tp name=~tp", [Path, Url, Name])).

-spec describe_named_attachment(binary(), map()) -> binary().
describe_named_attachment(Label, Attachment) ->
    Name = value(Attachment, [name, <<"name">>], <<>>),
    Path = value(Attachment, [path, <<"path">>], <<>>),
    <<Label/binary, " name=", Name/binary, " path=", Path/binary>>.

-spec type_label(term()) -> binary().
type_label(undefined) ->
    <<"attachment">>;
type_label(Type) when is_atom(Type) ->
    atom_to_binary(Type, utf8);
type_label(Type) when is_binary(Type) ->
    Type;
type_label(Type) ->
    iolist_to_binary(io_lib:format("~tp", [Type])).

-spec normalize_attachment(term(), map()) -> map().
normalize_attachment(Type, Attachment) ->
    Base = #{
        type => normalize_type(Type),
        name => attachment_name(Attachment, type_label(Type)),
        mime => attachment_mime(Attachment, undefined),
        uri => preferred_uri(Attachment)
    },
    case normalize_type(Type) of
        text ->
            Base#{text => value(Attachment, [text, <<"text">>, content, <<"content">>], <<>>)};
        image ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined),
                  url => value(Attachment, [url, <<"url">>, image_url, <<"image_url">>], undefined)};
        audio ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined),
                  size => value(Attachment, [size, <<"size">>], undefined)};
        file ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined)};
        document ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined)};
        mention ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined),
                  mention => value(Attachment, [name, <<"name">>], undefined)};
        skill ->
            Base#{path => value(Attachment, [path, <<"path">>], undefined),
                  skill => value(Attachment, [name, <<"name">>], undefined)};
        normalized_other ->
            Base#{value => Attachment}
    end.

-spec attachment_manifest_entry(map()) -> map().
attachment_manifest_entry(Attachment) ->
    Normalized = normalize_attachment(value(Attachment, [type, <<"type">>], undefined), Attachment),
    maps:with([type, name, mime, uri, path, url, text, mention, skill], Normalized).

-spec normalize_type(term()) -> text | image | audio | file | document | mention | skill | normalized_other.
normalize_type(text) ->
    text;
normalize_type(<<"text">>) ->
    text;
normalize_type(image) ->
    image;
normalize_type(<<"image">>) ->
    image;
normalize_type(local_image) ->
    image;
normalize_type(<<"local_image">>) ->
    image;
normalize_type(audio) ->
    audio;
normalize_type(<<"audio">>) ->
    audio;
normalize_type(file) ->
    file;
normalize_type(<<"file">>) ->
    file;
normalize_type(document) ->
    document;
normalize_type(<<"document">>) ->
    document;
normalize_type(mention) ->
    mention;
normalize_type(<<"mention">>) ->
    mention;
normalize_type(skill) ->
    skill;
normalize_type(<<"skill">>) ->
    skill;
normalize_type(_) ->
    normalized_other.

ensure_list(Value) when is_binary(Value) ->
    binary_to_list(Value).

-spec value(map(), [atom() | binary()], term()) -> term().
value(Map, [Key | Rest], Default) ->
    case maps:find(Key, Map) of
        {ok, Found} ->
            Found;
        error ->
            value(Map, Rest, Default)
    end;
value(_Map, [], Default) ->
    Default.
