# Interactive handoff and handback

Approved by the owner's instruction to implement the discussed original design.
No external project's source is cloned, copied or installed.

- REQ-HAND-001: Preparation records exact source client/session/surface, repository state, current phase, explicit assignment, target model/effort and a bounded Markdown briefing under a unique handoff ID. [verify: integration]
- REQ-HAND-002: Target model defaults come from that client's global role map using the current/next assigned phase; explicit model and effort override independently. Unknown phase or missing identity fails clearly, with no newest-session guessing or silent fallback. [verify: integration]
- REQ-HAND-003: The receiver accepts the exact package and checks repository freshness before continuing interactively with the owner. Source workflow yields ownership; launching a process alone is not acceptance. Cooperation is not an OS lock against arbitrary edits. [verify: integration]
- REQ-HAND-004: Handback records the receiver's work, owner decisions, tests and remaining work, then resumes the exact source conversation with a pointer to the return package. The source acknowledges receipt before closing. Source app navigation may require host-native tools; CLI resume is a documented fallback, never impersonated as an in-app switch. [verify: integration]
- REQ-HAND-005: State transitions are guarded and atomically persisted with an interprocess lock. Duplicate acceptance/return cannot overwrite context. Interrupted transfers retain recoverable state. One open handoff per checkout; nested handoffs are rejected in the initial version. [verify: integration]
- REQ-HAND-006: Cleanup may delete only this tool's known temporary payloads after the source acknowledged return, retaining a compact audit record. Live/open handoffs, source files, native transcripts and unrelated files are never deleted. [verify: integration]
- REQ-HAND-007: Install thin native commands/skills for both clients over a common original implementation. Use supported CLI launch/resume controls, capability preflight, argument arrays and a manual launch fallback. No permission bypass flags or private transcript rewriting. [verify: integration]
- REQ-HAND-008: Store requested and observed model selection separately, with unknown runtime selection and usage represented as unknown. Do not infer costs or fabricate token counts. Test both direction lifecycles, overrides, stale state, concurrency, interrupted launches and cleanup; report live probe limits honestly. [verify: integration]
