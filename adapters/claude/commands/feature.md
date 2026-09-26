---
description: Run a feature through the full AI-Native SDLC pipeline (spec → gates → build → verify → review)
---
Run the AI-Native SDLC pipeline for: $ARGUMENTS

Follow these phases in order. Announce each phase transition in one line.

1. **Spec (you, main session).** Brainstorm with the owner if the ask is vague
   (superpowers:brainstorming). Then write `specs/<feature>/requirements.md`
   (EARS form, permanent REQ-<FEATURE>-NNN IDs, a `verify:` tier per ID —
   unit | integration | e2e | deferred), `design.md` (call out anything
   irreversible), and `tasks.md` (every task lists the REQ-IDs it implements;
   1-5 IDs per task). Respect the repo's TEST_PROFILE: never assign
   `verify: e2e` in a lib/api repo.
2. **Spec review.** Spawn the `spec-reviewer` agent on the three files. Apply
   accepted findings. Run `~/.claude/hooks/req-gate.sh --report` and fix any
   Gate A misses.
3. **GATE 1 — present IN CHAT in decision-first format** (Decision Protocol in
   sdlc-policy.md). Order: (a) TL;DR — one sentence + one line of numbers
   (N requirements, M tasks, est. time, risk); (b) "Needs your judgment" —
   ONLY judgment calls, irreversible actions, and deferrals (omit the section
   if nothing qualifies — say "nothing controversial"); (c) assumed defaults,
   one line each; (d) the full requirement list LAST, as optional reading.
   Open questions are asked one at a time — plain sentence, concrete example,
   recommendation first — never as a dumped list. The files are the record;
   the chat is the review. Do not proceed without an explicit yes.
4. **Implement.** For each task in `tasks.md`, spawn the `implementer` agent
   with ONLY that task's REQ-IDs, quoting them verbatim from requirements.md
   (re-read the file first — never from memory). Sequential by default;
   parallel only for independent tasks, max 3. Tests must contain their REQ-ID
   (marker or test name). Check off tasks as they complete. Kill rule: 3 failed
   attempts on the same error → park the task with a note, move on.
5. **Verify.** Run `make check` and `make test` yourself in the main session.
   Spawn the `verifier` agent for fresh-eyes verification. For webapp repos
   with e2e requirements, spawn `ui-tester` on the EARS scenarios.
6. **Review.** Read the full diff yourself. Run /code-review --fix so accepted
   findings are applied; re-run checks after.
7. **Report.** Present GATE 2 exactly as /ship does: decision-first digest
   (TL;DR → needs-your-judgment: assumptions to ratify, verifier notes,
   amber/red matrix rows, parked items → detail last), one decision at a time
   with a recommendation first. Merge/push only on the owner's explicit yes —
   never push unprompted. After a feature is fully shipped, archive its spec
   (`mkdir -p specs/_shipped && git mv specs/<feature> "specs/_shipped/$(date +%Y-%m-%d)-<feature>"`) and
   clean worktrees (`git worktree remove` + `git branch -d`, then
   `git worktree prune`).
