%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_policy (Layer 1).
%%%
%%% Tests cover:
%%%   - evaluate/2: deny-wins, allow rules, default actions
%%%   - Chain/pipeline evaluation (any deny = whole denied)
%%%   - Opaque/subshell commands (always denied)
%%%   - Default deny rules (rm -rf, mkfs, dd, fork bomb, etc.)
%%%   - Match specs: program, program_args, contains, wildcard
%%%   - Default policy configuration
%%%
%%% All tests are pure — no processes, no ETS, no test doubles.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_policy_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

simple_cmd(Program) ->
    simple_cmd(Program, []).

simple_cmd(Program, Args) ->
    #{type => simple, program => Program, args => Args,
      raw => iolist_to_binary([Program | [[<<" ">>, A] || A <- Args]]),
      input_form => string}.

list_cmd(Program, Args) ->
    #{type => simple, program => Program, args => Args,
      raw => iolist_to_binary([Program | [[<<" ">>, A] || A <- Args]]),
      input_form => list}.

empty_policy() ->
    #{deny => [], allow => [],
      default_string_action => ask, default_list_action => allow}.

%%====================================================================
%% evaluate/2 — deny rules
%%====================================================================

deny_rule_blocks_program_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {program, <<"rm">>},
                   reason => <<"rm blocked">>}]
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"rm">>, [<<"-rf">>]), Policy),
    ?assertMatch({deny, <<"rm blocked">>}, Result).

deny_rule_contains_blocks_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {contains, <<"rm -rf">>},
                   reason => <<"rm -rf blocked">>}]
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"rm">>, [<<"-rf">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

deny_wins_over_allow_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {program, <<"rm">>},
                   reason => <<"denied">>}],
        allow => [#{type => allow, match => {program, <<"rm">>}}]
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"rm">>), Policy),
    ?assertMatch({deny, _}, Result).

deny_wildcard_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => '*', reason => <<"all blocked">>}]
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"echo">>), Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — allow rules
%%====================================================================

allow_rule_permits_test() ->
    P = empty_policy(),
    Policy = P#{
        allow => [#{type => allow, match => {program, <<"git">>}}],
        default_string_action => deny
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"git">>, [<<"status">>]), Policy),
    ?assertEqual(allow, Result).

allow_rule_no_match_uses_default_test() ->
    P = empty_policy(),
    Policy = P#{
        allow => [#{type => allow, match => {program, <<"git">>}}],
        default_string_action => deny
    },
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"echo">>), Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — default actions
%%====================================================================

default_list_form_allows_test() ->
    P = empty_policy(),
    Policy = P#{default_list_action => allow},
    Cmd = list_cmd(<<"custom_tool">>, [<<"arg">>]),
    Result = beam_agent_command_policy:evaluate(Cmd, Policy),
    ?assertEqual(allow, Result).

default_string_form_asks_test() ->
    P = empty_policy(),
    Policy = P#{default_string_action => ask},
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"custom_tool">>), Policy),
    ?assertEqual(ask, Result).

default_string_form_denies_test() ->
    P = empty_policy(),
    Policy = P#{default_string_action => deny},
    Result = beam_agent_command_policy:evaluate(simple_cmd(<<"custom_tool">>), Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — chain commands
%%====================================================================

chain_any_deny_blocks_all_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {program, <<"rm">>},
                   reason => <<"rm blocked">>}],
        default_string_action => allow
    },
    Chain = #{type => chain, operator => ';',
              commands => [simple_cmd(<<"echo">>), simple_cmd(<<"rm">>)],
              raw => <<"echo; rm">>},
    Result = beam_agent_command_policy:evaluate(Chain, Policy),
    ?assertMatch({deny, _}, Result).

chain_all_allow_passes_test() ->
    P = empty_policy(),
    Policy = P#{default_string_action => allow},
    Chain = #{type => chain, operator => '&&',
              commands => [simple_cmd(<<"echo">>), simple_cmd(<<"ls">>)],
              raw => <<"echo && ls">>},
    Result = beam_agent_command_policy:evaluate(Chain, Policy),
    ?assertEqual(allow, Result).

%%====================================================================
%% evaluate/2 — pipeline commands
%%====================================================================

pipeline_deny_blocks_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {program, <<"rm">>},
                   reason => <<"blocked">>}],
        default_string_action => allow
    },
    Pipe = #{type => pipeline,
             commands => [simple_cmd(<<"cat">>), simple_cmd(<<"rm">>)],
             raw => <<"cat | rm">>},
    Result = beam_agent_command_policy:evaluate(Pipe, Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — opaque commands
%%====================================================================

opaque_always_denied_test() ->
    P = empty_policy(),
    Policy = P#{default_string_action => allow},
    Opaque = #{type => opaque, raw => <<"echo $(whoami)">>,
               reason => <<"command substitution">>},
    Result = beam_agent_command_policy:evaluate(Opaque, Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — subshell commands
%%====================================================================

subshell_denied_test() ->
    P = empty_policy(),
    Policy = P#{default_string_action => allow},
    Sub = #{type => subshell, inner => <<"echo secret">>,
            raw => <<"(echo secret)">>},
    Result = beam_agent_command_policy:evaluate(Sub, Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — redirect commands
%%====================================================================

redirect_evaluates_inner_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny, match => {program, <<"rm">>},
                   reason => <<"blocked">>}]
    },
    Redir = #{type => redirect, command => simple_cmd(<<"rm">>),
              redirects => [#{direction => out, target => <<"log">>}],
              raw => <<"rm > log">>},
    Result = beam_agent_command_policy:evaluate(Redir, Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% evaluate/2 — program_args match
%%====================================================================

program_args_exact_match_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny,
                   match => {program_args, <<"chmod">>, [{exact, <<"777">>}]},
                   reason => <<"chmod 777 blocked">>}],
        default_string_action => allow
    },
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"chmod">>, [<<"777">>, <<"/tmp/x">>]), Policy),
    ?assertMatch({deny, _}, Result).

program_args_no_match_passes_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny,
                   match => {program_args, <<"chmod">>, [{exact, <<"777">>}]},
                   reason => <<"blocked">>}],
        default_string_action => allow
    },
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"chmod">>, [<<"755">>, <<"/tmp/x">>]), Policy),
    ?assertEqual(allow, Result).

program_args_prefix_match_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny,
                   match => {program_args, <<"rm">>, [{prefix, <<"-">>}]},
                   reason => <<"rm with flags blocked">>}],
        default_string_action => allow
    },
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-rf">>, <<"file">>]), Policy),
    ?assertMatch({deny, _}, Result).

%%====================================================================
%% Default deny rules
%%====================================================================

default_denies_rm_rf_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-rf">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_rm_fr_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-fr">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_mkfs_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"mkfs">>), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_dd_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"dd">>), Policy),
    ?assertMatch({deny, _}, Result).

%% Path normalization — /usr/bin/dd must still hit {program, dd} rule
default_denies_dd_absolute_path_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"/usr/bin/dd">>), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_shutdown_absolute_path_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"/sbin/shutdown">>), Policy),
    ?assertMatch({deny, _}, Result).

%% rm flag variants — capital R (combined)
default_denies_rm_capital_Rf_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-Rf">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_rm_fR_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-fR">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

%% rm flag variants — separated flags
default_denies_rm_r_f_separated_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-r">>, <<"-f">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_rm_f_r_separated_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-f">>, <<"-r">>, <<"/">>]), Policy),
    ?assertMatch({deny, _}, Result).

%% rm flag variants — long flags
default_denies_rm_recursive_force_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"--recursive">>, <<"--force">>, <<"/">>]),
        Policy),
    ?assertMatch({deny, _}, Result).

default_denies_rm_force_recursive_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"--force">>, <<"--recursive">>, <<"/">>]),
        Policy),
    ?assertMatch({deny, _}, Result).

%% rm flag variants — mixed short/long
default_denies_rm_recursive_short_f_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"--recursive">>, <<"-f">>, <<"/">>]),
        Policy),
    ?assertMatch({deny, _}, Result).

default_denies_rm_r_force_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"rm">>, [<<"-r">>, <<"--force">>, <<"/">>]),
        Policy),
    ?assertMatch({deny, _}, Result).

%% rm with absolute path — basename normalization applies
default_denies_rm_absolute_path_rf_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"/bin/rm">>, [<<"-r">>, <<"-f">>, <<"/">>]),
        Policy),
    ?assertMatch({deny, _}, Result).

%% Full-path pattern still matches exactly (no false basename collapse)
full_path_pattern_exact_match_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny,
                   match => {program, <<"/usr/local/bin/dd">>},
                   reason => <<"exact path blocked">>}],
        default_string_action => ask
    },
    %% Exact path matches
    ?assertMatch({deny, _}, beam_agent_command_policy:evaluate(
        simple_cmd(<<"/usr/local/bin/dd">>), Policy)),
    %% Different path does NOT match (basename dd alone is insufficient)
    ?assertEqual(ask, beam_agent_command_policy:evaluate(
        simple_cmd(<<"/tmp/dd">>), Policy)),
    %% Bare name does NOT match a full-path pattern
    ?assertEqual(ask, beam_agent_command_policy:evaluate(
        simple_cmd(<<"dd">>), Policy)).

%% program_args match with absolute path (basename normalization)
program_args_basename_normalization_test() ->
    P = empty_policy(),
    Policy = P#{
        deny => [#{type => deny,
                   match => {program_args, <<"chmod">>, [{exact, <<"777">>}]},
                   reason => <<"chmod 777 blocked">>}],
        default_string_action => allow
    },
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"/usr/bin/chmod">>, [<<"777">>, <<"/tmp/x">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_shutdown_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"shutdown">>), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_reboot_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"reboot">>), Policy),
    ?assertMatch({deny, _}, Result).

default_denies_chmod_777_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Result = beam_agent_command_policy:evaluate(
        simple_cmd(<<"chmod">>, [<<"777">>, <<"file">>]), Policy),
    ?assertMatch({deny, _}, Result).

default_allows_safe_list_form_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    Cmd = list_cmd(<<"echo">>, [<<"hello">>]),
    Result = beam_agent_command_policy:evaluate(Cmd, Policy),
    ?assertEqual(allow, Result).

%%====================================================================
%% default_policy/0
%%====================================================================

default_policy_structure_test() ->
    Policy = beam_agent_command_policy:default_policy(),
    ?assert(is_list(maps:get(deny, Policy))),
    ?assert(is_list(maps:get(allow, Policy))),
    ?assert(length(maps:get(deny, Policy)) > 0).

%%====================================================================
%% default_deny_rules/0
%%====================================================================

default_deny_rules_nonempty_test() ->
    Rules = beam_agent_command_policy:default_deny_rules(),
    ?assert(length(Rules) > 0),
    lists:foreach(fun(Rule) ->
        ?assert(maps:is_key(type, Rule)),
        ?assert(maps:is_key(match, Rule)),
        ?assert(maps:is_key(reason, Rule))
    end, Rules).
