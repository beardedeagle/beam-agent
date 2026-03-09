%%%-------------------------------------------------------------------
%%% @doc EUnit tests for beam_agent_control_core (session control protocol).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Control dispatch (setModel, setPermissionMode, setMaxThinkingTokens,
%%%     stopTask, unknown method, missing params, invalid params)
%%%   - Session config CRUD (get_config, set_config, get_all_config, clear_config)
%%%   - Permission mode convenience (set_permission_mode, get_permission_mode)
%%%   - Thinking tokens convenience (set_max_thinking_tokens, get_max_thinking_tokens)
%%%   - Task tracking lifecycle (register_task, unregister_task, stop_task, list_tasks)
%%%   - Feedback accumulation (submit_feedback, get_feedback, clear_feedback)
%%%   - Pending request lifecycle (store_pending_request, resolve_pending_request,
%%%     get_pending_response, list_pending_requests)
%%% @end
%%%-------------------------------------------------------------------
-module(beam_agent_control_core_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = beam_agent_control_core:ensure_tables(),
    ok = beam_agent_control_core:ensure_tables(),
    ok = beam_agent_control_core:ensure_tables(),
    beam_agent_control_core:clear().

clear_empties_all_tables_test() ->
    SId = <<"clear-session">>,
    beam_agent_control_core:ensure_tables(),
    beam_agent_control_core:set_config(SId, model, <<"claude">>),
    beam_agent_control_core:submit_feedback(SId, #{rating => good}),
    beam_agent_control_core:store_pending_request(SId, <<"r1">>, #{q => <<"hi">>}),
    ok = beam_agent_control_core:clear(),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_config(SId, model)),
    {ok, Feedback} = beam_agent_control_core:get_feedback(SId),
    ?assertEqual([], Feedback),
    {ok, Pending} = beam_agent_control_core:list_pending_requests(SId),
    ?assertEqual([], Pending).

%%====================================================================
%% Dispatch: setModel
%%====================================================================

dispatch_set_model_test() ->
    SId = <<"disp-model-session">>,
    {ok, Result} = beam_agent_control_core:dispatch(SId, <<"setModel">>,
        #{<<"model">> => <<"claude-opus-4-6">>}),
    ?assertEqual(<<"claude-opus-4-6">>, maps:get(model, Result)),
    {ok, Stored} = beam_agent_control_core:get_config(SId, model),
    ?assertEqual(<<"claude-opus-4-6">>, Stored),
    beam_agent_control_core:clear().

dispatch_set_model_missing_param_test() ->
    SId = <<"disp-model-miss-session">>,
    ?assertMatch({error, {missing_param, model}},
        beam_agent_control_core:dispatch(SId, <<"setModel">>, #{})),
    beam_agent_control_core:clear().

%%====================================================================
%% Dispatch: setPermissionMode
%%====================================================================

dispatch_set_permission_mode_test() ->
    SId = <<"disp-perm-session">>,
    {ok, Result} = beam_agent_control_core:dispatch(SId, <<"setPermissionMode">>,
        #{<<"permissionMode">> => <<"acceptEdits">>}),
    ?assertEqual(<<"acceptEdits">>, maps:get(permission_mode, Result)),
    {ok, Stored} = beam_agent_control_core:get_permission_mode(SId),
    ?assertEqual(<<"acceptEdits">>, Stored),
    beam_agent_control_core:clear().

dispatch_set_permission_mode_missing_param_test() ->
    SId = <<"disp-perm-miss-session">>,
    ?assertMatch({error, {missing_param, permission_mode}},
        beam_agent_control_core:dispatch(SId, <<"setPermissionMode">>, #{})),
    beam_agent_control_core:clear().

%%====================================================================
%% Dispatch: setMaxThinkingTokens
%%====================================================================

dispatch_set_max_thinking_tokens_test() ->
    SId = <<"disp-tokens-session">>,
    {ok, Result} = beam_agent_control_core:dispatch(SId, <<"setMaxThinkingTokens">>,
        #{<<"maxThinkingTokens">> => 8192}),
    ?assertEqual(8192, maps:get(max_thinking_tokens, Result)),
    {ok, Stored} = beam_agent_control_core:get_max_thinking_tokens(SId),
    ?assertEqual(8192, Stored),
    beam_agent_control_core:clear().

dispatch_set_max_thinking_tokens_missing_param_test() ->
    SId = <<"disp-tokens-miss-session">>,
    ?assertMatch({error, {missing_param, max_thinking_tokens}},
        beam_agent_control_core:dispatch(SId, <<"setMaxThinkingTokens">>, #{})),
    beam_agent_control_core:clear().

dispatch_set_max_thinking_tokens_invalid_zero_test() ->
    SId = <<"disp-tokens-zero-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        beam_agent_control_core:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => 0})),
    beam_agent_control_core:clear().

dispatch_set_max_thinking_tokens_invalid_negative_test() ->
    SId = <<"disp-tokens-neg-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        beam_agent_control_core:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => -100})),
    beam_agent_control_core:clear().

dispatch_set_max_thinking_tokens_invalid_string_test() ->
    SId = <<"disp-tokens-str-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        beam_agent_control_core:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => <<"8192">>})),
    beam_agent_control_core:clear().

%%====================================================================
%% Dispatch: stopTask
%%====================================================================

dispatch_stop_task_test() ->
    SId = <<"disp-stop-session">>,
    TaskId = <<"task-001">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    beam_agent_control_core:register_task(SId, TaskId, Pid),
    ok = beam_agent_control_core:dispatch(SId, <<"stopTask">>,
        #{<<"taskId">> => TaskId}),
    beam_agent_control_core:clear().

dispatch_stop_task_missing_param_test() ->
    SId = <<"disp-stop-miss-session">>,
    ?assertMatch({error, {missing_param, task_id}},
        beam_agent_control_core:dispatch(SId, <<"stopTask">>, #{})),
    beam_agent_control_core:clear().

%%====================================================================
%% Dispatch: unknown method
%%====================================================================

dispatch_unknown_method_test() ->
    SId = <<"disp-unknown-session">>,
    ?assertMatch({error, {unknown_method, <<"doSomethingUnknown">>}},
        beam_agent_control_core:dispatch(SId, <<"doSomethingUnknown">>, #{})),
    beam_agent_control_core:clear().

%%====================================================================
%% Session config CRUD
%%====================================================================

get_config_not_set_test() ->
    SId = <<"cfg-notset-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_config(SId, model)),
    beam_agent_control_core:clear().

set_and_get_config_test() ->
    SId = <<"cfg-set-session">>,
    ok = beam_agent_control_core:set_config(SId, model, <<"claude-haiku">>),
    ?assertEqual({ok, <<"claude-haiku">>}, beam_agent_control_core:get_config(SId, model)),
    beam_agent_control_core:clear().

set_config_overwrite_test() ->
    SId = <<"cfg-overwrite-session">>,
    ok = beam_agent_control_core:set_config(SId, model, <<"model-v1">>),
    ok = beam_agent_control_core:set_config(SId, model, <<"model-v2">>),
    ?assertEqual({ok, <<"model-v2">>}, beam_agent_control_core:get_config(SId, model)),
    beam_agent_control_core:clear().

get_all_config_empty_test() ->
    SId = <<"cfg-all-empty-session">>,
    beam_agent_control_core:ensure_tables(),
    {ok, Config} = beam_agent_control_core:get_all_config(SId),
    ?assertEqual(#{}, Config),
    beam_agent_control_core:clear().

get_all_config_multiple_keys_test() ->
    SId = <<"cfg-all-multi-session">>,
    beam_agent_control_core:set_config(SId, model, <<"claude-sonnet">>),
    beam_agent_control_core:set_config(SId, permission_mode, <<"acceptEdits">>),
    {ok, Config} = beam_agent_control_core:get_all_config(SId),
    ?assertEqual(<<"claude-sonnet">>, maps:get(model, Config)),
    ?assertEqual(<<"acceptEdits">>, maps:get(permission_mode, Config)),
    beam_agent_control_core:clear().

get_all_config_isolates_sessions_test() ->
    SId1 = <<"cfg-iso-session-1">>,
    SId2 = <<"cfg-iso-session-2">>,
    beam_agent_control_core:set_config(SId1, model, <<"model-1">>),
    beam_agent_control_core:set_config(SId2, model, <<"model-2">>),
    {ok, Config1} = beam_agent_control_core:get_all_config(SId1),
    {ok, Config2} = beam_agent_control_core:get_all_config(SId2),
    ?assertEqual(<<"model-1">>, maps:get(model, Config1)),
    ?assertEqual(<<"model-2">>, maps:get(model, Config2)),
    ?assertNot(maps:is_key(model, maps:without([model], Config1))
        andalso maps:get(model, Config1) =:= <<"model-2">>),
    beam_agent_control_core:clear().

clear_config_test() ->
    SId = <<"cfg-clear-session">>,
    beam_agent_control_core:set_config(SId, model, <<"claude">>),
    beam_agent_control_core:set_config(SId, permission_mode, <<"default">>),
    ok = beam_agent_control_core:clear_config(SId),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_config(SId, model)),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_config(SId, permission_mode)),
    beam_agent_control_core:clear().

clear_config_does_not_affect_other_sessions_test() ->
    SId1 = <<"cfg-clr-iso-1">>,
    SId2 = <<"cfg-clr-iso-2">>,
    beam_agent_control_core:set_config(SId1, model, <<"claude">>),
    beam_agent_control_core:set_config(SId2, model, <<"other">>),
    beam_agent_control_core:clear_config(SId1),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_config(SId1, model)),
    ?assertEqual({ok, <<"other">>}, beam_agent_control_core:get_config(SId2, model)),
    beam_agent_control_core:clear().

%%====================================================================
%% Permission mode convenience
%%====================================================================

set_get_permission_mode_test() ->
    SId = <<"perm-session">>,
    ok = beam_agent_control_core:set_permission_mode(SId, <<"bypassPermissions">>),
    ?assertEqual({ok, <<"bypassPermissions">>},
        beam_agent_control_core:get_permission_mode(SId)),
    beam_agent_control_core:clear().

get_permission_mode_not_set_test() ->
    SId = <<"perm-notset-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_permission_mode(SId)),
    beam_agent_control_core:clear().

%%====================================================================
%% Thinking tokens convenience
%%====================================================================

set_get_max_thinking_tokens_test() ->
    SId = <<"tokens-session">>,
    ok = beam_agent_control_core:set_max_thinking_tokens(SId, 16384),
    ?assertEqual({ok, 16384}, beam_agent_control_core:get_max_thinking_tokens(SId)),
    beam_agent_control_core:clear().

get_max_thinking_tokens_not_set_test() ->
    SId = <<"tokens-notset-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_set}, beam_agent_control_core:get_max_thinking_tokens(SId)),
    beam_agent_control_core:clear().

%%====================================================================
%% Task tracking
%%====================================================================

register_and_list_tasks_test() ->
    SId = <<"task-list-session">>,
    Pid = spawn(fun() -> timer:sleep(60000) end),
    ok = beam_agent_control_core:register_task(SId, <<"task-1">>, Pid),
    {ok, Tasks} = beam_agent_control_core:list_tasks(SId),
    ?assertEqual(1, length(Tasks)),
    [Task] = Tasks,
    ?assertEqual(<<"task-1">>, maps:get(task_id, Task)),
    ?assertEqual(SId, maps:get(session_id, Task)),
    ?assertEqual(Pid, maps:get(pid, Task)),
    ?assertEqual(running, maps:get(status, Task)),
    exit(Pid, kill),
    beam_agent_control_core:clear().

list_tasks_empty_test() ->
    SId = <<"task-empty-session">>,
    beam_agent_control_core:ensure_tables(),
    {ok, Tasks} = beam_agent_control_core:list_tasks(SId),
    ?assertEqual([], Tasks),
    beam_agent_control_core:clear().

unregister_task_test() ->
    SId = <<"task-unreg-session">>,
    Pid = spawn(fun() -> timer:sleep(60000) end),
    beam_agent_control_core:register_task(SId, <<"task-x">>, Pid),
    ok = beam_agent_control_core:unregister_task(SId, <<"task-x">>),
    {ok, Tasks} = beam_agent_control_core:list_tasks(SId),
    ?assertEqual([], Tasks),
    exit(Pid, kill),
    beam_agent_control_core:clear().

stop_task_running_test() ->
    SId = <<"task-stop-session">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    beam_agent_control_core:register_task(SId, <<"task-stop">>, Pid),
    ok = beam_agent_control_core:stop_task(SId, <<"task-stop">>),
    %% Task should be marked stopped, still in list
    {ok, Tasks} = beam_agent_control_core:list_tasks(SId),
    ?assertEqual(1, length(Tasks)),
    [Task] = Tasks,
    ?assertEqual(stopped, maps:get(status, Task)),
    beam_agent_control_core:clear().

stop_task_already_stopped_test() ->
    SId = <<"task-already-stopped-session">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    beam_agent_control_core:register_task(SId, <<"task-s2">>, Pid),
    ok = beam_agent_control_core:stop_task(SId, <<"task-s2">>),
    %% Second stop on an already-stopped task returns ok
    ok = beam_agent_control_core:stop_task(SId, <<"task-s2">>),
    beam_agent_control_core:clear().

stop_task_not_found_test() ->
    SId = <<"task-notfound-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_found},
        beam_agent_control_core:stop_task(SId, <<"no-such-task">>)),
    beam_agent_control_core:clear().

stop_task_dead_process_test() ->
    SId = <<"task-dead-session">>,
    Pid = spawn(fun() -> ok end),
    %% Let process finish
    timer:sleep(10),
    beam_agent_control_core:register_task(SId, <<"task-dead">>, Pid),
    %% Should handle dead process gracefully
    ok = beam_agent_control_core:stop_task(SId, <<"task-dead">>),
    beam_agent_control_core:clear().

list_tasks_isolates_sessions_test() ->
    SId1 = <<"task-iso-1">>,
    SId2 = <<"task-iso-2">>,
    Pid1 = spawn(fun() -> ok end),
    Pid2 = spawn(fun() -> ok end),
    beam_agent_control_core:register_task(SId1, <<"t1">>, Pid1),
    beam_agent_control_core:register_task(SId2, <<"t2">>, Pid2),
    {ok, Tasks1} = beam_agent_control_core:list_tasks(SId1),
    {ok, Tasks2} = beam_agent_control_core:list_tasks(SId2),
    ?assertEqual(1, length(Tasks1)),
    ?assertEqual(1, length(Tasks2)),
    [T1] = Tasks1,
    [T2] = Tasks2,
    ?assertEqual(<<"t1">>, maps:get(task_id, T1)),
    ?assertEqual(<<"t2">>, maps:get(task_id, T2)),
    beam_agent_control_core:clear().

%%====================================================================
%% Feedback
%%====================================================================

submit_and_get_feedback_test() ->
    SId = <<"fb-basic-session">>,
    ok = beam_agent_control_core:submit_feedback(SId, #{rating => good}),
    {ok, Feedback} = beam_agent_control_core:get_feedback(SId),
    ?assertEqual(1, length(Feedback)),
    [Entry] = Feedback,
    ?assertEqual(good, maps:get(rating, Entry)),
    ?assertEqual(SId, maps:get(session_id, Entry)),
    beam_agent_control_core:clear().

feedback_ordering_test() ->
    SId = <<"fb-order-session">>,
    beam_agent_control_core:submit_feedback(SId, #{order => first}),
    beam_agent_control_core:submit_feedback(SId, #{order => second}),
    beam_agent_control_core:submit_feedback(SId, #{order => third}),
    {ok, Feedback} = beam_agent_control_core:get_feedback(SId),
    ?assertEqual(3, length(Feedback)),
    [F1, F2, F3] = Feedback,
    ?assertEqual(first, maps:get(order, F1)),
    ?assertEqual(second, maps:get(order, F2)),
    ?assertEqual(third, maps:get(order, F3)),
    beam_agent_control_core:clear().

get_feedback_empty_test() ->
    SId = <<"fb-empty-session">>,
    beam_agent_control_core:ensure_tables(),
    {ok, Feedback} = beam_agent_control_core:get_feedback(SId),
    ?assertEqual([], Feedback),
    beam_agent_control_core:clear().

clear_feedback_test() ->
    SId = <<"fb-clear-session">>,
    beam_agent_control_core:submit_feedback(SId, #{rating => bad}),
    beam_agent_control_core:submit_feedback(SId, #{rating => good}),
    ok = beam_agent_control_core:clear_feedback(SId),
    {ok, Feedback} = beam_agent_control_core:get_feedback(SId),
    ?assertEqual([], Feedback),
    beam_agent_control_core:clear().

clear_feedback_does_not_affect_other_sessions_test() ->
    SId1 = <<"fb-clr-iso-1">>,
    SId2 = <<"fb-clr-iso-2">>,
    beam_agent_control_core:submit_feedback(SId1, #{from => s1}),
    beam_agent_control_core:submit_feedback(SId2, #{from => s2}),
    beam_agent_control_core:clear_feedback(SId1),
    {ok, F1} = beam_agent_control_core:get_feedback(SId1),
    {ok, F2} = beam_agent_control_core:get_feedback(SId2),
    ?assertEqual([], F1),
    ?assertEqual(1, length(F2)),
    beam_agent_control_core:clear().

%%====================================================================
%% Pending request lifecycle
%%====================================================================

store_and_list_pending_requests_test() ->
    SId = <<"pr-list-session">>,
    Request = #{<<"type">> => <<"user_input">>, <<"prompt">> => <<"Enter value:">>},
    ok = beam_agent_control_core:store_pending_request(SId, <<"req-1">>, Request),
    {ok, Reqs} = beam_agent_control_core:list_pending_requests(SId),
    ?assertEqual(1, length(Reqs)),
    [Req] = Reqs,
    ?assertEqual(<<"req-1">>, maps:get(request_id, Req)),
    ?assertEqual(pending, maps:get(status, Req)),
    StoredRequest = maps:get(request, Req),
    ?assertEqual(<<"beam_agent.control.request.v1">>, maps:get(schema_version, StoredRequest)),
    ?assertEqual(universal, maps:get(source, StoredRequest)),
    beam_agent_control_core:clear().

pending_request_events_are_canonicalized_test() ->
    SId = <<"pr-events-session">>,
    ok = beam_agent_events:clear(),
    {ok, Ref} = beam_agent_events:subscribe(SId),
    ok = beam_agent_control_core:store_pending_request(SId, <<"req-evt">>, #{prompt => <<"Enter">>}),
    ?assertMatch({ok, #{
        subtype := <<"pending_request_stored">>,
        session_id := SId,
        source := universal,
        event_class := control
    }}, beam_agent_events:receive_event(Ref, 0)),
    ok = beam_agent_control_core:resolve_pending_request(SId, <<"req-evt">>, #{answer => <<"ok">>}),
    ?assertMatch({ok, #{
        subtype := <<"pending_request_resolved">>,
        session_id := SId,
        source := universal,
        event_class := control
    }}, beam_agent_events:receive_event(Ref, 0)),
    ?assertEqual(ok, beam_agent_events:unsubscribe(SId, Ref)),
    beam_agent_control_core:clear(),
    ok = beam_agent_events:clear().

list_pending_requests_empty_test() ->
    SId = <<"pr-empty-session">>,
    beam_agent_control_core:ensure_tables(),
    {ok, Reqs} = beam_agent_control_core:list_pending_requests(SId),
    ?assertEqual([], Reqs),
    beam_agent_control_core:clear().

get_pending_response_unresolved_test() ->
    SId = <<"pr-unres-session">>,
    beam_agent_control_core:store_pending_request(SId, <<"req-u">>,
        #{<<"prompt">> => <<"??">>}),
    ?assertEqual({error, pending},
        beam_agent_control_core:get_pending_response(SId, <<"req-u">>)),
    beam_agent_control_core:clear().

get_pending_response_not_found_test() ->
    SId = <<"pr-notfound-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_found},
        beam_agent_control_core:get_pending_response(SId, <<"no-such-req">>)),
    beam_agent_control_core:clear().

resolve_pending_request_test() ->
    SId = <<"pr-resolve-session">>,
    beam_agent_control_core:store_pending_request(SId, <<"req-r">>,
        #{<<"prompt">> => <<"Enter:">>}),
    Response = #{<<"value">> => <<"user-answer">>},
    ok = beam_agent_control_core:resolve_pending_request(SId, <<"req-r">>, Response),
    {ok, Got} = beam_agent_control_core:get_pending_response(SId, <<"req-r">>),
    ?assertEqual(<<"user-answer">>, maps:get(<<"value">>, Got)),
    beam_agent_control_core:clear().

resolve_pending_request_double_resolve_test() ->
    SId = <<"pr-double-session">>,
    beam_agent_control_core:store_pending_request(SId, <<"req-d">>,
        #{<<"prompt">> => <<"?">>}),
    ok = beam_agent_control_core:resolve_pending_request(SId, <<"req-d">>,
        #{<<"value">> => <<"first">>}),
    ?assertEqual({error, already_resolved},
        beam_agent_control_core:resolve_pending_request(SId, <<"req-d">>,
            #{<<"value">> => <<"second">>})),
    beam_agent_control_core:clear().

resolve_pending_request_not_found_test() ->
    SId = <<"pr-res-notfound-session">>,
    beam_agent_control_core:ensure_tables(),
    ?assertEqual({error, not_found},
        beam_agent_control_core:resolve_pending_request(SId, <<"no-such-req">>,
            #{<<"value">> => <<"x">>})),
    beam_agent_control_core:clear().

pending_requests_isolate_sessions_test() ->
    SId1 = <<"pr-iso-1">>,
    SId2 = <<"pr-iso-2">>,
    beam_agent_control_core:store_pending_request(SId1, <<"req-a">>, #{<<"q">> => <<"1">>}),
    beam_agent_control_core:store_pending_request(SId2, <<"req-b">>, #{<<"q">> => <<"2">>}),
    {ok, Reqs1} = beam_agent_control_core:list_pending_requests(SId1),
    {ok, Reqs2} = beam_agent_control_core:list_pending_requests(SId2),
    ?assertEqual(1, length(Reqs1)),
    ?assertEqual(1, length(Reqs2)),
    [R1] = Reqs1,
    [R2] = Reqs2,
    ?assertEqual(<<"req-a">>, maps:get(request_id, R1)),
    ?assertEqual(<<"req-b">>, maps:get(request_id, R2)),
    beam_agent_control_core:clear().

%%====================================================================
%% Callback broker
%%====================================================================

register_and_request_permission_test() ->
    SId = <<"cb-permission-session">>,
    Handler = fun(_Method, Params, _Context) ->
        {allow, Params#{approved => true}}
    end,
    ok = beam_agent_control_core:register_session_callbacks(SId, #{
        permission_handler => Handler
    }),
    ?assertEqual({allow, #{foo => bar, approved => true}},
        beam_agent_control_core:request_permission(SId, <<"tool/use">>, #{foo => bar}, #{})),
    beam_agent_control_core:clear().

request_approval_via_approval_handler_test() ->
    SId = <<"cb-approval-session">>,
    Handler = fun(_Method, _Params, _Context) ->
        accept_for_session
    end,
    ok = beam_agent_control_core:register_session_callbacks(SId, #{
        approval_handler => Handler
    }),
    ?assertEqual(accept_for_session,
        beam_agent_control_core:request_approval(SId, <<"tool/use">>, #{}, #{})),
    beam_agent_control_core:clear().

request_user_input_via_callback_broker_test() ->
    SId = <<"cb-input-session">>,
    Handler = fun(_Request, _Context) ->
        {ok, #{answer => <<"typed">>}}
    end,
    ok = beam_agent_control_core:register_session_callbacks(SId, #{
        user_input_handler => Handler
    }),
    ?assertEqual({ok, #{answer => <<"typed">>}},
        beam_agent_control_core:request_user_input(SId, #{prompt => <<"Enter">>}, #{
            request_id => <<"req-input">>
        })),
    {ok, Response} = beam_agent_control_core:get_pending_response(SId, <<"req-input">>),
    ?assertEqual(#{answer => <<"typed">>}, maps:get(response, Response)),
    beam_agent_control_core:clear().

request_user_input_without_handler_test() ->
    SId = <<"cb-no-input-session">>,
    ok = beam_agent_control_core:register_session_callbacks(SId, #{}),
    {ok, Pending} = beam_agent_control_core:request_user_input(SId,
        #{prompt => <<"Enter">>},
        #{}),
    ?assertEqual(pending, maps:get(status, Pending)),
    ?assertEqual(universal, maps:get(source, Pending)),
    ?assertEqual(awaiting_external_response, maps:get(reason, Pending)),
    ?assertMatch(#{prompt := <<"Enter">>},
        maps:get(request, Pending)),
    ?assertEqual({error, pending},
        beam_agent_control_core:get_pending_response(SId,
            maps:get(request_id, Pending))),
    beam_agent_control_core:clear().

request_user_input_handler_failure_degrades_to_pending_test() ->
    SId = <<"cb-input-failed-session">>,
    Handler = fun(_Request, _Context) ->
        erlang:error(handler_crash)
    end,
    ok = beam_agent_control_core:register_session_callbacks(SId, #{
        user_input_handler => Handler
    }),
    {ok, Pending} = beam_agent_control_core:request_user_input(SId,
        #{prompt => <<"Enter">>},
        #{request_id => <<"req-failed">>}),
    ?assertEqual(pending, maps:get(status, Pending)),
    ?assertEqual(handler_failed, maps:get(reason, Pending)),
    ?assertEqual({error, pending},
        beam_agent_control_core:get_pending_response(SId, <<"req-failed">>)),
    beam_agent_control_core:clear().
