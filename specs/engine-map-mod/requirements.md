# Requirements — engine-map-mod

<!-- A Claude Code plugin of function hooks (a "mod") that makes the engine map
     effective at dispatch time instead of at install time. Today the map takes
     effect because scripts/apply-engines.sh rewrites the `model:` line of each
     installed agent; the mod reads the map when a subagent is dispatched and
     sets the model then. It routes; it never gates. The commit, Stop and
     requirement gates stay shell hooks, because a function hook that overruns
     its budget is treated as absent and the action proceeds, the fail-open
     class this repository's rules were paid for.

     Terms. "Once per process" means once for the life of one Claude Code
     process: the set of messages already shown lives in the engine's session
     state under one fixed key and the mod never resets it. "Bound" means the
     agent name appears in a role manifest (roles.conf) and that role appears
     in the map. "The map" is always `~/.claude/sdlc-engines.conf`; the mod
     never reads a map from anywhere else.

     Tiers. Behaviour of the hooks module is `verify: unit`, proved by the
     mod's own *.test.ts files run through `claude plugin test` with the
     engine mocked beneath them. Installer, gate and doctor behaviour is
     `verify: integration`, proved in a throwaway HOME. Three requirements are
     `deferred`: they depend on a shape of the live engine that only the T0
     probe can record, and they are rewritten from that record, never from a
     guess. Requirement bodies carry no other requirement's ID.

     No model name appears in this spec, the mod, its tests or the documents
     it touches: roles and fixture names only. TEST_PROFILE = lib. -->

## A. Loading and safety

REQ-MOD-001  WHEN the Claude adapter is installed (install.sh), THE INSTALLER
             SHALL place the mod at `~/.claude/skills/sdlc-engine-map/` as a
             plugin folder (manifest, hooks.json, hooks module, tests) through
             the existing skills install path with its ownership check and
             backup behaviour, and that installation SHALL add no key to
             settings.json (byte-identical before and after, in a HOME where
             no other migration applies).
             verify: integration

REQ-MOD-002  WHEN `make check` runs and `claude` is on PATH, THE GATE SHALL run
             `claude plugin validate` on the mod folder and SHALL fail when the
             validation fails.
             verify: integration

REQ-MOD-003  WHEN `make check` or `make test` runs and `claude` is NOT on PATH,
             THE GATE SHALL print one line saying the mod checks did not run
             and SHALL exit non-zero, unless `SDLC_SKIP_CLAUDE_MOD=1` is set,
             in which case it prints the same line and continues. The skip is
             always explicit, never inferred from the machine.
             verify: integration

REQ-MOD-004  WHEN a hook registered by the mod throws or overruns its budget,
             ITS `.catch` handler SHALL announce (toast and transcript line)
             the mod, the event and the failure kind and message, SHALL do no
             file I/O, and SHALL return `next(e)`: when the hook had not yet
             called `next`, the event proceeds un-routed; when it had, the
             already-settled result stands.
             verify: unit

REQ-MOD-005  WHEN `register` is called, IT SHALL wrap each registration so
             that a registration the engine refuses by throwing is recorded by
             event name and the remaining registrations still proceed; the
             recorded names are announced once per process at the first hook
             that runs, with the note that routing falls back to the agents'
             frontmatter.
             verify: unit

REQ-MOD-006  THE MOD SHALL register hooks on exactly the events `agent.spawn`,
             `session.start` and `turn.start` and on no other, as the hook
             report of `claude plugin validate` lists them, compared as a set.
             verify: integration

REQ-MOD-007  WHEN `agent.spawn` fires for a `subagentType` that is bound, has
             no `:` in its name, is not a fork and not a teammate, and the
             call set no `model`, THE MOD SHALL set `model` to the first entry
             of that role in the map.
             verify: unit

REQ-MOD-008  WHEN the call already set `model` and it differs from the map's
             first entry for that role, THE MOD SHALL leave it unchanged (a
             model named by the owner or chosen by the session outranks the
             map) and SHALL say once per process that the map was bypassed
             for that agent.
             verify: unit

REQ-MOD-009  WHEN `subagentType` is a fork, is a teammate, contains `:`, or is
             not bound, THE MOD SHALL pass the event through unchanged and
             SHALL say nothing.
             verify: unit

REQ-MOD-010  WHEN the map or a manifest is missing, or would be refused by
             scripts/apply-engines.sh (any error in any line), THE MOD SHALL
             pass every dispatch through unchanged and SHALL say so once per
             process, naming the file and the offending line number when there
             is one. It never routes the valid lines of a refused file.
             verify: unit

REQ-MOD-011  WHEN a subagent the mod routed ends with an error the engine
             attributes to the model being unavailable, THE MOD SHALL route
             every LATER dispatch of that role to the next entry of its chain
             for the rest of the process, in order and no further than the
             list goes, and SHALL say so once per role; the failed dispatch
             itself is not retried.
             verify: deferred

REQ-MOD-012  WHEN a subagent is dispatched on the live engine with a model id
             that does not exist, THE RECORDED PROBE SHALL show where the
             failure surfaces (the spawn result, a rejection, the subagent's
             turn completion) and what error kind it carries, so the fallback
             requirement above is written against the real shape.
             verify: deferred

REQ-MOD-013  WHEN every entry of a role's chain has failed in this process,
             THE MOD SHALL route later dispatches of that role with no model
             of its own (the frontmatter decides) and SHALL say once which
             role and how many entries were tried.
             verify: deferred

REQ-MOD-014  WHEN a dispatch is routed, THE MOD SHALL read the map and the
             manifests from disk at that dispatch, holding no copy across
             turns, so an edit to the map applies at the next dispatch without
             re-running apply-engines.sh.
             verify: unit

REQ-MOD-015  WHEN the map or a manifest is parsed, THE MOD SHALL reach the
             same verdict (accept, or refuse with the offending line number)
             and the same agent-to-first-entry table as scripts/apply-engines.sh
             on every case in `tests/fixtures/engine-map/`, a fixture set both
             tests/test_apply_engines.sh and the mod's tests run: comments,
             blank lines, whitespace around `=` and after commas, a trailing
             carriage return stripped, a duplicate key where the map's first
             wins and a manifest's last wins, an empty list element refused, a
             manifest role the map does not define refused, a manifest role
             containing a comma refused.
             verify: unit

REQ-MOD-016  WHEN `session.start` or a main-loop `turn.start` fires, THE MOD
             SHALL compare the main loop's model as the engine reports it (any
             bracketed suffix stripped) with the judge line's first entry, and
             SHALL treat them as matching when the id equals the entry, equals
             `claude-` plus the entry, or starts with `claude-` plus the entry
             plus `-`; it SHALL show `judge: <entry>` on the status line on a
             match and `JUDGE MISMATCH: <id> is not <entry>` otherwise.
             verify: unit

REQ-MOD-017  WHEN the status line is set by the mod, THE TEXT SHALL carry the
             active map in one line (`judge=… build=… verify=… read=…`), the
             mismatch flag when there is one, and the entry in force for any
             role that moved down its chain in this process.
             verify: unit

REQ-MOD-018  WHEN the mod has already shown a message in this process, IT
             SHALL NOT show an identical message again; new messages appear as
             a toast and a transcript line, and the standing state lives on
             the status line.
             verify: unit

## B. Precedence and environment

REQ-MOD-019  WHEN `<session root>/.claude/agents/roles.conf` exists, THE MOD
             SHALL consult it before `~/.claude/agents/roles.conf` for the
             agent name being dispatched, matching how a repository's own
             agents are bound under SDLC_AGENTS_DIR; the map itself is still
             read only from HOME.
             verify: unit

REQ-MOD-020  WHEN the environment variable `CLAUDE_CODE_SUBAGENT_MODEL` is
             set, THE MOD SHALL say once per process that subagent routing is
             overridden by that variable and SHALL still set the model it
             would have set, so the override is visible even if it wins.
             verify: unit

REQ-MOD-021  WHEN `agent.spawn` is routed, THE MOD SHALL call `next` at most
             once per dispatch and SHALL never return a `deny`, across every
             fixture (valid map, refused map, missing files, explicit model,
             fork, teammate, plugin agent, thrown error).
             verify: unit

## C. Coexistence with the installed binding

REQ-MOD-022  WHEN the mod is installed, scripts/apply-engines.sh, install.sh
             and hooks/session-engines.sh SHALL keep working unchanged, so the
             agents' frontmatter and the SessionStart announcement remain the
             binding and the statement for any session in which the mod is not
             loaded.
             verify: integration

REQ-MOD-023  WHEN adapters/claude/policy.md is read (and sdlc-policy.md
             rendered from it), THE FILE SHALL say that with the mod loaded a
             change to the map applies at the next dispatch and without it
             apply-engines.sh must be re-run, and SHALL name the mod as
             routing, not enforcement.
             verify: unit

REQ-MOD-024  WHEN the mod folder, its tests and the documents this feature
             touches are read, THEY SHALL name no model: the model-name
             pattern tests/test_docs_roles.sh applies to the README and the
             manual SHALL find nothing there.
             verify: unit

## D. Installer, doctor and documents

REQ-MOD-025  WHEN the skills install path copies a skill folder, IT SHALL skip
             `.DS_Store`, any `.claude-plugin/types/` directory, `tsconfig.json`
             and `node_modules`, so files the engine lays beside a loaded mod
             are neither installed nor hashed, and those names SHALL be
             ignored by git in the mod folder.
             verify: integration

REQ-MOD-026  WHEN `./doctor` runs and a file of the mod listed in the receipt
             is missing or changed, THE claude ROW SHALL name that file's path
             (which contains `skills/sdlc-engine-map`), using the receipt's
             existing managed-file check.
             verify: integration

REQ-MOD-027  WHEN the documents are read, ARCHITECTURE.md SHALL describe the
             mod in a routing paragraph set apart from the enforcement table,
             README.md's file map SHALL list it under the Claude adapter's
             skills while keeping the apply-engines.sh step in "Project layer",
             and the manual's `<h2>The crew</h2>` section SHALL say, in English
             and in the i18n block, that with the mod loaded a map change
             applies to the next dispatch.
             verify: unit

REQ-MOD-028  WHEN `make test` runs, tests/test_mod.sh SHALL run
             `claude plugin test` on the mod folder under the same explicit
             skip rule as the gate.
             verify: integration

REQ-MOD-029  WHEN the mod's test files are read, every test title SHALL match
             `REQ-MOD-[0-9]{3}`, checked by tests/test_mod.sh.
             verify: integration

REQ-MOD-030  WHEN the engine refuses a registration on the live build, THE
             RECORDED PROBE SHALL show whether `on()` throws or the module
             fails to load, so the refusal handling above is written against
             the real shape.
             verify: deferred
