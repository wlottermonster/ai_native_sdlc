# Framework Doctor Implementation Plan

Goal: a working manual doctor for both harnesses and workspace projects.
Architecture: shared inspection CLI plus installation metadata helper.
Tech stack: Python 3.12 standard library, existing shell/Make test gates.
Spec: requirements.md and design.md.

- [x] T1 REQ-DOCTOR-001 REQ-DOCTOR-003 REQ-DOCTOR-004 REQ-DOCTOR-005 REQ-DOCTOR-006: Implement core/doctor.py and tests/codex/test_doctor.py. Red tests for read-only inspection, nested discovery, contract failure, version/source drift, stale/failed receipts and timeout; then implement and run green.
- [x] T2 REQ-DOCTOR-002: Implement core/installation.py plus tests/codex/test_installation_receipt.py; integrate both installers. Test missing/modified files, deterministic fingerprints, no secret contents, install/reinstall parity in fake homes.
- [x] T3 REQ-DOCTOR-006: Add ./doctor and docs, run actual workspace inspection, full gates and independent review, integrate without reverting parallel loop work, install and snapshot settings.

Review focus: symlinks, corrupt/forged receipts, shared hooks, unavailable clients,
unchanged failed results, test-side mutation, timeout child processes and output
redaction. CLI flags are bounded; a doctor pass cannot imply latest upstream or
live protection. No automatic upgrades or scheduled jobs.
