# Backend Conformance Proof Inventory

This directory holds the documentation/conformance proof artifacts for the
current truth reset.

Current inventory:

- `beam_agent_docs_conformance_tests.erl`
  - verifies README, matrix, and plan docs reference the remaining-work truth
    source and proof inventory
  - verifies CI truth gates reject stale completion claims

Current status:

- the directory contains truthful-doc conformance checks for the current
  baseline
- they are not completion proof on their own
- per-backend semantic proof still needs to deepen before the backend matrices
  can be promoted to a completed state
