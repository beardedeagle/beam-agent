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

## Lifecycle

Each `ensure_table/3` call opens a DETS file via `dets:open_file/2`.
The file remains open until the owning process exits or `dets:close/1`
is called explicitly. DETS tables are not garbage-collected like ETS —
callers must close them when done.

## Limitations

  - DETS tables are limited to 2 GB per file (BEAM limitation).
  - DETS does not support `read_concurrency` or `write_concurrency`
    options — those are silently stripped from the options list.
  - `update_counter/4,5` is implemented as a read-modify-write cycle
    wrapped in a DETS-safe transaction. This is not atomic under
    concurrent access from multiple processes — use external
    serialization (e.g., a gen_server or the table owner) if atomicity
    is required.
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
    data_dir/1
]).

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
-spec ensure_table(atom(), [term()], map()) -> ok.
ensure_table(Table, Opts, StoreOpts) ->
    case dets:info(Table, type) of
        undefined ->
            Dir = resolve_data_dir(StoreOpts),
            ok = filelib:ensure_dir(filename:join(Dir, ".")),
            FilePath = filename:join(Dir, atom_to_list(Table) ++ ".dets"),
            DetsOpts = to_dets_opts(Opts, StoreOpts, FilePath),
            case dets:open_file(Table, DetsOpts) of
                {ok, Table} -> ok;
                {ok, _}     -> ok;
                {error, Reason} -> error({beam_agent_dets_open_failed, Table, Reason})
            end;
        _Type ->
            ok
    end.

-doc "Insert a record into a DETS table.".
-spec insert(atom(), tuple() | [tuple()], map()) -> true.
insert(Table, Record, _StoreOpts) ->
    ok = dets:insert(Table, Record),
    true.

-doc "Insert a record only if the key is new.".
-spec insert_new(atom(), tuple() | [tuple()], map()) -> boolean().
insert_new(Table, Record, _StoreOpts) ->
    dets:insert_new(Table, Record).

-doc "Delete a key from a DETS table.".
-spec delete(atom(), term(), map()) -> true.
delete(Table, Key, _StoreOpts) ->
    ok = dets:delete(Table, Key),
    true.

-doc "Delete a specific object from a DETS table.".
-spec delete_object(atom(), term(), map()) -> true.
delete_object(Table, ObjOrKey, _StoreOpts) ->
    ok = dets:delete_object(Table, ObjOrKey),
    true.

-doc "Delete every object from a DETS table.".
-spec delete_all_objects(atom(), map()) -> true.
delete_all_objects(Table, _StoreOpts) ->
    ok = dets:delete_all_objects(Table),
    true.

-doc """
Update a counter in a DETS table.

Implemented as read-modify-write. Not atomic under concurrent access —
use external serialization if atomicity is required.
""".
-spec update_counter(atom(), term(), term(), map()) -> integer().
update_counter(Table, Key, UpdateOp, _StoreOpts) ->
    do_update_counter(Table, Key, UpdateOp, undefined).

-doc """
Update a counter with a default record in a DETS table.

If the key does not exist, `Default` is inserted first, then the
update operation is applied.
""".
-spec update_counter(atom(), term(), term(), tuple(), map()) -> integer().
update_counter(Table, Key, UpdateOp, Default, _StoreOpts) ->
    do_update_counter(Table, Key, UpdateOp, Default).

-doc "Look up records by key in a DETS table.".
-spec lookup(atom(), term(), map()) -> [tuple()].
lookup(Table, Key, _StoreOpts) ->
    dets:lookup(Table, Key).

-doc "Fold over all records in a DETS table.".
-spec foldl(fun((tuple(), term()) -> term()), term(), atom(), map()) -> term().
foldl(Fun, Acc, Table, _StoreOpts) ->
    dets:foldl(Fun, Acc, Table).

-doc "Return the first key in a DETS table (hash order, not sorted).".
-spec first(atom(), map()) -> term() | '$end_of_table'.
first(Table, _StoreOpts) ->
    dets:first(Table).

-doc "Return the next key after Key in a DETS table (hash order).".
-spec next(atom(), term(), map()) -> term() | '$end_of_table'.
next(Table, Key, _StoreOpts) ->
    dets:next(Table, Key).

%%--------------------------------------------------------------------
%% Additional API
%%--------------------------------------------------------------------

-doc "Close a DETS table file. Safe to call if not open.".
-spec close_table(atom()) -> ok.
close_table(Table) ->
    case dets:info(Table, type) of
        undefined -> ok;
        _Type -> ok = dets:close(Table)
    end.

-doc "Flush pending writes for a DETS table to disk.".
-spec sync_table(atom()) -> ok.
sync_table(Table) ->
    ok = dets:sync(Table).

-doc "Resolve the data directory from store options.".
-spec data_dir(map()) -> file:filename().
data_dir(StoreOpts) ->
    resolve_data_dir(StoreOpts).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec resolve_data_dir(map()) -> file:filename().
resolve_data_dir(StoreOpts) ->
    case maps:get(data_dir, StoreOpts, undefined) of
        undefined  -> "beam_agent_data";
        Dir when is_binary(Dir) -> binary_to_list(Dir);
        Dir when is_list(Dir) -> Dir
    end.

-spec to_dets_opts([term()], map(), file:filename()) -> [term()].
to_dets_opts(EtsOpts, StoreOpts, FilePath) ->
    Type = extract_type(EtsOpts),
    AutoSave = maps:get(auto_save, StoreOpts, 30000),
    RamFile = maps:get(ram_file, StoreOpts, false),
    [{file, FilePath}, {type, Type}, {auto_save, AutoSave},
     {ram_file, RamFile}].

-spec extract_type([term()]) -> set | bag | duplicate_bag.
extract_type(Opts) ->
    case lists:member(bag, Opts) of
        true -> bag;
        false ->
            case lists:member(duplicate_bag, Opts) of
                true -> duplicate_bag;
                false -> set  %% ordered_set downgraded to set
            end
    end.

-spec do_update_counter(atom(), term(), term(), tuple() | undefined) -> integer().
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

-spec parse_update_op(term()) -> {pos_integer(), integer()}.
parse_update_op({Pos, Incr}) when is_integer(Pos), is_integer(Incr) ->
    {Pos, Incr};
parse_update_op(Incr) when is_integer(Incr) ->
    {2, Incr}.
