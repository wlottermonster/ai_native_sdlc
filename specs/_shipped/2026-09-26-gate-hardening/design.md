# Design — gate-hardening

## Approach

Five small closures found in one review, landing together because four of them
touch the same two hook scripts and the fifth is one sentence of policy.

**A — the filter.** The commit gate decides whether a Bash command is a commit
by grepping its text. Two false-positive classes were live: a heredoc body that
talks about commits (fixed in the installed copy, never ported upstream), and
the word `git` inside a path such as `.git/hooks/pre-commit`. The heredoc fix
is ported verbatim. The word match becomes: `git` preceded by nothing, whitespace,
a quote or a shell operator — so a path or word character before it disqualifies
— then optionally anything that does not cross `|`, `;` or `&`, then whitespace,
then `commit` as a whole word. Quoted strings are still matched on purpose: they
can reach `eval`, and the gate fails closed.

**B — the clock.** A PreToolUse hook that outlives its timeout does not block;
that is the harness's behaviour and cannot be changed from here. What can be
changed is who notices first. The gate reads its own entry's `timeout` from the
user's settings with `jq` (harness default 600 when absent), subtracts a
30-second margin, runs the checks in their own process group, polls once a
second, and on expiry kills the group and exits 2 with a message naming both
numbers. One number in one file now governs both the harness and the gate, so
they cannot drift. The process group is made with `set -m` around the launch
and `kill -- -pid`; no `timeout` binary is assumed (absent on some systems),
and no job-control `wait` is used, because its "Terminated" notice would land
in the hook's output. The exit code travels through a file, so an absent code
is distinguishable from a zero. `dod.sh` gets the identical mechanism against
its Stop entry.

**C — command references.** A sibling of the agent-reference check some repos
already run: scan CLAUDE.md and the repo's command files for backticked
`/name` tokens and ask the filesystem whether each exists — project commands
and skills, installed commands and skills, the harness built-ins, and a
per-repo `.claude/known-commands` list for anything else the repo vouches for.
The built-in list is the one hand-written thing; it is kept to the harness's
own commands.

**D — the snippet.** The push gate leaves the snippet: push-equals-deploy is a
property of a repo, so the gate belongs in that repo's own settings, and the
comment says so. `venv` joins the worktree symlink list. Both gate timeouts
move to 600 and the comment says what the gate now does with the number.

**E — the policy.** The Decision Protocol already asks for options with a
recommendation first; it now says outright that a bare yes/no is never asked.

## Components touched

| File | Change |
|---|---|
| `hooks/check-gate.sh` | heredoc stripping ported; word-boundary filter; own clock and process-group kill |
| `hooks/dod.sh` | own clock and process-group kill |
| `scripts/check-command-refs.sh` | **New.** |
| `settings/hooks-snippet.json` | no `permissions`; `venv`; timeouts 600; comment |
| `templates/Makefile.python`, `.node`, `.static` | budget comment names the deadline |
| `README.md` | Known-gaps entry closed; layout and project layer name the new script |
| `sdlc-policy.md` | never a bare yes/no |
| `tests/test_gate_hardening.sh` | **New.** |

## Irreversible actions (must be surfaced at Gate 1)

None. Every change is a file in this checkout; `install.sh` copies them and a
re-run of the previous commit's `install.sh` would restore the previous copies.

## Assumptions

- The harness default hook timeout is 600 seconds, per the harness's own
  documentation at the time of writing. The gate falls back to it only when the
  settings carry no number.
- `set -m` is honoured by bash when run non-interactively with stdin from a
  pipe, which is how the hook runner invokes the gate. The deadline test
  proves it wherever the suite runs.
