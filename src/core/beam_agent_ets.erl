-module(beam_agent_ets).
-moduledoc """
Transparent ETS access layer for the BEAM Agent SDK.

Provides drop-in replacements for `ets:insert/2`, `ets:delete/2`,
`ets:update_counter/3,4`, and other write operations that automatically
route through the table owner process when running in hardened mode.

Read operations (`lookup/2`, `foldl/3`, `select/2`, etc.) are passed
through directly to `ets` — they work on protected tables from any
process with zero overhead.

## Migration

Replace direct `ets:insert` / `ets:delete` / `ets:update_counter` calls
in SDK modules with the corresponding `beam_agent_ets` function:

```erlang
%% Before:
ets:insert(?TABLE, {Key, Value})

%% After:
beam_agent_ets:insert(?TABLE, {Key, Value})
```

Table creation uses `ensure_table/2` which automatically resolves the
correct access mode (public or protected) based on the table name and
the global access mode:

```erlang
%% Before:
ets:new(?TABLE, [set, public, named_table, {read_concurrency, true}])

%% After — note: omit the access specifier (public/protected/private):
beam_agent_ets:ensure_table(?TABLE, [set, named_table,
    {read_concurrency, true}])
```

## Performance Characteristics

- **Reads**: Zero overhead. Delegates directly to `ets` module.
- **Writes in public mode**: Zero overhead. Delegates directly to `ets`.
- **Writes in hardened mode from owner process**: Zero overhead. Detects
  self-ownership and writes directly.
- **Writes in hardened mode from other processes**: One synchronous
  message round-trip per write (send + receive acknowledgment).
""".

-export([
    %% Table lifecycle
    ensure_table/2,

    %% Write operations (proxied in hardened mode)
    insert/2,
    insert_new/2,
    delete/2,
    delete_object/2,
    delete_all_objects/1,
    update_counter/3,
    update_counter/4,

    %% Read operations (always direct — no proxy needed)
    lookup/2,
    foldl/3,
    whereis/1,
    next/2,
    select/2,
    match/2,
    match_object/2,
    tab2list/1,
    info/1,
    info/2
]).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc """
Ensure a named ETS table exists with the given options. Idempotent.

The access mode (`public` or `protected`) is resolved automatically
based on the table name and the global access mode configured via
`beam_agent_table_owner:init/1`. Do NOT include `public`, `protected`,
or `private` in the `Opts` list — it will be injected.

In hardened mode, if the calling process is not the table owner, the
table creation request is forwarded to the owner process via a
synchronous proxy call.

```erlang
%% Correct:
beam_agent_ets:ensure_table(my_table, [set, named_table,
    {read_concurrency, true}]).

%% Wrong — do not specify access mode:
beam_agent_ets:ensure_table(my_table, [set, protected, named_table]).
```
""".
-spec ensure_table(atom(), [term()]) -> ok.
ensure_table(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            Access = beam_agent_table_owner:resolve_access(Name),
            FullOpts = [Access | Opts],
            create_table(Name, FullOpts, Access);
        _Tid ->
            ok
    end.

%%--------------------------------------------------------------------
%% Write Operations
%%--------------------------------------------------------------------

-doc "Insert a record. Proxied through owner in hardened mode.".
-spec insert(atom(), tuple() | [tuple()]) -> true.
insert(Table, Record) ->
    case needs_proxy(Table) of
        false -> ets:insert(Table, Record);
        true  -> beam_agent_table_owner:write_proxy_sync(insert, Table, Record)
    end.

-doc "Insert a record only if the key does not exist. Proxied in hardened mode.".
-spec insert_new(atom(), tuple() | [tuple()]) -> boolean().
insert_new(Table, Record) ->
    case needs_proxy(Table) of
        false -> ets:insert_new(Table, Record);
        true  -> beam_agent_table_owner:write_proxy_sync(insert_new, Table, Record)
    end.

-doc "Delete all records with the given key. Proxied in hardened mode.".
-spec delete(atom(), term()) -> true.
delete(Table, Key) ->
    case needs_proxy(Table) of
        false -> ets:delete(Table, Key);
        true  -> beam_agent_table_owner:write_proxy_sync(delete, Table, Key)
    end.

-doc "Delete a specific object from a bag table. Proxied in hardened mode.".
-spec delete_object(atom(), term()) -> true.
delete_object(Table, ObjOrKey) ->
    case needs_proxy(Table) of
        false -> ets:delete_object(Table, ObjOrKey);
        true  -> beam_agent_table_owner:write_proxy_sync(delete_object, Table, ObjOrKey)
    end.

-doc "Delete all objects from a table. Proxied in hardened mode.".
-spec delete_all_objects(atom()) -> true.
delete_all_objects(Table) ->
    case needs_proxy(Table) of
        false -> ets:delete_all_objects(Table);
        true  -> beam_agent_table_owner:write_proxy_sync(delete_all_objects, Table, undefined)
    end.

-doc "Atomically update a counter. Always synchronous (returns the new value).".
-spec update_counter(atom(), term(), term()) -> integer().
update_counter(Table, Key, UpdateOp) ->
    case needs_proxy(Table) of
        false -> ets:update_counter(Table, Key, UpdateOp);
        true  -> beam_agent_table_owner:write_proxy_sync(
                     update_counter, Table, {Key, UpdateOp})
    end.

-doc "Atomically update a counter with a default record. Always synchronous.".
-spec update_counter(atom(), term(), term(), tuple()) -> integer().
update_counter(Table, Key, UpdateOp, Default) ->
    case needs_proxy(Table) of
        false -> ets:update_counter(Table, Key, UpdateOp, Default);
        true  -> beam_agent_table_owner:write_proxy_sync(
                     update_counter, Table, {Key, UpdateOp, Default})
    end.

%%--------------------------------------------------------------------
%% Read Operations (Direct Passthrough)
%%--------------------------------------------------------------------

-doc "Look up records by key. Always direct — no proxy.".
-spec lookup(atom(), term()) -> [tuple()].
lookup(Table, Key) ->
    ets:lookup(Table, Key).

-doc "Fold over all records. Always direct — no proxy.".
-spec foldl(fun((tuple(), Acc) -> Acc), Acc, atom()) -> Acc when Acc :: term().
foldl(Fun, Acc, Table) ->
    ets:foldl(Fun, Acc, Table).

-doc "Return the tid for a named table, or `undefined`. Always direct.".
-spec whereis(atom()) -> ets:tid() | undefined.
whereis(Name) ->
    ets:whereis(Name).

-doc "Return the next key after `Key` in an ordered_set. Always direct.".
-spec next(atom(), term()) -> term() | '$end_of_table'.
next(Table, Key) ->
    ets:next(Table, Key).

-doc "Select records matching a match specification. Always direct.".
-spec select(atom(), ets:match_spec()) -> [term()].
select(Table, MatchSpec) ->
    ets:select(Table, MatchSpec).

-doc "Match records against a pattern. Always direct.".
-spec match(atom(), ets:match_pattern()) -> [[term()]].
match(Table, Pattern) ->
    ets:match(Table, Pattern).

-doc "Match records and return full objects. Always direct.".
-spec match_object(atom(), ets:match_pattern()) -> [tuple()].
match_object(Table, Pattern) ->
    ets:match_object(Table, Pattern).

-doc "Return all records as a list. Always direct.".
-spec tab2list(atom()) -> [tuple()].
tab2list(Table) ->
    ets:tab2list(Table).

-doc "Return table info. Always direct.".
-spec info(atom()) -> [{atom(), term()}] | undefined.
info(Table) ->
    ets:info(Table).

-doc "Return specific table info item. Always direct.".
-spec info(atom(), atom()) -> term() | undefined.
info(Table, Item) ->
    ets:info(Table, Item).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% Determine if the current write needs to go through the proxy.
%% Returns false if:
%%   - Global mode is public (all tables are public, no proxy needed)
%%   - The owner process is not running
%%   - The calling process IS the table owner (direct write is safe)
%% Returns true in hardened mode when the caller is not the owner.
-spec needs_proxy(atom()) -> boolean().
needs_proxy(_Table) ->
    case beam_agent_table_owner:access_mode() of
        public ->
            false;
        hardened ->
            case beam_agent_table_owner:owner_pid() of
                undefined ->
                    false;
                OwnerPid ->
                    self() =/= OwnerPid
            end
    end.

%% Create a new named table, handling the race where another process
%% may create it between our whereis check and the new call.
%%
%% In hardened mode, if the table needs to be protected and we are not
%% the owner, delegate creation to the owner process.
-spec create_table(atom(), [term()], public | protected) -> ok.
create_table(Name, FullOpts, protected) ->
    case beam_agent_table_owner:owner_pid() of
        undefined ->
            %% No owner process — create directly. The calling process
            %% becomes the table owner. For always-protected tables this
            %% is correct because they are single-writer (consumer only).
            try_create(Name, FullOpts);
        OwnerPid when OwnerPid =:= self() ->
            %% We ARE the owner — create directly with protected access.
            try_create(Name, FullOpts);
        OwnerPid ->
            %% We're not the owner — ask the owner to create it.
            %% This is synchronous because the caller needs the table
            %% to exist before proceeding.
            Ref = make_ref(),
            OwnerPid ! {create_table, Name, FullOpts, self(), Ref},
            receive
                {table_created, Ref, ok} -> ok
            after 5000 ->
                error({beam_agent_table_create_timeout, Name})
            end
    end;
create_table(Name, FullOpts, public) ->
    try_create(Name, FullOpts).

-spec try_create(atom(), [term()]) -> ok.
try_create(Name, Opts) ->
    try
        _ = ets:new(Name, Opts),
        ok
    catch
        error:badarg -> ok  %% Already exists (race condition).
    end.
