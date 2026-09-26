# Design — engine-map

## Approach

Four moving parts, each with one job:

1. **The policy routes by role.** `sdlc-policy.md` stops naming Fable, Opus and
   Haiku in its table and names `judge`, `build`, `verify`, `read` instead. The
   table keeps every phase row it has today. This is the change that makes the
   framework survive a plan the owner has not bought.
2. **One file binds role to model.** `~/.claude/sdlc-engines.conf`, owned by the
   owner, created once by the installer, never overwritten afterwards. Each role
   gets an ordered list: the first entry is what runs, the rest is the fallback
   chain to drop to when the first is unavailable.
3. **A script makes the map effective.** Agents pin `model:` in their own
   frontmatter, so editing the map alone changes nothing. `apply-engines.sh`
   reads the map plus a role manifest and rewrites exactly the `model:` line of
   each installed agent. The installer runs it; the owner can re-run it after
   editing the map.
4. **`escalate` is a lever, not a row.** The routing table never sends a phase to
   the escalation engine on its own. The owner raises a phase to it by naming it
   in the moment, and a session may offer it when a judgement is close, contested
   or costly to get wrong. This is what "Opus for everything, Fable sometimes"
   looks like without a second routing table to keep in sync: the map's four
   working roles say what runs by default, and one extra line says what is
   available when it is worth it.
5. **Every session says what it is actually running.** A `SessionStart` hook
   injects the map and requires a one-line statement of the model in use and the
   roles it covers, including an explicit note when the running model is not the
   `judge` entry.

### The honest limit on "unavailable"

No shell script can ask the account which models a plan includes. So availability
is never auto-detected. The chain is documented and ordered, the owner edits the
map when a plan changes, and the mechanism that catches a mismatch is the session
itself: the model knows which model it is, the hook shows it what the map expects,
and requirement 019 makes the discrepancy something the session must say out loud
rather than route around. That is why the "check at the start of every session"
half of this feature is a hook plus an instruction, not a probe.

## Components touched

| File | Change |
|---|---|
| `sdlc-policy.md` | Engine column becomes a role. Opening line stops asserting a model for the main session. New short section: the four roles, the map's path, the fallback rule, owner-named model wins, no project-level `model` pin. |
| `templates/sdlc-engines.conf` | NEW. The shipped default is **one working model everywhere**: `judge = opus, sonnet` · `build = opus, sonnet` · `verify = opus, sonnet` · `read = haiku, sonnet`, plus `escalate = fable, opus`. Comments explain the format, how to change it after a plan change, and that swapping the whole framework to another model means editing three lines. |
| `agents/roles.conf` | NEW. `<agent> = <role>` for all seven agents: implementer→build; spec-reviewer, verifier, evidence, ui-tester, test-auditor→verify; researcher→read. No agent maps to `judge` (the judge is the main session, which has no frontmatter). |
| `scripts/apply-engines.sh` | NEW. Reads `$HOME/.claude/sdlc-engines.conf` and `<repo>/agents/roles.conf`; for each installed agent under `$HOME/.claude/agents/`, sets the `model:` line to the first model of its role. Validates first, writes second: a malformed map or an unknown role aborts before any file is touched. Idempotent; prints `<agent>: <old> → <new>` per change and a total. |
| `hooks/session-engines.sh` | NEW. `SessionStart` hook. Emits `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}` built with `jq -Rs` from the map plus a fixed instruction block. No map on disk means a valid JSON payload saying so, exit 0. Never blocks a session. |
| `settings/hooks-snippet.json` | Gains the `SessionStart` entry. |
| `install.sh` | Creates the map from the template only when absent; runs `apply-engines.sh` after installing agents and propagates its exit code; closing instructions gain the map and the new hook, and lose the stale `sdlc_llm` line. |
| `README.md` | "Project layer" gains the engine map: path, format, created-once, and the re-run-after-editing step. |
| `index.html` | The crew table becomes roles bound by the map; the file map lists the new files. |
| `tests/test_engines.sh` | NEW. Content assertions for the policy, template, manifest, snippet and docs. |
| `tests/test_apply_engines.sh` | NEW. Behaviour of the script and the installer in a throwaway `HOME`: create-once, never-overwrite, rewrite, idempotence, byte-exactness, error paths, hook output shape. |

## Data / API changes

One new owner-owned file, `~/.claude/sdlc-engines.conf`. Format chosen over a
Markdown file because the hook and the script both parse it and a `.conf` invites
no prose for a parser to skip, while still reading clearly when the hook pastes it
into context.

## Irreversible actions (must be surfaced at Gate 1)

- **`apply-engines.sh` rewrites installed agent files in place.** Those files are
  copies the installer owns and re-creates from the repo on every run, so a bad
  rewrite is undone by re-running `install.sh`. The script still validates the
  whole map before writing anything, so a malformed map cannot leave the agents
  half-rewritten.
- Nothing else is destructive. The installer still deletes nothing, and this
  feature adds a file rather than removing one.
- **One owner step remains manual:** merging the new `SessionStart` entry into
  `~/.claude/settings.json`. The auto-mode classifier blocks the session from
  editing that file, so the installer states it and the build hands over a script
  to run.

## Portability and mechanics (pinned after spec review)

- **bash 3.2.** `/bin/bash` on this machine is 3.2, so no associative arrays and
  no `mapfile`. The map and manifest are parsed with `awk`/`while read` into
  parallel plain variables or a temp file.
- **Never `sed -i`.** BSD requires an argument, GNU forbids one. Every rewrite is
  `awk` to a `mktemp` file in the target's own directory, then `mv` over it, which
  also satisfies the atomicity requirement.
- **The frontmatter fence is the boundary.** Only the first `model:` line strictly
  between the opening `---` and the next `---` is eligible. A body line beginning
  `model:` is untouched, and a file with no fence is skipped.
- **Byte-exactness is proved by reconstruction, not by diff-minus-a-line.** The
  test snapshots the file, runs the script, rebuilds the expected content by
  substituting exactly that one line, and `cmp`s. Fixtures: a body line starting
  `model:`, no `model:` line at all, no trailing newline, CRLF endings.
- **The hook drains stdin** the way `req-gate.sh` does, because a SessionStart
  hook is handed a JSON payload it does not need.

## Assumptions
<!-- Written DURING the build, never asked mid-flight. -->

- Model names in the map are passed through verbatim to agent frontmatter; the
  framework does not validate them against a catalogue, because the valid set
  changes with the plan and with releases. A typo therefore surfaces when the
  agent is dispatched, not when the map is saved.

## Decisions & rejected alternatives

- **A separate role manifest, not a `role:` key in agent frontmatter.** Adding an
  unknown key to agent frontmatter risks a validation error in some harness
  versions for no gain. A manifest costs one extra line when an agent is added
  and cannot break agent loading.
- **`.conf`, not `.md`.** Both the hook and the script parse it; a Markdown file
  would invite headings and prose that a parser must learn to skip.
- **No availability probe.** Rejected as undeliverable from bash, and dangerous if
  faked: a wrong "available" verdict would silently route work to a model the
  owner did not choose. The session-start announcement is the honest substitute.
- **`judge` deliberately binds no agent, and that is not an error.** The first
  draft would have made the shipped default map fail validation on a clean
  machine, because no agent claims the `judge` role. A role with no agents is a
  no-op; only the reverse — an agent claiming a role the map does not define — is
  fatal.
- **This feature supersedes two shipped requirements.** The generic-core spec
  pinned `model: opus` in agent frontmatter and pinned Opus and Fable in the
  routing rows, and two test files assert those literally. They are marked
  superseded in place and their assertions rewritten to the role binding, rather
  than left to fail silently.
- **One working model beats a tiered default (owner, at Gate 1).** The first
  draft made the judge a different model from the builder by default, which bakes
  a two-model plan into every install. The shipped default is now one model for
  judge, build and verify, a cheap one for read, and a named escalation entry —
  so a single-model plan works out of the box and a stronger model is something
  the owner reaches for, not something they inherit.
- **The judge has no agent.** The main session's model is set by the owner in the
  harness, not by this framework. The map records the intent so a session can
  compare itself against it and report a mismatch, which is exactly the owner's
  "check what model to use at the beginning of each session".
