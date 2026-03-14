-module(beam_agent_table_owner).
-moduledoc """
ETS table ownership and lifecycle management for the BEAM Agent SDK.

Provides two operational modes for ETS table access control:

  - `public` (default) — All tables use public access. Any process can
    read and write.

  - `hardened` — Five single-writer tables are unconditionally protected.
    The remaining 17 multi-writer tables are protected and writes are
    proxied through a linked owner process. Reads remain zero-cost from
    any process.

The owner process is a plain `proc_lib:spawn_link` — not a gen_server,
not a supervisor, not an OTP application. It lives and dies with the
consumer process that called `init/1`, exactly like an Erlang port or
a linked NIF resource. Tables are garbage-collected by the BEAM when
the owner exits.

## Usage

```erlang
%% In the consumer's gen_server init/1:
init(Args) ->
    ok = beam_agent_table_owner:init(#{table_access => hardened}),
    %% ... rest of init
```

## Security Properties

In hardened mode:
  - Only the owner process can write to protected tables via `ets:insert`
  - All other processes must route writes through `beam_agent_ets` wrappers
  - Reads (`ets:lookup`, `ets:foldl`, `ets:select`, etc.) work from any
    process with zero overhead — no message passing for reads
  - The owner process traps exits and sets the consumer as ETS heir
    via `{heir, Consumer, TableName}` on each created table, so tables
    survive owner crashes and transfer to the consumer for graceful
    recovery. The consumer will receive `{'ETS-TRANSFER', Table, OldOwner, TableName}`
    messages if this occurs and can respawn the owner if needed.

## Performance Characteristics

In hardened mode, all proxied writes serialize through the owner process's
mailbox. ETS writes are sub-microsecond operations, so the owner loop
processes writes at roughly 1-2 million operations per second — well beyond
what agent session workloads demand. However, if the SDK is used in an
application with hundreds of concurrent sessions all writing simultaneously,
the single owner could become a bottleneck.

Future mitigation paths if this proves to be an issue:
  - Shard the owner into N owner processes (one per table or table group)
  - Keep hot-path tables (session_messages, session_counters) as `public`
    even in hardened mode via `#{table_access => hardened, hot_path => public}`
  - Use per-session ETS tables owned by the session engine (architectural
    change that trades global queryability for write isolation)

For now, the single owner is the simplest correct implementation.

## Process Monitoring

In hardened mode, the owner process can monitor arbitrary pids on behalf
of SDK modules via `monitor_for_cleanup/2`. When a monitored process
dies, the owner executes the registered `{Module, Function, Args}` callback
to perform ETS cleanup. This piggybacks on the existing owner loop with
zero new processes.

In public mode (no owner process), `monitor_for_cleanup/2` returns
`ignored` — the consumer is responsible for monitoring subscriber
processes and calling cleanup functions directly.

## Audit Classification

Five tables are classified as single-writer (primarily written by
consumer-facing APIs or the router):

  - `beam_agent_control_callbacks` — primarily consumer-facing APIs
  - `beam_agent_backend_sessions` — primarily `beam_agent_router`
  - `beam_agent_apps` — primarily consumer-facing APIs
  - `beam_agent_skills` — primarily consumer-facing APIs
  - `beam_agent_checkpoints` — primarily consumer-facing APIs

Note: the session engine may also write to these tables during lifecycle
events (e.g., termination cleanup). In `public` mode all tables use public
access so any process can write. In `hardened` mode all tables are protected
and writes are proxied through the owner process.
""".

-export([
    init/0,
    init/1,
    access_mode/0,
    owner_pid/0,
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
    table_access => access_mode()
}.

%%--------------------------------------------------------------------
%% Persistent term keys
%%--------------------------------------------------------------------

-define(PT_MODE, beam_agent_table_access_mode).
-define(PT_OWNER, beam_agent_table_owner_pid).
-define(PT_INIT, beam_agent_tables_initialized).

%% Write proxy timeout — generous default for backpressure safety.
-define(WRITE_TIMEOUT, 5000).

%% Init ready timeout.
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

In `public` mode, tables are created in the calling process with public
access. In `hardened` mode, a linked helper process is spawned to own
the protected tables and proxy writes.

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
            do_init(Mode)
    end.

-doc "Return the current access mode. Defaults to `public` if not initialized.".
-spec access_mode() -> access_mode().
access_mode() ->
    persistent_term:get(?PT_MODE, public).

-doc "Return the table owner pid, or `undefined` if in public mode.".
-spec owner_pid() -> pid() | undefined.
owner_pid() ->
    persistent_term:get(?PT_OWNER, undefined).

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
is_always_protected(beam_agent_control_callbacks) -> true;
is_always_protected(beam_agent_backend_sessions)  -> true;
is_always_protected(beam_agent_apps)              -> true;
is_always_protected(beam_agent_skills)            -> true;
is_always_protected(beam_agent_checkpoints)       -> true;
is_always_protected(_)                            -> false.

-doc """
Resolve the effective access mode for a given table.

In `public` mode, all tables are public — including the five
always-protected tables. Without an owner process there is no write
proxy, so every process must be able to write directly.

In `hardened` mode, all tables are protected. Writes are serialized
through the owner process regardless of which table is being written to.
""".
-spec resolve_access(atom()) -> public | protected.
resolve_access(_TableName) ->
    case access_mode() of
        public   -> public;
        hardened -> protected
    end.

-doc """
Send a synchronous write command to the table owner and wait for the result.

This is the sole write path in hardened mode. All ETS mutations (insert,
delete, update_counter, etc.) are serialized through the owner to
guarantee write ordering. The caller blocks until the owner acknowledges
the write.

In public mode (or if the owner is not running), falls back to a direct
ETS call.
""".
-spec write_proxy_sync(atom(), atom(), term()) -> term().
write_proxy_sync(Op, Table, Arg) ->
    case owner_pid() of
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
Ask the owner process to monitor `Pid` and execute `MFA` when it dies.

In hardened mode, sends an asynchronous message to the owner process.
The owner calls `erlang:monitor(process, Pid)` and stores the MFA
callback. When the monitored process exits, the owner executes the
callback directly — since the owner owns the ETS tables, cleanup
writes have zero proxy overhead.

In public mode (no owner process), returns `ignored`. The consumer
is responsible for monitoring processes and calling cleanup functions.

Monitoring a pid that is already dead is safe — the BEAM immediately
delivers a `'DOWN'` message, so the cleanup callback fires on the
next owner loop iteration.
""".
-spec monitor_for_cleanup(pid(), {module(), atom(), [term()]}) -> ok | ignored.
monitor_for_cleanup(Pid, {Mod, Fun, Args} = MFA)
  when is_pid(Pid), is_atom(Mod), is_atom(Fun), is_list(Args) ->
    case owner_pid() of
        undefined ->
            ignored;
        OwnerPid ->
            OwnerPid ! {monitor_for_cleanup, Pid, MFA},
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Initialization
%%--------------------------------------------------------------------

-spec do_init(access_mode()) -> ok.
do_init(public) ->
    persistent_term:put(?PT_MODE, public),
    persistent_term:put(?PT_INIT, true),
    ok;
do_init(hardened) ->
    Consumer = self(),
    Pid = proc_lib:spawn_link(fun() ->
        process_flag(trap_exit, true),
        persistent_term:put(?PT_MODE, hardened),
        persistent_term:put(?PT_OWNER, self()),
        persistent_term:put(?PT_INIT, true),
        Consumer ! {self(), tables_ready},
        owner_loop(Consumer, #{})
    end),
    receive
        {Pid, tables_ready} ->
            ok
    after ?INIT_TIMEOUT ->
        error(beam_agent_table_init_timeout)
    end.

%%--------------------------------------------------------------------
%% Internal: Owner Process Loop
%%--------------------------------------------------------------------

-spec owner_loop(pid(), #{reference() => {module(), atom(), [term()]}}) ->
    no_return().
owner_loop(Consumer, Monitors) ->
    receive
        %% Table creation request — we must create it so we own it.
        %% Set the consumer as heir so tables survive owner crashes.
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
            owner_loop(Consumer, Monitors);

        %% Synchronous write — caller needs the result.
        {write_sync, Op, Table, Arg, From, Ref} ->
            Result = safe_write(Op, Table, Arg),
            From ! {write_ack, Ref, Result},
            owner_loop(Consumer, Monitors);

        %% Monitor a process for cleanup — called by SDK modules
        %% (e.g., beam_agent_events) to get automatic ETS cleanup
        %% when a subscriber dies.
        {monitor_for_cleanup, Pid, MFA} ->
            MonRef = erlang:monitor(process, Pid),
            owner_loop(Consumer, Monitors#{MonRef => MFA});

        %% Monitored process died — execute the cleanup callback.
        %% The callback runs inside the owner, so ETS writes are
        %% direct (no proxy overhead). Errors are caught to protect
        %% the owner from faulty callbacks.
        {'DOWN', MonRef, process, _Pid, _Reason} ->
            case maps:take(MonRef, Monitors) of
                {{Mod, Fun, Args}, Monitors1} ->
                    try apply(Mod, Fun, Args)
                    catch Class:Err:Stack ->
                        logger:warning(
                            "beam_agent_table_owner: monitor cleanup "
                            "callback ~p:~p/~p failed: ~p:~p~n~p",
                            [Mod, Fun, length(Args), Class, Err, Stack])
                    end,
                    owner_loop(Consumer, Monitors1);
                error ->
                    owner_loop(Consumer, Monitors)
            end;

        %% Consumer died — we follow.
        {'EXIT', Consumer, Reason} ->
            cleanup_persistent_terms(),
            exit(Reason);

        %% Any other linked process exit — continue.
        {'EXIT', _Other, normal} ->
            owner_loop(Consumer, Monitors);
        {'EXIT', _Other, _Reason} ->
            owner_loop(Consumer, Monitors)
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
    ets:update_counter(Table, Key, UpdateOp, Default).

%%--------------------------------------------------------------------
%% Internal: Cleanup
%%--------------------------------------------------------------------

-spec cleanup_persistent_terms() -> ok.
cleanup_persistent_terms() ->
    _ = persistent_term:erase(?PT_MODE),
    _ = persistent_term:erase(?PT_OWNER),
    _ = persistent_term:erase(?PT_INIT),
    ok.
