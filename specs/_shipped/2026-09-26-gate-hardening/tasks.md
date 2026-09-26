# Tasks — gate-hardening

<!-- Each task lists the REQ-IDs it implements. Every assertion lives in
     tests/test_gate_hardening.sh with its REQ-ID literally, for Gate B. -->

- [x] T1: port the heredoc stripping, fix the word match, expand a home-relative `cd` in `hooks/check-gate.sh`    [REQ-GATE-001, REQ-GATE-002, REQ-GATE-003, REQ-GATE-010]
- [x] T2: the gate's own clock in `hooks/check-gate.sh` and `hooks/dod.sh` — read the entry's timeout, kill the process group, refuse    [REQ-GATE-004, REQ-GATE-005]
- [x] T3: the hooks snippet and the Makefile templates    [REQ-GATE-006]
- [x] T4: `scripts/check-command-refs.sh`    [REQ-GATE-007]
- [x] T5: README Known-gaps entry, layout and project layer; the policy's no-bare-yes/no line    [REQ-GATE-008, REQ-GATE-009]

## Gate 2 checklist (owner, not automatable)

- Re-run `install.sh`, open `/hooks`, confirm the commit gate and the
  definition-of-done check are listed with a 600 timeout.
- Set a repo's `make check` to sleep past the budget once and watch the commit
  refused with the budget message, then put it back.
- [x] T6: review findings — no-jq refusal, shell-fed heredocs kept, quote after commit, line continuation, last-cd-before-commit, bare $HOME, prose-by-extension, unreadable Makefile in both gates, captured output on a missing exit code    [REQ-GATE-011, REQ-GATE-012, REQ-GATE-013]
