# Requirements — three-touch-points-phase-1

<!-- Phase 1 of the "three touch points" plan (docs/sdlc-review-2026-10-26.md,
     sections 10 and 13; approach B, owner decisions 1 to 5). Scope: one
     machine-owned state file and one evidence file per feature, a Gate 1 stamp
     the gates require, a warn-then-deny guard mechanism, the Stop gate's loop
     cap and evidence check, defects D1 to D5, and the engine-map mod re-probe.
     IDs are permanent. TEST_PROFILE here is lib: tiers are unit, integration
     or deferred; no e2e.
     Vocabulary: a "checkbox line" of tasks.md is a line starting `- [` plus its
     indented continuation lines up to the next checkbox line. The "evidence
     tree" of a commit or working tree is its git tree with
     specs/<feature>/state.json and specs/<feature>/evidence.json removed. -->

## A. The state file and the script that owns it (`scripts/sdlc-state.sh`)

REQ-TOUCH-001  WHEN `sdlc-state.sh init <feature>` runs in a repository holding
               `specs/<feature>/requirements.md`, THE SCRIPT SHALL write
               `specs/<feature>/state.json` listing every REQ-ID of that file
               with its `verify:` tier and `passes: false`, with no Gate 1 stamp,
               and with a `digest` field over the rest of the document.
               verify: unit

REQ-TOUCH-002  WHEN any gate or subcommand reads a `state.json` or
               `evidence.json` whose `digest` does not match its body, THE READER
               SHALL treat the file as invalid, say so naming the file, and never
               take it as a stamp or as evidence.
               verify: unit

REQ-TOUCH-003  WHEN `sdlc-state.sh stamp <feature>` runs, THE SCRIPT SHALL record
               `gate1.approved_at` (current time) and `gate1.spec_sha` (sha256 of
               `requirements.md`), add any REQ-ID new since `init` with
               `passes: false`, and leave every existing `passes` value as it was.
               verify: unit

REQ-TOUCH-004  WHEN `requirements.md` differs from the file the stamp was taken on
               (its sha256 is not `gate1.spec_sha`), THE READERS of the stamp
               (`status`, the commit guard) SHALL report the stamp as STALE and
               treat it as absent.
               verify: unit

REQ-TOUCH-005  WHEN `sdlc-state.sh evidence <feature>` runs, THE SCRIPT SHALL run
               the repository's check contract and then its test contract (the
               same resolution the gates use: Makefile targets, else
               `npm run check`/`test`, else `.venv/bin/pytest`), record each exit
               code and duration with HEAD, branch, time and the evidence tree
               of the working tree in `specs/<feature>/evidence.json`, and exit
               non-zero when either run did not exit 0 or no contract was found.
               verify: integration

REQ-TOUCH-006  WHEN an evidence run ends with both exit codes 0, THE SCRIPT SHALL
               set `passes: true` in `state.json` for exactly the REQ-IDs that
               `req-gate.sh --report` labels `OK` in that run and `false` for
               every other ID, and no other subcommand SHALL write `passes`.
               verify: unit

REQ-TOUCH-007  WHEN `sdlc-state.sh record <feature> <verifier|ui-tester>
               <PASS|FAIL|COULD-NOT-TEST> "<note>"` runs against current
               evidence, THE SCRIPT SHALL store that verdict, note and time under
               the named lane in `evidence.json` and recompute the digest.
               verify: unit

REQ-TOUCH-008  WHEN `sdlc-state.sh status` runs, THE SCRIPT SHALL print one line
               per `specs/<feature>/` (skipping `_`-prefixed directories) carrying
               the stamp state (none | stale | the approval date), the task
               counts (open, claimed, parked, done), the evidence state (none |
               invalid | stale | red | green) and the verifier and ui-tester
               verdicts (or none), reading `evidence.json` from the working tree
               and, when absent there, from the `sdlc/<feature>` ref.
               verify: unit

REQ-TOUCH-009  WHEN a subcommand cannot complete (not a git repository, the feature
               directory or its files unreadable, the target not writable), THE
               SCRIPT SHALL exit non-zero naming the path and SHALL leave the
               target file as it was (every write is temp file then rename).
               verify: unit

REQ-TOUCH-043  WHEN `record` runs and `evidence.json` is missing, invalid, or its
               evidence tree is not the working tree's evidence tree, THE SCRIPT
               SHALL refuse with a named reason and write nothing.
               verify: unit

REQ-TOUCH-044  WHEN evidence is compared for freshness (at Stop, at merge, in
               `status`), THE COMPARISON SHALL use evidence trees, so committing
               `state.json` and `evidence.json` themselves never makes evidence
               stale.
               verify: unit

## B. Guards that warn first, then deny (owner decision 2)

REQ-TOUCH-010  WHEN a guard evaluates and the guards directory
               (`SDLC_GUARDS_DIR`, default `~/.claude/sdlc-guards/`) does not
               exist at all, THE GUARD SHALL create it, seed `<guard>.since` with
               the current epoch time, and evaluate in warn mode.
               verify: unit

REQ-TOUCH-011  WHEN a guard would refuse and fewer than 14 days have passed since
               its `.since` time, THE GUARD SHALL allow, print the complete
               refusal text prefixed with `WARN` and the date denial begins, and
               append one line (time, repository, branch, reason) to
               `<guard>.log`.
               verify: unit

REQ-TOUCH-012  WHEN 14 days or more have passed since `.since`, or
               `SDLC_GUARD_MODE=deny` is set, THE GUARD SHALL refuse (exit 2) with
               the same text.
               verify: unit

REQ-TOUCH-013  WHEN the guards directory cannot be created or written, THE GUARD
               SHALL evaluate in deny mode and say why: a guard that cannot
               record its clock gets no grace window.
               verify: unit

REQ-TOUCH-014  WHEN a guard allows in warn mode from a PreToolUse hook, THE HOOK
               SHALL print one JSON document whose only decision field is
               `hookSpecificOutput.additionalContext` carrying the warning (never
               `permissionDecision`), with any requirement-gate text merged into
               it, so the warning reaches the model and no permission is granted.
               verify: unit

REQ-TOUCH-045  WHEN `SDLC_GUARD_MODE=warn` is set, THE GUARD SHALL stay in warn
               mode whatever the clock says.
               verify: unit

REQ-TOUCH-046  WHEN the guards directory exists and `<guard>.since` is missing,
               not a number, or in the future, THE GUARD SHALL evaluate in deny
               mode and name the file: a grace window cannot be restarted by
               deleting or editing its clock.
               verify: unit

REQ-TOUCH-047  WHEN `hooks/guard-lib.sh` cannot be sourced by `check-gate.sh` or
               `dod.sh`, THE HOOK SHALL exit 2 naming the library, never continue
               to an allow.
               verify: unit

## C. The commit gate (`hooks/check-gate.sh`)

REQ-TOUCH-015  WHEN a commit runs on a branch `sdlc/<x>` and `<x>` resolves to a
               feature (the longest `specs/<feature>/` name, `_`-prefixed
               excluded, that equals `<x>` or is a prefix of `<x>` followed by
               `-`), THE COMMIT GATE SHALL require a valid, non-stale Gate 1 stamp
               for that feature through the guard `gate1-stamp`, evaluated
               before the docs-only shortcut.
               verify: unit

REQ-TOUCH-016  WHEN the branch is not under `sdlc/`, or is `sdlc/hunt-*` or
               `sdlc/rca-*`, THE COMMIT GATE SHALL not evaluate the stamp guard;
               WHEN any other `sdlc/<x>` resolves to no feature, THE GUARD SHALL
               refuse under its mode naming the branch.
               verify: unit

REQ-TOUCH-017  WHEN a command of the merge family (`git merge`, `git pull`, `git
               rebase`, `git reset`) names a ref under `sdlc/` (`sdlc/<f>`,
               `sdlc/<f>-<task>`, `origin/sdlc/…`, `refs/heads/sdlc/…`) and the
               branch the command lands on is the repository's default branch
               (`origin/HEAD`, else `main`, else `master`), THE COMMIT GATE SHALL
               require current green evidence for the resolved feature (a valid
               `evidence.json` whose evidence tree equals the named ref's
               evidence tree and whose check and test exit codes are 0) through
               the guard `evidence-merge`.
               verify: unit

REQ-TOUCH-018  WHEN the merge guard cannot resolve the named ref's tree, cannot
               read the feature's evidence, or cannot resolve the feature, THE
               COMMIT GATE SHALL treat it as a refusal under the guard's mode,
               never as an allow.
               verify: unit

REQ-TOUCH-048  WHEN the command carries a `git checkout` or `git switch` before
               the commit or merge, THE COMMIT GATE SHALL decide on the branch
               that command lands on: a literal target is followed; a target it
               cannot parse is a refusal under the guard's mode.
               verify: unit

REQ-TOUCH-049  WHEN the command is neither commit-shaped nor merge-family nor a
               branch change followed by one of those, THE COMMIT GATE SHALL
               leave it alone as today.
               verify: unit

## D. The Stop gate (`hooks/dod.sh`)

REQ-TOUCH-019  WHEN the Stop payload carries `stop_hook_active: true`, THE STOP
               GATE SHALL run its checks again instead of allowing the stop
               unconditionally.
               verify: unit

REQ-TOUCH-020  WHEN the Stop gate has refused `SDLC_STOP_BLOCK_CAP` (default 6,
               below the client's own cap of 8) consecutive times for one
               session key (the payload's `session_id`, else `unknown`), IT SHALL
               allow the next stop, print that the tree is UNVERIFIED and the
               cap was reached, and log it.
               verify: unit

REQ-TOUCH-021  WHEN the session stops on a branch `sdlc/<feature>` (exactly a
               feature name) whose `tasks.md` has no `[ ]`, `[~]` or `[!]` box,
               and `evidence.json` is missing, invalid, red, or its evidence tree
               is not the working tree's, THE STOP GATE SHALL refuse through the
               guard `stop-evidence`, naming the command that produces evidence,
               evaluated before the clean-tree and docs-only allows.
               verify: unit

REQ-TOUCH-022  WHEN `tasks.md` still has an open, claimed or parked box, or the
               branch is not exactly a feature branch, THE STOP GATE SHALL not
               evaluate the evidence guard.
               verify: unit

REQ-TOUCH-050  WHEN the Stop gate exits 0 by any path, THE BLOCK COUNT for that
               session key SHALL be reset to zero (one exit trap, not one reset
               per allow).
               verify: unit

## E. Installation

REQ-TOUCH-023  WHEN `install.sh` runs, IT SHALL create the guards directory and
               seed a `.since` file for each guard that has none, leaving
               existing `.since` and `.log` files untouched.
               verify: unit

REQ-TOUCH-051  WHEN the test suite runs, EVERY test that runs a hook SHALL point
               `SDLC_GUARDS_DIR` at a throwaway directory (set once in
               `tests/lib.sh`), so no test reads or mutates the owner's guard
               clocks.
               verify: unit

## F. Defects D1 to D3

REQ-TOUCH-024  WHEN `agents/spec-reviewer.md` is read, ITS `tools:` line SHALL
               include `Bash`, so the `req-gate.sh --report` its prompt asks for
               can run.
               verify: unit

REQ-TOUCH-025  WHEN a REQ-ID is cited by at least one checkbox line of `tasks.md`
               and every checkbox line citing it is `[x]`, GATE B SHALL require a
               tagged test for that ID even while other tasks are open, claimed
               or parked.
               verify: unit

REQ-TOUCH-026  WHEN a REQ-ID is cited by no checkbox line of `tasks.md`, GATE B
               SHALL apply to it only when the file has no `[ ]`, `[~]` or `[!]`
               box, and `--report` SHALL label it `UNTASKED`.
               verify: unit

REQ-TOUCH-027  WHEN a REQ-ID is cited by a `[!]` line, `--report` SHALL label it
               `PARKED` and GATE B SHALL not block on it.
               verify: unit

REQ-TOUCH-028  WHEN `commands/ship.md` is read, IT SHALL instruct the session to
               run `sdlc-state.sh status` as ground truth and to walk no branch
               whose evidence is not current and green.
               verify: unit

REQ-TOUCH-029  WHEN `commands/build.md` is read, IT SHALL instruct the session to
               build no feature whose stamp is missing or stale (an unstamped
               in-flight feature is offered to the owner at the stamp prompt,
               once, never stamped silently), and to run `sdlc-state.sh
               evidence` as the LAST step of the wrap-up, after the code-review
               fixes, followed by `record` of the verifier's verdict (and the
               ui-tester's in a webapp repository).
               verify: unit

REQ-TOUCH-030  WHEN `commands/spec.md` is read, IT SHALL instruct the session to
               run `sdlc-state.sh init` once the three files are written, to run
               `sdlc-state.sh stamp` only after the owner's explicit approval at
               Gate 1, never before it, and to commit the spec and the stamp
               before any `/build`.
               verify: unit

REQ-TOUCH-052  WHEN `commands/ship.md` is read, IT SHALL instruct the session, in
               a repository whose `TEST_PROFILE` is `webapp` and whose evidence
               carries no ui-tester verdict, to dispatch `ui-tester` and record
               its verdict before the walk.
               verify: unit

## G. Defect D4: `/hunt` survives compaction

REQ-TOUCH-031  WHEN `commands/hunt.md` is read, the section "What it must never
               do" and the stop-reason list with its `STOPPED: <reason>` rule
               SHALL both end within the first 16,000 bytes of the file.
               verify: unit

REQ-TOUCH-032  WHEN the reordered `hunt.md` is read, each of its sections A to H
               SHALL be present exactly once under its own heading, and every
               sentence `tests/test_hunt.sh` pins SHALL still be present.
               verify: unit

## H. Defect D5: re-injection after compaction

REQ-TOUCH-033  WHEN the hooks snippet is read, the routing re-injection script
               SHALL be registered under the event the client documents for
               post-compaction context (a `SessionStart` entry whose matcher
               covers `compact`), and no `PostCompact` entry SHALL remain.
               verify: unit

REQ-TOUCH-034  WHEN the re-injection script runs on a payload whose `source` is
               `compact`, IT SHALL emit `hookSpecificOutput.hookEventName`
               `SessionStart` with the routing section as `additionalContext`,
               keeping the shipped fallbacks (no heading, no file, no jq, large
               payload).
               verify: unit

REQ-TOUCH-035  WHEN the session-engines entry's matcher is read, IT SHALL still
               exclude `compact`, so the engine map is not re-announced on every
               compaction.
               verify: unit

REQ-TOUCH-036  WHEN a real session on the installed client compacts, the routing
               heading SHALL be present in the context afterwards (observed once
               at Gate 2 on the installed build; the suite cannot compact a
               session).
               verify: deferred

## I. Engine-map mod re-probe on the installed build

REQ-TOUCH-037  WHEN the mod's `turn.start` hook receives an event carrying an
               `agentId`, IT SHALL pass the event on untouched and not set the
               status line.
               verify: unit

REQ-TOUCH-038  WHEN `scripts/mod-check.sh validate` and `scripts/mod-check.sh
               test` run on the installed build with its regenerated type
               declarations, BOTH SHALL pass.
               verify: integration

REQ-TOUCH-039  WHEN the re-probe is done, design.md SHALL carry a "Re-probe
               record" section with the build id and one entry under each of
               these headings: `agent.spawn` on resume, `turn.start` for subagent
               turns, `tool.check` throwing with and without `.catch`, the
               per-hook budget.
               verify: unit

## J. Documentation

REQ-TOUCH-040  WHEN `ARCHITECTURE.md`, `AGENTS.md`, `README.md`, `install.sh`'s
               messages and the snippet's top-level note are read, THEY SHALL
               describe the state file, the evidence file, the three guards with
               their warn window and the post-compaction entry, and SHALL make no
               `PostCompact` claim.
               verify: unit

## K. The stamp is the owner's (the one mechanical human gate the client offers)

REQ-TOUCH-041  WHEN the hooks snippet is read, ITS `permissions.ask` list SHALL
               carry a rule matching the `sdlc-state.sh stamp` command and a rule
               for `Edit`/`Write` on `specs/*/state.json`.
               verify: unit

REQ-TOUCH-042  WHEN `merge-settings.sh` merges a snippet carrying
               `permissions.ask`, `allow` or `deny` lists into settings that
               already have them, IT SHALL add the snippet's missing strings and
               keep every existing one, never dropping either side.
               verify: unit

REQ-TOUCH-053  WHEN `sdlc-state.sh stamp` runs, IT SHALL print the feature, the
               requirement count and the spec sha before writing, so a permission
               prompt on the command shows what is being approved.
               verify: unit
