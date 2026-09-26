---
description: Hunt this repo for bugs unattended — sweep, reproduce, fix what it can prove, file the rest, and stop itself with a named reason
---
Hunt the CURRENT repo for bugs, unattended, running your own rounds until a stop
condition is met. This command asks the one question no other command asks: DOES
THE CODE STILL HOLD? `/test-audit` asks whether the tests still mean anything,
`/rca` takes one KNOWN bug and makes its class extinct, `/build` executes an
approved spec. `/hunt` has no spec to execute — it goes looking, PROVES what it
found, fixes what it can prove under its own gates, and files the rest.

Read this whole file before doing anything. It edits source and commits with
nobody watching, so every rule below states the reason it exists: a rule whose
reason is stated survives being paraphrased at 3am, and a bare rule does not.

## Arguments
$ARGUMENTS may carry any of the following, all optional and in any order.
Resolve each ONCE at the start of the run, record what you resolved in the state
file, and say in the verdict which were given and which fell back to a default:

- **`floor: <duration>`** — the minimum time the run keeps hunting before a dry
  round is allowed to stop it. Default **2 hours**.
- **`ceiling: <duration>`** — the hard wall-clock limit on the whole run, and
  also the age at which a run lock goes stale. Default **6 hours**.
- **`fixes: <count>`** — the most findings any single round may fix.
  Default **5 findings per round**.
- **`areas: <names>`** — restrict the hunt to these area-matrix rows, by name.
  Default **every row in the matrix**.

An argument you cannot parse is reported and ignored, never guessed at: a misread
budget is the difference between a short run and an all-night one.

## A. Refusing to start
Check every precondition below BEFORE any other work, in the order given. When
one fails, stop and say in one line which precondition failed and what you
observed. Every abort in this section names the precondition that failed, so an
unattended run never ends in silence — a reader who sees only the last message
can tell "refused" from "crashed" without opening a log.

1. **A contract.** The repo must have a `check` target in a Makefile. With
   no `check` target in a Makefile, abort: a repo with no contract has no
   baseline, and a hunt without a baseline
   cannot tell a finding from a failure that was already there. Do not
   substitute a guessed lint or test command — guessing at the contract is
   inventing the baseline.
2. **A clean tree.** If the working tree is dirty (`git status --porcelain`
   prints anything), abort. Hunting on top of a half-finished edit
   attributes someone else's change to this run, and this run would then commit
   it under its own name.
   This run's own state file, `specs/_hunt/HUNT.md`, is
   the one thing this precondition expects to find ALREADY COMMITTED rather than
   dirty: the previous round committed it as the last act of that round
   (section E), so a resuming hunt reads its state out of a tree the last round
   left clean. A state file sitting dirty here is therefore not a resume — it is
   an unfinished round somebody interrupted, and it aborts like any other dirty
   tree.
3. **The branch.** The hunt runs on `sdlc/hunt-<YYYY-MM-DD>`, one branch per
   day's hunt. When the state file records a branch,
   reuse the branch recorded in the state file rather than computing a fresh
   name — a run that resumes after midnight must not silently start a second
   branch and split its own history.
   When the recorded branch and the current branch disagree, abort and name both:
   you are either in the wrong checkout or another hunt owns this state.
   With no branch recorded, create the dated
   branch from the current HEAD.
   Never run on the repository's default branch, even when it is clean: this
   command commits, and the default branch is not where anyone should find out
   what it committed.
4. **The requirement gates.** Run the repo's requirement-coverage gate
   (`req-gate.sh`) as a precondition, and
   abort when it is ALREADY failing.
   Some repos wire it into `make check` and some do not — of the Makefile
   templates this framework ships, none does — so
   run it YOURSELF rather than assuming the baseline already covered it.
   Never edit any `specs/<feature>/` directory — not a requirements file, not a tasks file, not a checkbox — to clear it.
   The gates are repo-global: another feature's
   coverage gap blocks every commit this run would make, and closing someone
   else's gap is that feature's work, not this run's. Report it and stop.
5. **The baseline.**
   Run `make check` yourself and read its exit code before the first round.
   A RED baseline is not something to hunt from — it is
   the whole job of the run: fix that failure, report it, and stop. A red gate is
   never a starting point to hunt from, because every later result would be
   measured against a broken gate and every fix this run made would look
   unproven.

Only once all five pass do you claim the run lock (section B) and start round 1.

## B. State — the hunt file
The run's state is `specs/_hunt/HUNT.md`, in the repo being hunted. It exists
because a hunt without memory re-finds its own findings, re-files them, and never
converges.

The requirement gates never see this file, and the reason is precise enough to be
worth stating exactly: the gates iterate `specs/*/requirements.md`, and
`specs/_hunt/` contains no `requirements.md`, so no iteration ever reaches it.
The directory is invisible because of what it does not contain, and
not because of the leading underscore, which is a naming convention and gates
nothing. So: NEVER create a `requirements.md` under `specs/_hunt/`. The moment
one exists, this run's private state becomes a feature the gates demand tasks and
tests for, and every commit in the repo starts failing.

### The shape of the file

```
HUNT-FORMAT: 1

## AREA MATRIX
| area | status | last round | note |
|---|---|---|---|
| src/parse | done | 3 | |
| src/net | todo | - | re-opened by the fix in round 3 |
seeding rule: <the rule used>
excluded: <what it left out, and why>

## SEEN
- CONFIRMED FIXABLE  src/net/retry.go:84  key=retry-count-off-by-one  round=3
- CONFIRMED FIXABLE  src/net/pool.go:31   key=pool-leak-on-timeout    round=4  unfixed
- CONFIRMED FIXABLE  src/net/dns.go:9     key=dns-retry-storm         round=4  unfixed  tried=<each attempt, and the way it failed>
- REFUTED            src/parse/lex.go:12  key=unclosed-string-at-eof  round=1  tried=<the command run, and what it printed>

## SEEN (archived)

## CURRENT ROUND
round: 4
branch: sdlc/hunt-<YYYY-MM-DD>
started: <YYYY-MM-DD>T<HH:MM><TZ>
floor: <resolved>  ceiling: <resolved>  fix budget: <resolved>  areas: <resolved>
RUN LOCK: branch=<branch> started=<YYYY-MM-DD>T<HH:MM><TZ> run=<identifier>
STOPPED: <reason>

## CONVERGENCE LOG
| round | confirmed FIXABLE |
|---|---|
| 3 | 1 |
| 4 | 0 |

## FINDINGS
(used only when the repo declares no `tracker:` — see section D)
```

Its parts:
- **`## AREA MATRIX`** — one row per area, each carrying a status (`todo` or `done`)
  and the round it was last swept in. Those two words are the ONLY
  vocabulary for a row's state anywhere in this file: a row is `todo` or it is
  `done`, in the shape above, in the round of section C, in the fixing rules of
  section E and in the convergence check of section F. A second pair of words
  for the same two states is a second matrix nobody is keeping.
  The matrix is the run's cost model:
  it is what makes a hunt bounded work rather than an unbounded stare.
- **`## SEEN`** — one line per candidate ever judged, each carrying its verdict.
  This is what stops the next round, and the next run, from re-finding what has
  already been decided.
  The seed writes the `## SEEN` header with no lines under it yet, so a file seeded before round 1 is never read as one missing a named section.
- **`## SEEN (archived)`** — the same lines, aged out (below).
  The seed writes this header too, and it stays empty until the first entry ages out — an empty archive is a section present and unused, never a section missing.
- **`## CURRENT ROUND`** —
  the round number, the run start time, and the run's resolved floor, ceiling, fix budget and areas, plus the branch and the run lock.
  All FOUR of the values the Arguments section resolves are recorded here, so
  a resumed run inherits the same budget AND the same scope rather than
  inventing either one.
- **`## CONVERGENCE LOG`** —
  one row per round completed, carrying that round's convergence count (section
  F). The log is per-ROUND rather than a single current number because the
  verdict of section G must report EACH round's count, and
  a resumed run cannot produce a count for a round it did not run. The SECTION
  is written by the seed, with its header and no round rows yet, so that a file
  seeded before round 1 is never read as one missing a named section.
- **`## FINDINGS`** — the findings of a run in a repo that declares no
  `tracker:`, and nothing else (section D). The seed writes this header as well,
  and in a repo that DOES declare a `tracker:` it stays empty for the whole life of the hunt —
  an empty `## FINDINGS` is the normal state of a tracker-having repo's file,
  and never one of the missing sections that make a state file unreadable.
- **`STOPPED: <reason>`** — one line under `## CURRENT ROUND`, written only once
  a stop condition has fired (section F).
  Its ABSENCE is the normal state of a running hunt, and is never read as one of
  the missing sections that make a state file unreadable.

Every field any later section writes into this file is declared here. A section
that writes a field this shape does not show would produce a file the
unreadable-state rule below then refuses to touch — night one writing a file
night two must abort on.

### Resume, never restart
If `specs/_hunt/HUNT.md` exists, resume from it: read the matrix, the round
number and the resolved budgets, and pick up where the last round left off,
and never start a new matrix over an existing file. A fresh invocation
continues the same hunt — that is the only reason a scheduler, or a session with
an empty context, can pick this command up at all. Restarting throws away every
`done` row and every verdict, and the run then spends its whole budget
re-deriving what the last one already knew.

### Seeding, the first time only
When there is no state file, seed the matrix with
one row per top-level source directory tracked by git (`git ls-files`),
excluding vendored, generated and dependency paths — `vendor/`, `node_modules/`,
`dist/`, `build/`, `target/`, lockfiles, and anything the repo's ignore rules or
its own conventions mark as not hand-written. The matrix is
capped at 20 rows: when more directories qualify, keep the largest by
tracked-file count and leave the remainder folded into one `other` row.
Then record the seeding rule used and what it excluded, in the matrix itself —
the owner corrects a wrong matrix by hand, and cannot correct a rule they cannot
see. Seed silently and report afterwards: an unattended command that opens with a
question is not unattended.

### Written every round, atomically
Write the state file at the end of EVERY round, before that round counts as
finished. A crashed, killed or interrupted run then
loses one round rather than the whole hunt.

`HUNT-FORMAT: 1` is the file's first line, and it is how a later version of this
command recognises a file it can still read. Every write is atomic: write the
full new contents to a
temporary file in the same directory, then rename it over the old one. A partial
write is worse than no write — a half-written SEEN list silently re-opens
everything below the truncation.

### A state file you cannot read
If the file exists but is
missing one of its named sections, or carries an unrecognised format version, stop before hunting.
A section whose header is present and whose body is empty is PRESENT, not missing: the seed
writes every header the shape above names, and several of them are legitimately
empty until the round or the repo that fills them comes along.
Report the path and exactly
what was wrong — which section was absent, or which version line was found — and
NEVER overwrite or re-seed it. That is the one tempting repair and it is the
worst one available: re-seeding discards SEEN, and every finding from every
previous run is then re-filed, into the tracker, unattended, as though it were
new. A human repairs this file; the run does not.

### SEEN, and how dedupe works
Dedupe every fresh candidate against the SEEN list
by SEARCHING it — grep for the path and for the key.
Never read the SEEN list end to end. The list
grows without bound and the context does not, so a run that reads it whole gets
slower every night and eventually cannot start at all.

Each SEEN line carries every field the sections below write into it, and the
shape above shows all of them: its verdict, its `<path>:<line>`, a
short mechanism key naming what is wrong (`retry-count-off-by-one`, never
`bug-2`), the round it was judged in, its class once section D has given it one,
`tried=` with what was attempted — for a candidate REFUTED in section C, the
command run and what it printed; for a finding the kill rule of section E abandoned, each attempt and the way it failed —
and `unfixed` when the round could not reach it inside its fix budget (section E).
A field a later section writes and this shape does not show is a field the
unreadable-state rule above cannot vouch for.
A candidate matches an existing entry when
PATH AND KEY together match. Path alone is not the match: matching on path
collides two different bugs in one file into a single entry and silently drops
the second, which is exactly the failure this list exists to prevent.

Entries older than 10 rounds move into the `## SEEN (archived)` section of the
same file, and dedupe searches the archive too — archiving shrinks the region a
search usually touches without ever losing a verdict.
Never delete a SEEN entry: not when it is old, not when the file is long, not
when the code it names is gone. A deleted verdict is a finding the next run
re-discovers and re-files.

A candidate that already carries a verdict in SEEN is never re-filed. That
includes a candidate judged REFUTED in an earlier round: refuted means the run
already spent evidence on it and it did not reproduce, so re-filing it spends
that evidence again and fills the tracker with what has already been checked. A
refuted candidate comes back only when a human re-opens it.

### The run lock
Claim the run before the first round: write a `RUN LOCK:` line into
`specs/_hunt/HUNT.md`
carrying the branch, the start time and a run identifier unique to this invocation,
and write it
before the first round begins. If an
unexpired lock naming a different run is already present, abort and name that
run's identifier and start time — two hunts committing to one branch produce a
history neither of them can explain.

A lock is stale once it is older than the run's recorded ceiling, and a stale lock may be taken over:
whoever held it is past the longest that run was ever allowed to
live, so it is either gone or misbehaving. When you take one over, say so —
name the takeover in the verdict, with the dead run's identifier and start time,
so a duplicated commit has a stated cause rather than a mystery.

## C. The round, and the refutation gate
A round is one bounded pass over part of the repo, and its shape is fixed: pick
areas, sweep, dedupe, reproduce, judge, classify, fix, gate, record. Work it in
that order. The order is the point — it is what stops an unattended loop from
fixing something it never proved.

### Pick the areas
Take AT MOST THREE area rows marked `todo` from the matrix each round, in the
order the matrix lists them, restricted to the rows `areas:` named when that
argument was given. Three is the number because three is also the lane cap, so
one round is exactly one full fan-out.
Taking a single row instead needs as many rounds as the repo has areas, and
spends most of the budget on per-round overhead. Taking every row at once is
the whole-repo sweep this loop exists to avoid: an unbounded stare that comes
back with a hundred guesses and no evidence for any of them.

### Sweep the areas
The sweep — the enumeration of candidates in one area — goes
to the `researcher` agent, whose role is `read`, one lane per area. That is
where it belongs because the sweep reads far more than it concludes: it touches
whole directories to return a short list, so the sweep is volume work, and volume is what it costs.
A sweep lane returns candidates only — each a `<path>:<line>` and a short
mechanism key — and never a fix, a diff or an edit.

A repo may add sweep lanes of its own: one line in its CLAUDE.md,
`hunt lanes: <agent>[, <agent>...]`, the same shape as the `tracker:` and
`protected paths:` declarations. Each agent named there is dispatched as one
more sweep lane over the same area, under the same contract — candidates only,
a `<path>:<line>` and a mechanism key, never a fix, a diff or an edit — and it
counts against the lane cap below like any other lane. An agent that edits, or
that returns verdicts instead of candidates, is not a sweep lane and does not
belong on that line: the main session still judges every candidate, whoever
found it. With no declaration the `researcher` sweeps alone, as before.
Because the cap bounds lanes running AT ONCE, a round in a repo with declared
lanes takes ONE area row rather than three, and runs that area's sweep lanes
in batches of three: the fan-out widened, so the ground covered per round
narrows to keep the round bounded. The count of candidates is what converges,
not the count of rows.

Dedupe every returned candidate against SEEN by the path-and-key match of
section B before anything else happens to it. A candidate that already carries
a verdict stops here.

### Reproduce, and judge the refutation
Every fresh candidate that survives dedupe goes
to the `evidence` agent to be REPRODUCED — the exact steps, the command run,
and the output actually observed. A candidate that
cannot be reproduced is recorded REFUTED in SEEN, together with what was tried,
so the next round does not spend the same evidence twice.

The agent gathers; it does not rule — the main session judges refutation
from the returned evidence, because judging is the one thing that must not be
delegated in a loop nobody is watching: an agent that both hunts and grades its
own hunt will find something every time.

The `verifier` agent is NOT used here, and the reason is mechanical rather than
a matter of taste: `verifier` is `isolation: worktree` and opens by checking out
the branch under review and diffing it against base, so it has
neither branch nor diff for a bare candidate. `evidence` is the
reproduce-or-fail agent, carries the same `verify` role, and needs nothing that
does not exist yet.

### Record a finding
A candidate the evidence confirms is a FINDING. Record it with
its file path and line, its mechanism key, and
the observable behaviour that makes it wrong — what the code does, and what it
should have done instead. "This looks wrong" is not a finding. A finding is
something a reader can go and see for themselves.

### Lanes
Never run more than THREE lanes at once, whatever a round has queued, and count
them yourself: the dispatching main session enforces the cap, because nothing
else in the harness is counting them for you.

Every fix lane works in
its own worktree, as `/build` does,
rather than sharing one tree. The framework already solved lane isolation with
worktrees, and a new command does not get to invent a weaker model beside the
one that works.

Read-only sweep lanes may share a tree, because reading cannot collide. But
no lane ever writes to a shared tree — not a scratch file, not a formatter's
reflow, not a `git stash`. A write into a shared tree is invisible to every
other lane standing in it, and it lands in whichever commit happens next.

## D. Classifying a finding
Every confirmed finding is classified into
exactly one of FIXABLE, REPORT-ONLY or NEEDS-OWNER. One class, chosen once,
written into SEEN beside the verdict. A finding with no class is a finding
nobody can act on, and a finding with two is an argument the loop will lose:

- FIXABLE is a finding the run may fix under its own gates.
- REPORT-ONLY is a finding inside a protected path, filed and never edited.
- NEEDS-OWNER is a finding whose fix needs a decision only the owner can make.

### Protected paths
Read the same protected paths `/rca` reads, and read them the same way: the
repo's `protected paths:` declaration in its CLAUDE.md, plus
`.claude/hooks/no_fix_zones.txt` when the repo has one, taken on top of it. Then
never edit any path they name, however small the fix looks — a REPORT-ONLY
finding is filed and left alone, and there the report IS the deliverable: name
the file, the line and the mechanism, and leave the change to its owner. A repo
that declares neither has no protected paths, and nothing is invented to fill
the gap.

### NEEDS-OWNER is not yours
The loop must never decide a NEEDS-OWNER finding — not by taking the option that
looks obvious, not by taking the smallest diff, not by "assuming a default and
recording it". That last one is the tempting move, and it is wrong here: the
mid-build rule lets a run assume a REVERSIBLE default, and a finding is
NEEDS-OWNER precisely when its fix is not that.

### Filing
File findings through the repo's declared `tracker:` command and through nothing
else; no tracker CLI is ever guessed at.
Search the tracker for an existing open item BEFORE filing anything — an
unattended loop that files without looking first is how one bug becomes nine
identical issues overnight, and the tracker's owner then stops reading any of
them. When an open item already exists for the finding, READ it before
classifying: an owner comment saying STOP, or the repo's approval label removed
from it, makes the finding NEEDS-OWNER whatever the code says — the tracker is
the owner's kill switch, and a loop that fixes past a STOP has taken a decision
that was not its to take. File at most 20 tracker items in a single run; on reaching the cap, stop
filing, keep recording in SEEN, and say in the verdict how many were held back.

When the repo declares no tracker, nothing is filed anywhere:
record the findings in the `## FINDINGS` section of the state file and repeat them in the verdict,
and that is the whole delivery. A repo that wants no unattended issues
declares no tracker, and that choice is honoured rather than worked around.

### NEEDS-OWNER leaves as one batch
Every NEEDS-OWNER finding a run produces goes out together,
as ONE BATCH in the verdict, in the
decision-first format — the TL;DR first, then the items that need judgment, then
the assumed defaults, then the detail — and
never as separate interruptions raised one at a time while the run is going. The
Decision Protocol
batches questions at the gates and forbids interrupting mid-build, and an
unattended hunt is mid-build for hours: a question asked into an empty room at
2am is not a question, it is a stalled run.

## E. Fixing, and the flywheel
Send each FIXABLE finding
to the `implementer` agent, whose role is `build`, one finding per lane, up to
the round's fix budget. The
failing regression test is written BEFORE the fix, and it pins the mechanism the
evidence showed rather than the surface symptom — a test written after a fix
passes immediately and proves only that the code does what it does.

### The gate is an exit code you read yourself
Run `make check` YOURSELF and record its exit code as the round's evidence that
a fix is committable. That exit code is the evidence; nothing else is.

The commit hook is not that evidence, and this is the trap worth spelling out in
full. `make check` normally runs through a PreToolUse hook on the commit; that
hook has a timeout, and a PreToolUse hook FAILS OPEN — when it times out it does
not block. In a repo whose suite outruns the timeout, every commit passes
ungated while looking perfectly gated. So
a commit hook that did not block is NOT evidence the checks passed; it is only
evidence that nothing stopped you. This is the framework's artifacts-not-claims
rule inverted: absence of a refusal is not a result.

When you cannot obtain an exit code at all — the command hangs, the runner is
missing, the output is swallowed by something that eats it — abort the run and
name that as the reason. A fix you cannot gate is a fix you do not commit.

### Committing a fix
A fix that passed the gate is COMMITTED, and this is where the run is told to
do it: one commit per finding, made on the lane's own worktree branch and
merged back onto the hunt branch the way `/build` lands a task — two worktrees
cannot hold the same branch, so the lane never commits onto the hunt branch
directly. Commit
with the regression test in the same commit as the fix — neither can be
read without the other, and a test that lands separately can be reverted alone.
The message shape is
`hunt(fix): <mechanism key> — <one line of observable behaviour>`, with the
finding's `<path>:<line>` on the next line of the body and the tracker item, if
one was filed. A fix nobody committed is a fix the next round re-finds from
scratch, and a message that does not name the mechanism makes the next reader
re-derive it from the diff.

Never commit a fix whose gate exit code you did not read yourself, and
never fold two findings into one commit: a round that lands three fixes and
then ends red is read back one finding at a time, and only if each finding has
a commit of its own.

### The flywheel is invoked, not restated
For each confirmed FIXABLE finding — and for no other class — take it through `/rca`,
and invoke it
rather than restating the flywheel here. Reproduce, root cause, a test-first
fix, a rule, a sibling sweep, the gate and the evidence summary are that
command's seven steps, and the rule about rules
lives in one place. A second copy of it in this file would drift from the
original within a month, and then the two would disagree in the dark.

The `implementer` fix lane is what runs `/rca`, inside its own worktree, on the
one finding that lane was given — the flywheel is not run by the main session
and not by a sweep lane.
REPORT-ONLY and NEEDS-OWNER findings NEVER enter the flywheel. Four of its
seven steps edit code, and
a REPORT-ONLY finding sits inside a protected path this file forbids editing at all,
while a NEEDS-OWNER finding has no fix the loop is allowed to choose. Sending
either one through `/rca` is precisely how an unattended loop edits a protected
path while believing it is obeying a command.

### When a fix will not land
The routing policy's kill rule applies per finding rather than per round: after
three failed attempts on the same error, stop working that finding, revert the
lane, and move on. The abandoned finding is then
filed with what was tried — each attempt and the way it failed — because the
next reader's first question is "what did it already try?", and a finding filed
without that answer costs them the same three attempts again.

Never weaken or delete an assertion to make a suite go green. Not by loosening a
comparison, not by marking a case skipped, not by deleting the test that caught
it. A suite bent to fit a fix is worse than the bug: it now certifies the bug.

### Findings the budget could not reach
Findings past the round's fix budget are not fixed this round, and are not lost
either — each one is
recorded in SEEN as unfixed, with its class, and the round it was found in, so
the next round picks it up already proved. Never drop a finding because a round
ran out of budget; the budget bounds what a round FIXES, never what it KNOWS.

### A fix re-opens what it touched
Whenever a round commits a fix,
mark every matrix row whose files that fix touched back to `todo`, so the area this
run changed is swept again before the hunt calls itself done. Without this the
matrix only ever fills up, and a regression this run caused is invisible to the
very loop that caused it.

### End the round clean, and commit the state file last
Every round must
end with the working tree clean —
every change either committed or reverted, no stashes, no half-applied lane —
before the state file is written. The state file is a claim about the
repository, and it is only true of a tree that has stopped moving; a resumed run
that inherits a dirty tree cannot tell which of those edits it made.

Then COMMIT the state file, as the LAST ACT OF EVERY ROUND: stage
`specs/_hunt/HUNT.md` alone and commit it with the message
`hunt(state): round <n>`, carrying nothing else in that commit. The sequence is
fixed and admits no other reading:
fixes commit first, the tree goes clean, the state file is written,
and committing that state file is what makes the round finished.

Leaving the state file written but uncommitted is the exact failure this rule
exists to prevent. It dirties the very tree the round has just cleaned; the
next invocation then aborts on the clean-tree precondition of section A, which
cannot tell this run's own bookkeeping from someone else's half-finished edit;
and
the resume this whole command is built on can never happen. A hunt that cannot
resume spends every night re-deriving what the last night already knew, which
is the one thing the state file exists to stop.

## F. Convergence, the budget, and stopping
A round ends by computing a number and writing it down. Everything in this
section exists so the run can tell "there is nothing left to find" apart from
"I have been looking for a while", with nobody in the room to tell them apart.

### The convergence line
At the end of every round, COMPUTE that round's convergence line and write it
into `specs/_hunt/HUNT.md` as a new row in the `## CONVERGENCE LOG` section
declared in section B, beside the round number,
carrying the count of confirmed FIXABLE findings that round produced. Append
the row; never overwrite the previous round's, because the verdict reports
every round's count and not just the last one.
Computed and written, never felt: a loop that grades its own progress from
memory reports the progress it hoped for, and nobody is awake to check.

A round is DRY when that count is zero — no confirmed FIXABLE finding at all.
That is the only thing "dry" means in this file, so the state file and the
verdict can never disagree about what a round did.

NEEDS-OWNER and REPORT-ONLY findings are EXCLUDED from the convergence count.
They are the owner's queue and not the loop's: this run is forbidden from
fixing either, so both are still there next round, and the round after that. A
loop that counted them would never converge — it would wake, re-count the same
untouchable pile, call itself productive, and hunt to the ceiling every night.

### The budget, resolved once
Resolve the floor, the ceiling and the fix budget ONCE at the start of the run,
from `$ARGUMENTS` or the stated defaults, and record all three under
`## CURRENT ROUND` in the state file, beside the `areas:` restriction the
Arguments section resolved at the same moment and records in the same place.
When the invocation names none, the
defaults are
a floor of 2 hours, a ceiling of 6 hours, and a fix budget of 5 findings per round.

- **The floor** is the minimum time the run keeps hunting before a dry round is
  allowed to stop it. It is
  resolved ONCE at the start of the run, recorded there, and
  compared against thereafter — the recorded start time plus the floor is a
  fixed instant, and every round checks the clock against that one instant.
  Never re-derive the floor at the start of a round, and never re-anchor it to
  the current round's start or to the current date. A floor re-derived each
  round is trivially true for a run that began earlier in the day: the first
  check passes, the first dry round is then allowed to stop the run, and that
  ends the hunt after a single pass. This is not hypothetical — it is a bug
  a real implementation of this rule has shipped with, and it is
  invisible from the outside, because a run that stops after one pass looks
  exactly like a run that found nothing.
- **The ceiling** is the hard wall-clock ceiling on the whole run, and the age
  at which a run lock goes stale (section B).
- **The fix budget** is the most findings a single round may fix; findings past
  it are recorded unfixed, never dropped (section E).

The ceiling and the fix budget are resolved at that same moment and
recorded in the state file beside the floor, so a resumed run inherits the same
budget rather than inventing a new one.
A floor gives the run a reason to keep going, and
nothing else gives it a reason to stop spending — a run holding a floor but no
recorded ceiling has no upper bound at all.

### The round gate
The full `make check` must be
green at the END of every round as well as before each commit, and you run it
and read its exit code yourself, as section E requires. A commit-time gate
proves the tree was green when one fix landed; only a round-end gate proves the
round as a whole left the repo green, and a round can commit three fixes that
pass apart and fail together.

A round that ends red stops the run. Record `round ended red` as the stop
reason, leave the tree exactly as it is for a human to read, and start no
further round. Hunting on from a red gate measures every later finding against
a broken baseline — the same reason section A refuses to start on one.

Leaving the tree as it is means reverting nothing and amending nothing — the
round's fixes are already committed and the tree already clean, because
section E required that before the gate ran. It does NOT except this round from
the state-file commit:
a round that ends red still commits the state file as its last act, or the
re-invocation refuses on a dirty tree instead of reporting the stop reason,
and the red gate nobody can read about is worse than the red gate itself.

### Stopping
Run rounds YOURSELF until a stop condition is met. This command is
self-driving: it does not wait to be told when to stop, and it
never depends on an external driver to stop it.

### Refusing to start is not stopping a run
A REFUSAL and a STOP are not the same event, and the list below is a list of
STOPS. A refusal ends the invocation on the spot and names the condition it
observed instead of a stop reason, because no round of this run ever ran its
course. The refusals are:
the five preconditions of section A;
the unreadable state file of section B, the lock conflict of section B;
and
the abort when `make check` yields no exit code at all in section E.
Each already names what it observed where it is defined, and they are
gathered here
so that the stop list below is exhaustive rather than approximately true.
A reader who finds a run ended for a reason not on that list is looking at a
refusal, and a refusal writes no `STOPPED:` line.

Two paths end an invocation without completing a round and do not fit that
shape cleanly, so they are named here rather than left for a reader to notice.
Precondition 5 is the one refusal that does not end on the spot: a RED baseline is refused as a
place to hunt FROM, but
the run then fixes that failure, reports it and stops, so it ends the
invocation having done work — and no round ran its course, so it writes no
`STOPPED:` line either.
A re-invocation after a `STOPPED:` line is the other path that ends an invocation without completing a round:
it does no work at all, and it reports the stop reason ALREADY recorded in the
file rather than writing a new one (below).
No count of refusals is stated here, and none should be: these two sit on the
boundary, and a stated number is the first thing one more path makes wrong.

These are the permitted stop reasons, and nothing else ends a run that started:

- **dry** — the round's convergence count was zero AND there is nothing left to
  look at: either the recorded floor has passed, or the matrix is fully swept
  with every row `done` and none re-opened. A dry round before the floor stops
  nothing WHILE ROWS REMAIN: sweep the next rows and keep going. But a dry round
  with no rows left stops the run whatever the clock says — the floor exists to
  stop a run giving up while there is still ground to cover, and there is none.
  (Added after a live run walked into the gap between these two reasons: matrix
  fully swept at three of three, convergence zero for two rounds, floor still
  twelve minutes out, and NO permitted stop reason applied. Read literally, the
  run had to keep starting rounds with no rows to sweep until the floor let
  `dry` fire. It terminates, so it is not a hang — it burns budget doing
  nothing and reports nothing about why.)
- **time floor** — the floor has been reached and the matrix is fully swept,
  with every row `done` and none re-opened. There is no work left in scope, and
  the floor is no longer holding the run open. This and `dry` now overlap on the
  swept-matrix case, deliberately: either name is true and either is honest, and
  an overlap between two correct reasons costs nothing, while the gap between
  them cost a run.
- **ceiling** — the recorded wall-clock ceiling was reached. This is the one
  reason that stops the run mid-work: finish the round in flight, leave the
  tree clean, write the state file, commit it as section E requires, and stop.
- **fix budget** — a round exhausted its fix budget and what remains of the
  ceiling has no room for another full round. The findings it could not reach
  are already recorded unfixed, so the next run starts with them proved.
- **kill rule** — every finding still workable has hit the kill rule of section
  E, so no further round can make progress on any of them.
- **round ended red** — the round-end `make check` was red.
- **owner stop** — the owner interrupted the run, or the repo asks it to stop.

Whichever one fired, name it in the verdict. A run
never ends without saying why: a finish with no stated reason is
indistinguishable from a crash, and the next reader has to reconstruct from a
log which of the two they are looking at.

When a stop condition is met, write a `STOPPED: <reason>` line into
`specs/_hunt/HUNT.md`, under `## CURRENT ROUND` where section B declares it, as
the LAST write of the run — then commit the state file exactly as section E
requires, which is the run's last ACT and adds nothing further to the file.
Say in the final message that
no further round is to be started. Then stop — no extra sweep, no one more
area, no "while I am here".

### Being re-invoked after a stop
When `/hunt` is invoked again in a repo
after a `STOPPED:` line has been written into its state file — by a scheduler,
by a fresh session, by anyone — the answer is to
report the recorded stop reason and do no work. Do not sweep, do not file, do
not fix, and never clear the line: a stopped hunt is re-opened by a human
removing that line, and by nothing else.

This is also why the run must stop itself rather than trust something else to
stop it. An external scheduler running on a
fixed interval cannot be stopped by the command it runs, so without this rule a
converged hunt would wake on every tick and
re-sweep forever — spending a full budget each time to re-derive that there is
nothing to find.

## G. The verdict
End with ONE verdict at the end of the run: one message, in one place, rather
than a commentary spread over the hours nobody was reading. It carries:

- **rounds run**, and each round's convergence count, so the shape of the run
  is visible — a hunt that went 4, 2, 1, 0 converged; one that went 1, 1, 1, 1
  was rationed by its fix budget and is not finished.
- **the named stop reason**, from the list in section F and from no other list.
- **findings by class** — how many FIXABLE, REPORT-ONLY and NEEDS-OWNER, and
  where each one was filed.
- **tests added** — the regression tests this run wrote, by name, because they
  are the only durable thing it leaves behind.
- **the branch name with its commit range**, so the whole run can be read with
  one `git log`.

The NEEDS-OWNER batch of section D, and any stale-lock takeover of section B,
go in this same verdict. There is no second report.

### SKIPPED is not passed
A lane that could not run — a worktree that could not be created, a missing
tool, an agent that returned nothing — is
reported as SKIPPED, with the reason it could not run.
Never report a lane that could not run as one that passed. An unattended run's
report is read by someone who was not there, so a silently missing lane reads
as a clean sweep of an area nothing ever looked at.

### Fixed but untested is not green
A run that fixed findings but
left them without tests is not a green run, and
the verdict says so — in its summary line, not in a footnote. An untested fix
is a change nobody can prove, and the next run cannot tell it apart from a fix
that was never made.

## H. What it must never do
This list is absolute, and it is short enough to hold in mind at the end of a
long run. Every line below is
what a stuck loop reaches for when nobody is watching, which is exactly the
condition this command runs in.

- **Never push.** Not the hunt branch, not a tag, not to a fork, not with a
  flag that makes it look like something else.
- **Never deploy**, and never run anything the repo declares to be a deploy.
- **Never merge into the default branch**, never rebase it, and never open a
  merge for someone else to click. Everything this run makes stops at a local
  branch, and Gate 2 is the owner's door.
- **Never edit a protected path.** A REPORT-ONLY finding is filed and left
  alone, however small the fix looks.
- **Never decide a NEEDS-OWNER finding.** Carry it to the owner as a question,
  never as a change already made.
- **Never rewrite history** — no `commit --amend`, no `rebase`, no
  `reset --hard`, no force of any kind. A history rewritten unattended destroys
  the only record of what the run did.
- **Never delete or disable a test**, and never weaken an assertion, skip a
  case or mark one expected-to-fail to get a suite green.
- **Never edit the `specs/` of another feature**, and never
  tick a task checkbox anywhere. Checkboxes are execution state a build owns;
  a hunt that ticks one reports work that was never done.
- **Never edit `.claude/settings.json` or the engine map.** A loop that widens
  its own permissions or changes which engine runs it has stopped being the
  thing that was approved to run unattended.

