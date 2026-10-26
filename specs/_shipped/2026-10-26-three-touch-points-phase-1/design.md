# Design — three-touch-points-phase-1

Input: `docs/sdlc-review-2026-10-26.md` (the review), its section 13 (the owner's
five decisions) and section 10 (phase 1 row). Harness facts below were checked
against the hooks, permissions and permission-modes docs for the installed client
build 2.1.310 on 2026-10-26. The adversarial spec review's accepted findings are
folded in; the three it rated critical (evidence staleness, branch read before
the command runs, a failed `source`) each have a requirement and a mutation test.

## Intent

Between the three human touch points everything is prose today: nothing records
that Gate 1 was passed, nothing records that the suite ran, and the Stop gate lets
the second stop through unchecked. Phase 1 gives each feature two machine-owned
files, three guards that read them, and the loop cap the Stop gate lacks, and it
fixes the five defects the review found. After it, Gate 2 still exists (four
touch points), but nothing between the points can be skipped silently.

Goals: a stamp and evidence that gates can read; guards that warn for two weeks
and then deny; `/hunt` whose stop rules survive compaction; re-injection that
actually fires; the mod proven on the current build.
Non-goals (later phases): integration and e2e lanes, `/validate`, the board and
prompt-state mods, the maintenance schedule, eval suites.
Anti-goals: a second engine map, a mod that gates, a copy of the policy in a repo.

## Approaches considered

1. **Checkboxes only (status quo plus prose).** Keep `tasks.md` as the only
   state and add sentences to the commands. Rejected: this is the reminder tax
   the review measured; nothing records approval or evidence, so nothing can
   require them.
2. **State and evidence files plus shell guards (chosen).** `state.json` and
   `evidence.json` under `specs/<feature>/`, written only by one script; the
   existing shell gates read them. Fits the repo's rule that gates are shell
   hooks with exit codes, is testable by mutation, and needs no new harness
   surface beyond one `SessionStart` entry and two `permissions.ask` rules.
3. **Native primitives as the state** (plan-mode approval as the stamp,
   `TaskCompleted` hooks as per-task evidence, a mod as the guard). Rejected for
   phase 1: plan files are not tied to `specs/`, harness tasks are not REQ-IDs,
   and the mod guard question (`tool.check`, fail-closed `.catch`) is exactly what
   this phase probes before phase 3 decides it.

## Components touched

- `scripts/sdlc-state.sh` (new): `init`, `stamp`, `evidence`, `record`,
  `status`. Installed by the existing `scripts/*.sh` loop and covered by the
  existing receipt, so the doctor needs no new code.
- `hooks/guard-lib.sh` (new, sourced with `|| exit 2`): `guard_mode <name>`,
  `guard_refuse <name> <text>`, `evidence_tree <path-or-ref>`; the warn
  window, the `.since` and `.log` files, `SDLC_GUARD_MODE`, `SDLC_GUARDS_DIR`.
- `hooks/check-gate.sh`: the `gate1-stamp` guard on `sdlc/*` commits, the
  `evidence-merge` guard on merge-family commands into the default branch, and
  a branch-change follower for `checkout`/`switch`.
- `hooks/dod.sh`: the loop cap with its own counter and exit-trap reset, and
  the `stop-evidence` guard ahead of the clean-tree and docs-only allows.
- `hooks/req-gate.sh`: Gate B per requirement; `UNTASKED` and `PARKED` labels.
- `hooks/postcompact-policy.sh` → renamed `hooks/compact-policy.sh`: emits
  `SessionStart`; `settings/hooks-snippet.json`: the `SessionStart` entry with
  matcher `compact`, the `PostCompact` entry removed, the `permissions.ask`
  rules.
- `scripts/merge-settings.sh`: union of permission lists.
- `install.sh`: seeds the guards directory; its two PostCompact messages.
- `agents/spec-reviewer.md`: `Bash` in `tools:`.
- `commands/spec.md`, `build.md`, `ship.md`: the state commands at the three
  points. `commands/hunt.md`: reordered.
- `adapters/claude/skills/sdlc-engine-map/`: `turn.start` filter, regenerated
  `types/`, the re-probe record here.
- Tests: `tests/lib.sh` (`SDLC_GUARDS_DIR`), `tests/test_state.sh` (new),
  `tests/test_guards.sh` (new), `tests/test_gates.sh`,
  `tests/test_gate_hardening.sh`, `tests/test_req_gate_per_req.sh` (new),
  `tests/test_hunt.sh`, `tests/test_postcompact_hook.sh` →
  `tests/test_compact_hook.sh`, `tests/test_engines.sh`,
  `tests/test_merge_settings.sh`, `tests/test_install.sh`,
  `tests/test_mod_docs.sh` (the ARCHITECTURE row names the renamed script),
  the mod's `*.test.ts`, `tests/test_touch_docs.sh` (new) for the prose.
- Docs: `ARCHITECTURE.md`, `AGENTS.md`, `README.md`.
- The Codex adapter is not touched: its guard stays the independently tested
  Python one (CLAUDE.md, "two enforcement designs").

## Data: the two files

`specs/<feature>/state.json` (REQ-TOUCH-001, 003, 006):

```json
{ "schema": 1, "feature": "<name>", "created_at": "<iso>",
  "gate1": { "approved_at": "<iso>|null", "spec_sha": "<sha256>|null" },
  "requirements": { "REQ-X-001": { "verify": "unit", "passes": false } },
  "digest": "<sha256 of the document with digest removed, keys sorted>" }
```

`specs/<feature>/evidence.json` (REQ-TOUCH-005, 007):

```json
{ "schema": 1, "feature": "<name>", "at": "<iso>", "branch": "sdlc/<name>",
  "head": "<sha>", "evidence_tree": "<sha>",
  "check": { "rc": 0, "seconds": 12, "command": "make check" },
  "test":  { "rc": 0, "seconds": 80, "command": "make test" },
  "coverage": { "REQ-X-001": "OK", "REQ-X-002": "DEFERRED" },
  "verifier":  { "verdict": "PASS", "note": "...", "at": "<iso>" },
  "ui-tester": null,
  "digest": "<sha256 as above>" }
```

Both are committed with the spec and archived with it on ship. The digest is
not a signature: it catches a hand edit and a truncated file, which is what the
gates need; it is computed with `jq -S` and `shasum -a 256`.

`passes` is written by `evidence` only (REQ-TOUCH-006): a REQ passes when the
whole suite was green in that run and `req-gate.sh --report` labelled it `OK`
(not `UNTASKED`, `PARKED` or `DEFERRED`). Per-lane and per-REQ results arrive
with the lanes in phase 2; this phase records the honest claim "its test was
part of a green run".

**Freshness is by evidence tree** (REQ-TOUCH-044). Committing the evidence
changes HEAD's tree, so a plain tree comparison would go stale on the commit
that records it (a loop at Stop, a dead merge guard). The evidence tree is the
tree with `specs/<feature>/state.json` and `specs/<feature>/evidence.json`
removed: a temporary index (`GIT_INDEX_FILE`), `git read-tree` of the ref or
`git add -A` of the working tree, `git update-index --force-remove` of the two
paths, `git write-tree`. The same function serves Stop (working tree), merge
(the named ref) and `status`. Trees rather than commits: a rebase that changes
nothing keeps the evidence, and any content change invalidates it.

## The guards (REQ-TOUCH-010 to 014, 045 to 047)

`SDLC_GUARDS_DIR` (default `~/.claude/sdlc-guards/`) holds `<guard>.since`
(epoch second the clock started) and `<guard>.log`. `install.sh` creates the
directory and seeds every missing `.since`. A guard self-seeds ONLY when the
directory itself is absent (a machine that never ran the installer); once the
directory exists, a missing, non-numeric or future `.since` is a deny with the
file named, so deleting or editing a clock cannot restart the grace window.
Warn window: 14 days, written `$((14 * 86400))` (the product spelled out
contains a four-digit run the year scrub matches). `SDLC_GUARD_MODE=deny|warn`
overrides the clock. Tests set `SDLC_GUARDS_DIR` in `tests/lib.sh` so the
owner's clocks are never read or mutated by the suite (REQ-TOUCH-051).

`guard-lib.sh` is sourced with `|| exit 2` and a message (REQ-TOUCH-047): the
gates run under `set -u` without `-e`, so a failed source would leave the guard
functions undefined and the script would fall through to its allows.

| Guard | Hook | Condition | Refusal names |
|---|---|---|---|
| `gate1-stamp` | PreToolUse, commit landing on `sdlc/<x>` | stamp missing, invalid or stale; or `<x>` resolves to no feature | `sdlc-state.sh stamp <feature>` after Gate 1 |
| `evidence-merge` | PreToolUse, merge-family command landing on the default branch naming `sdlc/…` | evidence missing, invalid, stale or red | `sdlc-state.sh evidence <feature>` on the branch |
| `stop-evidence` | Stop, on `sdlc/<f>` with every box `[x]` | evidence missing, invalid, stale or red | the same |

Warn output from PreToolUse: one JSON document on stdout,
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":
"WARN ..."}}` and nothing else. No `permissionDecision`: an `allow` there would
approve the whole Bash call and skip the `ask` prompt on a stamp chained into
the same command. The requirement gate's report text, which today goes to
stdout, is merged into the same `additionalContext` when both fire. The Stop
gate in warn mode exits 0 and prints the warning to stderr; a Stop hook has no
context channel on allow, so the `.log` line is the record there.

**The branch the command lands on, not the branch it starts on** (REQ-TOUCH-048,
049). The gate today exits 0 for anything not commit-shaped, so `git checkout
main && git merge sdlc/x` and `git switch -c sdlc/x && git commit` would both
skip a guard that read the current branch. The gate therefore recognises, after
the heredoc strip and the `cd`/`-C` following it already does: the commit
shape (existing), a merge-family shape (`merge`, `pull`, `rebase`, `reset`
naming a ref), and a branch-change shape (`checkout`, `switch`, with `-c`/`-b`,
`--`, quoted targets). The landing branch is the last literal `checkout`/
`switch` target before the commit or merge, else the current branch; a target
the parser cannot read (a variable, `-`, `@{-1}`, a detached sha) is a refusal
under the guard's mode. Merge-family refs are resolved as given: `sdlc/<f>`,
`sdlc/<f>-<task>`, `origin/sdlc/…`, `refs/heads/sdlc/…` all resolve to the
feature by the longest-prefix rule; octopus merges apply the guard to every
`sdlc/` ref named. Forms deliberately left outside (Known limits): `git -c`
aliases, `eval`, a ref held in a variable.

Branch to feature (REQ-TOUCH-015, 016): the longest feature directory name that
is `<x>` or a prefix of `<x>` followed by `-`. `sdlc/hunt-*` and `sdlc/rca-*`
are exempt by name (they have no spec by design); any other `sdlc/<x>` that
resolves to nothing is a refusal under the guard's mode, because a worktree
whose spec was never committed is exactly the case the stamp exists for. That
is why `spec.md` now commits the spec and the stamp before `/build` (REQ-TOUCH-030).

## The Stop gate's own counter (REQ-TOUCH-019, 020, 050)

The client caps consecutive Stop-hook blocks (binary string
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8, allows at the cap). The gate keeps
its own count in `$SDLC_GUARDS_DIR/stop/<session key>.count`, with a default cap
of 6 so it fires before the client's and the UNVERIFIED line is actually seen;
the session key is the payload's `session_id`, else `unknown`. Every block
increments; an exit trap resets the count on any exit 0, so the seven allow
paths in `dod.sh` need no reset of their own. `stop_hook_active` is read only
to know a retry is happening; it no longer allows anything by itself.

Order inside `dod.sh` (REQ-TOUCH-021): guard library, loop cap, then the
`stop-evidence` guard, then the existing clean-tree and docs-only allows. A
fully committed feature branch is a clean tree, so the guard must come first or
it never runs. Order inside `check-gate.sh` (REQ-TOUCH-015): the stamp guard
before the docs-only `run_req_gate` shortcut, for the same reason: ticking the
last box is a prose-only commit.

## Gate B per requirement (REQ-TOUCH-025 to 027)

For each REQ-ID: collect the checkbox lines of `tasks.md` citing it, where a
checkbox line includes its indented continuation lines. All `[x]` and at least
one line: claimed, Gate B applies. Any `[!]`: `PARKED`, reported, not blocked.
Any `[ ]` or `[~]`: open. No line at all: `UNTASKED`, and the old file-level
rule applies (claimed only when the file has no open box). Checked against this
repository's two open specs on 2026-10-26: `interactive-handoff`'s eight IDs all
sit on `[x]` lines, so they become claimed per requirement, and all eight have
tagged tests, so nothing goes red; `workspace-interoperability`'s eight IDs sit
on no checkbox line (cited in prose), so they are `UNTASKED` and stay unclaimed
while its T4 box is open.

## Post-compaction re-injection (REQ-TOUCH-033 to 036)

`PostCompact` is a documented event with "no decision control", for side
effects; no doc says it delivers `additionalContext`. `SessionStart` with
matcher `compact` is documented and adds its stdout as context. The script moves
to that entry and emits `hookEventName: SessionStart`. The session-engines entry
keeps excluding `compact`. Live confirmation on the installed client is
REQ-TOUCH-036, deferred to the Gate 2 checklist: the suite cannot compact a
session. The installer deletes nothing, so the old `postcompact-policy.sh` and
the owner's old `PostCompact` settings entry stay until the owner removes them
(see Irreversible actions); the old entry is harmless meanwhile.

## The stamp as the owner's act (REQ-TOUCH-041, 042, 053)

The docs state that explicit `ask` rules still force a prompt in auto mode. The
snippet carries `Bash(*sdlc-state.sh stamp *)` and an `ask` rule for `Edit`/
`Write` on `specs/*/state.json`, so the ordinary ways of stamping raise a prompt
the owner answers. This is a tripwire, not a wall: a session that writes the
file through a shell redirection and recomputes the digest raises no prompt,
and the suite cannot prove that a prompt appears (REQ-TOUCH-041 claims only
that the snippet carries the rules). The stamp prints the feature, the
requirement count and the spec sha first, so the prompt shows what is being
approved. `merge-settings.sh` must union the permission lists for the rules to
reach a settings file that already has `permissions.ask`.

## `/hunt` reordered (REQ-TOUCH-031, 032)

New order: Arguments; H (what it must never do); the stop rules of F (the
permitted stop reasons, `STOPPED:`, re-invocation after a stop); then A to E,
the rest of F, and G. Section letters keep their names so the cross-references
in the prose stay true; `tests/test_hunt.sh`'s order assertions are updated to
the new order, and one new assertion pins the byte budget at 16,000 bytes
(about 3,700 tokens, under the roughly 5,000 the client keeps per skill after
compaction, with margin). Moving the bulk to a skill with `references/` was
considered and left for the phase that moves the commands to skills: it changes
the installer, the shadow scan and the receipts.

## Engine-map mod re-probe (REQ-TOUCH-037 to 039)

Regenerate `types/` with the plugin-authoring skill on the installed build, run
validate and test, then a probe plugin (throwaway, under the scratchpad, never
installed) observes: `turn.start` for a subagent turn (`agentId` present), the
`resume` field on `agent.spawn`, a `tool.check` hook that throws with and
without `.catch`, and a hook that sleeps past 10 seconds. Findings go in the
"Re-probe record" below; the one code change is the `turn.start` filter. No
gating hook is added: the rule "a mod routes and informs; it never gates" is
re-decided in phase 3 on the record this probe writes.

## Irreversible actions (must be surfaced at Gate 1)

None in the repository. Owner-side effects, each reversible but each needing
the owner's hand:
- The guard clocks start at install: 14 days after the owner runs `install.sh`,
  the three guards deny on every repo on this machine. Reversible with
  `SDLC_GUARD_MODE=warn` (deleting a `.since` now denies, by design).
- Every in-flight feature in every enrolled repo that has a `specs/<feature>/`
  and an `sdlc/<feature>*` branch needs a stamp before day 14, or its commits
  are refused. `sdlc-state.sh status` lists the unstamped ones; stamping an
  in-flight feature is the owner saying "this was approved", at the prompt.
- `~/.claude/settings.json` must be re-merged by the owner (a session cannot
  edit it): the `SessionStart compact` entry and the two `ask` rules do nothing
  until then, and the doctor reports drift until it is done. The old
  `PostCompact` entry and `~/.claude/hooks/postcompact-policy.sh` are the
  owner's to delete; the global `~/.claude/CLAUDE.md` names a PostCompact hook
  in its routing paragraph and wants one line changed.

## Deviations from the review's phase 1 row (for Gate 1)

- `/hunt` is reordered, not split into a references file.
- The stamp adds one permission prompt per feature (the review's phase 1 row
  had the stamp written by `/spec` with no prompt).
- The Stop gate's cap is its own counter at 6, not the client's 8.

## Gate 1 record (2026-10-26)

Walked one at a time; the owner took the recommendation on each:
1. The stamp stays a permission prompt (`Bash(*sdlc-state.sh stamp *)` plus an
   `ask` on editing `state.json`).
2. In-flight features in other repos are stamped on first touch: the next
   session that works on an unstamped feature offers the stamp once at the
   prompt; no blanket stamping, no exemption for old specs.
3. REQ-TOUCH-036 (live re-injection after a real compaction) is deferred to
   the Gate 2 checklist.
4. `/hunt` is reordered now; the skill conversion waits for the
   commands-to-skills phase.
Bootstrap: this feature's own stamp is written by T1 the moment the script
exists, with `approved_at` set to the approval above, since no stamp script
existed at approval time.

## Owner decisions already taken (review section 13)

B in four phases; warn two weeks then deny; e2e gates per requirement (phase 2);
fitness checks plus fortnightly `/arch-review` (phase 2 and 3); superpowers
7.0.1 installed and enabled before this spec (checked: `claude plugin list`).

## Known limits (stated, not promised away)

- A shell alias, `--bare`, `disableAllHooks` or a hook the owner edits bypasses
  every guard; the policy already says hooks are not a security boundary.
- The digest detects edits, not authorship; the `ask` rules are a tripwire on
  the ordinary paths, not a wall (above).
- Command forms the gate does not follow: a `git -c alias.*` alias (a merge
  hidden behind an alias is not seen); a branch held in a shell variable as a
  `checkout`/`switch` target is refused as unreadable, but a merge ref held
  in a variable (`git merge "$B"`) carries no `sdlc/` text and is NOT seen;
  a merge-family argument not spelled `sdlc/…` (a tag or a sha at the tip of
  an `sdlc/` branch) is not seen; branch moves outside the merge family
  (`git branch -f main sdlc/x`, `git push . sdlc/x:main`, `git update-ref`)
  are not seen. Quoted text is not stripped, so `eval "git merge sdlc/x"`
  and `bash -c "…"` ARE seen and guarded. Listed here rather than claimed.
- `git --git-dir <d>` / `--work-tree <d>` are recognised (so the subcommand
  after them is still seen) but not followed: the gate decides in the
  repository of the payload's cwd or the command's `cd`/`-C`, not in the one
  those options name.
- `git pull <remote> sdlc/<x>` is checked against the remote-tracking ref
  `<remote>/sdlc/<x>` as it stands BEFORE the fetch the pull performs; a
  commit pushed between the check and the pull is merged unchecked. The
  verifiable spelling is `git fetch` then `git merge <remote>/sdlc/<x>`.
- Two rebase spellings are not recognised as landing on the default branch
  and are left for a follow-up: `git rebase --root <branch>` (one positional)
  and a rebase whose positional names the default branch by an unreadable
  spelling (`HEAD`, `@{-1}`, a sha) rather than its name.
- REQ-TOUCH-053's rationale overclaims the mechanism: a Bash permission
  prompt shows the command text, never its stdout, so the feature, count and
  spec sha the stamp prints are the session's record of what was stamped
  (written before the file, so a refused write still leaves the record), not
  what the prompt displays. The requirement's observable clause (print before
  write) holds and is tested; the "so the prompt shows" clause does not.
- `passes` is feature-wide evidence in this phase, not per-lane.
- The Stop gate's warn mode is visible to the owner, not the model.
- REQ-TOUCH-036 is a live observation; the suite proves the registration and
  the script, not the client's behaviour.

## Re-probe record

<!-- Written by T11 on the installed build: build id, then one entry under each
     heading: `agent.spawn` on resume; `turn.start` for subagent turns;
     `tool.check` throwing with and without `.catch`; the per-hook budget. -->

Build: 2.1.310 (2026-10-26)

How it was probed: two throwaway plugins, `probe-a` (hooks `agent.spawn`,
`turn.start`, `tool.check`, no `.catch` anywhere) and `probe-b` (one
`tool.check` hook with a `.catch` that answers `{ decision: 'deny' }`), written
under the session scratchpad and never installed. Each hook writes what it saw
with `$.ui.log`, which lands in the debug log as `[probe-x] $.ui.log: PROBE ...`.
Both were loaded for one headless run each with `--plugin-dir`; the debug log
shows `hooks module probe-a@inline loaded (worker, environment 1, tier user);
events: agent.spawn,turn.start,tool.check` and the same for `probe-b`
(`events: tool.check`). The installed engine-map mod was loaded beside them
(`sdlc-engine-map@skills-dir`). Commands, `<s>` standing for the scratchpad:

    claude -p "<steps>" --model haiku --plugin-dir <s>/probe-mod/probe-a \
      --plugin-dir <s>/probe-mod/probe-b --allowedTools 'Bash(echo:*)' Agent SendMessage \
      --debug-file <s>/probe-run/run1.debug.log          # run 1, exit 0
    claude -p "<steps>" --model haiku --plugin-dir <s>/probe-mod/probe-a \
      --allowedTools Agent SendMessage --debug-file <s>/probe-run/run2.debug.log   # run 2, exit 0

Run 1 asked for four Bash calls (`echo PROBE_NOCATCH_THROW`, `echo
PROBE_CATCH_THROW`, `echo PROBE_NOCATCH_SLEEP`, `echo PROBE_CATCH_SLEEP`, each
string the trigger of one probe branch), then one general-purpose subagent.
Run 2 started one subagent and then sent it a message by its agent id. Under
`--allowedTools 'Bash(echo:*)'` the verdict beneath every probe hook is allow,
so a call that is refused was refused by a hook.

### agent.spawn on resume

Observed (run 2). A new subagent raises `agent.spawn` without `resume`; a
SendMessage to a finished subagent raises `agent.spawn` again WITH `resume`,
carrying the id the run continues under, and `next` settles with that same id:

    00:06:19.806Z [probe-a] $.ui.log: PROBE agent.spawn keys=background,cwd,description,fork,model,name,parentModel,permissionMode,prompt,provider,subagentType,tool_use_id resume=null subagentType=general-purpose parentAgentId=-
    00:06:19.819Z [probe-a] $.ui.log: PROBE agent.spawn result={"model":"claude-haiku-5-5","agentId":"a6f20ff57c242e4d2"}
    00:06:27.133Z [probe-a] $.ui.log: PROBE agent.spawn keys=background,cwd,description,fork,model,name,parentModel,permissionMode,prompt,provider,resume,subagentType,tool_use_id resume={"agentId":"a6f20ff57c242e4d2"} subagentType=general-purpose parentAgentId=-
    00:06:27.142Z [probe-a] $.ui.log: PROBE agent.spawn result={"model":"claude-haiku-5-5","agentId":"a6f20ff57c242e4d2"}

`resume` holds `agentId` only; every other key of a new spawn is still
present. The build's declarations say a hook can only refuse a resumed spawn
and a changed content key (the model included) is ignored and said once; that
part was read from the types, not exercised. Consequence for the mod: a resumed
agent arrives as a second `agent.spawn` for an id the mod may already have
recorded, and its model cannot be moved there.

### turn.start for subagent turns

Observed (runs 1 and 2). A subagent's turn raises `turn.start` with `agentId`
set to the subagent's id; the main loop's turn has no `agentId` key at all:

    00:05:04.667Z [probe-a] $.ui.log: PROBE turn.start keys=text,turnId agentId=- turnId=a9981944-3d98-4317-ad9d-617aea76437a
    00:05:35.576Z [probe-a] $.ui.log: PROBE turn.start keys=agentId,text,turnId agentId=a4c7448f5d33c5f9c turnId=e04a622a-20ed-4636-b627-91b8ca29fa66
    00:06:27.142Z [probe-a] $.ui.log: PROBE turn.start keys=agentId,text,turnId agentId=a6f20ff57c242e4d2 turnId=b4f7f874-3386-402c-97f8-3b0d29639a8e

The last line is the resumed run of run 2: a resume raises a subagent
`turn.start` too. The installed engine-map mod (before this change) was
dispatched on the same subagent turn: `hooks module probe-a@inline,
sdlc-engine-map@skills-dir turn.start settled in 13.1ms` follows the subagent
line at 00:05:35.584Z, which is what the `agentId` filter (REQ-TOUCH-037) now
passes on untouched.

### tool.check throwing with and without .catch

Observed (run 1).

Without `.catch` (probe-a throws): the hook is skipped, the verdict beneath
stands, and the tool RAN. The guard failed open. The debug log and, in a
headless run, stderr say so:

    00:05:08.001Z [probe-a] $.ui.log: PROBE probe-a tool.check throwing (no .catch)
    00:05:08.001Z [ERROR] hook failed: probe-a: errorKind=Error errorChars=24 (tool.check; skipped; what is below it ran in its place)
    00:05:08.001Z [ERROR] probe-a: tool.check hook skipped: threw Error: probe-a deliberate throw
    stderr of the run: probe-a: tool.check hook skipped: threw Error: probe-a deliberate throw
    model's report: `echo PROBE_NOCATCH_THROW` ran, output PROBE_NOCATCH_THROW

With `.catch` (probe-b throws, its `.catch` answers deny): the handler is
called with `next.error = {"kind":"throw","message":"probe-b deliberate
throw","budget":1000}` and `next.called = false`, its answer is the verdict,
and the tool was REFUSED. The engine names this "failed closed":

    00:05:10.118Z [probe-b] $.ui.log: PROBE probe-b .catch called error={"kind":"throw","message":"probe-b deliberate throw","budget":1000} called=false at 1792973110118
    00:05:10.118Z [WARN] hook failed closed: probe-b: errorKind=Error errorChars=24 (tool.check; its .catch answered)
    00:05:10.118Z [DEBUG] tool.check Bash toolu_015HhsDZXg5kzjALuASeXoWv: unevaluated -> deny by plugins probe-a, probe-b: probe-b .catch denies
    model's report: refused, "Permission to use Bash denied by plugins probe-a, probe-b: probe-b .catch denies"

So the client does let a `.catch` turn a failing `tool.check` hook into a
refusal; without one it is an allow. This is the fact phase 3 re-decides "a
mod routes and informs; it never gates" on. The mod's own `.catch` handlers
answer `next(e)`, so they stay fail-open by design.

### the per-hook budget

Observed (run 1). The budget is 10 s of the hook's own time (a `$.clock.sleep`
counts); `.catch` gets a fresh 1 s grace (`budget: 1000`).

Without `.catch` (probe-a sleeps 11 s, then would answer deny): at 10 s the
hook is skipped as timed out, the verdict beneath runs in its place and the
tool RAN; the hook kept running and woke a second later, its deny discarded:

    00:05:12.198Z [probe-a] $.ui.log: PROBE probe-a tool.check sleeping 11000ms (no .catch) at 1792973112198
    00:05:22.200Z [ERROR] hook failed: probe-a: errorKind=HooksError errorChars=23 (tool.check; skipped; what is below it ran in its place)
    00:05:22.200Z [ERROR] probe-a: tool.check hook skipped: ran past its 10s budget
    00:05:22.206Z [DEBUG] hooks module probe-a@inline, probe-b@inline tool.check settled in 10007.6ms (worker hop, next() included)
    00:05:23.201Z [probe-a] $.ui.log: PROBE probe-a tool.check woke at 1792973123201, answering deny
    model's report: `echo PROBE_NOCATCH_SLEEP` ran

With `.catch` (probe-b sleeps 11 s, then would answer allow): at 10 s the
`.catch` is called with `{"kind":"timeout","budget":1000}`, its deny is the
verdict and the tool was REFUSED; the hook's late allow a second later
changed nothing:

    00:05:23.460Z [probe-b] $.ui.log: PROBE probe-b tool.check sleeping 11000ms (with .catch) at 1792973123460
    00:05:33.462Z [probe-b] $.ui.log: PROBE probe-b .catch called error={"kind":"timeout","budget":1000} called=false at 1792973133462
    00:05:33.462Z [WARN] hook failed closed: probe-b: errorKind=HooksError errorChars=23 (tool.check; its .catch answered)
    00:05:33.463Z [DEBUG] tool.check Bash toolu_01D3q7aPpiSJV618suzMPpG9: unevaluated -> deny by plugins probe-a, probe-b: probe-b .catch denies
    00:05:34.463Z [probe-b] $.ui.log: PROBE probe-b tool.check woke at 1792973134462, answering allow
    model's report: refused, "Permission to use Bash denied by plugins probe-a, probe-b: probe-b .catch denies"

Not exercised: a `.catch` that itself outruns its 1 s grace (the declarations
say the hook is then absent as if it had no handler, i.e. fail-open again).

## Assumptions

<!-- Written DURING the build, never asked mid-flight: one line each, what was
     assumed, why, how to reverse. Ratified at Gate 2. -->

- `sdlc-state.sh init` refuses (exit 1, naming the file, file untouched) when `state.json` already exists, because a re-run must never erase a stamp or a `passes` value; `stamp` picks up new REQ-IDs instead. Reverse by adding an explicit `--force` to `init`.
- T7: in `--report`, a claimed ID with no tagged test prints only its `GATE B:` line and no label (it used to print `OK` too), so nothing reads it as passing; an ID of a feature with no `tasks.md` is labelled `UNTASKED` (was `OK`) and still never blocked. Reverse: emit `<feat> <id> OK` after the `GATE B:` line in `hooks/req-gate.sh`.
- T7: a checkbox line's continuation is every following indented line; an unindented non-blank line ends it, a blank line does not; a box other than `[ ]`, `[~]`, `[!]` counts as `[x]` (as the file-level rule always did). Reverse: the `awk` block in `hooks/req-gate.sh`.
- T9: section F moved up whole (Arguments + H + F are about 13.3 KB, under the 16,000-byte budget) rather than split; to reverse, split F at its `### Stopping` part and move the remainder after E.
- T9: one word in section B changed ("any later section" → "any other section") because F now sits above B; to reverse, revert the word.
- T9: the REQ-HUNT-066 order assertion now reads "declared before written" as runtime order (F heading, then B and its two declarations), not file position; to reverse, restore the old assert_order.
- T10: compact-policy.sh emits nothing (exit 0) for any payload whose source is not `compact` (startup, resume, clear, absent, non-JSON, closed stdin), so the policy is never injected at startup; to reverse, drop the source guard in the script.
- T10: the shipped label REQ-POLICY-006 ("ITS PostCompact entry") now sits on the SessionStart compact entry assertion beside REQ-TOUCH-033; the protected shipped spec text is not edited; to reverse, delete that label line in tests/test_compact_hook.sh.
- T8: in /build, a feature whose stamp the owner declines or cannot answer is skipped and named in the build summary (unattended-safe, no silent stamping); to reverse, change that sentence in build.md.
- T8: /build and /ship commit evidence.json after `record`, because the merge guard reads the named ref and uncommitted evidence is invisible to it; to reverse, drop the commit sentences in build.md and ship.md.
- T8: the commands name the installed path `~/.claude/scripts/sdlc-state.sh` at first mention and the bare name after; to reverse, edit the paths.
- T12: the ask rules use the gitignore-style path `**/specs/*/state.json` (the form the owner's own rules use), so a nested worktree path matches too; to reverse, drop the `**/`.
- T12: when an existing `permissions` key or one of its lists has the wrong JSON type, merge-settings.sh keeps the owner's value and adds no rules rather than refusing; to reverse, make that case die.
- T3b: the gates locate guard-lib.sh by parameter expansion on `$0`, not dirname(1), because dirname is not guaranteed on PATH (the no-jq test proves it); to reverse, use dirname and accept that refusal.
- T3b: tests/lib.sh points SDLC_GUARDS_DIR at an existing empty mktemp directory, so inside the suite a guard DENIES unless the test seeds a `.since` or sets SDLC_GUARD_MODE (REQ-TOUCH-046); to reverse, point it at a not-yet-created child so the first guard self-seeds and warns.
- T3c: install.sh seeds `$HOME/.claude/sdlc-guards` and ignores SDLC_GUARD_DIR overrides; to reverse, honour the variable in the installer.
- T3b+T3c were built in one implementer run because both edit install.sh; one branch, two boxes.
- T11: the probe ran headless on `--model haiku` with `--plugin-dir`; the findings describe the client, not the model; to reverse, rerun the probe scripts on another model.
- T11: the new mod test titles carry REQ-MOD-016 beside REQ-TOUCH-037 because test_mod.sh requires a REQ-MOD id in every title; to reverse, widen that check to REQ-TOUCH.
- T11: types/index.d.ts is the mod's hand-written state contract and regeneration changed nothing (the engine writes its API declarations into the uncommitted .claude-plugin/types/ at load).
- T2: `evidence` records the evidence tree computed BEFORE the runs (the tree that was tested) and warns if the runs changed it; to reverse, record the tree computed after.
- T2: `evidence` needs BOTH a check and a test contract (half a contract cannot verify) and always runs both so both exit codes are recorded; to reverse, allow a check-only run or skip test after a red check.
- T2: `evidence` sets `passes` only for IDs already in state.json (adding IDs stays `stamp`'s job), and `record` accepts a verdict against red evidence when it is current (a FAIL on red is legitimate); to reverse, merge new IDs or refuse red.
- T2: `evidence-state` on an unknown ref prints `none` (stderr says no such ref) and a ref whose tree cannot be computed prints `stale`; `status` shows no verdicts for invalid evidence; to reverse, print `invalid` for the unknown ref.
- Shipped REQ-GATE-006 ("ship no `permissions` key") is superseded by the owner-approved REQ-TOUCH-041 (ask rules on the stamp); its test now asserts the clause's stated intent, no rule gates a push; the protected shipped spec text is not edited. OWNER TO CONFIRM at Gate 2; to reverse, drop the ask rules.
- T13: CLAUDE.md carries the same new rule bullet as AGENTS.md because test_readme.sh requires the two to match apart from the decision-log line; to reverse, revert both together.
- T13: the docs describe `evidence`, `record`, `evidence-state`, the guards and the Stop counter as design.md specifies them; verify the names against the landed T2/T4/T5/T6 code at wrap-up.
- T6: the Stop block cap is checked when the gate is about to block, not at the top, so a stop at the cap whose tree is green exits 0 without a false UNVERIFIED line; to reverse, test the cap right after the trap is set.
- T6: the counter is set up before the repository root is found (a cd failure counts, a not-a-repo allow resets); a failed library source exits 2 before the counter exists and relies on the client's own cap of 8; to reverse, set the counter up before the source.
- T6: an unreadable tasks.md counts as "no open box", so the evidence guard runs and refuses rather than allowing; a feature part with `/`, a leading `_`, `.` or `..` is not a feature branch.
- T5: a plain `checkout`/`switch` target counts as a landing branch only when it exists as a local branch or under refs/remotes/*/; otherwise it is treated as a path checkout and the current branch is used; path-mode forms (`--`, `--ours`, `--theirs`, `-p`, two positionals) are skipped, not refused; to reverse, return the target or `bad` in land().
- T5: merge-family refs are resolved as given (`git pull origin sdlc/x` checks the local `sdlc/x`); any `sdlc/`-shaped argument counts as a ref and a ref containing `$` is refused; in warn mode an unreadable target skips that command's guard; to reverse, tighten the ref collection or use current_branch.
- T5: Known limits narrowed: alias forms are not seen (the sentence claimed a refusal that nothing implements); eval and bash -c forms are seen because quotes are not stripped.
- FIX-B: when the Stop counter cannot be written every refused stop is allowed loudly with UNVERIFIED (no writable place remembers one allow); guards_seed_all seeds the three named guards plus the one evaluating; to reverse, keep a per-session marker in TMPDIR.
- FIX-A: option values are skipped per subcommand (merge: -m -F -X -s --strategy --strategy-option --into-name; pull: -X -s …; rebase: -X -s -C --exec -x); `-S`/`--gpg-sign` and `--onto` values are NOT skipped because they can carry a ref; `git pull . <ref>` keeps the local ref; a command that changes directory between its git commands is refused under the guard's mode; to reverse, widen the skip lists or anchor on the first command.
- FIX-D: a rebase or pull carrying an option outside the closed known-option list is refused under the guard's mode only when it may land on the default branch (current branch, a positional naming the default, or a dynamic positional); combined short flags such as `-qv` count as unknown; to reverse, refuse unconditionally or extend the lists.

## Decisions & rejected alternatives

- Evidence trees, not commit trees, decide freshness (committing the evidence
  must not stale it; a rebase keeps it; an edit kills it).
- The stamp hashes `requirements.md` only: approval is of the requirements;
  design.md gains Assumptions during the build and tasks.md gains checkboxes.
- The guard's clock is seeded at install, and only a missing directory
  self-seeds: a deleted clock denies instead of restarting the window.
- The gate decides on the branch the command lands on; unparseable branch
  changes refuse rather than guess.
- `hunt.md` is reordered rather than converted to a skill (see above).
- The Stop gate keeps its own block counter, below the client's cap, rather
  than trusting an undocumented default.
- The warn JSON carries no `permissionDecision`: a warning must never approve.
