-module(beam_agent_router).
-moduledoc false.

-dialyzer({no_underspecs, [route_session_capability/3, call_module/5]}).

-export([
    start_session/1,
    child_spec/1,
    stop/1,
    query/2,
    query/3,
    send_query/4,
    receive_message/3,
    session_info/1,
    health/1,
    backend/1,
    adapter_module/1,
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    send_control/3,
    list_sessions/0,
    list_sessions/1,
    get_session_messages/1,
    get_session_messages/2,
    get_session/1,
    delete_session/1,
    fork_session/2,
    revert_session/2,
    unrevert_session/1,
    share_session/1,
    share_session/2,
    unshare_session/1,
    summarize_session/1,
    summarize_session/2,
    thread_start/2,
    thread_resume/2,
    thread_list/1,
    thread_fork/2,
    thread_fork/3,
    thread_read/2,
    thread_read/3,
    thread_archive/2,
    thread_unarchive/2,
    thread_rollback/3,
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    account_info/1,
    server_health/1
]).

-doc "Start a unified session. `Opts.backend` is required.".
-spec start_session(beam_agent_core:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) when is_map(Opts) ->
    case maps:get(backend, Opts, undefined) of
        undefined ->
            {error, {missing_option, backend}};
        BackendLike ->
            case beam_agent_backend:normalize(BackendLike) of
                {ok, Backend} ->
                    Module = beam_agent_backend:adapter_module(Backend),
                    SessionOpts = maps:remove(backend, Opts),
                    case Module:start_session(SessionOpts) of
                        {ok, Session} ->
                            _ = beam_agent_backend:register_session(Session, Backend),
                            ok = beam_agent_runtime_core:register_session(Session, SessionOpts),
                            ok = register_callback_broker(Session, SessionOpts),
                            {ok, Session};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

-doc "Return a child spec for a unified session. `Opts.backend` is required.".
-spec child_spec(beam_agent_core:session_opts()) -> supervisor:child_spec().
child_spec(Opts) when is_map(Opts) ->
    case maps:find(backend, Opts) of
        {ok, BackendLike} ->
            {ok, Backend} = beam_agent_backend:normalize(BackendLike),
            Module = beam_agent_backend:adapter_module(Backend),
            Module:child_spec(maps:remove(backend, Opts));
        error ->
            erlang:error({missing_option, backend})
    end.

-doc "Stop a live unified session.".
-spec stop(pid()) -> ok.
stop(Session) when is_pid(Session) ->
    %% Resolve session_id while process is still alive so cleanup
    %% can clear the real session_id entry, not just the pid-based one.
    SessionId = session_id(Session),
    try
        case adapter_module(Session) of
            {ok, Module} ->
                case erlang:function_exported(Module, stop, 1) of
                    true -> Module:stop(Session);
                    false -> gen_statem:stop(Session, normal, 10000)
                end;
            _ ->
                gen_statem:stop(Session, normal, 10000)
        end
    catch
        Class:Reason ->
            logger:warning("session stop failed: ~p:~p", [Class, Reason])
    after
        _ = beam_agent_backend:unregister_session(Session),
        _ = beam_agent_runtime_core:clear_session(Session),
        _ = clear_callback_broker(Session, SessionId)
    end,
    ok.

-doc "Send a blocking query with default params.".
-spec query(pid(), binary()) -> {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

-doc "Send a blocking query through the canonical router.".
-spec query(pid(), binary(), beam_agent_core:query_opts()) ->
    {ok, [beam_agent_core:message()]} | {error, term()}.
query(Session, Prompt, Params)
  when is_pid(Session), is_binary(Prompt), is_map(Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            {ok, Backend} = backend(Session),
            Terminal = fun(Msg) ->
                beam_agent_backend:is_terminal(Backend, Msg)
            end,
            beam_agent_core:collect_messages(Session, Ref, Deadline,
                fun receive_message/3, Terminal);
        {error, _} = Error ->
            Error
    end.

-doc "Send a query and return the live query reference.".
-spec send_query(pid(), binary(), beam_agent_core:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Session, Prompt, Params, Timeout)
  when is_pid(Session), is_binary(Prompt), is_map(Params) ->
    Merged = beam_agent_runtime_core:merge_query_opts(Session, Params),
    {PreparedPrompt, PreparedParams} =
        beam_agent_attachments:prepare(Session, Prompt, Merged),
    gen_statem:call(Session, {send_query, PreparedPrompt, PreparedParams}, Timeout).

-doc "Pull the next message from a live query.".
-spec receive_message(pid(), reference(), timeout()) ->
    {ok, beam_agent_core:message()} | {error, term()}.
receive_message(Session, Ref, Timeout)
  when is_pid(Session), is_reference(Ref) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).

-doc "Query session info for a live session.".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) when is_pid(Session) ->
    try gen_statem:call(Session, session_info, 5000) of
        {ok, Info} when is_map(Info) ->
            case maps:get(adapter, Info, undefined) of
                undefined ->
                    {ok, Info};
                Adapter ->
                    _ = beam_agent_backend:register_session(Session, Adapter),
                    {ok, Info}
            end;
        Other ->
            {error, {invalid_session_info, Other}}
    catch
        exit:Reason ->
            {error, Reason}
    end.

-doc "Return the health state for a live session.".
-spec health(pid()) -> atom().
health(Session) when is_pid(Session) ->
    gen_statem:call(Session, health, 5000).

-doc "Resolve the backend for a live session.".
-spec backend(pid()) -> {ok, beam_agent_backend:backend()} |
    {error, beam_agent_backend:backend_lookup_error()}.
backend(Session) when is_pid(Session) ->
    beam_agent_backend:session_backend(Session).

-doc "Resolve the adapter facade module for a live session.".
-spec adapter_module(pid()) -> {ok, beam_agent_backend:adapter_module()} |
    {error, beam_agent_backend:backend_lookup_error()}.
adapter_module(Session) when is_pid(Session) ->
    case backend(Session) of
        {ok, Backend} ->
            {ok, beam_agent_backend:adapter_module(Backend)};
        {error, _} = Error ->
            Error
    end.

-doc "Change the model at runtime.".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) when is_pid(Session), is_binary(Model) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, set_model, [Model],
                fun() -> gen_statem:call(Session, {set_model, Model}, 5000) end);
        {error, _} = Error ->
            Error
    end.

-doc "Change the permission mode at runtime.".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) when is_pid(Session), is_binary(Mode) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, set_permission_mode, [Mode],
                fun() ->
                    SessionId = session_id(Session),
                    beam_agent_control_core:set_permission_mode(SessionId, Mode),
                    {ok, #{permission_mode => Mode}}
                end);
        {error, _} = Error ->
            Error
    end.

-doc "Interrupt active work on the session.".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) when is_pid(Session) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, interrupt, [],
                fun() -> gen_statem:call(Session, interrupt, 5000) end);
        {error, _} = Error ->
            Error
    end.

-doc "Abort active work on the session.".
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) when is_pid(Session) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, abort, [],
                fun() -> interrupt(Session) end);
        {error, _} = Error ->
            Error
    end.

-doc "Send a control message through the appropriate native or shared path.".
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params)
  when is_pid(Session), is_binary(Method), is_map(Params) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, send_control, [Method, Params],
                fun() ->
                    SessionId = session_id(Session),
                    beam_agent_control_core:dispatch(SessionId, Method, Params)
                end);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Shared session store
%%--------------------------------------------------------------------

-doc "List all tracked sessions in the shared store.".
-spec list_sessions() -> {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions() ->
    beam_agent_session_store_core:list_sessions().

-doc "List tracked sessions with filters.".
-spec list_sessions(beam_agent_session_store_core:list_opts()) ->
    {ok, [beam_agent_session_store_core:session_meta()]}.
list_sessions(Opts) when is_map(Opts) ->
    beam_agent_session_store_core:list_sessions(normalize_list_opts(Opts)).

-doc "Get all visible messages for a session id.".
-spec get_session_messages(binary()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    beam_agent_session_store_core:get_session_messages(SessionId).

-doc "Get visible messages for a session id with options.".
-spec get_session_messages(binary(), beam_agent_session_store_core:message_opts()) ->
    {ok, [beam_agent_core:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) when is_map(Opts) ->
    beam_agent_session_store_core:get_session_messages(SessionId, Opts).

-doc "Read shared session metadata by session id.".
-spec get_session(binary()) ->
    {ok, beam_agent_session_store_core:session_meta()} | {error, not_found}.
get_session(SessionId) ->
    beam_agent_session_store_core:get_session(SessionId).

-doc "Delete a tracked session from the shared store.".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    beam_agent_session_store_core:delete_session(SessionId).

%%--------------------------------------------------------------------
%% Routed session mutation
%%--------------------------------------------------------------------

-doc "Fork a live session.".
-spec fork_session(pid(), map()) -> {ok, map()} | {error, term()}.
fork_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    route_session_capability(Session, fork_session, [Opts]).

-doc "Revert a live session.".
-spec revert_session(pid(), map()) -> {ok, map()} | {error, term()}.
revert_session(Session, Selector) when is_pid(Session), is_map(Selector) ->
    route_session_capability(Session, revert_session, [Selector]).

-doc "Clear a session revert state.".
-spec unrevert_session(pid()) -> {ok, map()} | {error, term()}.
unrevert_session(Session) when is_pid(Session) ->
    route_session_capability(Session, unrevert_session, []).

-doc "Share a live session with default opts.".
-spec share_session(pid()) -> {ok, map()} | {error, term()}.
share_session(Session) when is_pid(Session) ->
    share_session(Session, #{}).

-doc "Share a live session.".
-spec share_session(pid(), map()) -> {ok, map()} | {error, term()}.
share_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    route_session_capability(Session, share_session, [Opts]).

-doc "Revoke sharing for a live session.".
-spec unshare_session(pid()) -> ok | {error, term()}.
unshare_session(Session) when is_pid(Session) ->
    route_session_capability(Session, unshare_session, []).

-doc "Summarize a live session with default opts.".
-spec summarize_session(pid()) -> {ok, map()} | {error, term()}.
summarize_session(Session) when is_pid(Session) ->
    summarize_session(Session, #{}).

-doc "Summarize a live session.".
-spec summarize_session(pid(), map()) -> {ok, map()} | {error, term()}.
summarize_session(Session, Opts) when is_pid(Session), is_map(Opts) ->
    route_session_capability(Session, summarize_session, [Opts]).

%%--------------------------------------------------------------------
%% Routed thread management
%%--------------------------------------------------------------------

-doc "Start a thread for a live session.".
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) when is_pid(Session), is_map(Opts) ->
    route_session_capability(Session, thread_start, [Opts]).

-doc "Resume a thread.".
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    route_session_capability(Session, thread_resume, [ThreadId]).

-doc "List threads for a live session.".
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) when is_pid(Session) ->
    route_session_capability(Session, thread_list, []).

-doc "Fork a thread with default opts.".
-spec thread_fork(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    thread_fork(Session, ThreadId, #{}).

-doc "Fork a thread.".
-spec thread_fork(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_fork(Session, ThreadId, Opts)
  when is_pid(Session), is_binary(ThreadId), is_map(Opts) ->
    route_session_capability(Session, thread_fork, [ThreadId, Opts]).

-doc "Read a thread with default opts.".
-spec thread_read(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    thread_read(Session, ThreadId, #{}).

-doc "Read a thread.".
-spec thread_read(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_read(Session, ThreadId, Opts)
  when is_pid(Session), is_binary(ThreadId), is_map(Opts) ->
    route_session_capability(Session, thread_read, [ThreadId, Opts]).

-doc "Archive a thread.".
-spec thread_archive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_archive(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    route_session_capability(Session, thread_archive, [ThreadId]).

-doc "Unarchive a thread.".
-spec thread_unarchive(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_unarchive(Session, ThreadId) when is_pid(Session), is_binary(ThreadId) ->
    route_session_capability(Session, thread_unarchive, [ThreadId]).

-doc "Rollback a thread.".
-spec thread_rollback(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
thread_rollback(Session, ThreadId, Selector)
  when is_pid(Session), is_binary(ThreadId), is_map(Selector) ->
    route_session_capability(Session, thread_rollback, [ThreadId, Selector]).

%%--------------------------------------------------------------------
%% Routed metadata accessors
%%--------------------------------------------------------------------

-doc "List slash commands from session init data.".
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) when is_pid(Session) ->
    route_session_capability(Session, supported_commands, []).

-doc "List models from session init data.".
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) when is_pid(Session) ->
    route_session_capability(Session, supported_models, []).

-doc "List agents from session init data.".
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) when is_pid(Session) ->
    route_session_capability(Session, supported_agents, []).

-doc "Get account info from session init data.".
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) when is_pid(Session) ->
    route_session_capability(Session, account_info, []).

-doc "Return high-level server health details when a backend exposes them.".
-spec server_health(pid()) -> {ok, map()} | {error, term()}.
server_health(Session) when is_pid(Session) ->
    route_session_capability(Session, server_health, []).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec route_session_capability(pid(), atom(), [term()]) -> term().
route_session_capability(Session, Function, Args) ->
    case adapter_module(Session) of
        {ok, Module} ->
            call_module(Session, Module, Function, Args,
                fun() -> {error, {unsupported_capability, Function}} end);
        {error, _} = Error ->
            Error
    end.

-spec call_module(pid(), module(), atom(), [term()], fun(() -> term())) -> term().
call_module(Session, Module, Function, Args, Fallback) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Arity = length(Args) + 1,
            case erlang:function_exported(Module, Function, Arity) of
                true ->
                    apply(Module, Function, [Session | Args]);
                false ->
                    Fallback()
            end;
        {error, _} ->
            Fallback()
    end.

-spec session_id(pid()) -> binary().
session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SessionId}} when is_binary(SessionId),
                                              byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

-spec register_callback_broker(pid(), map()) -> ok.
register_callback_broker(Session, SessionOpts) ->
    SessionId = session_id(Session),
    ok = beam_agent_control_core:register_session_callbacks(SessionId, SessionOpts),
    PidSessionId = unicode:characters_to_binary(erlang:pid_to_list(Session)),
    case PidSessionId =:= SessionId of
        true ->
            ok;
        false ->
            beam_agent_control_core:register_session_callbacks(PidSessionId, SessionOpts)
    end.

-spec clear_callback_broker(pid(), binary()) -> ok.
clear_callback_broker(Session, SessionId) ->
    ok = beam_agent_control_core:clear_session_callbacks(SessionId),
    PidSessionId = unicode:characters_to_binary(erlang:pid_to_list(Session)),
    case PidSessionId =:= SessionId of
        true ->
            ok;
        false ->
            beam_agent_control_core:clear_session_callbacks(PidSessionId)
    end.

-spec normalize_list_opts(map()) -> map().
normalize_list_opts(Opts) ->
    case maps:get(backend, Opts, undefined) of
        undefined ->
            Opts;
        BackendLike ->
            case beam_agent_backend:normalize(BackendLike) of
                {ok, Backend} ->
                    maps:put(adapter, Backend, maps:remove(backend, Opts));
                {error, _} ->
                    maps:remove(backend, Opts)
            end
    end.
