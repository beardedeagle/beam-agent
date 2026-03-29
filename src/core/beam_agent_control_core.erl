-module(beam_agent_control_core).
-moduledoc """
Universal session control protocol for the BEAM Agent SDK.

Provides session-scoped configuration state, task tracking,
feedback management, and turn response handling. Implements a
virtual control protocol for adapters without native control
message support.

Task registration is bridged into beam_agent_runs_core so live control
entries have a durable run history even after the task table entry is
removed.

Uses ETS for per-session state. All state is keyed by session_id
and persists for the node lifetime or until explicitly cleared.

Usage:
```erlang
%% Set session config:
beam_agent_control_core:set_permission_mode(SessionId, <<"acceptEdits">>),
beam_agent_control_core:set_max_thinking_tokens(SessionId, 8192),

%% Dispatch a control method:
{ok, _} = beam_agent_control_core:dispatch(SessionId, <<"setModel">>,
    #{<<"model">> => <<"claude-sonnet-4-6">>}),

%% Track tasks:
beam_agent_control_core:register_task(SessionId, TaskId, Pid),
beam_agent_control_core:stop_task(SessionId, TaskId),

%% Submit feedback:
beam_agent_control_core:submit_feedback(SessionId, #{rating => good}),

%% Turn response:
beam_agent_control_core:store_pending_request(SessionId, ReqId, Request),
beam_agent_control_core:resolve_pending_request(SessionId, ReqId, Response)
```
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Control dispatch
    dispatch/3,
    %% Session config
    get_config/2,
    set_config/3,
    get_all_config/1,
    clear_config/1,
    %% Permission mode
    set_permission_mode/2,
    get_permission_mode/1,
    %% Thinking tokens
    set_max_thinking_tokens/2,
    get_max_thinking_tokens/1,
    %% Task tracking
    register_task/3,
    unregister_task/2,
    stop_task/2,
    list_tasks/1,
    %% Feedback
    submit_feedback/2,
    get_feedback/1,
    clear_feedback/1,
    register_session_callbacks/2,
    clear_session_callbacks/1,
    request_permission/4,
    request_approval/4,
    request_user_input/3,
    %% Turn response
    store_pending_request/3,
    resolve_pending_request/3,
    get_pending_response/2,
    list_pending_requests/1
]).

-export_type([task_meta/0, pending_request/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type task_meta() :: #{
    task_id := binary(),
    session_id := binary(),
    pid := pid(),
    started_at := integer(),
    status := running | stopped,
    run_id => binary(),
    stopped_at => integer()
}.

-type pending_request() :: #{
    request_id := binary(),
    session_id := binary(),
    request := map(),
    status := pending | resolved,
    response => map(),
    created_at := integer(),
    resolved_at => integer()
}.
-type task_run_attempt() :: 0 | 1 | 2 | 3 | 4 | 5.
-type control_scope_map() :: #{
    session_id := binary(),
    profile_id => binary()
}.
-type task_event_map() :: #{
    session_id := binary(),
    tags := [control | task, ...],
    payload := #{task := map(), replaced => boolean()},
    run_id => binary()
}.
-type control_put_map() :: control_scope_map() | task_event_map().
-type control_journal_reason() :: awaiting_external_response | handler_failed.
-type feedback_entry() :: #{
    seq := integer(),
    session_id := binary(),
    submitted_at := integer(),
    _ => term()
}.
-type control_journal_payload() :: #{
    feedback => feedback_entry(),
    max_thinking_tokens => pos_integer(),
    model => term(),
    permission_mode => atom() | binary(),
    reason => control_journal_reason(),
    request => map(),
    request_id => binary(),
    response => map(),
    source => universal,
    status => pending,
    task_id => binary()
}.
-type journal_error() ::
    already_exists
  | session_id_required_for_thread
  | {invalid_event, event_id | payload | run_id | session_id | tags | thread_id | timestamp}
  | {invalid_event_type, binary()}.

-dialyzer({no_underspecs, [{pending_user_input_result, 4},
                           {normalize_pending_request, 2}]}).
-dialyzer({nowarn_function, [{journal_control_event, 3}]}).

%% ETS tables.
-define(TABLE, beam_agent_runtime).
-define(FEEDBACK_TABLE, beam_agent_control_feedback).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure all control ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_runtime:app_ensure_tables(),
    beam_agent_ets:ensure_table(?FEEDBACK_TABLE, [ordered_set, named_table]),
    ok.

-doc "Clear all control state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?TABLE, {{control_config, '_'}, '_'}),
    beam_agent_ets:match_delete(?TABLE, {{control_task, '_'}, '_'}),
    beam_agent_ets:delete_all_objects(?FEEDBACK_TABLE),
    beam_agent_ets:match_delete(?TABLE, {{control_callback, '_'}, '_'}),
    beam_agent_ets:match_delete(?TABLE, {{control_pending, '_'}, '_'}),
    ok.

%%--------------------------------------------------------------------
%% Control Dispatch
%%--------------------------------------------------------------------

-doc """
Dispatch a control method to the appropriate handler.
Known methods are handled internally; unknown methods return error.
""".
-spec dispatch(binary(), binary(), map()) ->
    {ok, term()} | {error, term()}.
dispatch(SessionId, Method, Params)
  when is_binary(SessionId), is_binary(Method), is_map(Params) ->
    case Method of
        <<"setModel">> ->
            Model = maps:get(<<"model">>, Params,
                maps:get(model, Params, undefined)),
            case Model of
                undefined -> {error, {missing_param, model}};
                M ->
                    set_config(SessionId, model, M),
                    publish_control_event(SessionId, <<"model_updated">>, #{model => M}),
                    {ok, #{model => M}}
            end;
        <<"setPermissionMode">> ->
            Mode = maps:get(<<"permissionMode">>, Params,
                maps:get(permission_mode, Params, undefined)),
            case Mode of
                undefined -> {error, {missing_param, permission_mode}};
                M ->
                    set_permission_mode(SessionId, M),
                    publish_control_event(SessionId, <<"permission_mode_updated">>, #{
                        permission_mode => M
                    }),
                    {ok, #{permission_mode => M}}
            end;
        <<"setMaxThinkingTokens">> ->
            Tokens = maps:get(<<"maxThinkingTokens">>, Params,
                maps:get(max_thinking_tokens, Params, undefined)),
            case Tokens of
                undefined -> {error, {missing_param, max_thinking_tokens}};
                T when is_integer(T), T > 0 ->
                    set_max_thinking_tokens(SessionId, T),
                    publish_control_event(SessionId, <<"max_thinking_tokens_updated">>, #{
                        max_thinking_tokens => T
                    }),
                    {ok, #{max_thinking_tokens => T}};
                _ -> {error, {invalid_param, max_thinking_tokens}}
            end;
        <<"stopTask">> ->
            TaskId = maps:get(<<"taskId">>, Params,
                maps:get(task_id, Params, undefined)),
            case TaskId of
                undefined -> {error, {missing_param, task_id}};
                TId ->
                    Result = stop_task(SessionId, TId),
                    case Result of
                        ok ->
                            publish_control_event(SessionId, <<"task_stop_requested">>, #{
                                task_id => TId
                            });
                        _ ->
                            ok
                    end,
                    Result
            end;
        _ ->
            {error, {unknown_method, Method}}
    end.

%%--------------------------------------------------------------------
%% Session Config
%%--------------------------------------------------------------------

-doc "Get a config value for a session.".
-spec get_config(binary(), atom()) -> {ok, binary() | atom() | map() | pos_integer()} | {error, not_set}.
get_config(SessionId, Key)
  when is_binary(SessionId), is_atom(Key) ->
    ensure_tables(),
    case ets:lookup(?TABLE, {control_config, {SessionId, Key}}) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, not_set}
    end.

-doc "Set a config value for a session.".
-spec set_config(binary(), atom(), binary() | atom() | map() | pos_integer()) -> ok.
set_config(SessionId, Key, Value)
  when is_binary(SessionId), is_atom(Key) ->
    ensure_tables(),
    beam_agent_ets:insert(?TABLE, {{control_config, {SessionId, Key}}, Value}),
    ok.

-doc "Get all config for a session as a map.".
-spec get_all_config(binary()) -> {ok, map()}.
get_all_config(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Config = ets:foldl(fun
        ({{control_config, {SId, Key}}, Value}, Acc) when SId =:= SessionId ->
            Acc#{Key => Value};
        (_, Acc) ->
            Acc
    end, #{}, ?TABLE),
    {ok, Config}.

-doc "Clear all config for a session.".
-spec clear_config(binary()) -> ok.
clear_config(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    %% Delete all keys for this session
    beam_agent_ets:match_delete(?TABLE, {{control_config, {SessionId, '_'}}, '_'}),
    ok.

%%--------------------------------------------------------------------
%% Permission Mode
%%--------------------------------------------------------------------

-doc "Set the permission mode for a session.".
-spec set_permission_mode(binary(), binary() | atom()) -> ok.
set_permission_mode(SessionId, Mode) when is_binary(SessionId) ->
    set_config(SessionId, permission_mode, Mode).

-doc "Get the permission mode for a session.".
-spec get_permission_mode(binary()) ->
    {ok, binary() | atom()} | {error, not_set}.
get_permission_mode(SessionId) when is_binary(SessionId) ->
    get_config(SessionId, permission_mode).

%%--------------------------------------------------------------------
%% Thinking Tokens
%%--------------------------------------------------------------------

-doc "Set max thinking tokens for a session.".
-spec set_max_thinking_tokens(binary(), pos_integer()) -> ok.
set_max_thinking_tokens(SessionId, Tokens)
  when is_binary(SessionId), is_integer(Tokens), Tokens > 0 ->
    set_config(SessionId, max_thinking_tokens, Tokens).

-doc "Get max thinking tokens for a session.".
-spec get_max_thinking_tokens(binary()) ->
    {ok, pos_integer()} | {error, not_set}.
get_max_thinking_tokens(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    case ets:lookup(?TABLE, {control_config, {SessionId, max_thinking_tokens}}) of
        [{_, Tokens}] when is_integer(Tokens), Tokens > 0 -> {ok, Tokens};
        _ -> {error, not_set}
    end.

%%--------------------------------------------------------------------
%% Task Tracking
%%--------------------------------------------------------------------

-doc "Register an active task for a session.".
-spec register_task(binary(), binary(), pid()) -> ok.
register_task(SessionId, TaskId, Pid)
  when is_binary(SessionId), is_binary(TaskId), is_pid(Pid) ->
    ensure_tables(),
    Key = {control_task, {SessionId, TaskId}},
    Replaced = case ets:lookup(?TABLE, Key) of
        [{_, ExistingTask}] ->
            ok = reconcile_replaced_task(ExistingTask),
            true;
        [] ->
            false
    end,
    Now = erlang:system_time(millisecond),
    RunId = create_task_run(SessionId, TaskId),
    Task = #{
        task_id => TaskId,
        session_id => SessionId,
        pid => Pid,
        started_at => Now,
        status => running,
        run_id => RunId
    },
    beam_agent_ets:insert(?TABLE, {Key, Task}),
    {ok, _Entry} = journal_task_event(<<"task_registered">>, SessionId, Task, #{
        replaced => Replaced
    }),
    ok.

-doc "Unregister a task (mark as complete).".
-spec unregister_task(binary(), binary()) -> ok.
unregister_task(SessionId, TaskId)
  when is_binary(SessionId), is_binary(TaskId) ->
    ensure_tables(),
    Key = {control_task, {SessionId, TaskId}},
    case ets:lookup(?TABLE, Key) of
        [{_, Task}] ->
            ok = reconcile_unregistered_task(Task),
            beam_agent_ets:delete(?TABLE, Key),
            {ok, _Entry} = journal_task_event(<<"task_unregistered">>, SessionId, Task, #{}),
            ok;
        [] ->
            ok
    end.

-doc """
Stop a running task by sending an interrupt to its process.
Returns `ok` if the task was found and signaled, error otherwise.
""".
-spec stop_task(binary(), binary()) -> ok | {error, not_found}.
stop_task(SessionId, TaskId)
  when is_binary(SessionId), is_binary(TaskId) ->
    ensure_tables(),
    Key = {control_task, {SessionId, TaskId}},
    case ets:lookup(?TABLE, Key) of
        [{_, #{pid := Pid, status := running} = Task}] ->
            Now = erlang:system_time(millisecond),
            %% Signal the process to stop
            case is_process_alive(Pid) of
                true ->
                    %% Try gen_statem interrupt first, fall back to exit
                    try
                        gen_statem:call(Pid, interrupt, 5000)
                    catch
                        _:_ ->
                            exit(Pid, shutdown)
                    end;
                false ->
                    ok
            end,
            ok = reconcile_stopped_task(Task),
            Updated = Task#{
                status => stopped,
                stopped_at => Now
            },
            beam_agent_ets:insert(?TABLE, {Key, Updated}),
            {ok, _Entry} = journal_task_event(<<"task_stopped">>, SessionId, Updated, #{}),
            ok;
        [{_, #{status := stopped}}] ->
            ok;
        [] ->
            {error, not_found}
    end.

-doc "List all tasks for a session.".
-spec list_tasks(binary()) -> {ok, [task_meta()]}.
list_tasks(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Tasks = ets:foldl(fun
        ({{control_task, {SId, _}}, Task}, Acc) when SId =:= SessionId ->
            [Task | Acc];
        (_, Acc) ->
            Acc
    end, [], ?TABLE),
    {ok, Tasks}.

%%--------------------------------------------------------------------
%% Feedback
%%--------------------------------------------------------------------

-doc "Submit feedback for a session. Feedback is accumulated.".
-spec submit_feedback(binary(), map()) -> ok.
submit_feedback(SessionId, Feedback)
  when is_binary(SessionId), is_map(Feedback) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Seq = beam_agent_ets:update_counter(?FEEDBACK_TABLE, {SessionId, seq},
        {2, 1}, {{SessionId, seq}, 0}),
    Entry = Feedback#{
        submitted_at => Now,
        session_id => SessionId,
        seq => Seq
    },
    beam_agent_ets:insert(?FEEDBACK_TABLE, {{SessionId, Seq}, Entry}),
    beam_agent_events:publish(SessionId, #{
        type => system,
        subtype => <<"feedback_submitted">>,
        session_id => SessionId,
        source => universal,
        event_class => control,
        feedback => Entry,
        timestamp => Now
    }),
    {ok, _Entry} = journal_control_event(<<"feedback_submitted">>, SessionId, #{
        feedback => Entry
    }),
    ok.

-doc "Get all feedback for a session, in submission order.".
-spec get_feedback(binary()) -> {ok, [map()]}.
get_feedback(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Feedback = ets:foldl(fun
        ({{SId, Key}, Entry}, Acc) when SId =:= SessionId, Key =/= seq ->
            [Entry | Acc];
        (_, Acc) ->
            Acc
    end, [], ?FEEDBACK_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(seq, A, 0) =< maps:get(seq, B, 0)
    end, Feedback),
    {ok, Sorted}.

-doc "Clear all feedback for a session.".
-spec clear_feedback(binary()) -> ok.
clear_feedback(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    ets:foldl(fun
        ({{SId, _} = Key, _}, ok) when SId =:= SessionId ->
            beam_agent_ets:delete(?FEEDBACK_TABLE, Key),
            ok;
        (_, ok) ->
            ok
    end, ok, ?FEEDBACK_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Session callback broker
%%--------------------------------------------------------------------

-doc "Register canonical callback handlers for a session.".
-spec register_session_callbacks(binary(), map()) -> ok.
register_session_callbacks(SessionId, Opts)
  when is_binary(SessionId), is_map(Opts) ->
    ensure_tables(),
    CallbackState = maps:filter(fun(_Key, Value) ->
        Value =/= undefined
    end, #{
        permission_handler => maps:get(permission_handler, Opts, undefined),
        permission_default => maps:get(permission_default, Opts, deny),
        approval_handler => maps:get(approval_handler, Opts, undefined),
        user_input_handler => maps:get(user_input_handler, Opts, undefined)
    }),
    case map_size(CallbackState) of
        0 ->
            beam_agent_ets:delete(?TABLE, {control_callback, SessionId});
        _ ->
            beam_agent_ets:insert(?TABLE, {{control_callback, SessionId}, CallbackState})
    end,
    ok.

-doc "Clear callback broker state for a session.".
-spec clear_session_callbacks(binary()) -> ok.
clear_session_callbacks(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    beam_agent_ets:delete(?TABLE, {control_callback, SessionId}),
    ok.

-doc "Request canonical permission handling for a session.".
-spec request_permission(binary(), binary(), map(), map()) ->
    beam_agent_core:permission_result().
request_permission(SessionId, Method, Params, Context)
  when is_binary(SessionId), is_binary(Method), is_map(Params), is_map(Context) ->
    ensure_tables(),
    case evaluate_control_policy(SessionId, approval, Method, Params, Context) of
        allow ->
            Callbacks = lookup_callbacks(SessionId),
            Decision = case Callbacks of
                #{permission_handler := Handler} when is_function(Handler) ->
                    safe_permission_handler(Handler, Method, Params, Context,
                        maps:get(permission_default, Callbacks, deny));
                #{approval_handler := Handler} when is_function(Handler) ->
                    approval_decision_to_permission(
                        safe_approval_handler(Handler, Method, Params, Context),
                        Params,
                        maps:get(permission_default, Callbacks, deny));
                #{permission_default := Default} ->
                    default_permission(Default, Params);
                #{} ->
                    default_permission(deny, Params)
            end,
            ok = audit_permission_decision(SessionId, Method, Decision, Params, Context),
            Decision;
        {deny, Reason} ->
            Decision = {deny, Reason},
            ok = audit_permission_decision(SessionId, Method, Decision, Params, Context),
            Decision
    end.

-doc "Request canonical approval handling for a session.".
-spec request_approval(binary(), binary(), map(), map()) ->
    accept | accept_for_session | decline | cancel.
request_approval(SessionId, Method, Params, Context)
  when is_binary(SessionId), is_binary(Method), is_map(Params), is_map(Context) ->
    ensure_tables(),
    case evaluate_control_policy(SessionId, approval, Method, Params, Context) of
        allow ->
            Callbacks = lookup_callbacks(SessionId),
            Decision = case Callbacks of
                #{approval_handler := Handler} when is_function(Handler) ->
                    safe_approval_handler(Handler, Method, Params, Context);
                #{permission_handler := Handler} when is_function(Handler) ->
                    case safe_permission_handler(Handler, Method, Params, Context,
                             maps:get(permission_default, Callbacks, deny)) of
                        {allow, _} ->
                            accept;
                        {allow, _, _Other} ->
                            accept;
                        {deny, _} ->
                            decline;
                        {deny, _, true} ->
                            cancel;
                        {deny, _, _} ->
                            decline
                    end;
                #{permission_default := allow} ->
                    accept;
                _ ->
                    decline
            end,
            ok = audit_approval_decision(SessionId, Method, Decision, Params, Context),
            Decision;
        {deny, Reason} ->
            ok = audit_approval_decision(SessionId, Method, decline, Params,
                Context#{policy_reason => Reason}),
            decline
    end.

-doc "Request canonical user input through the shared callback broker.".
-spec request_user_input(binary(), map(), map()) ->
    {ok, term()}.
request_user_input(SessionId, Request, Context)
  when is_binary(SessionId), is_map(Request), is_map(Context) ->
    ensure_tables(),
    RequestId = maps:get(request_id, Context, beam_agent_core:make_request_id()),
    StoredRequest = Request#{
        request_id => RequestId,
        source => maps:get(source, Request, universal),
        context => Context
    },
    ok = store_pending_request(SessionId, RequestId, StoredRequest),
    case lookup_callbacks(SessionId) of
        #{user_input_handler := Handler} when is_function(Handler) ->
            case safe_user_input_handler(Handler, Request, Context) of
                {ok, Response} ->
                    _ = resolve_pending_request(SessionId, RequestId, #{
                        response => Response,
                        source => callback
                    }),
                    {ok, Response};
                {error, _} ->
                    pending_user_input_result(SessionId,
                                              RequestId,
                                              StoredRequest,
                                              handler_failed)
            end;
        _ ->
            pending_user_input_result(SessionId,
                                      RequestId,
                                      StoredRequest,
                                      awaiting_external_response)
    end.

%%--------------------------------------------------------------------
%% Turn Response (Pending Request/Response)
%%--------------------------------------------------------------------

-doc """
Store a pending request from the agent.
Called when the agent asks for user input.
""".
-spec store_pending_request(binary(), binary(), map()) -> ok.
store_pending_request(SessionId, RequestId, Request)
  when is_binary(SessionId), is_binary(RequestId), is_map(Request) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    CanonicalRequest = normalize_pending_request(RequestId, Request),
    PublicRequest = beam_agent_redaction:map(CanonicalRequest),
    Entry = #{
        request_id => RequestId,
        session_id => SessionId,
        request => CanonicalRequest,
        status => pending,
        created_at => Now
    },
    beam_agent_ets:insert(?TABLE, {{control_pending, {SessionId, RequestId}}, Entry}),
    beam_agent_events:publish(SessionId, #{
        type => system,
        subtype => <<"pending_request_stored">>,
        session_id => SessionId,
        source => universal,
        event_class => control,
        request_id => RequestId,
        request => PublicRequest,
        timestamp => Now
    }),
    {ok, _Entry} = journal_control_event(<<"pending_request_stored">>, SessionId, #{
        request_id => RequestId,
        request => PublicRequest
    }),
    ok.

-doc "Resolve a pending request with a response.".
-spec resolve_pending_request(binary(), binary(), map()) ->
    ok | {error, not_found | already_resolved}.
resolve_pending_request(SessionId, RequestId, Response)
  when is_binary(SessionId), is_binary(RequestId), is_map(Response) ->
    ensure_tables(),
    Key = {control_pending, {SessionId, RequestId}},
    case ets:lookup(?TABLE, Key) of
        [{_, #{status := pending} = Entry}] ->
            Now = erlang:system_time(millisecond),
            Updated = Entry#{
                status => resolved,
                response => Response,
                resolved_at => Now
            },
            beam_agent_ets:insert(?TABLE, {Key, Updated}),
            beam_agent_events:publish(SessionId, #{
                type => system,
                subtype => <<"pending_request_resolved">>,
                session_id => SessionId,
                source => universal,
                event_class => control,
                request_id => RequestId,
                response => beam_agent_redaction:map(Response),
                timestamp => Now
            }),
            {ok, _Entry} = journal_control_event(<<"pending_request_resolved">>, SessionId, #{
                request_id => RequestId,
                response => beam_agent_redaction:map(Response)
            }),
            ok;
        [{_, #{status := resolved}}] ->
            {error, already_resolved};
        [] ->
            {error, not_found}
    end.

-doc "Get the response for a pending request.".
-spec get_pending_response(binary(), binary()) ->
    {ok, map()} | {error, pending | not_found}.
get_pending_response(SessionId, RequestId)
  when is_binary(SessionId), is_binary(RequestId) ->
    ensure_tables(),
    Key = {control_pending, {SessionId, RequestId}},
    case ets:lookup(?TABLE, Key) of
        [{_, #{status := resolved, response := Response}}] ->
            {ok, Response};
        [{_, #{status := pending}}] ->
            {error, pending};
        [] ->
            {error, not_found}
    end.

-doc "List all pending requests for a session.".
-spec list_pending_requests(binary()) -> {ok, [pending_request()]}.
list_pending_requests(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Requests = ets:foldl(fun
        ({{control_pending, {SId, _}}, Entry}, Acc) when SId =:= SessionId ->
            [beam_agent_redaction:pending_entry(Entry) | Acc];
        (_, Acc) ->
            Acc
    end, [], ?TABLE),
    {ok, lists:sort(fun(A, B) ->
        maps:get(created_at, A, 0) =< maps:get(created_at, B, 0)
    end, Requests)}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec lookup_callbacks(binary()) -> map().
lookup_callbacks(SessionId) ->
    case ets:lookup(?TABLE, {control_callback, SessionId}) of
        [{_, Callbacks}] when is_map(Callbacks) ->
            Callbacks;
        [] ->
            #{}
    end.

-spec safe_permission_handler(fun(), binary(), map(), map(), allow | deny) ->
    beam_agent_core:permission_result().
safe_permission_handler(Handler, Method, Params, Context, Default) ->
    try Handler(Method, Params, Context) of
        {allow, _} = Allow ->
            Allow;
        {allow, _, _} = Allow ->
            Allow;
        {deny, _} = Deny ->
            Deny;
        {deny, _, _} = Deny ->
            Deny;
        _ ->
            default_permission(Default, Params)
    catch
        _:_ ->
            default_permission(Default, Params)
    end.

-spec safe_approval_handler(fun(), binary(), map(), map()) ->
    accept | accept_for_session | decline | cancel.
safe_approval_handler(Handler, Method, Params, Context) ->
    try Handler(Method, Params, Context) of
        accept ->
            accept;
        accept_for_session ->
            accept_for_session;
        decline ->
            decline;
        cancel ->
            cancel;
        allow ->
            accept;
        deny ->
            decline;
        _ ->
            decline
    catch
        _:_ ->
            decline
    end.

-spec safe_user_input_handler(fun(), map(), map()) ->
    {ok, term()} | {error, user_input_handler_failed}.
safe_user_input_handler(Handler, Request, Context) ->
    try Handler(Request, Context) of
        {ok, _} = Ok ->
            Ok;
        Response ->
            {ok, Response}
    catch
        _:_ ->
            {error, user_input_handler_failed}
    end.

-spec pending_user_input_result(binary(), binary(), map(), atom()) -> {ok, map()}.
pending_user_input_result(SessionId, RequestId, Request, Reason) ->
    Now = erlang:system_time(millisecond),
    Pending = #{
        request_id => RequestId,
        status => pending,
        request => beam_agent_redaction:map(Request),
        source => universal,
        reason => Reason
    },
    beam_agent_events:publish(SessionId, Pending#{
        type => system,
        subtype => <<"user_input_requested">>,
        session_id => SessionId,
        event_class => control,
        timestamp => Now
    }),
    {ok, _Entry} = journal_control_event(<<"user_input_requested">>, SessionId, Pending),
    {ok, Pending}.

-spec normalize_pending_request(binary(), map()) -> map().
normalize_pending_request(RequestId, Request) ->
    Kind = maps:get(kind, Request,
        maps:get(type, Request,
            maps:get(subtype, Request, user_input))),
    maps:merge(#{
        request_id => RequestId,
        kind => Kind,
        source => maps:get(source, Request, universal),
        schema_version => <<"beam_agent.control.request.v1">>
    }, Request).


-spec approval_decision_to_permission(accept | accept_for_session | decline | cancel,
                                      map(), allow | deny) ->
    beam_agent_core:permission_result().
approval_decision_to_permission(accept, Params, _Default) ->
    {allow, Params};
approval_decision_to_permission(accept_for_session, Params, _Default) ->
    {allow, Params, allow};
approval_decision_to_permission(cancel, _Params, _Default) ->
    {deny, <<"cancelled">>, true};
approval_decision_to_permission(decline, _Params, _Default) ->
    {deny, <<"declined">>}.

-spec default_permission(allow | deny, map()) -> beam_agent_core:permission_result().
default_permission(allow, Params) ->
    {allow, Params};
default_permission(_, _Params) ->
    {deny, <<"denied">>}.

-spec evaluate_control_policy(binary(), approval, binary(), map(), map()) ->
    allow | {deny, binary()}.
evaluate_control_policy(SessionId, Action, Method, Params, Context) ->
    ProfileId = session_policy_profile(SessionId),
    beam_agent_policy_core:evaluate(ProfileId, Action, #{
        session_id => SessionId,
        method => Method,
        params => Params,
        context => Context
    }).

-spec session_policy_profile(binary()) -> binary() | undefined.
session_policy_profile(SessionId) ->
    case get_config(SessionId, policy_profile_id) of
        {ok, ProfileId} when is_binary(ProfileId) ->
            ProfileId;
        _ ->
            undefined
    end.

-spec audit_permission_decision(binary(), binary(),
    beam_agent_core:permission_result(), map(), map()) -> ok.
audit_permission_decision(SessionId, Method, Decision, Params, Context) ->
    Scope = control_audit_scope(SessionId),
    Details = #{
        decision => permission_decision_name(Decision),
        method => Method,
        params => beam_agent_redaction:map(Params),
        context => beam_agent_redaction:map(Context),
        profile_id => session_policy_profile(SessionId)
    },
    case beam_agent_audit_core:record(control, permission, Scope, Details) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

-spec audit_approval_decision(binary(), binary(),
    accept | accept_for_session | decline | cancel, map(), map()) -> ok.
audit_approval_decision(SessionId, Method, Decision, Params, Context) ->
    Scope = control_audit_scope(SessionId),
    Details = #{
        decision => Decision,
        method => Method,
        params => beam_agent_redaction:map(Params),
        context => beam_agent_redaction:map(Context),
        profile_id => session_policy_profile(SessionId)
    },
    case beam_agent_audit_core:record(control, approval, Scope, Details) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

-spec control_audit_scope(binary()) -> control_scope_map().
control_audit_scope(SessionId) ->
    maybe_put(profile_id, session_policy_profile(SessionId), #{
        session_id => SessionId
    }).

-spec permission_decision_name(
    {allow, map()} |
    {deny, binary()} |
    {deny, binary(), boolean()} |
    {allow, map(), map() | [map()]}
) -> allow | deny | cancel.
permission_decision_name({allow, _}) ->
    allow;
permission_decision_name({allow, _, _}) ->
    allow;
permission_decision_name({deny, _, true}) ->
    cancel;
permission_decision_name({deny, _, _}) ->
    deny;
permission_decision_name({deny, _}) ->
    deny.

publish_control_event(SessionId, Subtype, Payload) ->
    Event = Payload#{
        type => system,
        subtype => Subtype,
        session_id => SessionId,
        source => universal,
        event_class => control,
        timestamp => erlang:system_time(millisecond)
    },
    beam_agent_events:publish(SessionId, Event),
    {ok, _Entry} = journal_control_event(Subtype, SessionId, Payload),
    _ = beam_agent_audit_core:record(control, event, #{session_id => SessionId}, #{
        subtype => Subtype,
        payload => beam_agent_redaction:map(Payload)
    }),
    ok.

-spec create_task_run(binary(), binary()) -> binary().
create_task_run(SessionId, TaskId) ->
    create_task_run(SessionId, TaskId, 0).

-spec create_task_run(binary(), binary(), task_run_attempt()) -> binary().
create_task_run(SessionId, TaskId, Attempts) when Attempts < 5 ->
    case beam_agent_runs_core:start_run(SessionId, #{
        kind => task,
        metadata => #{
            task_id => TaskId,
            source => control_task
        }
    }) of
        {ok, #{run_id := RunId}} ->
            RunId;
        {error, already_exists} ->
            create_task_run(SessionId, TaskId, Attempts + 1)
    end;
create_task_run(SessionId, TaskId, Attempts) ->
    FallbackRunId = task_run_id(TaskId, Attempts),
    {ok, #{run_id := RunId}} = beam_agent_runs_core:start_run(SessionId, #{
        run_id => FallbackRunId,
        kind => task,
        metadata => #{
            task_id => TaskId,
            source => control_task
        }
    }),
    RunId.

-spec reconcile_replaced_task(task_meta()) -> ok.
reconcile_replaced_task(Task) ->
    cancel_task_run(Task, #{
        reason => task_re_registered,
        source => control_task,
        task_id => maps:get(task_id, Task)
    }).

-spec reconcile_unregistered_task(task_meta()) -> ok.
reconcile_unregistered_task(#{status := running} = Task) ->
    complete_task_run(Task, #{
        source => control_task,
        task_id => maps:get(task_id, Task),
        terminal_status => completed
    });
reconcile_unregistered_task(#{status := stopped} = Task) ->
    cancel_task_run(Task, #{
        reason => task_unregistered_after_stop,
        source => control_task,
        task_id => maps:get(task_id, Task)
    }).

-spec reconcile_stopped_task(#{
    task_id := binary(),
    session_id := binary(),
    pid := pid(),
    started_at := integer(),
    status := running,
    run_id => binary(),
    stopped_at => integer()
}) -> ok.
reconcile_stopped_task(Task) ->
    cancel_task_run(Task, #{
        reason => task_stopped,
        source => control_task,
        task_id => maps:get(task_id, Task)
    }).

-spec complete_task_run(task_meta(), map()) -> ok.
complete_task_run(Task, Result) ->
    case maps:find(run_id, Task) of
        {ok, RunId} ->
            case beam_agent_runs_core:complete_run(RunId, Result) of
                {ok, _Run} ->
                    ok;
                {error, active_steps} ->
                    cancel_task_run(Task, #{
                        reason => task_unregistered_with_active_steps,
                        source => control_task,
                        task_id => maps:get(task_id, Task)
                    });
                {error, {invalid_status_transition, _, _}} ->
                    ok;
                {error, not_found} ->
                    ok
            end;
        error ->
            ok
    end.

-spec cancel_task_run(task_meta(), map()) -> ok.
cancel_task_run(Task, Reason) ->
    case maps:find(run_id, Task) of
        {ok, RunId} ->
            case beam_agent_runs_core:cancel_run(RunId, Reason) of
                {ok, _Run} ->
                    ok;
                {error, {invalid_status_transition, _, _}} ->
                    ok;
                {error, not_found} ->
                    ok
            end;
        error ->
            ok
    end.

-spec task_run_id(binary(), task_run_attempt()) -> <<_:64, _:_*8>>.
task_run_id(TaskId, Attempt) ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(6), lowercase),
    <<SafeTaskId/binary>> = sanitize_task_id(TaskId),
    <<"run_task_", SafeTaskId/binary, "_", (integer_to_binary(Attempt))/binary,
      "_", Hex/binary>>.

-spec sanitize_task_id(binary()) -> binary().
sanitize_task_id(TaskId) ->
    binary:replace(TaskId, <<"/">>, <<"_">>, [global]).

-spec journal_control_event(<<_:64, _:_*8>>, binary(), control_journal_payload()) ->
    {ok, beam_agent_journal_core:entry()} | {error, journal_error()}.
journal_control_event(EventType, SessionId, Payload) ->
    beam_agent_journal_core:append(EventType, #{
        session_id => SessionId,
        tags => [control],
        payload => Payload
    }).

-spec journal_task_event(<<_:64, _:_*8>>, binary(), task_meta(),
    #{} | #{replaced => boolean()}) ->
    {ok, beam_agent_journal_core:entry()} | {error, journal_error()}.
journal_task_event(EventType, SessionId, Task, ExtraPayload) ->
    Event0 = #{
        session_id => SessionId,
        tags => [control, task],
        payload => maps:merge(#{task => task_journal_view(Task)}, ExtraPayload)
    },
    Event1 = maybe_put(run_id, maps:get(run_id, Task, undefined), Event0),
    beam_agent_journal_core:append(EventType, Event1).

-spec task_journal_view(task_meta()) -> map().
task_journal_view(Task) ->
    maps:without([pid], Task).

-spec maybe_put(profile_id | run_id, undefined | binary(), control_put_map()) -> control_put_map().
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.
