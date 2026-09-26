# Interactive Handoff Implementation Plan

Goal: original bidirectional interactive transfer and acknowledged handback.
Architecture: shared state store + runtime adapters + thin native skills.
Tech stack: Python 3.12 standard library and supported local client CLIs.
Spec: requirements.md and design.md in this directory.

- [x] T1 REQ-HAND-001 REQ-HAND-003 REQ-HAND-004 REQ-HAND-005 REQ-HAND-006: Store with red/green tests for both-direction lifecycles, exact identity,
  stale snapshots, immutable briefing, double accept, concurrent prepare, refusal
  of symlinks, interrupted state and cleanup limited to closed-owned payloads.
  Files core/handoff_store.py and tests/codex/test_handoff_store.py.
- [x] T2 REQ-HAND-002 REQ-HAND-007 REQ-HAND-008: Runtime routing/launch CLI with red/green tests for model/effort defaults,
  explicit overrides, unsafe argument text, unavailable binaries, exact resume
  identity, manual fallbacks and no success from launch alone. Files
  core/handoff_runtime.py, core/handoff.py, tests/codex/test_handoff_runtime.py.
- [x] T3 REQ-HAND-007: Original handoff/handback skills, installer receipts and fake-home tests,
  docs and doctor inventory. Preserve existing global preferences and source.
- [x] T4 REQ-HAND-008: Independent review, local gates, bounded native receiver
  smoke checks where quotas allow, and global installation. Final canonical gate
  results are recorded by doctor; backup results are kept in the local completion record.
- [x] Native acceptance, both receivers: Codex accepted with its real thread UUID
  (earlier bounded smoke); Claude accepted on 2026-09-26 with the launch-bound
  `--session-id`, the id the client itself reported back, on the map's `opus`
  model, recorded progress, returned and handed back; fixture source ack and
  cleanup closed the package with the fixture unchanged. Bounded headless smoke
  in a disposable fixture with an explicit state dir; receipt
  `.sdlc-openai/native-claude-receiver.json`.
- [ ] Deferred live certification: the interactive Terminal/app roundtrip with a
  real owner clarification remains unverified. It needs the owner at the keyboard
  and is explicitly not inferred from the headless receiver smokes above.

Review focus: stale dirty changes; same checkout concurrent preparation; explicit
session ID cannot be discovered; native launch succeeds but receiver never reads;
return delivery interrupted; cleanup must keep recovery and unrelated artifacts.
All failures must leave actionable state, not green completion.
