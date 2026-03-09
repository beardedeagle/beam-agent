-module(beam_agent_raw).
-compile([nowarn_missing_spec]).
-moduledoc """
Minimal escape-hatch namespace for transport/debug access only.

All user-visible features (threads, turns, skills, apps, files, MCP, accounts,
fuzzy search, etc.) are available through the canonical `beam_agent` module with
universal fallbacks across all backends.

This module exposes only the low-level primitives needed when callers must
bypass the canonical routing layer entirely:
- Transport identity inspection (`backend/1`, `adapter_module/1`)
- Generic escape hatches (`call/3`, `call_backend/3`)
- Native session access at the transport level
- Transport-level health, status, and auth probes
""".

-export([
    backend/1,
    adapter_module/1,
    call/3,
    call_backend/3,
    list_native_sessions/0,
    list_native_sessions/1,
    get_native_session_messages/1,
    get_native_session_messages/2,
    session_destroy/1,
    session_destroy/2,
    server_health/1,
    get_status/1,
    get_auth_status/1,
    get_last_session_id/1
]).

-define(RAW0(Name), Name(Session) -> call(Session, Name, [])).
-define(RAW1(Name, A1), Name(Session, A1) -> call(Session, Name, [A1])).
-define(RAW2(Name, A1, A2), Name(Session, A1, A2) -> call(Session, Name, [A1, A2])).
-define(RAW3(Name, A1, A2, A3), Name(Session, A1, A2, A3) -> call(Session, Name, [A1, A2, A3])).
-define(RAW4(Name, A1, A2, A3, A4),
        Name(Session, A1, A2, A3, A4) -> call(Session, Name, [A1, A2, A3, A4])).

-define(BACKEND0(Name, Backend), Name() -> call_backend(Backend, Name, [])).
-define(BACKEND1(Name, Backend, A1), Name(A1) -> call_backend(Backend, Name, [A1])).
-define(BACKEND2(Name, Backend, A1, A2), Name(A1, A2) -> call_backend(Backend, Name, [A1, A2])).

backend(Session) -> beam_agent_raw_core:backend(Session).
adapter_module(Session) -> beam_agent_raw_core:adapter_module(Session).
call(Session, Function, Args) -> beam_agent_raw_core:call(Session, Function, Args).
call_backend(BackendLike, Function, Args) ->
    beam_agent_raw_core:call_backend(BackendLike, Function, Args).

%% Transport-level native session access (Claude-native listing/inspection).
?BACKEND0(list_native_sessions, claude).
?BACKEND1(list_native_sessions, claude, Opts).
?BACKEND1(get_native_session_messages, claude, SessionId).
?BACKEND2(get_native_session_messages, claude, SessionId, Opts).

session_destroy(Session) ->
    call(Session, session_destroy, [session_identity(Session)]).
?RAW1(session_destroy, SessionId).

?RAW0(server_health).
?RAW0(get_status).
?RAW0(get_auth_status).
?RAW0(get_last_session_id).

-spec session_identity(pid()) -> binary().
session_identity(Session) ->
    case beam_agent:session_info(Session) of
        {ok, #{session_id := SessionId}} when is_binary(SessionId),
                                              byte_size(SessionId) > 0 ->
            SessionId;
        _ ->
            unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.
