defmodule BeamAgent.PolicyTest do
  use ExUnit.Case, async: false

  setup do
    :ok = :beam_agent_policy.clear()
    :ok
  end

  test "exports the canonical policy surface" do
    assert function_exported?(BeamAgent.Policy, :ensure_tables, 0)
    assert function_exported?(BeamAgent.Policy, :clear, 0)
    assert function_exported?(BeamAgent.Policy, :put_profile, 2)
    assert function_exported?(BeamAgent.Policy, :get_profile, 1)
    assert function_exported?(BeamAgent.Policy, :list_profiles, 0)
    assert function_exported?(BeamAgent.Policy, :evaluate, 3)
  end

  test "round-trips a profile and evaluates it" do
    assert :ok =
             BeamAgent.Policy.put_profile("ex-policy", %{
               default: :deny,
               rules: [
                 %{action: :backend, decision: :allow, match: {:eq, :backend, :gemini}}
               ]
             })

    assert {:ok, profile} = BeamAgent.Policy.get_profile("ex-policy")
    assert (profile[:profile_id] || profile["profile_id"]) == "ex-policy"
    assert :allow = BeamAgent.Policy.evaluate("ex-policy", :backend, %{backend: :gemini})
  end
end
