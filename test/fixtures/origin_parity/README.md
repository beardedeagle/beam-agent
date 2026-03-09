# Origin Parity Fixtures

This directory contains the human-readable parity records used by the current
truth-reset tests and CI truth gates.

Current contents:

- `canonical_capability_parity.md`
  - capability-to-proof index for the current canonical baseline
- `gemini_acp_parity.md`
  - Gemini-specific baseline record for the ACP backend

These documents are referenced by:

- `test/contract/beam_agent_capability_contract_tests.erl`
- `test/contract/beam_agent_truth_contract_tests.erl`
- `test/conformance/beam_agent_docs_conformance_tests.erl`

They are not completion proof on their own. They point to the current proof
surface and gap state.
