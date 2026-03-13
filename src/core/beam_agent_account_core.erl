-module(beam_agent_account_core).
-moduledoc false.

-export([
    %% Table lifecycle
    ensure_table/0,
    clear/0,
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
    status       := logged_in | logged_out | login_pending | login_cancelled,
    provider_id  => binary(),
    login_params => map(),
    logged_in_at => integer(),
    logged_out_at => integer()
}.

%% ETS table name.
-define(TABLE, beam_agent_accounts).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure the accounts ETS table exists. Idempotent -- safe to call multiple times.
The table is named and its access mode is resolved by `beam_agent_ets` based on
the global configuration.
""".
-spec ensure_table() -> ok.
ensure_table() ->
    beam_agent_ets:ensure_table(?TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Delete all account data from the ETS table.".
-spec clear() -> ok.
clear() ->
    ensure_table(),
    beam_agent_ets:delete_all_objects(?TABLE),
    ok.

%%--------------------------------------------------------------------
%% Account Operations
%%--------------------------------------------------------------------

-doc """
Initiate a login flow for a session.

Records login parameters and provider id (extracted from `Params` if present).
Since this is a universal fallback with no real OAuth flow, the session
transitions directly to `logged_in` to indicate it is authenticated via
the backend's own transport mechanism.

Returns `{ok, #{status => logged_in, provider_id => ProviderId}}`.
""".
-spec account_login(pid() | binary(), map()) ->
    {ok, #{status := logged_in, provider_id => binary()}}.
account_login(Session, Params) when is_map(Params) ->
    ensure_table(),
    Now = erlang:system_time(millisecond),
    ProviderId = maps:get(provider_id, Params, undefined),
    State0 = #{
        session      => Session,
        status       => login_pending,
        login_params => Params,
        logged_in_at => Now
    },
    State1 = case ProviderId of
        undefined -> State0;
        Id when is_binary(Id) -> State0#{provider_id => Id}
    end,
    %% Transition immediately to logged_in: universal fallback has no
    %% real OAuth handshake; the transport connection is the credential.
    State2 = State1#{status => logged_in},
    put_auth_state(Session, State2),
    Result = #{status => logged_in},
    Result2 = case ProviderId of
        undefined -> Result;
        Id2 when is_binary(Id2) -> Result#{provider_id => Id2}
    end,
    {ok, Result2}.

-doc """
Cancel a pending login for a session.

Sets status to `login_cancelled`. Preserves any previously stored
provider_id and login_params.
""".
-spec account_login_cancel(pid() | binary(), map()) ->
    {ok, #{status := login_cancelled}}.
account_login_cancel(Session, Params) when is_map(Params) ->
    ensure_table(),
    Existing = get_auth_state(Session),
    Updated = Existing#{
        session => Session,
        status  => login_cancelled
    },
    put_auth_state(Session, Updated),
    {ok, #{status => login_cancelled}}.

-doc """
Log out a session.

Sets status to `logged_out` with a `logged_out_at` timestamp.
Clears `logged_in_at` from the stored state.
""".
-spec account_logout(pid() | binary()) ->
    {ok, #{status := logged_out}}.
account_logout(Session) ->
    ensure_table(),
    Now = erlang:system_time(millisecond),
    Existing = get_auth_state(Session),
    Updated = (maps:without([logged_in_at], Existing))#{
        session       => Session,
        status        => logged_out,
        logged_out_at => Now
    },
    put_auth_state(Session, Updated),
    {ok, #{status => logged_out}}.

%%--------------------------------------------------------------------
%% Queries
%%--------------------------------------------------------------------

-doc """
Return the current authentication status for a session.

If no entry exists for the session, returns
`{ok, #{status => logged_in, source => inferred}}` — sessions are
authenticated by default because the underlying transport connection
itself serves as the credential.
""".
-spec auth_status(pid() | binary()) -> {ok, auth_state()}.
auth_status(Session) ->
    ensure_table(),
    {ok, get_auth_state(Session)}.

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

%% Return the ETS key for a session. Pid and binary are used as-is;
%% the ETS table is a set so both forms are valid keys.
-spec session_key(pid() | binary()) -> pid() | binary().
session_key(Session) when is_pid(Session) -> Session;
session_key(Session) when is_binary(Session) -> Session.

%% Look up auth state from ETS. Returns a default inferred state when
%% no entry is present.
-spec get_auth_state(pid() | binary()) -> auth_state().
get_auth_state(Session) ->
    Key = session_key(Session),
    case ets:lookup(?TABLE, Key) of
        [{_, State}] ->
            State;
        [] ->
            %% Default: sessions are authenticated by virtue of the
            %% transport being connected.
            #{session => Session, status => logged_in, source => inferred}
    end.

%% Insert or replace the auth state for a session.
-spec put_auth_state(pid() | binary(), auth_state()) -> ok.
put_auth_state(Session, State) ->
    Key = session_key(Session),
    beam_agent_ets:insert(?TABLE, {Key, State}),
    ok.
