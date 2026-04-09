-module(gemini_cli_client_supported_models_tests).
-behaviour(gen_statem).

-include_lib("eunit/include/eunit.hrl").

-export([callback_mode/0, init/1, handle_event/4]).

supported_models_retries_until_models_are_available_test() ->
    {ok, Session} =
        start_fake_session(
          [#{init_response => #{<<"models">> => []}},
           #{init_response => #{<<"models">> => [<<"gemini-2.5-pro">>]}}],
          [initializing]),
    try
        ?assertEqual(
           {ok, [<<"gemini-2.5-pro">>]},
           gemini_cli_client:supported_models(Session))
    after
        stop_fake_session(Session)
    end.

supported_models_returns_unexpected_shape_error_test() ->
    {ok, Session} =
        start_fake_session(
          [#{init_response => #{<<"models">> => #{<<"unexpected">> => true}}}],
          [ready]),
    try
        ?assertMatch(
           {error, {unexpected_models_shape, _}},
           gemini_cli_client:supported_models(Session))
    after
        stop_fake_session(Session)
    end.

wait_for_supported_models_clamps_sleep_to_remaining_timeout_test() ->
    {ok, Session} =
        start_fake_session(
          [#{init_response => #{<<"models">> => []}}],
          [initializing]),
    Start = erlang:monotonic_time(millisecond),
    try
        ?assertEqual(
           {ok, []},
           gemini_cli_client:wait_for_supported_models(Session, 20, 100))
    after
        stop_fake_session(Session)
    end,
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(Elapsed < 99).

wait_for_supported_models_bounds_internal_calls_by_remaining_budget_test() ->
    {ok, Session} =
        start_fake_session(
          [#{init_response => #{<<"models">> => []}}],
          [initializing],
          200),
    Start = erlang:monotonic_time(millisecond),
    Result = gemini_cli_client:wait_for_supported_models(Session, 20, 100),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assertEqual({error, timeout}, Result),
    stop_fake_session(Session),
    ?assert(Elapsed < 180).

callback_mode() ->
    handle_event_function.

init(#{session_infos := SessionInfos, healths := Healths} = Args) ->
    {ok, running,
     #{session_infos => SessionInfos,
       last_session_info => last_or_default(SessionInfos, #{}),
       healths => Healths,
       delay_ms => maps:get(delay_ms, Args, 0),
       last_health => last_or_default(Healths, ready)}}.

handle_event({call, From}, session_info, running, State) ->
    {SessionInfo, NextState} =
        next_sequence_value(session_infos, last_session_info, State),
    maybe_delay_reply(State),
    {keep_state, NextState, [{reply, From, {ok, SessionInfo}}]};
handle_event({call, From}, health, running, State) ->
    {Health, NextState} =
        next_sequence_value(healths, last_health, State),
    maybe_delay_reply(State),
    {keep_state, NextState, [{reply, From, Health}]};
handle_event(_EventType, _EventContent, running, State) ->
    {keep_state, State}.

start_fake_session(SessionInfos, Healths) ->
    start_fake_session(SessionInfos, Healths, 0).

start_fake_session(SessionInfos, Healths, DelayMs) ->
    gen_statem:start_link(?MODULE,
                          #{session_infos => SessionInfos,
                            healths => Healths,
                            delay_ms => DelayMs},
                          []).

stop_fake_session(Session) ->
    gen_statem:stop(Session).

next_sequence_value(Key, LastKey, State) ->
    case maps:get(Key, State) of
        [Value | Rest] ->
            {Value, State#{Key => Rest, LastKey => Value}};
        [] ->
            {maps:get(LastKey, State), State}
    end.

last_or_default([], Default) ->
    Default;
last_or_default(Values, _Default) ->
    lists:last(Values).

maybe_delay_reply(#{delay_ms := DelayMs}) when is_integer(DelayMs), DelayMs > 0 ->
    timer:sleep(DelayMs);
maybe_delay_reply(_) ->
    ok.
