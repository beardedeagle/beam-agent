defmodule BeamAgent.SensitiveKeys do
  @moduledoc """
  Single source of truth for sensitive key definitions.

  Every key that must be encrypted in credential storage, redacted from
  logs, or both is defined as a triple in the canonical registry. The
  credential and redaction modules derive their match lists from this
  module rather than maintaining separate, driftable lists.

  ## Triple Fields

  Each entry is `{canonical_name, category, handling}`:

  - `canonical_name` -- Erlang atom in `snake_case` (e.g., `:api_key`).
  - `category` -- Classification: `:credential`, `:auth`, `:session`, or `:oauth`.
  - `handling` -- Protection level:
    - `:encrypt_and_redact` -- Encrypted at rest AND redacted from logs.
    - `:redact_only` -- Redacted from logs only (not stored in credentials).

  ## Examples

      # Get all 18 sensitive key definitions
      BeamAgent.SensitiveKeys.all()

      # Check if a key is sensitive (any format)
      BeamAgent.SensitiveKeys.is_sensitive(:api_key)       # true
      BeamAgent.SensitiveKeys.is_sensitive("apiKey")        # true
      BeamAgent.SensitiveKeys.is_sensitive("username")      # false

  Delegates to `:beam_agent_redaction` (Erlang).
  """

  @doc "Return the canonical list of sensitive key triples."
  @spec all() :: [{atom(), atom(), atom()}]
  defdelegate all(), to: :beam_agent_redaction

  @doc """
  Flat list of all format variants for keys that require encryption.

  Each multi-word key produces three variants: the atom, a camelCase
  binary, and a snake_case binary. Single-word keys produce two.
  """
  @spec credential_match_keys() :: [atom() | binary()]
  defdelegate credential_match_keys(), to: :beam_agent_redaction

  @doc """
  Canonical lowercase binary keys (no separators) for all sensitive keys.
  """
  @spec redaction_match_keys() :: [binary()]
  defdelegate redaction_match_keys(), to: :beam_agent_redaction

  @doc """
  Check whether a key (atom or binary, any format) is sensitive.
  """
  @spec is_sensitive(atom() | binary()) :: boolean()
  defdelegate is_sensitive(key), to: :beam_agent_redaction
end
