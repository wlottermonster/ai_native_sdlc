# Tasks — hunt

<!-- Checkbox states are the ONLY execution state:
     [ ] open   [~] claimed/in progress   [x] done   [!] parked
     Each implementer run gets ONE task (its 1-5 REQ-IDs), re-read fresh.
     EVERY task also writes its assertions into tests/test_hunt.sh, each
     assertion carrying its REQ-ID literally — Gate B greps the ID inside files
     under tests/.

     SEQUENCING — T1 through T16 all write into ONE file, commands/hunt.md, and
     one test file. They are STRICTLY SEQUENTIAL: never dispatch two of them in
     parallel, whatever the fan-out limit allows. T17 (docs) is the only task
     that touches different files and may run alongside the tail of the others.

     BUILD HAZARD, T3/T4/T14 especially: the scrub fence over commands/*.md
     forbids any literal four-digit year, and these tasks describe timestamps.
     Use the <YYYY-MM-DD> idiom that commands/test-audit.md already uses. A
     literal date in an example fails `make check` immediately.

     The Gate 2 section below deliberately uses PLAIN bullets, not checkboxes:
     req-gate.sh suppresses Gate B while any `- [ ]` remains in this file, and
     owner-run items are never ticked by a build. -->

- [x] T1: `commands/hunt.md` — frontmatter with a one-line `description:`, and section A's core refusals (no contract, dirty tree, red baseline), each naming which precondition failed    [REQ-HUNT-057, REQ-HUNT-001, REQ-HUNT-002, REQ-HUNT-004, REQ-HUNT-005]    (run: sdlc/hunt, build run 1)
- [x] T2: section A — the branch contract (`sdlc/hunt-<YYYY-MM-DD>`, reuse the recorded branch, abort on disagreement, never the default branch), the requirement-gate precondition, and the `$ARGUMENTS` surface with its stated defaults    [REQ-HUNT-003, REQ-HUNT-055, REQ-HUNT-058]    (run: sdlc/hunt, build run 1)
- [x] T3: section B — `specs/_hunt/HUNT.md` named, why the gates never see it and the ban on a `requirements.md` there, its four parts, resume-don't-restart, the seeding rule, written every round    [REQ-HUNT-006, REQ-HUNT-007, REQ-HUNT-008, REQ-HUNT-009, REQ-HUNT-010]    (run: sdlc/hunt, build run 1)
- [x] T4: section B — the format-version line, the atomic write, and the stop-don't-re-seed path for a corrupt, hand-edited or older-version state file    [REQ-HUNT-051, REQ-HUNT-052]    (run: sdlc/hunt, build run 1)
- [x] T5: section B — SEEN: search never read end-to-end, the line format and the path-and-key dedupe match, the archive section, and never re-filing a candidate that already carries a verdict    [REQ-HUNT-011, REQ-HUNT-059, REQ-HUNT-060, REQ-HUNT-012]    (run: sdlc/hunt, build run 1)
- [x] T6: section B — the run lock, and the stale-lock takeover named in the verdict    [REQ-HUNT-047, REQ-HUNT-048]    (run: sdlc/hunt, build run 1)
- [x] T7: section C — the round: at most three not-done rows, `researcher` sweeps, `evidence` reproduces and the main session judges refutation, a finding recorded with path, line and observable behaviour    [REQ-HUNT-013, REQ-HUNT-014, REQ-HUNT-015, REQ-HUNT-016]    (run: sdlc/hunt, build run 2)
- [x] T8: section C — lane isolation: the cap of three enforced by the dispatching session, a worktree per fix lane, read-only sweep lanes may share a tree and never write to it    [REQ-HUNT-017, REQ-HUNT-018, REQ-HUNT-019]    (run: sdlc/hunt, build run 2)
- [x] T9: section D — exactly one of three classes, the three definitions verbatim, the protected paths `/rca` already reads, and NEEDS-OWNER never decided by the loop    [REQ-HUNT-020, REQ-HUNT-064, REQ-HUNT-021, REQ-HUNT-023]    (run: sdlc/hunt, build run 2)
- [x] T10: section D — filing: search the tracker before filing, the per-run cap, the no-tracker fallback, and NEEDS-OWNER delivered as ONE batch in decision-first format    [REQ-HUNT-024, REQ-HUNT-056]    (run: sdlc/hunt, build run 2)
- [x] T11: section E — `implementer` test-first, running `make check` ITSELF and recording the exit code (a hook that did not block is not evidence), `/rca` per confirmed finding, the kill rule, no weakened assertions    [REQ-HUNT-025, REQ-HUNT-026, REQ-HUNT-027, REQ-HUNT-028, REQ-HUNT-029]    (run: sdlc/hunt, build run 2)
- [x] T12: section E — findings past the fix budget recorded unfixed rather than dropped, matrix rows re-opened when a fix touches their files, and a clean tree at the end of every round    [REQ-HUNT-050, REQ-HUNT-053, REQ-HUNT-061]    (run: sdlc/hunt, build run 2)
- [x] T13: section F — the convergence line computed and written every round, DRY defined, the owner-queue classes excluded from the count    [REQ-HUNT-030, REQ-HUNT-031, REQ-HUNT-032]    (run: sdlc/hunt, build run 3)
- [x] T14: section F — the floor resolved once and never re-derived, the ceiling and fix budget with their named defaults, and a round that ends red    [REQ-HUNT-033, REQ-HUNT-049, REQ-HUNT-054]    (run: sdlc/hunt, build run 3)
- [x] T15: section F — the named stop-reason list, running rounds itself and writing `STOPPED: <reason>` as the last write, and the answer to a re-invocation after a stop    [REQ-HUNT-034, REQ-HUNT-035, REQ-HUNT-062]    (run: sdlc/hunt, build run 3)
- [x] T16: section G + H — the one verdict and its contents, SKIPPED never read as passed, a fixed-but-untested run is not green, and both halves of the prohibition list    [REQ-HUNT-036, REQ-HUNT-037, REQ-HUNT-038, REQ-HUNT-039, REQ-HUNT-063]    (run: sdlc/hunt, build run 3)
- [x] T17: docs — the `commands/` block in README's `## Layout`, the manual's control-panel row with the prose count corrected, and the three-way distinction from `/test-audit` and `/rca`    [REQ-HUNT-040, REQ-HUNT-041, REQ-HUNT-042]    (run: sdlc/hunt, build run 3)

## Fix round — from fresh-eyes verification (FAIL)

<!-- Same rule as T1-T16: one file, strictly sequential, never two in parallel. -->

- [x] T18: the resume deadlock — commit the state file as the last act of every round, and say in the clean-tree precondition that the run's own tracked state file is expected    [REQ-HUNT-065]    (run: sdlc/hunt, fix round)
- [x] T19: state-file shape — add the per-round convergence log and the `STOPPED:` line to the canonical shape in section B, so section F writes nothing section B has not declared    [REQ-HUNT-066]    (run: sdlc/hunt, fix round)
- [x] T20: reconcile refusals with stops — name the section A refusals, the unreadable-state stop, the lock conflict and the no-exit-code abort so "nothing else ends a run" is true; and tell the run how to commit a fix    [REQ-HUNT-067, REQ-HUNT-069]    (run: sdlc/hunt, fix round)
- [x] T21: only FIXABLE findings go through `/rca`'s fixing steps, naming the lane that runs it; and drop the false "the one `make check` already calls" parenthetical    [REQ-HUNT-068, REQ-HUNT-070]    (run: sdlc/hunt, fix round)
- [x] T22: harden the hollow assertions so deleting the clause they guard turns the suite red — REQ-HUNT-003 first (proven deletable with the suite green), then 004, 007, 024, 047, 048, 052, 055    [REQ-HUNT-071]    (run: sdlc/hunt, fix round)

## Residual round — disclosed by re-verification

- [x] T23: state-file completeness — the seed carve-out for every legitimately-absent section, the full SEEN line shape, and `areas:` in the recorded values    [REQ-HUNT-072, REQ-HUNT-073, REQ-HUNT-074]
- [x] T24: one vocabulary for a matrix row's two states, and a refusal enumeration that accounts for every path that ends an invocation    [REQ-HUNT-075, REQ-HUNT-076]
- [x] T25: document the merge-back step in `commands/build.md` so hunt.md's reference points at something real    [REQ-HUNT-077]

## Gate 2 checklist (owner, not automatable)

- REQ-HUNT-043 — OBSERVED in this repo. Round 1 completed: matrix seeded from `git ls-files` (8 rows), 5 candidates swept, 3 refuted on reading, 2 confirmed by an evidence lane, both fixed and committed, convergence row `| 1 | 2 |` written, `STOPPED: ceiling` recorded, state committed alone as `hunt(state): round 1`. All six named sections present throughout. Verdict below.
- REQ-HUNT-044 — OBSERVED. Both refusals fired and each named its precondition AND what it observed: on `main`, "precondition 3, current=main, the default branch"; on a dirty tree, "precondition 2, git status --porcelain printed 1 line". Neither touched anything.
- REQ-HUNT-062 — OBSERVED. With `STOPPED:` written, a re-invocation reports the recorded reason and does no work; SEEN and the convergence log survive intact (5 entries, row preserved), so the file resumes rather than restarts.
- REQ-HUNT-045 — PARTIAL. Resume-not-restart is shown above for a stopped run. NOT yet shown for a live multi-round run, which is the case that matters.
- REQ-HUNT-046 — NOT YET OBSERVED. Proving the floor is recorded once rather than re-derived needs a run that spans more than one round; this run stopped at the ceiling after one.
- ORIGINAL live-fire item, kept for reference: run `/hunt` in a repo with the contract (a repository with a fast suite is the cheapest baseline, one with a slower suite the most realistic). Confirm one round completes, `specs/_hunt/HUNT.md` appears with all its named sections, and the run ends with a verdict naming its stop reason.
- REQ-HUNT-044 — run it on a dirty tree, and again on the default branch. Each must refuse and name the precondition that failed.
- REQ-HUNT-045 — run it a second time in the same repo. Matrix rows already done must stay done, and no finding from the first run may be re-filed.
- REQ-HUNT-046 — let a run resume later the same day and confirm it still runs more than one round; a single-pass finish means the floor was re-derived rather than recorded.
- Confirm nothing was pushed and the default branch is untouched.
- OPEN, found during the fix round and not yet a requirement: section B calls a state file missing a named section unreadable, while `## FINDINGS` is described as used only when the repo declares no `tracker:`. Whether a tracker-having repo's file must still carry that heading is unresolved. If live-fire hits it, it earns a REQ-ID.
- [x] T27: project sweep lanes — the `hunt lanes:` declaration in commands/hunt.md    [REQ-HUNT-078]
- [x] T28: the tracker as kill switch — STOP or a removed approval label makes a tracked finding NEEDS-OWNER    [REQ-HUNT-079]
