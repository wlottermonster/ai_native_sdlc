# Design — engine-map-mod

## Approach

One plugin folder, `adapters/claude/skills/sdlc-engine-map/`, installed by
the existing skills path to `~/.claude/skills/sdlc-engine-map/`, which the
engine auto-loads and watches. Three hooks and nothing else:

- `agent.spawn` (REQ-MOD-007…010, 014, 015, 019, 020, 021): read the map and
  the manifests through `$.fs` with `$.env.get("HOME")` and `$.session.root()`,
  resolve `e.subagentType` to a role, and call `next({ ...e, model })` once
  with the role's entry in force when `e.model` is undefined. Forks,
  teammates, plugin agents (`<plugin>:<name>`) and unbound names pass
  straight through. A spawn resolves as soon as the subagent starts, so a
  model failure cannot be retried inside the dispatch (it surfaces later in
  the subagent's own loop); fallback therefore moves LATER dispatches of that
  role down the chain (REQ-MOD-011, 013), written only after T0 records
  where and how the failure surfaces (REQ-MOD-012).
- `session.start` and main-loop `turn.start` (REQ-MOD-016, 017): compare
  `await $.session.model()` with the judge entry and set `$.ui.status`.
  `prompt.compose` was rejected: it fires for every system prompt including
  subagents' and carries no loop id, so the status would flap on every
  dispatch, and it sits on every request's prompt path.
- Message set (REQ-MOD-005, 008, 010, 018, 020): kept in `$.state` under one
  fixed key and never reset by the mod. `session.start` fires once per
  process and again per reload, so nothing is seeded there.

Every `on(...)` carries a `.catch` that announces and returns `next(e)`
(REQ-MOD-004); with `next.called` true that resolves to the settled result.
`register` wraps each `on()` so a refused registration is recorded and the
rest proceed (REQ-MOD-005). The allow-list of events (REQ-MOD-006) is
proven from the validate report as a set, and a mutation step in T5 adds a
`tool.call` registration to watch the suite go red.

The map stays the only binding: the mod reads it, never copies it, and the
frontmatter written by apply-engines.sh remains in place as the binding for
sessions where the mod is not loaded.

## Components touched

- `adapters/claude/skills/sdlc-engine-map/.claude-plugin/plugin.json`,
  `hooks/hooks.json`, `hooks/register.ts`, `hooks/map.ts` (parser),
  `hooks/register.test.ts`, `hooks/map.test.ts`, `.gitignore`. No `SKILL.md`
  unless T0 shows the loader needs one.
- `tests/fixtures/engine-map/*.conf` with expected-verdict files;
  `tests/test_apply_engines.sh` rewritten to run them (REQ-MOD-015).
- `core/installation.py` skills path: exclusion list (REQ-MOD-025).
- `Makefile` (`check`: validate under the skip rule), `tests/test_mod.sh`.
- `tests/codex/test_doctor.py`: one test over existing code (REQ-MOD-026).
- `adapters/claude/policy.md` → rendered `sdlc-policy.md` (REQ-MOD-023).
- `ARCHITECTURE.md`, `README.md`, `ainative_sdlc.html` (REQ-MOD-027).

## Data / API changes

None to the framework's files. The mod depends on these engine facts, each
present in this build's declaration file: `agent.spawn` input
`{ subagentType, model?, parentModel, provider, isTeammate?, fork? }`, its
result `{ model, agentId }` or `{ deny }`, resolving once the subagent has
started; `$.session.model()`; `$.session.root()`; `$.fs`; `$.env.get`;
`$.ui.status`, `$.ui.toast`, `$.ui.log`; `$.state`; `.catch` with
`next.error.kind` in `throw | timeout` and `next.called`. The API is early
access: T0 pins the build it was proven on and `claude plugin validate` in
`make check` catches the next drift.

## Irreversible actions (must be surfaced at Gate 1)

None. Installation writes one folder under `~/.claude/skills/` with the
skills path's backup; removal is deleting that folder. settings.json is not
touched. No push, no deploy.

## Known limits (stated, not promised away)

- No engine call says whether a model is available before a dispatch, and a
  spawn resolves before the model is first called. Fallback is therefore
  for later dispatches, not the failing one; the failing dispatch fails as
  it would without the mod.
- Doctor cannot see a mod that is installed but not loaded (`--bare`, a
  refused load, a build without mods); the frontmatter covers that case.
- Survival of the message set across a hot reload or `/clear` cannot be
  simulated under `claude plugin test`; T0 observes it once and records it.
- The mismatch check matches an alias to an id by the three spellings in
  REQ-MOD-016; a future id scheme outside them shows a false mismatch, which
  is loud, not silent.
- `claude -p` and SDK sessions are said to load skills-folder plugins too;
  T0 proves the interactive terminal only.
- Whether `CLAUDE_CODE_SUBAGENT_MODEL` outranks a hook-set model is a T0
  probe; the mod announces the variable either way.

## T0 record
<!-- Filled by T0, owner-attended: build version, auto-load with and without
     SKILL.md, hook-set model observed in the spawn result, failure shape of an
     unknown model id, turn.start for subagent loops, /model mid-session at the
     next turn.start, on() refusal behaviour, validate/test inside the
     check-gate hook environment, CLAUDE_CODE_SUBAGENT_MODEL precedence,
     message-set survival across reload and /clear. -->

## Assumptions
<!-- Written DURING the build, never asked mid-flight. -->

## Decisions & rejected alternatives

- **Routing only, no gates in the mod.** A function hook past its budget is
  absent and the action proceeds; the repo's gates must refuse when they
  cannot verify. Rejected: moving check-gate into `tool.call`.
- **Later-dispatch fallback instead of retry.** A second `next` after a
  spawn that already started would start a second subagent, possibly a
  duplicate implementer editing files. Rejected: retry inside the dispatch,
  and a per-dispatch probe completion (a model call to test a model).
- **`$.session.model()` on session and turn start, not `prompt.compose`.**
  See Approach.
- **Allow-list of events, not a deny-list.** A list of refusals is one
  spelling short of the next bypass.
- **Skills folder, not `CLAUDE_CODE_PLUGIN_DIRS`.** Already installed, owned
  and hashed by the receipt; no settings edit. Rejected: an `env` entry in
  settings.json the owner would merge by hand.
- **Keep apply-engines.sh and session-engines.sh.** The frontmatter and the
  SessionStart statement are the binding wherever the mod is not loaded.
- **Explicit skip variable, not an inferred one.** A missing client fails
  the gate unless `SDLC_SKIP_CLAUDE_MOD=1` says so in the open; inferring
  from a receipt would let a deleted receipt turn a failure into a note.
- **Project manifest first, map from HOME always.** Matches apply-engines'
  `SDLC_AGENTS_DIR` semantics; a repository binds its own agents to roles
  but never carries its own map.
