# AI-Native SDLC — routing policy (re-injected after every compaction)

The main session runs the `judge` role: judgment only. Bulk work goes to subagents
via the Agent tool.

## The four roles

The framework routes by ROLE and names no model of its own.
`~/.claude/sdlc-engines.conf` — the engine map — is the binding from role to model,
and the one place a model is named.

- `judge` — the main session's own reasoning: architecture, spec and design work,
  gate decisions, RCA root cause, and the final review it reads itself.
- `build` — the implementer: tests-first implementation, in a worktree.
- `verify` — the reviewing and auditing agents: adversarial spec review,
  independent verification, debugging evidence, agentic e2e walkthroughs and
  test-suite audits.
- `read` — bulk reading: research, sweeps and summaries, where the volume is the
  cost.

### Reading the engine map

A role's model list is an ordered fallback chain: the first entry is what runs,
and the rest are what to drop to when it is unavailable — in order, and no
further than the list goes.

- A substitution is announced once, the first time it is used in a session: one
  line naming the role and the entry it fell back to, then not repeated.
- No phase silently runs on a model the owner did not list. If every entry for
  a role is unavailable, say so and stop rather than reaching past the list.
- A model the owner names in the moment outranks the map, and holds for as long
  as they say. The map is the default, never a veto.
- No project may pin `model` in its own `.claude/settings.json` — the engine
  map is the single binding, so a project-level pin would fork the routing
  invisibly. Change the map instead.

| Phase | Who | Role |
|---|---|---|
| Architecture / spec / design | main session | judge |
| Adversarial spec review | `spec-reviewer` agent | verify |
| Tests-first + implementation | `implementer` agent (worktree) | build |
| Independent verification | `verifier` agent (fresh worktree) | verify |
| Final review | main session (reads the diff itself) | judge |
| Research / bulk reading | `researcher` agent | read |
| Debugging evidence | `evidence` agent | verify |
| RCA root cause (/rca step 2) | main session | judge |
| Agentic e2e walkthrough (webapp, pre-ship) | `ui-tester` agent | verify |
| Test-suite audit (four lanes, read-only) | `test-auditor` agent | verify |

Rules:
- Route silently by this table; announce `<phase> → <role>` in one line. An explicit
  model named by the owner always wins.
- Token thrift: reading ~300+ lines, writing ~200+ lines, or reviewing 3+ files goes to a
  subagent; only digests/diff summaries come back to the main context.
- Artifacts, not claims: a subagent's success report is not evidence. Verify with
  `make check` exit codes and by reading the diff in the main session.
- Pipeline is sequential with checkpoints; parallel fan-out only for independent tasks,
  max 3–5, one file one owner, kill rule at 3 failed attempts on the same error.
- Human gates: Gate 1 = plan approval. Gate 2 = /ship review before push.
  Push = deploy on the repos the repo's CLAUDE.md names — never push without
  the owner's explicit yes.

### The `escalate` lever

The working roles all default to one general working model, so the framework
runs on a single-model plan. The map's fifth entry, `escalate`, is the stronger
model — reached for on purpose, so the owner can choose it sometimes without
making it the standing default.

- `escalate` is a lever, not a routing row: no phase escalates on its own, and
  the routing table above never sends work to it. Nothing in the framework
  promotes work to it, and it binds no agent.
- The owner raises a phase to it by naming it in the moment, and it holds for
  as long as they say — the next phase is back on the map.
- Any use of it is announced in the same one line as the phase, alongside the
  role, so an escalation is never silent.
- A session OFFERS the lever rather than silently taking it, when a judgement
  is close, contested, or costly to get wrong.
- Offering is not taking: the session says what it would escalate and why, in
  one line, and then waits for the owner's answer.

Project onboarding: `python3.12 ~/.claude/scripts/project.py --repo <project-root>`
inspects the local contract; add `--apply` for authorized enrollment/repair.
