# Claude routing recommendation — not applied

Current owner map uses opus for judge/build/verify, haiku for read, and reserves
fable for explicit escalation. Proposed balanced map:

| Role | Model alias | Suggested effort where supported |
| --- | --- | --- |
| Planning / judge | opus | high |
| Implementation / build | sonnet | high |
| Independent verification | opus | high |
| Routine reading | haiku | default |
| Deliberate escalation | fable, subject to access | high initially |

Keep hard diagnosis and high-risk implementation on Opus when deliberately
selected. Evidence collection can remain with verification initially: the current
Claude role manifest binds evidence and UI testing to verify, unlike the new
Codex mapping. Do not silently change that established workflow.

Use native subagent frontmatter and the existing apply-engines script. The judge
entry expresses intent; it does not switch the active main session. Avoid the
CLAUDE_CODE_SUBAGENT_MODEL environment override, which overrides role choices.
The existing comma-separated framework entries are not proof that native fallback
is enabled. Prefer explicit reporting of unavailability over silent fallback.

Official docs say opus/sonnet aliases follow provider-recommended versions, while
full model IDs pin versions. Alias resolution varies by provider. Fable may use
additional usage credits; keep the existing owner-only escalation policy.

Sources checked during this implementation:
- https://code.claude.com/docs/en/model-config
- https://code.claude.com/docs/en/sub-agents

No Claude engine-map, agent model or effort change is authorized by a request for
recommendations alone, so this task leaves those choices unchanged.
