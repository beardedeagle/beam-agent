-module(beam_agent_gemini_reverse_requests).
-moduledoc false.

-dialyzer({no_underspecs, [permission_response/3, selected/1, cancelled/0]}).

-export([permission_response/3]).

-spec permission_response(binary(), map(), [map()]) -> map().
permission_response(SessionId, ToolCall, Options)
  when is_binary(SessionId), is_map(ToolCall), is_list(Options) ->
    Method = maps:get(<<"kind">>, ToolCall, <<"tool">>),
    Context = #{
        source => gemini_acp,
        tool_call_id => maps:get(<<"toolCallId">>, ToolCall, <<>>),
        options => Options
    },
    Decision = beam_agent_control_core:request_approval(SessionId, Method, ToolCall, Context),
    decision_to_response(Decision, Options).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec decision_to_response(accept | accept_for_session | decline | cancel, [map()]) -> map().
decision_to_response(accept, Options) ->
    selected(first_matching_option(Options, [<<"allow_once">>, <<"allow_always">>]));
decision_to_response(accept_for_session, Options) ->
    selected(first_matching_option(Options, [<<"allow_always">>, <<"allow_once">>]));
decision_to_response(cancel, _Options) ->
    cancelled();
decision_to_response(decline, Options) ->
    selected(first_matching_option(Options, [<<"reject_once">>, <<"reject_always">>])).

-spec selected(binary()) -> map().
selected(OptionId) when is_binary(OptionId), byte_size(OptionId) > 0 ->
    #{
        <<"outcome">> => #{
            <<"outcome">> => <<"selected">>,
            <<"optionId">> => OptionId
        }
    };
selected(_) ->
    cancelled().

-spec cancelled() -> map().
cancelled() ->
    #{<<"outcome">> => #{<<"outcome">> => <<"cancelled">>}}.

-spec first_matching_option([map()], [binary()]) -> binary().
first_matching_option(Options, PreferredKinds) ->
    case lists:dropwhile(fun(Option) ->
             not option_matches(Option, PreferredKinds)
         end, Options) of
        [Option | _] ->
            maps:get(<<"optionId">>, Option, <<>>);
        [] ->
            case Options of
                [Option | _] ->
                    maps:get(<<"optionId">>, Option, <<>>);
                [] ->
                    <<>>
            end
    end.

-spec option_matches(map(), [binary()]) -> boolean().
option_matches(Option, PreferredKinds) when is_map(Option), is_list(PreferredKinds) ->
    Kind = maps:get(<<"kind">>, Option, undefined),
    lists:any(fun(Expected) -> Expected =:= Kind end, PreferredKinds);
option_matches(_, _) ->
    false.
