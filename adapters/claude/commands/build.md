---
description: Execute approved work (phases 4-8) — a named feature, or with no arguments the whole approved queue, unattended-safe
---
Run the AI-Native SDLC build stage. Scope/args: $ARGUMENTS

Scope: if $ARGUMENTS names a feature, build that feature's open tasks. With no
arguments, work the WHOLE queue: every unchecked task across `specs/*/tasks.md`
(or `prd.json` if present), in file order, until the queue is empty. Building
never needs the owner present — gates pause only at Gate 1 (already passed)
and Gate 2 (/ship). If no approved spec exists, say so and suggest /spec —
never invent requirements.

1. **Claim before work.** Mark a task `[~]` before starting so a concurrent
   session never doubles it; restore `[ ]` if abandoned.
2. **One task at a time, one worktree branch per task** (`sdlc/<feature>-<task>`).
   Spawn the `implementer` agent with ONLY that task's REQ-IDs, re-read
   verbatim from requirements.md. Tests carry their REQ-IDs. Sequential by
   default; parallel only for independent tasks, max 3.
3. **Task-local evidence before check-off**: targeted tests green + REQ-IDs in
   tests → mark `[x]`, append `(branch: sdlc/<...>)`, commit on the worktree branch.
   This means the task is implemented, not that the assembled feature
   passed its final gate. The commit hook still runs independently; never treat
   a non-blocking hook as proof of a passing check. NEVER push. NEVER merge to main.
4. **Land the task.** A finished task's worktree branch is
   merged back onto the FEATURE branch (`sdlc/<feature>`) —
   `git merge --no-ff sdlc/<feature>-<task>` run from the feature branch, once
   that task's targeted tests are green — and the worktree is then removed.
   Two worktrees cannot hold the same branch, so a task never commits onto the
   feature branch directly; merging back is how its commits arrive there, and a
   task left unmerged is work the next task cannot build on.
   This lands worktree branch → feature branch and nothing else:
   still NEVER push, and still NEVER merge to main.
   Only /ship (Gate 2) takes a feature branch further.
5. **Questions that arise mid-build**: do NOT interrupt the owner. Make the
   safest reversible choice, record it in the feature's design.md under
   `## Assumptions` (one line: what was assumed, why, how to reverse), and
   continue. Only a blocking, irreversible decision stops work — park the task
   `[!]` with the question in its `> parked:` line instead of guessing.
6. **Kill rule**: 3 failed attempts on the same error → mark `[!]` with a
   `> parked: <one-line diagnosis> (branch: ...)` line, move on.
7. **Stop on empty queue.** Never invent work.
8. **Wrap up**: the coordinating session runs `make check` and `make test` on the
   stable tree after all task branches are assembled, and records both exit codes.
   If the tree changes, re-run the affected full checks. Then use a fresh-eyes
   `verifier` (and `ui-tester` for webapp e2e), followed by /code-review with
   fixes applied and checks re-run. Present the build summary
   in chat (matrix, branches, parked items, assumptions made). Gate 2 happens
   via /ship — never push.
