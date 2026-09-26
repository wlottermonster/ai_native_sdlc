# Tasks — engine-map

<!-- Checkbox states are the ONLY execution state:
     [ ] open   [~] claimed/in progress   [x] done   [!] parked
     Each implementer run gets ONE task (its 1-5 REQ-IDs), re-read fresh.
     EVERY task also writes its assertions into tests/ (tests/test_engines.sh for
     content, tests/test_apply_engines.sh for behaviour), each assertion carrying
     its REQ-ID literally — Gate B greps the ID inside files under tests/.
     T0 first: without it the installer tests cannot see templates/. -->

- [x] T0: extend `install_fixture` in tests/lib.sh to copy `templates/` and `agents/*.conf`, and widen the scrub fence's file list to `agents/*.conf` and `settings/*.json`    [REQ-ENGINE-031] (branch: sdlc/engine-map-T0)
- [x] T1: `templates/sdlc-engines.conf` (four roles + `escalate`, one working model by default, primary + fallback, format comments) and `agents/roles.conf` (every shipped agent → exactly one role)    [REQ-ENGINE-005, REQ-ENGINE-006, REQ-ENGINE-009, REQ-ENGINE-039] (branch: sdlc/engine-map-T1)
- [x] T2: `scripts/apply-engines.sh` — parse map + manifest, validate ALL of it before writing anything, error paths, agent-less roles (`judge`, `escalate`) are no-ops    [REQ-ENGINE-014, REQ-ENGINE-027, REQ-ENGINE-029, REQ-ENGINE-042] (branch: sdlc/engine-map-T2)
- [x] T3: `scripts/apply-engines.sh` — rewrite only the `model:` line inside the leading frontmatter fence, byte-exact, atomic, with the awkward-file fixtures    [REQ-ENGINE-010, REQ-ENGINE-011, REQ-ENGINE-033, REQ-ENGINE-038] (branch: sdlc/engine-map-T3)
- [x] T4: `scripts/apply-engines.sh` — idempotence, reporting (`<agent>: <old> → <new>` + count), skip-and-report unlisted agents, manifest discovery    [REQ-ENGINE-012, REQ-ENGINE-013, REQ-ENGINE-028, REQ-ENGINE-030] (branch: sdlc/engine-map-T4)
- [x] T5: `install.sh` — create the map from the template only when absent, never overwrite, install `roles.conf`, run apply-engines and propagate its exit code    [REQ-ENGINE-007, REQ-ENGINE-008, REQ-ENGINE-015] (branch: sdlc/engine-map-T5)
- [x] T6: `hooks/session-engines.sh` — drain stdin, SessionStart JSON carrying the map, no-map case, no-jq case, never blocks    [REQ-ENGINE-016, REQ-ENGINE-017, REQ-ENGINE-034] (branch: sdlc/engine-map-T6)
- [x] T7: the injected instruction — one-line statement of the running model and its roles, and the explicit judge-mismatch note    [REQ-ENGINE-018, REQ-ENGINE-019] (branch: sdlc/engine-map-T7)
- [x] T8: `settings/hooks-snippet.json` SessionStart entry with matcher and timeout; install.sh closing instructions (new hook, the map, drop the stale command reference)    [REQ-ENGINE-020, REQ-ENGINE-035, REQ-ENGINE-021, REQ-ENGINE-026] (branch: sdlc/engine-map-T8)
- [x] T9: `sdlc-policy.md` — Role column, all phase rows kept, roles defined, the map named as the binding, `<phase> → <role>`    [REQ-ENGINE-001, REQ-ENGINE-002, REQ-ENGINE-003, REQ-ENGINE-004, REQ-ENGINE-036] (branch: sdlc/engine-map-T9)
- [x] T10: `sdlc-policy.md` — ordered fallback, announce once, owner-named model wins, no project-level model pin    [REQ-ENGINE-022, REQ-ENGINE-023] (branch: sdlc/engine-map-T10)
- [x] T10b: `sdlc-policy.md` — `escalate` as a lever: never automatic, owner-invoked, announced in the phase line, and offered by a session when a judgement is close or costly    [REQ-ENGINE-040, REQ-ENGINE-041] (branch: sdlc/engine-map-T10b)
- [x] T11: supersede the model-pinning claims of the shipped generic-core spec in place, and rewrite the assertions in tests/test_routing.sh and tests/test_auditor.sh to assert the role binding    [REQ-ENGINE-032] (branch: sdlc/engine-map-T11)
- [x] T12: docs — README "Project layer" gains the engine map; README and index.html stop naming a fixed model anywhere (crew, file map, legend, phase narration)    [REQ-ENGINE-024, REQ-ENGINE-025, REQ-ENGINE-037] (branch: sdlc/engine-map-T12)

## Gate 2 checklist (owner, not automatable)
- Run the handed-over script to merge the `SessionStart` entry into `~/.claude/settings.json`, then open `/hooks` or restart.
- Start a fresh session and confirm the first reply states the model in use and the roles it covers.
- Edit `~/.claude/sdlc-engines.conf`, re-run `scripts/apply-engines.sh`, and confirm the agents' `model:` lines followed.
