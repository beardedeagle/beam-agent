-module(beam_agent_command_policy).
-moduledoc false.

%% Layer 1 of the BeamAgent command security architecture.
%%
%% Pure function module — no processes, no side effects.
%% Evaluates parsed command structures against a policy rule set.
%%
%% Evaluation order:
%% 1. Deny rules checked against top-level raw command (catches
%%    cross-command patterns like fork bombs)
%% 2. Structure-recursive evaluation: deny rules → allow rules → default
%%
%% Deny-wins semantics: if any deny rule matches at any level, the
%% entire command is denied.

-export([
    evaluate/2,
    default_policy/0,
    default_deny_rules/0
]).

-export_type([
    policy_config/0,
    policy_rule/0,
    match_spec/0,
    arg_match/0,
    policy_result/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type policy_result() :: allow | ask | {deny, binary()}.

-type policy_config() :: #{
    deny := [policy_rule()],
    allow := [policy_rule()],
    default_string_action := allow | ask | deny,
    default_list_action := allow | ask | deny
}.

-type policy_rule() :: #{
    type := allow | deny,
    match := match_spec(),
    reason => binary()
}.

-type match_spec() ::
    %% Exact match on program name
    {program, binary()} |
    %% Program name starts with prefix (e.g., <<"mkfs">> matches mkfs.ext4)
    {program_prefix, binary()} |
    %% Program name + ordered subsequence of arg patterns
    {program_args, binary(), [arg_match()]} |
    %% Substring match in raw command text
    {contains, binary()} |
    %% Matches everything
    '*'.

-type arg_match() ::
    %% Exact arg value
    {exact, binary()} |
    %% Arg starts with prefix
    {prefix, binary()} |
    %% Matches any arg (skip/consume one)
    '*'.

%% Suppress benign supertype warnings: specs are intentionally wider than
%% current call-site usage to permit future extension without spec churn.
-dialyzer({nowarn_function, [default_deny_rules/0,
                             result_from_action/1]}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Evaluate a command struct against a policy configuration.".
-spec evaluate(beam_agent_command_parser:command_struct(), policy_config()) ->
    policy_result().
evaluate(CommandStruct, PolicyConfig) ->
    %% First pass: check deny rules against the top-level raw command.
    %% Catches cross-command patterns (e.g., fork bombs) that only
    %% appear in the full raw string.
    Raw = maps:get(raw, CommandStruct, <<>>),
    DenyRules = maps:get(deny, PolicyConfig, []),
    case check_deny_raw(Raw, DenyRules) of
        {deny, _} = Denial -> Denial;
        pass -> evaluate_struct(CommandStruct, PolicyConfig)
    end.

-doc "Return the default policy configuration.".
-spec default_policy() -> policy_config().
default_policy() ->
    #{
        deny => default_deny_rules(),
        allow => [],
        default_string_action => ask,
        default_list_action => allow
    }.

-doc "Return the built-in deny rules for known-dangerous patterns.".
-spec default_deny_rules() -> [policy_rule()].
default_deny_rules() ->
    [
        %% rm — combined flags (substring catches -rfi, -rf /, etc.)
        #{type => deny,
          match => {contains, <<"rm -rf">>},
          reason => <<"Recursive force removal blocked">>},
        #{type => deny,
          match => {contains, <<"rm -fr">>},
          reason => <<"Recursive force removal blocked">>},
        #{type => deny,
          match => {contains, <<"rm -Rf">>},
          reason => <<"Recursive force removal blocked">>},
        #{type => deny,
          match => {contains, <<"rm -fR">>},
          reason => <<"Recursive force removal blocked">>},
        #{type => deny,
          match => {program, <<"mkfs">>},
          reason => <<"Filesystem creation blocked">>},
        #{type => deny,
          match => {program_prefix, <<"mkfs">>},
          reason => <<"Filesystem creation variant blocked">>},
        #{type => deny,
          match => {program, <<"dd">>},
          reason => <<"Raw disk operation blocked">>},
        #{type => deny,
          match => {contains, <<":(){:|:&};:">>},
          reason => <<"Fork bomb pattern detected">>},
        #{type => deny,
          match => {contains, <<"chmod 777">>},
          reason => <<"Overly permissive chmod blocked">>},
        #{type => deny,
          match => {program, <<"shutdown">>},
          reason => <<"System shutdown blocked">>},
        #{type => deny,
          match => {program, <<"reboot">>},
          reason => <<"System reboot blocked">>},
        #{type => deny,
          match => {program, <<"halt">>},
          reason => <<"System halt blocked">>},
        #{type => deny,
          match => {program, <<"poweroff">>},
          reason => <<"System poweroff blocked">>}
    ] ++ rm_separated_flag_rules().

%% @private Generate deny rules for rm with separated recursive + force
%% flags.  Covers all combinations of -r/-R/--recursive with -f/--force
%% in both orderings, catching evasions like `rm -r -f /` or
%% `rm --force --recursive /`.
-spec rm_separated_flag_rules() -> [policy_rule()].
rm_separated_flag_rules() ->
    dangerous_flag_combo_rules(
        <<"rm">>,
        [<<"-r">>, <<"-R">>, <<"--recursive">>],
        [<<"-f">>, <<"--force">>],
        <<"Recursive force removal blocked">>).

%% @private Generate deny rules for a program where any combination of
%% a flag from GroupA with a flag from GroupB is dangerous.  Produces
%% rules for both orderings (A then B, B then A) so the check is
%% order-independent.  Uses program_args match specs, which benefit
%% from basename normalization.
-spec dangerous_flag_combo_rules(binary(), [binary()], [binary()],
                                  binary()) -> [policy_rule()].
dangerous_flag_combo_rules(Program, GroupA, GroupB, Reason) ->
    [#{type => deny,
       match => {program_args, Program, [{exact, A}, {exact, B}]},
       reason => Reason}
     || A <- GroupA, B <- GroupB]
    ++
    [#{type => deny,
       match => {program_args, Program, [{exact, B}, {exact, A}]},
       reason => Reason}
     || A <- GroupA, B <- GroupB].

%%--------------------------------------------------------------------
%% Internal: Structure evaluation
%%--------------------------------------------------------------------

-spec evaluate_struct(beam_agent_command_parser:command_struct(), policy_config()) ->
    policy_result().
evaluate_struct(#{type := opaque, reason := Reason}, _Config) ->
    {deny, <<"Opaque command denied: ", Reason/binary>>};
evaluate_struct(#{type := opaque}, _Config) ->
    {deny, <<"Opaque command denied">>};
evaluate_struct(#{type := simple} = Cmd, Config) ->
    evaluate_simple(Cmd, Config);
evaluate_struct(#{type := chain, commands := Cmds}, Config) ->
    evaluate_all(Cmds, Config);
evaluate_struct(#{type := pipeline, commands := Cmds}, Config) ->
    evaluate_all(Cmds, Config);
evaluate_struct(#{type := redirect, command := Inner}, Config) ->
    evaluate_struct(Inner, Config);
evaluate_struct(#{type := subshell}, _Config) ->
    {deny, <<"Subshell execution denied by default">>}.

-spec evaluate_all([beam_agent_command_parser:command_struct()], policy_config()) ->
    policy_result().
evaluate_all(Cmds, Config) ->
    Results = [evaluate(Cmd, Config) || Cmd <- Cmds],
    case find_first_deny(Results) of
        {deny, _} = Denial ->
            Denial;
        none ->
            case lists:member(ask, Results) of
                true  -> ask;
                false -> allow
            end
    end.

-spec evaluate_simple(beam_agent_command_parser:command_struct(), policy_config()) ->
    policy_result().
evaluate_simple(Cmd, Config) ->
    DenyRules = maps:get(deny, Config, []),
    AllowRules = maps:get(allow, Config, []),
    case check_rules_deny(Cmd, DenyRules) of
        {deny, _} = Denial ->
            Denial;
        pass ->
            case check_rules_allow(Cmd, AllowRules) of
                allow -> allow;
                pass  -> default_action(Cmd, Config)
            end
    end.

%%--------------------------------------------------------------------
%% Internal: Rule checking
%%--------------------------------------------------------------------

%% Check deny rules against the raw command string (top-level only).
%% Only {contains, _} and '*' specs apply here — program-level checks
%% require a parsed simple command.
-spec check_deny_raw(binary(), [policy_rule()]) -> {deny, binary()} | pass.
check_deny_raw(_Raw, []) ->
    pass;
check_deny_raw(Raw, [#{match := {contains, Pattern}} = Rule | Rest]) ->
    case binary:match(Raw, Pattern) of
        nomatch -> check_deny_raw(Raw, Rest);
        _       -> {deny, maps:get(reason, Rule, <<"Denied by policy">>)}
    end;
check_deny_raw(_Raw, [#{match := '*'} = Rule | _Rest]) ->
    {deny, maps:get(reason, Rule, <<"Denied by policy">>)};
check_deny_raw(Raw, [_ | Rest]) ->
    %% Non-contains rules checked at the command level, not raw string
    check_deny_raw(Raw, Rest).

-spec check_rules_deny(beam_agent_command_parser:command_struct(), [policy_rule()]) ->
    {deny, binary()} | pass.
check_rules_deny(_Cmd, []) ->
    pass;
check_rules_deny(Cmd, [Rule | Rest]) ->
    case match_rule(Rule, Cmd) of
        true  -> {deny, maps:get(reason, Rule, <<"Denied by policy">>)};
        false -> check_rules_deny(Cmd, Rest)
    end.

-spec check_rules_allow(beam_agent_command_parser:command_struct(), [policy_rule()]) ->
    allow | pass.
check_rules_allow(_Cmd, []) ->
    pass;
check_rules_allow(Cmd, [Rule | Rest]) ->
    case match_rule(Rule, Cmd) of
        true  -> allow;
        false -> check_rules_allow(Cmd, Rest)
    end.

%%--------------------------------------------------------------------
%% Internal: Rule matching
%%--------------------------------------------------------------------

-spec match_rule(policy_rule(), beam_agent_command_parser:command_struct()) ->
    boolean().
match_rule(#{match := MatchSpec}, Cmd) ->
    match_spec(MatchSpec, Cmd).

-spec match_spec(match_spec(), beam_agent_command_parser:command_struct()) ->
    boolean().
match_spec('*', _Cmd) ->
    true;
match_spec({program, Pattern}, #{program := Program}) ->
    Program =:= Pattern orelse
        normalize_basename(Program) =:= Pattern;
match_spec({program, _Pattern}, _Cmd) ->
    false;
match_spec({program_prefix, Prefix}, #{program := Program}) ->
    BaseName = normalize_basename(Program),
    PrefixLen = byte_size(Prefix),
    byte_size(BaseName) >= PrefixLen andalso
        binary:part(BaseName, 0, PrefixLen) =:= Prefix;
match_spec({program_prefix, _Prefix}, _Cmd) ->
    false;
match_spec({program_args, ProgramPattern, ArgPatterns},
           #{program := Program, args := Args}) ->
    (Program =:= ProgramPattern orelse
         normalize_basename(Program) =:= ProgramPattern) andalso
        match_args(ArgPatterns, Args);
match_spec({program_args, _, _}, _Cmd) ->
    false;
match_spec({contains, Pattern}, Cmd) ->
    Raw = maps:get(raw, Cmd, <<>>),
    binary:match(Raw, Pattern) =/= nomatch.

%% Match an ordered subsequence of arg patterns against actual args.
%% Each pattern consumes zero or more args scanning left-to-right.
-spec match_args([arg_match()], [binary()]) -> boolean().
match_args([], _Args) ->
    true;
match_args(_Patterns, []) ->
    false;
match_args([Pattern | PatternsRest], [Arg | ArgsRest]) ->
    case match_arg(Pattern, Arg) of
        true  -> match_args(PatternsRest, ArgsRest);
        false -> match_args([Pattern | PatternsRest], ArgsRest)
    end.

-spec match_arg(arg_match(), binary()) -> boolean().
match_arg('*', _Arg) ->
    true;
match_arg({exact, Expected}, Arg) ->
    Arg =:= Expected;
match_arg({prefix, Prefix}, Arg) ->
    PrefixLen = byte_size(Prefix),
    byte_size(Arg) >= PrefixLen andalso
        binary:part(Arg, 0, PrefixLen) =:= Prefix.

%%--------------------------------------------------------------------
%% Internal: Default action
%%--------------------------------------------------------------------

-spec default_action(beam_agent_command_parser:command_struct(), policy_config()) ->
    policy_result().
default_action(#{input_form := list}, Config) ->
    result_from_action(maps:get(default_list_action, Config, allow));
default_action(_Cmd, Config) ->
    result_from_action(maps:get(default_string_action, Config, ask)).

-spec result_from_action(allow | ask | deny) -> policy_result().
result_from_action(allow) -> allow;
result_from_action(ask)   -> ask;
result_from_action(deny)  -> {deny, <<"No matching policy rule">>}.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec find_first_deny([policy_result()]) -> {deny, binary()} | none.
find_first_deny([]) ->
    none;
find_first_deny([{deny, _} = Denial | _]) ->
    Denial;
find_first_deny([_ | Rest]) ->
    find_first_deny(Rest).

%% Strip directory components from a program binary, consistent with
%% beam_agent_command_parser:categorize/1.
-spec normalize_basename(binary()) -> binary().
normalize_basename(Program) ->
    list_to_binary(filename:basename(binary_to_list(Program))).
