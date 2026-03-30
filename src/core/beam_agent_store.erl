-module(beam_agent_store).
-moduledoc """
Internal store adapter boundary for canonical BeamAgent domains.

This module keeps store selection and persistence mechanics separate from
domain lifecycle logic. Canonical domains such as runs, artifacts, and the
journal still own their record shapes, filtering, and validation rules, while
`beam_agent_store` resolves which persistence adapter should back each domain.

The default adapter is `beam_agent_store_ets`, which preserves the existing
process-free ETS plus `beam_agent_table_owner` hardened-mode behavior. Future
durable adapters can be introduced behind the same boundary without forcing a
big-bang rewrite of every canonical domain.

== Shared `beam_agent_domains` Table — Composite-Key Contract

Several domain modules share the single `beam_agent_domains` ETS table to avoid
proliferating named tables. Each domain namespaces its entries using a unique
composite-key prefix tuple as the first element of the key:

| Domain Module                    | Key Prefix(es)                              |
|----------------------------------|----------------------------------------------|
| `beam_agent_runs_store`          | `{run, RunId}`, `{run_step, {RunId, StepId}}`|
| `beam_agent_artifacts_store`     | `{artifact, ArtifactId}`                     |
| `beam_agent_memory_store`        | `{memory, MemoryId}`                         |
| `beam_agent_threads_core`        | `{thread, ThreadKey}`, `{active_thread, Sid}` |
| `beam_agent_orchestrator_store`  | `{orch_link, ChildRunId}`                    |
| `beam_agent_policy_core`         | `{policy, PolicyId}`                         |
| `beam_agent_routing_core`        | `{routing_affinity, Key}`, `{routing_rr, Key}`|

**Rules for shared-table domains:**

1. **Key prefixes must be unique atoms** — no two domains may use the same
   prefix atom. New domains must choose a prefix that does not collide.

2. **Clear operations must use `match_delete/2`** — never call
   `delete_all_objects/2` on the shared table. Each domain's `clear/0`
   must only delete its own prefix:
   `beam_agent_ets:match_delete(?DOMAINS_TABLE, {{my_prefix, '_'}, '_'})`.

3. **Each domain calls `ensure_table/3` independently** — the call is
   idempotent and the table options must be `[set, named_table,
   {read_concurrency, true}]` for all domains sharing this table.
""".

-export([
    ensure_tables/0,
    clear/0,
    configure_domain/2,
    domain_config/1,
    adapter_module/1,
    reset_domain/1,
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

-export_type([
    domain/0,
    adapter_module/0,
    store_options/0,
    store_config/0,
    store_key/0,
    table_name/0,
    table_opt/0,
    update_op/0
]).

%% --- Store types ---

-type domain() :: atom().
-type adapter_module() :: module().
-type store_options() :: map().
-type store_config() :: #{
    adapter := adapter_module(),
    options => store_options()
}.

-type table_name() :: atom().
-type table_opt() :: set | ordered_set | bag | duplicate_bag
                   | named_table | {read_concurrency, boolean()}
                   | {write_concurrency, boolean() | auto}
                   | public | protected | private.
-type store_key() :: atom() | binary() | tuple() | pid() | integer().
-type update_op() :: integer()
                   | {pos_integer(), integer()}
                   | {pos_integer(), integer(), integer(), integer()}.

%% --- Callbacks ---

-callback ensure_table(table_name(), [table_opt()], store_options()) -> ok.
-callback insert(table_name(), tuple() | [tuple()], store_options()) -> true.
-callback insert_new(table_name(), tuple() | [tuple()], store_options()) -> boolean().
-callback delete(table_name(), store_key(), store_options()) -> true.
-callback delete_object(table_name(), tuple(), store_options()) -> true.
-callback delete_all_objects(table_name(), store_options()) -> true.
%% Note: atomicity of update_counter is adapter-dependent. The default
%% ETS adapter provides atomic updates via ets:update_counter/3,4. The
%% DETS adapter uses a read-modify-write cycle which is NOT atomic under
%% concurrent access unless atomic_counters => true is set. Callers
%% requiring atomic counters should verify their configured adapter
%% guarantees atomicity.
-callback update_counter(table_name(), store_key(), update_op(),
                         store_options()) -> integer().
-callback update_counter(table_name(), store_key(), update_op(),
                         tuple(), store_options()) -> integer().
-callback lookup(table_name(), store_key(), store_options()) -> [tuple()].
-callback foldl(fun((tuple(), Acc) -> Acc), Acc, table_name(),
                store_options()) -> Acc when Acc :: term().
-callback first(table_name(), store_options()) -> store_key() | '$end_of_table'.
-callback next(table_name(), store_key(), store_options()) ->
    store_key() | '$end_of_table'.

-define(CONFIG_TABLE, beam_agent_store_config).

-doc "Ensure the store configuration table exists. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    beam_agent_ets:ensure_table(?CONFIG_TABLE, [set, named_table,
        {read_concurrency, true}]).

-doc "Clear all domain store configuration and revert every domain to defaults.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    beam_agent_ets:delete_all_objects(?CONFIG_TABLE),
    ok.

-doc """
Configure a persistence adapter for a canonical domain.

Domains default to `beam_agent_store_ets`; callers only need this when a test
or future durable adapter wants to override that default.
""".
-spec configure_domain(domain(), store_config()) ->
    ok | {error, invalid_options | {invalid_adapter, atom()}}.
configure_domain(Domain, Config) when is_atom(Domain), is_map(Config) ->
    ensure_tables(),
    case normalize_config(Config) of
        {ok, Normalized} ->
            true = beam_agent_ets:insert(?CONFIG_TABLE, {Domain, Normalized}),
            ok;
        {error, _} = Error ->
            Error
    end.

-doc "Return the normalized store config for a domain, including defaults.".
-spec domain_config(domain()) -> store_config().
domain_config(Domain) when is_atom(Domain) ->
    ensure_tables(),
    case ets:lookup(?CONFIG_TABLE, Domain) of
        [{_, Config}] when is_map(Config) ->
            Config;
        [] ->
            default_config()
    end.

-doc "Return the adapter module backing a domain.".
-spec adapter_module(domain()) -> adapter_module().
adapter_module(Domain) when is_atom(Domain) ->
    maps:get(adapter, domain_config(Domain)).

-doc "Remove any custom store config for a domain and restore defaults.".
-spec reset_domain(domain()) -> ok.
reset_domain(Domain) when is_atom(Domain) ->
    ensure_tables(),
    beam_agent_ets:delete(?CONFIG_TABLE, Domain),
    ok.

-doc "Ensure a named table or equivalent backing store exists for a domain.".
-spec ensure_table(domain(), table_name(), [table_opt()]) -> ok.
ensure_table(Domain, Table, Opts)
  when is_atom(Domain), is_atom(Table), is_list(Opts) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:ensure_table(Table, Opts, AdapterOpts)
    end).

-doc "Insert a record through the configured domain store.".
-spec insert(domain(), table_name(), tuple() | [tuple()]) -> true.
insert(Domain, Table, Record) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:insert(Table, Record, AdapterOpts)
    end).

-doc "Insert a record only if its key does not yet exist.".
-spec insert_new(domain(), table_name(), tuple() | [tuple()]) -> boolean().
insert_new(Domain, Table, Record) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:insert_new(Table, Record, AdapterOpts)
    end).

-doc "Delete a key through the configured domain store.".
-spec delete(domain(), table_name(), store_key()) -> true.
delete(Domain, Table, Key) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:delete(Table, Key, AdapterOpts)
    end).

-doc "Delete a specific object from a bag-like store.".
-spec delete_object(domain(), table_name(), tuple()) -> true.
delete_object(Domain, Table, ObjOrKey) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:delete_object(Table, ObjOrKey, AdapterOpts)
    end).

-doc "Delete every object from a domain store table.".
-spec delete_all_objects(domain(), table_name()) -> true.
delete_all_objects(Domain, Table) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:delete_all_objects(Table, AdapterOpts)
    end).

-doc "Update a counter through the configured domain store.".
-spec update_counter(domain(), table_name(), store_key(), update_op()) ->
    integer().
update_counter(Domain, Table, Key, UpdateOp)
  when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:update_counter(Table, Key, UpdateOp, AdapterOpts)
    end).

-doc "Update a counter with a default record through the configured domain store.".
-spec update_counter(domain(), table_name(), store_key(), update_op(),
                     tuple()) -> integer().
update_counter(Domain, Table, Key, UpdateOp, Default)
  when is_atom(Domain), is_atom(Table), is_tuple(Default) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:update_counter(Table, Key, UpdateOp, Default, AdapterOpts)
    end).

-doc "Look up records by key through the configured domain store.".
-spec lookup(domain(), table_name(), store_key()) -> [tuple()].
lookup(Domain, Table, Key) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:lookup(Table, Key, AdapterOpts)
    end).

-doc "Fold over a domain store table.".
-spec foldl(domain(), fun((tuple(), Acc) -> Acc), Acc, table_name()) ->
    Acc when Acc :: term().
foldl(Domain, Fun, Acc, Table)
  when is_atom(Domain), is_function(Fun, 2), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:foldl(Fun, Acc, Table, AdapterOpts)
    end).

-doc "Return the first key in a domain store table.".
-spec first(domain(), table_name()) -> store_key() | '$end_of_table'.
first(Domain, Table) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:first(Table, AdapterOpts)
    end).

-doc "Return the next key in a domain store table.".
-spec next(domain(), table_name(), store_key()) ->
    store_key() | '$end_of_table'.
next(Domain, Table, Key) when is_atom(Domain), is_atom(Table) ->
    with_adapter(Domain, fun(Adapter, AdapterOpts) ->
        Adapter:next(Table, Key, AdapterOpts)
    end).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec with_adapter(domain(), fun((adapter_module(), store_options()) -> Result)) -> Result.
with_adapter(Domain, Fun) when is_atom(Domain), is_function(Fun, 2) ->
    #{adapter := Adapter, options := AdapterOpts} = domain_config(Domain),
    Fun(Adapter, AdapterOpts).

-spec normalize_config(store_config()) ->
    {ok, store_config()} | {error, invalid_options | {invalid_adapter, term()}}.
normalize_config(#{adapter := Adapter} = Config) when is_atom(Adapter) ->
    case validate_adapter(Adapter) of
        ok ->
            case maps:get(options, Config, #{}) of
                Options when is_map(Options) ->
                    {ok, #{
                        adapter => Adapter,
                        options => Options
                    }};
                _ ->
                    {error, invalid_options}
            end;
        {error, _} = Error ->
            Error
    end;
normalize_config(_) ->
    {error, invalid_options}.

-spec validate_adapter(adapter_module()) -> ok | {error, {invalid_adapter, atom()}}.
validate_adapter(Adapter) ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case lists:all(fun({Fun, Arity}) ->
                erlang:function_exported(Adapter, Fun, Arity)
            end, required_callbacks()) of
                true ->
                    ok;
                false ->
                    {error, {invalid_adapter, Adapter}}
            end;
        _ ->
            {error, {invalid_adapter, Adapter}}
    end.

-type required_callback() ::
    {ensure_table | insert | insert_new | delete | delete_object | lookup | next, 3}
  | {delete_all_objects | first, 2}
  | {update_counter, 4 | 5}
  | {foldl, 4}.

-spec required_callbacks() -> [required_callback(), ...].
required_callbacks() ->
    [
        {ensure_table, 3},
        {insert, 3},
        {insert_new, 3},
        {delete, 3},
        {delete_object, 3},
        {delete_all_objects, 2},
        {update_counter, 4},
        {update_counter, 5},
        {lookup, 3},
        {foldl, 4},
        {first, 2},
        {next, 3}
    ].

-spec default_config() -> #{adapter := beam_agent_store_ets, options := #{}}.
default_config() ->
    #{
        adapter => beam_agent_store_ets,
        options => #{}
    }.
