:ok = :beam_agent.init(%{table_access: :hardened})

# Seed the credential encryption key for tests.
# Replicates beam_agent_credential:do_derive(beam_agent_test_cookie)
# so that protect/unprotect work without Erlang distribution.
#
# Why duplicated here: cookie_to_key/1 and do_derive/1 are only exported
# under -ifdef(TEST) in the Erlang source. Mix compiles the dependency
# with the default rebar3 profile (not test), so those functions are
# unavailable from Elixir tests. This derivation must stay in sync with
# the KDF constants in beam_agent_credential.erl.
kdf_salt = "beam_agent_credential_v1"
kdf_info = "aes-256-gcm-key"
ikm = Atom.to_string(:beam_agent_test_cookie)
prk = :crypto.mac(:hmac, :sha256, kdf_salt, ikm)
key = :crypto.mac(:hmac, :sha256, prk, kdf_info <> <<1>>)
:persistent_term.put(:beam_agent_credential, key)

ExUnit.start()
