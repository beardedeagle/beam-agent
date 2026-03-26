defmodule BeamAgent.Credential do
  @moduledoc """
  Cookie generation and credential encryption helpers.

  BeamAgent encrypts sensitive credential fields (API keys, tokens, secrets)
  at rest using AES-256-GCM with a key derived from the BEAM node cookie.
  This module exposes cookie generation so you can bootstrap a secure node
  without full distributed Erlang.

  ## Quick Setup

  Generate a secure cookie and set it on the node:

      cookie = BeamAgent.Credential.generate_cookie()
      Node.set_cookie(cookie)

  For production, persist the cookie in your release configuration:

    - **`rel/vm.args.eex`**: `-setcookie <%= release_cookie() %>`
    - **`config/runtime.exs`**: `Node.set_cookie(:<value>)`
    - **CLI flag**: `--cookie <value>`

  ## Why a cookie is needed

  Without a node cookie, `erlang:get_cookie/0` returns `:nocookie` — a
  publicly known atom. Deriving an encryption key from it would provide
  zero confidentiality. When no cookie is set, BeamAgent automatically
  generates a secure ephemeral cookie, applies it to the running node,
  and logs a warning with instructions for persisting it across restarts.

  ## Architecture

  Delegates to `:beam_agent_credential` (Erlang). The cookie is used solely
  as key material for HKDF-SHA256 derivation — you do **not** need
  distributed Erlang or clustering. A local cookie on a standalone node
  is sufficient.
  """

  @doc """
  Generate a cryptographically secure node cookie.

  Returns an atom suitable for `Node.set_cookie/1`. The cookie is 32 bytes
  of randomness encoded as URL-safe base64 (no padding), producing a
  43-character atom with 256 bits of entropy.

  ## Example

      cookie = BeamAgent.Credential.generate_cookie()
      Node.set_cookie(cookie)

  """
  @spec generate_cookie() :: atom()
  def generate_cookie do
    :beam_agent_credential.generate_cookie()
  end
end
