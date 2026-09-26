---
description: Run only the spec stage — write requirements/design/tasks for a feature in this repo, get them adversarially reviewed, present the digest for Gate 1
---
Run the AI-Native SDLC spec stage for: $ARGUMENTS

Scope: phases 1–3 only. No code is written.

1. **Spec (you, main session).** Brainstorm with the owner if the ask is vague.
   Then write, INSIDE THE CURRENT REPO, `specs/<feature>/requirements.md`
   (EARS form, permanent REQ-<FEATURE>-NNN IDs, a `verify:` tier per ID),
   `design.md` (irreversible actions called out), and `tasks.md` (every task
   lists its REQ-IDs, 1-5 per task). Respect the repo's TEST_PROFILE.
2. **Spec review.** Spawn the `spec-reviewer` agent; apply accepted findings;
   run `~/.claude/hooks/req-gate.sh --report` and fix Gate A misses.
3. **GATE 1 — present IN CHAT in decision-first format** (Decision Protocol in
   sdlc-policy.md): TL;DR + numbers first; then ONLY what needs the owner's
   judgment (judgment calls, irreversible actions, deferrals — or "nothing
   controversial"); then assumed defaults, one line each; the full requirement
   list LAST as optional reading. Open questions one at a time — plain
   sentence, concrete example, recommendation first — never a dumped list.
   During the interview (step 1) the same rule applies: one question at a
   time, with a recommended answer the owner can just accept.
   Apply requested edits and re-present. Stop after approval — building
   happens via /build.
