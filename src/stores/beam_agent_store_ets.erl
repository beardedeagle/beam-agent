-module(beam_agent_store_ets).
-moduledoc """
Default ETS-backed store adapter for canonical BeamAgent domains.

This adapter preserves the current BeamAgent storage model:

- named ETS tables
- direct read access from any process
- `beam_agent_ets` write proxying in hardened mode
- zero new BeamAgent-owned resident processes

It exists behind `beam_agent_store` so future durable adapters can be added
without changing domain lifecycle code.
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

-doc "Ensure an ETS table exists for the calling domain.".
-spec ensure_table(atom(), [term()], map()) -> ok.
ensure_table(Table, Opts, _StoreOpts) ->
    beam_agent_ets:ensure_table(Table, Opts).

-doc "Insert a record into an ETS-backed store table.".
-spec insert(atom(), tuple() | [tuple()], map()) -> true.
insert(Table, Record, _StoreOpts) ->
    beam_agent_ets:insert(Table, Record).

-doc "Insert a record only if the key is new.".
-spec insert_new(atom(), tuple() | [tuple()], map()) -> boolean().
insert_new(Table, Record, _StoreOpts) ->
    beam_agent_ets:insert_new(Table, Record).

-doc "Delete a key from an ETS-backed store table.".
-spec delete(atom(), term(), map()) -> true.
delete(Table, Key, _StoreOpts) ->
    beam_agent_ets:delete(Table, Key).

-doc "Delete a specific bag object from an ETS-backed store table.".
-spec delete_object(atom(), term(), map()) -> true.
delete_object(Table, ObjOrKey, _StoreOpts) ->
    beam_agent_ets:delete_object(Table, ObjOrKey).

-doc "Delete every object from an ETS-backed store table.".
-spec delete_all_objects(atom(), map()) -> true.
delete_all_objects(Table, _StoreOpts) ->
    beam_agent_ets:delete_all_objects(Table).

-doc "Update a counter in an ETS-backed store table.".
-spec update_counter(atom(), term(), term(), map()) -> integer().
update_counter(Table, Key, UpdateOp, _StoreOpts) ->
    beam_agent_ets:update_counter(Table, Key, UpdateOp).

-doc "Update a counter with a default record in an ETS-backed store table.".
-spec update_counter(atom(), term(), term(), tuple(), map()) -> integer().
update_counter(Table, Key, UpdateOp, Default, _StoreOpts) ->
    beam_agent_ets:update_counter(Table, Key, UpdateOp, Default).

-doc "Look up records in an ETS-backed store table.".
-spec lookup(atom(), term(), map()) -> [tuple()].
lookup(Table, Key, _StoreOpts) ->
    ets:lookup(Table, Key).

-doc "Fold over an ETS-backed store table.".
-spec foldl(fun((tuple(), term()) -> term()), term(), atom(), map()) -> term().
foldl(Fun, Acc, Table, _StoreOpts) ->
    ets:foldl(Fun, Acc, Table).

-doc "Return the first key in an ordered ETS-backed store table.".
-spec first(atom(), map()) -> term() | '$end_of_table'.
first(Table, _StoreOpts) ->
    ets:first(Table).

-doc "Return the next key in an ordered ETS-backed store table.".
-spec next(atom(), term(), map()) -> term() | '$end_of_table'.
next(Table, Key, _StoreOpts) ->
    ets:next(Table, Key).
