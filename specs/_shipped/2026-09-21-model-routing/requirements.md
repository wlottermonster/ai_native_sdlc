# Global Codex model routing

User approved the preceding role/model proposal. Claude changes are recommendation
only in this task; no Claude routing settings are changed.

- REQ-ROUTE-001: Bind global Codex roles to the approved model and reasoning pairs; projects remain role-based and existing main-session model stays unchanged.
- REQ-ROUTE-002: Generate native global agent definitions from one central map, preserving instructions and unrelated fields. Install transactionally with backups; existing owner maps remain unchanged unless explicitly migrated.
- REQ-ROUTE-003: Validate routing shape and compare installed agent assignments in doctor. Invalid or mismatched settings are unhealthy; static validation never claims live model availability or selection.
- REQ-ROUTE-004: Escalation requires explicit owner instruction; no silent fallback. Independent verification uses a fresh agent when available. Simple edits need not launch every role.
  - traceability: "no silent fallback" and "only the escalation agent routes to escalate" are tested in tests/codex/test_routing.py (REQ-ROUTE-004). The owner-instruction, fresh-agent and simple-edit clauses are instructions to the agent, not code paths; they are verified by reading adapters/codex/policy.md (stage-specific agents) and adapters/codex/agents/escalation.toml, not by a test.
- REQ-ROUTE-005: Test installation, preservation, idempotence, malformed maps and drift; record live probe results or their limits. Document Claude recommendation separately.
  - traceability: the tested half is tagged REQ-ROUTE-005 in tests/codex/test_routing.py; install-level preservation and idempotence are also exercised by the REQ_ROUTE_002 tests and test_dry_run_and_idempotence in tests/codex/test_install.py, left untagged because docs/portability-step5/source-disposition.json pins that file's hash. The probe limits are recorded in adapters/codex/README.md (routing section) and the Claude recommendation in claude-recommendation.md beside this file; both are documents, verified by reading.
