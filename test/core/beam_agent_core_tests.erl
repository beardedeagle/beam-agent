%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_core normalization cleanup behavior.
%%%-------------------------------------------------------------------
-module(beam_agent_core_tests).

-include_lib("eunit/include/eunit.hrl").

bare_control_type_normalizes_to_raw_test() ->
    Msg = beam_agent_core:normalize_message(#{
        <<"type">> => <<"control">>,
        <<"request_id">> => <<"raw-control">>,
        <<"content">> => <<"ignored">>
    }),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(<<"control">>, maps:get(<<"type">>, maps:get(raw, Msg))).

result_messages_require_result_field_for_normalized_content_test() ->
    Msg = beam_agent_core:normalize_message(#{
        <<"type">> => <<"result">>,
        <<"content">> => <<"raw-content-field">>
    }),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<>>, maps:get(content, Msg)),
    ?assertEqual(<<"raw-content-field">>, maps:get(<<"content">>, maps:get(raw, Msg))).

assistant_message_accepts_nested_message_shape_test() ->
    Msg = beam_agent_core:normalize_message(#{
        <<"type">> => <<"assistant">>,
        <<"message">> => #{
            <<"id">> => <<"msg_nested">>,
            <<"model">> => <<"claude-sonnet">>,
            <<"stop_reason">> => <<"end_turn">>,
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"hello from nested">>}
            ]
        }
    }),
    ?assertEqual(assistant, maps:get(type, Msg)),
    ?assertEqual(<<"msg_nested">>, maps:get(message_id, Msg)),
    ?assertEqual(<<"claude-sonnet">>, maps:get(model, Msg)),
    ?assertEqual(end_turn, maps:get(stop_reason_atom, Msg)),
    [Block] = maps:get(content_blocks, Msg),
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(<<"hello from nested">>, maps:get(text, Block)).

assistant_message_prefers_top_level_content_over_nested_message_shape_test() ->
    Msg = beam_agent_core:normalize_message(#{
        <<"type">> => <<"assistant">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"top-level">>}
        ],
        <<"message">> => #{
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"nested">>}
            ]
        }
    }),
    [Block] = maps:get(content_blocks, Msg),
    ?assertEqual(<<"top-level">>, maps:get(text, Block)).
