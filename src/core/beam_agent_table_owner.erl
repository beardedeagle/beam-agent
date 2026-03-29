-module(beam_agent_table_owner).
-moduledoc """
ETS table ownership and lifecycle management for the BEAM Agent SDK.

Provides two operational modes for ETS table access control:

  - `public` (default) — All tables use public access. Any process can
    read and write.

  - `hardened` — All tables are protected and writes are proxied through
    one or more linked shard owner processes. Reads remain zero-cost from
    any process.

## Write Sharding

In hardened mode, writes can be distributed across N shard processes
to reduce mailbox contention under high-concurrency workloads. Each
table is assigned to exactly one shard via consistent hashing
(`erlang:phash2(Table, N)`). Writes for a given table always route
to the same shard, preserving per-table write ordering.

Configure sharding via the `shard_count` option:

```erlang
ok = beam_agent_table_owner:init(#{
    table_access => hardened,
    shard_count  => 4
}).
```

When `shard_count` is 1 (the default), behavior is identical to a
single owner process. Increasing the count distributes write load
across independent mailboxes.

## Usage

```erlang
%% In the consumer's gen_server init/1:
init(Args) ->
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% ... rest of init
```

## Security Properties

In hardened mode:
  - Only shard owner processes can write to protected tables via `ets:insert`
  - All other processes must route writes through `beam_agent_ets` wrappers
  - Reads (`ets:lookup`, `ets:foldl`, `ets:select`, etc.) work from any
    process with zero overhead — no message passing for reads
  - Each shard process traps exits and sets the consumer as ETS heir
    via `{heir, Consumer, TableName}` on each created table, so tables
    survive shard crashes and transfer to the consumer for graceful
    recovery.

## Process Monitoring

In hardened mode, the primary shard (shard 0) can monitor arbitrary pids
on behalf of SDK modules via `monitor_for_cleanup/2`. When a monitored
process dies, the primary shard executes the registered
`{Module, Function, Args}` callback to perform ETS cleanup.

In public mode (no owner process), `monitor_for_cleanup/2` returns
`ignored`.

## Audit Classification

Five tables are classified as single-writer (primarily written by
consumer-facing APIs or the router):

  - `beam_agent_runtime` — unified runtime table, primarily consumer-facing APIs
  - `beam_agent_backend_sessions` — primarily `beam_agent_routing`

Note: the session engine may also write to these tables during lifecycle
events (e.g., termination cleanup). In `public` mode all tables use public
access so any process can write. In `hardened` mode all tables are protected
and writes are proxied through the shard owner processes.
""".

-export([
    init/0,
    init/1,
    access_mode/0,
    owner_pid/0,
    shard_count/0,
    shard_pids/0,
    shard_for_table/1,
    is_owner_process/0,
    is_always_protected/1,
    resolve_access/1,
    write_proxy_sync/3,
    monitor_for_cleanup/2,
    initialized/0
]).

-export_type([access_mode/0, init_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type access_mode() :: public | hardened.

-type init_opts() :: #{
    table_access => access_mode(),
    shard_count  => pos_integer()
}.

%%--------------------------------------------------------------------
%% Persistent term keys
%%--------------------------------------------------------------------

-define(PT_MODE, beam_agent_table_access_mode).
-define(PT_OWNER, beam_agent_table_owner_pid).
-define(PT_SHARDS, beam_agent_table_owner_shards).
-define(PT_INIT, beam_agent_tables_initialized).

%% Write proxy timeout — generous default for backpressure safety.
-define(WRITE_TIMEOUT, 5000).

%% Init ready timeout per shard.
-define(INIT_TIMEOUT, 5000).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-doc """
Initialize ETS tables with default settings (public access).
Equivalent to `init(#{})`.
""".
-spec init() -> ok.
init() ->
    init(#{}).

-doc """
Initialize ETS tables with the given options.

Options:
  - `table_access` — `public` (default) or `hardened`
  - `shard_count`  — number of shard owner processes in hardened mode
    (default 1). Ignored in public mode.

In `public` mode, tables are created in the calling process with public
access. In `hardened` mode, `shard_count` linked helper processes are
spawned to own the protected tables and proxy writes. Each table is
assigned to a shard via consistent hashing.

This function is idempotent. Calling it again after initialization is
a no-op that returns `ok`.

Should be called early in the consumer's `init/1` callback, before any
SDK functions that touch ETS.
""".
-spec init(init_opts()) -> ok.
init(Opts) ->
    case initialized() of
        true ->
            ok;
        false ->
            Mode = maps:get(table_access, Opts, public),
            ShardCount = maps:get(shard_count, Opts, 1),
            do_init(Mode, ShardCount)
    end.

-doc "Return the current access mode. Defaults to `public` if not initialized.".
-spec access_mode() -> access_mode().
access_mode() ->
    persistent_term:get(?PT_MODE, public).

-doc """
Return the primary shard owner pid, or `undefined` if in public mode.

In sharded configurations this returns the shard 0 (primary) pid.
Use `shard_for_table/1` for write routing and `shard_pids/0` for
the full shard tuple.
""".
-spec owner_pid() -> pid() | undefined.
owner_pid() ->
    persistent_term:get(?PT_OWNER, undefined).

-doc "Return the number of shard owner processes. Returns 0 in public mode.".
-spec shard_count() -> non_neg_integer().
shard_count() ->
    case shard_pids() of
        undefined -> 0;
        Shards    -> tuple_size(Shards)
    end.

-doc """
Return the tuple of all shard owner pids, or `undefined` in public mode.
""".
-spec shard_pids() -> tuple() | undefined.
shard_pids() ->
    persistent_term:get(?PT_SHARDS, undefined).

-doc """
Return the shard owner pid responsible for a given table.

Uses consistent hashing (`erlang:phash2(Table, N)`) to assign each
table to exactly one shard. Returns `undefined` in public mode.
""".
-spec shard_for_table(atom()) -> pid() | undefined.
shard_for_table(Table) ->
    case shard_pids() of
        undefined -> undefined;
        Shards ->
            N = tuple_size(Shards),
            Idx = erlang:phash2(Table, N) + 1,
            element(Idx, Shards)
    end.

-doc """
Return whether the calling process is any shard owner.

Used by `beam_agent_ets` to short-circuit the write proxy when the
caller is already a shard owner (direct write is safe).
""".
-spec is_owner_process() -> boolean().
is_owner_process() ->
    case shard_pids() of
        undefined -> false;
        Shards    -> is_member_of_tuple(self(), Shards)
    end.

-doc "Return whether `init/1` has been called.".
-spec initialized() -> boolean().
initialized() ->
    persistent_term:get(?PT_INIT, false).

-doc """
Return whether a table was identified as primarily single-writer by the
security audit.

These five tables are primarily written by consumer-facing APIs, though
the session engine may also write during lifecycle events (e.g.,
termination cleanup). This classification is informational — it does not
affect the access mode, which is determined solely by `resolve_access/1`.
""".
-spec is_always_protected(atom()) -> boolean().
is_always_protected(beam_agent_runtime)            -> true;
is_always_protected(beam_agent_backend_sessions)   -> true;
is_always_protected(_)                             -> false.

-doc """
Resolve the effective access mode for a given table.

In `public` mode, all tables are public — including the five
always-protected tables. Without an owner process there is no write
proxy, so every process must be able to write directly.

In `hardened` mode, all tables are protected. Writes are serialized
through the shard owner process regardless of which table is being
written to.
""".
-spec resolve_access(atom()) -> public | protected.
resolve_access(_TableName) ->
    case access_mode() of
        public   -> public;
        hardened -> protected
    end.

-doc """
Send a synchronous write command to the shard owner for `Table` and
wait for the result.

This is the sole write path in hardened mode. Each table is routed to
its assigned shard via consistent hashing, distributing write load
across shard mailboxes. The caller blocks until the shard acknowledges
the write.

In public mode (or if no shards are running), falls back to a direct
ETS call.
""".
-spec write_proxy_sync(atom(), atom(), term()) -> term().
write_proxy_sync(Op, Table, Arg) ->
    case shard_for_table(Table) of
        undefined ->
            direct_write(Op, Table, Arg);
        Pid ->
            Ref = make_ref(),
            Pid ! {write_sync, Op, Table, Arg, self(), Ref},
            receive
                {write_ack, Ref, Result} ->
                    Result
            after ?WRITE_TIMEOUT ->
                error({beam_agent_table_write_timeout, Op, Table})
            end
    end.

-doc """
Ask the primary shard to monitor `Pid` and execute `MFA` when it dies.

In hardened mode, sends an asynchronous message to the primary shard
(shard 0). The shard calls `erlang:monitor(process, Pid)` and stores
the MFA callback. When the monitored process exits, the shard executes
the callback. Cleanup writes within the callback use `beam_agent_ets`
wrappers which route to the correct shard automatically.

In public mode (no owner process), returns `ignored`.

Monitoring a pid that is already dead is safe — the BEAM immediately
delivers a `'DOWN'` message, so the cleanup callback fires on the
next shard loop iteration.
""".
-spec monitor_for_cleanup(pid(), {module(), atom(), [term()]}) -> ok | ignored.
monitor_for_cleanup(Pid, {Mod, Fun, Args} = MFA)
  when is_pid(Pid), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    case owner_pid() of
        undefined ->
            ignored;
        PrimaryPid ->
            PrimaryPid ! {monitor_for_cleanup, Pid, MFA},
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Initialization
%%--------------------------------------------------------------------

-spec do_init(access_mode(), pos_integer()) -> ok.
do_init(public, _ShardCount) ->
    persistent_term:put(?PT_MODE, public),
    persistent_term:put(?PT_INIT, true),
    ok;
do_init(hardened, ShardCount) when is_integer(ShardCount), ShardCount >= 1 ->
    Consumer = self(),
    ShardPids = lists:map(fun(Idx) ->
        IsPrimary = Idx =:= 0,
        Pid = proc_lib:spawn_link(fun() ->
            process_flag(trap_exit, true),
            Consumer ! {self(), shard_ready},
            receive {Consumer, go} -> ok end,
            shard_loop(Consumer, #{}, IsPrimary)
        end),
        receive
            {Pid, shard_ready} -> Pid
        after ?INIT_TIMEOUT ->
            error({beam_agent_shard_init_timeout, Idx})
        end
    end, lists:seq(0, ShardCount - 1)),
    ShardTuple = list_to_tuple(ShardPids),
    persistent_term:put(?PT_MODE, hardened),
    persistent_term:put(?PT_SHARDS, ShardTuple),
    persistent_term:put(?PT_OWNER, element(1, ShardTuple)),
    %% Send `go` to all shards BEFORE marking initialized, so that
    %% other processes cannot observe initialized=true while shards
    %% are still blocked waiting for the go signal.
    lists:foreach(fun(Pid) -> Pid ! {Consumer, go} end, ShardPids),
    persistent_term:put(?PT_INIT, true),
    ok.

%%--------------------------------------------------------------------
%% Internal: Shard Process Loop
%%--------------------------------------------------------------------

-spec shard_loop(pid(), #{reference() => {module(), atom(), [term()]}},
                 boolean()) -> no_return().
shard_loop(Consumer, Monitors, IsPrimary) ->
    receive
        %% Table creation request — we must create it so we own it.
        %% Set the consumer as heir so tables survive shard crashes.
        {create_table, Name, Opts, From, Ref} ->
            HeirOpts = [{heir, Consumer, Name} | Opts],
            _ = try
                _ = ets:new(Name, HeirOpts),
                From ! {table_created, Ref, ok}
            catch
                error:badarg ->
                    %% Already exists — that's fine.
                    From ! {table_created, Ref, ok}
            end,
            shard_loop(Consumer, Monitors, IsPrimary);

        %% Synchronous write — caller needs the result.
        {write_sync, Op, Table, Arg, From, Ref} ->
            Result = safe_write(Op, Table, Arg),
            From ! {write_ack, Ref, Result},
            shard_loop(Consumer, Monitors, IsPrimary);

        %% Monitor a process for cleanup — only the primary shard
        %% handles this. The monitor_for_cleanup/2 API sends this
        %% message only to the primary shard pid, but we guard here
        %% defensively to prevent duplicate monitors if a non-primary
        %% shard ever receives this message due to a bug.
        {monitor_for_cleanup, Pid, MFA} when IsPrimary ->
            MonRef = erlang:monitor(process, Pid),
            shard_loop(Consumer, Monitors#{MonRef => MFA}, IsPrimary);
        {monitor_for_cleanup, _Pid, _MFA} ->
            %% Non-primary shard — drop silently.
            shard_loop(Consumer, Monitors, IsPrimary);

        %% Monitored process died — execute the cleanup callback.
        %% The callback runs inside the shard, so ETS writes for tables
        %% owned by this shard are direct. Writes to other shards' tables
        %% route through beam_agent_ets wrappers automatically.
        {'DOWN', MonRef, process, _Pid, _Reason} ->
            case maps:take(MonRef, Monitors) of
                {{Mod, Fun, Args}, Monitors1} ->
                    try apply(Mod, Fun, Args)
                    catch Class:Err:Stack ->
                        logger:warning(
                            "beam_agent_table_owner: monitor cleanup "
                            "callback ~p:~p/~p failed: ~p:~p~n~p",
                            [Mod, Fun, length(Args), Class,
                             beam_agent_redaction:reason(Err),
                             beam_agent_redaction:stacktrace(Stack)])
                    end,
                    shard_loop(Consumer, Monitors1, IsPrimary);
                error ->
                    shard_loop(Consumer, Monitors, IsPrimary)
            end;

        %% Consumer died — primary cleans up persistent terms, all exit.
        {'EXIT', Consumer, Reason} ->
            case IsPrimary of
                true  -> cleanup_persistent_terms();
                false -> ok
            end,
            exit(Reason);

        %% Any other linked process exit — continue.
        {'EXIT', _Other, _Reason} ->
            shard_loop(Consumer, Monitors, IsPrimary)
    end.

%%--------------------------------------------------------------------
%% Internal: Write Dispatch
%%--------------------------------------------------------------------

%% safe_write/3 intentionally uses term() — dispatches to different ETS
%% operations that return different types.
-dialyzer({nowarn_function, [safe_write/3]}).
-spec safe_write(atom(), atom(), term()) -> term().
safe_write(Op, Table, Arg) ->
    try direct_write(Op, Table, Arg)
    catch
        error:badarg ->
            %% Table may not exist yet — this is a defensive fallback.
            %% In normal operation, ensure_table is called before writes.
            error({beam_agent_table_not_found, Table, Op})
    end.

-spec direct_write(atom(), atom(), term()) -> term().
direct_write(insert, Table, Record) ->
    ets:insert(Table, Record);
direct_write(insert_new, Table, Record) ->
    ets:insert_new(Table, Record);
direct_write(delete, Table, Key) ->
    ets:delete(Table, Key);
direct_write(delete_object, Table, ObjOrKey) ->
    ets:delete_object(Table, ObjOrKey);
direct_write(delete_all_objects, Table, _Arg) ->
    ets:delete_all_objects(Table);
direct_write(update_counter, Table, {Key, UpdateOp}) ->
    ets:update_counter(Table, Key, UpdateOp);
direct_write(update_counter, Table, {Key, UpdateOp, Default}) ->
    ets:update_counter(Table, Key, UpdateOp, Default);
direct_write(select_replace, Table, MatchSpec) ->
    ets:select_replace(Table, MatchSpec);
direct_write(match_delete, Table, Pattern) ->
    ets:match_delete(Table, Pattern).

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

-spec is_member_of_tuple(pid(), tuple()) -> boolean().
is_member_of_tuple(Val, Tuple) ->
    is_member_of_tuple(Val, Tuple, 1, tuple_size(Tuple)).

-spec is_member_of_tuple(pid(), tuple(), pos_integer(), non_neg_integer()) ->
    boolean().
is_member_of_tuple(_Val, _Tuple, Idx, Size) when Idx > Size ->
    false;
is_member_of_tuple(Val, Tuple, Idx, Size) ->
    case element(Idx, Tuple) =:= Val of
        true  -> true;
        false -> is_member_of_tuple(Val, Tuple, Idx + 1, Size)
    end.

%%--------------------------------------------------------------------
%% Internal: Cleanup
%%--------------------------------------------------------------------

-spec cleanup_persistent_terms() -> ok.
cleanup_persistent_terms() ->
    _ = persistent_term:erase(?PT_MODE),
    _ = persistent_term:erase(?PT_OWNER),
    _ = persistent_term:erase(?PT_SHARDS),
    _ = persistent_term:erase(?PT_INIT),
    ok.
