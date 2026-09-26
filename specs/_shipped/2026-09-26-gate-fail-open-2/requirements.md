# Requirements — gate-fail-open-2

<!-- Three fail-opens and one design gap in the commit gate, each confirmed by
     reproduction in a scratch repository, plus a stale pre-push guard in
     push.sh and two siblings found by the sweep.

     1. The docs-only shortcut read the index WHEN THE HOOK RAN. With a .md file
        already staged, `git add code.py && git commit`, `git commit -a` and
        `git commit code.py` all exited 0 and a failing `make check` never ran.
     2. `bash "$gate" || exit $?` passed req-gate.sh's exit 1 ("could not
        verify") through, and a PreToolUse exit 1 does not block.
     3. A req-gate.sh found nowhere printed "coverage gates skipped" and
        exited 0.
     4. The docs-only shortcut skipped the requirement gate entirely, so the
        commit that ticks the last box — a prose-only commit — was never
        coverage-checked.
     5. push.sh reinstalled the pre-push guard only when its marker line was
        missing, so a stale guard was never refreshed.

     TEST_PROFILE = lib. The scrub fence covers hooks/*.sh and README.md. -->

## A. The docs-only shortcut

REQ-GATE-014  WHEN every staged path is prose by extension, THE COMMIT GATE
              SHALL skip `make check` only if the command commits the index
              exactly as it stands: `cd` steps and one git invocation, that
              commit, carrying only options known not to change its content.
              WHEN the command also runs any other git invocation (`add`,
              `rm`, `mv`, `stage`, …), passes a pathspec or `--`, uses `-a`,
              `--all`, `-i`, `--include`, `-o`, `--only`, `-p` or
              `--interactive`, sets an environment variable, contains a
              command substitution other than a `$(cat <<EOF …)` message, or
              cannot be tokenised, IT SHALL run the full check.
              verify: integration

REQ-GATE-017  WHEN the docs-only shortcut is taken, THE COMMIT GATE SHALL NOT
              invoke `make` and SHALL still run the requirement gate, blocking
              with exit 2 when it fails.
              verify: integration

## B. The requirement gate at commit time

REQ-GATE-015  WHEN req-gate.sh exits non-zero during a commit, THE COMMIT GATE
              SHALL exit 2 with a message beginning "COMMIT BLOCKED" that
              carries req-gate.sh's own output. req-gate.sh's exit codes on the
              Stop path are unchanged.
              verify: integration

REQ-GATE-016  WHEN req-gate.sh is found neither in the repository's hooks/ nor
              in ~/.claude/hooks, THE COMMIT GATE SHALL exit 2 and tell the
              reader to run install.sh.
              verify: integration

REQ-GATE-019  WHEN a feature directory under specs/ cannot be listed or
              entered, specs/ itself cannot be searched, or a requirements.md
              or tasks.md exists but cannot be read, THE REQUIREMENT GATE SHALL
              exit 1 saying coverage was not checked and naming each path,
              never passing as if the feature had no requirements.
              verify: integration

REQ-GATE-020  WHEN no Makefile check target exists and package.json exists but
              cannot be read, THE COMMIT GATE SHALL refuse the commit with
              exit 2, never reading the repo as having no check contract.
              verify: integration

## C. The pre-push guard

REQ-GATE-018  WHEN push.sh runs, IT SHALL run `publish.sh --install-guard`
              before every push, whatever the existing pre-push hook contains,
              so a stale guard that still carries the marker line is replaced.
              verify: integration
