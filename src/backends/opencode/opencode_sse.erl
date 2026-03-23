-module(opencode_sse).
-moduledoc false.
-export([new_state/0,new_state/1,parse_chunk/2,buffer_size/1]).
-export_type([sse_event/0,parse_state/0]).
-type sse_event() ::
          #{data := binary(), event => binary(), id => binary()}.
-record(evt,{event_type = undefined :: binary() | undefined,
             event_id = undefined :: binary() | undefined,
             data_lines = [] :: [binary()]}).
-opaque parse_state() :: {binary(), #evt{}, pos_integer()}.

%% Default maximum number of data: lines per SSE event.
%% Assuming ~1 KB per line, 10 000 lines ≈ 10 MB — prevents unbounded
%% per-event accumulation when the outer buffer_max guard does not apply.
-define(DEFAULT_MAX_DATA_LINES, 10000).

-spec new_state() -> parse_state().
new_state() ->
    {<<>>, #evt{}, ?DEFAULT_MAX_DATA_LINES}.

-spec new_state(map()) -> parse_state().
new_state(Opts) ->
    MaxDataLines = maps:get(max_data_lines, Opts, ?DEFAULT_MAX_DATA_LINES),
    {<<>>, #evt{}, MaxDataLines}.
-spec buffer_size(parse_state()) -> non_neg_integer().
buffer_size({Buffer, _Evt, _MaxDataLines}) ->
    byte_size(Buffer).
-spec parse_chunk(binary(), parse_state()) ->
                     {[sse_event()], parse_state()}.
parse_chunk(Chunk, {Buffer, Evt, MaxDataLines}) ->
    Full = <<Buffer/binary,Chunk/binary>>,
    {Lines, Remaining} = split_lines(Full),
    {Events, FinalEvt} = process_lines(Lines, Evt, [], MaxDataLines),
    {Events, {Remaining, FinalEvt, MaxDataLines}}.
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
-spec process_lines([binary()], #evt{}, [sse_event()], pos_integer()) ->
                       {[sse_event()], #evt{}}.
process_lines([], Evt, Events, _MaxDataLines) ->
    {lists:reverse(Events), Evt};
process_lines([Line | Rest], Evt, Events, MaxDataLines) ->
    case Line of
        <<>> ->
            case flush_event(Evt) of
                skip ->
                    process_lines(Rest, #evt{}, Events, MaxDataLines);
                Event ->
                    process_lines(Rest, #evt{}, [Event | Events], MaxDataLines)
            end;
        <<$:,_/binary>> ->
            process_lines(Rest, Evt, Events, MaxDataLines);
        _ ->
            Evt1 = apply_field(Line, Evt, MaxDataLines),
            process_lines(Rest, Evt1, Events, MaxDataLines)
    end.
-spec apply_field(binary(), #evt{}, pos_integer()) -> #evt{}.
apply_field(Line, Evt, MaxDataLines) ->
    case binary:split(Line, <<": ">>) of
        [Field, Value] ->
            apply_named_field(Field, Value, Evt, MaxDataLines);
        [Field] ->
            apply_named_field(Field, <<>>, Evt, MaxDataLines);
        [Field | _Rest] ->
            apply_named_field(Field, <<>>, Evt, MaxDataLines)
    end.
-spec apply_named_field(binary(), binary(), #evt{}, pos_integer()) -> #evt{}.
apply_named_field(<<"data">>, Value, Evt, MaxDataLines) ->
    CurrentCount = length(Evt#evt.data_lines),
    case CurrentCount >= MaxDataLines of
        true ->
            logger:warning(
                "opencode_sse: discarding SSE event — data: line count ~p "
                "exceeded max_data_lines limit ~p",
                [CurrentCount + 1, MaxDataLines]),
            #evt{};
        false ->
            Evt#evt{data_lines = [Value | Evt#evt.data_lines]}
    end;
apply_named_field(<<"event">>, Value, Evt, _MaxDataLines) ->
    Evt#evt{event_type = Value};
apply_named_field(<<"id">>, Value, Evt, _MaxDataLines) ->
    Evt#evt{event_id = Value};
apply_named_field(<<"retry">>, _Value, Evt, _MaxDataLines) ->
    %% The SSE spec (https://html.spec.whatwg.org/multipage/server-sent-events.html)
    %% defines the retry field as the reconnection delay the client should use
    %% after a connection is lost.  This SDK does not implement auto-reconnection,
    %% so the field is intentionally ignored here.
    %%
    %% If reconnection is added in the future, the retry value MUST be validated
    %% before use:
    %%   - Enforce a minimum floor (e.g. 1 000 ms) to prevent a malicious
    %%     server from issuing `retry:0` and causing a tight reconnect loop.
    %%   - Enforce a maximum cap (e.g. 300 000 ms / 5 min) to prevent
    %%     a server from permanently disabling reconnection with a huge value.
    Evt;
apply_named_field(_Other, _Value, Evt, _MaxDataLines) ->
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

