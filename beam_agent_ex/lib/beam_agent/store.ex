defmodule BeamAgent.Store do
  @moduledoc """
  Store adapter boundary for canonical BeamAgent domains.

  This module wraps the Erlang `:beam_agent_store` boundary, providing
  idiomatic Elixir access to domain-level persistence configuration.
  Domains default to the ETS adapter (`:beam_agent_store_ets`); callers
  only need this module when switching a domain to a durable adapter
  such as `:beam_agent_store_dets`.

  ## Quick start

  ```elixir
  # Switch a domain to DETS-backed durable storage
  :ok = BeamAgent.Store.configure_domain(:my_domain, %{
    adapter: :beam_agent_store_dets,
    options: %{data_dir: "/var/data", ram_file: false}
  })

  # With atomic counters for concurrent-safe increments
  :ok = BeamAgent.Store.configure_domain(:my_domain, %{
    adapter: :beam_agent_store_dets,
    options: %{data_dir: "/var/data", atomic_counters: true}
  })

  # Query current config
  %{adapter: :beam_agent_store_dets} = BeamAgent.Store.domain_config(:my_domain)

  # Reset back to default ETS adapter
  :ok = BeamAgent.Store.reset_domain(:my_domain)
  ```

  ## Available adapters

  | Adapter | Description |
  |---------|-------------|
  | `:beam_agent_store_ets` | Default. In-memory ETS with hardened-mode write proxying. |
  | `:beam_agent_store_dets` | Durable disk-backed DETS. Supports `atomic_counters` option. |

  ## DETS store options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `data_dir` | binary or string | `"beam_agent_data"` | Directory for `.dets` files |
  | `auto_save` | non_neg_integer or `:infinity` | `30000` | Auto-save interval in ms |
  | `ram_file` | boolean | `false` | Keep file contents in RAM (useful for tests) |
  | `atomic_counters` | boolean | `false` | Use `atomics` CAS loops for lock-free counter increments |
  """

  @typedoc "A canonical domain atom (e.g., `:runs`, `:artifacts`, `:journal`)."
  @type domain() :: atom()

  @typedoc "A store adapter module implementing the `beam_agent_store` behaviour."
  @type adapter_module() :: module()

  @typedoc "Adapter-specific options passed through to the backing store."
  @type store_options() :: map()

  @typedoc """
  Store configuration map.

  Must contain `:adapter` (a module implementing the store behaviour).
  May contain `:options` (adapter-specific settings).
  """
  @type store_config() :: %{
          required(:adapter) => adapter_module(),
          optional(:options) => store_options()
        }

  @typedoc "ETS/DETS table name."
  @type table_name() :: atom()

  @typedoc """
  Store key type.

  Covers the common BEAM key types used across BeamAgent domains.
  """
  @type store_key() :: atom() | binary() | tuple() | pid() | integer()

  @typedoc """
  Counter update operation.

  - Integer: increment element at position 2 by the given amount.
  - `{pos, incr}`: increment element at `pos` by `incr`.
  - `{pos, incr, threshold, set_value}`: bounded increment.
  """
  @type update_op() ::
          integer()
          | {pos_integer(), integer()}
          | {pos_integer(), integer(), integer(), integer()}

  # -------------------------------------------------------------------
  # Domain configuration
  # -------------------------------------------------------------------

  @doc """
  Configure a persistence adapter for a canonical domain.

  Domains default to `:beam_agent_store_ets`. Use this to switch a
  domain to `:beam_agent_store_dets` or any custom adapter implementing
  the `beam_agent_store` behaviour.

  Returns `:ok` on success, or `{:error, reason}` for invalid config.

  ## Example

      :ok = BeamAgent.Store.configure_domain(:my_domain, %{
        adapter: :beam_agent_store_dets,
        options: %{data_dir: "/var/data"}
      })
  """
  @spec configure_domain(domain(), store_config()) ::
          :ok | {:error, :invalid_options | {:invalid_adapter, atom()}}
  defdelegate configure_domain(domain, config), to: :beam_agent_store

  @doc """
  Return the normalized store config for a domain, including defaults.

  ## Example

      %{adapter: :beam_agent_store_ets, options: %{}} =
        BeamAgent.Store.domain_config(:default_domain)
  """
  @spec domain_config(domain()) :: store_config()
  defdelegate domain_config(domain), to: :beam_agent_store

  @doc """
  Return the adapter module backing a domain.

  ## Example

      :beam_agent_store_ets = BeamAgent.Store.adapter_module(:runs)
  """
  @spec adapter_module(domain()) :: adapter_module()
  defdelegate adapter_module(domain), to: :beam_agent_store

  @doc """
  Remove any custom store config for a domain and restore defaults.

  ## Example

      :ok = BeamAgent.Store.reset_domain(:my_domain)
  """
  @spec reset_domain(domain()) :: :ok
  defdelegate reset_domain(domain), to: :beam_agent_store

  @doc """
  Ensure the store configuration table exists. Idempotent.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_store

  @doc """
  Clear all domain store configuration and revert every domain to defaults.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_store

  # -------------------------------------------------------------------
  # DETS helpers
  # -------------------------------------------------------------------

  @doc """
  Close a DETS table file.

  Flushes any in-memory atomic counter values to disk before closing.
  Safe to call on tables that are not open. No-op for ETS-backed domains.

  ## Example

      :ok = BeamAgent.Store.close_table(:my_dets_table)
  """
  @spec close_table(table_name()) :: :ok
  defdelegate close_table(table), to: :beam_agent_store_dets

  @doc """
  Flush pending writes for a DETS table to disk.

  Also flushes any in-memory atomic counter values before syncing.

  ## Example

      :ok = BeamAgent.Store.sync_table(:my_dets_table)
  """
  @spec sync_table(table_name()) :: :ok
  defdelegate sync_table(table), to: :beam_agent_store_dets

  @doc """
  Flush in-memory atomic counter values back to their DETS records.

  No-op when `atomic_counters` is not enabled or no counters have been
  incremented for `table`. After flushing, tracking entries are removed
  so the next `update_counter` re-seeds from DETS.

  Called automatically by `close_table/1` and `sync_table/1`.

  ## Example

      :ok = BeamAgent.Store.flush_counters(:my_dets_table)
  """
  @spec flush_counters(table_name()) :: :ok
  defdelegate flush_counters(table), to: :beam_agent_store_dets

  @doc """
  Resolve the data directory from DETS store options.

  Returns the directory path where `.dets` files are stored.
  Defaults to `"beam_agent_data"` when no `data_dir` is configured.

  ## Examples

      "beam_agent_data" = BeamAgent.Store.data_dir(%{})
      "/var/data" = BeamAgent.Store.data_dir(%{data_dir: "/var/data"})
  """
  @spec data_dir(store_options()) :: charlist()
  defdelegate data_dir(store_opts), to: :beam_agent_store_dets
end
