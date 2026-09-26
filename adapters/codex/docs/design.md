> Historical pre-consolidation record, retained for provenance. Current source
> layout and policy are described by the repository README and ARCHITECTURE.md.

# Global OpenAI SDLC

The owner approved one workspace, independent Claude/Codex frameworks, global
Codex defaults for projects under the workspace root, and separate worktrees for concurrent
work. This document makes that approved design executable.

## Scope

Source lives here. Installation lives in ~/.codex/sdlc-openai, with a Codex-only
skill under ~/.codex/skills/openai-sdlc and a managed global AGENTS.md section.
No writes to ~/.claude, ~/.agents, other projects, shell startup, or Git hooks.
Global applicability is checked against the configured workspace's resolved
path, including nested repositories. Other workspaces keep ordinary Codex rules.

## Migration

Back up affected Codex files before installation. Replace only the obsolete
imported model/routing sections in global AGENTS.md. Preserve owner preferences.
Disable Codex external-agent import sync so Claude does not overwrite this setup.
Replace known imported SDLC hook entries; retain unrelated hooks and safety guard.
Never populate hook trust hashes or bypass trust. Codex requires its own hook
review after installation. Existing model and plugin configuration stays intact.

## Runtime

One skill routes feature/spec/build/verify/ship/debug/audit/handoff workflows.
Load task-specific references progressively. Context consists of requirements,
design, tasks, decisions, evidence and a durable JSON loop record, never secrets.
Roles inherit the selected session model; an owner-controlled role map can express
future routing. No claim that a file can change the current model automatically.

The loop helper persists objective, attempts, repeated-failure count, budget,
status, last evidence and next step. It stops on budget or repeated-failure limit.
It does not autonomously launch models. A bounded check runner executes argv
commands, records exit status and duration, and kills its process group on timeout.
Missing checks are a reported gap, never a green result. Commit checks are a
best-effort hook convenience; CI and explicit evidence are authoritative.

Startup and post-compaction hooks inject scoped policy references. Stop hooks
inspect explicitly tracked active work, permit questions/read-only turns, and
bound continuation to avoid infinite loops. No hook is a sandbox replacement.

## Verification

Test installer in a fake home with Claude sentinels, custom preferences/hooks,
idempotence, conflicting paths and malformed configuration. Test loop transitions,
timeouts, passing/failing checks, workspace boundaries and hook JSON. Review the
installed configuration and compare Claude hashes before/after. Validate skills
and run a read-only independent scenario review. Run your own settings backup
after meaningful settings changes. No deployment or repository push is needed.
