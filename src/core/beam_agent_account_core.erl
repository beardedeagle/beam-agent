-module(beam_agent_account_core).
-moduledoc false.

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    clear_session/1,
    %% Account operations
    account_login/2,
    account_login_cancel/2,
    account_logout/1,
    %% Queries
    auth_status/1,
    rate_limits/1,
    account_info/1
]).

-export_type([auth_state/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Authentication state stored per session in ETS.
-type auth_state() :: #{
    session      := pid() | binary(),
    status       := logged_in | logged_out | login_pending | login_cancelled | unknown,
    source       => cli | api | env | manual | inferred | unavailable,
    provider_id  => binary(),
    login_params => map(),
    logged_in_at => integer(),
    logged_out_at => integer(),
    details      => map()
}.

%% ETS table name.
-define(TABLE, beam_agent_runtime).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the accounts ETS table exists. Idempotent -- safe to call multiple times.
The table is named and its access mode is resolved by `beam_agent_ets` based on
the global configuration.
""".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_runtime:app_ensure_tables().

-doc "Delete all account data from the ETS table.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:match_delete(?TABLE, {{account, '_'}, '_'}),
    ok.

-doc "Delete auth state for a single session. Safe to call when no entry exists.".
-spec clear_session(pid() | binary()) -> ok.
clear_session(Session) ->
    ensure_tables(),
    Key = beam_agent_ets:session_key(Session),
    beam_agent_ets:delete(?TABLE, {account, Key}),
    ok.

%%--------------------------------------------------------------------
%% Account Operations
%%--------------------------------------------------------------------

-doc """
Initiate a login flow for a session.

Records login parameters and provider id (extracted from `Params` if present).
Attempts real CLI authentication via `beam_agent_auth_core` when the
session's backend can be resolved.  Falls back to recording `login_pending`
when the backend is unknown — callers should check `auth_status/1` after
the transport connects.

Returns `{ok, #{status := logged_in | login_pending, ...}}`.
""".
-spec account_login(pid() | binary(), map()) ->
    {ok, #{status := logged_in | login_pending, provider_id => binary()}} |
    {error, login_failed | timeout |
            {login_failed, binary()} |
            {opencode_unreachable, term()} |
            {port_error, term()} |
            {api_key_required, opencode}}.
account_login(Session, Params) when is_map(Params) ->
    ensure_tables(),
    ProviderId = maps:get(provider_id, Params, undefined),
    %% Strip secret fields before persisting in ETS — api_key, tokens,
    %% and credentials must not linger in process-accessible storage.
    %% Uses beam_agent_redaction:is_sensitive/1 as the canonical sensitive-key
    %% check so new sensitive keys are automatically excluded.
    SafeParams = maps:filter(
        fun(K, _V) -> not beam_agent_redaction:is_sensitive(K) end, Params),
    State0 = #{
        session      => Session,
        status       => login_pending,
        login_params => SafeParams
    },
    State1 = case ProviderId of
        undefined -> State0;
        Id when is_binary(Id) -> State0#{provider_id => Id}
    end,
    put_auth_state(Session, State1),
    %% Attempt real CLI auth when the backend is resolvable.
    case resolve_session_backend(Session) of
        {ok, Backend} ->
            AuthOpts = login_opts_from_params(Params),
            case beam_agent_auth_core:login(Backend, AuthOpts) of
                {ok, #{outcome := authenticated}} ->
                    State2 = State1#{status => logged_in,
                                     source => cli,
                                     logged_in_at => erlang:system_time(millisecond)},
                    put_auth_state(Session, State2),
                    {ok, maybe_add_provider(#{status => logged_in}, ProviderId)};
                {ok, #{outcome := pending}} ->
                    %% Device/OAuth flow started but not completed
                    {ok, maybe_add_provider(#{status => login_pending}, ProviderId)};
                {ok, #{outcome := failed, message := Msg}} ->
                    put_auth_state(Session, State1#{status => unknown}),
                    {error, {login_failed, Msg}};
                {ok, #{outcome := failed}} ->
                    put_auth_state(Session, State1#{status => unknown}),
                    {error, login_failed};
                {error, {not_supported, _, _, _}} ->
                    %% Backend has no CLI login (e.g. gemini) — stay pending
                    {ok, maybe_add_provider(#{status => login_pending}, ProviderId)};
                {error, {cli_not_found, _}} ->
                    %% CLI not installed — stay pending, transport is credential
                    {ok, maybe_add_provider(#{status => login_pending}, ProviderId)};
                {error, Reason} ->
                    put_auth_state(Session, State1#{status => unknown}),
                    {error, Reason}
            end;
        {error, _} ->
            %% Cannot resolve backend — record pending, transport is credential
            {ok, maybe_add_provider(#{status => login_pending}, ProviderId)}
    end.

-doc """
Cancel a pending login for a session.

Sets status to `login_cancelled`. Preserves any previously stored
provider_id and login_params.
""".
-spec account_login_cancel(pid() | binary(), map()) ->
    {ok, #{status := login_cancelled}}.
account_login_cancel(Session, Params) when is_map(Params) ->
    ensure_tables(),
    Existing = get_auth_state(Session),
    Updated = Existing#{
        session => Session,
        status  => login_cancelled
    },
    put_auth_state(Session, Updated),
    {ok, #{status => login_cancelled}}.

-doc """
Log out a session.

Attempts real CLI logout via `beam_agent_auth_core` when the session's
backend can be resolved.  Always records `logged_out` in ETS regardless
of whether the CLI call succeeds — the session state is authoritative.
""".
-spec account_logout(pid() | binary()) ->
    {ok, #{status := logged_out}}.
account_logout(Session) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    %% Retrieve stored login params to pass relevant opts through to logout
    %% (e.g. base_url for OpenCode, cli_path for custom binary locations).
    Existing0 = get_auth_state(Session),
    LogoutOpts = login_opts_from_params(maps:get(login_params, Existing0, #{})),
    %% Best-effort real CLI logout — track whether CLI actually ran
    %% so `source` accurately reflects the logout method.
    Source =
        case resolve_session_backend(Session) of
            {ok, Backend} ->
                case beam_agent_auth_core:logout(Backend, LogoutOpts) of
                    ok ->
                        cli;
                    {error, {cli_not_found, _}} ->
                        unavailable;
                    {error, Reason} ->
                        logger:warning("CLI logout failed for ~p: ~tp",
                                       [Backend, Reason]),
                        cli
                end;
            {error, _} ->
                unavailable
        end,
    Updated = (maps:without([logged_in_at], Existing0))#{
        session       => Session,
        status        => logged_out,
        source        => Source,
        logged_out_at => Now
    },
    put_auth_state(Session, Updated),
    {ok, #{status => logged_out}}.

%%--------------------------------------------------------------------
%% Queries
%%--------------------------------------------------------------------

-doc """
Return the current authentication status for a session.

When the session has a cached auth state in ETS, returns that directly.
Otherwise, attempts a real CLI auth check via `beam_agent_auth_core:status/2`
and caches the result.  Returns `#{status => unknown}` when neither the
cache nor the CLI check can determine the state.
""".
-spec auth_status(pid() | binary()) -> {ok, auth_state()}.
auth_status(Session) ->
    ensure_tables(),
    Key = beam_agent_ets:session_key(Session),
    case ets:lookup(?TABLE, {account, Key}) of
        [{_, #{status := Status} = State}]
          when Status =/= login_pending, Status =/= unknown ->
            {ok, State};
        [{_, State}] ->
            %% Transient states (login_pending, unknown) — re-probe the
            %% backend only when resolvable, otherwise keep cached state.
            case resolve_session_backend(Session) of
                {ok, _} -> probe_and_cache_auth(Session);
                {error, _} -> {ok, State}
            end;
        [] ->
            probe_and_cache_auth(Session)
    end.

-doc """
Return rate limit information for a session.

The universal fallback has no access to real rate limit data from the
backend, so returns an empty limits list with `source => universal`.
""".
-spec rate_limits(pid() | binary()) ->
    {ok, #{limits := [], source := universal}}.
rate_limits(_Session) ->
    {ok, #{limits => [], source => universal}}.

-doc """
Return combined account information for a session.

Merges the auth state and rate limit info into a single map.
""".
-spec account_info(pid() | binary()) ->
    {ok, #{auth := auth_state(), rate_limits := #{limits := [], source := universal}}}.
account_info(Session) ->
    {ok, AuthState} = auth_status(Session),
    {ok, RateLimits} = rate_limits(Session),
    {ok, #{auth => AuthState, rate_limits => RateLimits}}.

%%--------------------------------------------------------------------
%% Internal Helpers
%%--------------------------------------------------------------------

%% Look up auth state from ETS. Returns a default state when no entry
%% is present — used only by internal functions that don't need CLI probing.
-spec get_auth_state(pid() | binary()) -> auth_state().
get_auth_state(Session) ->
    Key = beam_agent_ets:session_key(Session),
    case ets:lookup(?TABLE, {account, Key}) of
        [{_, State}] ->
            State;
        [] ->
            #{session => Session, status => unknown, source => unavailable}
    end.

%% Insert or replace the auth state for a session.
-spec put_auth_state(pid() | binary(), auth_state()) -> ok.
put_auth_state(Session, State) ->
    Key = beam_agent_ets:session_key(Session),
    beam_agent_ets:insert(?TABLE, {{account, Key}, State}),
    ok.

%% Probe real CLI auth and cache the result in ETS.
-spec probe_and_cache_auth(pid() | binary()) ->
    {ok, #{session := pid() | binary(),
           status  := logged_in | logged_out | unknown,
           source  := cli | api | env | manual | unavailable,
           details => #{authenticated := boolean(),
                        backend => beam_agent_backend:backend(),
                        method => api | cli | env | manual}}}.
probe_and_cache_auth(Session) ->
    case resolve_session_backend(Session) of
        {ok, Backend} ->
            case beam_agent_auth_core:status(Backend, #{}) of
                {ok, #{authenticated := true} = Details} ->
                    SafeDetails = beam_agent_auth_core:sanitize_for_agent(Details),
                    Source = auth_source_from_details(Details),
                    State = #{session => Session, status => logged_in,
                              source => Source, details => SafeDetails},
                    put_auth_state(Session, State),
                    {ok, State};
                {ok, #{authenticated := false} = Details} ->
                    SafeDetails = beam_agent_auth_core:sanitize_for_agent(Details),
                    Source = auth_source_from_details(Details),
                    State = #{session => Session, status => logged_out,
                              source => Source, details => SafeDetails},
                    put_auth_state(Session, State),
                    {ok, State};
                {error, {cli_not_found, _}} ->
                    %% CLI not installed — cannot determine, don't cache
                    {ok, #{session => Session, status => unknown,
                           source => unavailable}};
                {error, _} ->
                    {ok, #{session => Session, status => unknown,
                           source => unavailable}}
            end;
        {error, _} ->
            {ok, #{session => Session, status => unknown,
                   source => unavailable}}
    end.

%% Resolve the backend for a session, if possible.
-spec resolve_session_backend(pid() | binary()) ->
    {ok, beam_agent_backend:backend()} | {error, term()}.
resolve_session_backend(Session) ->
    beam_agent_backend:session_backend(Session).

%% Extract auth options from login Params (api_key, env, etc).
-spec login_opts_from_params(map()) -> beam_agent_auth_core:auth_opts().
login_opts_from_params(Params) ->
    lists:foldl(fun({ParamKey, OptKey}, Acc) ->
        case maps:get(ParamKey, Params, undefined) of
            undefined -> Acc;
            Value     -> Acc#{OptKey => Value}
        end
    end, #{}, [
        {api_key, api_key},
        {cli_path, cli_path},
        {timeout, timeout},
        {base_url, base_url}
    ]).

%% Map the auth method from beam_agent_auth_core:status/2 to an account source.
-spec auth_source_from_details(#{authenticated := boolean(),
                                  backend := beam_agent_backend:backend(),
                                  method := api | cli | env | manual,
                                  _ => _}) ->
    api | cli | env | manual.
auth_source_from_details(#{method := api})    -> api;
auth_source_from_details(#{method := env})    -> env;
auth_source_from_details(#{method := manual}) -> manual;
auth_source_from_details(#{method := cli})    -> cli.

%% Add provider_id to a result map when present.
-spec maybe_add_provider(#{status := logged_in | login_pending}, binary() | undefined) ->
    #{status := logged_in | login_pending, provider_id => binary()}.
maybe_add_provider(Result, undefined) -> Result;
maybe_add_provider(Result, Id) when is_binary(Id) -> Result#{provider_id => Id}.
