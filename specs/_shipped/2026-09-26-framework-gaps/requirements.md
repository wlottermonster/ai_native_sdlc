# Requirements — framework-gaps

<!-- Three gaps in the framework itself, none of them theoretical:

     1. The commit gate is a PreToolUse hook with a timeout, and a PreToolUse
        hook FAILS OPEN. In a repo whose `check` exceeds the timeout, every
        commit passes ungated while LOOKING gated. Two large repositories with
        roughly 8-minute unit suites exceed a 300s limit. `/hunt` already works
        around it by running the checks itself; the framework does not, and its
        own "Known gaps" does not mention it.
     2. `apply-engines.sh` rewrites only the global agents. A repo with its own
        agents keeps their `model:` lines in step BY HAND, so a repo can quietly
        run on a model the owner moved off months ago. A repository can carry
        a dozen or more such agents.
     3. The gates run locally only. A push that skipped a local gate has nothing
        behind it. A CI mirror closes that gap, and it costs one file.

     TEST_PROFILE = lib. The scrub fence covers README.md, install.sh,
     scripts/*.sh and templates/**: no project names, no literal four-digit
     years. The framework names no model. -->

## A. The gate that fails open

REQ-GAP-001  WHEN README.md's "Known gaps" section is read, IT SHALL state that
             the commit gate runs as a PreToolUse hook with a timeout and that a
             hook which times out does NOT block — so in a repo whose `check`
             exceeds the timeout, commits pass ungated while appearing gated.
             verify: unit

REQ-GAP-002  WHEN README.md is read, IT SHALL state the rule that follows from
             that: the absence of a block is not evidence the checks passed, and
             a repo must keep `check` inside the timeout or know it is ungated.
             verify: unit

REQ-GAP-003  WHEN settings/hooks-snippet.json is read, IT SHALL name the
             commit-gate timeout as the budget a repo's `check` must fit inside,
             and say what happens when it does not — in its TOP-LEVEL comment,
             and NEVER as a key inside a hook entry object.
             (Amended after verification. The first build put the comment inside
             the hook entry. Claude Code's documentation says it does not accept
             comments in a settings file, unknown-key tolerance inside a hook
             object is undocumented, and a schema validation error rejects the
             WHOLE settings file — so a merge of that snippet risked taking every
             hook, permission and setting with it, silently. `jq -e .` proves the
             file is JSON; it proves nothing about the harness's schema.)
             verify: unit

REQ-GAP-012  WHEN settings/hooks-snippet.json is read, NO hook entry object
             SHALL carry any key beyond those the hook schema defines, and the
             file SHALL tell the reader to run `/hooks` after merging and confirm
             the commit gate is listed — the only way to see that an entry was
             accepted rather than silently dropped.
             verify: unit

REQ-GAP-004  WHEN templates/Makefile.python, templates/Makefile.node and
             templates/Makefile.static are read, EACH SHALL carry a comment
             stating the timeout budget `check` must fit inside and directing a
             repo that cannot to split the slow work into `test`.
             verify: unit

## B. Repo-local agents drift off the map

REQ-GAP-005  WHEN scripts/apply-engines.sh is run with an agents directory given
             in the environment, IT SHALL rewrite the `model:` lines of the
             agents in THAT directory using a `roles.conf` found beside them,
             rather than only the global ones.
             verify: integration

REQ-GAP-006  WHEN scripts/apply-engines.sh is run that way and the directory has
             no `roles.conf`, IT SHALL report that and change nothing, rather
             than guessing a role for an agent.
             verify: integration

REQ-GAP-007  WHEN scripts/apply-engines.sh is run that way, IT SHALL read the
             engine map from its usual machine-level location, because the map
             is the single binding and a repo must not carry its own.
             verify: integration

REQ-GAP-008  WHEN README.md's "Project layer" section is read, IT SHALL name the
             command that keeps a repo's own agents in step with the map, in
             place of the current statement that they are the repo's to maintain
             by hand.
             verify: unit

## D. The class a live `/hunt` found — a gate that cannot verify must not allow

<!-- Found by the first live `/hunt` run and confirmed by an evidence lane: the
     commit gate exited 0 (ALLOW) when a `cd` failed, and in one path ran
     `make check` in a DIFFERENT repository and allowed the commit on that
     result. Root cause: a guard that tests `[ -d ]` and then acts as though the
     operation must succeed. `-d` does not test the execute bit; `-f` does not
     test readability. The sibling sweep found the same shape in three more
     places, so this is the class, not the instance. -->

REQ-GAP-013  WHEN a hook under hooks/ cannot reach or read the repository it is
             meant to check, IT SHALL exit non-zero and name what it could not
             do, and SHALL NOT exit 0. A gate that cannot verify must never
             allow: exit 0 from a gate is an ALLOW and has to be earned.
             Narrowed after verification, which pointed out that the original
             wording said "any hook" while the tests covered three by behaviour
             and two by reading their source. It now claims what is proven.
             The exit CODE differs by position and that is deliberate:
             check-gate.sh and dod.sh exit 2 (blocking), and req-gate.sh exits 1
             (non-blocking, still loud) because it drains stdin and therefore
             cannot read `stop_hook_active` — a blocking exit from a Stop hook,
             on a condition the model cannot fix, would have no loop break.
             verify: integration

REQ-GAP-015  WHEN a mutant reintroduces a fail-open into hooks/dod.sh or
             hooks/req-gate.sh by ANY spelling — a swallowed cd, an `if ! cd`
             block, a different redirect — THE TEST SUITE SHALL go red. A grep
             for one literal spelling of the old line is not a test of the
             behaviour; it is a test of the spelling, and the next fail-open
             will not be spelled the same way.
             verify: integration

REQ-GAP-014  WHEN scripts/apply-engines.sh is given a map or manifest that
             exists but cannot be READ, IT SHALL say the file is not readable
             and exit non-zero, naming the unreadable file FIRST so the true
             cause is the first thing read.
             Narrowed after verification: the original said "rather than"
             reporting the downstream cascade, and the cascade still prints
             after the true cause. Suppressing it would mean unwinding the
             validate-everything-then-report design, which is worth more than
             a tidy error list. What matters is that the reader is not left
             inferring the cause from seven wrong ones, and that is what this
             now claims. A readable-but-EMPTY map still produces the cascade
             with no true-cause line: recorded, not fixed, and not claimed.
             verify: integration

## C. No CI mirror

REQ-GAP-009  WHEN templates/ is listed, IT SHALL contain a CI workflow template
             that runs the repo's `make check` on push and on pull request, so a
             repo can close the local-only gap by copying one file.
             verify: unit

REQ-GAP-010  WHEN that template is read, IT SHALL state in a comment that it
             deliberately runs `check` and not `test`, and that any suite
             needing credentials stays out of CI and is run by hand before a
             deploy.
             verify: unit

REQ-GAP-016  WHEN README.md's file map is read, EVERY file shipped in
             templates/ SHALL appear in it. The map lists templates
             individually, so one that is missing is invisible to a reader
             deciding what the framework offers.
             (Its own ID because the assertion had been filed under the CI
             workflow's requirement, so a missing template failed while naming
             the wrong rule — a test that misreports what broke costs the next
             reader the time it was meant to save.)
             verify: unit

REQ-GAP-011  WHEN README.md's "Known gaps" is read, ITS no-CI-mirror entry SHALL
             point at that template as the way to close it.
             verify: unit
