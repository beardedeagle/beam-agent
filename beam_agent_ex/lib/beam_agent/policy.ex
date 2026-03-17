defmodule BeamAgent.Policy do
  @moduledoc """
  Canonical BeamAgent policy profiles and deterministic evaluation.

  Policy profiles provide reusable allow/deny decisions for approvals,
  commands, backend selection, routines, memory writes, compaction, and
  orchestration.

  Profiles are stored documents with a default decision, ordered rules, and
  optional metadata. Evaluation is deterministic and deny-wins, so multiple
  domains can share the same policy vocabulary without introducing custom
  callback trees in each subsystem.
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

  @spec put_profile(binary(), map()) ::
          :ok
          | {:error,
             {:invalid_default
              | :invalid_match
              | :invalid_profile
              | :invalid_reason
              | :invalid_rule_action
              | :unsupported_profile_key
              | :unsupported_rule_key, term()}}
  defdelegate put_profile(profile_id, profile), to: :beam_agent_policy

  @spec get_profile(binary()) :: {:ok, profile()} | {:error, :not_found}
  defdelegate get_profile(profile_id), to: :beam_agent_policy

  @spec list_profiles() :: {:ok, [profile()]}
  defdelegate list_profiles(), to: :beam_agent_policy

  @spec evaluate(nil, action(), map()) :: :allow
  def evaluate(nil, action, context), do: :beam_agent_policy.evaluate(:undefined, action, context)

  @spec evaluate(binary(), action(), map()) :: :allow | {:deny, binary()}
  defdelegate evaluate(profile_id, action, context), to: :beam_agent_policy
end
