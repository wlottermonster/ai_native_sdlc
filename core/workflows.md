# Workflow selection

## Feature / spec

Read relevant code and existing decisions. Capture concrete acceptance criteria
in specs/<feature>/requirements.md; use REQ-IDs where traceability helps. Write
design.md for interfaces, alternatives, risks and assumptions. tasks.md maps each
requirement to an implementation step and meaningful verification. Resolve only
material unanswered choices with the owner; don't reopen approved decisions.
For substantial designs, obtain adversarial review before implementation when
an independent agent is available and permitted. Record issues and resolutions.

## Build

Work from the approved task list. Inspect the working tree; preserve other edits.
Use a separate worktree when another agent/person is working concurrently. Start
a bounded run and record each iteration. Write failing behavior tests, implement
the smallest coherent change, run targeted checks, and report task-local evidence.
The coordinating session runs the complete required checks once on the stable tree
after the batch is assembled, records their exit codes, and rechecks if that tree
changes. Inspect every delegated diff and actual results. Commit hooks remain
independent checks; a hook that does not block is not evidence of a passing gate.

## Verify / audit

Check behavior against acceptance criteria and test honesty, not only green exit
codes. Probe meaningful failure paths. For browser flows, execute the key user
journey with available browser tools and preserve useful evidence. Independent
review uses a fresh reviewer and relevant raw artifacts; label self-review honestly.
Audit requested scope only. Report findings with location, reproduction and impact.
Do not change production data or send external messages during an audit.

## Debug / RCA

Reproduce first. Collect evidence, formulate a testable cause, and discriminate
between hypotheses before editing. Preserve a failing regression test; fix the
cause and check adjacent behavior. Repeated identical failure stops the loop.
Turn a demonstrated recurring cause into a focused test or documented invariant.

## Ship / operate

Review the final diff, requirements, test evidence, target branch and deployment
mechanism.
Push only under the authorization the owner has already given for that repository;
never force-push, and say plainly when a push deploys.
Inspect deployment results when available, and distinguish pushed, deployed and
healthy. For material changes, record rollback and monitoring steps. Don't create
new infrastructure, credentials or paid services without task authorization.

## Handoff / resume

Save the objective, scope, authorization, branch, changed files, current evidence,
failure signature and concrete next action in the adapter handoff record. On resume read it, inspect current Git
status, verify the run status and evidence freshness, and continue the next task.
Treat external research as referenced input. Transfer the relevant artifact through
the connected tool or a saved file; do not assume shared conversation memory.
