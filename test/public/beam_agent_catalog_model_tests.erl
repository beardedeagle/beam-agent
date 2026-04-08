-module(beam_agent_catalog_model_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_model_list_result_flattens_binary_data_envelope_test() ->
    Models = [#{<<"modelId">> => <<"gpt-5">>}],
    ?assertEqual({ok, Models},
                 beam_agent_catalog:normalize_model_list_result(
                     {ok, #{<<"data">> => Models}})).

normalize_model_list_result_flattens_binary_models_envelope_test() ->
    Models = [#{<<"modelId">> => <<"gpt-5">>}],
    ?assertEqual({ok, Models},
                 beam_agent_catalog:normalize_model_list_result(
                     {ok, #{<<"models">> => Models}})).

normalize_model_list_result_keeps_list_results_test() ->
    Models = [#{<<"modelId">> => <<"gpt-5">>}],
    ?assertEqual({ok, Models},
                 beam_agent_catalog:normalize_model_list_result({ok, Models})).

maybe_fallback_model_list_uses_supported_models_on_session_error_test() ->
    Models = [#{<<"modelId">> => <<"gpt-5">>}],
    ?assertEqual(
        {ok, #{<<"models">> => Models}},
        beam_agent_catalog:maybe_fallback_model_list(
            {error, session_error},
            fun() -> {ok, #{<<"models">> => Models}} end)).

maybe_fallback_model_list_keeps_native_error_when_fallback_fails_test() ->
    ?assertEqual(
        {error, session_error},
        beam_agent_catalog:maybe_fallback_model_list(
            {error, session_error},
            fun() -> {error, reconnecting} end)).

maybe_fallback_model_list_keeps_native_error_when_fallback_exits_test() ->
    ?assertEqual(
        {error, session_error},
        beam_agent_catalog:maybe_fallback_model_list(
            {error, session_error},
            fun() -> exit(timeout) end)).
