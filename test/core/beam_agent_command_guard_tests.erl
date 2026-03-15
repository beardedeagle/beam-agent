%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_guard (Layer 3).
%%%
%%% Tests cover:
%%%   - Lifecycle: init, teardown, running
%%%   - State: starts active, status reporting
%%%   - evaluate/2: allow, deny, throttle results
%%%   - record_execution/3: synchronous history recording
%%%   - lockdown/1 and reset/0
%%%   - reload_policy/1
%%%   - Rate limiting (per-program, per-category, global)
%%%   - Throttle -> lockdown escalation
%%%   - Validator crash -> fail-safe deny
%%%   - on_execution/3 post-execution notification
%%%   - on_execution/3 crash -> fail-safe (no break)
%%%
%%% These tests use real ETS tables — no mocks, no processes.
%%% Each test initializes/tears down the guard for isolation.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_guard_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

simple_cmd(Program) ->
    simple_cmd(Program, []).

simple_cmd(Program, Args) ->
    #{type => simple, program => Program, args => Args,
      raw => iolist_to_binary([Program | [[<<" ">>, A] || A <- Args]])}.

default_opts() ->
    #{agent => test_agent, session_state => active}.

%% A policy that allows everything
allow_all_policy() ->
    #{deny => [], allow => [],
      default_string_action => allow, default_list_action => allow}.

%% A policy that denies rm
deny_rm_policy() ->
    #{deny => [#{type => deny, match => {program, <<"rm">>},
                 reason => <<"rm blocked">>}],
      allow => [],
      default_string_action => allow, default_list_action => allow}.

%% Guard config with generous rate limits (won't trigger during tests)
relaxed_config() ->
    #{policy => allow_all_policy(),
      rate_limits => #{
          global => {1000, 60000},
          per_program => {1000, 60000},
          per_category => #{}
      },
      temporal_rules => []}.

%% Guard config with very tight rate limits
tight_config() ->
    #{policy => allow_all_policy(),
      rate_limits => #{
          global => {2, 60000},
          per_program => {1, 60000},
          per_category => #{destructive => {1, 60000}}
      },
      temporal_rules => []}.

%% Init guard, run fun, teardown — ensures cleanup
with_guard(Config, Fun) ->
    beam_agent_command_guard:init(Config),
    try
        Fun()
    after
        beam_agent_command_guard:teardown()
    end.

%%====================================================================
%% Lifecycle
%%====================================================================

init_teardown_test() ->
    with_guard(relaxed_config(), fun() ->
        ?assert(beam_agent_command_guard:running())
    end),
    ?assertNot(beam_agent_command_guard:running()).

%%====================================================================
%% Status
%%====================================================================

status_starts_active_test() ->
    with_guard(relaxed_config(), fun() ->
        Status = beam_agent_command_guard:status(),
        ?assertEqual(active, maps:get(state, Status)),
        ?assertEqual(0, maps:get(history_size, Status))
    end).

%%====================================================================
%% evaluate/2 — allow
%%====================================================================

evaluate_allows_safe_command_test() ->
    with_guard(relaxed_config(), fun() ->
        Cmd = simple_cmd(<<"echo">>, [<<"hello">>]),
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertEqual(allow, Result)
    end).

evaluate_allows_multiple_commands_test() ->
    with_guard(relaxed_config(), fun() ->
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(
                simple_cmd(<<"echo">>), default_opts())),
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(
                simple_cmd(<<"ls">>), default_opts())),
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(
                simple_cmd(<<"cat">>), default_opts()))
    end).

%%====================================================================
%% evaluate/2 — deny (policy-based)
%%====================================================================

evaluate_denies_blocked_command_test() ->
    C = relaxed_config(),
    Config = C#{policy => deny_rm_policy()},
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"rm">>, [<<"-rf">>]),
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertMatch({deny, _}, Result)
    end).

evaluate_deny_includes_reason_test() ->
    C = relaxed_config(),
    Config = C#{policy => deny_rm_policy()},
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"rm">>),
        {deny, Reason} = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assert(byte_size(Reason) > 0)
    end).

%%====================================================================
%% record_execution/3 — synchronous, no sleep needed
%%====================================================================

record_execution_updates_history_test() ->
    with_guard(relaxed_config(), fun() ->
        Cmd = simple_cmd(<<"echo">>, [<<"test">>]),
        beam_agent_command_guard:record_execution(
            Cmd, default_opts(), {ok, #{exit_code => 0}}),
        Status = beam_agent_command_guard:status(),
        ?assert(maps:get(history_size, Status) > 0)
    end).

%%====================================================================
%% lockdown/1 and reset/0
%%====================================================================

lockdown_denies_all_commands_test() ->
    with_guard(relaxed_config(), fun() ->
        beam_agent_command_guard:lockdown(<<"test lockdown">>),
        Cmd = simple_cmd(<<"echo">>),
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertMatch({deny, _}, Result)
    end).

lockdown_reason_in_denial_test() ->
    with_guard(relaxed_config(), fun() ->
        beam_agent_command_guard:lockdown(<<"security incident">>),
        {deny, Reason} = beam_agent_command_guard:evaluate(
            simple_cmd(<<"echo">>), default_opts()),
        ?assertNotEqual(nomatch, binary:match(Reason, <<"security incident">>))
    end).

lockdown_status_test() ->
    with_guard(relaxed_config(), fun() ->
        beam_agent_command_guard:lockdown(<<"test">>),
        Status = beam_agent_command_guard:status(),
        ?assertEqual(lockdown, maps:get(state, Status))
    end).

reset_from_lockdown_test() ->
    with_guard(relaxed_config(), fun() ->
        beam_agent_command_guard:lockdown(<<"test">>),
        beam_agent_command_guard:reset(),
        Status = beam_agent_command_guard:status(),
        ?assertEqual(active, maps:get(state, Status)),
        %% Should allow commands again
        Result = beam_agent_command_guard:evaluate(
            simple_cmd(<<"echo">>), default_opts()),
        ?assertEqual(allow, Result)
    end).

%%====================================================================
%% reload_policy/1
%%====================================================================

reload_policy_takes_effect_test() ->
    with_guard(relaxed_config(), fun() ->
        Cmd = simple_cmd(<<"rm">>),
        %% Initially allowed
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(Cmd, default_opts())),
        %% Reload with deny policy
        beam_agent_command_guard:reload_policy(deny_rm_policy()),
        %% Now denied
        ?assertMatch({deny, _},
            beam_agent_command_guard:evaluate(Cmd, default_opts()))
    end).

%%====================================================================
%% Rate limiting — global
%%====================================================================

global_rate_limit_throttles_test() ->
    Config = #{
        policy => allow_all_policy(),
        rate_limits => #{
            global => {2, 60000},
            per_program => {1000, 60000},
            per_category => #{}
        },
        temporal_rules => []
    },
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"echo">>),
        %% First two should pass (global limit = 2)
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(Cmd, default_opts())),
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(Cmd, default_opts())),
        %% Third should throttle
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertMatch({throttle, _}, Result)
    end).

%%====================================================================
%% Rate limiting — per-program
%%====================================================================

per_program_rate_limit_test() ->
    Config = #{
        policy => allow_all_policy(),
        rate_limits => #{
            global => {1000, 60000},
            per_program => {1, 60000},
            per_category => #{}
        },
        temporal_rules => []
    },
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"echo">>),
        %% First passes
        ?assertEqual(allow,
            beam_agent_command_guard:evaluate(Cmd, default_opts())),
        %% Second throttles (per_program limit = 1)
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertMatch({throttle, _}, Result)
    end).

%%====================================================================
%% Throttle -> active recovery via reset
%%====================================================================

throttle_reset_recovers_test() ->
    with_guard(tight_config(), fun() ->
        Cmd = simple_cmd(<<"echo">>),
        %% Exhaust rate limits
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        %% Verify in throttle
        Status = beam_agent_command_guard:status(),
        ?assertEqual(throttle, maps:get(state, Status)),
        %% Reset
        beam_agent_command_guard:reset(),
        StatusAfter = beam_agent_command_guard:status(),
        ?assertEqual(active, maps:get(state, StatusAfter))
    end).

%%====================================================================
%% Throttle -> lockdown escalation
%%====================================================================

throttle_escalates_to_lockdown_test() ->
    with_guard(tight_config(), fun() ->
        Cmd = simple_cmd(<<"echo">>),
        %% Exhaust rate limits to enter throttle
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        beam_agent_command_guard:evaluate(Cmd, default_opts()),
        %% Keep hitting throttle — after LOCKDOWN_THRESHOLD (10) denials,
        %% should escalate to lockdown
        lists:foreach(fun(_) ->
            beam_agent_command_guard:evaluate(Cmd, default_opts())
        end, lists:seq(1, 10)),
        Status = beam_agent_command_guard:status(),
        ?assertEqual(lockdown, maps:get(state, Status))
    end).

%%====================================================================
%% Validator crash -> fail-safe deny
%%====================================================================

validator_crash_failsafe_test() ->
    %% Use a real test module that always crashes (no mocks)
    C = relaxed_config(),
    Config = C#{
        validator => beam_agent_test_crashing_validator
    },
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"echo">>),
        Result = beam_agent_command_guard:evaluate(Cmd, default_opts()),
        ?assertMatch({deny, _}, Result)
    end).

%%====================================================================
%% running/0
%%====================================================================

running_false_when_not_initialized_test() ->
    ?assertNot(beam_agent_command_guard:running()).

running_true_when_initialized_test() ->
    with_guard(relaxed_config(), fun() ->
        ?assert(beam_agent_command_guard:running())
    end).

%%====================================================================
%% Lockdown from initial state
%%====================================================================

lockdown_from_initial_state_test() ->
    with_guard(relaxed_config(), fun() ->
        %% Lockdown immediately without any evaluates
        beam_agent_command_guard:lockdown(<<"preemptive">>),
        Status = beam_agent_command_guard:status(),
        ?assertEqual(lockdown, maps:get(state, Status))
    end).

%%====================================================================
%% on_execution/3 — post-execution validator notification
%%====================================================================

on_execution_called_after_record_test() ->
    C = relaxed_config(),
    Config = C#{validator => beam_agent_test_on_execution_validator},
    Tab = ets:new(test_on_execution_log, [named_table, public, bag]),
    try
        with_guard(Config, fun() ->
            Cmd = simple_cmd(<<"echo">>, [<<"hello">>]),
            beam_agent_command_guard:record_execution(
                Cmd, default_opts(), {ok, #{exit_code => 0}}),
            %% Verify on_execution was called exactly once
            Entries = ets:tab2list(Tab),
            ?assertEqual(1, length(Entries)),
            [{_, RecordedCmd, RecordedResult}] = Entries,
            ?assertEqual(<<"echo">>, maps:get(program, RecordedCmd)),
            ?assertMatch({ok, #{exit_code := 0}}, RecordedResult)
        end)
    after
        ets:delete(Tab)
    end.

on_execution_crash_safe_test() ->
    C = relaxed_config(),
    Config = C#{validator => beam_agent_test_crashing_on_execution_validator},
    with_guard(Config, fun() ->
        Cmd = simple_cmd(<<"echo">>),
        %% Should not crash despite validator's on_execution crashing
        ?assertEqual(ok,
            beam_agent_command_guard:record_execution(
                Cmd, default_opts(), {ok, #{exit_code => 0}})),
        %% History should still be recorded
        Status = beam_agent_command_guard:status(),
        ?assert(maps:get(history_size, Status) > 0)
    end).
