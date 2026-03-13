-module(beam_agent_account).
-moduledoc """
Public API for account management.

This module provides account lifecycle operations for agentic coder
sessions: login, logout, rate limit checks, and account information.

Every function uses native-first routing: it tries the backend's native
implementation via beam_agent_raw_core:call/3, and falls back to a
universal ETS-backed implementation in beam_agent_account_core if the
backend returns {error, {unsupported_native_call, _}}.

This module is a pure delegation layer — it holds no state, no
processes, and no side effects.

## Getting Started

```erlang
{ok, Session} = beam_agent:start_session(#{backend => claude}),
{ok, Info} = beam_agent_account:info(Session),
io:format("Account: ~p~n", [Info]).
```

## See Also

  - beam_agent_account_core: universal fallback implementations
  - beam_agent: lifecycle entry point
""".

-export([
    login/2,
    cancel/2,
    logout/1,
    rate_limits/1,
    info/1
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Initiate an account login flow.".
-spec login(pid(), map()) -> {ok, term()} | {error, term()}.
login(Session, Params) ->
    beam_agent_core:native_or(Session, account_login, [Params], fun() ->
        beam_agent_account_core:account_login(Session, Params)
    end).

-doc "Cancel an in-progress account login flow.".
-spec cancel(pid(), map()) -> {ok, term()} | {error, term()}.
cancel(Session, Params) ->
    beam_agent_core:native_or(Session, account_login_cancel, [Params], fun() ->
        beam_agent_account_core:account_login_cancel(Session, Params)
    end).

-doc "Log out of the current account.".
-spec logout(pid()) -> {ok, term()} | {error, term()}.
logout(Session) ->
    beam_agent_core:native_or(Session, account_logout, [], fun() ->
        beam_agent_account_core:account_logout(Session)
    end).

-doc "Get rate limit information for the current account.".
-spec rate_limits(pid()) -> {ok, term()} | {error, term()}.
rate_limits(Session) ->
    beam_agent_core:native_or(Session, account_rate_limits, [], fun() ->
        info(Session)
    end).

-doc "Return account and authentication information for the session.".
-spec info(pid()) -> {ok, map()} | {error, term()}.
info(Session) ->
    beam_agent_core:native_or(Session, account_info, [], fun() ->
        beam_agent_core:account_info(Session)
    end).
