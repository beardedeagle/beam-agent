-module(beam_agent_gemini_translate).
-moduledoc """
Translate Gemini ACP session updates into canonical BeamAgent messages.
""".

-dialyzer({no_underspecs,
           [tool_call_message/2,
            tool_call_update_messages/2,
            nonempty_or_default/2]}).

-export([
    session_update_messages/2,
    prompt_result_message/2
]).

-spec session_update_messages(binary(), map()) -> [beam_agent_core:message()].
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"user_message_chunk">>} = Update) ->
    [content_message(user, SessionId, Update)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"agent_message_chunk">>} = Update) ->
    [content_message(text, SessionId, Update)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"agent_thought_chunk">>} = Update) ->
    [content_message(thinking, SessionId, Update)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"tool_call">>} = Update) ->
    [tool_call_message(SessionId, Update)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"tool_call_update">>} = Update) ->
    tool_call_update_messages(SessionId, Update);
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"plan">>} = Update) ->
    [system_message(SessionId, <<"plan">>, Update, update_text(Update))];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"available_commands_update">>} = Update) ->
    [system_message(SessionId, <<"available_commands_update">>, Update, <<>>)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"current_mode_update">>} = Update) ->
    [system_message(SessionId, <<"current_mode_update">>, Update, <<>>)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"config_option_update">>} = Update) ->
    [system_message(SessionId, <<"config_option_update">>, Update, <<>>)];
session_update_messages(SessionId, #{<<"sessionUpdate">> := <<"session_info_update">>} = Update) ->
    [system_message(SessionId, <<"session_info_update">>, Update, update_text(Update))];
session_update_messages(SessionId, Update) when is_map(Update) ->
    [system_message(SessionId, <<"unknown_update">>, Update, <<>>)].

-spec prompt_result_message(binary(), map()) -> beam_agent_core:message().
prompt_result_message(SessionId, Result) when is_binary(SessionId), is_map(Result) ->
    StopReason = maps:get(<<"stopReason">>, Result, <<>>),
    #{
        type => result,
        session_id => SessionId,
        content => <<>>,
        stop_reason => StopReason,
        stop_reason_atom => beam_agent_core:parse_stop_reason(StopReason),
        raw => Result,
        timestamp => erlang:system_time(millisecond)
    }.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec content_message(beam_agent_core:message_type(), binary(), map()) ->
    beam_agent_core:message().
content_message(Type, SessionId, Update) ->
    #{
        type => Type,
        session_id => SessionId,
        content => content_block_text(maps:get(<<"content">>, Update, #{})),
        raw => Update,
        timestamp => erlang:system_time(millisecond)
    }.

-spec tool_call_message(binary(), map()) -> map().
tool_call_message(SessionId, Update) ->
    #{
        type => tool_use,
        session_id => SessionId,
        tool_name => maps:get(<<"title">>, Update,
            maps:get(<<"kind">>, Update, <<"tool_call">>)),
        tool_input => maps:without([<<"sessionUpdate">>], Update),
        tool_use_id => maps:get(<<"toolCallId">>, Update, <<>>),
        raw => Update,
        timestamp => erlang:system_time(millisecond)
    }.

-spec tool_call_update_messages(binary(), map()) -> [map()].
tool_call_update_messages(SessionId, Update) ->
    Status = maps:get(<<"status">>, Update, undefined),
    Content = tool_call_content_text(maps:get(<<"content">>, Update, [])),
    ToolUseId = maps:get(<<"toolCallId">>, Update, <<>>),
    case Status of
        <<"failed">> ->
            [#{
                type => error,
                session_id => SessionId,
                content => nonempty_or_default(Content, <<"tool call failed">>),
                tool_use_id => ToolUseId,
                raw => Update,
                timestamp => erlang:system_time(millisecond)
            }];
        _ ->
            [#{
                type => tool_result,
                session_id => SessionId,
                content => Content,
                tool_use_id => ToolUseId,
                raw => Update,
                timestamp => erlang:system_time(millisecond)
            }]
    end.

-spec system_message(binary(), binary(), map(), binary()) -> beam_agent_core:message().
system_message(SessionId, Subtype, Update, Content) ->
    #{
        type => system,
        session_id => SessionId,
        subtype => Subtype,
        content => Content,
        raw => Update,
        timestamp => erlang:system_time(millisecond)
    }.

-spec content_block_text(map()) -> binary().
content_block_text(#{<<"type">> := <<"text">>, <<"text">> := Text}) when is_binary(Text) ->
    Text;
content_block_text(#{<<"type">> := <<"resource_link">>} = Block) ->
    resource_text(Block);
content_block_text(#{<<"type">> := <<"resource">>} = Block) ->
    resource_text(Block);
content_block_text(Block) when is_map(Block) ->
    iolist_to_binary(io_lib:format("~tp", [Block]));
content_block_text(Other) ->
    iolist_to_binary(io_lib:format("~tp", [Other])).

-spec resource_text(map()) -> binary().
resource_text(Block) ->
    Uri = maps:get(<<"uri">>, Block, <<>>),
    Name = maps:get(<<"name">>, Block, <<>>),
    iolist_to_binary([
        <<"resource ">>,
        Name,
        <<" ">>,
        Uri
    ]).

-spec tool_call_content_text(list()) -> binary().
tool_call_content_text(Content) when is_list(Content) ->
    iolist_to_binary(
        lists:join(<<"\n">>,
            [tool_call_content_item(Item) || Item <- Content]));
tool_call_content_text(_) ->
    <<>>.

-spec tool_call_content_item(map()) -> binary().
tool_call_content_item(#{<<"type">> := <<"content">>, <<"content">> := Block}) ->
    content_block_text(Block);
tool_call_content_item(#{<<"type">> := <<"diff">>} = Item) ->
    Path = maps:get(<<"path">>, Item, <<>>),
    <<"[diff] ", Path/binary>>;
tool_call_content_item(Item) ->
    iolist_to_binary(io_lib:format("~tp", [Item])).

-spec update_text(map()) -> binary().
update_text(Update) ->
    case maps:get(<<"title">>, Update, undefined) of
        Title when is_binary(Title) ->
            Title;
        _ ->
            iolist_to_binary(io_lib:format("~tp", [maps:without([<<"sessionUpdate">>], Update)]))
    end.

-spec nonempty_or_default(binary(), binary()) -> binary().
nonempty_or_default(<<>>, Default) ->
    Default;
nonempty_or_default(Value, _Default) ->
    Value.
