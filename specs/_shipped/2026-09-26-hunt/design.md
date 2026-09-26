# Design — hunt

## Approach

`/hunt` is a **prompt file**, not a script: `commands/hunt.md`, installed globally
by `install.sh` alongside the other six. That is the whole implementation surface.
It is **self-driving**: it runs its own rounds and stops itself, and depends on no
external scheduler to end it (REQ-HUNT-035).
Everything it needs already exists in the framework — the Makefile contract, four
agents, the `protected paths:` / `tracker:` / `decision log:` declarations, the
`/rca` flywheel, the routing policy's fan-out and kill rules. This feature adds no
script, no hook, no settings change.

The command answers the one question no existing command asks:

| Command | Question |
|---|---|
| `/hunt` | **Does the code still hold?** Goes looking. Fixes what it can prove. |
| `/test-audit` | Do the tests still mean anything? Read-only, informs, never edits. |
| `/rca` | This ONE bug is known — how do I make its class extinct? |
| `/build` | This spec is approved — execute it. |

Two properties are preconditions rather than features, and the design is shaped
around them:

**1. State, because a hunt without memory re-finds its own findings.**
`specs/_hunt/HUNT.md` carries the area matrix, the SEEN list and the current
round. It is written at the end of every round, so a fresh `/loop` invocation —
which may arrive with an empty context — resumes rather than restarts
(REQ-HUNT-008, REQ-HUNT-010). The `_hunt` name follows the `_shipped` / `_audit`
convention; mechanically it is already safe, because `req-gate.sh` iterates
`specs/*/requirements.md` and a directory without one is never matched.

**2. Refutation, because a hunt that believes itself fills a tracker with noise.**
Every candidate goes to `evidence` to be REPRODUCED; a candidate that cannot be
reproduced is recorded REFUTED, and the main session judges refutation from the
returned evidence (REQ-HUNT-015). This is the framework's artifacts-not-claims
rule applied where it matters most: an unattended loop with nobody reading over
its shoulder.

Spec review corrected the agent here. `verifier` looked like the obvious choice
and is the wrong one: it is `isolation: worktree` and opens by checking out *the
branch under review*, then diffing against base. A bare bug candidate gives it
neither branch nor diff. `evidence` is the reproduce-or-fail agent, carries the
same `verify` role, and needs no routing change.

**3. The run must not trust the harness to have checked anything.** `make check`
runs via a PreToolUse commit hook with a timeout, and a PreToolUse hook FAILS
OPEN — a hook that times out does not block. In a repo whose suite exceeds the
timeout, every commit passes ungated while looking gated. So the run executes
`make check` itself and records the exit code as its evidence (REQ-HUNT-026).
Absence of a block is not proof of a pass.

### The round

    resume state  →  next TODO areas from the matrix
                  →  researcher sweeps for candidates        [read]
                  →  dedupe against SEEN by path + key
                  →  evidence tries to REPRODUCE each        [verify]
                  →  main session judges refutation          [judge]
                  →  classify: FIXABLE / REPORT-ONLY / NEEDS-OWNER
                  →  implementer fixes FIXABLE, test first   [build]
                  →  make check (run and read the exit code)
                  →  /rca per confirmed finding
                  →  re-open matrix rows the fix touched
                  →  make check green at END of round, tree clean
                  →  write matrix + SEEN + convergence line
                  →  dry / floor / ceiling / budget / red / kill?
                       → verdict + STOPPED: line, or round N+1

Lane-to-role bindings are the framework's existing ones, so the engine map alone
decides what runs each lane and this command names no model (REQ-HUNT-014,
REQ-HUNT-015, REQ-HUNT-025).

### Convergence

Computed and written, never felt (REQ-HUNT-030). The count is confirmed FIXABLE
findings for the round; NEEDS-OWNER and REPORT-ONLY are excluded because they are
the owner's queue and would otherwise keep a converged loop running forever
(REQ-HUNT-032). The time floor is computed ONCE and compared against thereafter
(REQ-HUNT-033) — re-deriving it per round makes it trivially true for a run
started earlier in the day and ends the hunt after a single pass.

## Components touched

| File | Change |
|---|---|
| `commands/hunt.md` | **New.** The whole feature. |
| `README.md` | Commands list gains `hunt.md`; one line distinguishing it from `/test-audit` and `/rca`. |
| `ainative_sdlc.html` | Control-panel table gains a `/hunt` row; same distinction. |
| `tests/test_hunt.sh` | **New.** Content assertions, one per REQ-ID. |

`install.sh` needs no change: it globs `commands/*.md`. `sdlc-policy.md` needs no
change: every lane binds to a role the routing table already defines.

## Data / API changes

One new file format, `specs/_hunt/HUNT.md`, created in the target repo by the
command rather than shipped as a template — a template would be a second copy of
a format the command already has to describe, and the framework has just spent a
review removing second copies. Three sections: AREA MATRIX, SEEN, CURRENT ROUND
(REQ-HUNT-007), plus a FINDINGS section used only when the repo declares no
tracker (REQ-HUNT-024).

## Irreversible actions (must be surfaced at Gate 1)

- **The command edits source and commits.** It is the second command after
  `/build` that writes code unattended. It is bounded by: a hunt branch, never
  the default branch (REQ-HUNT-003); `make check` green before every commit
  (REQ-HUNT-026); protected paths never edited (REQ-HUNT-021); and
  an explicit prohibition list (REQ-HUNT-039).
- **It never pushes, deploys or merges.** Everything it produces stops at a local
  branch for the owner to review at Gate 2.
- **It files into the repo's tracker**, which for a GitHub tracker means issues
  created unattended. Bounded by a per-run cap and a search-before-filing rule
  (REQ-HUNT-024); a repo that does not want it at all declares no `tracker:` and
  gets findings in the state file and the verdict instead.
- **It takes a run lock** in the state file and may take over a stale one
  (REQ-HUNT-047, REQ-HUNT-048). A takeover is named in the verdict.
- Nothing here is a migration, a deletion, or a deploy.

## Assumptions

These are the defaults the build will use where the requirements say "a stated
default". They are written here BEFORE the build rather than discovered during
it, so the owner overrules by speaking up rather than by reading a diff.

| Knob | Default | Why, and how to reverse |
|---|---|---|
| `floor:` | 2 hours | Long enough for several rounds on a repo with a ~1min suite. Pass `floor: 30m` for a short run. |
| `ceiling:` | 6 hours | A hard spend limit; nothing in the loop otherwise stops. Also defines when a run lock goes stale. |
| `fixes:` | 5 per round | At a ~1min suite that is ~5 minutes of gate per round. Repos with slower suites should pass a lower number. |
| Matrix seed | one row per top-level git-tracked source dir, excluding vendored/generated/dependency paths, capped at 20 with the rest folded into `other` | Keeps the row count — which is the cost model — bounded on a monorepo. Correct the matrix by hand; the run reports what it seeded. |
| Rows per round | 3 | Matches the lane cap, so one round is one full fan-out. |
| Lane cap | 3 | The policy says "max 3-5" and `/build` says "max 3"; the tighter number wins, and the command states it literally rather than pointing at a range. |
| Branch | `sdlc/hunt-<YYYY-MM-DD>` | One branch per day's hunt, matching `/build`'s `sdlc/` prefix. |
| SEEN archive | entries older than 10 rounds | Keeps the searched region small without ever deleting a verdict. |
| Tracker cap | 20 items per run | 
**Build-time assumption (recorded per the mid-build rule, not asked).** T1-T16 all
write into ONE file and are strictly sequential, so dispatching sixteen separate
worktree implementers would mean sixteen serial merges to assemble a single prompt
file — and a document written in sixteen disjoint slices by sixteen agents reads
like one. They are therefore built in THREE implementer runs on one branch, each
taking a contiguous, coherent part of the document: A+B (preconditions and state),
C+D+E (the round, classification, fixing), F+G+H plus docs (stopping, verdict,
prohibitions). Each run still re-reads its REQ-IDs verbatim, writes its assertions
into tests/test_hunt.sh carrying the IDs literally, and must show a green
`make check`. Reverse by splitting any run back into its constituent tasks — the
task list and its REQ-ID mapping are unchanged. An overnight run should not be able to open a hundred issues. |

## Decisions & rejected alternatives

- **Self-driving, not loop-driven.** The command was first specified to be
  stopped by `/loop`. That is wrong in two ways: `/loop` is a harness built-in
  the framework does not own, and in its fixed-interval form the command cannot
  stop it at all — a converged hunt would wake forever. So `/hunt` runs its own
  rounds, writes `STOPPED: <reason>`, and answers a later re-invocation by
  reporting that reason and doing nothing. An external scheduler remains a
  convenience, never a dependency.
- **Worktrees, not a shared branch with path-limited commits.** The first draft
  invented lane coexistence rules — path-limited commits, copy-to-scratch. The
  framework already solved this with
  worktrees (`/build`, and the `worktree` key in the hooks snippet). Inventing a
  strictly weaker isolation model in a new command needs an argument, and there
  isn't one.
- **One global command, not a copy per repo.** Several copies of the same rules
  is a known drift class. A repo that
  genuinely needs more can shadow `/hunt` with its own — the collision rule makes
  that a deliberate, warned-about choice.
- **The command loops internally AND is resumable.** Either alone is worse:
  internal-only breaks when `/loop` restarts it with a fresh context;
  resume-only makes `/hunt` useless when run by hand.
- **The matrix is seeded from the repo, not asked for.** An unattended command
  that opens with a question is not unattended. It seeds, then says what it
  seeded so the owner can correct it (REQ-HUNT-009).
- **No `sdlc-policy.md` routing row added.** The lanes reuse rows that exist. A
  new row would restate the binding in a second place.
- **`/rca` is invoked, not restated.** The first draft copied the flywheel's
  discipline and the protected-path rules into `hunt.md`. Those rules already
  live in `commands/rca.md` and are already proved by `tests/test_rca.sh`; a
  second copy is the same drift class. `/hunt` now points at them.
- **`/hunt` does not run `/test-audit`.** A hunt could compose a suite audit as
  its last phase; here the two stay separate commands the owner can compose with `/loop`, because a generic hunt
  has no way to know a repo's audit is cheap enough to run every night.
- **Rejected: making the state file a shipped template.** The command must
  describe the format anyway; a template would be the second copy.
