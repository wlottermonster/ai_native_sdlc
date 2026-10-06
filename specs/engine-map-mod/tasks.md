# Tasks — engine-map-mod

<!-- Checkbox states are the ONLY execution state:
     [ ] open   [~] claimed/in progress   [x] done   [!] parked
     Each implementer run gets ONE task (its 1-5 REQ-IDs), re-read fresh.
     Mod behaviour is proved in hooks/*.test.ts (run by `claude plugin test`),
     every test title carrying its REQ-ID literally; installer, gate and
     doctor behaviour in tests/test_mod.sh and tests/codex/test_doctor.py.
     T0 is OWNER-ATTENDED and runs first: T3 and the refusal half of T5 are
     written against what it records, and T1, T2, T4 proceed after it. -->

- [ ] T0 (owner-attended): live probe on this build with `--plugin-dir` against the real config, a throwaway skills folder for the auto-load question only. Record in design.md "T0 record": build version; auto-load with and without SKILL.md; a hook-set model observed in the spawn result; where and how a non-existent model id fails; does `turn.start` fire for subagent loops; does `/model` mid-session show at the next `turn.start`; does a refused `on()` throw or fail the load; do `claude plugin validate` and `test` run inside the check-gate hook environment without an auth or nested-session refusal; whether `CLAUDE_CODE_SUBAGENT_MODEL` outranks a hook-set model; message-set survival across reload and `/clear`    [REQ-MOD-012, REQ-MOD-030]
- [ ] T1: `tests/fixtures/engine-map/` cases with expected verdicts; `tests/test_apply_engines.sh` rewritten to run them; `hooks/map.ts` parser reaching the same verdicts, read fresh per call    [REQ-MOD-014, REQ-MOD-015]
- [ ] T2: `agent.spawn` routing — bound agent gets the role's entry in force; explicit differing model left alone and said once; forks, teammates, plugin agents and unbound names untouched; refused or missing files pass everything through with one notice; project manifest consulted first    [REQ-MOD-007, REQ-MOD-008, REQ-MOD-009, REQ-MOD-010, REQ-MOD-019]
- [ ] T3 (after T0): single `next` per dispatch and never `deny` as a property over every fixture; later-dispatch fallback down the chain and the exhausted-chain notice, written against the recorded failure shape    [REQ-MOD-021, REQ-MOD-011, REQ-MOD-013]
- [ ] T4: judge check on `session.start` and main-loop `turn.start` from the engine's own model report, the three-spelling match rule, the one-line status with fallbacks in force, the subagent-model variable notice    [REQ-MOD-016, REQ-MOD-017, REQ-MOD-020]
- [ ] T5: safety — `.catch` on every registration with both `called` branches and a clock-driven overrun; wrapped `register` recording refused events; message set in session state, identical message never repeated; event allow-list proven from the validate report, then the mutation step (add a `tool.call` registration, watch the suite go red, remove it)    [REQ-MOD-004, REQ-MOD-005, REQ-MOD-006, REQ-MOD-018]
- [ ] T6: install — mod folder under adapters/claude/skills with `.gitignore`; installer exclusion list; settings.json byte-identical across install    [REQ-MOD-001, REQ-MOD-025]
- [ ] T7: gate — `make check` runs `claude plugin validate`, `tests/test_mod.sh` runs `claude plugin test` and checks every test title, both under the explicit skip variable; README "Codex specifics" names the variable    [REQ-MOD-002, REQ-MOD-003, REQ-MOD-028, REQ-MOD-029]
- [ ] T8: doctor — one Python test proving the claude row names a missing or changed mod file through the existing managed-file check    [REQ-MOD-026]
- [ ] T9: policy and docs — adapters/claude/policy.md rendered into sdlc-policy.md; ARCHITECTURE routing paragraph; README file map with the apply-engines step kept; manual crew section in both languages; model-name pattern over the mod folder and touched docs; apply-engines, install.sh and session-engines.sh still exercised unchanged    [REQ-MOD-022, REQ-MOD-023, REQ-MOD-024, REQ-MOD-027]

## Gate 2 checklist (owner, not automatable)
- Start a fresh session and confirm the status line shows the map and `judge: <entry>`.
- Edit `~/.claude/sdlc-engines.conf`, dispatch a researcher, and confirm the transcript shows the new model without re-running apply-engines.
- Remove one file of the mod folder, run `./doctor`, and confirm the claude row names it; reinstall.
