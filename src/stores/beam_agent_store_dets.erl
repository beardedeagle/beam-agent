-module(beam_agent_store_dets).
-moduledoc """
DETS-backed durable store adapter for canonical BeamAgent domains.

This adapter persists domain data to disk using OTP's DETS module,
providing crash-survivable storage behind the `beam_agent_store`
boundary. It is a drop-in replacement for `beam_agent_store_ets` —
callers switch via `beam_agent_store:configure_domain/2`.

## Store Options

The adapter accepts the following keys in the `options` map passed
through `beam_agent_store:configure_domain/2`:

  - `data_dir` (binary or string) — directory for DETS files. Each
    table gets its own file named `<TableAtom>.dets`. Defaults to
    `"beam_agent_data"` under the current working directory.

  - `auto_save` (non_neg_integer | infinity) — DETS auto_save interval
    in milliseconds. Defaults to `30000` (30 seconds). Set to `infinity`
    to disable periodic auto-save (data is still flushed on close).

  - `ram_file` (boolean) — when `true`, DETS keeps the file contents
    in RAM and only flushes to disk on `dets:sync/1` or `dets:close/1`.
    Defaults to `false`. Useful for tests that want durability semantics
    without disk I/O overhead.

  - `atomic_counters` (boolean) — when `true`, `update_counter/4,5`
    uses an in-memory `atomics` reference for lock-free atomic
    increments (hardware CAS) instead of a DETS read-modify-write
    cycle. Counter values are flushed back to DETS on `sync_table/1`,
    `close_table/1`, or explicitly via `flush_counters/1`. Defaults to
    `false`.

    Use this when multiple processes may call `update_counter` on the
    same DETS table concurrently and correctness requires every
    increment to be counted. The tradeoff is a small durability window:
    a crash between an increment and the next flush loses unflushed
    counter deltas.

## Lifecycle

Each `ensure_table/3` call opens a DETS file via `dets:open_file/2`.
The file remains open until the owning process exits or `dets:close/1`
is called explicitly. DETS tables are not garbage-collected like ETS —
callers must close them when done.

## Limitations

  - DETS tables are limited to 2 GB per file (BEAM limitation).
  - DETS does not support `read_concurrency` or `write_concurrency`
    options — those are silently stripped from the options list.
  - Without `atomic_counters`, `update_counter/4,5` uses a
    read-modify-write cycle that is not atomic under concurrent access.
    Enable `atomic_counters` or use external serialization (e.g., a
    gen_server or the table owner) if atomicity is required.
  - `ordered_set` is not supported by DETS — `first/2` and `next/3`
    iterate in hash order, not key order.
""".

-behaviour(beam_agent_store).

-export([
    ensure_table/3,
    insert/3,
    insert_new/3,
    delete/3,
    delete_object/3,
    delete_all_objects/2,
    update_counter/4,
    update_counter/5,
    lookup/3,
    foldl/4,
    first/2,
    next/3
]).

-export([
    close_table/1,
    sync_table/1,
    flush_counters/1,
    data_dir/1
]).

%% Internal ETS table for tracking atomics refs when atomic_counters is
%% enabled.  Uses raw ets: calls intentionally — this is an adapter-internal
%% bookkeeping structure, not SDK-managed state, so it does not route through
%% beam_agent_ets / hardened-mode table-owner proxying.
%%
%% Schema: {{Table, Key}, atomics:atomics_ref(), Pos :: pos_integer()}
-define(ATOMIC_COUNTERS_TABLE, beam_agent_dets_atomic_counters).

%%--------------------------------------------------------------------
%% Store Callbacks
%%--------------------------------------------------------------------

-doc """
Ensure a DETS table file is open.

Opens the DETS file `<data_dir>/<Table>.dets`. If the file is already
open, this is a no-op. ETS-specific options (`read_concurrency`,
`write_concurrency`, `named_table`, access specifiers) are stripped.

The DETS table type is inferred from the options list: if `ordered_set`
is present it is downgraded to `set` (DETS does not support ordered_set).
""".
-spec ensure_table(beam_agent_store:table_name(), [beam_agent_store:table_opt()],
                   beam_agent_store:store_options()) -> ok.
ensure_table(Table, Opts, StoreOpts) ->
    case dets:info(Table, type) of
        undefined ->
            Dir = resolve_data_dir(StoreOpts),
            ok = filelib:ensure_dir(filename:join(Dir, ".")),
            FilePath = filename:join(Dir, atom_to_list(Table) ++ ".dets"),
            DetsOpts = to_dets_opts(Opts, StoreOpts, FilePath),
            case dets:open_file(Table, DetsOpts) of
                {ok, Table} ->
                    _ = file:change_mode(FilePath, 8#0600),
                    ok;
                {ok, _} ->
                    _ = file:change_mode(FilePath, 8#0600),
                    ok;
                {error, Reason} ->
                    error({beam_agent_dets_open_failed, Table, Reason})
            end;
        _Type ->
            ok
    end.

-doc "Insert a record into a DETS table.".
-spec insert(beam_agent_store:table_name(), tuple() | [tuple()],
             beam_agent_store:store_options()) -> true.
insert(Table, Record, _StoreOpts) ->
    ok = dets:insert(Table, Record),
    true.

-doc "Insert a record only if the key is new.".
-spec insert_new(beam_agent_store:table_name(), tuple() | [tuple()],
                 beam_agent_store:store_options()) -> boolean().
insert_new(Table, Record, _StoreOpts) ->
    dets:insert_new(Table, Record).

-doc "Delete a key from a DETS table.".
-spec delete(beam_agent_store:table_name(), beam_agent_store:store_key(),
             beam_agent_store:store_options()) -> true.
delete(Table, Key, _StoreOpts) ->
    ok = dets:delete(Table, Key),
    true.

-doc "Delete a specific object from a DETS table.".
-spec delete_object(beam_agent_store:table_name(), tuple(),
                    beam_agent_store:store_options()) -> true.
delete_object(Table, ObjOrKey, _StoreOpts) ->
    ok = dets:delete_object(Table, ObjOrKey),
    true.

-doc "Delete every object from a DETS table.".
-spec delete_all_objects(beam_agent_store:table_name(),
                         beam_agent_store:store_options()) -> true.
delete_all_objects(Table, _StoreOpts) ->
    ok = dets:delete_all_objects(Table),
    true.

-doc """
Update a counter in a DETS table.

Implemented as read-modify-write. Not atomic under concurrent access —
use external serialization if atomicity is required.
""".
-spec update_counter(beam_agent_store:table_name(), beam_agent_store:store_key(),
                     beam_agent_store:update_op(),
                     beam_agent_store:store_options()) -> integer().
update_counter(Table, Key, UpdateOp, StoreOpts) ->
    case maps:get(atomic_counters, StoreOpts, false) of
        true  -> atomic_update_counter(Table, Key, UpdateOp, undefined);
        false -> do_update_counter(Table, Key, UpdateOp, undefined)
    end.

-doc """
Update a counter with a default record in a DETS table.

If the key does not exist, `Default` is inserted first, then the
update operation is applied.
""".
-spec update_counter(beam_agent_store:table_name(), beam_agent_store:store_key(),
                     beam_agent_store:update_op(), tuple(),
                     beam_agent_store:store_options()) -> integer().
update_counter(Table, Key, UpdateOp, Default, StoreOpts) ->
    case maps:get(atomic_counters, StoreOpts, false) of
        true  -> atomic_update_counter(Table, Key, UpdateOp, Default);
        false -> do_update_counter(Table, Key, UpdateOp, Default)
    end.

-doc "Look up records by key in a DETS table.".
-spec lookup(beam_agent_store:table_name(), beam_agent_store:store_key(),
             beam_agent_store:store_options()) -> [tuple()].
lookup(Table, Key, _StoreOpts) ->
    dets:lookup(Table, Key).

-doc "Fold over all records in a DETS table.".
-spec foldl(fun((tuple(), Acc) -> Acc), Acc, beam_agent_store:table_name(),
            beam_agent_store:store_options()) -> Acc when Acc :: term().
foldl(Fun, Acc, Table, _StoreOpts) ->
    dets:foldl(Fun, Acc, Table).

-doc "Return the first key in a DETS table (hash order, not sorted).".
-spec first(beam_agent_store:table_name(), beam_agent_store:store_options()) ->
    beam_agent_store:store_key() | '$end_of_table'.
first(Table, _StoreOpts) ->
    dets:first(Table).

-doc "Return the next key after Key in a DETS table (hash order).".
-spec next(beam_agent_store:table_name(), beam_agent_store:store_key(),
           beam_agent_store:store_options()) ->
    beam_agent_store:store_key() | '$end_of_table'.
next(Table, Key, _StoreOpts) ->
    dets:next(Table, Key).

%%--------------------------------------------------------------------
%% Additional API
%%--------------------------------------------------------------------

-doc "Close a DETS table file. Flushes atomic counters first. Safe to call if not open.".
-spec close_table(beam_agent_store:table_name()) -> ok.
close_table(Table) ->
    flush_counters(Table),
    case dets:info(Table, type) of
        undefined -> ok;
        _Type -> ok = dets:close(Table)
    end.

-doc "Flush pending writes for a DETS table to disk. Flushes atomic counters first.".
-spec sync_table(beam_agent_store:table_name()) -> ok.
sync_table(Table) ->
    flush_counters(Table),
    ok = dets:sync(Table).

-doc """
Flush in-memory atomic counter values back to their DETS records.

No-op when `atomic_counters` is not enabled or no counters have been
incremented for `Table`. After flushing, the tracking entries for the
table are removed so the next `update_counter` re-seeds from DETS.

Called automatically by `close_table/1` and `sync_table/1`.
""".
-spec flush_counters(beam_agent_store:table_name()) -> ok.
flush_counters(Table) ->
    case ets:whereis(?ATOMIC_COUNTERS_TABLE) of
        undefined -> ok;
        _ ->
            Entries = ets:match_object(?ATOMIC_COUNTERS_TABLE,
                                       {{Table, '_'}, '_', '_'}),
            lists:foreach(fun({{_T, Key}, Ref, Pos}) ->
                Val = atomics:get(Ref, 1),
                case dets:lookup(Table, Key) of
                    [Record] when is_tuple(Record),
                                  tuple_size(Record) >= Pos ->
                        Updated = setelement(Pos, Record, Val),
                        ok = dets:insert(Table, Updated);
                    _ ->
                        %% Key deleted from DETS — nothing to flush.
                        ok
                end
            end, Entries),
            %% Remove tracking entries so next update re-seeds from DETS.
            lists:foreach(fun({EntryKey, _, _}) ->
                ets:delete(?ATOMIC_COUNTERS_TABLE, EntryKey)
            end, Entries),
            ok
    end.

-doc "Resolve the data directory from store options.".
-spec data_dir(beam_agent_store:store_options()) -> file:filename().
data_dir(StoreOpts) ->
    resolve_data_dir(StoreOpts).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec resolve_data_dir(beam_agent_store:store_options()) -> file:filename().
resolve_data_dir(StoreOpts) ->
    case maps:get(data_dir, StoreOpts, undefined) of
        undefined  -> "beam_agent_data";
        Dir when is_binary(Dir) -> binary_to_list(Dir);
        Dir when is_list(Dir) -> Dir
    end.

-spec to_dets_opts([beam_agent_store:table_opt()],
                   beam_agent_store:store_options(), file:filename()) ->
    [term()].
to_dets_opts(EtsOpts, StoreOpts, FilePath) ->
    Type = extract_type(EtsOpts),
    AutoSave = maps:get(auto_save, StoreOpts, 30000),
    RamFile = maps:get(ram_file, StoreOpts, false),
    [{file, FilePath}, {type, Type}, {auto_save, AutoSave},
     {ram_file, RamFile}].

-spec extract_type([beam_agent_store:table_opt()]) -> set | bag | duplicate_bag.
extract_type(Opts) ->
    case lists:member(bag, Opts) of
        true -> bag;
        false ->
            case lists:member(duplicate_bag, Opts) of
                true -> duplicate_bag;
                false -> set  %% ordered_set downgraded to set
            end
    end.

-spec do_update_counter(beam_agent_store:table_name(), beam_agent_store:store_key(),
                        beam_agent_store:update_op(), tuple() | undefined) ->
    integer().
do_update_counter(Table, Key, UpdateOp, Default) ->
    {Pos, Incr} = parse_update_op(UpdateOp),
    case dets:lookup(Table, Key) of
        [] when Default =/= undefined ->
            ok = dets:insert(Table, Default),
            NewVal = element(Pos, Default) + Incr,
            Updated = setelement(Pos, Default, NewVal),
            ok = dets:insert(Table, Updated),
            NewVal;
        [] ->
            error(badarg);
        [Record | _] ->
            OldVal = element(Pos, Record),
            NewVal = OldVal + Incr,
            Updated = setelement(Pos, Record, NewVal),
            ok = dets:insert(Table, Updated),
            NewVal
    end.

-spec parse_update_op(beam_agent_store:update_op()) -> {pos_integer(), integer()}.
parse_update_op({Pos, Incr}) when is_integer(Pos), is_integer(Incr) ->
    {Pos, Incr};
parse_update_op(Incr) when is_integer(Incr) ->
    {2, Incr}.

%%--------------------------------------------------------------------
%% Atomic counters (optional, enabled via atomic_counters => true)
%%
%% Each {Table, Key} pair gets a single-slot `atomics` ref.  Increments
%% use a compare-and-exchange loop so concurrent callers never lose an
%% update.  Values live in memory and are flushed to DETS by
%% flush_counters/1 (called automatically on close/sync).
%%--------------------------------------------------------------------

-spec ensure_atomic_table() -> ok.
ensure_atomic_table() ->
    case ets:whereis(?ATOMIC_COUNTERS_TABLE) of
        undefined ->
            try
                _ = ets:new(?ATOMIC_COUNTERS_TABLE, [named_table, public, set]),
                ok
            catch error:badarg -> ok  %% race: another process created it
            end;
        _ -> ok
    end.

-spec atomic_update_counter(beam_agent_store:table_name(),
                            beam_agent_store:store_key(),
                            beam_agent_store:update_op(),
                            tuple() | undefined) -> integer().
atomic_update_counter(Table, Key, UpdateOp, Default) ->
    ensure_atomic_table(),
    {Pos, Incr, Bounds} = parse_atomic_op(UpdateOp),
    Ref = get_or_create_atomic(Table, Key, Pos, Default),
    case Bounds of
        none ->
            atomic_add_get(Ref, Incr);
        {Threshold, SetValue} ->
            atomic_add_get_bounded(Ref, Incr, Threshold, SetValue)
    end.

%% Look up or lazily create the atomics ref for {Table, Key}.
%% Concurrent creators race on ets:insert_new — exactly one wins.
-spec get_or_create_atomic(beam_agent_store:table_name(),
                           beam_agent_store:store_key(), pos_integer(),
                           tuple() | undefined) -> atomics:atomics_ref().
get_or_create_atomic(Table, Key, Pos, Default) ->
    LookupKey = {Table, Key},
    case ets:lookup(?ATOMIC_COUNTERS_TABLE, LookupKey) of
        [{_, Ref, _}] -> Ref;
        [] ->
            InitVal = seed_value(Table, Key, Pos, Default),
            Ref = atomics:new(1, [{signed, true}]),
            atomics:put(Ref, 1, InitVal),
            case ets:insert_new(?ATOMIC_COUNTERS_TABLE, {LookupKey, Ref, Pos}) of
                true -> Ref;
                false ->
                    %% Lost the race — use the winner's ref.
                    [{_, ExistingRef, _}] =
                        ets:lookup(?ATOMIC_COUNTERS_TABLE, LookupKey),
                    ExistingRef
            end
    end.

-spec seed_value(beam_agent_store:table_name(), beam_agent_store:store_key(),
                 pos_integer(), tuple() | undefined) -> integer().
seed_value(Table, Key, Pos, Default) ->
    case dets:lookup(Table, Key) of
        [Record] when is_tuple(Record), tuple_size(Record) >= Pos ->
            element(Pos, Record);
        _ when is_tuple(Default), tuple_size(Default) >= Pos ->
            ok = dets:insert(Table, Default),
            element(Pos, Default);
        _ ->
            error(badarg)
    end.

%% Lock-free atomic add-and-get via compare-and-exchange loop.
-spec atomic_add_get(atomics:atomics_ref(), integer()) -> integer().
atomic_add_get(Ref, Incr) ->
    Old = atomics:get(Ref, 1),
    case atomics:compare_exchange(Ref, 1, Old, Old + Incr) of
        ok     -> Old + Incr;
        _Stale -> atomic_add_get(Ref, Incr)
    end.

%% Bounded variant: if the new value crosses Threshold, use SetValue.
-spec atomic_add_get_bounded(atomics:atomics_ref(), integer(),
                             integer(), integer()) -> integer().
atomic_add_get_bounded(Ref, Incr, Threshold, SetValue) ->
    Old = atomics:get(Ref, 1),
    New0 = Old + Incr,
    New = if
        Incr >= 0, New0 > Threshold -> SetValue;
        Incr < 0,  New0 < Threshold -> SetValue;
        true -> New0
    end,
    case atomics:compare_exchange(Ref, 1, Old, New) of
        ok     -> New;
        _Stale -> atomic_add_get_bounded(Ref, Incr, Threshold, SetValue)
    end.

%% Parse UpdateOp into {Pos, Incr, Bounds} for the atomic path.
-spec parse_atomic_op(beam_agent_store:update_op()) ->
    {pos_integer(), integer(), none | {integer(), integer()}}.
parse_atomic_op({Pos, Incr, Threshold, SetValue})
  when is_integer(Pos), is_integer(Incr) ->
    {Pos, Incr, {Threshold, SetValue}};
parse_atomic_op({Pos, Incr})
  when is_integer(Pos), is_integer(Incr) ->
    {Pos, Incr, none};
parse_atomic_op(Incr) when is_integer(Incr) ->
    {2, Incr, none}.
