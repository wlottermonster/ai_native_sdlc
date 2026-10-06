# How AI-Native SDLC works, and how to read the code

`README.md` says what the framework does. This file says how, one layer at a time,
and points at the file that implements each piece so the code can be read in the
order it matters. Line counts are approximate and given only to size the read.

## 1. The idea in one paragraph

A coding agent's own report is not evidence. So the framework never asks an agent
whether the work is good; it puts mechanical gates in the harness that refuse to
let bad work through, and it makes every claim a requirement with an ID that must
be traceable to a task and a test. The human makes two decisions, plan approval
and ship approval. Most of what is between them is automated and graded on artifacts:
exit codes, diffs, test output, files on disk.

## 2. The lifecycle

```
 idea ──/spec──▶ specs/<feature>/{requirements,design,tasks}.md
                 │  spec-reviewer agent attacks it (verify role)
                 ▼
         GATE 1: plan approved by the owner
                 │
         /build ─┼─▶ implementer agent (build role), test-first, in a git worktree
                 │     every test tagged with the REQ-ID it proves
                 │     commit gate: `make check` must pass or the commit is refused
                 │     requirement gate A: every REQ has a task
                 ▼
                 verifier agent (verify role), fresh context, checks result vs spec
                 requirement gate B: at completion every REQ has a tagged test
                 ▼
         /ship ──▶ digest computed from ground truth (diff, tests, coverage)
         GATE 2: one explicit yes per branch; where push deploys, that yes deploys
```

Two more commands run outside that line: `/hunt` (unattended bug hunt that proves
each finding before fixing it and stops itself with a named reason) and `/rca`
(one known bug becomes a fix, a regression test, a rule and a sibling sweep).
`/test-audit` judges the test suite itself. `/feature` chains spec, build and ship
for one ask.

Where to read: `commands/*.md`. Each is a prompt the harness runs as a slash
command. `hunt.md` is the largest and the most instructive: its sections A to E
spell out refusal conditions, the state file it keeps, the refutation gate every
finding must pass, and the kill rule after three failed attempts on one error.

## 3. Enforcement: the hooks

The hooks are the part that makes the framework "harness-enforced" rather than
advisory. They are shell scripts registered in the client's settings
(`settings/hooks-snippet.json` shows the exact entries) and they follow one rule:
**exit 0 is an ALLOW and has to be earned. A gate that cannot verify must block.**

| Hook | Event | What it does | Read `hooks/` |
|------|-------|--------------|---------------|
| `check-gate.sh` | PreToolUse on Bash | Recognises a `git commit` in the command, runs the repo's `make check`, exits 2 to refuse when it fails. Reads its own timeout from the settings and stops the checks 30 seconds early so a slow check is a loud refusal, not a silent pass. | ~310 lines |
| `dod.sh` | Stop | The session may not end while the working tree fails its checks. Same own-clock rule. | ~160 lines |
| `req-gate.sh` | Stop (`--stop`) and inside `make check` | Gate A: every non-deferred REQ-ID in `requirements.md` appears in `tasks.md`. Gate B, only when `tasks.md` has no unchecked box: every REQ-ID appears in at least one test file. | ~120 lines |
| `autofix.sh` | PostToolUse on Edit/Write, async | Runs a formatter on the touched file if the repo has one. Never blocks. | ~25 lines |
| `session-engines.sh` | SessionStart | Emits the active engine map as context so the session states which model fills which role. Never blocks. | ~115 lines |
| `postcompact-policy.sh` | PostCompact | Re-injects the routing section of the policy after compaction, the whole file if the heading is missing, and says so when the file is absent. Never blocks. | ~45 lines |

Two things to notice in `check-gate.sh`:

- It tests the operation, not the predicate. `[ -d dir ]` proves nothing about
  whether `cd dir` will succeed, so the gate treats a failed `cd` as unverifiable
  and blocks, rather than running the checks in whatever directory it inherited.
- It clears Git's environment selectors before running checks, so a fixture
  repository created by a test cannot redirect the gate at the committing repo,
  and then re-exports absolute selectors when the work tree no longer leads back.

A PostCompact entry (`postcompact-policy.sh`) re-injects the routing section of `sdlc-policy.md` after the client compacts the
conversation, so the routing policy survives context loss.

### Routing, not enforcement: the engine-map mod

Not every hook is a gate. The engine-map mod is a Claude Code plugin of function
hooks, kept in `adapters/claude/skills/sdlc-engine-map/` and installed to
`~/.claude/skills/sdlc-engine-map/`, where the client loads it from the skills
folder with no edit to the settings. It routes and informs; it never blocks, and
it is deliberately kept out of the table above:

- **Dispatch routing** (`agent.spawn`): when an agent bound to a role is
  dispatched without a model of its own, the mod reads the map at that moment and
  sets the role's entry in force, so a change to the map applies at the next
  dispatch for a role-bound subagent dispatched without a model of its own. When a
  routed subagent fails on an unavailable model
  (`turn.complete`), later dispatches of that role move down its fallback chain.
- **Status line** (`session.start`, `turn.start`): one line carrying the active
  map, the entry in force for any role that has moved down its chain, and a flag
  when the session's own model is not the judge entry.
- **One-time notices**: a bypassed map, a refused map, an exhausted chain or a
  hook failure is said once, the set of messages already shown kept in the
  session state.

It fails open by design: a hook that throws or overruns announces the failure and
lets the dispatch proceed un-routed (a failure after the hook has already passed the
event on leaves the settled result standing), so the agent's frontmatter, written by
`scripts/apply-engines.sh`, decides, as it does in any session where the mod is
not loaded. That is acceptable only because the mod is routing; the gates above
stay shell hooks that refuse when they cannot verify. Two limits are stated
rather than promised away: the mod cannot rescue the dispatch that fails (a spawn
resolves before its model is first called, so only later dispatches fall back),
and the doctor cannot see a mod that is installed but not loaded (a `--bare`
session, a refused load), which is why the frontmatter stays the binding.

Files: `.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/register.ts` (the
registrations and their `.catch` handlers), `hooks/routing.ts`, `hooks/chain.ts`,
`hooks/status.ts`, `hooks/notices.ts`, `hooks/safety.ts` and `hooks/map.ts` (the
map parser), each with its `*.test.ts`. `scripts/mod-check.sh` runs `claude plugin
validate` for `make check` and `claude plugin test` for `make test`, failing
without `claude` unless `SDLC_SKIP_CLAUDE_MOD=1` says so; `tests/test_mod.sh`
runs the suite and checks every test title carries a REQ-ID.

## 4. Requirements as the spine

`templates/specs/requirements.md` shows the shape: EARS-style statements ("WHEN
… THE SYSTEM SHALL …"), each with an ID like `REQ-GATE-004`, and a verify tier
saying how it will be proven. `tasks.md` cites the IDs. Tests carry the ID as a
literal string. The two requirement gates then make the chain mechanical, and
`scripts/trace-matrix.sh` renders it as `specs/<feature>/matrix.html` with
uncovered requirements in red.

This repository eats its own cooking: `specs/` holds its in-flight features and
`specs/_shipped/` the audit trail of decisions already made, and every test file
under `tests/` is labelled with the REQ-IDs it proves. `grep -r REQ-GATE-004 tests/`
finds the proof of that one requirement.

## 5. Roles, agents and the engine map

Agents are Markdown job descriptions in `agents/`. Each carries a `model:` line
in its front matter, but that line is written by a script, not by hand:

```
agents/roles.conf              implementer = build, verifier = verify, …
~/.claude/sdlc-engines.conf    build = <model>, <fallback>; verify = …; read = …
scripts/apply-engines.sh       rewrites each installed agent's model: line
```

The roles are `judge` (the main session), `build`, `verify`, `read`, and
`escalate` (a lever the owner pulls by name, never automatic). Changing the model
the framework runs on is editing the map and re-running the
script; with the engine-map mod loaded (section 3) the edit alone applies at the
next dispatch for a role-bound subagent dispatched without a model of its own. No prompt, document or agent names a model, and `tests/test_docs_roles.sh`
fails if one does.

`adapters/codex/engines.toml` is the same idea for Codex, with a reasoning-effort
table beside the model table.

## 6. Installation, receipts and the doctor

`install.sh` copies the Claude adapter into `~/.claude` (agents, commands, hooks,
scripts, policy) and creates the engine map from its template on first run only.
It never edits `settings.json`; the hooks snippet is merged by hand once. It also
scans the workspace for project commands that shadow a global one and prints a
warning per shadow.

`core/installation.py` (~260 lines) writes a receipt of what was installed: file
hashes only, never contents. Files the installer shares with the owner or the
client (`config.toml`, `hooks.json`, `AGENTS.md`) are hashed by their
installer-owned fragment, so an owner's own edit elsewhere in them is not drift.

`core/doctor.py` (~545 lines) is the read-only inspector behind `./doctor`. It
checks the receipt against the source checkout, inventories dependencies and
client versions offline, discovers repositories in a workspace without following
symlinks or dependency directories, and reads per-project verification receipts.
Because the receipt records copied files and not whether the hooks are switched
on, it also reads `~/.claude/settings.json` and checks that every hook command in
`settings/hooks-snippet.json` is registered under its event; a missing hook, or a
settings file that is absent or unparsable, makes the doctor unhealthy by name.
A workspace in which it finds no repository reports `Nothing inspected` rather
than healthy.
With `--verify --project X` it runs that project's `make check` and `make test`
under one deadline with process-group cleanup and discards the output, so a test
can never leak a secret into saved state. A receipt is invalidated by any change
to the project's Git-visible content, so evidence cannot outlive the code it
proved.

`core/project.py` (~110 lines) enrols a repository: it inspects for the
`check`/`test` contract and, with `--apply`, adds the missing instruction entry
points and the pre-commit mirror without overwriting anything that exists.

## 7. Handoff between harnesses

`core/handoff_store.py` (~860 lines) is a private, atomic state store under
`~/.local/state/ainative-sdlc/handoffs/`, keyed by checkout. A handoff package
holds an immutable briefing (hashed; tampering blocks acceptance), a snapshot of
the repository state, and progress and return records. `core/handoff_runtime.py`
resolves the receiving role and model from the destination's engine map and
builds the launch command for the other client. `core/handoff.py` is the JSON
command-line interface the skills call.

The property that matters: **only acceptance transfers ownership.** The sender's
Stop gates keep refusing to end until the receiver has accepted; a prepared
package nobody accepted never expires into an allow. `should_yield()` answers the
Stop hook's question without creating any state, and one corrupt package is
diagnosed by name and blocks a new `prepare` until it is retired, never a
checkout-wide outage.

## 8. The Codex adapter

Codex has no shell-hook commit gate of the Claude kind, so `adapters/codex/` gives
it comparable checks in Python:

- `scripts/sdlc.py` (~550 lines): durable task loops with atomic JSON state, a
  bounded `check` runner, and the commit-gate hook. It lexes the command with a
  small shell tokenizer (never executing or expanding anything), recognises a
  standalone `git commit` and a bounded set of wrappers, and denies compound or
  wrapped forms with instructions to use the standalone form.
- `scripts/protected_paths.py` (~210 lines): a conservative PreToolUse guard for
  a repo's declared no-fix zones. Under a lock only a small read-only command set
  is accepted; it is an accidental-edit guard, not a sandbox, and says so.
- `scripts/routing.py`: plans native agent files from `engines.toml` without
  touching the running session.
- `scripts/install.py`: installs into `~/.codex` while preserving unrelated
  configuration, with a manifest and backups for rollback.
- `skills/openai-sdlc/`: the discoverable skill and its workflow references.

`core/policy.md` is the shared, harness-neutral policy; `adapters/claude/policy.md`
adds Claude routing; `adapters/claude/render-policy.py` composes the two into
`sdlc-policy.md`, and `make check` rejects drift between them.

## 9. How the tests are written

`tests/run.sh` executes every `tests/test_*.sh`; `tests/lib.sh` gives them
`req`, `assert_grep`, `capture`, `assert_rc` and fixture builders that copy the
gating surface into a temp directory. `tests/codex/` holds the Python suites,
run in a fake `$HOME` so an install test can never touch the real one.

Three habits worth copying:

- **Prove a guard by mutation.** `test_gate_hardening.sh` and `test_publish.sh`
  make the same fixture pass clean, then plant the fault and watch the suite go
  red. A test that greps for one spelling of a bug tests the spelling.
- **Assert on the operation.** Fixtures are made unreadable, timeouts are forced,
  Git selectors are planted, and the assertion is that the gate blocked.
- **Positive controls.** Every absence assertion sits next to a presence
  assertion, so a gutted file cannot pass by containing nothing.

## 10. Reading order

1. `settings/hooks-snippet.json`, then `hooks/check-gate.sh`: the enforcement.
2. `templates/specs/requirements.md` and `hooks/req-gate.sh`: the REQ chain.
3. `commands/spec.md`, `commands/build.md`, `commands/ship.md`: the lifecycle.
4. `agents/roles.conf`, `templates/sdlc-engines.conf`, `scripts/apply-engines.sh`.
5. `install.sh`, `core/installation.py`, `core/doctor.py`.
6. `core/handoff_store.py` for the ownership model.
7. `adapters/codex/scripts/sdlc.py` for the Codex mirror of the gates.
8. `tests/test_gate_hardening.sh` to see how a fail-open was found and closed.

## 11. Extending it

- **A new agent**: add `agents/<name>.md`, one line in `agents/roles.conf`, run
  `scripts/apply-engines.sh`. The scrub test and `test_engines.sh` cover it.
- **A new command**: add `commands/<name>.md`; `scripts/check-command-refs.sh`
  will hold every instruction file that cites it to a name that resolves.
- **A new hook**: keep it boring, drain stdin first, and remember that a crash
  or a timeout in a PreToolUse hook is an allow. Give it its own clock.
- **A project-only rule**: put it in that repo's `CLAUDE.md` or `AGENTS.md` as an
  add-on; the framework's rules are never copied into a project.
