%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_transport_utils hardening.
%%%
%%% Tests cover:
%%%   - L3: logger:warning emitted when AllowInsecure=true
%%%   - tls_client_opts returns ok when AllowInsecure=true
%%%   - tls_client_opts returns error for unsafe custom opts when
%%%     AllowInsecure=false
%%%   - no warning when AllowInsecure=false with safe opts
%%%
%%% The warning test uses the OTP logger handler mechanism to capture
%%% log messages without mocks: we install a temporary logger handler
%%% that collects warning-level messages, call tls_client_opts with
%%% AllowInsecure=true, then verify the expected warning was emitted.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_transport_utils_tests).

-include_lib("eunit/include/eunit.hrl").

%% OTP logger handler callbacks
-export([log/2]).

%%====================================================================
%% L3: insecure TLS warning
%%====================================================================

insecure_tls_warning_test_() ->
    {"tls_client_opts emits warning when AllowInsecure=true",
     {setup,
      fun setup_log_capture/0,
      fun cleanup_log_capture/1,
      fun(HandlerId) -> [
          {"warning logged for AllowInsecure=true",
           fun() -> test_insecure_tls_warning(HandlerId) end},
          {"no warning logged for AllowInsecure=false",
           fun() -> test_no_warning_when_secure(HandlerId) end}
      ] end}}.

test_insecure_tls_warning(HandlerId) ->
    %% Call with AllowInsecure=true to trigger the warning path.
    %% Pass {allow_insecure_tls, true} in Custom so the unsafe check passes.
    {ok, _Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.com",
        [{verify, verify_none}, {allow_insecure_tls, true}],
        true
    ),
    %% Give logger a moment to deliver the message synchronously
    %% (OTP logger handlers are called in the calling process context
    %%  for synchronous handlers, so no sleep needed — but we flush
    %%  just in case).
    Warnings = collect_warnings(HandlerId),
    ?assert(lists:any(
        fun(Msg) -> string:find(Msg, "MITM") =/= nomatch end,
        Warnings
    )).

test_no_warning_when_secure(HandlerId) ->
    %% Flush any warnings accumulated by earlier sub-tests
    _ = collect_warnings(HandlerId),
    %% Baseline: safe opts, AllowInsecure=false — no warning
    {ok, _Opts} = beam_agent_transport_utils:tls_client_opts(
        "example.com",
        [],
        false
    ),
    Warnings = collect_warnings(HandlerId),
    ?assertEqual([], [W || W <- Warnings,
                           string:find(W, "MITM") =/= nomatch]).

%%====================================================================
%% tls_client_opts correctness (no logger interaction)
%%====================================================================

allow_insecure_returns_ok_test() ->
    %% With AllowInsecure=true, unsafe opts are permitted
    Result = beam_agent_transport_utils:tls_client_opts(
        "host.example.com",
        [{verify, verify_none}, {allow_insecure_tls, true}],
        true
    ),
    ?assertMatch({ok, _}, Result).

safe_opts_returns_ok_test() ->
    %% Default safe opts, no insecure flag
    Result = beam_agent_transport_utils:tls_client_opts(
        "host.example.com",
        [],
        false
    ),
    ?assertMatch({ok, _}, Result).

unsafe_opts_without_allow_insecure_returns_error_test() ->
    %% Unsafe verify_none with AllowInsecure=false → rejected
    Result = beam_agent_transport_utils:tls_client_opts(
        "host.example.com",
        [{verify, verify_none}],
        false
    ),
    ?assertEqual({error, unsafe_tls_opts}, Result).

allow_insecure_strips_internal_flag_test() ->
    %% The {allow_insecure_tls, _} internal flag must not appear in
    %% the returned TLS options list
    {ok, Opts} = beam_agent_transport_utils:tls_client_opts(
        "host.example.com",
        [{verify, verify_none}, {allow_insecure_tls, true}],
        true
    ),
    ?assertNot(lists:keymember(allow_insecure_tls, 1, Opts)).

%%====================================================================
%% Logger capture helpers
%%====================================================================

-define(LOG_HANDLER_ID, test_warning_capture).

setup_log_capture() ->
    HandlerId = ?LOG_HANDLER_ID,
    %% Store warnings in a process dictionary of a collector process
    Pid = spawn(fun collector_loop/0),
    ok = logger:add_handler(HandlerId, ?MODULE, #{
        level  => warning,
        config => #{collector => Pid}
    }),
    HandlerId.

cleanup_log_capture(HandlerId) ->
    case logger:get_handler_config(HandlerId) of
        {ok, #{config := #{collector := Pid}}} ->
            Pid ! stop;
        _ ->
            ok
    end,
    _ = logger:remove_handler(HandlerId),
    ok.

collect_warnings(HandlerId) ->
    case logger:get_handler_config(HandlerId) of
        {ok, #{config := #{collector := Pid}}} ->
            Pid ! {collect, self()},
            receive
                {warnings, Ws} -> Ws
            after 500 -> []
            end;
        _ ->
            []
    end.

%% OTP logger handler callback.
%% The second argument is the full handler config map; the custom
%% application config lives under the `config` sub-key.
log(#{level := warning, msg := Msg}, #{config := #{collector := Pid}}) ->
    Formatted = format_msg(Msg),
    Pid ! {warning, Formatted},
    ok;
log(_LogEvent, _HandlerConfig) ->
    ok.

format_msg({string, S}) when is_list(S) -> S;
format_msg({string, S}) when is_binary(S) -> binary_to_list(S);
format_msg({report, R}) -> io_lib:format("~0p", [R]);
format_msg({Format, Args}) -> io_lib:format(Format, Args).

collector_loop() ->
    collector_loop([]).

collector_loop(Acc) ->
    receive
        {warning, Msg} ->
            collector_loop([Msg | Acc]);
        {collect, From} ->
            %% Reply with accumulated warnings and reset the list so
            %% successive collect calls in the same fixture see only
            %% warnings emitted after the previous collect.
            From ! {warnings, lists:reverse(Acc)},
            collector_loop([]);
        stop ->
            ok
    end.
