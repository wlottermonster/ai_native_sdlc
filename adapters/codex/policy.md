# Codex adapter policy

Read engines.toml; inherit means the active host-selected model. Never import the
Claude engine map or claim a model change from a file. The discoverable skill is
~/.codex/skills/openai-sdlc/SKILL.md; runtime is ~/.codex/sdlc-openai/scripts/sdlc.py.
Workspace and canonical source are recorded in installation.json. Hook trust is
reviewed by the owner through the host; installation does not grant trust.

For multi-step builds use `~/.codex/sdlc-openai/scripts/sdlc.py begin` with an
explicit objective and attempt budget. Its check command accepts `--timeout` for
longer project checks. The ordinary commit hook allows 870 seconds inside a
900-second host timeout, preserving a 30-second cleanup margin for long suites.
A check that exceeds the internal budget is denied; measure each project's gate
before claiming it fits. Missing checks and failed checks still deny the commit.
SessionStart injects scoped context. PostCompact uses the host system message.
Stop requests one continuation for active runs, then yields. None proves that
the host enabled or trusted the hooks.

The existing Codex release policy is retained: push follows the authorization
the owner has already given for that repository; never force-push, respect
runtime permissions, and plainly report when push deploys to production.

Project onboarding: `python3.12 ~/.codex/sdlc-openai/scripts/project.py --repo <project-root>`
inspects the local contract; add `--apply` for authorized enrollment/repair.

## Stage-specific agents

The global engines.toml maps roles to models and reasoning effort. The installer
renders those settings into native global agent definitions. Rerun the installer
after editing the map; doctor reports map/agent drift. Never claim a model change
inside an already-running parent session. Use planner for substantial design,
implementer for approved implementation, spec-reviewer for design review,
verifier and test-auditor for independent checks, researcher/evidence for focused
reading and reproduction, and ui-tester for browser walkthroughs. These workflow
instructions authorize useful bounded delegation; small changes stay inline.
Use fresh context for independent review, passing concrete paths and evidence.
Only dispatch escalation when the owner explicitly requests it. If a required
model is unavailable, report the failure; do not silently substitute models.
Record actual dispatch metadata when exposed, never treat an agent's statement
of its own model as proof. New native definitions may require a client restart.
