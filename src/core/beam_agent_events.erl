-module(beam_agent_events).
-moduledoc false.

-export([
    ensure_tables/0,
    clear/0,
    subscribe/1,
    unsubscribe/2,
    publish/2,
    complete/1,
    receive_event/2
]).

-dialyzer({no_underspecs, [ensure_ets/2]}).

-define(SUBSCRIPTIONS_TABLE, beam_agent_event_subscriptions).
-define(SESSIONS_TABLE, beam_agent_event_session_refs).

-doc "Ensure ETS tables exist for the universal event stream.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    ensure_ets(?SUBSCRIPTIONS_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_ets(?SESSIONS_TABLE, [bag, public, named_table,
        {read_concurrency, true}]),
    ok.

-doc "Clear every universal event subscription.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    ets:delete_all_objects(?SUBSCRIPTIONS_TABLE),
    ets:delete_all_objects(?SESSIONS_TABLE),
    ok.

-doc "Subscribe the calling process to future events for a session.".
-spec subscribe(binary()) -> {ok, reference()}.
subscribe(SessionId) when is_binary(SessionId), byte_size(SessionId) > 0 ->
    ensure_tables(),
    Ref = make_ref(),
    Owner = self(),
    Metadata = #{session_id => SessionId, owner => Owner},
    ets:insert(?SUBSCRIPTIONS_TABLE, {Ref, Metadata}),
    ets:insert(?SESSIONS_TABLE, {SessionId, Ref}),
    {ok, Ref}.

-doc "Remove a universal event subscription.".
-spec unsubscribe(binary(), reference()) -> ok | {error, bad_ref}.
unsubscribe(SessionId, Ref)
  when is_binary(SessionId), is_reference(Ref) ->
    ensure_tables(),
    case ets:lookup(?SUBSCRIPTIONS_TABLE, Ref) of
        [{Ref, #{session_id := SessionId}}] ->
            ets:delete(?SUBSCRIPTIONS_TABLE, Ref),
            ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref}),
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

-spec publish_to_refs(binary(), fun((pid(), reference()) -> term())) -> ok.
publish_to_refs(SessionId, SendFun) ->
    lists:foreach(fun({SessionId0, Ref}) when SessionId0 =:= SessionId ->
        case ets:lookup(?SUBSCRIPTIONS_TABLE, Ref) of
            [{Ref, #{owner := Owner}}] ->
                case is_process_alive(Owner) of
                    true ->
                        SendFun(Owner, Ref);
                    false ->
                        ets:delete(?SUBSCRIPTIONS_TABLE, Ref),
                        ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref})
                end;
            [] ->
                ets:delete_object(?SESSIONS_TABLE, {SessionId, Ref})
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

-spec ensure_ets(atom(), [term()]) -> ok.
ensure_ets(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.
