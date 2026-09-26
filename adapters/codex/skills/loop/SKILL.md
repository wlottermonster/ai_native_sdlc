---
name: loop
description: Run a user-requested workflow repeatedly with a deadline, bounded rounds, durable checkpoints and explicit stop reasons. Use for /loop followed by a workflow or an explicit request to repeat a workflow until its completion condition or limit.
---

# Loop a workflow

`/loop` is an instruction alias, not a registered native command, scheduler,
daemon or promise of execution after this session ends. Run in the active
session using available tools. Do not install scheduling or launch headless
agents merely because this skill was invoked. A host interruption is a pause
or stop, never proof that another round will run automatically.

## Resolve scope before starting

Read the current project's AGENTS.md and its declared workflow skill. For
`/loop /<project-loop>`, use that project's own loop adapter; never assume a
workflow from another repository. Follow a named phase or arguments as supplied.
If the workflow cannot be resolved, report the missing definition and ask for
its path or intended task; do not invent actions, especially cleanup/deletion.
Read the referenced workflow and its actual checks before running it.

Use the active harness's policy/model routing. A reference to another harness's
command is a procedure to map explicitly, not proof the tool exists. Preserve
the workflow's approvals, protected paths and external-action boundaries.
Looping grants no additional permission to publish, send, deploy or delete.

## Establish one durable run

Use the installed OpenAI SDLC helper and its `references/loops.md` for task
attempts and verification evidence. It is not a scheduler and does not enforce
this skill's total deadline or round count. Enforce those in the controller.
Do not count a helper `record progress` per phase as a full workflow round.

Before the first action, write `.sdlc-openai/loops/<run>.json` atomically using
a temporary file in the same directory and rename. Refuse symlinked state paths.
Use a unique run name; do not overwrite another session's state. Record:

- objective, resolved workflow path and arguments, repository/worktree/branch;
- UTC start and absolute deadline, maximum rounds, rounds started/completed;
- current round/phase, phase PASS/FAIL/SKIPPED with evidence paths;
- status, consecutive failure signature/count, stop reason and exact next step;
- owned resources for cleanup, SDLC helper run name and verification evidence.

Resolve each bound independently: use the user's deadline or workflow deadline,
otherwise one hour; use the user's round limit or workflow round limit,
otherwise three rounds.
When user and workflow hard limits coexist, honor the earliest/lowest boundary.
State the resolved limits at the start. Translate relative duration to UTC once;
downtime counts. Persist `rounds_started` BEFORE each round so an interruption
cannot grant a free additional round. Phase checkpoints do not consume rounds.
For helper attempts use its policy/default budget separately; never reset it
to evade a block. Keep state free of credentials and private user data.

## Execute and checkpoint

Before each phase and retry, check the deadline, owner stop,
workflow preconditions and repeated-failure limit. Bound subprocess timeouts
by remaining time and reserve time for cleanup/reporting. Cancel owned work
at the deadline when supported; disclose any work that could not be stopped.
Never start a new phase merely because a previous one began before the deadline.
The round budget prevents STARTING another round after the limit. An already
started final round may finish or resume, subject to all other limits; do not
reject its phases merely because rounds_started equals maximum_rounds.

Run the workflow in its prescribed order. After each phase, save actual results,
evidence and the next action. A skipped or unavailable mandatory phase is not
PASS. A command invocation without its result is not evidence. Diagnose a
failure before retrying; three consecutive occurrences of the same underlying
failure stop the run. Never blindly repeat an irreversible external action.

After every full round, compute the workflow's completion/convergence condition
from evidence. Zero findings counts as dry only when all required phases ran
successfully and the workflow's own dry criteria hold. Otherwise report the
untested scope and stop blocked if it prevents valid further progress.

Stop at the first applicable boundary: verified completion/dry condition,
deadline, round limit, helper attempt limit, repeated failure, external blocker,
or owner stop. Deadline/limits are not success. Run final audit/report phases
only within the remaining deadline; otherwise mark them unfinished.
Always attempt cleanup of resources owned by this run, including on failure;
never kill another session's server or remove its lock. Save unresolved cleanup.

## Resume and report

Read persisted state and Git status before resuming. Preserve original deadline,
round counts and approvals. An expired deadline means cleanup/report only even
with rounds remaining. A failed or interrupted phase may already have external
effects: inspect them before repeating. Do not start a second controller for an
active run; establish that the previous controller stopped before taking over.
Do not invent progress or restart with new limits without explicit authorization.

Report stop reason, rounds, checks, findings, skipped phases, artifacts and next
action. Claim complete only with current passing evidence and actual workflow
completion. Record helper completion only when its verification contract passes;
otherwise record the real blocker/limit and next step. Explain any host execution
limit rather than promising unattended continuation. A new session may need to
reload installed skills; AGENTS routing supplies an explicit path meanwhile.
