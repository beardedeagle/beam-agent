-module(opencode_sse).
-export([new_state/0,parse_chunk/2,buffer_size/1]).
-export_type([sse_event/0,parse_state/0]).
-type sse_event() ::
          #{data := binary(), event => binary(), id => binary()}.
-opaque parse_state() :: {binary(), term()}.
-record(evt,{event_type = undefined :: binary() | undefined,
             event_id = undefined :: binary() | undefined,
             data_lines = [] :: [binary()]}).
-spec new_state() -> parse_state().
new_state() ->
    {<<>>, #evt{}}.
-spec buffer_size(parse_state()) -> non_neg_integer().
buffer_size({Buffer, _Evt}) ->
    byte_size(Buffer).
-spec parse_chunk(binary(), parse_state()) ->
                     {[sse_event()], parse_state()}.
parse_chunk(Chunk, {Buffer, Evt}) ->
    Full = <<Buffer/binary,Chunk/binary>>,
    {Lines, Remaining} = split_lines(Full),
    {Events, FinalEvt} = process_lines(Lines, Evt, []),
    {Events, {Remaining, FinalEvt}}.
-spec split_lines(binary()) -> {[binary()], binary()}.
split_lines(Data) ->
    split_lines(Data, [], <<>>).
-spec split_lines(binary(), [binary()], binary()) ->
                     {[binary()], binary()}.
split_lines(<<>>, Lines, Current) ->
    {lists:reverse(Lines), Current};
split_lines(<<$\r,$\n,Rest/binary>>, Lines, Current) ->
    split_lines(Rest, [Current | Lines], <<>>);
split_lines(<<$\n,Rest/binary>>, Lines, Current) ->
    split_lines(Rest, [Current | Lines], <<>>);
split_lines(<<Byte,Rest/binary>>, Lines, Current) ->
    split_lines(Rest, Lines, <<Current/binary,Byte>>).
-spec process_lines([binary()], #evt{}, [sse_event()]) ->
                       {[sse_event()], #evt{}}.
process_lines([], Evt, Events) ->
    {lists:reverse(Events), Evt};
process_lines([Line | Rest], Evt, Events) ->
    case Line of
        <<>> ->
            case flush_event(Evt) of
                skip ->
                    process_lines(Rest, #evt{}, Events);
                Event ->
                    process_lines(Rest, #evt{}, [Event | Events])
            end;
        <<$:,_/binary>> ->
            process_lines(Rest, Evt, Events);
        _ ->
            Evt1 = apply_field(Line, Evt),
            process_lines(Rest, Evt1, Events)
    end.
-spec apply_field(binary(), #evt{}) -> #evt{}.
apply_field(Line, Evt) ->
    case binary:split(Line, <<": ">>) of
        [Field, Value] ->
            apply_named_field(Field, Value, Evt);
        [Field] ->
            apply_named_field(Field, <<>>, Evt);
        [Field | _Rest] ->
            apply_named_field(Field, <<>>, Evt)
    end.
-spec apply_named_field(binary(), binary(), #evt{}) -> #evt{}.
apply_named_field(<<"data">>, Value, Evt) ->
    Evt#evt{data_lines = [Value | Evt#evt.data_lines]};
apply_named_field(<<"event">>, Value, Evt) ->
    Evt#evt{event_type = Value};
apply_named_field(<<"id">>, Value, Evt) ->
    Evt#evt{event_id = Value};
apply_named_field(<<"retry">>, _Value, Evt) ->
    Evt;
apply_named_field(_Other, _Value, Evt) ->
    Evt.
-spec flush_event(#evt{}) -> sse_event() | skip.
flush_event(#evt{data_lines = []}) ->
    skip;
flush_event(#evt{data_lines = DataLines,
                 event_type = EventType,
                 event_id = EventId}) ->
    Data = join_data_lines(lists:reverse(DataLines)),
    Base = #{data => Data},
    M0 =
        case EventType of
            undefined ->
                Base;
            ET ->
                Base#{event => ET}
        end,
    case EventId of
        undefined ->
            M0;
        EId ->
            M0#{id => EId}
    end.
-spec join_data_lines([binary()]) -> binary().
join_data_lines([]) ->
    <<>>;
join_data_lines([Single]) ->
    Single;
join_data_lines(Lines) ->
    lists:foldl(fun(Line, <<>>) ->
                       Line;
                   (Line, Acc) ->
                       <<Acc/binary,$\n,Line/binary>>
                end,
                <<>>, Lines).

