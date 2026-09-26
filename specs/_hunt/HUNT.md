HUNT-FORMAT: 1

## AREA MATRIX
| area | status | last round | note |
|---|---|---|---|
| settings | done | 1 | |
| scripts | done | 2 | |
| hooks | done | 2 | |
seeding rule: three rows, deliberately small — this run exists to exercise the floor
excluded: everything else, via areas:

## SEEN

## SEEN (archived)

## CURRENT ROUND
round: 2
branch: sdlc/hunt-floor
started: 2026-09-04T13:56:04
floor: 15m  ceiling: 45m  fix budget: 2  areas: settings, scripts, hooks
RUN LOCK: branch=sdlc/hunt-floor started=2026-09-04T13:56:04 run=floor-test
STOPPED: owner stop — the operator ended the run at the state described in FINDINGS, where the matrix was fully swept before the recorded floor and NO permitted stop reason applied. Recording that honestly rather than inventing a reason from the list, which is itself the finding.

## CONVERGENCE LOG
| round | confirmed FIXABLE |
|---|---|
| 1 | 0 |
| 2 | 0 |

## FINDINGS
(no tracker declared here)

### CONFIRMED — the stop list has a hole, and this run fell in it
Observed, not predicted. State at 13:59: matrix fully swept (3 of 3 rows `done`),
convergence 0 for both rounds, recorded floor not reached until 14:11.

Walk the permitted stop reasons in section F against that state:
- **dry** — needs convergence 0 AND the floor passed. Floor has NOT passed.
- **time floor** — needs the floor reached AND the matrix swept. Floor has NOT
  been reached.
- ceiling, fix budget, kill rule, round ended red, owner stop — none apply.

So a run that finishes its matrix early and finds nothing has NO permitted stop
reason, and section F also says "run rounds YOURSELF until a stop condition is
met". The literal reading is to keep starting rounds that have no rows left to
sweep, until the floor finally lets `dry` fire. It terminates, so it is not a
hang — it burns budget doing nothing and reports nothing about why.

The first fresh-eyes pass listed this as a theoretical gap and ranked it below
the failures. It is no longer theoretical: the second real run hit it.

The fix is one clause, not a redesign — `dry` should fire on a convergence of
zero with the matrix fully swept, whether or not the floor has passed. The floor
exists to stop a run giving up while there is still ground to cover; there is no
ground left to cover here.
