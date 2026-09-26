# Tasks — gate-fail-open-2

<!-- Each task lists the REQ-IDs it implements. The commit-gate assertions live
     in tests/test_gate_fail_open.sh and the push assertion in
     tests/test_push.sh, each with its REQ-ID literally, for Gate B. -->

- [x] T1: `index_only` whitelist in `hooks/check-gate.sh`; the docs-only shortcut only when it holds    [REQ-GATE-014]
- [x] T2: `run_req_gate` — every non-zero exit is a block with req-gate's output; missing req-gate blocks    [REQ-GATE-015, REQ-GATE-016]
- [x] T3: the docs-only shortcut still runs the requirement gate, and never make    [REQ-GATE-017]
- [x] T4: `push.sh` runs `publish.sh --install-guard` before every push    [REQ-GATE-018]
- [x] T5: sibling sweep — unreadable feature dir / requirements.md / tasks.md in `hooks/req-gate.sh`, unreadable package.json in `hooks/check-gate.sh`    [REQ-GATE-019, REQ-GATE-020]
- [x] T6: existing gate fixtures install req-gate.sh in their throwaway HOME; one rule in CLAUDE.md
