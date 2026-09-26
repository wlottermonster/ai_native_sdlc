---
name: openai-sdlc
description: Run the global OpenAI software lifecycle for projects under the configured workspace, including feature planning, implementation loops, verification, debugging, release, and resumable handoffs. Use for software work in that workspace or explicit OpenAI SDLC requests.
---

# OpenAI SDLC

Read `~/.codex/sdlc-openai/installation.json` for the workspace and source,
then `~/.codex/sdlc-openai/policy.md` and `engines.toml`. If installation is
missing, use the framework source policy and report that global setup is absent.
Apply automatically only within the configured workspace. Existing project
instructions, actual user intent and authorization determine the task scope.

Choose the relevant workflow in [workflows.md](references/workflows.md), loading
only its section. For multi-step work and handoffs, use the executable examples
in [loops.md](references/loops.md). For tool choice, consult
[tools.md](references/tools.md) when an external capability is needed.

Start by reading project instructions and Git status. Identify the acceptance
criteria and required check commands. Scale process to the change: small fixes
don't need a platform design. A plan already approved remains approved.

Keep durable records; verify current files with real commands; report the outcome,
evidence and any remaining limitation. Never claim independent review when the
same agent did it. Never claim hooks are active merely because files exist.

Examples: "Use OpenAI SDLC to build this feature", "Resume the checkout fix",
"Verify and ship this branch", "Investigate why login fails".
