-module(beam_agent_app_core).
-moduledoc """
Universal app/project management for the BEAM Agent SDK.

Provides ETS-backed app registration, info, and logging across all adapters.
Apps are scoped to a session — each session can register multiple apps,
query their status, and append log entries.

Uses ETS for fast in-process storage. App entries persist for the
lifetime of the BEAM node (or until explicitly deleted/cleared).

Usage:
```erlang
%% Register an app:
{ok, App} = beam_agent_app_core:register_app(SessionId, <<"my-app">>, #{
    name => <<"My App">>,
    modes => [<<"default">>, <<"debug">>]
}),

%% List apps for a session:
{ok, Apps} = beam_agent_app_core:apps_list(SessionId),

%% Append a log entry:
ok = beam_agent_app_core:app_log(SessionId, <<"Tool executed">>)
```
""".

-export([
    %% Table lifecycle
    ensure_table/0,
    clear/0,
    %% App operations
    register_app/3,
    apps_list/1,
    apps_list/2,
    app_info/1,
    app_init/1,
    app_log/2,
    app_modes/1,
    unregister_app/2
]).

-export_type([app_entry/0, apps_list_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% A single app entry stored in ETS.
-type app_entry() :: #{
    id := binary(),
    name := binary(),
    session := pid() | binary(),
    status := active | inactive,
    modes := [binary(), ...],
    log := [#{timestamp := integer(), body := term()}],
    metadata := #{registered_at => integer(), atom() => term()}
}.

%% Options for apps_list/2.
-type apps_list_opts() :: #{
    status => active | inactive
}.

-define(TABLE, beam_agent_apps).

-define(DEFAULT_MODES, [<<"default">>, <<"debug">>, <<"verbose">>]).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure the apps ETS table exists. Idempotent.".
-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            try
                _ = ets:new(?TABLE, [set, public, named_table,
                    {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.

-doc "Clear all app data.".
-spec clear() -> ok.
clear() ->
    ensure_table(),
    ets:delete_all_objects(?TABLE),
    ok.

%%--------------------------------------------------------------------
%% App Operations
%%--------------------------------------------------------------------

-doc """
Register or update an app entry for a session.

Creates a new entry if `AppId` is not yet registered under `Session`.
Updates the existing entry (merging opts) if it already exists.

Opts:
- `name`: human-readable label (binary)
- `modes`: list of mode binaries
- `metadata`: arbitrary map of extra fields
""".
-spec register_app(pid() | binary(), binary(), map()) ->
    {ok, app_entry()}.
register_app(Session, AppId, Opts)
  when (is_pid(Session) orelse is_binary(Session)),
       is_binary(AppId), is_map(Opts) ->
    ensure_table(),
    Key = {session_key(Session), AppId},
    Existing = case ets:lookup(?TABLE, Key) of
        [{_, E}] -> E;
        []       -> new_app_entry(Session, AppId)
    end,
    Name     = maps:get(name, Opts, maps:get(name, Existing, AppId)),
    Modes    = maps:get(modes, Opts, maps:get(modes, Existing, ?DEFAULT_MODES)),
    Meta     = maps:merge(maps:get(metadata, Existing, #{}),
                          maps:get(metadata, Opts, #{})),
    Entry    = Existing#{
        name     => Name,
        modes    => Modes,
        metadata => Meta,
        status   => maps:get(status, Opts, maps:get(status, Existing, active))
    },
    ets:insert(?TABLE, {Key, Entry}),
    {ok, Entry}.

-doc "List all apps registered for `Session`. Equivalent to `apps_list(Session, #{})`.".
-spec apps_list(pid() | binary()) -> {ok, [app_entry()]}.
apps_list(Session) ->
    apps_list(Session, #{}).

-doc """
List all apps registered for `Session` with optional filters.

Opts:
- `status`: filter to only `active` or `inactive` entries
""".
-spec apps_list(pid() | binary(), apps_list_opts()) -> {ok, [app_entry()]}.
apps_list(Session, Opts)
  when (is_pid(Session) orelse is_binary(Session)), is_map(Opts) ->
    ensure_table(),
    SK = session_key(Session),
    All = ets:foldl(fun
        ({{S, _}, Entry}, Acc) when S =:= SK ->
            case matches_status(Entry, Opts) of
                true  -> [Entry | Acc];
                false -> Acc
            end;
        (_, Acc) ->
            Acc
    end, [], ?TABLE),
    {ok, All}.

-doc """
Get information about the current app for a session.

If exactly one app is registered, returns it.
If multiple apps are registered, returns the one registered most recently
(by comparing ETS traversal order; registration order is preserved via
the entry's metadata timestamp).
Returns `{error, no_app}` if no apps are registered.
""".
-spec app_info(pid() | binary()) -> {ok, app_entry()} | {error, no_app}.
app_info(Session) when is_pid(Session) orelse is_binary(Session) ->
    case apps_list(Session) of
        {ok, []} ->
            {error, no_app};
        {ok, [Single]} ->
            {ok, chronological_log(Single)};
        {ok, Many} ->
            Latest = lists:last(
                lists:sort(fun(A, B) ->
                    registered_at(A) =< registered_at(B)
                end, Many)
            ),
            {ok, chronological_log(Latest)}
    end.

-doc """
Initialize a default app for a session if none exists.

Creates an app entry with id `<<"default">>` and name derived from
the session key. If an app already exists, returns the current one
via `app_info/1`.
""".
-spec app_init(pid() | binary()) -> {ok, app_entry()}.
app_init(Session) when is_pid(Session) orelse is_binary(Session) ->
    case app_info(Session) of
        {ok, Entry} ->
            {ok, Entry};
        {error, no_app} ->
            DefaultName = default_app_name(Session),
            register_app(Session, <<"default">>, #{name => DefaultName})
    end.

-doc """
Append a log entry to the current app for a session.

`Body` can be any term. The entry is timestamped in milliseconds.
Returns `{error, no_app}` if no app is registered for the session.
""".
-spec app_log(pid() | binary(), term()) -> ok | {error, no_app}.
app_log(Session, Body) when is_pid(Session) orelse is_binary(Session) ->
    ensure_table(),
    SK = session_key(Session),
    case app_info(Session) of
        {error, no_app} ->
            {error, no_app};
        {ok, Entry} ->
            AppId = maps:get(id, Entry),
            Key   = {SK, AppId},
            LogEntry = #{
                timestamp => erlang:system_time(millisecond),
                body      => Body
            },
            Log0  = maps:get(log, Entry, []),
            Entry2 = Entry#{log => [LogEntry | Log0]},
            ets:insert(?TABLE, {Key, Entry2}),
            ok
    end.

-doc """
Return available modes for the current app.

Returns the modes stored on the current app entry, or the default
mode list if no app is registered.
""".
-spec app_modes(pid() | binary()) -> {ok, [binary()]}.
app_modes(Session) when is_pid(Session) orelse is_binary(Session) ->
    case app_info(Session) of
        {ok, Entry} ->
            {ok, maps:get(modes, Entry, ?DEFAULT_MODES)};
        {error, no_app} ->
            {ok, ?DEFAULT_MODES}
    end.

-doc "Remove an app entry for a session. No-op if the entry does not exist.".
-spec unregister_app(pid() | binary(), binary()) -> ok.
unregister_app(Session, AppId)
  when (is_pid(Session) orelse is_binary(Session)), is_binary(AppId) ->
    ensure_table(),
    Key = {session_key(Session), AppId},
    ets:delete(?TABLE, Key),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec session_key(pid() | binary()) -> pid() | binary().
session_key(Session) when is_pid(Session)    -> Session;
session_key(Session) when is_binary(Session) -> Session.

-spec new_app_entry(pid() | binary(), binary()) ->
    #{id := binary(), name := binary(), session := pid() | binary(),
      status := active, modes := [<<_:40, _:_*16>>, ...], log := [],
      metadata := #{registered_at := integer()}}.
new_app_entry(Session, AppId) ->
    #{
        id       => AppId,
        name     => AppId,
        session  => Session,
        status   => active,
        modes    => ?DEFAULT_MODES,
        log      => [],
        metadata => #{registered_at => erlang:system_time(millisecond)}
    }.

%% Log entries are stored in reverse chronological order (prepend for O(1)).
%% Reverse them before returning to callers so the public contract is
%% chronological (oldest first).
-spec chronological_log(app_entry()) -> app_entry().
chronological_log(#{log := Log} = Entry) ->
    Entry#{log => lists:reverse(Log)}.

-spec registered_at(app_entry()) -> integer().
registered_at(Entry) ->
    Meta = maps:get(metadata, Entry, #{}),
    maps:get(registered_at, Meta, 0).

-spec matches_status(app_entry(), apps_list_opts()) -> boolean().
matches_status(Entry, Opts) ->
    case maps:find(status, Opts) of
        {ok, Expected} ->
            maps:get(status, Entry, active) =:= Expected;
        error ->
            true
    end.

-spec default_app_name(pid() | binary()) -> <<_:32, _:_*8>>.
default_app_name(Session) when is_pid(Session) ->
    PidBin = list_to_binary(pid_to_list(Session)),
    <<"app-", PidBin/binary>>;
default_app_name(Session) when is_binary(Session) ->
    <<"app-", Session/binary>>.
