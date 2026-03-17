defmodule BeamAgent.Policy do
  @moduledoc """
  Canonical BeamAgent policy profiles and deterministic evaluation.

  Policy profiles provide reusable allow/deny decisions for approvals,
  commands, backend selection, routines, memory writes, compaction, and
  orchestration.
  """

  @type decision() :: :allow | :deny
  @type action() :: atom() | binary()
  @type key_path() :: atom() | binary() | [atom() | binary()]

  @type match_spec() ::
          :*
          | {:exists, key_path()}
          | {:eq, key_path(), term()}
          | {:member, key_path(), [term()]}
          | {:prefix, key_path(), binary()}
          | {:path_prefix, key_path(), binary()}

  @type profile_rule() :: %{
          required(:action) => action() | :*,
          required(:decision) => decision(),
          required(:match) => match_spec(),
          optional(:reason) => binary()
        }

  @type profile() :: %{
          required(:profile_id) => binary(),
          required(:default) => decision(),
          required(:metadata) => map(),
          required(:rules) => [profile_rule()],
          required(:created_at) => integer(),
          required(:updated_at) => integer()
        }

  @spec ensure_tables() :: :ok
  defdelegate ensure_tables(), to: :beam_agent_policy

  @spec clear() :: :ok
  defdelegate clear(), to: :beam_agent_policy

  @spec put_profile(binary(), map()) :: :ok | {:error, term()}
  defdelegate put_profile(profile_id, profile), to: :beam_agent_policy

  @spec get_profile(binary()) :: {:ok, profile()} | {:error, :not_found}
  defdelegate get_profile(profile_id), to: :beam_agent_policy

  @spec list_profiles() :: {:ok, [profile()]}
  defdelegate list_profiles(), to: :beam_agent_policy

  @spec evaluate(binary() | nil, action(), map()) :: :allow | {:deny, binary()}
  def evaluate(nil, action, context), do: :beam_agent_policy.evaluate(nil, action, context)
  defdelegate evaluate(profile_id, action, context), to: :beam_agent_policy
end
