-module(beam_agent_policy).
-moduledoc """
Public API for canonical BeamAgent policy profiles.

Policy profiles provide deterministic allow/deny evaluation for reusable
runtime concerns such as approvals, command execution, backend selection,
routines, memory writes, compaction, and orchestration.
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

-type decision() :: beam_agent_policy_core:decision().
-type action() :: beam_agent_policy_core:action().
-type key_path() :: beam_agent_policy_core:key_path().
-type match_spec() :: beam_agent_policy_core:match_spec().
-type profile_rule() :: beam_agent_policy_core:profile_rule().
-type profile() :: beam_agent_policy_core:profile().

-doc "Ensure the policy profile table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_policy_core:ensure_tables().

-doc "Clear all policy profiles. Intended for tests and resets.".
-spec clear() -> ok.
clear() ->
    beam_agent_policy_core:clear().

-doc "Insert or overwrite a policy profile.".
-spec put_profile(binary(), map()) -> ok | {error, term()}.
put_profile(ProfileId, Profile) ->
    beam_agent_policy_core:put_profile(ProfileId, Profile).

-doc "Fetch a policy profile by id.".
-spec get_profile(binary()) -> {ok, profile()} | {error, not_found}.
get_profile(ProfileId) ->
    beam_agent_policy_core:get_profile(ProfileId).

-doc "List all policy profiles.".
-spec list_profiles() -> {ok, [profile()]}.
list_profiles() ->
    beam_agent_policy_core:list_profiles().

-doc """
Evaluate an action against a stored policy profile.

`undefined` profile ids are treated as "no policy" and therefore allow.
""".
-spec evaluate(binary() | undefined, action(), map()) -> allow | {deny, binary()}.
evaluate(ProfileId, Action, Context) ->
    beam_agent_policy_core:evaluate(ProfileId, Action, Context).
