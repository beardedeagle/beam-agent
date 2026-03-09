# Gemini ACP Parity Record

This document records the current Gemini baseline and gap state for the BeamAgent
canonical contract.

Current baseline:

- persistent multi-turn Gemini ACP session management via
  `src/backends/gemini/gemini_cli_session.erl`
- ACP wire normalization via
  `src/backends/gemini/beam_agent_gemini_wire.erl`
- Gemini message/event translation via
  `src/backends/gemini/beam_agent_gemini_translate.erl`
- reverse permission request mediation via
  `src/backends/gemini/beam_agent_gemini_reverse_requests.erl`
- participation in shared BeamAgent runtime, callback, attachment, and event
  pathways where universal layers currently provide the canonical surface

Verified by the current baseline proof inventory:

- `test/backends/gemini/gemini_cli_session_tests.erl`
- `test/backends/gemini/gemini_cli_protocol_tests.erl`
- `test/backends/gemini/prop_gemini_cli_protocol.erl`
- `test/public/beam_agent_fallback_tests.erl`
- `beam_agent_ex/test/wrappers/gemini_ex_test.exs`

Open truth constraints:

- this file is not completion proof on its own
- any current `full` projection for Gemini-backed canonical rows is still
  subordinate to the baseline/gap-state truth captured here
- broader universal parity still depends on repo-wide closure tracked in
  `BEAM_AGENT_UNIVERSAL_PARITY_REMAINING_WORK_SPEC.md`
- native Gemini UI, IDE, and other product-specific escape hatches remain out
  of canonical scope unless explicitly promoted
