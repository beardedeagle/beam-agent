-module(beam_agent_error_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit: categorize/1 — passthrough when category already set
%%====================================================================

categorize_passthrough_existing_category_test() ->
    Msg = #{type => error, content => <<"rate limit">>, category => auth_expired},
    ?assertEqual(Msg, beam_agent_core:categorize(Msg)).

categorize_infers_from_content_test() ->
    Msg = #{type => error, content => <<"rate limit exceeded">>},
    Result = beam_agent_core:categorize(Msg),
    ?assertEqual(rate_limit, maps:get(category, Result)).

categorize_unknown_when_no_content_test() ->
    Msg = #{type => error},
    Result = beam_agent_core:categorize(Msg),
    ?assertEqual(unknown, maps:get(category, Result)).

categorize_unknown_for_unrecognized_content_test() ->
    Msg = #{type => error, content => <<"something completely unrelated">>},
    Result = beam_agent_core:categorize(Msg),
    ?assertEqual(unknown, maps:get(category, Result)).

categorize_passes_non_error_unchanged_test() ->
    Msg = #{type => text, content => <<"hello">>},
    ?assertEqual(Msg, beam_agent_core:categorize(Msg)).

categorize_passes_result_unchanged_test() ->
    Msg = #{type => result, content => <<"done">>},
    ?assertEqual(Msg, beam_agent_core:categorize(Msg)).

%%====================================================================
%% EUnit: infer_category/1 — rate_limit patterns
%%====================================================================

infer_rate_limit_text_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"rate limit exceeded">>)).

infer_rate_limit_underscore_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"rate_limit">>)).

infer_rate_limit_joined_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"ratelimit">>)).

infer_rate_limit_too_many_requests_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"too many requests">>)).

infer_rate_limit_429_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"HTTP 429 error">>)).

infer_rate_limit_throttled_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"request throttled">>)).

infer_rate_limit_throttling_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"throttling applied">>)).

infer_rate_limit_case_insensitive_test() ->
    ?assertEqual(rate_limit, beam_agent_core:infer_category(<<"Rate Limit Exceeded">>)).

%%====================================================================
%% EUnit: infer_category/1 — subscription_exhausted patterns
%%====================================================================

infer_subscription_quota_exceeded_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"quota exceeded">>)).

infer_subscription_quota_underscore_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"quota_exceeded for account">>)).

infer_subscription_usage_cap_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"usage cap reached">>)).

infer_subscription_usage_limit_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"usage limit hit">>)).

infer_subscription_plan_limit_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"plan limit exceeded">>)).

infer_subscription_billing_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"billing issue detected">>)).

infer_subscription_credits_exhausted_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"credits exhausted">>)).

infer_subscription_tokens_exhausted_test() ->
    ?assertEqual(subscription_exhausted,
        beam_agent_core:infer_category(<<"tokens exhausted">>)).

%%====================================================================
%% EUnit: infer_category/1 — context_exceeded patterns
%%====================================================================

infer_context_length_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"context length exceeded">>)).

infer_context_window_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"context window full">>)).

infer_context_underscore_length_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"context_length overflow">>)).

infer_context_underscore_window_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"context_window exceeded">>)).

infer_context_token_limit_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"token limit reached">>)).

infer_context_too_many_tokens_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"too many tokens in request">>)).

infer_context_maximum_context_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"maximum context reached">>)).

infer_context_max_tokens_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"max_tokens exceeded">>)).

infer_context_input_too_long_test() ->
    ?assertEqual(context_exceeded,
        beam_agent_core:infer_category(<<"input too long for model">>)).

%%====================================================================
%% EUnit: infer_category/1 — auth_expired patterns
%%====================================================================

infer_auth_unauthorized_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"unauthorized access">>)).

infer_auth_unauthenticated_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"unauthenticated request">>)).

infer_auth_invalid_api_key_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"invalid api key">>)).

infer_auth_invalid_api_key_underscore_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"invalid_api_key">>)).

infer_auth_api_key_expired_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"api key expired">>)).

infer_auth_token_expired_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"token expired">>)).

infer_auth_access_denied_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"access denied">>)).

infer_auth_forbidden_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"forbidden resource">>)).

infer_auth_401_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"401 Unauthorized">>)).

infer_auth_403_test() ->
    ?assertEqual(auth_expired,
        beam_agent_core:infer_category(<<"403 Forbidden">>)).

%%====================================================================
%% EUnit: infer_category/1 — server_error patterns
%%====================================================================

infer_server_internal_server_error_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"internal server error">>)).

infer_server_server_error_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"server error occurred">>)).

infer_server_service_unavailable_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"service unavailable">>)).

infer_server_bad_gateway_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"bad gateway">>)).

infer_server_gateway_timeout_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"gateway timeout">>)).

infer_server_overloaded_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"server overloaded">>)).

infer_server_500_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"500 Internal Server Error">>)).

infer_server_502_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"502 Bad Gateway">>)).

infer_server_503_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"503 Service Unavailable">>)).

infer_server_504_test() ->
    ?assertEqual(server_error,
        beam_agent_core:infer_category(<<"504 Gateway Timeout">>)).

%%====================================================================
%% EUnit: infer_category/1 — unknown / edge cases
%%====================================================================

infer_unknown_for_unrecognized_test() ->
    ?assertEqual(unknown, beam_agent_core:infer_category(<<"something else">>)).

infer_unknown_for_empty_binary_test() ->
    ?assertEqual(unknown, beam_agent_core:infer_category(<<>>)).

infer_unknown_for_non_binary_test() ->
    ?assertEqual(unknown, beam_agent_core:infer_category(12345)).

infer_unknown_for_atom_test() ->
    ?assertEqual(unknown, beam_agent_core:infer_category(some_atom)).

infer_unknown_for_list_test() ->
    ?assertEqual(unknown, beam_agent_core:infer_category("a string list")).

%%====================================================================
%% EUnit: infer_category/1 — priority ordering
%%====================================================================

%% rate_limit takes priority over other patterns that might partially match
infer_priority_rate_limit_over_server_test() ->
    ?assertEqual(rate_limit,
        beam_agent_core:infer_category(<<"rate limit: 429 server error">>)).

%%====================================================================
%% EUnit: enrich/2 — protocol-level extraction from Raw
%%====================================================================

enrich_extracts_binary_category_test() ->
    Msg = #{type => error, content => <<"something">>},
    Raw = #{<<"category">> => <<"rate_limit">>},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(rate_limit, maps:get(category, Result)).

enrich_extracts_atom_category_test() ->
    Msg = #{type => error, content => <<"something">>},
    Raw = #{<<"category">> => server_error},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(server_error, maps:get(category, Result)).

enrich_falls_back_to_inference_test() ->
    Msg = #{type => error, content => <<"rate limit exceeded">>},
    Raw = #{},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(rate_limit, maps:get(category, Result)).

enrich_extracts_retry_after_integer_test() ->
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"retry_after">> => 30},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(30, maps:get(retry_after, Result)).

enrich_extracts_retry_after_binary_test() ->
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"retry_after">> => <<"60">>},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(60, maps:get(retry_after, Result)).

enrich_skips_invalid_retry_after_test() ->
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"retry_after">> => <<"not-a-number">>},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertNot(maps:is_key(retry_after, Result)).

enrich_skips_zero_retry_after_test() ->
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"retry_after">> => 0},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertNot(maps:is_key(retry_after, Result)).

enrich_skips_negative_retry_after_test() ->
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"retry_after">> => -5},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertNot(maps:is_key(retry_after, Result)).

enrich_passes_non_error_unchanged_test() ->
    Msg = #{type => text, content => <<"hello">>},
    Raw = #{<<"category">> => <<"rate_limit">>},
    ?assertEqual(Msg, beam_agent_core:enrich_error(Msg, Raw)).

enrich_protocol_category_wins_over_inference_test() ->
    %% Protocol sets auth_expired, but content says "rate limit" —
    %% protocol-level category should prevail since categorize/1
    %% sees it already set and passes through.
    Msg = #{type => error, content => <<"rate limit exceeded">>},
    Raw = #{<<"category">> => <<"auth_expired">>},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    ?assertEqual(auth_expired, maps:get(category, Result)).

enrich_unknown_binary_category_test() ->
    Msg = #{type => error, content => <<"something">>},
    Raw = #{<<"category">> => <<"not_a_real_category">>},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    %% parse_category_bin returns unknown for unrecognized binaries,
    %% then categorize/1 sees category already set and passes through.
    ?assertEqual(unknown, maps:get(category, Result)).

enrich_undefined_atom_category_ignored_test() ->
    %% undefined atom in category is treated as missing
    Msg = #{type => error, content => <<"rate limit">>},
    Raw = #{<<"category">> => undefined},
    Result = beam_agent_core:enrich_error(Msg, Raw),
    %% Falls through to infer_category
    ?assertEqual(rate_limit, maps:get(category, Result)).

%%====================================================================
%% EUnit: parse_retry_after/1
%%====================================================================

parse_retry_after_positive_integer_test() ->
    ?assertEqual(30, beam_agent_core:parse_retry_after(30)).

parse_retry_after_binary_digits_test() ->
    ?assertEqual(45, beam_agent_core:parse_retry_after(<<"45">>)).

parse_retry_after_float_test() ->
    ?assertEqual(3, beam_agent_core:parse_retry_after(2.5)).

parse_retry_after_float_ceil_test() ->
    ?assertEqual(10, beam_agent_core:parse_retry_after(9.1)).

parse_retry_after_zero_integer_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(0)).

parse_retry_after_negative_integer_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(-10)).

parse_retry_after_zero_binary_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(<<"0">>)).

parse_retry_after_negative_binary_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(<<"-5">>)).

parse_retry_after_non_numeric_binary_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(<<"abc">>)).

parse_retry_after_undefined_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(undefined)).

parse_retry_after_atom_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(none)).

parse_retry_after_zero_float_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(0.0)).

parse_retry_after_negative_float_test() ->
    ?assertEqual(undefined, beam_agent_core:parse_retry_after(-1.5)).

parse_retry_after_large_integer_test() ->
    ?assertEqual(3600, beam_agent_core:parse_retry_after(3600)).
