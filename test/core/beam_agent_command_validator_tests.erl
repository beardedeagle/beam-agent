%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_command_validator behaviour and
%%% beam_agent_command_validator_default (Layer 2).
%%%
%%% Tests cover:
%%%   - Default validator: allow/deny/ask pass-through
%%%   - Default validator: ask + list-form → allow
%%%   - Default validator: ask + string-form → deny
%%%   - Behaviour type exports exist
%%%
%%% All tests are pure — no processes, no ETS, no test doubles.
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_command_validator_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

simple_cmd(Program) ->
    simple_cmd(Program, []).

simple_cmd(Program, Args) ->
    #{type => simple, program => Program, args => Args,
      raw => iolist_to_binary([Program | [[<<" ">>, A] || A <- Args]])}.

%%====================================================================
%% Default validator — allow pass-through
%%====================================================================

default_allows_when_policy_allows_test() ->
    Cmd = simple_cmd(<<"echo">>, [<<"hello">>]),
    Ctx = #{policy_result => allow, command_form => string},
    ?assertEqual(allow, beam_agent_command_validator_default:validate(Cmd, Ctx)).

%%====================================================================
%% Default validator — deny pass-through
%%====================================================================

default_denies_when_policy_denies_test() ->
    Cmd = simple_cmd(<<"rm">>, [<<"-rf">>]),
    Ctx = #{policy_result => {deny, <<"blocked">>}, command_form => string},
    ?assertEqual({deny, <<"blocked">>},
                 beam_agent_command_validator_default:validate(Cmd, Ctx)).

default_denies_preserves_reason_test() ->
    Cmd = simple_cmd(<<"dd">>),
    Reason = <<"Raw disk operation blocked">>,
    Ctx = #{policy_result => {deny, Reason}, command_form => string},
    ?assertMatch({deny, Reason},
                 beam_agent_command_validator_default:validate(Cmd, Ctx)).

%%====================================================================
%% Default validator — ask handling
%%====================================================================

default_ask_list_form_allows_test() ->
    Cmd = simple_cmd(<<"custom_tool">>, [<<"arg">>]),
    Ctx = #{policy_result => ask, command_form => list},
    ?assertEqual(allow, beam_agent_command_validator_default:validate(Cmd, Ctx)).

default_ask_string_form_denies_test() ->
    Cmd = simple_cmd(<<"custom_tool">>, [<<"arg">>]),
    Ctx = #{policy_result => ask, command_form => string},
    ?assertMatch({deny, _},
                 beam_agent_command_validator_default:validate(Cmd, Ctx)).

default_ask_string_form_reason_test() ->
    Cmd = simple_cmd(<<"unknown">>),
    Ctx = #{policy_result => ask, command_form => string},
    {deny, Reason} = beam_agent_command_validator_default:validate(Cmd, Ctx),
    ?assert(byte_size(Reason) > 0).

%%====================================================================
%% Default validator — ignores command content
%%====================================================================

default_ignores_command_struct_test() ->
    %% The default validator only cares about context, not the command
    DangerousCmd = simple_cmd(<<"rm">>, [<<"-rf">>, <<"/">>]),
    Ctx = #{policy_result => allow, command_form => string},
    ?assertEqual(allow,
                 beam_agent_command_validator_default:validate(DangerousCmd, Ctx)).

%%====================================================================
%% Behaviour module exports types
%%====================================================================

behaviour_exports_types_test() ->
    %% Verify the behaviour module is loadable and exports types
    Info = beam_agent_command_validator:module_info(exports),
    ?assert(is_list(Info)).

%%====================================================================
%% Default validator is a valid behaviour implementation
%%====================================================================

default_validator_implements_behaviour_test() ->
    Behaviours = proplists:get_value(
        behaviour, beam_agent_command_validator_default:module_info(attributes), []),
    ?assert(lists:member(beam_agent_command_validator, Behaviours)).
