---
description: Gate 2 — compute the ship digest from ground truth and walk ship decisions, one explicit yes per branch
---
Run the AI-Native SDLC ship review. Scope/args: $ARGUMENTS

Compute everything fresh from ground truth — never from a stored report or
memory of past sessions:

1. Read every `specs/*/tasks.md` in the current repo: `[x]` done (with
   branches), `[!]` parked (with their `> parked:` diagnoses), `[~]` stale
   claims (flag these — a crashed run may have left them), `[ ]` still open.
2. Run `~/.claude/hooks/req-gate.sh --report` and
   `~/.claude/scripts/trace-matrix.sh`; list `sdlc/*` branches
   (`git branch --list 'sdlc/*'`).
3. Present IN CHAT using the decision-first format (see the Decision Protocol
   in sdlc-policy.md): TL;DR first, then ONLY what needs the owner's judgment —
   assumptions recorded during the build (from design.md "## Assumptions"),
   verifier notes, amber/red matrix rows, parked items with options. Full
   detail last, as optional reading.
4. Walk decisions ONE AT A TIME, each with a concrete example of its effect
   and a recommendation stated first. For each branch the owner explicitly
   approves: merge to the main branch and run the checks once more. Push ONLY
   on an explicit yes — push = deploy on the repos the repo's CLAUDE.md names.
   Never batch-assume: one yes per branch.
5. **Archive on ship.** When every task of a feature is merged and shipped:
   `mkdir -p specs/_shipped && git mv specs/<feature> "specs/_shipped/$(date +%Y-%m-%d)-<feature>"` and
   distill any lasting decisions from its design.md into the project's decision log
   (the `decision log:` path its CLAUDE.md declares, else CLAUDE.md itself — the
   same rule /rca follows). The gates and matrix only scan `specs/*/` — shipped specs stop being tracked
   but stay greppable for the orphan-drift check and in git history.
6. **Worktree hygiene.** For each merged branch: `git worktree remove <path>`
   then `git branch -d sdlc/<...>` (never bare `rm -rf` — it orphans git
   metadata). Finish with `git worktree prune`.
