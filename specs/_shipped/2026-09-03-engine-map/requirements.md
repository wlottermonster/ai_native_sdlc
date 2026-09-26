# Requirements — engine-map

<!-- The framework must not hard-code model names. It routes by ROLE, the owner
     chooses which model fills each role in one file the installer never
     overwrites, and every session states the mapping it is actually running
     under instead of assuming.

     Wording convention (inherited from the generic-core spec): a command, agent
     or policy file is a prompt file. Its requirements say "THE <file> SHALL
     instruct the model to …" or "SHALL contain …", so a content assertion proves
     exactly the claim and `verify: unit` is literally true. Behaviour of the
     shell pieces (installer, script, hook) is `verify: integration` and is
     proved in a throwaway HOME.

     TEST_PROFILE = lib. No literal four-digit years anywhere in framework prose
     (the scrub fence forbids them). -->

## A. Routing by role

REQ-ENGINE-001  WHEN sdlc-policy.md's routing table is read, ITS third column
                SHALL be headed `Role` and SHALL hold one of `judge`, `build`,
                `verify`, `read` on every phase row, naming no model.
                verify: unit

REQ-ENGINE-002  WHEN sdlc-policy.md is read, THE FILE SHALL retain a row for
                every phase it names today: architecture/spec/design, adversarial
                spec review, tests-first implementation, independent
                verification, final review, research/bulk reading, debugging
                evidence, RCA root cause, agentic e2e walkthrough, test-suite
                audit.
                verify: unit

REQ-ENGINE-003  WHEN sdlc-policy.md is read, THE FILE SHALL define the four roles
                and the work each covers: `judge` the main session's own
                reasoning, `build` the implementer, `verify` the reviewing and
                auditing agents, `read` bulk reading.
                verify: unit

REQ-ENGINE-004  WHEN sdlc-policy.md is read, THE FILE SHALL name
                `~/.claude/sdlc-engines.conf` as the binding from role to model,
                and SHALL NOT assert a specific model as the main session's.
                verify: unit

## B. The engine map

REQ-ENGINE-005  WHEN the repo is read, THE FILE `templates/sdlc-engines.conf`
                SHALL exist and SHALL define all four roles, each with a primary
                model and at least one fallback, plus comments explaining the
                format and how to change it.
                verify: unit

REQ-ENGINE-006  WHEN `templates/sdlc-engines.conf` is read, THE FILE SHALL use
                the line format `<role> = <model>[, <model>…]`, SHALL treat a
                line whose first non-blank character is `#` as a comment, and
                SHALL ignore blank lines.
                verify: unit

REQ-ENGINE-007  WHEN install.sh runs and `$HOME/.claude/sdlc-engines.conf` does
                not exist, THE SCRIPT SHALL create it from the template and say
                so.
                verify: integration

REQ-ENGINE-008  WHEN install.sh runs and `$HOME/.claude/sdlc-engines.conf`
                already exists, THE SCRIPT SHALL leave its contents byte-for-byte
                unchanged, whatever the template now says.
                verify: integration

## C. Applying the map

REQ-ENGINE-009  WHEN the repo is read, THE FILE `agents/roles.conf` SHALL map
                every agent shipped in `agents/` to exactly one role, and SHALL
                name no agent that the repo does not ship.
                verify: unit

REQ-ENGINE-010  WHEN `scripts/apply-engines.sh` runs, THE SCRIPT SHALL read the
                engine map and the role manifest and SHALL set the `model:` line
                of each installed agent under `$HOME/.claude/agents/` to the
                first model listed for that agent's role.
                verify: integration

REQ-ENGINE-011  WHEN `scripts/apply-engines.sh` rewrites an agent, THE SCRIPT
                SHALL change only that agent's `model:` line: every other byte of
                the file, frontmatter and body alike, SHALL be unchanged.
                verify: integration

REQ-ENGINE-012  WHEN `scripts/apply-engines.sh` runs a second time with no change
                to the map, THE SCRIPT SHALL rewrite nothing and SHALL report
                that no agent changed.
                verify: integration

REQ-ENGINE-013  WHEN `scripts/apply-engines.sh` changes an agent, THE SCRIPT
                SHALL print one line per change naming the agent, the old model
                and the new model, and SHALL print the count of agents changed.
                verify: integration

REQ-ENGINE-014  WHEN the role manifest names a role the engine map does not
                define, or the map contains a malformed line or an empty model
                name, THE SCRIPT SHALL exit non-zero with a message naming the
                offending line and SHALL leave every agent file unchanged.
                verify: integration

REQ-ENGINE-015  WHEN install.sh runs, THE SCRIPT SHALL run
                `scripts/apply-engines.sh` after installing the agents, and SHALL
                exit non-zero if that script fails.
                verify: integration

## D. The session-start announcement

REQ-ENGINE-016  WHEN `hooks/session-engines.sh` runs, THE SCRIPT SHALL emit JSON
                whose `hookSpecificOutput.hookEventName` is `SessionStart` and
                whose `additionalContext` contains the active engine map.
                verify: integration

REQ-ENGINE-017  WHEN `hooks/session-engines.sh` runs and no engine map exists,
                THE SCRIPT SHALL emit valid JSON saying the map is absent and the
                built-in defaults apply, and SHALL exit 0.
                verify: integration

REQ-ENGINE-018  WHEN the emitted `additionalContext` is read, IT SHALL instruct
                the session to state in ONE line, at the start of its first
                reply, the model it is running as and the roles that model
                covers.
                verify: integration

REQ-ENGINE-019  WHEN the emitted `additionalContext` is read, IT SHALL instruct
                the session that if the model it is running as is not the first
                model listed for `judge`, it says so in that same line rather
                than routing as though it were.
                verify: integration

REQ-ENGINE-020  WHEN `settings/hooks-snippet.json` is read, IT SHALL contain a
                `SessionStart` hook entry invoking
                `$HOME/.claude/hooks/session-engines.sh`, and the file SHALL
                remain valid JSON.
                verify: unit

REQ-ENGINE-021  WHEN install.sh finishes, THE SCRIPT SHALL tell the owner that
                the settings merge is theirs to perform because the session
                cannot edit `~/.claude/settings.json`, and SHALL name the
                `SessionStart` entry as newly added.
                verify: integration

## E. Choosing, and losing, a model

REQ-ENGINE-022  WHEN sdlc-policy.md is read, THE FILE SHALL instruct the model
                that the list for a role is an ordered fallback chain, that a
                substitution is announced once when it is first used, and that no
                phase silently runs on a model the owner did not list.
                verify: unit

REQ-ENGINE-023  WHEN sdlc-policy.md is read, THE FILE SHALL state that a model
                named by the owner in the moment outranks the map, and that no
                project may pin `model` in its own `.claude/settings.json`
                because the map is the single binding.
                verify: unit

## F. Documentation

REQ-ENGINE-024  WHEN README.md's "Project layer" section is read, IT SHALL
                describe the engine map, name its path, and state that the
                installer creates it once and never overwrites it.
                verify: unit

REQ-ENGINE-025  WHEN index.html is read, ITS crew section SHALL present the four
                roles rather than fixed model names, and SHALL name the engine
                map as what binds a role to a model.
                verify: unit

REQ-ENGINE-026  WHEN install.sh's closing instructions are read, THEY SHALL NOT
                reference the deleted `sdlc_llm` command.
                verify: integration

## G. Consequences the first pass missed

REQ-ENGINE-027  WHEN a role defined in the engine map has no agent bound to it in
                the manifest — `judge` always, because the main session has no
                frontmatter — THE SCRIPT SHALL treat it as a no-op and SHALL NOT
                fail.
                verify: integration

REQ-ENGINE-028  WHEN an agent is installed under `$HOME/.claude/agents/` that the
                manifest does not name, THE SCRIPT SHALL leave that file
                byte-unchanged and SHALL report it as skipped.
                verify: integration

REQ-ENGINE-029  WHEN the manifest names an agent that is not installed, THE
                SCRIPT SHALL warn, name it, and continue with the rest.
                verify: integration

REQ-ENGINE-030  WHEN `scripts/apply-engines.sh` looks for the role manifest, IT
                SHALL prefer `$HOME/.claude/agents/roles.conf` and fall back to
                the manifest beside the running script's checkout; and install.sh
                SHALL install `agents/roles.conf` alongside the agents so the
                installed copy is runnable on its own.
                verify: integration

REQ-ENGINE-031  WHEN the scrub fence builds its file list, IT SHALL include
                `agents/*.conf` and `settings/*.json`, so a forbidden token in
                the role manifest or the hooks snippet cannot ship unscanned.
                verify: unit

REQ-ENGINE-032  WHEN this feature lands, THE SHIPPED generic-core requirements
                that pin a model by name — the agent frontmatter `model: opus`
                claim and the routing-row claim naming Opus and Fable — SHALL be
                marked superseded in place, and the assertions in
                `tests/test_routing.sh` and `tests/test_auditor.sh` that enforce
                them SHALL be rewritten to assert the role binding instead.
                verify: unit

REQ-ENGINE-033  WHEN `scripts/apply-engines.sh` writes an agent file, IT SHALL
                write to a temporary file in the same directory and rename it
                over the target, so an interrupted run never leaves a partial
                file.
                verify: integration

REQ-ENGINE-034  WHEN `hooks/session-engines.sh` runs, IT SHALL drain its standard
                input before doing anything else, and WHEN `jq` is unavailable IT
                SHALL emit a hand-built valid JSON object rather than a partial
                one, exiting 0 either way.
                verify: integration

REQ-ENGINE-035  WHEN `settings/hooks-snippet.json`'s SessionStart entry is read,
                IT SHALL carry a matcher limiting the hook to `startup`, `resume`
                and `clear`, and a timeout, so it does not re-fire on every
                compaction alongside the existing PostCompact entry.
                verify: unit

REQ-ENGINE-036  WHEN sdlc-policy.md's routing rules are read, THE FILE SHALL
                instruct the model to announce `<phase> → <role>` rather than
                `<phase> → <engine>`.
                verify: unit

REQ-ENGINE-037  WHEN README.md and index.html are read, NEITHER SHALL present a
                specific model as the fixed engine for a phase, an agent or a
                tier; both SHALL express the crew, the file map and the phase
                narration in roles.
                verify: unit

REQ-ENGINE-038  WHEN `scripts/apply-engines.sh` processes an agent file whose
                body contains a line beginning `model:`, or which has no `model:`
                line, or which ends without a trailing newline, IT SHALL change
                only the `model:` line inside the leading frontmatter fence, or
                nothing at all when there is none.
                verify: integration

## H. Opus by default, Fable on purpose (owner change at Gate 1)

REQ-ENGINE-039  WHEN `templates/sdlc-engines.conf` is read, ITS shipped defaults
                SHALL name the same model for `judge`, `build` and `verify` — the
                one general working model — with a cheaper model for `read`, and
                SHALL define a fifth entry `escalate` naming the model reserved
                for deliberate escalation.
                verify: unit

REQ-ENGINE-040  WHEN sdlc-policy.md is read, THE FILE SHALL define `escalate` as
                a lever rather than a routing row: no phase escalates on its own,
                the owner raises a phase to it by naming it in the moment, and any
                use of it is announced in the same one line as the phase.
                verify: unit

REQ-ENGINE-041  WHEN sdlc-policy.md is read, THE FILE SHALL instruct the model
                that `escalate` is also what a session offers, rather than
                silently takes, when a judgement is close, contested, or costly
                to get wrong.
                verify: unit

REQ-ENGINE-042  WHEN `scripts/apply-engines.sh` reads a map containing
                `escalate`, IT SHALL treat that entry as bound to no agent and
                SHALL NOT fail, exactly as it treats `judge`.
                verify: integration
