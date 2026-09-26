---
name: handoff
description: Transfer the current task interactively to Claude or Codex when the user invokes /handoff or explicitly asks to switch clients with context. Use global phase defaults unless model or effort is specified.
---

# Interactive handoff

User invocation authorizes preparing context and opening the receiving client.
Use `~/.codex/sdlc-openai/scripts/handoff.py` with Python 3.12. Read `--help` and subcommand help when needed.
Do not copy private transcripts or another project's implementation.

1. Read project instructions and current work state. Use the exact CODEX_THREAD_ID environment value (or the host-provided current task ID). Set surface=app in the desktop app, otherwise cli.
   Missing exact identity is a blocker to reliable handback: ask for that ID,
   never select a recent session by timestamp. Check `status` for an open transfer.
2. Resolve destination (`claude` or `codex`) and receiving assignment from the
   conversation. The phase is the NEXT assigned phase: a build followed by review
   uses `review`, not `build`. Allow explicit `--role`, `--model`, `--effort`.
   If task or phase is ambiguous, ask one focused question. Model selection comes
   from destination global settings; never automatically dispatch escalation.
3. Write a private temporary Markdown context file, at most 32 KiB: original
   request; assigned task and acceptance criteria; decisions/constraints; relevant
   files; dirty changes; test evidence with limitations; failed approaches; exact
   next step. Include only relevant information. Omit credentials and raw logs.
4. Run `prepare --source-client codex --source-session <exact-id>
   --source-surface <app|cli> --to <client> --phase <assigned-phase>
   --task <bounded-assignment> --context-file <path>` with optional overrides.
   Global `--repo <absolute-root>` precedes the subcommand. Read structured output.
   Delete your temporary context input only after preparation succeeds; the durable
   start package is retained. Never interpolate raw arguments into shell code.
5. Show destination, task, requested model/effort and the handoff ID. Run
   `launch <id> --mode terminal` to open a separate interactive terminal on macOS.
   If unsupported or failed, show `launch <id> --mode print` output and the exact
   manual command. An opened window is not accepted work. Do not run a headless
   worker as a substitute for the owner's interactive conversation.
6. Yield: end the current turn without continuing edits or looping. Report
   prepared/awaiting receiver until acceptance exists. The user now talks directly
   with the receiving client. Preserve source session for handback.

## Receiving an incoming package

Read its start file and manifest, verify repository state, then call `accept <id>
--client codex --session <your-exact-id>`. Use global --state-dir if supplied
in the incoming pointer. Acceptance with changed files requires owner reconciliation
using --allow-changed and --reconcile-reason; never automatically bypass freshness.
Requested model is not observed evidence. Only populate observed model/effort from
reliable native runtime metadata; otherwise leave unknown. Continue the accepted
assignment with the owner, asking clarification normally. Save meaningful decisions
through `progress` using a private text file. The owner invokes `/handback` to return.

## Recovery

For an abandoned transfer, confirm the receiver has stopped, then the source may
run `cancel <id> --client codex --session <source-id> --receiver-stopped
--reason <reason>`. This reclaims cooperative ownership; it does not kill a client.
No nested transfer: finish or explicitly cancel the current handoff first.
