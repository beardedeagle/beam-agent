-module(beam_agent_policy_core).
-moduledoc """
Canonical policy profiles and deterministic evaluation for BeamAgent.

This module keeps reusable allow/deny policy logic outside product-specific
applications. Profiles are stored through the canonical store abstraction,
defaulting to ETS, and evaluation is pure and process-free.

The initial slice intentionally focuses on a small, explicit rule language that
is easy to reason about:

- action-scoped rules
- deny-wins evaluation
- exact, membership, prefix, and path-prefix matches over context maps

Higher-order consumers such as MonkeyClaw can compose richer semantics on top
without changing BeamAgent's execution core.
""".

-export([
    ensure_tables/0,
    clear/0,
    put_profile/2,
    get_profile/1,
    list_profiles/0,
    evaluate/3
]).

-export_type([
    decision/0,
    action/0,
    key_path/0,
    match_spec/0,
    profile_rule/0,
    profile/0
]).

-type decision() :: allow | deny.
-type action() :: approval | command | backend | routine | memory_write
                | compaction | orchestrator | atom() | binary().
-type key_path() :: atom() | binary() | [atom() | binary()].

-type match_spec() ::
    '*'
  | {exists, key_path()}
  | {eq, key_path(), term()}
  | {member, key_path(), [term()]}
  | {prefix, key_path(), binary()}
  | {path_prefix, key_path(), binary()}.

-type profile_rule() :: #{
    action := action() | '*',
    decision := decision(),
    match := match_spec(),
    reason => binary()
}.

-type profile() :: #{
    profile_id := binary(),
    default := decision(),
    metadata := map(),
    rules := [profile_rule()],
    created_at := integer(),
    updated_at := integer()
}.

-define(PROFILES_TABLE, beam_agent_policy_profiles).
-define(STORE_DOMAIN, policy).

-doc "Ensure the policy profile table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?PROFILES_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Clear all policy profiles. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?PROFILES_TABLE),
    ok.

-doc "Insert or overwrite a policy profile.".
-spec put_profile(binary(), map()) -> ok | {error, term()}.
put_profile(ProfileId, ProfileInput)
  when is_binary(ProfileId), is_map(ProfileInput) ->
    ensure_tables(),
    TeleMeta = #{profile_id => ProfileId, rule_count => length(maps:get(rules, ProfileInput, []))},
    StartTime = telemetry_start(put_profile, TeleMeta),
    Result = case normalize_profile(ProfileId, ProfileInput) of
        {ok, Profile} ->
            true = beam_agent_store:insert(?STORE_DOMAIN, ?PROFILES_TABLE,
                {ProfileId, Profile}),
            ok;
        {error, _} = Error ->
            Error
    end,
    case Result of
        ok ->
            telemetry_stop(put_profile, StartTime, TeleMeta),
            ok;
        {error, _} = ErrorResult ->
            telemetry_exception(put_profile, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc "Fetch a policy profile by id.".
-spec get_profile(binary()) -> {ok, profile()} | {error, not_found}.
get_profile(ProfileId) when is_binary(ProfileId) ->
    ensure_tables(),
    StartTime = telemetry_start(get_profile, #{profile_id => ProfileId}),
    case beam_agent_store:lookup(?STORE_DOMAIN, ?PROFILES_TABLE, ProfileId) of
        [{_, Profile}] when is_map(Profile) ->
            telemetry_stop(get_profile, StartTime, #{
                profile_id => ProfileId,
                found => true,
                rule_count => length(maps:get(rules, Profile, []))
            }),
            {ok, Profile};
        [] ->
            telemetry_stop(get_profile, StartTime, #{profile_id => ProfileId, found => false}),
            {error, not_found}
    end.

-doc "List all policy profiles, newest update first.".
-spec list_profiles() -> {ok, [profile()]}.
list_profiles() ->
    ensure_tables(),
    StartTime = telemetry_start(list_profiles, #{}),
    Profiles = beam_agent_store:foldl(?STORE_DOMAIN, fun
        ({_, Profile}, Acc) when is_map(Profile) ->
            [Profile | Acc]
    end, [], ?PROFILES_TABLE),
    Sorted = lists:sort(fun sort_profiles/2, Profiles),
    telemetry_stop(list_profiles, StartTime, #{result_count => length(Sorted)}),
    {ok, Sorted}.

-doc """
Evaluate an action against a stored policy profile.

`undefined` profile ids are treated as "no policy" and therefore allow.
Missing profiles are denied explicitly so callers cannot silently bypass a
configured policy reference.
""".
-spec evaluate(binary() | undefined, action(), map()) -> allow | {deny, binary()}.
evaluate(undefined, _Action, _Context) ->
    StartTime = telemetry_start(evaluate, #{profile_id => undefined}),
    telemetry_stop(evaluate, StartTime, #{decision => allow}),
    allow;
evaluate(ProfileId, Action, Context)
  when is_binary(ProfileId), is_map(Context) ->
    TeleMeta = #{
        profile_id => ProfileId,
        action => Action
    },
    StartTime = telemetry_start(evaluate, TeleMeta),
    Result = case get_profile(ProfileId) of
        {ok, Profile} ->
            evaluate_profile(Profile, Action, Context);
        {error, not_found} ->
            {deny, <<"unknown policy profile">>}
    end,
    telemetry_stop(evaluate, StartTime, TeleMeta#{decision => Result}),
    Result.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec normalize_profile(binary(), map()) -> {ok, profile()} | {error, term()}.
normalize_profile(ProfileId, ProfileInput) ->
    Allowed = [default, metadata, rules],
    case validate_allowed_keys(ProfileInput, Allowed, unsupported_profile_key) of
        ok ->
            case normalize_default(maps:get(default, ProfileInput, allow)) of
                {ok, Default} ->
                    case normalize_metadata(maps:get(metadata, ProfileInput, #{})) of
                        {ok, Metadata} ->
                            case normalize_rules(maps:get(rules, ProfileInput, []), []) of
                                {ok, Rules} ->
                                    Now = erlang:system_time(millisecond),
                                    CreatedAt = case get_profile(ProfileId) of
                                        {ok, Existing} ->
                                            maps:get(created_at, Existing, Now);
                                        {error, not_found} ->
                                            Now
                                    end,
                                    {ok, #{
                                        profile_id => ProfileId,
                                        default => Default,
                                        metadata => Metadata,
                                        rules => Rules,
                                        created_at => CreatedAt,
                                        updated_at => Now
                                    }};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_rules([map()], [profile_rule()]) ->
    {ok, [profile_rule()]} | {error, term()}.
normalize_rules([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_rules([Rule | Rest], Acc) when is_map(Rule) ->
    case normalize_rule(Rule) of
        {ok, Normalized} ->
            normalize_rules(Rest, [Normalized | Acc]);
        {error, _} = Error ->
            Error
    end;
normalize_rules(_, _Acc) ->
    {error, {invalid_profile, rules}}.

-spec normalize_rule(map()) -> {ok, profile_rule()} | {error, term()}.
normalize_rule(Rule) ->
    Allowed = [action, decision, match, reason],
    case validate_allowed_keys(Rule, Allowed, unsupported_rule_key) of
        ok ->
            case normalize_rule_action(maps:get(action, Rule, '*')) of
                {ok, Action} ->
                    case normalize_default(maps:get(decision, Rule, deny)) of
                        {ok, Decision} ->
                            case normalize_match(maps:get(match, Rule, '*')) of
                                {ok, Match} ->
                                    case normalize_reason(maps:get(reason, Rule, undefined)) of
                                        {ok, Reason} ->
                                            {ok, maybe_put(reason, Reason, #{
                                                action => Action,
                                                decision => Decision,
                                                match => Match
                                            })};
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec evaluate_profile(profile(), action(), map()) -> allow | {deny, binary()}.
evaluate_profile(Profile, Action, Context) ->
    Rules = maps:get(rules, Profile, []),
    case first_matching_deny(Rules, Action, Context) of
        {deny, Reason} ->
            {deny, Reason};
        none ->
            case has_matching_allow(Rules, Action, Context) of
                true ->
                    allow;
                false ->
                    result_from_default(maps:get(default, Profile, allow))
            end
    end.

-spec first_matching_deny([profile_rule()], action(), map()) ->
    {deny, binary()} | none.
first_matching_deny([], _Action, _Context) ->
    none;
first_matching_deny([Rule | Rest], Action, Context) ->
    case {rule_matches_action(Rule, Action), rule_matches_context(Rule, Context),
          maps:get(decision, Rule)} of
        {true, true, deny} ->
            {deny, maps:get(reason, Rule, <<"denied by policy profile">>)};
        _ ->
            first_matching_deny(Rest, Action, Context)
    end.

-spec has_matching_allow([profile_rule()], action(), map()) -> boolean().
has_matching_allow(Rules, Action, Context) ->
    lists:any(fun(Rule) ->
        rule_matches_action(Rule, Action) andalso
            rule_matches_context(Rule, Context) andalso
            maps:get(decision, Rule) =:= allow
    end, Rules).

-spec rule_matches_action(profile_rule(), action()) -> boolean().
rule_matches_action(#{action := '*'}, _Action) ->
    true;
rule_matches_action(#{action := RuleAction}, Action) ->
    RuleAction =:= Action.

-spec rule_matches_context(profile_rule(), map()) -> boolean().
rule_matches_context(#{match := '*'}, _Context) ->
    true;
rule_matches_context(#{match := {exists, Path}}, Context) ->
    path_value(Context, Path) =/= undefined;
rule_matches_context(#{match := {eq, Path, Value}}, Context) ->
    path_value(Context, Path) =:= Value;
rule_matches_context(#{match := {member, Path, Values}}, Context) ->
    lists:member(path_value(Context, Path), Values);
rule_matches_context(#{match := {prefix, Path, Prefix}}, Context) ->
    case path_value(Context, Path) of
        Value when is_binary(Value) ->
            binary:longest_common_prefix([Value, Prefix]) =:= byte_size(Prefix);
        _ ->
            false
    end;
rule_matches_context(#{match := {path_prefix, Path, Prefix}}, Context) ->
    case path_value(Context, Path) of
        Value when is_binary(Value) ->
            binary:longest_common_prefix([normalize_path(Value),
                normalize_path(Prefix)]) =:= byte_size(normalize_path(Prefix));
        _ ->
            false
    end.

-spec path_value(map(), key_path()) -> term().
path_value(Context, Path) when is_atom(Path); is_binary(Path) ->
    maps:get(Path, Context, undefined);
path_value(Context, [Key | Rest]) when is_map(Context) ->
    case maps:get(Key, Context, undefined) of
        Next when Rest =:= [] ->
            Next;
        Next when is_map(Next) ->
            path_value(Next, Rest);
        _ ->
            undefined
    end;
path_value(_Context, _Path) ->
    undefined.

-spec normalize_match(term()) -> {ok, match_spec()} | {error, term()}.
normalize_match('*') ->
    {ok, '*'};
normalize_match({exists, Path}) ->
    case normalize_key_path(Path, invalid_match) of
        {ok, KeyPath} -> {ok, {exists, KeyPath}};
        {error, _} = Error -> Error
    end;
normalize_match({eq, Path, Value}) ->
    case normalize_key_path(Path, invalid_match) of
        {ok, KeyPath} -> {ok, {eq, KeyPath, Value}};
        {error, _} = Error -> Error
    end;
normalize_match({member, Path, Values}) when is_list(Values) ->
    case normalize_key_path(Path, invalid_match) of
        {ok, KeyPath} -> {ok, {member, KeyPath, Values}};
        {error, _} = Error -> Error
    end;
normalize_match({prefix, Path, Prefix}) when is_binary(Prefix) ->
    case normalize_key_path(Path, invalid_match) of
        {ok, KeyPath} -> {ok, {prefix, KeyPath, Prefix}};
        {error, _} = Error -> Error
    end;
normalize_match({path_prefix, Path, Prefix}) when is_binary(Prefix) ->
    case normalize_key_path(Path, invalid_match) of
        {ok, KeyPath} -> {ok, {path_prefix, KeyPath, Prefix}};
        {error, _} = Error -> Error
    end;
normalize_match(Match) ->
    {error, {invalid_match, Match}}.

-spec normalize_key_path(term(), atom()) -> {ok, key_path()} | {error, term()}.
normalize_key_path(Path, _ErrorTag) when is_atom(Path); is_binary(Path) ->
    {ok, Path};
normalize_key_path(Path, ErrorTag) when is_list(Path) ->
    case lists:all(fun(Key) -> is_atom(Key) orelse is_binary(Key) end, Path) of
        true -> {ok, Path};
        false -> {error, {ErrorTag, Path}}
    end;
normalize_key_path(Path, ErrorTag) ->
    {error, {ErrorTag, Path}}.

-spec normalize_rule_action(term()) -> {ok, action() | '*'} | {error, term()}.
normalize_rule_action('*') ->
    {ok, '*'};
normalize_rule_action(Action) when is_atom(Action); is_binary(Action) ->
    {ok, Action};
normalize_rule_action(Action) ->
    {error, {invalid_rule_action, Action}}.

-spec normalize_default(term()) -> {ok, decision()} | {error, term()}.
normalize_default(allow) -> {ok, allow};
normalize_default(deny) -> {ok, deny};
normalize_default(Value) -> {error, {invalid_default, Value}}.

-spec normalize_reason(term()) -> {ok, binary() | undefined} | {error, term()}.
normalize_reason(undefined) ->
    {ok, undefined};
normalize_reason(Reason) when is_binary(Reason) ->
    {ok, Reason};
normalize_reason(Reason) ->
    {error, {invalid_reason, Reason}}.

-spec normalize_metadata(term()) -> {ok, map()} | {error, term()}.
normalize_metadata(Metadata) when is_map(Metadata) ->
    {ok, Metadata};
normalize_metadata(Metadata) ->
    {error, {invalid_profile, Metadata}}.

-spec validate_allowed_keys(map(), [atom()], atom()) -> ok | {error, term()}.
validate_allowed_keys(Map, Allowed, ErrorTag) ->
    case [Key || Key <- maps:keys(Map),
            is_atom(Key),
            not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [Unsupported | _] ->
            {error, {ErrorTag, Unsupported}}
    end.

-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec telemetry_start(atom(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry_core:span_start(policy, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(atom(), integer(), map()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry_core:span_stop(policy, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(atom(), term(), map()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry_core:span_exception(policy, Operation, Reason,
        compact_telemetry(Metadata)).

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).

-spec result_from_default(decision()) -> allow | {deny, binary()}.
result_from_default(allow) ->
    allow;
result_from_default(deny) ->
    {deny, <<"denied by policy profile default">>}.

-spec sort_profiles(profile(), profile()) -> boolean().
sort_profiles(A, B) ->
    compare_desc(
        maps:get(updated_at, A, 0),
        maps:get(updated_at, B, 0),
        maps:get(profile_id, A),
        maps:get(profile_id, B)
    ).

-spec compare_desc(integer(), integer(), binary(), binary()) -> boolean().
compare_desc(Left, Right, _LeftId, _RightId) when Left > Right ->
    true;
compare_desc(Left, Right, _LeftId, _RightId) when Left < Right ->
    false;
compare_desc(_Left, _Right, LeftId, RightId) ->
    LeftId =< RightId.

-spec normalize_path(binary()) -> binary().
normalize_path(Path) ->
    binary:replace(Path, <<"\\">>, <<"/">>, [global]).
