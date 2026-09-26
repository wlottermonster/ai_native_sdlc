---
name: handback
description: Return an accepted interactive handoff to its exact originating conversation with the owner's decisions, changed files and verification evidence. Use when the user invokes /handback or explicitly asks to return.
---

# Return to the original conversation

Use `python3.12 ~/.codex/sdlc-openai/scripts/handoff.py --repo <root>`; retain explicit --state-dir from the
incoming package when present. Use the exact CODEX_THREAD_ID environment value (or the host-provided current task ID). Set surface=app in the desktop app, otherwise cli.

1. Inspect `status`, select the active handoff bound to this exact receiver
   session; never choose by newest timestamp. Read immutable start and progress.
2. Write a private return file, at most 64 KiB: completed work, owner decisions
   made in this conversation, changed paths, real check results, unresolved work
   and proposed next step. Include the bounded assignment's outcome. Do not claim
   tests passed without evidence. Usage remains unknown unless native usage data
   was actually available; do not estimate charges from transcript size.
3. Call `handback <id> --client codex --session <exact-id> --file <return-file>`.
   Remove your temporary input only after success. Returned is not yet resumed.
4. Get `launch <id> --return --mode print`. If source.surface=app and host tools
   can send a message and open that exact task, deliver the returned pointer and
   navigate there. This handback instruction authorizes that precise task delivery.
   Otherwise use `--mode terminal` to resume the original CLI session, or show the
   printed manual command. Label CLI fallback clearly for an app-origin task.
   Do not run both delivery routes or start duplicate sessions.
5. Yield immediately. Preserve the package until the source acknowledges it.

## When the original conversation receives a handback

Read return and progress, compare repository state and original acceptance
criteria. Record a compact closure note (at most 16 KiB), then call `ack <id>
--client codex --session <original-id> --file <closure-note>`.
Changed repository state since handback requires explicit owner reconciliation
with --allow-changed and --reconcile-reason. Successful ack means the original
conversation owns the work again; proceed with the next agreed task.

Then call `cleanup <id>`: it removes only the closed handoff's known temporary
payloads and retains manifest plus the closure summary. Never delete open
packages, native transcripts, source files or unrelated artifacts. Interrupted
return delivery remains recoverable from `status`; do not fabricate acknowledgment.

If an interrupted save leaves an immutable return or closure file beside an
active/returned manifest, preserve it. Do not delete or overwrite it to force a
retry. Inspect the existing evidence; the original session can reclaim through
`cancel` with a reason once the receiver has stopped, retaining the package.
