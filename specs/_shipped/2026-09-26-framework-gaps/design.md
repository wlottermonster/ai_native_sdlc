# Design — framework-gaps

## Approach

Three unrelated gaps, fixed in one pass because each is small and all three were
found in the same review. Nothing here changes how the framework routes or gates
— it closes holes in what it TELLS you and in one script's reach.

**A — the gate that fails open.** There is no way to make a PreToolUse hook fail
closed; that is the harness's behaviour, not ours. So the fix is honesty plus a
budget: say it in "Known gaps", say the rule that follows (absence of a block is
not evidence), and put the timeout budget where someone writing a `check` target
will actually see it — the hooks snippet and all three Makefile templates. A repo
then either fits the budget or knows it is ungated. `/hunt` already models the
stronger move for anything unattended: run the checks yourself and read the exit
code.

**B — repo-local agents.** `apply-engines.sh` hardcodes `$HOME/.claude/agents`.
It already discovers `roles.conf` beside the agents, so the change is small:
honour an agents directory given in the environment, and find that directory's
own manifest. The engine map deliberately stays machine-level — a repo carrying
its own map would be the second binding the whole framework exists to prevent.

**C — CI mirror.** One workflow file that runs `make check`. It closes the
"gates run locally only" gap for any repo that copies it, and a repository
that already has one shows it costs a single file.

## Components touched

| File | Change |
|---|---|
| `README.md` | "Known gaps" gains the fails-open entry and points the CI entry at the new template; "Project layer" names the command for repo-local agents. |
| `settings/hooks-snippet.json` | Comment naming the timeout as a budget. |
| `templates/Makefile.python|node|static` | The same budget comment in each. |
| `scripts/apply-engines.sh` | Honour an agents directory from the environment. |
| `templates/ci-check.yml` | **New.** |
| `tests/test_gaps.sh` | **New.** |

## Irreversible actions (must be surfaced at Gate 1)

None. No migration, no deletion, no deploy. `apply-engines.sh` gains a path it
did not have; its existing behaviour with no environment override is unchanged,
which the tests must pin.

## Assumptions

## Measurements this feature rests on

Verification asked, fairly, where the numbers come from — the claim sat in
prose with no artifact behind it. They come from timed unit-stage runs on two
large repositories with roughly 8-minute unit suites.

Both exceed the commit gate's 300s budget, which is what REQ-GAP-001 through
REQ-GAP-004 are about. They are also far UNDER an earlier estimate of "about two
hours" that had been repeated in the manual and in commit messages — that figure
was extrapolated from a cold first run and was wrong by roughly an order of
magnitude. The correction matters beyond tidiness: at ~8 minutes the remedy is a
modest trim or a raised budget, not the suite restructure the wrong number
implied.

Re-measure rather than trust this table if the suites grow; the point of the
budget is that it is checked, not remembered.

## Decisions & rejected alternatives

- **Rejected: raising the hook timeout to fit the slowest repo.** It would hide
  the problem rather than name it, and the number that fits today stops fitting
  as a suite grows. A stated budget that a repo must fit is the honest shape.
- **Rejected: letting a repo carry its own engine map.** That is the second
  binding the framework exists to prevent. The map stays machine-level and only
  the agents directory moves.
- **Rejected: a CI template that runs `make test`.** The heavier suite is where
  credentials and long runs live; a CI job that needs secrets is a job people
  turn off.
