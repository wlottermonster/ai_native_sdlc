#!/bin/bash
# AI-Native SDLC — content tests for commands/hunt.md, the unattended bug-hunt
# loop prompt.
#
# This file covers the FIRST HALF of the command — its frontmatter, section A
# (refusing to start) and section B (the state file):
#   REQ-HUNT-057  frontmatter with a one-line description
#   REQ-HUNT-001  no `check` target in a Makefile → abort
#   REQ-HUNT-002  dirty working tree → abort
#   REQ-HUNT-004  baseline `make check`, and a RED baseline is the whole job
#   REQ-HUNT-005  every abort names WHICH precondition failed
#   REQ-HUNT-003  the branch contract
#   REQ-HUNT-055  the requirement-coverage gate as a precondition
#   REQ-HUNT-058  the $ARGUMENTS surface and its stated defaults
#   REQ-HUNT-006  specs/_hunt/HUNT.md, and why the gates never see it
#   REQ-HUNT-007  the state file's parts
#   REQ-HUNT-008  resume, never restart
#   REQ-HUNT-009  the matrix seeding rule
#   REQ-HUNT-010  written at the end of every round
#   REQ-HUNT-051  format-version line, and the atomic write
#   REQ-HUNT-052  corrupt or unrecognised state → stop, never re-seed
#   REQ-HUNT-011  dedupe by SEARCHING SEEN, never reading it end to end
#   REQ-HUNT-059  the SEEN line format, and the path+key dedupe match
#   REQ-HUNT-060  the SEEN archive, and no entry is ever deleted
#   REQ-HUNT-012  a candidate with a verdict is never re-filed
#   REQ-HUNT-047  the run lock
#   REQ-HUNT-048  stale-lock takeover, named in the verdict
# ...and the MIDDLE of the command — sections C (the round and the refutation
# gate), D (classifying a finding) and E (fixing, and the flywheel):
#   REQ-HUNT-013  at most three `todo` area rows per round
#   REQ-HUNT-014  the sweep goes to `researcher`, whose role is `read`
#   REQ-HUNT-015  every fresh candidate goes to `evidence` to be REPRODUCED
#   REQ-HUNT-016  a finding carries path, line and the observable behaviour
#   REQ-HUNT-017  the lane cap of three, enforced by the dispatching session
#   REQ-HUNT-018  a worktree per fix lane, as `/build` does
#   REQ-HUNT-019  read-only sweep lanes may share a tree and never write to it
#   REQ-HUNT-020  exactly one of FIXABLE, REPORT-ONLY, NEEDS-OWNER
#   REQ-HUNT-064  the three class definitions, verbatim
#   REQ-HUNT-021  the same protected paths `/rca` reads
#   REQ-HUNT-023  the loop never decides a NEEDS-OWNER finding
#   REQ-HUNT-024  filing through `tracker:`, search first, capped, no-tracker path
#   REQ-HUNT-056  all NEEDS-OWNER findings as ONE batch, decision-first
#   REQ-HUNT-025  each FIXABLE to `implementer`, test first
#   REQ-HUNT-026  run `make check` ITSELF; a hook that did not block is no proof
#   REQ-HUNT-027  each confirmed finding goes through `/rca`, not a restatement
#   REQ-HUNT-028  the kill rule per finding, and the abandoned finding filed
#   REQ-HUNT-029  never weaken or delete an assertion to go green
#   REQ-HUNT-050  findings past the fix budget recorded unfixed, never dropped
#   REQ-HUNT-053  matrix rows re-opened when a committed fix touched their files
#   REQ-HUNT-061  every round ends with a clean tree, before the state write
# ...and the END of the command — sections F (convergence, the budget and
# stopping), G (the verdict) and H (what it must never do), plus the two
# discoverability documents:
#   REQ-HUNT-030  a convergence line computed and written every round
#   REQ-HUNT-031  DRY is that count being zero
#   REQ-HUNT-032  NEEDS-OWNER and REPORT-ONLY excluded from the count
#   REQ-HUNT-033  the time floor resolved ONCE, never re-derived per round
#   REQ-HUNT-049  the ceiling and the fix budget, with their named defaults
#   REQ-HUNT-054  `make check` green at the END of every round; red is a stop
#   REQ-HUNT-034  the named stop reasons, stated in the verdict
#   REQ-HUNT-035  runs its own rounds, writes `STOPPED: <reason>` last
#   REQ-HUNT-062  a re-invocation after a stop reports the reason, does nothing
#   REQ-HUNT-036  ONE verdict, and everything it carries
#   REQ-HUNT-037  a lane that could not run is SKIPPED, never passed
#   REQ-HUNT-038  fixed but untested is not a green run
#   REQ-HUNT-039  the prohibition list: push, deploy, merge, protected, owner
#   REQ-HUNT-063  ...and history, tests, other specs, settings and engine map
#   REQ-HUNT-040  README's `commands/` block lists hunt.md
#   REQ-HUNT-041  the manual's command table has a /hunt row, and the count
#   REQ-HUNT-042  hunt vs test-audit vs rca, in one line in each document
# ...and the FIX ROUND, from the fresh-eyes verification that returned FAIL —
# defects between sections, which no single-section assertion could catch:
#   REQ-HUNT-065  the state file is COMMITTED as the last act of every round
#   REQ-HUNT-066  section B declares every field section F writes into the file
#   REQ-HUNT-067  refusing to start is not stopping a run; the stop list is true
#   REQ-HUNT-068  only FIXABLE findings enter `/rca`, and the lane is named
#   REQ-HUNT-069  the run is told to commit a fix, and with what message
#   REQ-HUNT-070  no claim that `make check` calls the requirement gate
#   REQ-HUNT-071  the hardened assertions: deleting a clause turns this red
# ...and the RESIDUALS the re-verification disclosed and ranked below the
# findings that failed it — fixed here rather than carried as debt:
#   REQ-HUNT-072  a seed carve-out for every legitimately-absent section
#   REQ-HUNT-073  the SEEN line shape carries every field C, D and E write
#   REQ-HUNT-074  `areas:` recorded beside floor, ceiling and fix budget
#   REQ-HUNT-075  ONE vocabulary for a matrix row's two states
#   REQ-HUNT-076  a refusal enumeration that states no count it cannot keep
#   REQ-HUNT-077  build.md documents the merge-back hunt.md cites
#
# These are read-only assertions against the shipped prompt file; nothing here
# writes outside the repo.
#
# shellcheck disable=SC2016
# File-wide: every pattern here is literal prose lifted out of a Markdown
# prompt. Backticks are code spans in that prose and `$ARGUMENTS` is the
# harness placeholder the command names — both are content to be matched, never
# expansions, so single quotes are exactly right and SC2016 is noise.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

hunt="$repo/commands/hunt.md"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-hunt.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
req "REQ-HUNT-057"
assert_file "$hunt"
# Frontmatter first, carrying a one-line description — the same shape every
# other command in commands/ opens with.
assert_grep '^description: ' "$hunt"
assert_order "$hunt" \
  '^---$' \
  '^description: '

# The two sections this half of the command is made of, in order.
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-001"
# No `check` target in a Makefile: abort before any other work, with the
# reason stated — no contract means no baseline, and no baseline means the run
# cannot tell what it found from what was already broken.
assert_fgrep 'no `check` target in a Makefile' "$hunt"
assert_fgrep 'cannot tell a finding from a failure that was already there' "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'no .check. target in a Makefile' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-002"
# A dirty working tree aborts: hunting on top of a half-finished edit
# attributes someone else's change to this run.
assert_fgrep 'working tree is dirty' "$hunt"
assert_fgrep "attributes someone else's change to this run" "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'working tree is dirty' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-004"
# A baseline `make check` before the first round, and a RED baseline is the
# whole job of the run — fix it, report it, stop. Never hunt from a red tree.
assert_fgrep 'Run `make check` yourself and read its exit code before the first round' "$hunt"
assert_fgrep 'RED baseline' "$hunt"
assert_fgrep 'the whole job of the run' "$hunt"
assert_fgrep 'never a starting point to hunt from' "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'RED baseline' \
  'the whole job of the run' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-005"
# Every abort in section A names WHICH precondition failed, so an unattended
# run never ends in silence.
assert_fgrep 'which precondition failed' "$hunt"
assert_fgrep 'never ends in silence' "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'which precondition failed' \
  'never ends in silence' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-003"
# The branch contract: the dated hunt branch, reuse of the recorded branch,
# an abort when the recorded and current branches disagree, and a hard refusal
# to run on the default branch.
assert_fgrep 'sdlc/hunt-<YYYY-MM-DD>' "$hunt"
assert_fgrep 'reuse the branch recorded in the state file' "$hunt"
# The abort clause itself, not the word `disagree` — which recurs three more
# times in unrelated sentences, so the whole clause could be deleted with the
# suite still green (REQ-HUNT-071).
assert_fgrep 'When the recorded branch and the current branch disagree, abort and name both' "$hunt"
assert_fgrep 'you are either in the wrong checkout or another hunt owns this state' "$hunt"
assert_fgrep "the repository's default branch" "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'sdlc/hunt-<YYYY-MM-DD>' \
  'reuse the branch recorded in the state file' \
  "the repository's default branch" \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-055"
# The requirement-coverage gate runs as a precondition, an ALREADY-failing
# gate aborts the run, and the run may never edit a feature's specs/ to clear
# it — the gates are repo-global, so another feature's gap would block every
# commit this run makes.
assert_fgrep 'requirement-coverage gate' "$hunt"
assert_fgrep 'ALREADY failing' "$hunt"
# The whole prohibition, not the bare path token — which survives deleting the
# "Never edit" rule, since the same path appears in the sentences around it
# (REQ-HUNT-071).
assert_fgrep 'Never edit any `specs/<feature>/` directory — not a requirements file, not a tasks file, not a checkbox — to clear it' "$hunt"
assert_fgrep 'repo-global' "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'requirement-coverage gate' \
  'ALREADY failing' \
  'specs/<feature>/' \
  '^## B\. State — the hunt file$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-058"
# The $ARGUMENTS surface: four optional knobs, any order, each with the
# default it falls back to when absent.
assert_fgrep '$ARGUMENTS' "$hunt"
assert_fgrep 'all optional and in any order' "$hunt"
assert_fgrep 'floor: <duration>' "$hunt"
assert_fgrep 'ceiling: <duration>' "$hunt"
assert_fgrep 'fixes: <count>' "$hunt"
assert_fgrep 'areas: <names>' "$hunt"
# ...and the stated default for each.
assert_fgrep 'Default **2 hours**' "$hunt"
assert_fgrep 'Default **6 hours**' "$hunt"
assert_fgrep 'Default **5 findings per round**' "$hunt"
assert_fgrep 'Default **every row in the matrix**' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-006"
# The state file is named, the reason the requirement gates never see it is
# stated PRECISELY — they iterate `specs/*/requirements.md` and specs/_hunt/
# has none, NOT because of the leading underscore — and creating a
# requirements.md there is forbidden.
assert_fgrep 'specs/_hunt/HUNT.md' "$hunt"
assert_fgrep 'specs/*/requirements.md' "$hunt"
assert_fgrep 'contains no `requirements.md`' "$hunt"
assert_fgrep 'not because of the leading underscore' "$hunt"
assert_fgrep 'NEVER create a `requirements.md` under `specs/_hunt/`' "$hunt"
assert_order "$hunt" \
  '^## B\. State — the hunt file$' \
  'specs/\*/requirements\.md' \
  'not because of the leading underscore'

# ---------------------------------------------------------------------------
req "REQ-HUNT-007"
# The parts of the state file: the area matrix (a status per row), the SEEN
# list (a verdict per candidate ever judged), and the current round with the
# run's start time and its computed floor, ceiling and fix budget.
assert_grep '^## AREA MATRIX$' "$hunt"
assert_grep '^## SEEN$' "$hunt"
assert_grep '^## CURRENT ROUND$' "$hunt"
assert_fgrep 'one row per area' "$hunt"
assert_fgrep 'one line per candidate ever judged' "$hunt"
# The WHOLE description of `## CURRENT ROUND`, not a prefix truncated before
# "floor, ceiling and fix budget" — half the requirement was unasserted, so the
# budgets could drop out of the shape with the suite green (REQ-HUNT-071).
assert_fgrep "the round number, the run start time, and the run's resolved floor, ceiling, fix budget and areas, plus the branch and the run lock" "$hunt"
assert_order "$hunt" \
  '^## B\. State — the hunt file$' \
  '^## AREA MATRIX$' \
  '^## SEEN$' \
  '^## CURRENT ROUND$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-008"
# An existing state file is RESUMED, never replaced with a fresh matrix — a
# new invocation continues the same hunt.
assert_fgrep 'resume from it' "$hunt"
assert_fgrep 'never start a new matrix' "$hunt"
assert_fgrep 'continues the same hunt' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-009"
# Seeding: one row per top-level git-tracked source directory, vendored,
# generated and dependency paths excluded, capped, the remainder folded into
# one `other` row — and the rule and its exclusions recorded in the file.
assert_fgrep 'one row per top-level source directory tracked by git' "$hunt"
assert_fgrep 'vendored, generated and dependency paths' "$hunt"
assert_fgrep 'capped at 20 rows' "$hunt"
assert_fgrep 'folded into one `other` row' "$hunt"
assert_fgrep 'record the seeding rule used and what it excluded' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-010"
# The file is written at the END OF EVERY ROUND: a crash costs one round, not
# the whole hunt.
assert_fgrep 'end of EVERY round' "$hunt"
assert_fgrep 'loses one round rather than the whole hunt' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-051"
# A format-version line is the file's FIRST line, and every write is atomic:
# a temporary file in the same directory, then a rename.
assert_fgrep 'HUNT-FORMAT: 1' "$hunt"
assert_fgrep 'first line' "$hunt"
assert_fgrep 'atomically' "$hunt"
assert_fgrep 'temporary file in the same directory, then rename' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-052"
# A state file that exists but is missing a named section or carries an
# unrecognised version stops the run before hunting, and is NEVER overwritten
# or re-seeded — re-seeding discards SEEN and every old finding is re-filed.
# BOTH triggers on one line — the "missing a named section" half was unasserted
# and could be deleted with the suite green (REQ-HUNT-071).
assert_fgrep 'missing one of its named sections, or carries an unrecognised format version, stop before hunting' "$hunt"
assert_fgrep 'NEVER overwrite or re-seed it' "$hunt"
assert_fgrep 're-seeding discards SEEN' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-011"
# Dedupe SEARCHES the SEEN list; reading it end to end is forbidden, because
# the list grows without bound and the context does not.
assert_fgrep 'by SEARCHING it' "$hunt"
assert_fgrep 'Never read the SEEN list end to end' "$hunt"
assert_fgrep 'grows without bound and the context does not' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-059"
# The SEEN line format, and the dedupe match: path AND key together, because
# path alone collides two bugs in one file and drops the second in silence.
assert_fgrep '<path>:<line>' "$hunt"
assert_fgrep 'mechanism key' "$hunt"
assert_fgrep 'PATH AND KEY together' "$hunt"
assert_fgrep 'collides two different bugs in one file' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-060"
# Old entries are ARCHIVED inside the same file, dedupe still searches the
# archive, and a SEEN entry is never deleted.
assert_grep '^## SEEN \(archived\)$' "$hunt"
assert_fgrep 'older than 10 rounds' "$hunt"
assert_fgrep 'dedupe searches the archive too' "$hunt"
assert_fgrep 'Never delete a SEEN entry' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-012"
# A candidate that already carries a verdict is never re-filed — REFUTED
# included, or every run re-files everything the last run disproved.
assert_fgrep 'already carries a verdict in SEEN is never re-filed' "$hunt"
assert_fgrep 'judged REFUTED in an earlier round' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-047"
# The run is claimed with a RUN LOCK line carrying branch, start time and a
# run identifier, written before the first round; an unexpired lock naming a
# different run aborts.
assert_fgrep 'RUN LOCK:' "$hunt"
# What the lock line CARRIES was unasserted — only the words `run identifier`
# were, and those recur (REQ-HUNT-071).
assert_fgrep 'carrying the branch, the start time and a run identifier unique to this invocation' "$hunt"
assert_fgrep 'before the first round' "$hunt"
assert_fgrep 'unexpired lock naming a different run' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-048"
# A lock older than the recorded ceiling is stale, may be taken over, and the
# takeover is named in the verdict.
# The staleness rule as one clause — the bare word `stale` occurs five times
# elsewhere in the file and could not fail (REQ-HUNT-071).
assert_fgrep "A lock is stale once it is older than the run's recorded ceiling, and a stale lock may be taken over" "$hunt"
assert_fgrep 'name the takeover in the verdict' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-013"
# At most THREE `todo` rows per round: one row makes the hunt as long as the
# repo has areas, all of them is the whole-repo sweep this loop exists to avoid.
assert_grep '^## C\. The round, and the refutation gate$' "$hunt"
assert_fgrep 'AT MOST THREE area rows marked `todo`' "$hunt"
assert_fgrep 'as many rounds as the repo has areas' "$hunt"
assert_fgrep 'the whole-repo sweep this loop exists to avoid' "$hunt"
assert_order "$hunt" \
  '^## B\. State — the hunt file$' \
  '^## C\. The round, and the refutation gate$' \
  'AT MOST THREE area rows marked .todo.'

# ---------------------------------------------------------------------------
req "REQ-HUNT-014"
# The sweep — enumerating candidates in an area — goes to `researcher`, whose
# role is `read`, because the sweep is volume work and volume is what it costs.
assert_fgrep 'to the `researcher` agent' "$hunt"
assert_fgrep 'whose role is `read`' "$hunt"
assert_fgrep 'the sweep is volume work, and volume is what it costs' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-015"
# Every fresh candidate goes to `evidence` to be REPRODUCED; one that cannot be
# reproduced is recorded REFUTED; the MAIN SESSION judges refutation from the
# returned evidence. `verifier` is explicitly NOT the agent for this — it is
# worktree-isolated and opens on the branch under review, and a bare candidate
# gives it neither branch nor diff.
assert_fgrep 'to the `evidence` agent to be REPRODUCED' "$hunt"
assert_fgrep 'cannot be reproduced is recorded REFUTED' "$hunt"
assert_fgrep 'the main session judges refutation' "$hunt"
assert_fgrep 'The `verifier` agent is NOT used here' "$hunt"
assert_fgrep 'neither branch nor diff for a bare candidate' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-016"
# A finding is recorded with its file path and line, and the observable
# behaviour that makes it wrong.
assert_fgrep 'its file path and line' "$hunt"
assert_fgrep 'the observable behaviour that makes it wrong' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-017"
# Concurrent lanes are capped at THREE, and the cap is enforced by the
# dispatching main session — nothing else counts the lanes.
assert_fgrep 'Never run more than THREE lanes at once' "$hunt"
assert_fgrep 'the dispatching main session enforces the cap' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-018"
# Every fix lane gets its OWN WORKTREE, as `/build` does — the framework
# already solved lane isolation and this command invents nothing weaker.
assert_fgrep 'its own worktree, as `/build` does' "$hunt"
assert_fgrep 'rather than sharing one tree' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-019"
# Read-only sweep lanes may share one tree; no lane may write to it.
assert_fgrep 'Read-only sweep lanes may share a tree' "$hunt"
assert_fgrep 'no lane ever writes to a shared tree' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-020"
# Every confirmed finding is classified into EXACTLY ONE of three classes.
assert_grep '^## D\. Classifying a finding$' "$hunt"
assert_fgrep 'exactly one of FIXABLE, REPORT-ONLY or NEEDS-OWNER' "$hunt"
assert_order "$hunt" \
  '^## C\. The round, and the refutation gate$' \
  '^## D\. Classifying a finding$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-064"
# The three classes are DEFINED, not just named.
assert_fgrep 'FIXABLE is a finding the run may fix under its own gates' "$hunt"
assert_fgrep 'REPORT-ONLY is a finding inside a protected path, filed and never edited' "$hunt"
assert_fgrep 'NEEDS-OWNER is a finding whose fix needs a decision only the owner can make' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-021"
# The protected paths are the SAME ones `/rca` reads — the repo's declaration
# plus the no-fix-zones file — and no path they name is ever edited.
assert_fgrep 'the same protected paths `/rca` reads' "$hunt"
assert_fgrep '`protected paths:`' "$hunt"
assert_fgrep '.claude/hooks/no_fix_zones.txt' "$hunt"
assert_fgrep 'never edit any path they name' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-023"
# The loop never DECIDES a NEEDS-OWNER finding — that decision is the owner's.
assert_fgrep 'never decide a NEEDS-OWNER finding' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-024"
# Filing goes through the repo's declared tracker, the tracker is SEARCHED for
# an open item first, the run is capped at 20 items, and a repo with no
# tracker gets its findings in the state file and the verdict instead.
assert_fgrep 'declared `tracker:` command' "$hunt"
assert_fgrep 'Search the tracker for an existing open item BEFORE filing' "$hunt"
assert_fgrep 'at most 20 tracker items' "$hunt"
assert_fgrep 'declares no tracker' "$hunt"
# The PROSE rule, not the bare heading — `## FINDINGS` also appears in section
# B's sample state file, so the rule could be deleted with the suite green
# (REQ-HUNT-071).
assert_fgrep 'record the findings in the `## FINDINGS` section of the state file' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-056"
# All NEEDS-OWNER findings leave as ONE BATCH in the verdict, decision-first,
# never as separate interruptions — the Decision Protocol batches questions at
# the gates and forbids interrupting mid-build.
assert_fgrep 'as ONE BATCH in the verdict' "$hunt"
assert_fgrep 'decision-first format' "$hunt"
assert_fgrep 'never as separate interruptions' "$hunt"
assert_fgrep 'batches questions at the gates and forbids interrupting mid-build' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-025"
# Each FIXABLE finding goes to `implementer`, whose role is `build`, and the
# failing regression test is written BEFORE the fix.
assert_grep '^## E\. Fixing, and the flywheel$' "$hunt"
assert_fgrep 'to the `implementer` agent, whose role is `build`' "$hunt"
assert_fgrep 'failing regression test is written BEFORE the fix' "$hunt"
assert_order "$hunt" \
  '^## D\. Classifying a finding$' \
  '^## E\. Fixing, and the flywheel$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-026"
# The run executes `make check` ITSELF and records the exit code as its
# evidence. A commit hook that did not block is NOT evidence: it is a
# PreToolUse hook with a timeout, and a PreToolUse hook FAILS OPEN. No exit
# code obtainable → abort with that as the named reason.
assert_fgrep 'Run `make check` YOURSELF and record its exit code' "$hunt"
assert_fgrep 'a commit hook that did not block is NOT evidence the checks passed' "$hunt"
assert_fgrep 'FAILS OPEN' "$hunt"
assert_fgrep 'cannot obtain an exit code' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-027"
# Each confirmed finding is taken through `/rca` — the flywheel is INVOKED,
# never restated here, so the rule about rules lives in one place.
assert_fgrep 'take it through `/rca`' "$hunt"
assert_fgrep 'rather than restating the flywheel here' "$hunt"
assert_fgrep 'lives in one place' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-028"
# The routing policy's kill rule applies PER FINDING, and the finding that hits
# it is filed with what was tried.
assert_fgrep 'three failed attempts on the same error' "$hunt"
assert_fgrep 'per finding' "$hunt"
assert_fgrep 'filed with what was tried' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-029"
# Never weaken or delete an assertion to make a suite go green.
assert_fgrep 'Never weaken or delete an assertion to make a suite go green' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-050"
# Findings past the round's fix budget are recorded in SEEN as unfixed, with
# their class. Dropping one is forbidden.
assert_fgrep "past the round's fix budget" "$hunt"
assert_fgrep 'recorded in SEEN as unfixed, with its class' "$hunt"
assert_fgrep 'Never drop a finding' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-053"
# A committed fix RE-OPENS every matrix row whose files it touched, so an area
# this run changed is swept again.
assert_fgrep 'mark every matrix row whose files that fix touched back to `todo`' "$hunt"
assert_fgrep 'a regression this run caused' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-061"
# Every round ends with a clean working tree — committed or reverted — before
# the state file is written.
assert_fgrep 'end with the working tree clean' "$hunt"
assert_fgrep 'every change either committed or reverted' "$hunt"
assert_fgrep 'before the state file is written' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-030"
# The convergence line is COMPUTED and WRITTEN into the state file at the end
# of every round, and it carries the count of confirmed FIXABLE findings that
# round produced. A loop that judges its own progress from memory reports what
# it hoped for, and nobody is awake to correct it.
assert_grep '^## F\. Convergence, the budget, and stopping$' "$hunt"
assert_fgrep 'convergence line' "$hunt"
assert_fgrep 'the count of confirmed FIXABLE findings' "$hunt"
assert_fgrep 'Computed and written, never felt' "$hunt"
assert_order "$hunt" \
  '^## E\. Fixing, and the flywheel$' \
  '^## F\. Convergence, the budget, and stopping$' \
  'convergence line'

# ---------------------------------------------------------------------------
req "REQ-HUNT-031"
# DRY is defined as that count being zero — one word, defined once, so the
# state file and the verdict never disagree about what happened.
assert_fgrep 'A round is DRY when that count is zero' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-032"
# NEEDS-OWNER and REPORT-ONLY are excluded from the count: they are the
# owner's queue, the loop cannot clear them, and a loop that counted them
# would never converge.
assert_fgrep 'EXCLUDED from the convergence count' "$hunt"
assert_fgrep "the owner's queue and not the loop's" "$hunt"
assert_fgrep 'would never converge' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-033"
# The time floor is resolved ONCE at the start, recorded, and compared against
# thereafter. Re-deriving it each round is the named failure: for a run started
# earlier in the day the floor is trivially already past, and the hunt ends
# after a single pass.
assert_fgrep 'resolved ONCE at the start of the run' "$hunt"
assert_fgrep 'compared against thereafter' "$hunt"
assert_fgrep 'Never re-derive the floor at the start of a round' "$hunt"
assert_fgrep 'trivially true' "$hunt"
assert_fgrep 'ends the hunt after a single pass' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-049"
# A wall-clock ceiling and a per-round fix budget are resolved at the same
# moment and recorded beside the floor, each with the default it falls back to.
# The floor is the reason to keep going; these two are the only reason to stop
# spending.
assert_fgrep 'wall-clock ceiling' "$hunt"
assert_fgrep 'the most findings a single round may fix' "$hunt"
assert_fgrep 'recorded in the state file beside the floor' "$hunt"
assert_fgrep 'a floor of 2 hours, a ceiling of 6 hours, and a fix budget of 5 findings per round' "$hunt"
assert_fgrep 'A floor gives the run a reason to keep going' "$hunt"
assert_fgrep 'nothing else gives it a reason to stop spending' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-054"
# The full `make check` must be green at the END of every round as well as
# before each commit, and a round that ends red is a named stop reason.
assert_fgrep 'green at the END of every round as well as before each commit' "$hunt"
assert_fgrep 'A round that ends red stops the run' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-034"
# The permitted stop reasons are NAMED — nothing else ends a run — and the one
# that fired is stated in the verdict, so a run never ends without saying why.
assert_fgrep 'permitted stop reasons' "$hunt"
assert_fgrep '**dry**' "$hunt"
assert_fgrep '**time floor**' "$hunt"
assert_fgrep '**ceiling**' "$hunt"
assert_fgrep '**fix budget**' "$hunt"
assert_fgrep '**kill rule**' "$hunt"
assert_fgrep '**round ended red**' "$hunt"
assert_fgrep '**owner stop**' "$hunt"
assert_fgrep 'never ends without saying why' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-035"
# The command runs its own rounds and stops ITSELF. When a stop condition is
# met it writes `STOPPED: <reason>` into the state file as the LAST write of
# the run, and says in its final message that no further round is to be
# started. It depends on no external driver to stop it.
assert_fgrep 'Run rounds YOURSELF until a stop condition is met' "$hunt"
assert_fgrep 'STOPPED: <reason>' "$hunt"
assert_fgrep 'the LAST write of the run' "$hunt"
assert_fgrep 'no further round is to be started' "$hunt"
assert_fgrep 'never depends on an external driver to stop it' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-062"
# A re-invocation after a `STOPPED:` line has been written reports the recorded
# reason and does no work: an external scheduler on a fixed interval cannot be
# stopped by this command, so a converged hunt would otherwise re-sweep forever.
assert_fgrep 'after a `STOPPED:` line has been written' "$hunt"
assert_fgrep 'report the recorded stop reason and do no work' "$hunt"
assert_fgrep 'fixed interval' "$hunt"
assert_fgrep 're-sweep forever' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-036"
# ONE verdict at the end of the run, carrying all six things: rounds run, each
# round's convergence count, the named stop reason, findings by class, tests
# added, and the branch with its commit range.
assert_grep '^## G\. The verdict$' "$hunt"
assert_fgrep 'ONE verdict at the end of the run' "$hunt"
assert_fgrep 'rounds run' "$hunt"
assert_fgrep "each round's convergence count" "$hunt"
assert_fgrep 'the named stop reason' "$hunt"
assert_fgrep 'findings by class' "$hunt"
assert_fgrep 'tests added' "$hunt"
assert_fgrep 'the branch name with its commit range' "$hunt"
assert_order "$hunt" \
  '^## F\. Convergence, the budget, and stopping$' \
  '^## G\. The verdict$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-037"
# A lane that could not run is reported SKIPPED with its reason, and never as
# a lane that passed.
assert_fgrep 'reported as SKIPPED, with the reason it could not run' "$hunt"
assert_fgrep 'Never report a lane that could not run as one that passed' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-038"
# A run that fixed findings and left them without tests is NOT a green run,
# and the verdict says so.
assert_fgrep 'left them without tests is not a green run' "$hunt"
assert_fgrep 'the verdict says so' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-039"
# The prohibition list, first half: push, deploy, merge into the default
# branch, edit a protected path, decide a NEEDS-OWNER finding.
assert_grep '^## H\. What it must never do$' "$hunt"
assert_fgrep 'Never push' "$hunt"
assert_fgrep 'Never deploy' "$hunt"
assert_fgrep 'Never merge into the default branch' "$hunt"
assert_fgrep 'Never edit a protected path' "$hunt"
assert_fgrep 'Never decide a NEEDS-OWNER finding' "$hunt"
assert_order "$hunt" \
  '^## G\. The verdict$' \
  '^## H\. What it must never do$' \
  'Never push'

# ---------------------------------------------------------------------------
req "REQ-HUNT-063"
# ...and its second half, in the SAME list: history, tests, other features'
# specs and their checkboxes, the settings file and the engine map. Each is
# something a stuck loop reaches for when nobody is watching.
assert_fgrep 'Never rewrite history' "$hunt"
assert_fgrep 'reset --hard' "$hunt"
assert_fgrep 'Never delete or disable a test' "$hunt"
assert_fgrep 'Never edit the `specs/` of another feature' "$hunt"
assert_fgrep 'tick a task checkbox' "$hunt"
assert_fgrep 'Never edit `.claude/settings.json` or the engine map' "$hunt"
assert_fgrep 'what a stuck loop reaches for when nobody is watching' "$hunt"
# ONE list, not two: both halves sit under section H, in order.
assert_order "$hunt" \
  '^## H\. What it must never do$' \
  'Never push' \
  'Never rewrite history' \
  'Never edit `\.claude/settings\.json` or the engine map'

# ---------------------------------------------------------------------------
req "REQ-HUNT-065"
# The resume deadlock. Section E's round-end left the state file WRITTEN but
# uncommitted, and section A's precondition 2 aborts on any dirty tree — so
# every round ended dirty, every next invocation refused, and the resume the
# state file exists for could never happen. The run now COMMITS the state file
# as the last act of every round, and the precondition says that file is the one
# thing it expects to find already committed.
assert_fgrep 'COMMIT the state file, as the LAST ACT OF EVERY ROUND' "$hunt"
assert_fgrep 'the one thing this precondition expects to find ALREADY COMMITTED' "$hunt"
assert_fgrep 'the resume this whole command is built on can never happen' "$hunt"
# ...and the ordering is unambiguous: fixes commit, the tree goes clean, the
# state file is written, and committing that state file is what ends the round.
assert_fgrep 'fixes commit first, the tree goes clean, the state file is written' "$hunt"
# ...and EVERY round means every round: a round that ended red is not excepted,
# or the re-invocation refuses on a dirty tree instead of reporting the stop.
assert_fgrep 'a round that ends red still commits the state file as its last act' "$hunt"
assert_order "$hunt" \
  '^## A\. Refusing to start$' \
  'ALREADY COMMITTED' \
  '^## E\. Fixing, and the flywheel$' \
  'COMMIT the state file, as the LAST ACT OF EVERY ROUND'

# ---------------------------------------------------------------------------
# Re-verification found the deadlock fix guarded only the round-end and red-round
# paths. The CEILING stop and the GENERIC stop also write the state file, and
# deleting either commit instruction left the suite green — re-creating the
# original HIGH finding on the two paths an overnight run most often takes.
assert_fgrep 'commit it as section E requires' "$hunt"
assert_fgrep 'then commit the state file exactly as section E' "$hunt"

req "REQ-HUNT-066"
# Section F may write nothing section B has not declared, because section B also
# calls a state file missing a named section unreadable and FORBIDS repairing
# it. So the canonical shape carries both fields section F writes: a per-ROUND
# convergence log and the `STOPPED:` line.
assert_grep '^## CONVERGENCE LOG$' "$hunt"
assert_grep '^STOPPED: <reason>$' "$hunt"
# The log is per-ROUND and not just the current one — section G's verdict has to
# report each round's count, and a resumed run has no other source for it.
assert_fgrep 'one row per round completed, carrying that round' "$hunt"
assert_fgrep 'a resumed run cannot produce a count for a round it did not run' "$hunt"
# ...and an absent `STOPPED:` line is the normal state of a running hunt, never
# read as the missing section that stops the run.
assert_fgrep 'Its ABSENCE is the normal state of a running hunt' "$hunt"
# Both are declared in section B before section F ever writes to them.
assert_order "$hunt" \
  '^## B\. State — the hunt file$' \
  '^STOPPED: <reason>$' \
  '^## CONVERGENCE LOG$' \
  '^## F\. Convergence, the budget, and stopping$'

# ---------------------------------------------------------------------------
# The seed carve-out: without it a file seeded before round 1 reads as one
# missing a named section, which section B refuses to repair.
assert_fgrep 'is written by the seed, with its header and no round rows yet' "$hunt"

req "REQ-HUNT-067"
# REFUSING TO START and STOPPING A RUN are different events, and the "nothing
# else ends a run" claim is true of the STOP list. The four things that end an
# invocation without a stop reason are named as refusals rather than left as
# silent exceptions.
assert_fgrep 'A REFUSAL and a STOP are not the same event' "$hunt"
assert_fgrep 'the five preconditions of section A' "$hunt"
assert_fgrep 'the unreadable state file of section B, the lock conflict of section B' "$hunt"
assert_fgrep 'the abort when `make check` yields no exit code at all in section E' "$hunt"
assert_fgrep 'so that the stop list below is exhaustive rather than approximately true' "$hunt"
assert_order "$hunt" \
  '^## F\. Convergence, the budget, and stopping$' \
  'A REFUSAL and a STOP are not the same event' \
  'permitted stop reasons'

# ---------------------------------------------------------------------------
req "REQ-HUNT-068"
# Only FIXABLE findings go through the `/rca` flywheel's fixing steps, and the
# lane that runs it is named. REPORT-ONLY findings are by definition inside
# protected paths this file forbids editing, so sending one through a flywheel
# whose steps fix and sweep is how an unattended loop edits a protected path
# while believing it is following a command.
assert_fgrep 'For each confirmed FIXABLE finding — and for no other class — take it through `/rca`' "$hunt"
assert_fgrep 'The `implementer` fix lane is what runs `/rca`' "$hunt"
assert_fgrep 'REPORT-ONLY and NEEDS-OWNER findings NEVER enter the flywheel' "$hunt"
assert_fgrep 'a REPORT-ONLY finding sits inside a protected path this file forbids editing at all' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-069"
# Section E says "Whenever a round commits a fix" — so some section has to tell
# the run to commit one, and with what message.
assert_fgrep 'A fix that passed the gate is COMMITTED' "$hunt"
assert_fgrep 'one commit per finding' "$hunt"
assert_fgrep '`hunt(fix): <mechanism key> — <one line of observable behaviour>`' "$hunt"
assert_fgrep 'with the regression test in the same commit as the fix' "$hunt"
assert_fgrep 'never fold two findings into one commit' "$hunt"
# The instruction to commit comes before the rule that reads back off it.
assert_order "$hunt" \
  '^## E\. Fixing, and the flywheel$' \
  'A fix that passed the gate is COMMITTED' \
  'Whenever a round commits a fix'

# ---------------------------------------------------------------------------
# The commit rule must stay git-possible: two worktrees cannot hold one branch,
# so a lane never commits onto the hunt branch directly. Inverting this to the
# impossible form previously left the suite green.
assert_fgrep 'two worktrees' "$hunt"
assert_fgrep 'the lane never commits onto the hunt branch' "$hunt"

req "REQ-HUNT-070"
# The command ships to ANY repo with the contract. `make check` calling the
# requirement gate is true of some Makefiles and of none of the three shipped
# templates, so the claim is gone and the gate is run by the command itself.
assert_no_grep 'the one .make check. already calls' "$hunt"
assert_fgrep 'Some repos wire it into `make check` and some do not' "$hunt"
assert_fgrep 'run it YOURSELF rather than assuming the baseline already covered it' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-071"
# Mutation honesty. Each phrase below is the load-bearing clause itself rather
# than a word that recurs elsewhere, and each was PROVEN by deletion: removing
# the clause it is lifted from turns this suite red under that clause's own
# REQ-ID. The count assertion is the standing guard on that property — a phrase
# appearing more than once could be satisfied by the wrong line, which is
# exactly how the eight assertions these replaced went hollow.
hardened_phrases=(
  'When the recorded branch and the current branch disagree, abort and name both'
  'Run `make check` yourself and read its exit code before the first round'
  "the round number, the run start time, and the run's resolved floor, ceiling, fix budget and areas, plus the branch and the run lock"
  'record the findings in the `## FINDINGS` section of the state file'
  'carrying the branch, the start time and a run identifier unique to this invocation'
  "A lock is stale once it is older than the run's recorded ceiling, and a stale lock may be taken over"
  'missing one of its named sections, or carries an unrecognised format version, stop before hunting'
  'Never edit any `specs/<feature>/` directory — not a requirements file, not a tasks file, not a checkbox — to clear it'
  'A section whose header is present and whose body is empty is PRESENT, not missing'
  'Each SEEN line carries every field the sections below write into it'
  'Precondition 5 is the one refusal that does not end on the spot'
  'mark every matrix row whose files that fix touched back to `todo`'
)
for phrase in "${hardened_phrases[@]}"; do
  printf '%s\n' "$(grep -cF -- "$phrase" "$hunt" || true)" > "$tmpdir/phrase.count"
  printf '     once? %s\n' "$phrase"
  assert_grep '^1$' "$tmpdir/phrase.count"
done

# ---------------------------------------------------------------------------
# ...and the RESIDUALS the re-verification disclosed and ranked below the five
# findings that failed it (section L of requirements.md). Each is a
# disagreement BETWEEN sections of the same file, which is what four sequential
# authoring passes produce.

req "REQ-HUNT-072"
# Section B declares a file "missing one of its named sections" unreadable and
# REFUSES to repair it, so an under-declared section is a path to an
# unrecoverable state. Every section a seeded, pre-round-1 file legitimately
# lacks now carries the same explicit seed carve-out `## CONVERGENCE LOG` has.
assert_fgrep 'is written by the seed, with its header and no round rows yet' "$hunt"
assert_fgrep 'The seed writes the `## SEEN` header with no lines under it yet' "$hunt"
assert_fgrep 'The seed writes this header too, and it stays empty until the first entry ages out' "$hunt"
# `## FINDINGS` is documented as used only where the repo declares no tracker,
# so a tracker-having repo's file needs an unambiguous answer of its own.
assert_grep '^## FINDINGS$' "$hunt"
assert_fgrep 'in a repo that DOES declare a `tracker:` it stays empty for the whole life of the hunt' "$hunt"
# ...and the unreadable-state rule itself says which of the two it is reading.
assert_fgrep 'A section whose header is present and whose body is empty is PRESENT, not missing' "$hunt"
assert_order "$hunt" \
  '^## B\. State — the hunt file$' \
  'A section whose header is present and whose body is empty is PRESENT, not missing' \
  '^## C\. The round, and the refutation gate$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-073"
# The declared SEEN line shape carries every field sections C, D and E write
# into it, not the three it used to name: the round, the class, what was tried
# for a refuted or abandoned candidate, and the unfixed marker.
assert_fgrep 'Each SEEN line carries every field the sections below write into it' "$hunt"
assert_fgrep 'the round it was judged in' "$hunt"
assert_fgrep 'its class once section D has given it one' "$hunt"
assert_fgrep 'a finding the kill rule of section E abandoned, each attempt and the way it failed' "$hunt"
assert_fgrep '`unfixed` when the round could not reach it inside its fix budget' "$hunt"
# ...and the example lines in the file shape actually carry them, so the shape
# and the prose cannot drift apart.
assert_grep '^- CONFIRMED FIXABLE .*round=[0-9]+ +unfixed' "$hunt"
assert_grep '^- REFUTED .*round=[0-9]+ +tried=' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-074"
# The Arguments section says all FOUR resolved values are recorded in the state
# file; the `## CURRENT ROUND` shape declared three.
assert_grep '^floor: <resolved>  ceiling: <resolved>  fix budget: <resolved>  areas: <resolved>$' "$hunt"
assert_fgrep "the run's resolved floor, ceiling, fix budget and areas" "$hunt"
assert_fgrep 'a resumed run inherits the same budget AND the same scope' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-075"
# ONE vocabulary for a matrix row's two states. The file carried three:
# `todo`/`done` in the shape, not-done/NOT-DONE in the round and fixing rules,
# and "every row `done` and none re-opened" in the convergence check.
assert_fgrep 'a status (`todo` or `done`)' "$hunt"
assert_fgrep 'AT MOST THREE area rows marked `todo`' "$hunt"
assert_fgrep 'mark every matrix row whose files that fix touched back to `todo`' "$hunt"
assert_fgrep 'with every row `done` and none re-opened' "$hunt"
# ...and the retired words are gone from the file entirely, in either case.
assert_no_grep 'not-done' "$hunt"
assert_no_grep 'NOT-DONE' "$hunt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-076"
# The refusal enumeration claimed an exact count while two more paths end an
# invocation without completing a round. The count is gone and both paths are
# named: precondition 5's red baseline, which does work before it ends, and a
# re-invocation after a `STOPPED:` line, which does none.
assert_no_grep 'exactly four kinds of refusal' "$hunt"
assert_fgrep 'Precondition 5 is the one refusal that does not end on the spot' "$hunt"
assert_fgrep 'the run then fixes that failure, reports it and stops, so it' "$hunt"
assert_fgrep 'A re-invocation after a `STOPPED:` line is the other path that ends an invocation' "$hunt"
assert_fgrep 'No count of refusals is stated here' "$hunt"
assert_order "$hunt" \
  'A REFUSAL and a STOP are not the same event' \
  'Precondition 5 is the one refusal that does not end on the spot' \
  'These are the permitted stop reasons'

# ---------------------------------------------------------------------------
req "REQ-HUNT-077"
# hunt.md sends a fix lane's commits back onto the hunt branch "the way
# `/build` lands a task" — and build.md documented no merge-back at all, only
# "commit on the worktree branch. NEVER merge to main." The reference pointed
# at behaviour no file described.
build="$repo/commands/build.md"
assert_file "$build"
assert_fgrep 'merged back onto the hunt branch the way `/build` lands a task' "$hunt"
assert_fgrep 'merged back onto the FEATURE branch' "$build"
assert_fgrep 'git merge --no-ff sdlc/<feature>-<task>' "$build"
assert_fgrep 'Two worktrees cannot hold the same branch' "$build"
# ...and documenting it does not weaken the rule beside it: the merge is
# worktree branch → feature branch, and nothing reaches main.
assert_fgrep 'NEVER push. NEVER merge to main.' "$build"
assert_fgrep 'still NEVER push, and still NEVER merge to main' "$build"
assert_order "$build" \
  'commit on the worktree branch' \
  'merged back onto the FEATURE branch' \
  'still NEVER push, and still NEVER merge to main'

# ---------------------------------------------------------------------------
# The two discoverability documents.
readme="$repo/README.md"
manual="$repo/ainative_sdlc.html"

# The `## Layout` section body, extracted exactly as tests/test_readme.sh
# extracts it — the `commands/` block lives inside that section and nowhere
# else, so a hunt.md line parked under some other heading must not pass.
awk '
  $0 == "## Layout" { inside = 1; next }
  /^## / { inside = 0 }
  inside { print }
' "$readme" > "$tmpdir/layout.txt"
wc -l < "$tmpdir/layout.txt" | tr -d '[:space:]' > "$tmpdir/layout.count"

req "REQ-HUNT-040"
assert_file "$readme"
# The section must have a body; an empty one cannot pass by listing nothing.
assert_grep '^[1-9][0-9]*$' "$tmpdir/layout.count"
# hunt.md is listed with a one-line description, inside the commands/ block.
assert_grep '^ *hunt\.md +/hunt — ' "$tmpdir/layout.txt"
assert_order "$tmpdir/layout.txt" \
  '^ *commands/$' \
  '^ *hunt\.md ' \
  '^ *settings/$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-041"
assert_file "$manual"
# The command table carries a /hunt row, describing the unattended bug hunt.
assert_fgrep '<tr><td><code>/hunt</code></td>' "$manual"
assert_grep '<code>/hunt</code>.*on its own' "$manual"

# ...and the count stated in the prose above the table matches the number of
# rows in it. Counted here rather than hard-coded: adding a row and leaving the
# sentence behind is exactly the drift this asserts against.
rows=$(grep -c '<tr><td><code>/' "$manual" | tr -d '[:space:]')
words=(zero one two three four five six seven eight nine ten eleven twelve)
printf '%s\n' "$rows" > "$tmpdir/rows.txt"
assert_grep '^[1-9][0-9]*$' "$tmpdir/rows.txt"
# The prose is the cmd.p paragraph, whatever its wording; only the number in it
# is pinned, so a reworded sentence with the right count still passes and a
# stale count still fails.
grep -o 'data-i18n="cmd.p">[^<]*\(<b>\)\{0,1\}[a-z]*' "$manual" > "$tmpdir/cmd-p.txt"
assert_grep "These (<b>)?${words[$rows]}(</b>)?( |$)" "$tmpdir/cmd-p.txt"

# ---------------------------------------------------------------------------
req "REQ-HUNT-042"
# Both documents separate the three commands that look alike from a distance,
# each in ONE line.
assert_fgrep 'hunt looks for bugs, test-audit judges the tests, rca kills the class of one known bug' "$readme"
assert_fgrep 'hunt looks for bugs, test-audit judges the tests, rca kills the class of one known bug' "$manual"

# ---------------------------------------------------------------------------
req "REQ-HUNT-078"
# A repo may declare its own sweep lanes; they return candidates only and count
# against the lane cap; without the line the researcher sweeps alone.
assert_fgrep '`hunt lanes: <agent>[, <agent>...]`' "$hunt"
assert_fgrep 'dispatched as one' "$hunt"
assert_fgrep 'counts against the lane cap below like any other lane' "$hunt"
assert_fgrep 'With no declaration the `researcher` sweeps alone' "$hunt"
assert_order "$hunt" '^### Sweep the areas$' 'hunt lanes:' '^### Reproduce, and judge the refutation$'

# ---------------------------------------------------------------------------
req "REQ-HUNT-079"
# A tracked finding the owner has said STOP to is NEEDS-OWNER, not FIXABLE: the
# tracker is the owner's kill switch over an unattended run.
assert_fgrep 'READ it before' "$hunt"
assert_fgrep 'an owner comment saying STOP' "$hunt"
assert_grep "the owner.s kill switch" "$hunt"
assert_order "$hunt" '^### Filing$' 'kill switch' '^### NEEDS-OWNER leaves as one batch$'
# ...and a repo with declared lanes takes one area per round, keeping the cap.
assert_fgrep 'takes ONE area row rather than three' "$hunt"

finish
