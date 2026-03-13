-module(beam_agent_raw).
-moduledoc """
Minimal escape-hatch namespace for transport-level and debug access only.

All user-visible features — threads, turns, skills, apps, files, MCP, accounts,
fuzzy search, and so on — are available through the canonical `beam_agent`
module with universal fallbacks across all five backends. You almost certainly
want `beam_agent`, not this module.

## When to use beam_agent_raw

Use `beam_agent_raw` only when you need to:

- Inspect transport-level identity (`backend/1`, `adapter_module/1`)
- Call a backend-native function that does not yet have a canonical wrapper
  (`call/3`, `call_backend/3`)
- Access Claude-native session listing or message inspection
  (`list_native_sessions/0,1`, `get_native_session_messages/1,2`)
- Probe transport-level health, status, and auth without the canonical layer
  (`server_health/1`, `get_status/1`, `get_auth_status/1`, `get_last_session_id/1`)

## call/3 vs call_backend/3

`call/3` takes a live session `pid()` and routes the function call to the
correct backend adapter for that session, prepending the session pid to the
argument list:

```erlang
%% Calls claude_agent_session:thread_realtime_start(SessionPid, Opts)
{ok, _} = beam_agent_raw:call(SessionPid, thread_realtime_start, [#{mode => <<"voice">>}]).
```

`call_backend/3` routes to a backend adapter by name (no session pid prepended),
which is useful for backend-scoped helpers that are not tied to an active session:

```erlang
{ok, Sessions} = beam_agent_raw:call_backend(claude, list_native_sessions, []).
```

## Native session access is Claude-only

`list_native_sessions`, `get_native_session_messages`, and the variants with
options are Claude-native operations that go directly to the Claude SDK session
store. They are not available on other backends.

## Core concepts

This module is the escape hatch for backend-specific features that do
not yet have a wrapper in the main beam_agent module. You almost
certainly want beam_agent instead -- use this module only when you need
something backend-specific or transport-level.

call/3 routes a function call through a live session. It takes a session
pid and prepends it to the argument list automatically. call_backend/3
routes by backend name without a session, which is useful for operations
that are not tied to an active session (e.g., listing Claude sessions).

Functions like backend/1 and adapter_module/1 let you inspect which
backend and adapter module a session is using. The server_health and
get_status functions probe transport-level state directly.

## Architecture deep dive

call/3 prepends the session pid to the args list and delegates to
beam_agent_raw_core:call/3. call_backend/3 does not prepend a pid
and routes via beam_agent_raw_core:call_backend/3 instead.

Return value normalization in the core wraps bare terms in ok tuples.
Native session access (list_native_sessions, get_native_session_messages)
is Claude-only and goes directly to the Claude SDK session store.

This module should stay small (currently 14 exports). As features
mature, they graduate from beam_agent_raw to beam_agent with proper
universal fallbacks. The anti-bloat guard in tests enforces this.

## Session destruction

`session_destroy/1` accepts a live session `pid()` and resolves the session ID
automatically. `session_destroy/2` accepts a session `pid()` and an explicit
`SessionId` binary for cases where the session process is no longer alive but
you still have a known ID.
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

%% Dialyzer: adapter_module/1 intentionally uses the broad module() type
%% in the public spec rather than enumerating concrete backend modules.
-dialyzer({no_underspecs, [adapter_module/1]}).

-define(RAW0(Name), Name(Session) -> call(Session, Name, [])).
-define(RAW1(Name, A1), Name(Session, A1) -> call(Session, Name, [A1])).
-define(RAW2(Name, A1, A2), Name(Session, A1, A2) -> call(Session, Name, [A1, A2])).
-define(RAW3(Name, A1, A2, A3), Name(Session, A1, A2, A3) -> call(Session, Name, [A1, A2, A3])).
-define(RAW4(Name, A1, A2, A3, A4),
        Name(Session, A1, A2, A3, A4) -> call(Session, Name, [A1, A2, A3, A4])).

-define(BACKEND0(Name, Backend), Name() -> call_backend(Backend, Name, [])).
-define(BACKEND1(Name, Backend, A1), Name(A1) -> call_backend(Backend, Name, [A1])).
-define(BACKEND2(Name, Backend, A1, A2), Name(A1, A2) -> call_backend(Backend, Name, [A1, A2])).

-doc """
Resolve the backend atom for a live session pid.

Returns `{ok, Backend}` where `Backend` is one of `claude | codex | gemini |
opencode | copilot`, or `{error, Reason}` if the session is not registered.
""".
-spec backend(pid()) ->
    {ok, beam_agent_backend:backend()} | {error, term()}.
backend(Session) -> beam_agent_raw_core:backend(Session).

-doc """
Resolve the adapter facade module for a live session pid.

Returns `{ok, Module}` where `Module` is the backend adapter module
(e.g. `claude_agent_session`), or `{error, Reason}` if the session is not
registered.
""".
-spec adapter_module(pid()) ->
    {ok, module()} | {error, term()}.
adapter_module(Session) -> beam_agent_raw_core:adapter_module(Session).

-doc """
Call a backend-native function for a live session, routing by session pid.

The session pid is prepended to `Args` before the call, so the effective
call is `AdapterModule:Function(Session, Args...)`. The return value is
normalised: bare terms are wrapped in `{ok, Term}`, existing `{ok, _}` and
`{error, _}` tuples pass through unchanged.

Returns `{error, {unsupported_native_call, Function}}` if the backend adapter
does not export `Function/Arity`.

```erlang
%% Equivalent to claude_agent_session:thread_realtime_start(Pid, #{mode => <<"voice">>})
{ok, _} = beam_agent_raw:call(Pid, thread_realtime_start, [#{mode => <<"voice">>}]).
```
""".
-spec call(pid(), atom(), [term()]) ->
    {ok, term()} | {error, term()}.
call(Session, Function, Args) -> beam_agent_raw_core:call(Session, Function, Args).

-doc """
Call a backend facade function directly, without prepending a session pid.

`BackendLike` may be a backend atom, a binary such as `<<"claude">>`, or any
value accepted by `beam_agent_backend:normalize/1`. The call is dispatched as
`AdapterModule:Function(Args...)`.

Use this for backend-scoped helpers that are not bound to an active session
(e.g. listing all native Claude sessions). For session-bound calls, prefer
`call/3`.

```erlang
{ok, Sessions} = beam_agent_raw:call_backend(claude, list_native_sessions, []).
```
""".
-spec call_backend(beam_agent_backend:backend() | binary() | atom(),
                   atom(), [term()]) ->
    {ok, term()} | {error, term()}.
call_backend(BackendLike, Function, Args) ->
    beam_agent_raw_core:call_backend(BackendLike, Function, Args).

%% Transport-level native session access (Claude-native listing/inspection).

-doc """
List all native Claude SDK sessions (no options).

This calls the Claude adapter directly and returns the raw session list from the
Claude SDK session store. Not available on other backends.
""".
-spec list_native_sessions() -> {ok, term()} | {error, term()}.
?BACKEND0(list_native_sessions, claude).

-doc """
List all native Claude SDK sessions with options.

`Opts` is a map passed directly to the Claude adapter's `list_native_sessions/1`
function. Consult the Claude adapter documentation for supported option keys.
""".
-spec list_native_sessions(map()) -> {ok, term()} | {error, term()}.
?BACKEND1(list_native_sessions, claude, Opts).

-doc """
Fetch all messages for a native Claude session by session ID binary.

Returns the raw message list from the Claude SDK session store.
""".
-spec get_native_session_messages(binary()) -> {ok, term()} | {error, term()}.
?BACKEND1(get_native_session_messages, claude, SessionId).

-doc """
Fetch messages for a native Claude session with options.

`Opts` is a map passed directly to the Claude adapter. Use this variant when
you need pagination or filtering supported by the underlying Claude adapter.
""".
-spec get_native_session_messages(binary(), map()) -> {ok, term()} | {error, term()}.
?BACKEND2(get_native_session_messages, claude, SessionId, Opts).

-doc """
Destroy the session associated with a live session pid.

Resolves the session ID from the running session process via `beam_agent:session_info/1`
and calls the backend's `session_destroy` function. Falls back to the pid
string if the session ID cannot be resolved.

Use `session_destroy/2` if the session process is no longer alive.
""".
-spec session_destroy(pid()) -> {ok, term()} | {error, term()}.
session_destroy(Session) ->
    call(Session, session_destroy, [session_identity(Session)]).

-doc """
Destroy a session by providing an explicit session ID.

Use this variant when you have a known `SessionId` binary but the session
process (`Session` pid) may or may not still be running. The pid is still
required to route to the correct backend adapter.
""".
-spec session_destroy(pid(), binary()) -> {ok, term()} | {error, term()}.
?RAW1(session_destroy, SessionId).

-doc """
Probe the transport-level health of the backend server for a session.

Delegates to the backend adapter's `server_health/1`. The return value format
is adapter-specific.
""".
-spec server_health(pid()) -> {ok, term()} | {error, term()}.
?RAW0(server_health).

-doc """
Fetch the raw status map from the backend server for a session.

Delegates to the backend adapter's `get_status/1`. The return value format
is adapter-specific.
""".
-spec get_status(pid()) -> {ok, term()} | {error, term()}.
?RAW0(get_status).

-doc """
Fetch the raw authentication status from the backend server for a session.

Delegates to the backend adapter's `get_auth_status/1`. The return value
format is adapter-specific.
""".
-spec get_auth_status(pid()) -> {ok, term()} | {error, term()}.
?RAW0(get_auth_status).

-doc """
Fetch the last known session ID reported by the backend for a session.

Delegates to the backend adapter's `get_last_session_id/1`. Useful for
correlating a BEAM session pid with the backend's own session identifier
without going through `beam_agent:session_info/1`.
""".
-spec get_last_session_id(pid()) -> {ok, binary()} | {error, term()}.
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
