# Design — engine-map-mod

## Approach

One plugin folder, `adapters/claude/skills/sdlc-engine-map/`, installed by
the existing skills path to `~/.claude/skills/sdlc-engine-map/`, which the
engine auto-loads and watches. Four hooks and nothing else:

- `agent.spawn` (REQ-MOD-007…010, 014, 015, 019, 020, 021): read the map and
  the manifests through `$.fs` with `$.env.get("HOME")` and `$.session.root()`,
  resolve `e.subagentType` to a role, and call `next({ ...e, model })` once
  with the role's entry in force when `e.model` is undefined. Forks,
  teammates, plugin agents (`<plugin>:<name>`) and unbound names pass
  straight through. A spawn resolves as soon as the subagent starts, so a
  model failure cannot be retried inside the dispatch (it surfaces later in
  the subagent's own loop); fallback therefore moves LATER dispatches of that
  role down the chain (REQ-MOD-011, 013). T0 recorded that the failure
  surfaces at the subagent's `turn.complete` with a bare `error` reason, so
  a `turn.complete` hook classifies it with one bounded `$.model.complete`
  on the entry and moves the chain only on an unavailable-model answer.
- `session.start` and main-loop `turn.start` (REQ-MOD-016, 017): compare
  `await $.session.model()` with the judge entry and set `$.ui.status`.
  `prompt.compose` was rejected: it fires for every system prompt including
  subagents' and carries no loop id, so the status would flap on every
  dispatch, and it sits on every request's prompt path.
- Message set (REQ-MOD-005, 008, 010, 018, 020): kept in `$.state` under one
  fixed key and never reset by the mod. `session.start` fires once per
  process and again per reload, so nothing is seeded there. The fallback
  chain (REQ-MOD-011, 013, 017) is a second key: by role, the entry NAMES
  classified unavailable; the entry in force is the first entry of the map's
  current list not among them.

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
- The mod's own hooks cannot be overrun from the mocked clock: they await
  only `$` calls and `next`, which a hook's budget does not count, and the
  budget is a fixed ten seconds of real time that advancing the clock does not
  shorten. The timeout branch of their `.catch` is proven with fakes, and one
  engine overrun (ten real seconds) runs the same `announceFailure` in a
  `.catch` on a hook of the test's own.
- A session state that cannot be read or written does not stop routing: the
  message set and the chain fall back to process memory and that is said once;
  across a hot reload in that state, both are lost. Survival across a real hot
  reload is still observed at Gate 2; the tests answer `state.get` with stored
  entries.
- What is still lost on a hot reload: the routed agents awaiting their first
  turn (`Pending`, process memory, capped at 64) and any classification call in
  flight. A routed subagent whose turn fails after a reload is not classified,
  so its entry is not marked; a later failure of that entry after the reload
  is.

## T0 record

Probed on build 2.1.291 (builtAt 2026-10-06T02:24Z), headless `claude -p`
against the real config, a probe plugin recording every event to files;
headless `claude -p` runs load `--plugin-dir` and skills-folder plugins alike.

- **Auto-load.** A plugin folder under `~/.claude/skills/<name>` holding only
  `.claude-plugin/plugin.json` and `hooks/` loaded with no SKILL.md and no
  settings edit (`session.start` fired). No SKILL.md will be shipped.
- **Hook-set model wins.** `agent.spawn` for `researcher` (frontmatter bound
  to the read role) with the hook setting `model` to the build-role alias
  resolved to that alias's id in the spawn result; with no hook model the
  result was the frontmatter's id. `e.model` arrived undefined when the
  Agent call named none.
- **Hook beats the environment variable.** With `CLAUDE_CODE_SUBAGENT_MODEL`
  set to one alias and the hook setting another, the result carried the
  hook's. REQ-MOD-020 is worded from this.
- **A bad model id does not fail the spawn.** `next(e)` resolved to
  `{ model: <bad id>, agentId }`; the failure surfaced at the subagent's
  `turn.complete` as `reason: "error"` with no error kind and no usage,
  and the main loop received the Agent tool's error text naming
  `model_not_found (HTTP 404)`. The mod cannot see that text, so it
  classifies with one bounded `$.model.complete` on the entry (REQ-MOD-011).
- **Fields seen.** `agent.spawn`: tool_use_id, prompt, description,
  subagentType, provider {plugin, tier}, model?, parentModel, background,
  fork, isTeammate? (absent, not false, for a plain subagent), parentAgentId?.
  `turn.start`: text, turnId only, and it fired for the main loop only (none
  for the subagent's turn). `turn.complete`: agentId present for the
  subagent's turn and absent for the main loop's.
- **`$.session.model()`** answered the main model id with no bracketed
  suffix even though settings pin one; the strip in REQ-MOD-016 is harmless.
- **Unknown event.** `claude plugin validate` refuses a module naming an
  event this build lacks, before any load (REQ-MOD-030). Runtime refusal was
  therefore not probed; `register` still wraps `on()` (REQ-MOD-005).
- **Validate output** lists the hooked events by name and warns on a gating
  hook without `.catch`, naming `agent.spawn` as gating: the allow-list and
  the `.catch` requirement both read straight off it.
- **Test kit.** `claude-code/testing` mocks the clock, the store and the
  environment, not the filesystem: a hook's `$.fs.read`, `$.fs.exists`,
  `$.session.root()`, `$.ui.toast` and `$.ui.log` have no implementation
  ("no implementation for <event>") unless the test answers them itself
  with its own `on(...)` hooks beneath the plugin, each answering
  `{ value }` or `{ deny }`. (T0 guessed tests could write fixtures through
  `$.fs`; T1 and T2 found otherwise.)
- **Not probed (interactive only), left to the Gate 2 checklist:** the
  status line drawing, `/model` mid-session at the next `turn.start`,
  message-set survival across a hot reload and `/clear`, and `claude plugin
  validate` from inside the check-gate hook process (validate ran from a
  session's Bash tool without any nested-session refusal).
- **Validate inside a commit hook (T7).** The T7 commit ran `make check`
  from the repository's git pre-commit hook, itself launched from a session's
  Bash tool: `claude plugin validate` printed its full report and `Validation
  passed`, and the hook ended `check: OK`, with no auth or nested-session
  refusal. The Claude PreToolUse check-gate's own run is not visible to the
  session, so validate inside that hook process is still unobserved.
- **Classification shape (probed by the coordinator, fix round).** On build
  2.1.291 a live `$.model.complete` on a model id that does not exist answered
  exactly `{ isAnswered: false, reason: "api-error", status: 404, error:
  "model_not_found", usage: <all zero> }`, and on a valid alias `{ isAnswered:
  true, text, usage }`: the shape `isUnavailable` reads (REQ-MOD-011).

## Assumptions
<!-- Written DURING the build, never asked mid-flight. -->
- The plugin test kit gives hooks no filesystem on this build, so the
  routing logic is a pure module (`hooks/routing.ts`) driven by fakes, and
  the engine adapter in `register.ts` is exercised through the
  no-filesystem pass-through path (plus one kit test whose own hooks answer
  `fs.read`, `fs.exists` and `session.root`).
- T1 extended tests/test_apply_engines.sh rather than rewriting it.
- A tab inside a key or list entry is not modelled by the fixtures.
- The mod's tests read the fixture set through the generated
  `hooks/map.fixtures.ts`, held byte-equal by the shell suite.
- T2: when `$.session.root()` or `$.fs.exists` on the project manifest
  fails, nothing is routed and that is said once: routing past a project
  manifest that cannot be consulted could bind a repository's agent to the
  wrong role.
- T2: an unset HOME is the missing-map case (the map cannot be found).
- T2: "said once" is keyed per agent for a bypass and per full message for a
  refusal, so a different fault after an edit to the map is said again.
- T2: a fork, teammate or plugin agent is decided before any file is read,
  so even a refused map says nothing for them.
- T3: `route()` catches anything thrown while deciding (a read answering no
  text, a message set or chain state that throws) and passes the dispatch
  through as given, said once, so the no-deny property holds inside the pure
  module; the hook-level `.catch` stays T5's.
- T3 (superseded by the fix round below): the chain index is per role, in a
  module-level state behind the `ChainState` interface (`hooks/chain.ts`); an
  edit to the map does not reset it, and a role's list that grows after
  exhaustion routes again from there.
- T3: a routed agent is remembered with the chain as the map listed it at its
  dispatch, and forgotten at its first `turn.complete` whatever the reason; a
  resumed subagent's later error is not classified.
- T3 (superseded by the fix round below): no classification call is made
  when the failed entry is no longer the one in force, and the chain moves only
  from the index the failed dispatch ran on, so a late answer never moves it
  twice or backwards.
- T3: a classification call that rejects (a model the engine refuses to send
  to) counts as not unavailable and leaves the chain where it is.
- T3 (superseded by the fix round below): "said once per role" is literal:
  the first move down a role's chain is said; later moves are not, and
  exhaustion has its own once-per-role notice.
- T3: an exhausted role leaves an explicit model as given with no notice.
- T3: the classification is `maxTokens: 1`, `timeoutMs: 5000`, prompt `.`.
- T3: the kit raises `turn.complete` directly (`$.turn.complete`), so
  REQ-MOD-011 and 013 are proven both on the pure handler with fakes and once
  through the engine.
- T4: the status line is one line, `<flag> | judge=… build=… verify=… read=…`,
  each role showing its first entry and ` → <entry in force>` (or
  ` → frontmatter`) once its chain index has moved; a role absent from the map
  shows `none`, escalate and any other role are left out.
- T4: a map with no judge line is a mismatch (`… is not none`); a model the
  engine cannot report (the call throws or answers empty) is flagged
  `JUDGE UNKNOWN`, never taken as a match.
- T4: a missing or unreadable map is `engine map: <file> missing or
  unreadable` (the two are one reading failure to `loadBinding`); a refused
  one is `engine map: <file> refused line <n>`. Only the map is read for the
  status line, not the manifests.
- T4: the CLAUDE_CODE_SUBAGENT_MODEL notice is said once per process whatever
  the value (one key), carries the value, and an empty value counts as unset.
- T4: the status line and the variable notice are proven on the pure module
  with fakes and once each through the engine: the kit raises
  `session.start` and `turn.start` directly (`$.session.start`,
  `$.turn.start`). The kit maps leave verify out, because T3's kit test moves
  the process-wide verify chain.
- T4: no try/catch around `$.ui.status`; a throw there is left to T5's `.catch`.
- T5: the engine accepts a `.catch` handler only as a function literal or the
  name of one, and refuses to load a module that keeps the value of
  `on(...).catch(...)` (a concise arrow returning it counts). So each of the
  four registrations carries the same three-line literal: await `failed(...)`
  (register.ts), then `return next(e)`. The announcement itself is the pure
  `announceFailure` in `hooks/safety.ts`, which never throws.
- T5: the failure notice is `engine map mod: the <event> hook failed
  (<kind>[: <message>]); ` followed by `the event proceeds un-routed`, or `the
  result it had already settled stands` when `next.called`.
- T5: `$.state` under the kit: the kit implements it itself, in memory (a
  first read answers `{ version: 0 }`, a set then reads back), and a test may
  answer `state.get` and `state.set` with its own hooks returning `{ value }`;
  `{ deny }` makes `$.state.get` reject. The type contract must export a type:
  `types/index.d.ts` with only `export {}` beside the `declare module` block
  was refused by validate (key "not declared"), with `export type …` accepted.
- T5: the kit loads a fresh plugin instance per test: module memory does not
  carry from one kit test to the next, and the test's own import of a module
  is a separate instance from the one the engine loads. A test's own hooks may
  not call a `$` noun its module's scan does not list (`$.clock.sleep refused:
  its hooks module does not call it`), so the overrun test waits on the mocked
  clock's own `sleep`. Each event can be hooked once per test.
- T5: the message set is one key, `sdlc-engine-map.said`, a list of
  `key:<key>` and `text:<text>` entries; `once` refuses when either was seen,
  so an identical text is never shown twice under any key. Each hook opens the
  set from `$.state` first (a read that fails throws, and the `.catch` takes
  over) and writes back what it said before it calls `next`, merged under
  `ifVersion` with up to three attempts; a write that loses three races leaves
  the entries in process memory only. The `.catch` handler alone falls back to
  process memory when the state cannot be opened. (Superseded by the fix round
  below: every hook now falls back, and routing goes on.)
- T5: a single try per registration covers both `on()` and `.catch()`; were
  the engine to refuse only the `.catch`, the event would be reported as not
  registered although the hook may stand. Runtime refusal stays unprobed (T0).
- T5: the refused-registration notice is said under one key, once per process
  and, through the session state, once per session.
- T5: through the engine, a failure after `next` is provoked by the hook
  beneath throwing: the mod's `next` rejects, the replay settles to the same
  rejection, and the hook beneath ran once.
- T5: `tests/test_mod.sh` reads the hooked events from the `notes` of
  `claude plugin validate --json` (the JSON report has no hooks field of its
  own; the note is `<module> hooks: a, b, c`) and the `.catch` state from its
  `gatingHooks[].hasCatch`, requiring at least one gating hook. It assumes
  `claude` on PATH until T7 adds the skip rule, and `tests/run.sh` now runs it.
- T7: REQ-MOD-003 says the skip "prints the same line", so `scripts/mod-check.sh`
  prints one identical line in both cases, `mod checks NOT run: claude is not
  on PATH (only SDLC_SKIP_CLAUDE_MOD=1 lets the gate continue)`; only the exit
  code differs. Only the value `1` skips; any other value fails.
- T7: the script resolves the checkout LOGICALLY (`cd scripts && cd ..`):
  `scripts` is a symlink into `adapters/claude`, so a physical `..` lands in
  `adapters/claude` and the mod is not found. A missing mod folder fails with
  a message whether or not the skip is set.
- T7: exit 0 is earned: besides the client's exit code, validate must print
  `Validation passed` and test must print a non-zero pass count and `0 fail`,
  so a client that exits 0 without its report fails the gate. The wording is
  this build's; a reworded report fails closed.
- T7: a SET skip never silences a check that ran: with `claude` on PATH the
  variable is ignored, proved by `make check` on a fixture whose mod names an
  unknown event with the variable set.
- T7: without `claude`, tests/test_mod.sh still runs the source title check
  and the gate-fixture REQ-MOD-003 runs (they need no client), then fails, or
  with the skip prints the line and finishes on what passed.
- T7: the title check reads every `test(`/`it(` first argument from the
  source (a non-literal title counts as untitled) and every result line of
  `claude plugin test`, whose count must equal the kit's `Ran N tests`.
- T7: the no-claude PATH is a temp bin of symlinks to every command on PATH
  except `claude`, so `make check` keeps make, jq, shellcheck and python3.12.
- T7: `make check` changes the Makefile, whose hash is pinned in
  `docs/portability-step5/source-disposition.json`; the pin was updated.
- T9: the document assertions live in a new `tests/test_mod_docs.sh` rather
  than in `tests/test_docs_roles.sh`, which stays about roles; it reads the
  model-name pattern out of `test_docs_roles.sh` so the two cannot drift, and
  runs it over every file in the mod folder, the engine-map fixtures,
  `tests/test_mod*.sh`, `scripts/mod-check.sh`, both policy files,
  ARCHITECTURE.md, README.md and the manual.
- T9: REQ-MOD-022 is a regression guard over code this feature does not
  change, so it passed before any edit; it was proven by mutation instead
  (the apply step removed from a copy of install.sh, then the session hook
  removed: each turned the block red, and both were restored byte-identical).
- T9: ARCHITECTURE has no separate file map, so the mod's files,
  `scripts/mod-check.sh` and `tests/test_mod.sh` are listed inside the new
  routing section (section 3, after the enforcement table), and section 5's
  "edit the map and re-run the script" gained the mod's next-dispatch case.
- T9: the manual's Chinese sentence names the mod as 引擎對照表模組 with the
  English term in brackets, matching how the page keeps code names in English.
- Fix round (A): the chain is a per-role SET of entry names classified
  unavailable, in `$.state` under a second declared key (`gone`) over process
  memory; the entry in force is the first entry of the CURRENT map list not in
  the set, exhausted when every entry is. A reload or a map edit after a
  fallback can no longer put a role on a dead entry or skip a promoted one.
- Fix round (A): parallel failures of one entry share one in-flight
  classification promise (process memory, by role and entry), so they make one
  call; an entry already in the set is not classified again.
- Fix round (A): a move down a chain is said once per role and entry moved
  (REQ-MOD-011 reworded); the T3 test that asserted one notice after two moves
  now asserts two.
- Fix round (A): the routed agents awaiting their first turn are capped at 64,
  the oldest forgotten first.
- Fix round (A): the engine wants each `$.state` reference and each
  `$.env.get` name spelled as a literal at the call, so the two keys keep a
  save function each and HOME is read by one `readHome` helper.
- Fix round (B): a session state that cannot be opened (or written) falls back
  to process memory for both keys and routing goes on; `engine map: session
  state unavailable (…)` is said once. The four kit tests that provoked a
  hook failure by refusing `state.get` now assert the hook does NOT fail; the
  before-next branch of the mod's own `.catch` literals stays proven with fakes
  in safety.test.ts, and through the engine on a hook of the test's own, since
  nothing in the mod's hooks fails before `next` any more that the kit can
  provoke (the ui calls are fire-and-forget and every read is caught).
- Fix round (C): `scripts/mod-check.sh validate` fails on `gating hook
  without .catch` and unless the hooked events, read from the report's
  indented `<module> hooks:` lines, equal the allow-list as a set. The list
  lives in one line of the script (`allowed_events=…`), which
  tests/test_mod.sh reads.
- Fix round (D): mod-check.sh looks for the mod in the checkout layout, then at
  `<script dir>/../skills/sdlc-engine-map` (the installed layout); neither is a
  loud failure.
- Fix round (E): tests/test_mod.sh runs itself under the no-claude PATH with
  `SDLC_TEST_MOD_NESTED=1`, which skips the REQ-MOD-003 fixture block and the
  re-invocation in the nested run.
- Fix round (F): `walk_files()` in core/installation.py prunes excluded
  directories during an `os.walk` (symlinked directories listed, not followed,
  as `rglob` did); a test counts the directories `os.scandir` opened.
- Fix round (G): the next-dispatch sentence is qualified "for a role-bound
  subagent dispatched without a model of its own" in the policy, ARCHITECTURE
  and README, and in both languages of the manual; the required fixture names
  live once in tests/engine_map_cases.sh and reach map.test.ts through the
  generated mirror (`REQUIRED`).

## Decisions & rejected alternatives

- **Routing only, no gates in the mod.** A function hook past its budget is
  absent and the action proceeds; the repo's gates must refuse when they
  cannot verify. Rejected: moving check-gate into `tool.call`.
- **Later-dispatch fallback instead of retry.** A second `next` after a
  spawn that already started would start a second subagent, possibly a
  duplicate implementer editing files. Rejected: retry inside the dispatch,
  and a per-dispatch probe completion. Accepted: one one-token classification
  call per FAILED subagent, never per dispatch, because the failure event
  carries no error kind.
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
- **A session state that fails does not turn routing off.** The mod's state
  is a convenience (said-once, the chain across reloads); losing it costs a
  repeated notice at worst, while failing the hook would route nothing.
  Rejected: letting the `.catch` take over (the T5 choice).
- **Project manifest first, map from HOME always.** Matches apply-engines'
  `SDLC_AGENTS_DIR` semantics; a repository binds its own agents to roles
  but never carries its own map.
