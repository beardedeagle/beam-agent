:ok = :beam_agent.init(%{table_access: :hardened})

# Seed the credential encryption key for tests.
# Replicates beam_agent_credential:do_derive(beam_agent_test_cookie)
# so that protect/unprotect work without Erlang distribution.
kdf_salt = "beam_agent_credential_v1"
kdf_info = "aes-256-gcm-key"
ikm = Atom.to_string(:beam_agent_test_cookie)
prk = :crypto.mac(:hmac, :sha256, kdf_salt, ikm)
key = :crypto.mac(:hmac, :sha256, prk, kdf_info <> <<1>>)
:persistent_term.put(:beam_agent_credential, key)

ExUnit.start()
