defmodule BeamAgent.Memory do
  @moduledoc """
  Canonical long-term memory for BeamAgent.

  Memories are durable cross-session facts and notes that can be scoped to
  sessions, threads, or runs, linked to artifacts and other typed references,
  and recalled later using lexical search. This is the Elixir facade over the
  Erlang `:beam_agent_memory` public module.
  """

  @typedoc """
  Scope passed to `remember/2,3` and `recall/2`.

  Use either a binary session id or a map containing any of
  `:session_id`, `:thread_id`, and `:run_id`.
  """
  @type scope() ::
          binary()
          | %{
              optional(:session_id) => binary(),
              optional(:thread_id) => binary(),
              optional(:run_id) => binary()
            }

  @typedoc """
  Typed source reference stored on a memory.
  """
  @type source_ref() :: %{
          required(:type) => atom() | binary(),
          required(:id) => binary(),
          optional(:metadata) => map()
        }

  @typedoc """
  Input accepted by `remember/2,3`.
  """
  @type memory_input() ::
          binary()
          | %{
              optional(:memory_id) => binary(),
              optional(:kind) => atom() | binary(),
              optional(:content) => term(),
              optional(:attributes) => map(),
              optional(:source_refs) => [source_ref()],
              optional(:ttl) => non_neg_integer() | :infinity,
              optional(:pinned) => boolean(),
              optional(:salience) => non_neg_integer(),
              optional(:session_id) => binary(),
              optional(:thread_id) => binary(),
              optional(:run_id) => binary()
            }

  @typedoc """
  Exact-match filter accepted by `list/1`, `search/2`, and `expire/1`.
  """
  @type memory_filter() :: %{
          optional(:memory_id) => binary(),
          optional(:kind) => atom() | binary(),
          optional(:session_id) => binary(),
          optional(:thread_id) => binary(),
          optional(:run_id) => binary(),
          optional(:pinned) => boolean(),
          optional(:source_ref_type) => atom() | binary(),
          optional(:source_ref_id) => binary(),
          optional(:limit) => pos_integer(),
          optional(:since) => integer(),
          optional(:include_expired) => boolean(),
          optional(:min_salience) => non_neg_integer(),
          optional(:before) => integer()
        }

  @typedoc """
  Canonical memory record.
  """
  @type memory_record() :: %{
          required(:memory_id) => binary(),
          required(:kind) => atom() | binary(),
          required(:content) => term(),
          required(:attributes) => map(),
          required(:source_refs) => [source_ref()],
          required(:scope) => map(),
          required(:pinned) => boolean(),
          required(:salience) => non_neg_integer(),
          required(:ttl) => non_neg_integer() | :infinity,
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          optional(:expires_at) => integer()
        }

  @doc """
  Ensure the memory store exists.
  """
  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_memory

  @doc """
  Clear all memories.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_memory

  @doc """
  Remember content with embedded or explicit kind on a scope.
  """
  @spec remember(scope(), memory_input()) :: {:ok, memory_record()} | {:error, term()}
  defdelegate remember(scope, memory_input), to: :beam_agent_memory

  @doc """
  Remember content with an explicit kind on a scope.
  """
  @spec remember(scope(), atom() | binary(), memory_input()) ::
          {:ok, memory_record()} | {:error, term()}
  defdelegate remember(scope, kind, memory_input), to: :beam_agent_memory

  @doc """
  Fetch a memory by id.
  """
  @spec get(binary()) :: {:ok, memory_record()} | {:error, :not_found}
  defdelegate get(memory_id), to: :beam_agent_memory

  @doc """
  List all visible memories.
  """
  @spec list() :: {:ok, [memory_record()]}
  defdelegate list(), to: :beam_agent_memory

  @doc """
  List memories with exact-match filters and visibility controls.
  """
  @spec list(memory_filter()) :: {:ok, [memory_record()]} | {:error, term()}
  defdelegate list(filter), to: :beam_agent_memory

  @doc """
  Recall memories for a scope using lexical search.
  """
  @spec recall(scope(), binary()) :: {:ok, [memory_record()]} | {:error, term()}
  defdelegate recall(scope, query), to: :beam_agent_memory

  @doc """
  Search memories across all scopes.
  """
  @spec search(binary()) :: {:ok, [memory_record()]} | {:error, term()}
  defdelegate search(query), to: :beam_agent_memory

  @doc """
  Search memories with a lexical query plus exact-match filters.
  """
  @spec search(binary(), memory_filter()) :: {:ok, [memory_record()]} | {:error, term()}
  defdelegate search(query, filter), to: :beam_agent_memory

  @doc """
  Forget a memory by id.
  """
  @spec forget(binary()) :: :ok | {:error, :not_found}
  defdelegate forget(memory_id), to: :beam_agent_memory

  @doc """
  Pin a memory.
  """
  @spec pin(binary()) :: :ok | {:error, :not_found}
  defdelegate pin(memory_id), to: :beam_agent_memory

  @doc """
  Unpin a memory.
  """
  @spec unpin(binary()) :: :ok | {:error, :not_found}
  defdelegate unpin(memory_id), to: :beam_agent_memory

  @doc """
  Expire all currently expired, unpinned memories.
  """
  @spec expire() :: {:ok, non_neg_integer()}
  defdelegate expire(), to: :beam_agent_memory

  @doc """
  Expire currently expired, unpinned memories matching a filter.
  """
  @spec expire(memory_filter()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate expire(filter), to: :beam_agent_memory
end
