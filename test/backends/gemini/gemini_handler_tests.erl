%%%-------------------------------------------------------------------
%%% @doc EUnit tests for gemini_session_handler pure-function coverage.
%%%
%%% Tests handle_set_model/2, agentCapabilities parsing via
%%% build_session_info/1, and _meta.quota token usage extraction.
%%% No mocks, no processes.
%%% @end
%%%-------------------------------------------------------------------
-module(gemini_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% handle_set_model/2 — no session (stores locally, no send action)
%%====================================================================

set_model_no_session_returns_ok_tuple_test() ->
    HState = minimal_hstate(),
    Model = <<"gemini-2.0-flash">>,
    Result = gemini_session_handler:handle_set_model(Model, HState),
    ?assertMatch({ok, Model, [], _}, Result).

set_model_no_session_returns_requested_model_test() ->
    HState = minimal_hstate(),
    Model = <<"gemini-2.5-pro">>,
    {ok, Returned, _, _} =
        gemini_session_handler:handle_set_model(Model, HState),
    ?assertEqual(Model, Returned).

set_model_no_session_empty_actions_test() ->
    HState = minimal_hstate(),
    {ok, _, Actions, _} =
        gemini_session_handler:handle_set_model(<<"gemini-2.0-flash">>, HState),
    ?assertEqual([], Actions).

%%====================================================================
%% set_model_params wire encoding (validates JSON-RPC params shape)
%%====================================================================

set_model_params_shape_test() ->
    Params = beam_agent_gemini_wire:set_model_params(
                 <<"sess-42">>, <<"gemini-2.5-pro">>),
    ?assertEqual(<<"sess-42">>, maps:get(<<"sessionId">>, Params)),
    ?assertEqual(<<"gemini-2.5-pro">>, maps:get(<<"modelId">>, Params)),
    ?assertEqual(2, maps:size(Params)).

%%====================================================================
%% agentCapabilities — build_session_info exposes capabilities
%%====================================================================

session_info_contains_agent_capabilities_test() ->
    HState = minimal_hstate(),
    Info = gemini_session_handler:build_session_info(HState),
    ?assert(maps:is_key(agent_capabilities, Info)).

session_info_default_agent_capabilities_empty_test() ->
    %% Before init handshake, agent_capabilities is the record default #{}
    HState = minimal_hstate(),
    Info = gemini_session_handler:build_session_info(HState),
    ?assertEqual(#{}, maps:get(agent_capabilities, Info)).

%%====================================================================
%% _meta.quota token usage — prompt_result_message/2
%%====================================================================

prompt_result_with_full_token_usage_test() ->
    Response = #{
        <<"stopReason">> => <<"end_turn">>,
        <<"_meta">> => #{
            <<"quota">> => #{
                <<"token_count">> => #{
                    <<"input_tokens">> => 150,
                    <<"output_tokens">> => 42
                }
            }
        }
    },
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assert(maps:is_key(token_usage, Msg)),
    Usage = maps:get(token_usage, Msg),
    ?assertEqual(150, maps:get(input_tokens, Usage)),
    ?assertEqual(42, maps:get(output_tokens, Usage)).

prompt_result_without_meta_no_token_usage_test() ->
    Response = #{<<"stopReason">> => <<"end_turn">>},
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertNot(maps:is_key(token_usage, Msg)).

prompt_result_empty_quota_no_token_usage_test() ->
    Response = #{
        <<"stopReason">> => <<"end_turn">>,
        <<"_meta">> => #{<<"quota">> => #{}}
    },
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assertNot(maps:is_key(token_usage, Msg)).

prompt_result_partial_input_only_test() ->
    Response = #{
        <<"stopReason">> => <<"end_turn">>,
        <<"_meta">> => #{
            <<"quota">> => #{
                <<"token_count">> => #{
                    <<"input_tokens">> => 100
                }
            }
        }
    },
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assert(maps:is_key(token_usage, Msg)),
    Usage = maps:get(token_usage, Msg),
    ?assertEqual(100, maps:get(input_tokens, Usage)),
    ?assertEqual(error, maps:find(output_tokens, Usage)).

prompt_result_partial_output_only_test() ->
    Response = #{
        <<"stopReason">> => <<"end_turn">>,
        <<"_meta">> => #{
            <<"quota">> => #{
                <<"token_count">> => #{
                    <<"output_tokens">> => 77
                }
            }
        }
    },
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assert(maps:is_key(token_usage, Msg)),
    Usage = maps:get(token_usage, Msg),
    ?assertEqual(77, maps:get(output_tokens, Usage)),
    ?assertEqual(error, maps:find(input_tokens, Usage)).

prompt_result_preserves_stop_reason_with_meta_test() ->
    Response = #{
        <<"stopReason">> => <<"max_tokens">>,
        <<"_meta">> => #{
            <<"quota">> => #{
                <<"token_count">> => #{
                    <<"input_tokens">> => 10,
                    <<"output_tokens">> => 20
                }
            }
        }
    },
    Msg = beam_agent_gemini_translate:prompt_result_message(<<"s1">>, Response),
    ?assertEqual(<<"max_tokens">>, maps:get(stop_reason, Msg)).

%%====================================================================
%% Helpers
%%====================================================================

%% Build a minimal #hstate{} via init_handler to avoid coupling to
%% the record definition. init_handler is a pure function that returns
%% {ok, #{handler_state := HState}}. The transport is never started.
minimal_hstate() ->
    {ok, #{handler_state := HState}} =
        gemini_session_handler:init_handler(#{
            cli_path => "/nonexistent/gemini"
        }),
    HState.
