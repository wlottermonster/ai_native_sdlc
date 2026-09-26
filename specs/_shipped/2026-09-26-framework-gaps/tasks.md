# Tasks — framework-gaps

<!-- Each implementer run gets ONE task. Every task writes its assertions into
     tests/test_gaps.sh with its REQ-ID literally, for Gate B.
     T2 and T3 touch different files and may run in parallel; T1 must land
     first because it creates the test file. -->

- [x] T1: README "Known gaps" — the fails-open entry, the rule that follows, and the CI entry pointing at the template; plus tests/test_gaps.sh    [REQ-GAP-001, REQ-GAP-002, REQ-GAP-011]
- [x] T6: move the budget out of the hook entry to the top-level comment, and tell the reader to run `/hooks` after merging    [REQ-GAP-003, REQ-GAP-012] (verification finding)
- [x] T2: the timeout budget where it will be seen — the hooks snippet comment and the same comment in all three Makefile templates    [REQ-GAP-003, REQ-GAP-004]
- [x] T3: `scripts/apply-engines.sh` — honour an agents directory from the environment, find that directory's own roles.conf, report and change nothing when it has none, and keep reading the map from its machine-level location    [REQ-GAP-005, REQ-GAP-006, REQ-GAP-007]
- [x] T4: README "Project layer" names the command for repo-local agents    [REQ-GAP-008]
- [x] T5: `templates/ci-check.yml` and its stated reason for running check not test    [REQ-GAP-009, REQ-GAP-010]
- [x] T7: class extinction from the live /hunt finding — `hooks/dod.sh` and `hooks/req-gate.sh` block instead of allowing when they cannot enter the repo root, and `scripts/apply-engines.sh` distinguishes present from readable    [REQ-GAP-013, REQ-GAP-014] (found by /hunt, swept by /rca)
- [x] T8: behavioural tests for the sibling gates — a mutant reintroducing a fail-open by any spelling turns the suite red, replacing the source-text greps that only tested one spelling    [REQ-GAP-015] (verification finding)
- [x] T9: give the templates-file-map assertion its own requirement, so a missing template reports the rule it actually broke    [REQ-GAP-016] (verification finding)

## Gate 2 checklist (owner, not automatable)

- Run the new apply-engines path against a repo that has its own agents and confirm their `model:` lines follow the map.
- Copy the CI template into one repo and confirm it goes green on a push.
