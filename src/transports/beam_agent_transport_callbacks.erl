-module(beam_agent_transport_callbacks).
-compile([nowarn_missing_spec]).
-moduledoc """
Reusable callback/control helpers for backends that need approvals, user input,
turn responses, or other out-of-band session control.
""".

-export([
    ensure_tables/0,
    clear/0,
    dispatch/3,
    hook/2,
    hook/3,
    new_registry/0,
    register_hook/2,
    register_hooks/2,
    fire/3,
    build_registry/1,
    set_permission_mode/2,
    get_permission_mode/1,
    set_max_thinking_tokens/2,
    get_max_thinking_tokens/1,
    register_task/3,
    unregister_task/2,
    stop_task/2,
    list_tasks/1,
    submit_feedback/2,
    get_feedback/1,
    clear_feedback/1,
    store_pending_request/3,
    resolve_pending_request/3,
    get_pending_response/2,
    list_pending_requests/1
]).

ensure_tables() -> beam_agent_control_core:ensure_tables().
clear() ->
    ok = beam_agent_control_core:clear(),
    ok.
dispatch(SessionId, Method, Params) -> beam_agent_control_core:dispatch(SessionId, Method, Params).
hook(Event, Callback) -> beam_agent_hooks_core:hook(Event, Callback).
hook(Event, Callback, Matcher) -> beam_agent_hooks_core:hook(Event, Callback, Matcher).
new_registry() -> beam_agent_hooks_core:new_registry().
register_hook(Hook, Registry) -> beam_agent_hooks_core:register_hook(Hook, Registry).
register_hooks(Hooks, Registry) -> beam_agent_hooks_core:register_hooks(Hooks, Registry).
fire(Event, Context, Registry) -> beam_agent_hooks_core:fire(Event, Context, Registry).
build_registry(Opts) -> beam_agent_hooks_core:build_registry(Opts).
set_permission_mode(SessionId, Mode) -> beam_agent_control_core:set_permission_mode(SessionId, Mode).
get_permission_mode(SessionId) -> beam_agent_control_core:get_permission_mode(SessionId).
set_max_thinking_tokens(SessionId, Tokens) ->
    beam_agent_control_core:set_max_thinking_tokens(SessionId, Tokens).
get_max_thinking_tokens(SessionId) -> beam_agent_control_core:get_max_thinking_tokens(SessionId).
register_task(SessionId, TaskId, Pid) -> beam_agent_control_core:register_task(SessionId, TaskId, Pid).
unregister_task(SessionId, TaskId) -> beam_agent_control_core:unregister_task(SessionId, TaskId).
stop_task(SessionId, TaskId) -> beam_agent_control_core:stop_task(SessionId, TaskId).
list_tasks(SessionId) -> beam_agent_control_core:list_tasks(SessionId).
submit_feedback(SessionId, Feedback) -> beam_agent_control_core:submit_feedback(SessionId, Feedback).
get_feedback(SessionId) -> beam_agent_control_core:get_feedback(SessionId).
clear_feedback(SessionId) -> beam_agent_control_core:clear_feedback(SessionId).
store_pending_request(SessionId, RequestId, Request) ->
    beam_agent_control_core:store_pending_request(SessionId, RequestId, Request).
resolve_pending_request(SessionId, RequestId, Response) ->
    beam_agent_control_core:resolve_pending_request(SessionId, RequestId, Response).
get_pending_response(SessionId, RequestId) ->
    beam_agent_control_core:get_pending_response(SessionId, RequestId).
list_pending_requests(SessionId) -> beam_agent_control_core:list_pending_requests(SessionId).
