# Requirements — hunt

<!-- `/hunt` is an unattended bug-hunt loop for any repo that has the Makefile
     contract. It asks the one question no other command asks: DOES THE CODE
     STILL HOLD? — /test-audit asks whether the tests mean anything, /rca takes
     one KNOWN bug and kills its class, /build executes an approved spec. /hunt
     has no spec to execute: it goes looking, proves what it found, fixes what
     it can prove, and files the rest.

     Wording convention (inherited from generic-core and engine-map): a command
     is a prompt file. Its requirements say "THE commands/hunt.md SHALL instruct
     the model to …" or "SHALL contain …", so a content assertion proves exactly
     the claim and `verify: unit` is literally true. Whether the model then
     FOLLOWS the text is live-fired by the owner at Gate 2 — that is what
     `verify: deferred` marks, and there are four of them, not one.

     TEST_PROFILE = lib. commands/*.md is inside the scrub fence: no project
     names, no literal four-digit years in the command file (use <YYYY-MM-DD>).

     IDs are permanent. Where spec review split a requirement, the original ID
     was NARROWED and a new ID appended — never renumbered, never reused.

     The design premise, stated once: this command edits and commits source code
     with nobody watching. Every requirement below that looks like paranoia — the
     lock, the ceiling, the format version, the re-opening matrix, running the
     checks itself — is there because the alternative is a silent wrong answer at
     3am. -->

## A. Refusing to start

REQ-HUNT-001  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to abort with a named reason, before any other work, if the repo
              has no `check` target in a Makefile — a repo with no contract has
              no baseline, and a hunt without a baseline cannot tell a finding
              from a pre-existing failure.
              verify: unit

REQ-HUNT-002  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to abort with a named reason if the working tree is dirty, because
              hunting on top of a half-finished edit attributes someone else's
              change to this run.
              verify: unit

REQ-HUNT-003  WHEN commands/hunt.md is read, THE FILE SHALL name the hunt branch
              pattern `sdlc/hunt-<YYYY-MM-DD>`, SHALL instruct the model to
              reuse the branch recorded in the state file when one is recorded,
              SHALL require an abort with a named reason when the recorded
              branch and the current branch disagree, and SHALL refuse to run on
              the repository's default branch.
              verify: unit

REQ-HUNT-004  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to run `make check` as a baseline before the first round, and to
              treat a RED baseline as the whole job of the run — fix that
              failure, report it, stop — never as a starting point to hunt from.
              verify: unit

REQ-HUNT-005  WHEN commands/hunt.md is read, THE FILE SHALL state that each
              abort in section A reports WHICH precondition failed, so an
              unattended run never ends in silence.
              verify: unit

REQ-HUNT-055  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to run the repo's requirement-coverage gate as a precondition and
              to abort with a named reason when it is ALREADY failing, and SHALL
              forbid the run from editing any `specs/<feature>/` directory to
              clear it. The gates are repo-global: another feature's coverage gap
              would otherwise block every commit this run makes.
              verify: unit

REQ-HUNT-057  WHEN commands/hunt.md is read, IT SHALL open with frontmatter
              carrying a one-line `description:`.
              verify: unit

REQ-HUNT-058  WHEN commands/hunt.md is read, THE FILE SHALL define its
              `$ARGUMENTS` surface — `floor: <duration>`, `ceiling: <duration>`,
              `fixes: <count>`, `areas: <names>` — all optional and accepted in
              any order, and SHALL name the default used for each when absent.
              verify: unit

## B. State — the hunt file

REQ-HUNT-006  WHEN commands/hunt.md is read, THE FILE SHALL name
              `specs/_hunt/HUNT.md` as the run's state, SHALL state that the
              requirement gates never see it BECAUSE THEY SCAN
              `specs/*/requirements.md` and `specs/_hunt/` contains none, and
              SHALL forbid the run from ever creating a `requirements.md` under
              `specs/_hunt/`.
              verify: unit

REQ-HUNT-007  WHEN commands/hunt.md is read, THE FILE SHALL specify that
              `specs/_hunt/HUNT.md` holds an AREA MATRIX (one row per area, each
              carrying a status), a SEEN list (one line per candidate ever
              judged, with its verdict), and the CURRENT ROUND (its number, the
              run's start time, and the run's computed floor, ceiling and fix
              budget).
              verify: unit

REQ-HUNT-008  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to resume from an existing `specs/_hunt/HUNT.md` rather than
              starting a new matrix, so that a fresh invocation continues the
              same hunt.
              verify: unit

REQ-HUNT-009  WHEN commands/hunt.md is read, THE FILE SHALL seed the matrix with
              one row per top-level source directory tracked by git, excluding
              vendored, generated and dependency paths, capped at a stated
              maximum with the remainder folded into one `other` row, and SHALL
              record in the state file the rule used and what it excluded.
              verify: unit

REQ-HUNT-010  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to write the state file at the END OF EVERY ROUND, so that a
              crashed or interrupted run loses one round rather than the whole
              hunt.
              verify: unit

REQ-HUNT-051  WHEN commands/hunt.md is read, THE FILE SHALL require
              `specs/_hunt/HUNT.md` to carry a format-version line as its first
              line, and SHALL require the state file to be written atomically —
              to a temporary file in the same directory, then renamed.
              verify: unit

REQ-HUNT-052  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model,
              IF the state file exists but is missing a named section or carries
              an unrecognised format version, to stop before hunting and report
              the file and what was wrong, and SHALL FORBID overwriting or
              re-seeding it — re-seeding discards SEEN, and every finding from
              every previous run is then re-filed.
              verify: unit

REQ-HUNT-011  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to dedupe against the SEEN list BY SEARCHING IT, and SHALL forbid
              reading the list end to end — the list grows without bound and the
              context does not.
              verify: unit

REQ-HUNT-059  WHEN commands/hunt.md is read, THE FILE SHALL specify the SEEN
              line format as one line per candidate carrying its verdict, its
              `<path>:<line>`, and a short mechanism key, and SHALL define the
              dedupe match as PATH AND KEY together — path alone collides two
              different bugs in one file and silently drops the second.
              verify: unit

REQ-HUNT-060  WHEN commands/hunt.md is read, THE FILE SHALL require SEEN entries
              older than a stated number of rounds to be moved to a
              `## SEEN (archived)` section of the same file, which dedupe still
              searches, and SHALL forbid deleting a SEEN entry.
              verify: unit

REQ-HUNT-012  WHEN commands/hunt.md is read, THE FILE SHALL state that a
              candidate already carrying a verdict in SEEN is never re-filed,
              including a candidate judged REFUTED in an earlier round.
              verify: unit

REQ-HUNT-047  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to claim the run by writing a `RUN LOCK:` line carrying the branch,
              the start time and a run identifier into `specs/_hunt/HUNT.md`
              before the first round, and to abort with a named reason when an
              unexpired lock naming a different run is already present.
              verify: unit

REQ-HUNT-048  WHEN commands/hunt.md is read, THE FILE SHALL define a lock as
              stale once it is older than the run's recorded ceiling, SHALL
              permit a stale lock to be taken over, and SHALL require the
              takeover to be named in the verdict.
              verify: unit

## C. The round, and the refutation gate

REQ-HUNT-013  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to take AT MOST THREE area rows marked not-done per round, rather
              than one row (which needs as many rounds as the repo has areas) or
              all of them (which is the whole-repo sweep this requirement exists
              to prevent).
              verify: unit

REQ-HUNT-014  WHEN commands/hunt.md is read, THE FILE SHALL send the sweep — the
              enumeration of candidates in an area — to the `researcher` agent,
              whose role is `read`, because the sweep is volume work and volume
              is what it costs.
              verify: unit

REQ-HUNT-015  WHEN commands/hunt.md is read, THE FILE SHALL send every fresh
              candidate to the `evidence` agent to be REPRODUCED, SHALL state
              that a candidate which cannot be reproduced is recorded REFUTED,
              and SHALL have the main session judge refutation from the returned
              evidence. The `verifier` agent is NOT used here: it verifies a
              finished branch from a worktree and has neither branch nor diff
              for a bare candidate.
              verify: unit

REQ-HUNT-016  WHEN commands/hunt.md is read, THE FILE SHALL require a finding to
              be recorded with its file path and line, and the observable
              behaviour that makes it wrong.
              verify: unit

REQ-HUNT-017  WHEN commands/hunt.md is read, THE FILE SHALL cap concurrent lanes
              at THREE, and SHALL state that the dispatching main session
              enforces the cap.
              verify: unit

REQ-HUNT-018  WHEN commands/hunt.md is read, THE FILE SHALL require each fix
              lane to work in its own worktree, as `/build` does, rather than
              sharing one tree — the framework already solved lane isolation and
              this command SHALL NOT invent a weaker model.
              verify: unit

REQ-HUNT-019  WHEN commands/hunt.md is read, THE FILE SHALL state that read-only
              sweep lanes may share a tree, and SHALL forbid any lane from
              writing to it.
              verify: unit

## D. Classifying a finding

REQ-HUNT-020  WHEN commands/hunt.md is read, THE FILE SHALL classify every
              confirmed finding into exactly one of FIXABLE, REPORT-ONLY or
              NEEDS-OWNER.
              verify: unit

REQ-HUNT-064  WHEN commands/hunt.md is read, THE FILE SHALL define the three
              classes verbatim: FIXABLE is a finding the run may fix under its
              own gates; REPORT-ONLY is a finding inside a protected path, filed
              and never edited; NEEDS-OWNER is a finding whose fix needs a
              decision only the owner can make.
              verify: unit

REQ-HUNT-021  WHEN commands/hunt.md is read, THE FILE SHALL read the same
              protected paths `/rca` reads — the repo's `protected paths:`
              declaration and `.claude/hooks/no_fix_zones.txt` when it has one —
              and SHALL forbid editing any path they name.
              verify: unit

REQ-HUNT-023  WHEN commands/hunt.md is read, THE FILE SHALL forbid the loop from
              deciding a NEEDS-OWNER finding.
              verify: unit

REQ-HUNT-024  WHEN commands/hunt.md is read, THE FILE SHALL file findings
              through the repo's declared `tracker:` command, SHALL require the
              tracker to be searched for an existing open item before filing,
              SHALL cap the number of tracker items one run may create, and
              SHALL record findings in the state file and the verdict instead
              when the repo declares no tracker.
              verify: unit

REQ-HUNT-056  WHEN commands/hunt.md is read, THE FILE SHALL require ALL
              NEEDS-OWNER findings from a run to be delivered as ONE BATCH in
              the verdict in the decision-first format, never as separate
              interruptions — the Decision Protocol batches questions at the
              gates and forbids interrupting mid-build.
              verify: unit

## E. Fixing, and the flywheel

REQ-HUNT-025  WHEN commands/hunt.md is read, THE FILE SHALL send each FIXABLE
              finding to the `implementer` agent, whose role is `build`, and
              SHALL require the failing regression test to be written before the
              fix.
              verify: unit

REQ-HUNT-026  WHEN commands/hunt.md is read, THE FILE SHALL require the model to
              RUN `make check` ITSELF and record its exit code as the evidence a
              fix is committable, SHALL state that the commit hook failing to
              block is NOT evidence the checks passed — it is a PreToolUse hook
              with a timeout and it fails open — and SHALL abort the run with a
              named reason when it cannot obtain an exit code.
              verify: unit

REQ-HUNT-027  WHEN commands/hunt.md is read, THE FILE SHALL require each
              confirmed finding to be taken through `/rca` rather than restating
              the flywheel here, so the rule about rules lives in one place.
              verify: unit

REQ-HUNT-028  WHEN commands/hunt.md is read, THE FILE SHALL apply the routing
              policy's kill rule — three failed attempts on the same error —
              per finding, and SHALL require the abandoned finding to be filed
              with what was tried.
              verify: unit

REQ-HUNT-029  WHEN commands/hunt.md is read, THE FILE SHALL forbid weakening or
              deleting an assertion to make a suite go green.
              verify: unit

REQ-HUNT-050  WHEN commands/hunt.md is read, THE FILE SHALL require findings
              beyond the round's fix budget to be recorded in SEEN as unfixed
              with their class, and SHALL forbid dropping them.
              verify: unit

REQ-HUNT-053  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model,
              whenever a round commits a fix, to mark every matrix row whose
              files that fix touched as NOT-DONE, so an area the run itself
              changed is re-swept. Without this the matrix only ever fills up
              and a regression the run caused is invisible to it.
              verify: unit

REQ-HUNT-061  WHEN commands/hunt.md is read, THE FILE SHALL require every round
              to end with the working tree clean — every change either committed
              or reverted — before the state file is written.
              verify: unit

## F. Convergence, the budget, and stopping

REQ-HUNT-030  WHEN commands/hunt.md is read, THE FILE SHALL require a
              convergence line to be COMPUTED AND WRITTEN into the state file at
              the end of every round, carrying the count of confirmed FIXABLE
              findings for that round.
              verify: unit

REQ-HUNT-031  WHEN commands/hunt.md is read, THE FILE SHALL define DRY as that
              count being zero.
              verify: unit

REQ-HUNT-032  WHEN commands/hunt.md is read, THE FILE SHALL exclude NEEDS-OWNER
              and REPORT-ONLY findings from the convergence count, because they
              are the owner's queue and not the loop's, and a loop that counted
              them would never converge.
              verify: unit

REQ-HUNT-033  WHEN commands/hunt.md is read, THE FILE SHALL require the run's
              time floor to be resolved ONCE at the start from the `floor:`
              argument or its stated default, recorded in the state file, and
              compared against thereafter — and SHALL forbid re-deriving it each
              round, which makes a floor trivially true and ends a hunt after
              one pass.
              verify: unit

REQ-HUNT-049  WHEN commands/hunt.md is read, THE FILE SHALL require a per-run
              wall-clock CEILING and a maximum number of findings fixed per
              round to be resolved at the start, recorded in the state file
              beside the floor, and SHALL name the default used for each when
              the invocation gives none. A floor gives the run a reason to keep
              going; nothing else gives it a reason to stop spending.
              verify: unit

REQ-HUNT-054  WHEN commands/hunt.md is read, THE FILE SHALL require the full
              `make check` to be green at the END of every round as well as
              before each commit, and SHALL make a round that ends red a named
              stop reason.
              verify: unit

REQ-HUNT-034  WHEN commands/hunt.md is read, THE FILE SHALL name the permitted
              stop reasons — dry, time floor, ceiling, fix budget, kill rule,
              round ended red, owner stop — and SHALL require the reason to be
              stated in the verdict, so a run never ends without saying why.
              verify: unit

REQ-HUNT-035  WHEN commands/hunt.md is read, THE FILE SHALL instruct the model
              to run rounds ITSELF until a stop condition is met, and, when one
              is met, to write a `STOPPED: <reason>` line into
              `specs/_hunt/HUNT.md` as the last write of the run and to state in
              its final message that no further round is to be started. The
              command SHALL NOT depend on any external driver to stop it.
              verify: unit

REQ-HUNT-062  WHEN commands/hunt.md is read, THE FILE SHALL state that an
              external scheduler re-invoking `/hunt` after a `STOPPED:` line has
              been written is answered by reporting the recorded stop reason and
              doing no work.
              verify: unit

## G. The verdict

REQ-HUNT-036  WHEN commands/hunt.md is read, THE FILE SHALL require ONE verdict
              at the end of the run carrying: rounds run, each round's
              convergence count, the named stop reason, findings by class, tests
              added, and the branch name with its commit range.
              verify: unit

REQ-HUNT-037  WHEN commands/hunt.md is read, THE FILE SHALL require a lane that
              could not run to be reported as SKIPPED with its reason, and SHALL
              forbid reporting it as a lane that passed.
              verify: unit

REQ-HUNT-038  WHEN commands/hunt.md is read, THE FILE SHALL state that a run
              which fixed findings but left them without tests is not a green
              run, and that the verdict says so.
              verify: unit

## H. What it must never do

REQ-HUNT-039  WHEN commands/hunt.md is read, THE FILE SHALL contain an explicit
              prohibition list covering at least: never push, never deploy,
              never merge into the default branch, never edit a protected path,
              and never decide a NEEDS-OWNER finding.
              verify: unit

REQ-HUNT-063  WHEN commands/hunt.md is read, THAT SAME prohibition list SHALL
              also cover: never rewrite history (amend, rebase, reset --hard,
              any force), never delete or disable a test, never edit another
              feature's `specs/` or tick a task checkbox, and never edit
              `.claude/settings.json` or the engine map. Each is something a
              stuck loop reaches for when nobody is watching.
              verify: unit

## I. Discoverability

REQ-HUNT-040  WHEN README.md is read, THE `commands/` BLOCK inside its
              `## Layout` section SHALL list `hunt.md` with a one-line
              description.
              verify: unit

REQ-HUNT-041  WHEN ainative_sdlc.html is read, ITS control-panel command table
              SHALL carry a row for `/hunt` describing it as the unattended
              bug-hunt loop, AND the command count stated in the prose above
              that table SHALL match the number of rows in it.
              verify: unit

REQ-HUNT-042  WHEN ainative_sdlc.html and README.md are read, THEY SHALL
              distinguish `/hunt` from `/test-audit` and `/rca` in one line
              each: hunt looks for bugs, test-audit judges the tests, rca kills
              the class of one known bug.
              verify: unit

## K. Fixes from fresh-eyes verification

<!-- Gate 2 verification returned FAIL. These IDs exist because the artifact
     contradicted itself in ways no content assertion could catch: the file was
     written in three passes and the passes disagreed. Each one below is a
     defect that was REPRODUCED, not predicted. -->

REQ-HUNT-065  WHEN commands/hunt.md is read, THE FILE SHALL instruct the run to
              COMMIT `specs/_hunt/HUNT.md` as the last act of every round, and
              the clean-tree precondition SHALL say that the run's own committed
              state file is the one thing it expects to find already tracked.
              Without this the round ends by dirtying the tree, the next
              invocation aborts on the dirty-tree precondition, and the resume
              the whole command is built on can never happen.
              verify: unit

REQ-HUNT-066  WHEN commands/hunt.md is read, THE STATE FILE SHAPE IT SHOWS SHALL
              include every field later sections require to be written into it —
              a per-round convergence log carrying each round's count, and the
              `STOPPED:` line — because the file also declares a state file
              missing a named section unreadable and refuses to repair it.
              verify: unit

REQ-HUNT-067  WHEN commands/hunt.md is read, THE FILE SHALL distinguish
              REFUSING TO START from STOPPING A RUN, and its "nothing else ends
              a run" claim SHALL be true of the stop list: the section A
              refusals, the unreadable-state-file stop, the lock conflict and
              the no-exit-code abort are named as refusals, not silent
              exceptions to an exhaustive list.
              verify: unit

REQ-HUNT-068  WHEN commands/hunt.md is read, THE FILE SHALL send only FIXABLE
              findings through the `/rca` flywheel's fixing steps, because
              REPORT-ONLY findings sit in protected paths the file forbids
              editing, and SHALL say which lane runs it.
              verify: unit

REQ-HUNT-069  WHEN commands/hunt.md is read, THE FILE SHALL instruct the run how
              to COMMIT a fix — that it commits at all, and the message shape —
              since a later section says "whenever a round commits a fix" while
              no section ever tells it to.
              verify: unit

REQ-HUNT-070  WHEN commands/hunt.md is read, IT SHALL NOT claim that `make
              check` calls the requirement gate: that is true of this repo's own
              Makefile and of none of the three shipped templates, and the
              command ships to any repo with the contract.
              verify: unit

REQ-HUNT-071  WHEN a load-bearing clause of commands/hunt.md is deleted, THE
              TEST SUITE SHALL go red. Assertions SHALL pin the behaviour rather
              than a word that recurs elsewhere in the file — proven for
              REQ-HUNT-003, whose abort rule could be deleted entirely with the
              suite still green, and for the same weakness in REQ-HUNT-004, 007,
              024, 047, 048, 052 and 055.
              verify: unit

## L. Residuals disclosed by re-verification

<!-- Re-verification PASSED the five original findings and ranked these below
     them: none re-creates a deadlock, all were disclosed rather than carried
     silently. They are fixed here rather than left as known debt. -->

REQ-HUNT-072  WHEN commands/hunt.md is read, EVERY section of the state file
              that a seeded, pre-round-1 file legitimately lacks SHALL carry the
              same explicit seed carve-out `## CONVERGENCE LOG` has. Without it
              the asymmetry invites reading `## FINDINGS` as legitimately absent
              in a repo that declares a tracker, which the unreadable-state rule
              then refuses to repair — the same unrecoverable state the resume
              deadlock produced.
              verify: unit

REQ-HUNT-073  WHEN commands/hunt.md is read, THE SEEN LINE SHAPE IT DECLARES
              SHALL carry every field later sections require of it: the verdict,
              `<path>:<line>`, the mechanism key, the round, the class, what was
              tried for an abandoned finding, and the unfixed marker for one past
              the fix budget.
              verify: unit

REQ-HUNT-074  WHEN commands/hunt.md is read, THE STATE FILE SHAPE SHALL declare
              `areas:` alongside the floor, ceiling and fix budget, because the
              arguments section says all four resolved values are recorded there.
              verify: unit

REQ-HUNT-075  WHEN commands/hunt.md is read, IT SHALL use ONE vocabulary for a
              matrix row's two states throughout — the same two words in the
              file shape, the round, the fixing rules and the convergence check.
              verify: unit

REQ-HUNT-076  WHEN commands/hunt.md is read, ITS enumeration of refusals SHALL
              account for every path that ends an invocation without completing
              a round, including the red baseline (which does work first) and a
              re-invocation after `STOPPED:`, or SHALL drop the exact count
              rather than state one that is wrong.
              verify: unit

REQ-HUNT-077  WHEN commands/hunt.md and commands/build.md are read, THE
              MERGE-BACK STEP hunt.md cites SHALL actually be documented in
              build.md. A command may reference another's rule instead of
              restating it only when the rule is there to reference.
              verify: unit

## J. Live-fire (owner, at Gate 2)

REQ-HUNT-043  WHEN the owner runs `/hunt` in a repo with the contract, THE
              COMMAND SHALL complete at least one round, write
              `specs/_hunt/HUNT.md` with all its named sections, and end with a
              verdict naming its stop reason.
              verify: deferred

REQ-HUNT-044  WHEN the owner runs `/hunt` on a dirty tree, and again on the
              default branch, THE COMMAND SHALL refuse each time and name the
              precondition that failed.
              verify: deferred

REQ-HUNT-045  WHEN the owner runs `/hunt` a second time in the same repo, THE
              COMMAND SHALL resume — matrix rows already done stay done, and no
              finding from the first run is re-filed.
              verify: deferred

REQ-HUNT-046  WHEN the owner runs `/hunt` and it resumes later the same day, THE
              COMMAND SHALL still run more than one round, proving the floor was
              recorded once rather than re-derived.
              verify: deferred

## K. Project sweep lanes

REQ-HUNT-078  WHEN a repo's CLAUDE.md carries a `hunt lanes: <agent>[, <agent>...]`
              line, commands/hunt.md SHALL direct the run to dispatch each named
              agent as an additional read-only sweep lane over the same area,
              returning candidates only and counting against the lane cap; with
              no such line the `researcher` sweeps alone. (A project with its
              own specialised finders can hand its unattended run to `/hunt`,
              so those finders feed one SEEN list instead of a second loop.)
              verify: unit

REQ-HUNT-079  WHEN a confirmed finding already has an open item in the repo's
              declared tracker, commands/hunt.md SHALL direct the run to read
              that item before classifying, and to classify the finding
              NEEDS-OWNER when the owner has commented STOP on it or removed the
              repo's approval label — the tracker being the owner's kill switch
              over an unattended run.
              verify: unit
