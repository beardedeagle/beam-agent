-module(beam_agent_backend).
-moduledoc """
Backend registry and routing helpers for the canonical `beam_agent_core` SDK.

This module keeps the backend-selection logic centralized:

  - normalize backend identifiers from atoms/binaries/strings
  - map a backend to its adapter facade module
  - infer a backend from a live session pid
  - cache pid-to-backend lookups in ETS
  - provide backend-specific terminal-message semantics

All backend metadata is defined in the single `registry/0` function.
To add a new backend, add one entry there — `available_backends/0`,
`normalize/1`, and `adapter_module/1` all derive from the registry
automatically.

It intentionally uses ETS, not a dedicated process, because the state is
small, contention is low, and lookups are on the hot path for query routing.
""".

-export([
    ensure_tables/0,
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

%%====================================================================
%% Registry — single source of truth
%%====================================================================

-doc """
The canonical backend registry.

To register a new backend, add one entry here. `available_backends/0`,
`normalize/1`, and `adapter_module/1` all derive from this map.

Each entry maps a canonical backend atom to its adapter module and a
list of recognized aliases (atoms and binaries).
""".
registry() ->
    #{claude   => #{module  => claude_agent_sdk,
                    handler => claude_session_handler,
                    aliases => [claude_agent_sdk,
                                <<"claude">>, <<"claude_code">>,
                                <<"claude_agent_sdk">>]},
      codex    => #{module  => codex_app_server,
                    handler => codex_session_handler,
                    aliases => [codex_app_server,
                                <<"codex">>, <<"codex_cli">>,
                                <<"codex_app_server">>]},
      gemini   => #{module  => gemini_cli_client,
                    handler => gemini_session_handler,
                    aliases => [gemini_cli_client,
                                <<"gemini">>, <<"gemini_cli">>,
                                <<"gemini_cli_client">>]},
      opencode => #{module  => opencode_client,
                    handler => opencode_session_handler,
                    aliases => [opencode_client,
                                <<"opencode">>,
                                <<"opencode_client">>]},
      copilot  => #{module  => copilot_client,
                    handler => copilot_session_handler,
                    aliases => [copilot_client,
                                <<"copilot">>,
                                <<"copilot_client">>]}}.

%%====================================================================
%% Public API
%%====================================================================

-doc "Ensure the pid-to-backend ETS table exists.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?SESSIONS_TABLE,
        [set, named_table, {read_concurrency, true}]).

-doc "Clear the backend registry.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?SESSIONS_TABLE),
    ok.

-doc "Return the canonical backend atoms supported by the unified SDK.".
-spec available_backends() -> [backend(), ...].
available_backends() ->
    lists:sort(maps:keys(registry())).

-doc """
Normalize a backend identifier into a canonical backend atom.

Accepted forms include atoms, binaries, and strings such as:
`claude`, `<<"claude_agent_sdk">>`, `"codex_app_server"`, etc.
The recognized aliases are defined in `registry/0`.
""".
-spec normalize(term()) -> {ok, backend()} | {error, backend_error()}.
normalize(Value) when is_list(Value) ->
    normalize(unicode:characters_to_binary(Value));
normalize(Value) when is_atom(Value); is_binary(Value) ->
    Reg = registry(),
    case maps:is_key(Value, Reg) of
        true  -> {ok, Value};
        false -> lookup_alias(Value, Reg)
    end;
normalize(Value) ->
    {error, {unknown_backend, Value}}.

-doc "Map a canonical backend to its adapter facade module.".
-spec adapter_module(backend()) -> adapter_module().
adapter_module(Backend) ->
    case maps:find(Backend, registry()) of
        {ok, #{module := Mod}} -> Mod;
        error -> error({unknown_backend, Backend})
    end.

-doc "Cache a live session pid with its backend.".
-spec register_session(pid(), backend() | binary() | atom()) ->
    {ok, backend()} | {error, term()}.
register_session(Session, BackendLike) when is_pid(Session) ->
    ensure_tables(),
    case normalize(BackendLike) of
        {ok, Backend} ->
            beam_agent_ets:insert(?SESSIONS_TABLE, {Session, Backend}),
            {ok, Backend};
        {error, _} = Error ->
            Error
    end.

-doc "Remove a session pid from the backend cache.".
-spec unregister_session(pid()) -> ok.
unregister_session(Session) when is_pid(Session) ->
    ensure_tables(),
    beam_agent_ets:delete(?SESSIONS_TABLE, Session),
    ok.

-doc """
Resolve the backend for a live session pid or persisted session id.

Resolution order:

  1. cached pid-to-backend entry
  2. `session_info` call on the session process
  3. persisted session metadata lookup for a session id binary
""".
-spec session_backend(pid() | binary()) -> {ok, backend()} | {error, backend_lookup_error()}.
session_backend(Session) when is_pid(Session) ->
    ensure_tables(),
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Backend}] ->
            {ok, Backend};
        [] ->
            infer_session_backend(Session)
    end;
session_backend(SessionId) when is_binary(SessionId), byte_size(SessionId) > 0 ->
    infer_persisted_session_backend(SessionId).

-doc """
Return whether a message should terminate collection for a backend.

Dispatches to the backend's session handler module via the registry,
keeping `beam_agent_backend` closed to modification when new backends
are added (OCP). Each handler implements the required `is_terminal/1`
callback with its own wire-protocol semantics.

Crashes with `{unknown_backend, Backend}` if the backend atom is not
in the registry — this is a programmer error, not a runtime condition.
""".
-spec is_terminal(backend(), map()) -> boolean().
is_terminal(Backend, Message) ->
    Module = handler_module(Backend),
    Module:is_terminal(Message).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec handler_module(backend()) -> module().
handler_module(Backend) ->
    case maps:find(Backend, registry()) of
        {ok, #{handler := Mod}} -> Mod;
        error -> error({unknown_backend, Backend})
    end.

-spec lookup_alias(atom() | binary(), #{backend() => map()}) ->
    {ok, backend()} | {error, backend_error()}.
lookup_alias(Alias, Registry) ->
    Result = maps:fold(fun
        (Backend, #{aliases := Aliases}, error) ->
            case lists:member(Alias, Aliases) of
                true  -> {ok, Backend};
                false -> error
            end;
        (_Backend, _Entry, Found) ->
            Found
    end, error, Registry),
    case Result of
        {ok, _} = Ok -> Ok;
        error -> {error, {unknown_backend, Alias}}
    end.

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

-spec infer_persisted_session_backend(binary()) ->
    {ok, backend()} | {error, backend_not_present | backend_error()}.
infer_persisted_session_backend(SessionId) ->
    case beam_agent_session_store_core:get_session(SessionId) of
        {ok, Info} when is_map(Info) ->
            backend_from_info(Info);
        {error, not_found} ->
            {error, backend_not_present}
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
