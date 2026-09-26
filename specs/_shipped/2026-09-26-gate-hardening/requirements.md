# Requirements — gate-hardening

<!-- Found reviewing installed repositories against the three disciplines the
     framework claims: harness engineering, loop engineering, context
     engineering.

     1. The commit gate's self-filter grepped the raw command text. A read-only
        `ls .git/hooks/pre-commit` matched it, ran the repo's whole suite, and —
        because that suite was red for an unrelated reason — refused a command
        that touched nothing. The heredoc half of this had already been fixed
        in an INSTALLED copy and never ported back to the source checkout, so
        the next install would have reverted it.
     2. The commit gate's fails-open-on-timeout was recorded as a Known gap and
        left there. It is closable from inside the gate: read the timeout the
        gate was installed with, stop the checks before it, and refuse.
     3. A repo's CLAUDE.md can name slash commands that no longer exist.
        Nothing checked that a `/name` in the instructions resolves to anything;
        the agent-reference check next to it already proved the shape works.
     4. The hooks snippet shipped a push gate as a global default. Whether push
        deploys is a fact about a repo, not about the machine.
     5. A decision put to the owner comes as options, never a bare yes/no.

     TEST_PROFILE = lib. The scrub fence covers hooks/*.sh, scripts/*.sh,
     settings/*.json and templates/**: no project names, no four-digit years. -->

## A. The commit filter matches shell, not prose

REQ-GATE-001  WHEN the command text contains a heredoc whose BODY mentions a
              commit and nothing outside the body does, THE COMMIT GATE SHALL
              not treat the command as a commit and SHALL run no checks; the
              same words outside a heredoc SHALL still gate.
              verify: integration

REQ-GATE-002  WHEN the word `git` appears only as part of a path or a longer
              word (`.git/hooks/pre-commit`, `mygit`), THE COMMIT GATE SHALL not
              treat the command as a commit; WHEN `git` stands as a command word
              — at the start, after whitespace, a quote or a shell operator,
              including `/usr/bin/git` — followed by `commit`, IT SHALL gate.
              verify: integration

REQ-GATE-003  WHEN `commit` appears only inside another token (`--no-commit`,
              `pre-commit`) or on the far side of a pipe or command separator
              from `git`, THE COMMIT GATE SHALL not treat the command as a
              commit; a `commit` followed by a separator (`git commit -m x;`)
              SHALL still gate.
              verify: integration

REQ-GATE-010  WHEN the command's leading `cd` names a path beginning with `~/`,
              `$HOME/` or `${HOME}/`, THE COMMIT GATE SHALL expand it to the
              user's home and check THAT repository, never falling through to
              the session's cwd. (Found while building this spec: a command
              of the form `cd ~/repo && git commit` was gated against the
              repository the session happened to be standing in.)
              verify: integration

## B. The gate keeps its own clock

REQ-GATE-004  WHEN the repo's checks have not finished within the commit-gate
              hook's configured timeout minus a 30-second margin — the timeout
              read from the check-gate entry in the user's settings, the
              harness default of 600 when there is none — THE COMMIT GATE
              SHALL kill the checks and everything they started, refuse the
              commit with exit 2, and name both the budget and the timeout.
              verify: integration

REQ-GATE-005  WHEN the definition-of-done Stop hook's checks have not finished
              within its own entry's timeout minus the same margin, IT SHALL
              kill the checks, refuse to let the turn end with exit 2, and name
              both numbers.
              verify: integration

REQ-GATE-006  WHEN settings/hooks-snippet.json is read, IT SHALL ship no
              `permissions` key (push-equals-deploy is a repo fact, so a push
              gate belongs in that repo's own settings), SHALL list `venv`
              beside `.venv` and `node_modules` under worktree symlinks, SHALL
              give the commit gate and the Stop gate the same timeout, and its
              top-level comment SHALL say the gate stops the checks 30 seconds
              before that timeout and blocks; the three Makefile templates
              SHALL say the same.
              verify: unit

## C. Instructions name commands that exist

REQ-GATE-007  WHEN scripts/check-command-refs.sh is run against a repo, IT SHALL
              resolve every backticked `/name` in that repo's CLAUDE.md and
              .claude/commands/*.md against the repo's commands and skills, the
              installed commands and skills, the harness built-ins, and the
              repo's optional .claude/known-commands list; IT SHALL exit 1
              naming file, line and name for each that resolves nowhere, exit 0
              when all resolve, and exit 2 when the repo has no CLAUDE.md.
              verify: integration

## D. The framework says what it now does

REQ-GATE-008  WHEN README.md's "Known gaps" section is read, its commit-gate
              entry SHALL keep the mechanism the framework-gaps spec pins (the timeout, the hook that does NOT block, the rule that follows)
              and SHALL then say the gate keeps its own clock, so the entry
              reads as closed rather than open.
              verify: unit

REQ-GATE-009  WHEN sdlc-policy.md's Decision Protocol is read, IT SHALL state
              that a question to the owner is never a bare yes/no: it carries
              options with the recommendation first.
              verify: unit

## E. Found by adversarial review of the first cut

REQ-GATE-011  WHEN jq is not on PATH, THE COMMIT GATE SHALL scan the raw payload
              and refuse a commit-shaped one rather than allowing every commit;
              WHEN a heredoc is fed to a shell or interpreter (`bash <<EOF`,
              `ssh host <<EOF`, `eval`), its body SHALL stay in the scan; WHEN
              `commit` is followed by a quote (`bash -c "git commit"`) or split
              from `git` by a backslash-newline, the command SHALL still gate.
              verify: integration

REQ-GATE-012  WHEN the command has more than one `cd`, THE COMMIT GATE SHALL
              follow the LAST `cd` that precedes the commit, on any line, and
              a `cd` after the commit SHALL not be followed; a bare `cd $HOME`
              SHALL be expanded like `~/`.
              verify: integration

REQ-GATE-013  WHEN every staged (or, at Stop, changed) file is prose by
              extension (.md .txt .rst .html) the gates SHALL skip the checks,
              and a script under docs/ SHALL NOT count as prose; WHEN the
              Makefile exists but cannot be read, BOTH gates SHALL refuse and
              say so in the gate's own output; WHEN the checks end without an
              exit code, the gate SHALL print what they wrote before refusing;
              and a refusal on budget SHALL print no stray shell error.
              verify: integration
