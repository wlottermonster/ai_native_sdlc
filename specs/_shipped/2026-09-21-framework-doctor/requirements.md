# Manual framework doctor

Approved: user's yes to the manual checker design. Initial deliverable covers
installation receipts, workspace inspection and explicit verification. Public
packaging/license selection and automated updates remain separate release work.

- REQ-DOCTOR-001: Default inspection is offline/read-only; it never changes project settings or executes project checks.
- REQ-DOCTOR-002: Both adapters install the same doctor and a versioned receipt with source revision and managed file hashes; preserve owner configuration.
- REQ-DOCTOR-003: Workspace discovery includes nested repositories and classifies missing contracts without silently enrolling or repairing them.
- REQ-DOCTOR-004: Verification is explicit, bounded by timeout, records actual outcomes and never saves command output or credentials. Distinguish tests from live harness compatibility.
- REQ-DOCTOR-005: Reuse evidence only for matching source/project/client fingerprints; prior failures remain failures until a new passing run; unavailable evidence is blocked/unverified.
- REQ-DOCTOR-006: Provide readable output and JSON, nonzero unhealthy status, documented manual commands, real regression tests and clean integration.
