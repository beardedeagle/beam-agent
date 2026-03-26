-module(beam_agent_context_core).
-moduledoc """
Canonical policy-driven context management for BeamAgent.

This module builds on the existing session summary and universal thread
compaction primitives to provide a process-free context policy layer.
It can estimate budget pressure, report current context status, and apply
policy-driven compaction with optional memory promotion before visible
thread history is reduced.
""".

-export([
    context_status/1,
    budget_estimate/1,
    compact_now/2,
    maybe_compact/2
]).

-export_type([
    scope/0,
    context_status/0,
    budget_estimate_result/0,
    context_error/0,
    compact_now_result/0,
    maybe_compact_result/0
]).

-type scope() ::
    pid()
  | binary()
  | #{
        session_id := binary(),
        thread_id => binary()
    }.

-type resolved_scope() :: #{
    session_id := binary(),
    thread_id => binary()
}.
-type context_error() :: invalid_scope | not_found.
-type budget_snapshot() :: #{
    scope := resolved_scope(),
    session_message_count := non_neg_integer(),
    visible_message_count := non_neg_integer(),
    estimated_content_bytes := non_neg_integer(),
    estimated_token_count := non_neg_integer(),
    idle_ms := non_neg_integer(),
    summary_present := boolean(),
    memory_count := non_neg_integer()
}.
-type compaction_trigger() ::
    estimated_token_threshold
  | idle_ms_threshold
  | message_count_threshold
  | task_boundary
  | visible_message_threshold.
-type summary_result() :: #{
    generated := boolean(),
    summary => beam_agent_session_store_core:session_summary()
}.
-type memory_promotion_result() :: #{
    promoted := boolean(),
    memory => beam_agent_memory:memory_record(),
    error => term()
}.
-type compact_selector() :: #{
    count => term(),
    message_id => term(),
    uuid => term(),
    visible_message_count => term()
}.
-type thread_compaction_result() :: #{
    compacted := boolean(),
    selector => compact_selector(),
    thread => beam_agent_threads_core:thread_meta(),
    error => invalid_selector | not_found
}.
-type compact_now_result() :: #{
    compacted := boolean(),
    scope := resolved_scope(),
    session_summary := summary_result(),
    memory := memory_promotion_result(),
    thread_compaction := thread_compaction_result(),
    budget_after := budget_estimate_result()
}.
-type maybe_compact_result() :: #{
    compacted := boolean(),
    scope := resolved_scope(),
    budget_before := budget_estimate_result(),
    triggers := [compaction_trigger()],
    budget_after => budget_estimate_result(),
    session_summary => summary_result(),
    memory => memory_promotion_result(),
    thread_compaction => thread_compaction_result()
}.
-type context_result() :: context_status() | budget_estimate_result() |
    compact_now_result() | maybe_compact_result().
-type context_operation() :: context_status | budget_estimate | compact_now | maybe_compact.

-type budget_estimate_result() :: #{
    scope := resolved_scope(),
    session_message_count := non_neg_integer(),
    visible_message_count := non_neg_integer(),
    estimated_content_bytes := non_neg_integer(),
    estimated_token_count := non_neg_integer(),
    idle_ms := non_neg_integer(),
    summary_present := boolean(),
    memory_count := non_neg_integer(),
    triggers := [compaction_trigger()],
    recommended := boolean()
}.

-type context_status() :: #{
    scope := resolved_scope(),
    budget := budget_estimate_result(),
    session_summary => beam_agent_session_store_core:session_summary(),
    thread => beam_agent_threads_core:thread_meta()
}.

-doc "Return current context pressure and available summary/memory state.".
-spec context_status(scope()) -> {ok, context_status()} | {error, context_error()}.
context_status(SessionOrThread) ->
    TeleMeta = telemetry_scope_meta(SessionOrThread, #{}),
    StartTime = telemetry_start(context_status, TeleMeta),
    Result = case resolve_scope(SessionOrThread, #{}) of
        {ok, #{session_id := SessionId} = Scope} ->
            case budget_estimate_for_scope(Scope, #{}) of
                {ok, Budget} ->
                    Status0 = #{
                        scope => Scope,
                        budget => Budget
                    },
                    Status1 = case beam_agent_session_store_core:get_summary(
                        SessionId) of
                        {ok, Summary} -> Status0#{session_summary => Summary};
                        {error, not_found} -> Status0
                    end,
                    Status2 = case maps:get(thread_id, Scope, undefined) of
                        ThreadId when is_binary(ThreadId) ->
                            case beam_agent_threads_core:get_thread(
                                SessionId, ThreadId) of
                                {ok, Thread} -> Status1#{thread => Thread};
                                {error, not_found} -> Status1
                            end;
                        _ ->
                            Status1
                    end,
                    {ok, Status2};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(context_status, StartTime, Result, TeleMeta),
    Result.

-doc "Estimate current context budget pressure using default policy thresholds.".
-spec budget_estimate(scope()) -> {ok, budget_estimate_result()} | {error, context_error()}.
budget_estimate(SessionOrThread) ->
    TeleMeta = telemetry_scope_meta(SessionOrThread, #{}),
    StartTime = telemetry_start(budget_estimate, TeleMeta),
    Result = case resolve_scope(SessionOrThread, #{}) of
        {ok, Scope} ->
            budget_estimate_for_scope(Scope, #{});
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(budget_estimate, StartTime, Result, TeleMeta),
    Result.

-doc """
Summarize a session, optionally promote the summary to memory, and compact the
thread scope immediately.
""".
-spec compact_now(scope(), map()) ->
    {ok, compact_now_result()}
  | {error, context_error() | {hook_denied, binary()} | {hook_ask, binary()}}.
compact_now(SessionOrThread, Opts) when is_map(Opts) ->
    TeleMeta = telemetry_scope_meta(SessionOrThread, Opts),
    StartTime = telemetry_start(compact_now, TeleMeta),
    Result = case resolve_scope(SessionOrThread, Opts) of
        {ok, Scope} ->
            case maybe_fire_pre_compact(Scope, Opts) of
                {deny, Reason} ->
                    {error, {hook_denied, Reason}};
                {ask, Reason} ->
                    {error, {hook_ask, Reason}};
                {ok, _} ->
                    compact_now_for_scope(Scope, Opts)
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(compact_now, StartTime, Result, TeleMeta),
    Result.

-doc """
Evaluate compaction policy and compact only when at least one trigger fires.

Supported triggers:

  - `message_count_threshold`
  - `visible_message_threshold`
  - `estimated_token_threshold`
  - `idle_ms_threshold`
  - `task_boundary`
""".
-spec maybe_compact(scope(), map()) ->
    {ok, maybe_compact_result()}
  | {error, context_error() | {hook_denied, binary()} | {hook_ask, binary()}}.
maybe_compact(SessionOrThread, Opts) when is_map(Opts) ->
    TeleMeta = telemetry_scope_meta(SessionOrThread, Opts),
    StartTime = telemetry_start(maybe_compact, TeleMeta),
    Result = case resolve_scope(SessionOrThread, Opts) of
        {ok, Scope} ->
            case budget_estimate_for_scope(Scope, Opts) of
                {ok, #{triggers := Triggers} = Budget} ->
                    case Triggers of
                        [] ->
                            {ok, #{
                                compacted => false,
                                scope => Scope,
                                budget_before => Budget,
                                triggers => []
                            }};
                        Triggers ->
                            case maybe_fire_pre_compact(Scope, Opts) of
                                {deny, Reason} ->
                                    {error, {hook_denied, Reason}};
                                {ask, Reason} ->
                                    {error, {hook_ask, Reason}};
                                {ok, _} ->
                                    case compact_now_for_scope(Scope, Opts) of
                                        {ok, CompactResult} ->
                                            {ok, CompactResult#{
                                                budget_before => Budget,
                                                triggers => Triggers
                                            }};
                                        {error, _} = Error ->
                                            Error
                                    end
                            end
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end,
    telemetry_finish(maybe_compact, StartTime, Result, TeleMeta),
    Result.

%%--------------------------------------------------------------------
%% Internal: pre_compact hook gate
%%--------------------------------------------------------------------

%% Fire the pre_compact blocking hook before compaction.
%% Always calls fire/3 so global hooks fire even when no per-session
%% registry is present in Opts.
-spec maybe_fire_pre_compact(resolved_scope(), map()) ->
    {ok, beam_agent_hooks_core:hook_context()}
  | {deny, binary()}
  | {ask, binary()}.
maybe_fire_pre_compact(#{session_id := SessionId}, Opts) ->
    HookReg = maps:get(sdk_hook_registry, Opts, undefined),
    beam_agent_hooks_core:fire(pre_compact,
        #{event => pre_compact, session_id => SessionId},
        HookReg).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec compact_now_for_scope(resolved_scope(), map()) ->
    {ok, compact_now_result()} | {error, not_found}.
compact_now_for_scope(#{session_id := SessionId} = Scope, Opts) ->
    case beam_agent_session_store_core:get_session(SessionId) of
        {ok, _Meta} ->
            {ok, Budget} = budget_estimate_for_scope(Scope, Opts),
            {SummaryResult, SummaryContent} = maybe_summarize_session(SessionId, Opts),
            MemoryResult = maybe_promote_summary(Scope, SummaryContent, Opts),
            ThreadResult = maybe_compact_thread(Scope, Opts),
            {ok, #{
                compacted => summary_changed(SummaryResult) orelse
                    thread_compacted(ThreadResult),
                scope => Scope,
                session_summary => SummaryResult,
                memory => MemoryResult,
                thread_compaction => ThreadResult,
                budget_after => maps:get(budget_after,
                    recompute_budget(Scope, Opts, Budget), Budget)
            }};
        {error, not_found} ->
            {error, not_found}
    end.

-spec budget_estimate_for_scope(resolved_scope(), map()) ->
    {ok, budget_estimate_result()} | {error, not_found}.
budget_estimate_for_scope(#{session_id := SessionId} = Scope, Opts) ->
    case beam_agent_session_store_core:get_session(SessionId) of
        {ok, Meta} ->
            {ok, SessionMessages} = beam_agent_session_store_core:get_session_messages(SessionId),
            VisibleCount = visible_message_count(Scope),
            Bytes = estimated_content_bytes(SessionMessages),
            Tokens = estimated_token_count(Bytes),
            IdleMs = max(0, erlang:system_time(millisecond) - maps:get(updated_at, Meta, 0)),
            SummaryPresent = is_ok(beam_agent_session_store_core:get_summary(SessionId)),
            MemoryCount = scope_memory_count(Scope),
            Budget0 = #{
                scope => Scope,
                session_message_count => length(SessionMessages),
                visible_message_count => VisibleCount,
                estimated_content_bytes => Bytes,
                estimated_token_count => Tokens,
                idle_ms => IdleMs,
                summary_present => SummaryPresent,
                memory_count => MemoryCount
            },
            Triggers = compaction_triggers(Budget0, Opts),
            {ok, Budget0#{
                triggers => Triggers,
                recommended => (Triggers =/= [])
            }};
        {error, not_found} ->
            {error, not_found}
    end.

-spec resolve_scope(scope(), map()) -> {ok, resolved_scope()} | {error, invalid_scope}.
resolve_scope(Session, Opts) when is_pid(Session) ->
    resolve_scope(beam_agent_core:session_identity(Session), Opts);
resolve_scope(SessionId, Opts) when is_binary(SessionId), byte_size(SessionId) > 0 ->
    resolve_scope_from_parts(SessionId,
        maps:get(thread_id, Opts, undefined));
resolve_scope(#{session_id := SessionId} = Scope, Opts)
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    resolve_scope_from_parts(SessionId,
        maps:get(thread_id, Scope, maps:get(thread_id, Opts, undefined)));
resolve_scope(_Other, _Opts) ->
    {error, invalid_scope}.

-spec resolve_scope_from_parts(binary(), term()) ->
    {ok, resolved_scope()} | {error, invalid_scope}.
resolve_scope_from_parts(SessionId, ThreadId) when is_binary(ThreadId), byte_size(ThreadId) > 0 ->
    {ok, #{session_id => SessionId, thread_id => ThreadId}};
resolve_scope_from_parts(SessionId, undefined) ->
    case beam_agent_threads_core:active_thread(SessionId) of
        {ok, ThreadId} ->
            {ok, #{session_id => SessionId, thread_id => ThreadId}};
        {error, _} ->
            {ok, #{session_id => SessionId}}
    end;
resolve_scope_from_parts(_SessionId, _Other) ->
    {error, invalid_scope}.

-spec maybe_summarize_session(binary(), map()) ->
    {map(), binary() | undefined}.
maybe_summarize_session(SessionId, Opts) ->
    case maps:get(summarize_session, Opts, true) of
        false ->
            case beam_agent_session_store_core:get_summary(SessionId) of
                {ok, Summary} ->
                    {#{generated => false, summary => Summary},
                        maps:get(content, Summary, undefined)};
                {error, not_found} ->
                    {#{generated => false}, undefined}
            end;
        true ->
            SummaryOpts = maps:with([content, summary, generated_by], Opts),
            case beam_agent_session_store_core:summarize_session(SessionId, SummaryOpts) of
                {ok, Summary} ->
                    {#{generated => true, summary => Summary},
                        maps:get(content, Summary, undefined)};
                {error, not_found} ->
                    {#{generated => false}, undefined}
            end
    end.

-spec maybe_promote_summary(resolved_scope(), binary() | undefined, map()) ->
    memory_promotion_result().
maybe_promote_summary(_Scope, undefined, _Opts) ->
    #{promoted => false};
maybe_promote_summary(_Scope, _Summary, #{promote_to_memory := false}) ->
    #{promoted => false};
maybe_promote_summary(#{session_id := SessionId} = Scope, SummaryContent, Opts) ->
    ThreadId = maps:get(thread_id, Scope, undefined),
    MemoryScope = case ThreadId of
        ScopeThreadId when is_binary(ScopeThreadId) ->
            #{session_id => SessionId, thread_id => ScopeThreadId};
        _ ->
            SessionId
    end,
    SourceRefs0 = [#{type => session, id => SessionId}],
    SourceRefs = case ThreadId of
        ThreadRefId when is_binary(ThreadRefId) ->
            SourceRefs0 ++ [#{type => thread, id => ThreadRefId}];
        _ ->
            SourceRefs0
    end,
    Input = #{
        kind => maps:get(memory_kind, Opts, context_summary),
        content => SummaryContent,
        salience => maps:get(memory_salience, Opts, 20),
        source_refs => SourceRefs
    },
    Ttl = maps:get(memory_ttl, Opts, undefined),
    Input1 = case Ttl of
        undefined -> Input;
        MemoryTtl -> Input#{ttl => MemoryTtl}
    end,
    case beam_agent_memory:remember(MemoryScope, Input1) of
        {ok, Memory} ->
            #{
                promoted => true,
                memory => Memory
            };
        {error, Reason} ->
            #{
                promoted => false,
                error => Reason
            }
    end.

-spec maybe_compact_thread(resolved_scope(), map()) -> thread_compaction_result().
maybe_compact_thread(#{session_id := SessionId} = Scope, Opts) ->
    case maps:get(compact_thread, Opts, true) of
        false ->
            #{compacted => false};
        true ->
            case maps:get(thread_id, Scope, undefined) of
                ThreadId when is_binary(ThreadId) ->
                    Selector = compact_selector(Opts),
                    case beam_agent_threads_core:rollback_thread(SessionId, ThreadId, Selector) of
                        {ok, Thread} ->
                            #{
                                compacted => true,
                                selector => Selector,
                                thread => Thread
                            };
                        {error, Reason} ->
                            #{
                                compacted => false,
                                error => Reason
                            }
                    end;
                _ ->
                    #{compacted => false}
            end
    end.

-spec compact_selector(map()) -> compact_selector().
compact_selector(Opts) ->
    Selector0 =
        maybe_put_selector(count, maps:get(count, Opts, undefined),
            maybe_put_selector(visible_message_count,
                maps:get(visible_message_count, Opts, undefined),
                maybe_put_selector(message_id,
                    maps:get(message_id, Opts, undefined),
                    maybe_put_selector(uuid, maps:get(uuid, Opts, undefined), #{})))),
    case map_size(Selector0) of
        0 -> #{visible_message_count => 0};
        _ -> Selector0
    end.

-spec visible_message_count(resolved_scope()) -> non_neg_integer().
visible_message_count(#{session_id := SessionId, thread_id := ThreadId}) ->
    case beam_agent_threads_core:get_thread(SessionId, ThreadId) of
        {ok, Thread} ->
            maps:get(visible_message_count, Thread, maps:get(message_count, Thread, 0));
        {error, not_found} ->
            0
    end;
visible_message_count(#{session_id := SessionId}) ->
    case beam_agent_session_store_core:get_session(SessionId) of
        {ok, Meta} ->
            maps:get(message_count, Meta, 0);
        {error, not_found} ->
            0
    end.

-spec estimated_content_bytes([beam_agent_core:message()]) -> non_neg_integer().
estimated_content_bytes(Messages) ->
    lists:sum([byte_size(message_content(Message)) || Message <- Messages]).

-spec estimated_token_count(non_neg_integer()) -> non_neg_integer().
estimated_token_count(Bytes) when is_integer(Bytes), Bytes >= 0 ->
    (Bytes + 3) div 4.

-spec message_content(beam_agent_core:message()) -> binary().
message_content(Message) ->
    case maps:get(content, Message, <<>>) of
        Content when is_binary(Content) ->
            Content;
        Content when is_list(Content) ->
            unicode:characters_to_binary(Content);
        _ ->
            <<>>
    end.

-spec scope_memory_count(resolved_scope()) -> non_neg_integer().
scope_memory_count(#{session_id := SessionId, thread_id := ThreadId}) ->
    case beam_agent_memory:list(#{session_id => SessionId, thread_id => ThreadId}) of
        {ok, Memories} -> length(Memories);
        {error, _} -> 0
    end;
scope_memory_count(#{session_id := SessionId}) ->
    case beam_agent_memory:list(#{session_id => SessionId}) of
        {ok, Memories} -> length(Memories);
        {error, _} -> 0
    end.

-spec compaction_triggers(budget_snapshot(), map()) -> [compaction_trigger()].
%% All Budget fields use maps:get/3 with default 0, meaning "no threshold
%% exceeded" — the safe fallback when a Budget map is partially populated or
%% comes from an unexpected code path during context compaction decisions.
compaction_triggers(Budget, Opts) ->
    maybe_add_trigger(task_boundary, maps:get(task_boundary, Opts, false),
        maybe_add_trigger(idle_ms_threshold,
            over_threshold(maps:get(idle_ms, Budget, 0),
                maps:get(idle_ms_threshold, Opts, undefined)),
            maybe_add_trigger(estimated_token_threshold,
                over_threshold(maps:get(estimated_token_count, Budget, 0),
                    maps:get(estimated_token_threshold, Opts, 16000)),
                maybe_add_trigger(visible_message_threshold,
                    over_threshold(maps:get(visible_message_count, Budget, 0),
                        maps:get(visible_message_threshold, Opts, 80)),
                    maybe_add_trigger(message_count_threshold,
                        over_threshold(maps:get(session_message_count, Budget, 0),
                            maps:get(message_count_threshold, Opts, 200)),
                        []))))).

-spec over_threshold(non_neg_integer(), term()) -> boolean().
over_threshold(_Value, undefined) ->
    false;
over_threshold(Value, Threshold) when is_integer(Threshold), Threshold >= 0 ->
    Value >= Threshold;
over_threshold(_Value, _Threshold) ->
    false.

-spec maybe_add_trigger(compaction_trigger(), boolean(),
    [compaction_trigger()]) -> [compaction_trigger()].
maybe_add_trigger(_Trigger, false, Acc) ->
    Acc;
maybe_add_trigger(Trigger, true, Acc) ->
    [Trigger | Acc].

-spec recompute_budget(resolved_scope(), map(), budget_estimate_result()) ->
    #{budget_after := budget_estimate_result()}.
recompute_budget(Scope, Opts, Fallback) ->
    case budget_estimate_for_scope(Scope, Opts) of
        {ok, BudgetAfter} -> #{budget_after => BudgetAfter};
        {error, _} -> #{budget_after => Fallback}
    end.

-spec summary_changed(summary_result()) -> boolean().
summary_changed(#{generated := true}) ->
    true;
summary_changed(_) ->
    false.

-spec thread_compacted(thread_compaction_result()) -> boolean().
thread_compacted(#{compacted := true}) ->
    true;
thread_compacted(_) ->
    false.

-spec maybe_put_selector(count | message_id | uuid | visible_message_count,
    term(), compact_selector()) -> compact_selector().
maybe_put_selector(_Key, undefined, Acc) ->
    Acc;
maybe_put_selector(Key, Value, Acc) ->
    Acc#{Key => Value}.

-spec is_ok({ok, beam_agent_session_store_core:session_summary()} | {error, not_found}) ->
    boolean().
is_ok({ok, _}) -> true;
is_ok(_) -> false.

-spec telemetry_start(context_operation(), map()) -> integer().
telemetry_start(Operation, Metadata) ->
    beam_agent_telemetry_core:span_start(context, Operation, compact_telemetry(Metadata)).

-spec telemetry_finish(context_operation(), integer(),
    {ok, context_result()} | {error, context_error()}, map()) -> ok.
telemetry_finish(Operation, StartTime, {ok, Result}, Metadata) ->
    TeleMeta = compact_telemetry(maps:merge(Metadata, telemetry_result_meta(Result))),
    beam_agent_telemetry_core:span_stop(context, Operation, StartTime, TeleMeta),
    maybe_emit_compaction_transition(Result, TeleMeta);
telemetry_finish(Operation, _StartTime, {error, Reason}, Metadata) ->
    beam_agent_telemetry_core:span_exception(context, Operation, Reason,
        compact_telemetry(Metadata)).

-spec telemetry_scope_meta(scope(), map()) -> map().
telemetry_scope_meta(Session, _Opts) when is_pid(Session) ->
    #{session_id => beam_agent_core:session_identity(Session)};
telemetry_scope_meta(SessionId, _Opts) when is_binary(SessionId) ->
    #{session_id => SessionId};
telemetry_scope_meta(#{session_id := _} = Scope, _Opts) ->
    maps:with([session_id, thread_id], Scope);
telemetry_scope_meta(_Other, Opts) ->
    maps:with([thread_id], Opts).

-spec telemetry_result_meta(context_result()) -> map().
telemetry_result_meta(Result) ->
    Base = maps:with([compacted, triggers], Result),
    case maps:get(scope, Result, undefined) of
        Scope when is_map(Scope) ->
            maps:merge(Base, maps:with([session_id, thread_id], Scope));
        _ ->
            Base
    end.

-spec maybe_emit_compaction_transition(context_result(), map()) -> ok.
maybe_emit_compaction_transition(#{compacted := true}, Metadata) ->
    beam_agent_telemetry_core:state_change(context, stable, compacted, Metadata);
maybe_emit_compaction_transition(_Result, _Metadata) ->
    ok.

-spec compact_telemetry(map()) -> map().
compact_telemetry(Metadata) ->
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Metadata).
