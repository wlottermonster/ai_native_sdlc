---
description: Audit a repo's test suite — coverage currency, mutation honesty, stale assertions, unclosed findings — into one dated report
---
Audit the TEST SUITE of the current repo. $ARGUMENTS may carry, all optional
and in any order: a base ref, a mutation budget (`budget: <n> mutations` or
`budget: <n> minutes`), and a lane subset (`lanes: <name>, <name>`).

## Arguments
- **base ref** — with none given, take the FIRST of these that resolves, and
  say in the report which one was used: the merge-base with the main branch
  (`git merge-base HEAD <main>`), else the last tag
  (`git describe --tags --abbrev=0`), else `HEAD~20`.
- **mutation budget** — passed through to the agent, and it overrides the
  agent's own bound. With none given, the agent's bound stands.
- **lane subset** — named by the canonical lane names below; with none given,
  all four run. A lane you did not ask for is not reported at all.

## 1. Dispatch
Dispatch the `test-auditor` agent (read-only, verify role) ONCE with: the repo path,
the resolved base ref and how it resolved, the mutation budget, and the lanes
to run. It returns its verdicts and findings in its final message; assembling
them is yours, not its. This command
never edits source or tests, and step 3's report is the only file it writes.

## 2. Assemble the table
Build the verdict table from the agent's final message, with EXACTLY these four
lane names as its rows, spelled this way and in this order:

| lane | verdict | note |
|---|---|---|
| coverage currency | | |
| mutation honesty | | |
| stale assertions | | |
| unclosed findings | | |

Each lane is reported as PASS, FAIL or SKIPPED — no fourth verdict, none left out.

A lane that could not run — the base ref does not resolve, the tooling is
missing, the budget ran out before it started, or the scratchpad copy
cannot run the suite — is SKIPPED with that reason in its note, never PASS.
PASS means the lane ran and found nothing; "could not look" is not that.

## 3. Write the report
Write the report to `specs/_audit/<YYYY-MM-DD>.md` in the repo under audit,
dated today; create `specs/_audit/` if missing. If that name is taken,
append `-2`, `-3`, … until the name is free — the next audit reads them all.

The report carries the table, the base ref and how it resolved, the budget and
what the agent did not reach, then the findings, each on ONE line, exactly
`- [ ] AUD-<date>-<n>: <text>`, with `<n>` counting from 1 within the report.
Nothing else on the line: the next audit's unclosed-findings lane greps these
lines back out of `specs/_audit/`, so a finding that spills onto a second line
or loses its `- [ ]` box is a finding the next audit cannot see. One still open
from an earlier report is repeated under `## Still open` with its ORIGINAL id:
ids are never reissued, and a fix named in a finding is proposed, never applied.

## 4. Close in chat
Close with the table itself in chat — four lanes, their verdicts, the reason on
every SKIPPED one — plus the report path and the count of open findings. The
final message is the data: a reader who never opens the file can still act.
