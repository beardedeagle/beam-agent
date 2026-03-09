%%%-------------------------------------------------------------------
%%% @doc EUnit tests for opencode_protocol event normalization.
%%%
%%% Pure unit tests — no processes, no external dependencies.
%%% Tests every SSE event type mapping in the protocol module.
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% message.part.updated — text with delta
%%====================================================================

text_part_with_delta_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{<<"type">> => <<"text">>,
                                   <<"delta">> => <<"Hello">>}}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"Hello">>, maps:get(content, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))).

%%====================================================================
%% message.part.updated — text with no delta (uses text field)
%%====================================================================

text_part_no_delta_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{<<"type">> => <<"text">>,
                                   <<"text">> => <<"Full text">>}}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"Full text">>, maps:get(content, Msg)).

%%====================================================================
%% message.part.updated — reasoning → thinking
%%====================================================================

reasoning_part_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{<<"type">> => <<"reasoning">>,
                                   <<"text">> => <<"I am thinking...">>}}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"I am thinking...">>, maps:get(content, Msg)).

%%====================================================================
%% message.part.updated — tool pending → tool_use
%%====================================================================

tool_part_pending_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{
            <<"type">>  => <<"tool">>,
            <<"state">> => #{
                <<"status">> => <<"pending">>,
                <<"tool">>   => <<"bash">>,
                <<"input">>  => #{<<"cmd">> => <<"ls">>}
            }
        }}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"cmd">> => <<"ls">>}, maps:get(tool_input, Msg)).

%%====================================================================
%% message.part.updated — tool running → tool_use
%%====================================================================

tool_part_running_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{
            <<"type">>  => <<"tool">>,
            <<"state">> => #{
                <<"status">> => <<"running">>,
                <<"tool">>   => <<"read_file">>,
                <<"input">>  => #{<<"path">> => <<"/tmp/foo">>}
            }
        }}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg)).

%%====================================================================
%% message.part.updated — tool completed → tool_result
%%====================================================================

tool_part_completed_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{
            <<"type">>  => <<"tool">>,
            <<"state">> => #{
                <<"status">> => <<"completed">>,
                <<"tool">>   => <<"bash">>,
                <<"output">> => <<"file1.txt\nfile2.txt">>
            }
        }}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"file1.txt\nfile2.txt">>, maps:get(content, Msg)).

%%====================================================================
%% message.part.updated — tool error → error
%%====================================================================

tool_part_error_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{
            <<"type">>  => <<"tool">>,
            <<"state">> => #{
                <<"status">> => <<"error">>,
                <<"error">>  => <<"permission denied">>
            }
        }}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"permission denied">>, maps:get(content, Msg)).

%%====================================================================
%% message.part.updated — step-start → system
%%====================================================================

step_start_part_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{<<"type">> => <<"step-start">>}}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"step_start">>, maps:get(subtype, Msg)).

%%====================================================================
%% message.part.updated — step-finish → system with cost/tokens
%%====================================================================

step_finish_part_test() ->
    Event = #{
        event => <<"message.part.updated">>,
        data  => #{<<"part">> => #{
            <<"type">>   => <<"step-finish">>,
            <<"cost">>   => 0.005,
            <<"tokens">> => #{<<"input">> => 100, <<"output">> => 200}
        }}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"step_finish">>, maps:get(subtype, Msg)),
    ?assertEqual(0.005, maps:get(total_cost_usd, Msg)).

%%====================================================================
%% message.updated with error → error
%%====================================================================

message_updated_with_error_test() ->
    Event = #{
        event => <<"message.updated">>,
        data  => #{
            <<"error">> => #{
                <<"name">> => <<"APIError">>,
                <<"data">> => <<"rate limited">>
            }
        }
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    Content = maps:get(content, Msg),
    ?assert(binary:match(Content, <<"APIError">>) =/= nomatch).

%%====================================================================
%% message.updated without error → raw
%%====================================================================

message_updated_no_error_test() ->
    Event = #{
        event => <<"message.updated">>,
        data  => #{<<"role">> => <<"assistant">>}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(raw, maps:get(type, Msg)).

%%====================================================================
%% session.idle → result
%%====================================================================

session_idle_test() ->
    Event = #{
        event => <<"session.idle">>,
        data  => #{<<"id">> => <<"sess-001">>}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"sess-001">>, maps:get(session_id, Msg)).

%%====================================================================
%% session.error → error
%%====================================================================

session_error_test() ->
    Event = #{
        event => <<"session.error">>,
        data  => #{<<"message">> => <<"server error occurred">>}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"server error occurred">>, maps:get(content, Msg)).

%%====================================================================
%% permission.updated → control_request
%%====================================================================

permission_updated_test() ->
    Event = #{
        event => <<"permission.updated">>,
        data  => #{
            <<"id">>      => <<"perm-123">>,
            <<"request">> => #{<<"tool">> => <<"bash">>,
                               <<"cmd">>  => <<"rm -rf /tmp/test">>}
        }
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(<<"perm-123">>, maps:get(request_id, Msg)),
    ?assert(is_map(maps:get(request, Msg))).

%%====================================================================
%% server.heartbeat → skip
%%====================================================================

server_heartbeat_test() ->
    Event = #{
        event => <<"server.heartbeat">>,
        data  => #{}
    },
    Result = opencode_protocol:normalize_event(Event),
    ?assertEqual(skip, Result).

%%====================================================================
%% server.connected → system
%%====================================================================

server_connected_test() ->
    Event = #{
        event => <<"server.connected">>,
        data  => #{<<"version">> => <<"1.0.0">>}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"connected">>, maps:get(subtype, Msg)).

%%====================================================================
%% Unknown event → raw
%%====================================================================

unknown_event_test() ->
    Event = #{
        event => <<"some.future.event">>,
        data  => #{<<"foo">> => <<"bar">>}
    },
    Msg = opencode_protocol:normalize_event(Event),
    ?assertEqual(raw, maps:get(type, Msg)).

%%====================================================================
%% build_prompt_input
%%====================================================================

build_prompt_input_basic_test() ->
    Body = opencode_protocol:build_prompt_input(<<"Hello">>, #{}),
    Parts = maps:get(<<"parts">>, Body),
    ?assertEqual(1, length(Parts)),
    [Part] = Parts,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Part)),
    ?assertEqual(<<"Hello">>, maps:get(<<"text">>, Part)).

build_prompt_input_with_model_test() ->
    Body = opencode_protocol:build_prompt_input(
        <<"Hi">>,
        #{model => #{<<"id">> => <<"gpt-4">>, <<"providerID">> => <<"openai">>}}),
    ?assertEqual(<<"gpt-4">>, maps:get(<<"modelID">>, Body)),
    ?assertEqual(<<"openai">>, maps:get(<<"providerID">>, Body)).

%%====================================================================
%% build_permission_reply
%%====================================================================

build_permission_reply_allow_test() ->
    Body = opencode_protocol:build_permission_reply(<<"perm-1">>, <<"allow">>),
    ?assertEqual(<<"perm-1">>, maps:get(<<"id">>, Body)),
    ?assertEqual(<<"allow">>, maps:get(<<"decision">>, Body)).

build_permission_reply_deny_test() ->
    Body = opencode_protocol:build_permission_reply(<<"perm-2">>, <<"deny">>),
    ?assertEqual(<<"deny">>, maps:get(<<"decision">>, Body)).

%%====================================================================
%% parse_session
%%====================================================================

parse_session_test() ->
    Raw = #{
        <<"id">>        => <<"sess-abc">>,
        <<"directory">> => <<"/home/user/project">>,
        <<"model">>     => <<"claude-3-5-sonnet">>
    },
    Parsed = opencode_protocol:parse_session(Raw),
    ?assertEqual(<<"sess-abc">>, maps:get(id, Parsed)),
    ?assertEqual(<<"/home/user/project">>, maps:get(directory, Parsed)),
    ?assertEqual(<<"claude-3-5-sonnet">>, maps:get(model, Parsed)),
    ?assertEqual(Raw, maps:get(raw, Parsed)).

%%====================================================================
%% Timestamp is always present
%%====================================================================

timestamp_always_present_test() ->
    Events = [
        #{event => <<"message.part.updated">>,
          data  => #{<<"part">> => #{<<"type">> => <<"text">>,
                                     <<"text">> => <<"hi">>}}},
        #{event => <<"session.idle">>, data => #{}},
        #{event => <<"server.heartbeat">>, data => #{}}
    ],
    lists:foreach(fun(E) ->
        Result = opencode_protocol:normalize_event(E),
        case Result of
            skip -> ok;
            Msg  -> ?assert(is_integer(maps:get(timestamp, Msg)))
        end
    end, Events).
