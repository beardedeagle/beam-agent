-module(beam_agent_events).
-moduledoc """
Universal event subscription and delivery for the BEAM Agent SDK.

Subscribers call `subscribe/1` with a session ID and receive events as
Erlang messages. Events are delivered via `publish/2` and end-of-stream
is signalled via `complete/1`.

## Subscriber Lifecycle

Subscribing inserts records into two ETS tables (subscriptions and
session refs). Unsubscribing removes them and flushes pending messages
from the caller's mailbox.

## Dead Subscriber Cleanup

Events are delivered by sending directly to the subscriber pid. If the
subscriber has died, the message is silently discarded by the BEAM —
no crash, no error.

In **hardened mode**, the table owner process monitors each subscriber
automatically. When a subscriber dies, the owner receives a `'DOWN'`
message and removes its ETS records immediately. No consumer action
is needed.

In **public mode**, cleanup is the consumer's responsibility. The
recommended pattern is to monitor the subscriber from a supervisor
or manager process and call `unsubscribe/2` when it exits:

```erlang
%% In the consumer's gen_server that manages subscribers:
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% Look up the subscription ref for Pid and call:
    beam_agent_events:unsubscribe(SessionId, SubscriptionRef),
    {noreply, remove_subscriber(Pid, State)};
```

Stale ETS entries from dead subscribers in public mode are harmless —
each is a small map — and are removed when `unsubscribe/2` or `clear/0`
is called.
""".

-export([
    ensure_tables/0,
    clear/0,
    subscribe/1,
    unsubscribe/2,
    publish/2,
    complete/1,
    receive_event/2,
    cleanup_dead_subscriber/2
]).

-define(SUBSCRIPTIONS_TABLE, beam_agent_event_subscriptions).
-define(SESSIONS_TABLE, beam_agent_event_session_refs).

-doc "Ensure ETS tables exist for the universal event stream.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SUBSCRIPTIONS_TABLE, [set, named_table,
        {read_concurrency, true}]),
    beam_agent_ets:ensure_table(?SESSIONS_TABLE, [bag, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear every universal event subscription.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?SUBSCRIPTIONS_TABLE),
    beam_agent_ets:delete_all_objects(?SESSIONS_TABLE),
    ok.

-doc "Subscribe the calling process to future events for a session.".
-spec subscribe(binary()) -> {ok, reference()}.
subscribe(SessionId) when is_binary(SessionId), byte_size(SessionId) > 0 ->
    ensure_tables(),
    Ref = make_ref(),
    Owner = self(),
    Metadata = #{session_id => SessionId, owner => Owner},
    beam_agent_ets:insert(?SUBSCRIPTIONS_TABLE, {Ref, Metadata}),
    beam_agent_ets:insert(?SESSIONS_TABLE, {SessionId, Ref}),
    _ = beam_agent_table_owner:monitor_for_cleanup(Owner,
        {?MODULE, cleanup_dead_subscriber, [SessionId, Ref]}),
    {ok, Ref}.

-doc "Remove a universal event subscription.".
-spec unsubscribe(binary(), reference()) -> ok | {error, bad_ref}.
unsubscribe(SessionId, Ref)
  when is_binary(SessionId), is_reference(Ref) ->
    ensure_tables(),
    case ets:lookup(?SUBSCRIPTIONS_TABLE, Ref) of
        [{Ref, #{session_id := SessionId}}] ->
            beam_agent_ets:delete(?SUBSCRIPTIONS_TABLE, Ref),
            beam_agent_ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref}),
            flush_subscription_mailbox(Ref),
            ok;
        _ ->
            {error, bad_ref}
    end.

-doc "Publish an event to all universal subscribers for a session.".
-spec publish(binary(), map()) -> ok.
publish(SessionId, Event)
  when is_binary(SessionId), is_map(Event) ->
    ensure_tables(),
    publish_to_refs(SessionId, fun(Owner, Ref) ->
        Owner ! {beam_agent_event, Ref, Event}
    end),
    ok.

-doc "Signal end-of-stream to all universal subscribers for a session.".
-spec complete(binary()) -> ok.
complete(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    publish_to_refs(SessionId, fun(Owner, Ref) ->
        Owner ! {beam_agent_event_complete, Ref}
    end),
    ok.

-doc "Receive the next universal event for a subscription.".
-spec receive_event(reference(), timeout()) ->
    {ok, map()} | {error, complete | timeout | bad_ref}.
receive_event(Ref, Timeout) when is_reference(Ref), is_integer(Timeout), Timeout >= 0 ->
    ensure_tables(),
    case ets:lookup(?SUBSCRIPTIONS_TABLE, Ref) of
        [] ->
            {error, bad_ref};
        _ ->
            receive
                {beam_agent_event, Ref, Event} ->
                    {ok, Event};
                {beam_agent_event_complete, Ref} ->
                    {error, complete}
            after Timeout ->
                {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-doc """
Remove a dead subscriber's ETS records.

Exported for use as an MFA callback by `beam_agent_table_owner:monitor_for_cleanup/2`.
In hardened mode, the table owner calls this when a monitored subscriber
process exits. Both deletes are idempotent — calling this for an already-
cleaned-up subscription is a no-op.
""".
-spec cleanup_dead_subscriber(binary(), reference()) -> ok.
cleanup_dead_subscriber(SessionId, Ref)
  when is_binary(SessionId), is_reference(Ref) ->
    beam_agent_ets:delete(?SUBSCRIPTIONS_TABLE, Ref),
    beam_agent_ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref}),
    ok.

-spec publish_to_refs(binary(), fun((pid(), reference()) -> term())) -> ok.
publish_to_refs(SessionId, SendFun) ->
    lists:foreach(fun({SessionId0, Ref}) when SessionId0 =:= SessionId ->
        case ets:lookup(?SUBSCRIPTIONS_TABLE, Ref) of
            [{Ref, #{owner := Owner}}] ->
                %% Send directly. If Owner is dead, the message is
                %% silently discarded by the BEAM — no crash, no error.
                %% Stale ETS entries are cleaned up by the table owner
                %% monitor (hardened mode) or by the consumer calling
                %% unsubscribe/2 (public mode).
                SendFun(Owner, Ref);
            [] ->
                beam_agent_ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref})
        end
    end, ets:lookup(?SESSIONS_TABLE, SessionId)),
    ok.

-spec flush_subscription_mailbox(reference()) -> ok.
flush_subscription_mailbox(Ref) ->
    receive
        {beam_agent_event, Ref, _} ->
            flush_subscription_mailbox(Ref);
        {beam_agent_event_complete, Ref} ->
            flush_subscription_mailbox(Ref)
    after 0 ->
        ok
    end.

