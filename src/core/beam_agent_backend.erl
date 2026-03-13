-module(beam_agent_backend).
-moduledoc """
Backend registry and routing helpers for the canonical `beam_agent_core` SDK.

This module keeps the backend-selection logic centralized:

  - normalize backend identifiers from atoms/binaries/strings
  - map a backend to its adapter facade module
  - infer a backend from a live session pid
  - cache pid-to-backend lookups in ETS
  - provide backend-specific terminal-message semantics

It intentionally uses ETS, not a dedicated process, because the state is
small, contention is low, and lookups are on the hot path for query routing.
""".

-export([
    ensure_table/0,
    clear/0,
    available_backends/0,
    normalize/1,
    adapter_module/1,
    session_backend/1,
    register_session/2,
    unregister_session/1,
    is_terminal/2
]).

-export_type([backend/0, adapter_module/0, backend_lookup_error/0, capability_path/0]).

-type backend() :: claude | codex | gemini | opencode | copilot.
-type adapter_module() ::
    claude_agent_sdk |
    codex_app_server |
    gemini_cli_client |
    opencode_client |
    copilot_client.
-type capability_path() :: native | universal | both | missing.
-type backend_error() :: {unknown_backend, term()}.
-type backend_lookup_error() ::
    backend_not_present |
    backend_error() |
    {invalid_session_info, term()} |
    {session_backend_lookup_failed, term()}.

-define(SESSIONS_TABLE, beam_agent_backend_sessions).

-doc "Ensure the pid-to-backend ETS table exists.".
-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?SESSIONS_TABLE) of
        undefined ->
            try
                _ = ets:new(?SESSIONS_TABLE, [set, public, named_table,
                    {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.

-doc "Clear the backend registry.".
-spec clear() -> ok.
clear() ->
    ensure_table(),
    ets:delete_all_objects(?SESSIONS_TABLE),
    ok.

-doc "Return the canonical backend atoms supported by the unified SDK.".
-spec available_backends() -> [backend(), ...].
available_backends() ->
    [claude, codex, gemini, opencode, copilot].

-doc """
Normalize a backend identifier into a canonical backend atom.

Accepted forms include atoms, binaries, and strings such as:
`claude`, `<<"claude_agent_sdk">>`, `"codex_app_server"`, etc.
""".
-spec normalize(term()) -> {ok, backend()} | {error, backend_error()}.
normalize(claude) -> {ok, claude};
normalize(codex) -> {ok, codex};
normalize(gemini) -> {ok, gemini};
normalize(opencode) -> {ok, opencode};
normalize(copilot) -> {ok, copilot};
normalize(claude_agent_sdk) -> {ok, claude};
normalize(codex_app_server) -> {ok, codex};
normalize(gemini_cli_client) -> {ok, gemini};
normalize(opencode_client) -> {ok, opencode};
normalize(copilot_client) -> {ok, copilot};
normalize(Value) when is_list(Value) ->
    normalize(unicode:characters_to_binary(Value));
normalize(<<"claude">>) -> {ok, claude};
normalize(<<"claude_code">>) -> {ok, claude};
normalize(<<"claude_agent_sdk">>) -> {ok, claude};
normalize(<<"codex">>) -> {ok, codex};
normalize(<<"codex_cli">>) -> {ok, codex};
normalize(<<"codex_app_server">>) -> {ok, codex};
normalize(<<"gemini">>) -> {ok, gemini};
normalize(<<"gemini_cli">>) -> {ok, gemini};
normalize(<<"gemini_cli_client">>) -> {ok, gemini};
normalize(<<"opencode">>) -> {ok, opencode};
normalize(<<"opencode_client">>) -> {ok, opencode};
normalize(<<"copilot">>) -> {ok, copilot};
normalize(<<"copilot_client">>) -> {ok, copilot};
normalize(Value) ->
    {error, {unknown_backend, Value}}.

-doc "Map a canonical backend to its adapter facade module.".
-spec adapter_module(backend()) -> adapter_module().
adapter_module(claude) -> claude_agent_sdk;
adapter_module(codex) -> codex_app_server;
adapter_module(gemini) -> gemini_cli_client;
adapter_module(opencode) -> opencode_client;
adapter_module(copilot) -> copilot_client.

-doc "Cache a live session pid with its backend.".
-spec register_session(pid(), backend() | binary() | atom()) ->
    {ok, backend()} | {error, term()}.
register_session(Session, BackendLike) when is_pid(Session) ->
    ensure_table(),
    case normalize(BackendLike) of
        {ok, Backend} ->
            ets:insert(?SESSIONS_TABLE, {Session, Backend}),
            {ok, Backend};
        {error, _} = Error ->
            Error
    end.

-doc "Remove a session pid from the backend cache.".
-spec unregister_session(pid()) -> ok.
unregister_session(Session) when is_pid(Session) ->
    ensure_table(),
    ets:delete(?SESSIONS_TABLE, Session),
    ok.

-doc """
Resolve the backend for a live session pid.

Resolution order:

  1. cached pid-to-backend entry
  2. `session_info` call on the session process
""".
-spec session_backend(pid()) -> {ok, backend()} | {error, backend_lookup_error()}.
session_backend(Session) when is_pid(Session) ->
    ensure_table(),
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Backend}] ->
            {ok, Backend};
        [] ->
            infer_session_backend(Session)
    end.

-doc """
Return whether a message should terminate collection for a backend.

Copilot emits non-terminal `error` messages, so only `error` messages with
`is_error := true` halt that backend's collection loop.
""".
-spec is_terminal(backend(), map()) -> boolean().
is_terminal(copilot, #{type := result}) ->
    true;
is_terminal(copilot, #{type := error, is_error := true}) ->
    true;
is_terminal(copilot, #{type := error}) ->
    false;
is_terminal(_, #{type := result}) ->
    true;
is_terminal(_, #{type := error}) ->
    true;
is_terminal(_, _) ->
    false.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec infer_session_backend(pid()) -> {ok, backend()} | {error, backend_lookup_error()}.
infer_session_backend(Session) ->
    try gen_statem:call(Session, session_info, 5000) of
        {ok, Info} when is_map(Info) ->
            case backend_from_info(Info) of
                {ok, Backend} ->
                    _ = register_session(Session, Backend),
                    {ok, Backend};
                {error, _} = Error ->
                    Error
            end;
        Other ->
            {error, {invalid_session_info, Other}}
    catch
        exit:Reason ->
            {error, {session_backend_lookup_failed, Reason}}
    end.

-spec backend_from_info(map()) ->
    {ok, backend()} | {error, backend_not_present | backend_error()}.
backend_from_info(Info) ->
    case maps:get(adapter, Info, maps:get(backend, Info, undefined)) of
        undefined ->
            {error, backend_not_present};
        Adapter ->
            normalize(Adapter)
    end.
