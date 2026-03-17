-module(beam_agent_routing_core).
-moduledoc """
Canonical backend routing policy engine for BeamAgent.

This module selects a backend according to reusable routing policy instead of
forcing every consumer to hard-code backend choice. It is intentionally
process-free: routing state for sticky affinity and round-robin cursors is
stored through the canonical store abstraction, which defaults to ETS.

Routing decisions are deterministic for a given request and can be reused by
callers before session start. The engine also appends durable routing decision
events into the BeamAgent journal.
""".

-export([
    ensure_tables/0,
    clear/0,
    select_backend/1,
    select_backend/2
]).

-export_type([
    route_policy/0,
    fallback_policy/0,
    health_status/0,
    route_request/0,
    route_decision/0
]).

-type route_policy() ::
    explicit
  | sticky
  | round_robin
  | failover
  | capability_first
  | preferred_then_fallback.

-type fallback_policy() :: none | available.
-type health_status() :: healthy | degraded | unhealthy | down.

-type route_request() :: #{
    backend => beam_agent_backend:backend() | binary() | atom(),
    preferred_backends => [beam_agent_backend:backend() | binary() | atom()],
    excluded_backends => [beam_agent_backend:backend() | binary() | atom()],
    fallback_backends => [beam_agent_backend:backend() | binary() | atom()],
    capabilities => [beam_agent_capabilities:capability()],
    policy => route_policy(),
    affinity_key => binary(),
    policy_profile_id => binary(),
    last_backend => beam_agent_backend:backend() | binary() | atom(),
    fallback_policy => fallback_policy(),
    health => #{beam_agent_backend:backend() | binary() | atom() => health_status()}
}.

-type route_decision() :: #{
    backend := beam_agent_backend:backend(),
    candidates := [beam_agent_backend:backend()],
    policy := route_policy(),
    reasons := [binary()],
    fallback_chain := [beam_agent_backend:backend()],
    affinity_key => binary(),
    policy_profile_id => binary()
}.

-type normalized_request() :: #{
    backend => beam_agent_backend:backend(),
    preferred_backends := [beam_agent_backend:backend()],
    excluded_backends := [beam_agent_backend:backend()],
    fallback_backends := [beam_agent_backend:backend()],
    capabilities := [beam_agent_capabilities:capability()],
    policy := route_policy(),
    affinity_key => binary(),
    policy_profile_id => binary(),
    last_backend => beam_agent_backend:backend(),
    fallback_policy := fallback_policy(),
    health := #{beam_agent_backend:backend() => health_status()}
}.

-type candidate_sets() :: #{
    eligible := [beam_agent_backend:backend()],
    preferred := [beam_agent_backend:backend()],
    fallback := [beam_agent_backend:backend()],
    remaining := [beam_agent_backend:backend()],
    ordered := [beam_agent_backend:backend()]
}.
-type default_route_policy() :: explicit | preferred_then_fallback.
-type selection_reason_text() :: <<_:64, _:_*8>>.
-type no_backend_error() :: {error, {no_backend_available, #{
    policy := route_policy(),
    requested_capabilities := [beam_agent_capabilities:capability()],
    preferred_backends := [beam_agent_backend:backend()],
    excluded_backends := [beam_agent_backend:backend()],
    eligible_backends := [beam_agent_backend:backend()]
}}}.
-type route_key() :: {routing,
    route_policy(),
    boolean(),
    [beam_agent_backend:backend(), ...],
    [beam_agent_capabilities:capability()],
    [beam_agent_backend:backend()],
    [beam_agent_backend:backend()],
    [beam_agent_backend:backend()]}.
-type routing_operation() :: select_backend.
-type routing_decision_meta() :: #{
    backend := beam_agent_backend:backend(),
    candidate_count := non_neg_integer(),
    fallback_count := non_neg_integer(),
    policy := route_policy(),
    reason_count := non_neg_integer()
}.
-type routing_telemetry_meta() :: #{
    backend := beam_agent_backend:backend(),
    candidate_count := non_neg_integer(),
    fallback_count := non_neg_integer(),
    policy := route_policy(),
    reason_count := non_neg_integer(),
    decision := allow | {deny, binary()}
}.
-type routing_optional_key() ::
    affinity_key | backend | last_backend | policy_profile_id | profile_id | reason |
    reasons.
-type routing_put_map() ::
    route_request()
  | route_decision()
  | normalized_request()
  | routing_telemetry_meta()
  | #{
        candidates := [beam_agent_backend:backend()],
        decision := allow | deny,
        fallback_chain := [term()],
        atom() => term()
    }.

-define(AFFINITY_TABLE, beam_agent_routing_affinity).
-define(ROUND_ROBIN_TABLE, beam_agent_routing_round_robin).
-define(STORE_DOMAIN, routing).
-define(SUPPORTED_KEYS,
    [backend, preferred_backends, excluded_backends, fallback_backends,
     capabilities, policy, affinity_key, policy_profile_id, last_backend,
     fallback_policy, health]).

-doc "Ensure routing state tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?AFFINITY_TABLE, [set,
        named_table,
        {read_concurrency, true}]),
    beam_agent_store:ensure_table(?STORE_DOMAIN, ?ROUND_ROBIN_TABLE, [set,
        named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear sticky affinity and round-robin routing state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?AFFINITY_TABLE),
    beam_agent_store:delete_all_objects(?STORE_DOMAIN, ?ROUND_ROBIN_TABLE),
    ok.

-doc """
Select a backend using a normalized routing request.

Supported request keys:

  - `backend`
  - `preferred_backends`
  - `excluded_backends`
  - `fallback_backends`
  - `capabilities`
  - `policy`
  - `affinity_key`
  - `last_backend`
  - `fallback_policy`
  - `health`
""".
-spec select_backend(route_request()) ->
    {ok, route_decision()} |
    {error, term()}.
select_backend(RouteRequest) when is_map(RouteRequest) ->
    ensure_tables(),
    TeleMeta = telemetry_request_meta(RouteRequest),
    StartTime = telemetry_start(select_backend, TeleMeta),
    Result = case normalize_request(RouteRequest) of
        {ok, Normalized} ->
            case choose_backend(Normalized) of
                {ok, Decision0} ->
                    Decision = maybe_put(policy_profile_id,
                        maps:get(policy_profile_id, Normalized, undefined), Decision0),
                    case enforce_route_policy(Normalized, Decision) of
                        allow ->
                            ok = persist_decision(Normalized, Decision),
                            _ = append_routing_event(Normalized, Decision),
                            ok = audit_routing_decision(Normalized, Decision, allow, undefined),
                            {ok, Decision, allow};
                        {deny, Reason} ->
                            ok = audit_routing_decision(Normalized, Decision, deny, Reason),
                            {error, {policy_denied, Reason}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end,
    case Result of
        {ok, DecisionMap, DecisionResult} ->
            telemetry_stop(select_backend, StartTime,
                (telemetry_decision_meta(DecisionMap))#{
                    decision => DecisionResult
                }),
            {ok, DecisionMap};
        {error, _} = ErrorResult ->
            telemetry_exception(select_backend, ErrorResult, TeleMeta),
            ErrorResult
    end.

-doc """
Select a backend after deriving defaults from a session identity or session opts.

When the first argument is a session opts map, any `backend` and `routing`
values are turned into a base routing request before merging `RouteRequest`.
When it is a live session pid or persisted session id, the router uses the
current backend as `last_backend`; persisted session ids also become the
default sticky `affinity_key`.
""".
-spec select_backend(pid() | binary() | map(), route_request()) ->
    {ok, route_decision()} | {error, term()}.
select_backend(SessionOrOpts, RouteRequest) when is_map(RouteRequest) ->
    case base_request(SessionOrOpts) of
        {ok, Base} ->
            select_backend(maps:merge(Base, RouteRequest));
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal selection
%%--------------------------------------------------------------------

-spec choose_backend(normalized_request()) ->
    {ok, route_decision()} | {error, term()}.
choose_backend(Request) ->
    Candidates = candidate_sets(Request),
    case maps:get(policy, Request) of
        explicit ->
            choose_explicit(Request, Candidates);
        preferred_then_fallback ->
            choose_preferred_then_fallback(Request, Candidates);
        capability_first ->
            choose_capability_first(Request, Candidates);
        round_robin ->
            choose_round_robin(Request, Candidates, false);
        sticky ->
            choose_sticky(Request, Candidates);
        failover ->
            choose_failover(Request, Candidates)
    end.

-spec choose_explicit(normalized_request(), candidate_sets()) ->
    {ok, route_decision()} | {error, term()}.
choose_explicit(Request, Candidates) ->
    case maps:get(backend, Request, undefined) of
        undefined ->
            case maps:get(ordered, Candidates) of
                [Backend | _] ->
                    {ok, decision(Backend, Candidates, explicit,
                        [<<"selected first explicit candidate">>], Request)};
                [] ->
                    no_backend_error(Request, Candidates)
            end;
        Backend ->
            Eligible = maps:get(eligible, Candidates),
            case lists:member(Backend, Eligible) of
                true ->
                    Single = Candidates#{
                        ordered => [Backend],
                        preferred => [Backend],
                        fallback => [],
                        remaining => []
                    },
                    {ok, decision(Backend, Single, explicit,
                        [<<"selected explicit backend override">>], Request)};
                false ->
                    {error, {backend_not_eligible, Backend}}
            end
    end.

-spec choose_preferred_then_fallback(normalized_request(), candidate_sets()) ->
    {ok, route_decision()} | {error, term()}.
choose_preferred_then_fallback(Request, Candidates) ->
    case maps:get(ordered, Candidates) of
        [Backend | _] ->
            Reason = selection_reason(Backend, Candidates, Request),
            {ok, decision(Backend, Candidates, preferred_then_fallback,
                [Reason], Request)};
        [] ->
            no_backend_error(Request, Candidates)
    end.

-spec choose_capability_first(normalized_request(), candidate_sets()) ->
    {ok, route_decision()} | {error, term()}.
choose_capability_first(Request, Candidates) ->
    case {maps:get(capabilities, Request), maps:get(eligible, Candidates)} of
        {[_ | _] = Caps, []} ->
            {error, {no_backend_supports_capabilities, Caps}};
        {_, [Backend | _]} ->
            Reason = case maps:get(capabilities, Request) of
                [] ->
                    selection_reason(Backend, Candidates, Request);
                Caps ->
                    list_to_binary(io_lib:format(
                        "selected backend satisfying capabilities ~p", [Caps]))
            end,
            {ok, decision(Backend, Candidates, capability_first,
                [Reason], Request)};
        {_, []} ->
            no_backend_error(Request, Candidates)
    end.

-spec choose_round_robin(normalized_request(), candidate_sets(), boolean()) ->
    {ok, route_decision()} | {error, term()}.
choose_round_robin(Request, Candidates, Sticky) ->
    case maps:get(ordered, Candidates) of
        [] ->
            no_backend_error(Request, Candidates);
        Ordered ->
            RouteKey = route_key(Request, Ordered, Sticky),
            Counter = beam_agent_store:update_counter(?STORE_DOMAIN,
                ?ROUND_ROBIN_TABLE, RouteKey, {2, 1}, {RouteKey, 0}),
            Index = (Counter - 1) rem length(Ordered),
            Backend = lists:nth(Index + 1, Ordered),
            Rotated = rotate_candidates(Ordered, Index),
            Decision0 = #{
                backend => Backend,
                candidates => Rotated,
                policy => round_robin,
                reasons => [<<"selected by round robin policy">>],
                fallback_chain => lists:nthtail(1, Rotated)
            },
            Decision = maybe_put(affinity_key,
                maps:get(affinity_key, Request, undefined), Decision0),
            {ok, Decision}
    end.

-spec choose_sticky(normalized_request(), candidate_sets()) ->
    {ok, route_decision()} | {error, term()}.
choose_sticky(Request, Candidates) ->
    case maps:get(affinity_key, Request, undefined) of
        undefined ->
            {error, {invalid_route_request, affinity_key_required}};
        AffinityKey ->
            case affinity_backend(AffinityKey) of
                {ok, Backend} ->
                    case lists:member(Backend, maps:get(eligible, Candidates)) of
                        true ->
                            Ordered = move_to_front(Backend,
                                maps:get(ordered, Candidates)),
                            {ok, #{
                                backend => Backend,
                                candidates => Ordered,
                                policy => sticky,
                                reasons => [<<"reused sticky affinity backend">>],
                                fallback_chain => lists:nthtail(1, Ordered),
                                affinity_key => AffinityKey
                            }};
                        false ->
                            choose_and_bind_sticky(Request, Candidates, AffinityKey)
                    end;
                error ->
                    choose_and_bind_sticky(Request, Candidates, AffinityKey)
            end
    end.

-spec choose_and_bind_sticky(normalized_request(), candidate_sets(), binary()) ->
    {ok, route_decision()} | {error, term()}.
choose_and_bind_sticky(Request, Candidates, AffinityKey) ->
    case choose_round_robin(Request, Candidates, true) of
        {ok, Decision} ->
            {ok, Decision#{
                policy => sticky,
                reasons => [<<"selected backend and bound sticky affinity">>],
                affinity_key => AffinityKey
            }};
        {error, _} = Error ->
            Error
    end.

-spec choose_failover(normalized_request(), candidate_sets()) ->
    {ok, route_decision()} | {error, term()}.
choose_failover(Request, Candidates) ->
    Ordered0 = maps:get(ordered, Candidates),
    Ordered = deprioritize_last_backend(maps:get(last_backend, Request, undefined), Ordered0),
    case Ordered of
        [Backend | _] ->
            Reason = case maps:get(last_backend, Request, undefined) of
                Backend ->
                    <<"reused last backend because no failover candidate remained">>;
                undefined ->
                    <<"selected first failover candidate">>;
                _ ->
                    <<"skipped last backend and selected failover candidate">>
            end,
            {ok, #{
                backend => Backend,
                candidates => Ordered,
                policy => failover,
                reasons => [Reason],
                fallback_chain => lists:nthtail(1, Ordered)
            }};
        [] ->
            no_backend_error(Request, Candidates)
    end.

-spec candidate_sets(normalized_request()) -> candidate_sets().
candidate_sets(Request) ->
    Available = beam_agent_backend:available_backends(),
    NotExcluded = lists:filter(fun(Backend) ->
        not lists:member(Backend, maps:get(excluded_backends, Request))
    end, Available),
    Healthy = apply_health(NotExcluded, maps:get(health, Request)),
    Eligible = apply_capabilities(Healthy, maps:get(capabilities, Request)),
    Preferred = ordered_subset(maps:get(preferred_backends, Request), Eligible),
    Fallback = ordered_subset(maps:get(fallback_backends, Request),
        lists:subtract(Eligible, Preferred)),
    Remaining = lists:subtract(Eligible, Preferred ++ Fallback),
    Ordered = ordered_candidates(Request, Preferred, Fallback, Remaining, Eligible),
    #{
        eligible => Eligible,
        preferred => Preferred,
        fallback => Fallback,
        remaining => Remaining,
        ordered => Ordered
    }.

-spec ordered_candidates(normalized_request(),
    [beam_agent_backend:backend()],
    [beam_agent_backend:backend()],
    [beam_agent_backend:backend()],
    [beam_agent_backend:backend()]) -> [beam_agent_backend:backend()].
ordered_candidates(Request, Preferred, Fallback, Remaining, Eligible) ->
    case {Preferred, Fallback} of
        {[], []} ->
            Eligible;
        _ ->
            case maps:get(fallback_policy, Request) of
                none ->
                    dedupe_preserve_order(Preferred ++ Fallback);
                available ->
                    dedupe_preserve_order(Preferred ++ Fallback ++ Remaining)
            end
    end.

%%--------------------------------------------------------------------
%% Normalization
%%--------------------------------------------------------------------

-spec normalize_request(route_request()) ->
    {ok, normalized_request()} | {error, term()}.
normalize_request(Request) when is_map(Request) ->
    case unsupported_keys(Request) of
        [] ->
            with_normalized_request(Request);
        [Key | _] ->
            {error, {unsupported_route_key, Key}}
    end.

-spec with_normalized_request(route_request()) ->
    {ok, normalized_request()} | {error, term()}.
with_normalized_request(Request) ->
    Policy0 = maps:get(policy, Request, default_policy(Request)),
    with_policy(Policy0, fun(Policy) ->
        with_optional_backend(maps:get(backend, Request, undefined), fun(Backend) ->
            with_backend_list(preferred_backends, Request, fun(Preferred) ->
                with_backend_list(excluded_backends, Request, fun(Excluded) ->
                    with_backend_list(fallback_backends, Request, fun(Fallback) ->
                        with_capabilities(maps:get(capabilities, Request, []), fun(Caps) ->
                            with_optional_backend(maps:get(last_backend, Request, undefined),
                                fun(LastBackend) ->
                                    with_fallback_policy(
                                        maps:get(fallback_policy, Request, available),
                                        fun(FallbackPolicy) ->
                                            with_affinity(
                                                maps:get(affinity_key, Request, undefined),
                                                fun(AffinityKey) ->
                                                    with_optional_binary(
                                                        policy_profile_id, Request,
                                                        fun(ProfileId) ->
                                                            with_health(
                                                                maps:get(health, Request, #{}),
                                                                fun(Health) ->
                                                                    Base = #{
                                                                        preferred_backends => Preferred,
                                                                        excluded_backends => Excluded,
                                                                        fallback_backends => Fallback,
                                                                        capabilities => Caps,
                                                                        policy => Policy,
                                                                        fallback_policy => FallbackPolicy,
                                                                        health => Health
                                                                    },
                                                                    {ok, maybe_put(last_backend,
                                                                        LastBackend,
                                                                        maybe_put(backend,
                                                                            Backend,
                                                                            maybe_put(affinity_key,
                                                                                AffinityKey,
                                                                                maybe_put(
                                                                                    policy_profile_id,
                                                                                    ProfileId,
                                                                                    Base))))}
                                                                end)
                                                        end)
                                                end)
                                        end)
                                end)
                        end)
                    end)
                end)
            end)
        end)
    end).

-spec default_policy(route_request()) -> default_route_policy().
default_policy(Request) ->
    case maps:get(backend, Request, undefined) of
        undefined ->
            preferred_then_fallback;
        auto ->
            preferred_then_fallback;
        <<"auto">> ->
            preferred_then_fallback;
        "auto" ->
            preferred_then_fallback;
        _ ->
            explicit
    end.

-spec unsupported_keys(map()) -> [atom()].
unsupported_keys(Request) ->
    [Key || Key <- maps:keys(Request),
            is_atom(Key),
            not lists:member(Key, ?SUPPORTED_KEYS)].

-spec with_policy(term(), fun((route_policy()) -> Result)) ->
    Result | {error, {invalid_policy, term()}}.
with_policy(explicit, Fun) -> Fun(explicit);
with_policy(sticky, Fun) -> Fun(sticky);
with_policy(round_robin, Fun) -> Fun(round_robin);
with_policy(failover, Fun) -> Fun(failover);
with_policy(capability_first, Fun) -> Fun(capability_first);
with_policy(preferred_then_fallback, Fun) -> Fun(preferred_then_fallback);
with_policy(Value, _Fun) -> {error, {invalid_policy, Value}}.

-spec with_optional_binary(atom(), map(), fun((binary() | undefined) -> Result)) ->
    Result | {error, {invalid_route_request, atom()}}.
with_optional_binary(Key, Request, Fun) ->
    case maps:get(Key, Request, undefined) of
        undefined ->
            Fun(undefined);
        Value when is_binary(Value), byte_size(Value) > 0 ->
            Fun(Value);
        _ ->
            {error, {invalid_route_request, Key}}
    end.

-spec enforce_route_policy(normalized_request(), route_decision()) ->
    allow | {deny, binary()}.
enforce_route_policy(Request, Decision) ->
    beam_agent_policy_core:evaluate(
        maps:get(policy_profile_id, Request, undefined),
        backend,
        #{
            backend => maps:get(backend, Decision),
            decision => Decision,
            request => maps:remove(health, Request)
        }
    ).

-spec audit_routing_decision(normalized_request(), route_decision(),
    allow | deny, binary() | undefined) -> ok.
audit_routing_decision(Request, Decision, DecisionResult, Reason) ->
    Scope = maybe_put(profile_id, maps:get(policy_profile_id, Request, undefined), #{}),
    Details0 = #{
        decision => DecisionResult,
        backend => maps:get(backend, Decision),
        policy => maps:get(policy, Decision),
        candidates => maps:get(candidates, Decision),
        fallback_chain => maps:get(fallback_chain, Decision)
    },
    Details1 = maybe_put(reasons, maps:get(reasons, Decision, undefined), Details0),
    Details = maybe_put(reason, Reason, Details1),
    case beam_agent_audit_core:record(routing, decision, Scope, Details) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

-spec with_fallback_policy(term(), fun((fallback_policy()) -> Result)) ->
    Result | {error, {invalid_fallback_policy, term()}}.
with_fallback_policy(none, Fun) -> Fun(none);
with_fallback_policy(available, Fun) -> Fun(available);
with_fallback_policy(Value, _Fun) -> {error, {invalid_fallback_policy, Value}}.

-spec with_optional_backend(term(), fun((beam_agent_backend:backend() | undefined) -> Result)) ->
    Result | {error, term()}.
with_optional_backend(undefined, Fun) -> Fun(undefined);
with_optional_backend(auto, Fun) -> Fun(undefined);
with_optional_backend(<<"auto">>, Fun) -> Fun(undefined);
with_optional_backend("auto", Fun) -> Fun(undefined);
with_optional_backend(Value, Fun) ->
    case beam_agent_backend:normalize(Value) of
        {ok, Backend} -> Fun(Backend);
        {error, _} = Error -> Error
    end.

-spec with_backend_list(atom(), map(), fun(([beam_agent_backend:backend()]) -> Result)) ->
    Result | {error, term()}.
with_backend_list(Key, Request, Fun) ->
    case maps:get(Key, Request, []) of
        Backends when is_list(Backends) ->
            case normalize_backend_list(Backends, []) of
                {ok, Normalized} -> Fun(Normalized);
                {error, _} = Error -> Error
            end;
        Value ->
            case normalize_backend_list([Value], []) of
                {ok, Normalized} -> Fun(Normalized);
                {error, _} = Error -> Error
            end
    end.

-spec normalize_backend_list([term()], [beam_agent_backend:backend()]) ->
    {ok, [beam_agent_backend:backend()]} | {error, term()}.
normalize_backend_list([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_backend_list([Value | Rest], Acc) ->
    case beam_agent_backend:normalize(Value) of
        {ok, Backend} ->
            NextAcc = case lists:member(Backend, Acc) of
                true -> Acc;
                false -> [Backend | Acc]
            end,
            normalize_backend_list(Rest, NextAcc);
        {error, _} = Error ->
            Error
    end.

-spec with_capabilities(term(), fun(([beam_agent_capabilities:capability()]) -> Result)) ->
    Result | {error, term()}.
with_capabilities(Caps, Fun) when is_list(Caps) ->
    case normalize_capabilities(Caps, []) of
        {ok, Normalized} -> Fun(Normalized);
        {error, _} = Error -> Error
    end;
with_capabilities(_, _Fun) ->
    {error, {invalid_route_request, capabilities}}.

-spec normalize_capabilities([term()], [beam_agent_capabilities:capability()]) ->
    {ok, [beam_agent_capabilities:capability()]} | {error, term()}.
normalize_capabilities([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_capabilities([Capability | Rest], Acc) when is_atom(Capability) ->
    case lists:member(Capability, beam_agent_capabilities:capability_ids()) of
        true ->
            NextAcc = case lists:member(Capability, Acc) of
                true -> Acc;
                false -> [Capability | Acc]
            end,
            normalize_capabilities(Rest, NextAcc);
        false ->
            {error, {unknown_capability, Capability}}
    end;
normalize_capabilities([Capability | _], _Acc) ->
    {error, {unknown_capability, Capability}}.

-spec with_affinity(term(), fun((binary() | undefined) -> Result)) ->
    Result | {error, {invalid_affinity_key, term()}}.
with_affinity(undefined, Fun) -> Fun(undefined);
with_affinity(Value, Fun) when is_binary(Value), byte_size(Value) > 0 -> Fun(Value);
with_affinity(Value, _Fun) -> {error, {invalid_affinity_key, Value}}.

-spec with_health(term(), fun((#{beam_agent_backend:backend() => health_status()}) -> Result)) ->
    Result | {error, term()}.
with_health(Health, Fun) when is_map(Health) ->
    case normalize_health(maps:to_list(Health), #{}) of
        {ok, Normalized} -> Fun(Normalized);
        {error, _} = Error -> Error
    end;
with_health(Value, _Fun) ->
    {error, {invalid_route_request, {health, Value}}}.

-spec normalize_health([{term(), term()}], #{beam_agent_backend:backend() => health_status()}) ->
    {ok, #{beam_agent_backend:backend() => health_status()}} | {error, term()}.
normalize_health([], Acc) ->
    {ok, Acc};
normalize_health([{BackendLike, Status} | Rest], Acc) ->
    case beam_agent_backend:normalize(BackendLike) of
        {ok, Backend} ->
            case normalize_health_status(Status) of
                {ok, HealthStatus} ->
                    normalize_health(Rest, Acc#{Backend => HealthStatus});
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec normalize_health_status(term()) ->
    {ok, health_status()} | {error, {invalid_health_status, term()}}.
normalize_health_status(healthy) -> {ok, healthy};
normalize_health_status(degraded) -> {ok, degraded};
normalize_health_status(unhealthy) -> {ok, unhealthy};
normalize_health_status(down) -> {ok, down};
normalize_health_status(Value) -> {error, {invalid_health_status, Value}}.

%%--------------------------------------------------------------------
%% Selection helpers
%%--------------------------------------------------------------------

-spec apply_health([beam_agent_backend:backend()],
    #{beam_agent_backend:backend() => health_status()}) ->
    [beam_agent_backend:backend()].
apply_health(Backends, Health) ->
    lists:filter(fun(Backend) ->
        case maps:get(Backend, Health, healthy) of
            unhealthy -> false;
            down -> false;
            healthy -> true;
            degraded -> true
        end
    end, Backends).

-spec apply_capabilities([beam_agent_backend:backend()],
    [beam_agent_capabilities:capability()]) -> [beam_agent_backend:backend()].
apply_capabilities(Backends, []) ->
    Backends;
apply_capabilities(Backends, Capabilities) ->
    [Backend || Backend <- Backends,
        lists:all(fun(Capability) ->
            beam_agent_capabilities:supports(Capability, Backend) =:= {ok, true}
        end, Capabilities)].

-spec ordered_subset([beam_agent_backend:backend()], [beam_agent_backend:backend()]) ->
    [beam_agent_backend:backend()].
ordered_subset(Requested, Eligible) ->
    [Backend || Backend <- Requested, lists:member(Backend, Eligible)].

-spec selection_reason(beam_agent_backend:backend(), candidate_sets(),
    normalized_request()) -> selection_reason_text().
selection_reason(Backend, Candidates, _Request) ->
    case lists:member(Backend, maps:get(preferred, Candidates)) of
        true ->
            <<"selected preferred backend">>;
        false ->
            case lists:member(Backend, maps:get(fallback, Candidates)) of
                true -> <<"selected fallback backend">>;
                false -> <<"selected first eligible backend">>
            end
    end.

-spec decision(beam_agent_backend:backend(), candidate_sets(), route_policy(),
    [binary()], normalized_request()) -> route_decision().
decision(Backend, Candidates, Policy, Reasons, Request) ->
    Ordered = move_to_front(Backend, maps:get(ordered, Candidates)),
    Decision0 = #{
        backend => Backend,
        candidates => Ordered,
        policy => Policy,
        reasons => Reasons,
        fallback_chain => lists:nthtail(1, Ordered)
    },
    maybe_put(affinity_key, maps:get(affinity_key, Request, undefined), Decision0).

-spec no_backend_error(normalized_request(), candidate_sets()) -> no_backend_error().
no_backend_error(Request, Candidates) ->
    {error, {no_backend_available, #{
        policy => maps:get(policy, Request),
        requested_capabilities => maps:get(capabilities, Request),
        preferred_backends => maps:get(preferred_backends, Request),
        excluded_backends => maps:get(excluded_backends, Request),
        eligible_backends => maps:get(eligible, Candidates)
    }}}.

-spec route_key(normalized_request(), [beam_agent_backend:backend(), ...], boolean()) ->
    route_key().
route_key(Request, Candidates, Sticky) ->
    {routing,
     maps:get(policy, Request),
     Sticky,
     Candidates,
     maps:get(capabilities, Request),
     maps:get(preferred_backends, Request),
     maps:get(fallback_backends, Request),
     maps:get(excluded_backends, Request)}.

-spec rotate_candidates([beam_agent_backend:backend(), ...], non_neg_integer()) ->
    [beam_agent_backend:backend()].
rotate_candidates(Candidates, 0) ->
    Candidates;
rotate_candidates(Candidates, Index) ->
    {Head, Tail} = lists:split(Index, Candidates),
    Tail ++ Head.

-spec move_to_front(beam_agent_backend:backend(), [beam_agent_backend:backend()]) ->
    [beam_agent_backend:backend()].
move_to_front(Backend, Candidates) ->
    [Backend | [Candidate || Candidate <- Candidates, Candidate =/= Backend]].

-spec deprioritize_last_backend(beam_agent_backend:backend() | undefined,
    [beam_agent_backend:backend()]) -> [beam_agent_backend:backend()].
deprioritize_last_backend(undefined, Candidates) ->
    Candidates;
deprioritize_last_backend(LastBackend, Candidates) ->
    case lists:member(LastBackend, Candidates) of
        false ->
            Candidates;
        true when length(Candidates) =:= 1 ->
            Candidates;
        true ->
            [Backend || Backend <- Candidates, Backend =/= LastBackend] ++ [LastBackend]
    end.

-spec dedupe_preserve_order([beam_agent_backend:backend()]) ->
    [beam_agent_backend:backend()].
dedupe_preserve_order(Backends) ->
    dedupe_preserve_order(Backends, []).

-spec dedupe_preserve_order([beam_agent_backend:backend()], [beam_agent_backend:backend()]) ->
    [beam_agent_backend:backend()].
dedupe_preserve_order([], Acc) ->
    lists:reverse(Acc);
dedupe_preserve_order([Backend | Rest], Acc) ->
    NextAcc = case lists:member(Backend, Acc) of
        true -> Acc;
        false -> [Backend | Acc]
    end,
    dedupe_preserve_order(Rest, NextAcc).

%%--------------------------------------------------------------------
%% State and journal helpers
%%--------------------------------------------------------------------

-spec persist_decision(normalized_request(), route_decision()) -> ok.
persist_decision(Request, Decision) ->
    case maps:get(policy, Request) of
        sticky ->
            case maps:get(affinity_key, Decision, undefined) of
                AffinityKey when is_binary(AffinityKey) ->
                    true = beam_agent_store:insert(?STORE_DOMAIN, ?AFFINITY_TABLE,
                        {AffinityKey, maps:get(backend, Decision)}),
                    ok;
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

-spec affinity_backend(binary()) ->
    {ok, beam_agent_backend:backend()} | error.
affinity_backend(AffinityKey) ->
    case beam_agent_store:lookup(?STORE_DOMAIN, ?AFFINITY_TABLE, AffinityKey) of
        [{_, Backend}] -> {ok, Backend};
        [] -> error
    end.

-spec append_routing_event(normalized_request(), route_decision()) ->
    {ok, beam_agent_journal_core:entry()} | {error, term()}.
append_routing_event(Request, Decision) ->
    Payload = #{
        request => journal_request(Request),
        decision => Decision
    },
    beam_agent_journal_core:append(<<"routing_selected">>, #{
        tags => [routing],
        payload => Payload
    }).

-spec journal_request(normalized_request()) -> map().
journal_request(Request) ->
    maps:with([backend, preferred_backends, excluded_backends, fallback_backends,
        capabilities, policy, affinity_key, last_backend, fallback_policy],
        Request).

-spec base_request(pid() | binary() | map()) -> {ok, route_request()} | {error, term()}.
base_request(Opts) when is_map(Opts) ->
    case maps:get(routing, Opts, #{}) of
        Routing when is_map(Routing) ->
            base_request_from_opts(Opts, Routing);
        Value ->
            {error, {invalid_route_request, {routing, Value}}}
    end;
base_request(SessionId) when is_binary(SessionId) ->
    Request0 = case beam_agent_backend:session_backend(SessionId) of
        {ok, Backend} -> #{last_backend => Backend};
        {error, _} -> #{}
    end,
    {ok, Request0#{affinity_key => SessionId}};
base_request(Session) when is_pid(Session) ->
    Request = case beam_agent_backend:session_backend(Session) of
        {ok, Backend} -> #{last_backend => Backend};
        {error, _} -> #{}
    end,
    {ok, Request}.

-spec base_request_from_opts(map(), route_request()) -> {ok, route_request()}.
base_request_from_opts(Opts, Routing) ->
    case maps:get(backend, Opts, undefined) of
        undefined ->
            {ok, Routing};
        auto ->
            {ok, Routing};
        <<"auto">> ->
            {ok, Routing};
        "auto" ->
            {ok, Routing};
        Backend ->
            {ok, Routing#{backend => Backend, policy => explicit}}
    end.

-spec maybe_put(routing_optional_key(), term(), routing_put_map()) -> routing_put_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

-spec telemetry_start(routing_operation(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry_core:span_start(routing, Operation, compact_telemetry(Metadata)).

-spec telemetry_stop(routing_operation(), integer(), routing_telemetry_meta()) -> ok.
telemetry_stop(Operation, StartTime, Metadata) ->
    beam_agent_telemetry_core:span_stop(routing, Operation, StartTime,
        compact_telemetry(Metadata)).

-spec telemetry_exception(routing_operation(), {error, {atom(), term()}}, map()) -> ok.
telemetry_exception(Operation, Reason, Metadata) ->
    beam_agent_telemetry_core:span_exception(routing, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_request_meta(map()) -> map().
telemetry_request_meta(Request) ->
    maps:with([backend, policy, affinity_key, policy_profile_id, last_backend,
        fallback_policy], Request).

-spec telemetry_decision_meta(route_decision()) -> routing_decision_meta().
telemetry_decision_meta(Decision) ->
    #{
        backend => maps:get(backend, Decision),
        policy => maps:get(policy, Decision),
        candidate_count => length(maps:get(candidates, Decision, [])),
        fallback_count => length(maps:get(fallback_chain, Decision, [])),
        reason_count => length(maps:get(reasons, Decision, []))
    }.

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).
