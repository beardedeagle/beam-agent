-module(beam_agent_control).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for the consolidated control and callback state layer.".

-export([
    ensure_tables/0,
    clear/0,
    dispatch/3,
    get_config/2,
    set_config/3,
    get_all_config/1,
    clear_config/1,
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
    register_session_callbacks/2,
    clear_session_callbacks/1,
    request_permission/4,
    request_approval/4,
    request_user_input/3,
    store_pending_request/3,
    resolve_pending_request/3,
    get_pending_response/2,
    list_pending_requests/1
]).

ensure_tables() -> beam_agent_control_core:ensure_tables().
clear() -> beam_agent_control_core:clear().
dispatch(SessionId, Method, Params) -> beam_agent_control_core:dispatch(SessionId, Method, Params).
get_config(SessionId, Key) -> beam_agent_control_core:get_config(SessionId, Key).
set_config(SessionId, Key, Value) -> beam_agent_control_core:set_config(SessionId, Key, Value).
get_all_config(SessionId) -> beam_agent_control_core:get_all_config(SessionId).
clear_config(SessionId) -> beam_agent_control_core:clear_config(SessionId).
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
register_session_callbacks(SessionId, Opts) ->
    beam_agent_control_core:register_session_callbacks(SessionId, Opts).
clear_session_callbacks(SessionId) -> beam_agent_control_core:clear_session_callbacks(SessionId).
request_permission(SessionId, Method, Params, Context) ->
    beam_agent_control_core:request_permission(SessionId, Method, Params, Context).
request_approval(SessionId, Method, Params, Context) ->
    beam_agent_control_core:request_approval(SessionId, Method, Params, Context).
request_user_input(SessionId, Request, Context) ->
    beam_agent_control_core:request_user_input(SessionId, Request, Context).
store_pending_request(SessionId, RequestId, Request) ->
    beam_agent_control_core:store_pending_request(SessionId, RequestId, Request).
resolve_pending_request(SessionId, RequestId, Response) ->
    beam_agent_control_core:resolve_pending_request(SessionId, RequestId, Response).
get_pending_response(SessionId, RequestId) ->
    beam_agent_control_core:get_pending_response(SessionId, RequestId).
list_pending_requests(SessionId) -> beam_agent_control_core:list_pending_requests(SessionId).
